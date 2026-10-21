/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation

public struct NewsgroupInfo: Sendable, Hashable, Identifiable {
  public var name: String
  public var high: Int
  public var low: Int
  public var id: String { name }
  public var estimatedCount: Int { max(0, high - low + 1) }
}

/// An NNTP (RFC 3977) connection for reading and posting news.
public actor NNTPClient {
  private let server: ServerConfig
  private let credential: Credential?
  private var connection: LineConnection?
  private var currentGroup: String?

  public init(server: ServerConfig, credential: Credential?) {
    self.server = server
    self.credential = credential
  }

  private func reply(_ connection: LineConnection) async throws -> (Int, String) {
    let line = String(decoding: try await connection.readLine(), as: UTF8.self)
    guard let code = Int(line.prefix(3)) else { throw MailError.protocolError(line) }
    return (code, line)
  }

  @discardableResult
  private func command(_ text: String, expect: Set<Int>) async throws -> String {
    let connection = try await connected()
    try await connection.write("\(text)\r\n")
    var (code, line) = try await reply(connection)
    if code == 480, credential != nil {
      try await authenticate(connection)
      try await connection.write("\(text)\r\n")
      (code, line) = try await reply(connection)
    }
    guard expect.contains(code) else {
      throw code == 481 ? MailError.authenticationFailed(line) : MailError.server(line)
    }
    return line
  }

  private func authenticate(_ connection: LineConnection) async throws {
    guard case .password(let password) = credential else { return }
    try await connection.write("AUTHINFO USER \(server.username)\r\n")
    let (code, line) = try await reply(connection)
    if code == 381 {
      try await connection.write("AUTHINFO PASS \(password)\r\n")
      let (passCode, passLine) = try await reply(connection)
      guard passCode == 281 else { throw MailError.authenticationFailed(passLine) }
    } else if code != 281 {
      throw MailError.authenticationFailed(line)
    }
  }

  private func connected() async throws -> LineConnection {
    if let connection { return connection }
    let connection = LineConnection(host: server.host, port: server.port, implicitTLS: server.security == .tls)
    let (code, line) = try await reply(connection)
    guard code == 200 || code == 201 else { throw MailError.server(line) }
    self.connection = connection
    if server.security == .startTLS {
      try await connection.write("STARTTLS\r\n")
      let (tlsCode, tlsLine) = try await reply(connection)
      guard tlsCode == 382 else { throw MailError.server(tlsLine) }
      await connection.startTLS()
    }
    try await connection.write("MODE READER\r\n")
    _ = try await reply(connection)
    if credential != nil, !server.username.isEmpty {
      try await authenticate(connection)
    }
    return connection
  }

  private func readMultiline() async throws -> Data {
    let connection = try await connected()
    var output = Data()
    while true {
      var line = try await connection.readLine()
      if line == Data(".".utf8) { return output }
      if line.first == UInt8(ascii: ".") { line.removeFirst() }
      output.append(line)
      output.append(crlf)
    }
  }

  public func close() async {
    if let connection {
      try? await connection.write("QUIT\r\n")
      await connection.close()
    }
    connection = nil
    currentGroup = nil
  }

  public func listGroups(matching pattern: String = "*") async throws -> [NewsgroupInfo] {
    try await command("LIST ACTIVE \(pattern)", expect: [215])
    let body = String(decoding: try await readMultiline(), as: UTF8.self)
    return body.split(separator: "\r\n").compactMap { line in
      let parts = line.split(separator: " ")
      guard parts.count >= 3, let high = Int(parts[1]), let low = Int(parts[2]) else { return nil }
      return NewsgroupInfo(name: String(parts[0]), high: high, low: low)
    }
  }

  @discardableResult
  public func group(_ name: String) async throws -> NewsgroupInfo {
    let line = try await command("GROUP \(name)", expect: [211])
    currentGroup = name
    let parts = line.split(separator: " ")
    guard parts.count >= 4, let low = Int(parts[2]), let high = Int(parts[3]) else {
      throw MailError.protocolError(line)
    }
    return NewsgroupInfo(name: name, high: high, low: low)
  }

  /// Fetches overview data for article numbers in `range` and turns it into summaries.
  public func overview(_ range: ClosedRange<Int>) async throws -> [MessageSummary] {
    try await command("OVER \(range.lowerBound)-\(range.upperBound)", expect: [224])
    let body = String(decoding: try await readMultiline(), as: UTF8.self)
    return body.split(separator: "\r\n").compactMap { line -> MessageSummary? in
      let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
      guard fields.count >= 7, let number = UInt32(fields[0]) else { return nil }
      return MessageSummary(
        uid: number,
        subject: MIMEDecoder.decodeEncodedWords(fields[1]),
        from: MailAddress.parseList(fields[2]),
        to: [],
        cc: [],
        date: MailDate.parse(fields[3]) ?? Date(timeIntervalSince1970: 0),
        size: Int(fields[6]) ?? 0,
        flags: [],
        messageID: fields[4],
        inReplyTo: MessageSummary.parseReferences(fields[5]).last,
        hasAttachment: false,
        references: MessageSummary.parseReferences(fields[5])
      )
    }
  }

  public func article(_ number: UInt32, in group: String) async throws -> Data {
    if currentGroup != group {
      try await self.group(group)
    }
    try await command("ARTICLE \(number)", expect: [220])
    return try await readMultiline()
  }

  public func post(_ message: Data) async throws {
    try await command("POST", expect: [340])
    try await connected().write(SMTPClient.dotStuffed(message) + Data(".\r\n".utf8))
    let (code, line) = try await reply(try await connected())
    guard code == 240 else { throw MailError.server(line) }
  }
}

/// A news account: subscribed groups appear as folders; read state is kept locally.
public actor NNTPBackend: MailBackend {
  public let account: MailAccount
  public nonisolated let accountID: UUID
  public nonisolated let capabilities = BackendCapabilities(
    canMoveAndDelete: false, canManageFolders: false, canAppend: false, canSearchServer: false)
  private let cache: MailCache
  private var client: NNTPClient?
  private let lock = AsyncLock()
  private var stateURL: URL { LocalBackend.storageRoot(for: accountID).appending(path: "newsrc.json") }

  private struct NewsState: Codable {
    var subscribed: [String] = []
    var flags: [String: [UInt32: Set<String>]] = [:]
  }

  public init(account: MailAccount, cache: MailCache) {
    self.account = account
    self.accountID = account.id
    self.cache = cache
  }

  private func loadState() -> NewsState {
    (try? JSONDecoder().decode(NewsState.self, from: Data(contentsOf: stateURL))) ?? NewsState()
  }

  private func saveState(_ state: NewsState) {
    try? FileManager.default.createDirectory(
      at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
  }

  private func connected() async throws -> NNTPClient {
    if let client { return client }
    let credential: Credential? =
      account.incoming.username.isEmpty
      ? nil : try await Credentials.resolve(account.incoming, key: account.incomingKeychainKey)
    let client = NNTPClient(server: account.incoming, credential: credential)
    self.client = client
    return client
  }

  private func perform<T: Sendable>(_ body: (NNTPClient) async throws -> T) async throws -> T {
    await lock.acquire()
    do {
      let result: T
      do {
        result = try await body(try await connected())
      } catch let error as MailError where error.isConnectionLoss {
        await client?.close()
        client = nil
        result = try await body(try await connected())
      }
      await lock.release()
      return result
    } catch {
      await lock.release()
      throw error
    }
  }

  public var subscribedGroups: [String] { loadState().subscribed }

  public func availableGroups(matching pattern: String) async throws -> [NewsgroupInfo] {
    try await perform { try await $0.listGroups(matching: pattern.isEmpty ? "*" : pattern) }
  }

  public func updateSubscription(_ group: String, _ subscribed: Bool) {
    var state = loadState()
    state.subscribed.removeAll { $0 == group }
    if subscribed {
      state.subscribed.append(group)
      state.subscribed.sort()
    }
    saveState(state)
  }

  private func folders() -> [RemoteFolder] {
    let state = loadState()
    return state.subscribed.map { name in
      var folder = RemoteFolder(path: name, delimiter: nil, attributes: [], role: .normal)
      if let snapshot = cache.snapshot(account: accountID, path: name) {
        let flags = state.flags[name] ?? [:]
        folder.unseen = snapshot.messages.filter { !(flags[$0.uid]?.contains(MessageFlag.seen) ?? false) }.count
        folder.total = snapshot.messages.count
      }
      return folder
    }
  }

  public func cachedFolders() -> [RemoteFolder] { folders() }
  public func refreshFolders() async throws -> [RemoteFolder] { folders() }

  private func applyFlags(_ messages: [MessageSummary], group: String) -> [MessageSummary] {
    let flags = loadState().flags[group] ?? [:]
    return messages.map { message in
      var message = message
      message.flags = flags[message.uid] ?? []
      return message
    }.sorted { $0.date > $1.date }
  }

  public func cachedMessages(in path: String) -> [MessageSummary] {
    applyFlags(cache.snapshot(account: accountID, path: path)?.messages ?? [], group: path)
  }

  public func sync(path: String, limit: Int) async throws -> SyncResult {
    let cache = cache
    let accountID = accountID
    let messages = try await perform { client -> [MessageSummary] in
      let info = try await client.group(path)
      var known = cache.snapshot(account: accountID, path: path)?.messages ?? []
      let highestKnown = Int(known.map(\.uid).max() ?? 0)
      let start = max(info.low, info.high - limit + 1, highestKnown + 1)
      if start <= info.high {
        known += try await client.overview(start...info.high)
      }
      known = Array(known.sorted { $0.uid > $1.uid }.prefix(limit))
      cache.saveSnapshot(FolderSnapshot(uidValidity: 1, messages: known), account: accountID, path: path)
      return known
    }
    return SyncResult(messages: applyFlags(messages, group: path), newMessages: [])
  }

  public func message(uid: UInt32, in path: String) async throws -> Data {
    if let cached = cache.message(account: accountID, path: path, uid: uid) { return cached }
    let data = try await perform { try await $0.article(uid, in: path) }
    cache.saveMessage(data, account: accountID, path: path, uid: uid)
    return data
  }

  public func setFlags(_ flags: [String], on: Bool, uids: [UInt32], in path: String) async throws {
    var state = loadState()
    var groupFlags = state.flags[path] ?? [:]
    for uid in uids {
      var current = groupFlags[uid] ?? []
      for flag in flags {
        if on { current.insert(flag) } else { current.remove(flag) }
      }
      groupFlags[uid] = current
    }
    state.flags[path] = groupFlags
    saveState(state)
  }

  public func move(uids: [UInt32], from source: String, to destination: String) async throws -> [UInt32: UInt32] {
    throw MailError.unsupported("Moving news articles")
  }
  public func copy(uids: [UInt32], from source: String, to destination: String) async throws -> [UInt32: UInt32] {
    throw MailError.unsupported("Copying news articles")
  }
  public func delete(uids: [UInt32], in path: String) async throws {
    try await setFlags([MessageFlag.seen], on: true, uids: uids, in: path)
  }
  public func emptyFolder(_ path: String) async throws {}
  public func append(_ message: Data, to path: String, flags: [String]) async throws {
    throw MailError.unsupported("Saving messages to a newsgroup")
  }
  public func search(_ query: SearchQuery, in path: String, limit: Int) async throws -> [MessageSummary] {
    Array(cachedMessages(in: path).filter { query.matches($0) }.prefix(limit))
  }
  public func findMessage(messageID: String, in path: String) async throws -> [UInt32] { [] }
  public func createFolder(_ name: String, parent: String?) async throws -> String {
    updateSubscription(name, true)
    return name
  }
  public func setSubscribed(_ path: String, _ subscribed: Bool) async throws {
    updateSubscription(path, subscribed)
  }
  public func renameFolder(_ path: String, to name: String) async throws {
    throw MailError.unsupported("Renaming newsgroups")
  }
  public func deleteFolder(_ path: String) async throws {
    updateSubscription(path, false)
    cache.clearFolder(account: accountID, path: path)
  }
  public func disconnect() async {
    await client?.close()
    client = nil
  }
}
