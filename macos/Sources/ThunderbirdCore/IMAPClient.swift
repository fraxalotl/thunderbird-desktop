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
  private let credential: Credential
  private let timeout: TimeInterval
  private var connection: LineConnection?
  private var tagCounter = 0
  public private(set) var capabilities: Set<String> = []
  private var selectedPath: String?
  private var lastTaggedStatus = ""

  public init(server: ServerConfig, credential: Credential, timeout: TimeInterval = 60) {
    self.server = server
    self.credential = credential
    self.timeout = timeout
  }

  public init(server: ServerConfig, password: String) {
    self.init(server: server, credential: .password(password))
  }

  public var isConnected: Bool { connection != nil }

  public func connect() async throws {
    let connection = LineConnection(
      host: server.host, port: server.port, implicitTLS: server.security == .tls, timeout: timeout)
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
        lastTaggedStatus = status
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
    if let token = credential.xoauth2(user: server.username) {
      let connection = try requireConnection()
      let tag = nextTag()
      try await connection.write("\(tag) AUTHENTICATE XOAUTH2 \(token)\r\n")
      while true {
        let raw = try await readResponse()
        if raw.first == UInt8(ascii: "+") {
          try await connection.write("\r\n")
          continue
        }
        if raw.starts(with: Data("\(tag) ".utf8)) {
          let status = String(decoding: raw.dropFirst(tag.count + 1), as: UTF8.self)
          guard status.uppercased().hasPrefix("OK") else { throw MailError.authenticationFailed(status) }
          return
        }
      }
    }
    guard case .password(let password) = credential else { return }
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

  /// Paths the user has subscribed to (LSUB). Empty when the server doesn't track subscriptions.
  public func subscribedPaths() async throws -> Set<String> {
    let responses = try await command(#"LSUB "" "*""#)
    return Set(responses.filter { $0.keyword == "LSUB" }.compactMap { $0.values.count >= 5 ? $0.values[4].text : nil })
  }

  public func setSubscribed(_ path: String, _ subscribed: Bool) async throws {
    try await command("\(subscribed ? "SUBSCRIBE" : "UNSUBSCRIBE") \(Self.quote(path))")
  }

  public func expungeFolder(_ path: String) async throws {
    try await select(path)
    try await command("EXPUNGE")
  }

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
    let items = "UID FLAGS INTERNALDATE RFC822.SIZE ENVELOPE BODY.PEEK[HEADER.FIELDS (CONTENT-TYPE REFERENCES X-PRIORITY IMPORTANCE LIST-POST)]"
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

  /// Moves messages and returns the source → destination UID map from COPYUID, when the server reports it.
  @discardableResult
  public func move(uids: [UInt32], from source: String, to destination: String) async throws -> [UInt32: UInt32] {
    guard !uids.isEmpty else { return [:] }
    try await ensureSelected(source)
    let set = Self.sequenceSet(uids)
    if capabilities.contains("MOVE") {
      let responses = try await command("UID MOVE \(set) \(Self.quote(destination))")
      return Self.copyUIDs(responses.map(\.line) + [lastTaggedStatus])
    }
    let responses = try await command("UID COPY \(set) \(Self.quote(destination))")
    let mapping = Self.copyUIDs(responses.map(\.line) + [lastTaggedStatus])
    try await expunge(uids: uids, in: source)
    return mapping
  }

  /// Parses `[COPYUID <validity> <source set> <destination set>]` (RFC 4315).
  static func copyUIDs(_ lines: [String]) -> [UInt32: UInt32] {
    for line in lines {
      guard let range = line.range(of: "[COPYUID ", options: .caseInsensitive),
        let end = line[range.upperBound...].firstIndex(of: "]")
      else { continue }
      let parts = line[range.upperBound..<end].split(separator: " ")
      guard parts.count == 3 else { continue }
      let source = expandSet(String(parts[1]))
      let destination = expandSet(String(parts[2]))
      guard source.count == destination.count else { continue }
      return Dictionary(zip(source, destination), uniquingKeysWith: { first, _ in first })
    }
    return [:]
  }

  static func expandSet(_ set: String) -> [UInt32] {
    set.split(separator: ",").flatMap { part -> [UInt32] in
      let bounds = part.split(separator: ":").compactMap { UInt32($0) }
      guard let first = bounds.first else { return [] }
      let last = bounds.count > 1 ? bounds[1] : first
      return first <= last ? Array(first...last) : Array((last...first).reversed())
    }
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

  @discardableResult
  public func copy(uids: [UInt32], from source: String, to destination: String) async throws -> [UInt32: UInt32] {
    guard !uids.isEmpty else { return [:] }
    try await ensureSelected(source)
    let responses = try await command("UID COPY \(Self.sequenceSet(uids)) \(Self.quote(destination))")
    return Self.copyUIDs(responses.map(\.line) + [lastTaggedStatus])
  }

  public func expungeAll(in path: String) async throws {
    try await ensureSelected(path)
    try await command("STORE 1:* +FLAGS.SILENT (\\Deleted)")
    try await command("EXPUNGE")
  }

  public func create(_ path: String) async throws {
    try await command("CREATE \(Self.quote(path))")
    _ = try? await command("SUBSCRIBE \(Self.quote(path))")
  }

  public func rename(_ path: String, to newPath: String) async throws {
    if selectedPath == path {
      _ = try? await command("CLOSE")
      selectedPath = nil
    }
    try await command("RENAME \(Self.quote(path)) \(Self.quote(newPath))")
  }

  public func delete(folder path: String) async throws {
    if selectedPath == path {
      _ = try? await command("CLOSE")
      selectedPath = nil
    }
    try await command("DELETE \(Self.quote(path))")
  }

  /// Runs `UID SEARCH` with pre-built criteria; non-ASCII text is sent as a UTF-8 literal.
  public func search(_ query: SearchQuery, in path: String) async throws -> [UInt32] {
    try await ensureSelected(path)
    var criteria: [String] = []
    if query.unreadOnly { criteria.append("UNSEEN") }
    if query.flaggedOnly { criteria.append("FLAGGED") }
    if let since = query.since {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.dateFormat = "d-MMM-yyyy"
      criteria.append("SINCE \(formatter.string(from: since))")
    }
    let text = query.text.trimmingCharacters(in: .whitespaces)
    let responses: [IMAPResponse]
    if text.isEmpty {
      responses = try await command("UID SEARCH \(criteria.isEmpty ? "ALL" : criteria.joined(separator: " "))")
    } else if text.allSatisfy({ $0.isASCII }) {
      let quoted = Self.quote(text)
      let textCriteria: String =
        switch query.field {
        case .all: "TEXT \(quoted)"
        case .subject: "SUBJECT \(quoted)"
        case .from: "FROM \(quoted)"
        case .recipients: "OR OR TO \(quoted) CC \(quoted) BCC \(quoted)"
        case .body: "BODY \(quoted)"
        case .headers: "OR OR SUBJECT \(quoted) FROM \(quoted) TO \(quoted)"
        }
      responses = try await command("UID SEARCH \((criteria + [textCriteria]).joined(separator: " "))")
    } else {
      let key: String =
        switch query.field {
        case .all, .headers: "TEXT"
        case .subject: "SUBJECT"
        case .from: "FROM"
        case .recipients: "TO"
        case .body: "BODY"
        }
      let prefix = (["UID SEARCH CHARSET UTF-8"] + criteria + [key]).joined(separator: " ")
      responses = try await commandWithLiteral(prefix, literal: Data(text.utf8))
    }
    return responses.filter { $0.keyword == "SEARCH" }.flatMap { response in
      response.values.dropFirst(2).compactMap { $0.text.flatMap { UInt32($0) } }
    }
  }

  public func searchHeader(_ name: String, value: String, in path: String) async throws -> [UInt32] {
    try await ensureSelected(path)
    let responses = try await command("UID SEARCH HEADER \(Self.quote(name)) \(Self.quote(value))")
    return responses.filter { $0.keyword == "SEARCH" }.flatMap { response in
      response.values.dropFirst(2).compactMap { $0.text.flatMap { UInt32($0) } }
    }
  }

  /// Waits in IDLE until the selected mailbox changes. Returns false if IDLE isn't supported.
  public func idleUntilChange(in path: String) async throws -> Bool {
    guard capabilities.contains("IDLE") else { return false }
    try await select(path)
    let connection = try requireConnection()
    let tag = nextTag()
    try await connection.write("\(tag) IDLE\r\n")
    while true {
      let response = IMAPResponse(raw: try await readResponse())
      if response.raw.first == UInt8(ascii: "+") { continue }
      if response.line.hasPrefix(tag) {
        return false
      }
      if ["EXISTS", "EXPUNGE", "FETCH", "RECENT"].contains(response.keyword ?? "") {
        try await connection.write("DONE\r\n")
        _ = try await collect(tag: tag)
        return true
      }
    }
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
    let headerBlock = attributes.first(where: { $0.key.hasPrefix("BODY[HEADER") })?.value.data ?? Data()
    let headers = MIMEParser.parseHeaders(headerBlock + Data("\r\n\r\n".utf8))
    let contentType = headers["Content-Type"]?.lowercased() ?? ""
    var summary = MessageSummary(
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
      hasAttachment: contentType.contains("multipart/mixed"),
      references: MessageSummary.parseReferences(headers["References"])
    )
    summary.priority = MessageSummary.parsePriority(headers["X-Priority"] ?? headers["Importance"])
    summary.listPost = MessageSummary.parseListPost(headers["List-Post"])
    summary.received = attributes["INTERNALDATE"]?.text.flatMap(MailDate.parseInternalDate)
    return summary
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
