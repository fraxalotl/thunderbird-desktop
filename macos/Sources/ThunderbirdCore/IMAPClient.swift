/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation

public struct SelectedMailbox: Sendable {
  public var exists: Int
  public var uidValidity: UInt32
  public var uidNext: UInt32?
}

public actor IMAPClient {
  private let server: ServerConfig
  private let password: String
  private var connection: LineConnection?
  private var tagCounter = 0
  public private(set) var capabilities: Set<String> = []
  private var selectedPath: String?

  public init(server: ServerConfig, password: String) {
    self.server = server
    self.password = password
  }

  public var isConnected: Bool { connection != nil }

  public func connect() async throws {
    let connection = LineConnection(host: server.host, port: server.port, implicitTLS: server.security == .tls)
    self.connection = connection
    do {
      let greeting = IMAPResponse(raw: try await readResponse())
      guard greeting.line.hasPrefix("* OK") || greeting.line.hasPrefix("* PREAUTH") else {
        throw MailError.protocolError(greeting.line)
      }
      if server.security == .startTLS {
        try await command("STARTTLS")
        await connection.startTLS()
      }
      try await refreshCapabilities()
      if !greeting.line.hasPrefix("* PREAUTH") {
        try await authenticate()
        try await refreshCapabilities()
      }
    } catch {
      await disconnect()
      throw error
    }
  }

  public func disconnect() async {
    if let connection {
      try? await connection.write("\(nextTag()) LOGOUT\r\n")
      await connection.close()
    }
    connection = nil
    selectedPath = nil
  }

  // MARK: - Protocol plumbing

  private func nextTag() -> String {
    tagCounter += 1
    return String(format: "A%04d", tagCounter)
  }

  private func requireConnection() throws -> LineConnection {
    guard let connection else { throw MailError.connectionClosed }
    return connection
  }

  /// Reads one response, following any `{n}` literals that continue it onto further lines.
  private func readResponse() async throws -> Data {
    let connection = try requireConnection()
    var result = Data()
    var line = try await connection.readLine()
    while let length = Self.literalLength(line) {
      result.append(line)
      result.append(crlf)
      result.append(try await connection.readBytes(length))
      line = try await connection.readLine()
    }
    result.append(line)
    return result
  }

  static func literalLength(_ line: Data) -> Int? {
    guard line.last == UInt8(ascii: "}"), let open = line.lastIndex(of: UInt8(ascii: "{")) else { return nil }
    var digits = line[line.index(after: open)..<line.index(before: line.endIndex)]
    if digits.last == UInt8(ascii: "+") {
      digits = digits.dropLast()
    }
    return Int(String(decoding: digits, as: UTF8.self))
  }

  @discardableResult
  private func command(_ text: String) async throws -> [IMAPResponse] {
    let tag = nextTag()
    try await requireConnection().write("\(tag) \(text)\r\n")
    return try await collect(tag: tag)
  }

  private func collect(tag: String) async throws -> [IMAPResponse] {
    var untagged: [IMAPResponse] = []
    let prefix = Data("\(tag) ".utf8)
    while true {
      let raw = try await readResponse()
      if raw.starts(with: prefix) {
        let status = String(decoding: raw.dropFirst(prefix.count), as: UTF8.self)
        if status.uppercased().hasPrefix("OK") {
          return untagged
        }
        if status.localizedCaseInsensitiveContains("AUTHENTICATIONFAILED") {
          throw MailError.authenticationFailed(status)
        }
        throw MailError.server(status)
      }
      if raw.first == UInt8(ascii: "+") {
        continue
      }
      let response = IMAPResponse(raw: raw)
      if response.line.uppercased().hasPrefix("* BYE") {
        connection = nil
        throw MailError.connectionClosed
      }
      untagged.append(response)
    }
  }

  /// Sends a command whose last argument is a literal, waiting for the server's continuation.
  private func commandWithLiteral(_ text: String, literal: Data) async throws -> [IMAPResponse] {
    let connection = try requireConnection()
    let tag = nextTag()
    let useNonSynchronizing = capabilities.contains("LITERAL+")
    try await connection.write("\(tag) \(text) {\(literal.count)\(useNonSynchronizing ? "+" : "")}\r\n")
    if !useNonSynchronizing {
      while true {
        let raw = try await readResponse()
        if raw.first == UInt8(ascii: "+") {
          break
        }
        if raw.starts(with: Data("\(tag) ".utf8)) {
          throw MailError.server(String(decoding: raw, as: UTF8.self))
        }
      }
    }
    var payload = literal
    payload.append(crlf)
    try await connection.write(payload)
    return try await collect(tag: tag)
  }

  private func refreshCapabilities() async throws {
    let responses = try await command("CAPABILITY")
    var caps = Set<String>()
    for response in responses where response.keyword == "CAPABILITY" {
      for value in response.values.dropFirst(2) {
        if let text = value.text {
          caps.insert(text.uppercased())
        }
      }
    }
    capabilities = caps
  }

  private func authenticate() async throws {
    if capabilities.contains("AUTH=PLAIN") {
      let token = Data("\0\(server.username)\0\(password)".utf8).base64EncodedString()
      let connection = try requireConnection()
      let tag = nextTag()
      if capabilities.contains("SASL-IR") {
        try await connection.write("\(tag) AUTHENTICATE PLAIN \(token)\r\n")
      } else {
        try await connection.write("\(tag) AUTHENTICATE PLAIN\r\n")
        let challenge = try await readResponse()
        guard challenge.first == UInt8(ascii: "+") else {
          throw MailError.authenticationFailed(String(decoding: challenge, as: UTF8.self))
        }
        try await connection.write("\(token)\r\n")
      }
      do {
        _ = try await collect(tag: tag)
      } catch MailError.server(let detail) {
        throw MailError.authenticationFailed(detail)
      }
      return
    }
    guard !capabilities.contains("LOGINDISABLED") else {
      throw MailError.authenticationFailed("The server does not allow password login on this connection.")
    }
    do {
      try await command("LOGIN \(Self.quote(server.username)) \(Self.quote(password))")
    } catch MailError.server(let detail) {
      throw MailError.authenticationFailed(detail)
    }
  }

  static func quote(_ value: String) -> String {
    let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
  }

  // MARK: - Mailboxes

  public func listFolders() async throws -> [RemoteFolder] {
    let returnStatus = capabilities.contains("LIST-STATUS")
    let listCommand = returnStatus ? #"LIST "" "*" RETURN (STATUS (MESSAGES UNSEEN))"# : #"LIST "" "*""#
    let responses = try await command(listCommand)

    var folders: [RemoteFolder] = []
    var statuses: [String: (Int?, Int?)] = [:]
    for response in responses {
      switch response.keyword {
      case "LIST":
        guard response.values.count >= 5, let attributeList = response.values[2].items,
          let path = response.values[4].text
        else { continue }
        let attributes = Set(attributeList.compactMap { $0.text?.lowercased() })
        folders.append(RemoteFolder(path: path, delimiter: response.values[3].text, attributes: attributes))
      case "STATUS":
        if let (path, status) = Self.parseStatus(response) {
          statuses[path] = status
        }
      default:
        break
      }
    }

    if !returnStatus {
      for folder in folders where folder.isSelectable {
        if let response = try? await command("STATUS \(Self.quote(folder.path)) (MESSAGES UNSEEN)").first(where: {
          $0.keyword == "STATUS"
        }), let (_, status) = Self.parseStatus(response) {
          statuses[folder.path] = status
        }
      }
    }

    return folders.map { folder in
      var folder = folder
      if let (total, unseen) = statuses[folder.path] {
        folder.total = total
        folder.unseen = unseen
      }
      return folder
    }
  }

  private static func parseStatus(_ response: IMAPResponse) -> (String, (Int?, Int?))? {
    guard response.values.count >= 4, let path = response.values[2].text, let items = response.values[3].items else {
      return nil
    }
    var total: Int?
    var unseen: Int?
    var index = 0
    while index + 1 < items.count {
      let value = items[index + 1].text.flatMap { Int($0) }
      switch items[index].text?.uppercased() {
      case "MESSAGES": total = value
      case "UNSEEN": unseen = value
      default: break
      }
      index += 2
    }
    return (path, (total, unseen))
  }

  @discardableResult
  public func select(_ path: String) async throws -> SelectedMailbox {
    let responses = try await command("SELECT \(Self.quote(path))")
    selectedPath = path
    var mailbox = SelectedMailbox(exists: 0, uidValidity: 0, uidNext: nil)
    for response in responses {
      if response.keyword == "EXISTS", let count = response.number {
        mailbox.exists = count
      }
      if let validity = response.responseCode("UIDVALIDITY").flatMap({ UInt32($0) }) {
        mailbox.uidValidity = validity
      }
      if let next = response.responseCode("UIDNEXT").flatMap({ UInt32($0) }) {
        mailbox.uidNext = next
      }
    }
    return mailbox
  }

  private func ensureSelected(_ path: String) async throws {
    if selectedPath != path {
      try await select(path)
    }
  }

  // MARK: - Messages

  /// Fetches UID and flags for the newest `limit` messages of the selected mailbox.
  public func fetchFlags(newest limit: Int, exists: Int) async throws -> [UInt32: Set<String>] {
    guard exists > 0 else { return [:] }
    let first = max(1, exists - limit + 1)
    let responses = try await command("FETCH \(first):* (UID FLAGS)")
    var result: [UInt32: Set<String>] = [:]
    for response in responses where response.keyword == "FETCH" {
      let attributes = Self.fetchAttributes(response)
      if let uid = attributes["UID"]?.text.flatMap({ UInt32($0) }) {
        result[uid] = Self.flags(attributes["FLAGS"])
      }
    }
    return result
  }

  public func fetchSummaries(uids: [UInt32], in path: String) async throws -> [MessageSummary] {
    guard !uids.isEmpty else { return [] }
    try await ensureSelected(path)
    let items = "UID FLAGS INTERNALDATE RFC822.SIZE ENVELOPE BODY.PEEK[HEADER.FIELDS (CONTENT-TYPE)]"
    var summaries: [MessageSummary] = []
    for chunk in stride(from: 0, to: uids.count, by: 500).map({ Array(uids[$0..<min($0 + 500, uids.count)]) }) {
      let responses = try await command("UID FETCH \(Self.sequenceSet(chunk)) (\(items))")
      for response in responses where response.keyword == "FETCH" {
        if let summary = Self.summary(from: Self.fetchAttributes(response)) {
          summaries.append(summary)
        }
      }
    }
    return summaries
  }

  public func fetchMessage(uid: UInt32, in path: String) async throws -> Data {
    try await ensureSelected(path)
    let responses = try await command("UID FETCH \(uid) (UID BODY.PEEK[])")
    for response in responses where response.keyword == "FETCH" {
      let attributes = Self.fetchAttributes(response)
      if let body = attributes.first(where: { $0.key.hasPrefix("BODY[") })?.value.data {
        return body
      }
    }
    throw MailError.server("Message \(uid) is no longer on the server.")
  }

  public func store(flags: [String], add: Bool, uids: [UInt32], in path: String) async throws {
    guard !uids.isEmpty else { return }
    try await ensureSelected(path)
    try await command("UID STORE \(Self.sequenceSet(uids)) \(add ? "+" : "-")FLAGS.SILENT (\(flags.joined(separator: " ")))")
  }

  public func move(uids: [UInt32], from source: String, to destination: String) async throws {
    guard !uids.isEmpty else { return }
    try await ensureSelected(source)
    let set = Self.sequenceSet(uids)
    if capabilities.contains("MOVE") {
      try await command("UID MOVE \(set) \(Self.quote(destination))")
      return
    }
    try await command("UID COPY \(set) \(Self.quote(destination))")
    try await expunge(uids: uids, in: source)
  }

  public func expunge(uids: [UInt32], in path: String) async throws {
    guard !uids.isEmpty else { return }
    try await ensureSelected(path)
    let set = Self.sequenceSet(uids)
    try await command("UID STORE \(set) +FLAGS.SILENT (\\Deleted)")
    if capabilities.contains("UIDPLUS") {
      try await command("UID EXPUNGE \(set)")
    } else {
      try await command("EXPUNGE")
    }
  }

  public func append(_ message: Data, to path: String, flags: [String]) async throws {
    _ = try await commandWithLiteral("APPEND \(Self.quote(path)) (\(flags.joined(separator: " ")))", literal: message)
  }

  public func noop() async throws {
    try await command("NOOP")
  }

  // MARK: - Response decoding

  static func sequenceSet(_ uids: [UInt32]) -> String {
    let sorted = Array(Set(uids)).sorted()
    var ranges: [String] = []
    var index = 0
    while index < sorted.count {
      let start = sorted[index]
      var end = start
      while index + 1 < sorted.count, sorted[index + 1] == end + 1 {
        index += 1
        end = sorted[index]
      }
      ranges.append(start == end ? "\(start)" : "\(start):\(end)")
      index += 1
    }
    return ranges.joined(separator: ",")
  }

  static func fetchAttributes(_ response: IMAPResponse) -> [String: IMAPValue] {
    guard let list = response.values.last?.items else { return [:] }
    var attributes: [String: IMAPValue] = [:]
    var index = 0
    while index + 1 < list.count {
      if let key = list[index].text?.uppercased() {
        attributes[key] = list[index + 1]
      }
      index += 2
    }
    return attributes
  }

  static func flags(_ value: IMAPValue?) -> Set<String> {
    Set(value?.items?.compactMap { $0.text.map(MessageFlag.normalize) } ?? [])
  }

  static func summary(from attributes: [String: IMAPValue]) -> MessageSummary? {
    guard let uid = attributes["UID"]?.text.flatMap({ UInt32($0) }) else { return nil }
    let envelope = attributes["ENVELOPE"]?.items ?? []
    func field(_ index: Int) -> IMAPValue? {
      index < envelope.count ? envelope[index] : nil
    }
    let date = field(0)?.text.flatMap(MailDate.parse)
      ?? attributes["INTERNALDATE"]?.text.flatMap(MailDate.parseInternalDate)
      ?? Date(timeIntervalSince1970: 0)
    let contentType = attributes.first(where: { $0.key.hasPrefix("BODY[HEADER") })?.value.text?.lowercased() ?? ""
    return MessageSummary(
      uid: uid,
      subject: field(1)?.text.map(MIMEDecoder.decodeEncodedWords) ?? "",
      from: addresses(field(2)),
      to: addresses(field(5)),
      cc: addresses(field(6)),
      date: date,
      size: attributes["RFC822.SIZE"]?.text.flatMap { Int($0) } ?? 0,
      flags: flags(attributes["FLAGS"]),
      messageID: field(9)?.text,
      inReplyTo: field(8)?.text,
      hasAttachment: contentType.contains("multipart/mixed")
    )
  }

  static func addresses(_ value: IMAPValue?) -> [MailAddress] {
    (value?.items ?? []).compactMap { entry in
      guard let parts = entry.items, parts.count >= 4, let mailbox = parts[2].text, let host = parts[3].text else {
        return nil
      }
      let name = parts[0].text.map(MIMEDecoder.decodeEncodedWords)
      return MailAddress(name: name, email: "\(mailbox)@\(host)")
    }
  }
}
