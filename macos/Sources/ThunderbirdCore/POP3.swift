/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation

public struct POP3Client: Sendable {
  private let server: ServerConfig
  private let credential: Credential

  public init(server: ServerConfig, credential: Credential) {
    self.server = server
    self.credential = credential
  }

  @discardableResult
  private func readStatus(_ connection: LineConnection) async throws -> String {
    let line = String(decoding: try await connection.readLine(), as: UTF8.self)
    guard line.hasPrefix("+") else {
      throw line.localizedCaseInsensitiveContains("auth") || line.localizedCaseInsensitiveContains("pass")
        ? MailError.authenticationFailed(line) : MailError.server(line)
    }
    return line
  }

  @discardableResult
  private func command(_ text: String, _ connection: LineConnection) async throws -> String {
    try await connection.write("\(text)\r\n")
    return try await readStatus(connection)
  }

  private func readMultiline(_ connection: LineConnection) async throws -> Data {
    var output = Data()
    while true {
      var line = try await connection.readLine()
      if line == Data(".".utf8) { return output }
      if line.first == UInt8(ascii: ".") {
        line.removeFirst()
      }
      output.append(line)
      output.append(crlf)
    }
  }

  private func open() async throws -> LineConnection {
    let connection = LineConnection(host: server.host, port: server.port, implicitTLS: server.security == .tls)
    do {
      try await readStatus(connection)
      if server.security == .startTLS {
        try await command("STLS", connection)
        await connection.startTLS()
      }
      switch credential {
      case .oauth:
        try await command("AUTH XOAUTH2 \(credential.xoauth2(user: server.username) ?? "")", connection)
      case .password(let password):
        try await command("USER \(server.username)", connection)
        try await command("PASS \(password)", connection)
      }
      return connection
    } catch {
      await connection.close()
      throw error
    }
  }

  public func verify() async throws {
    let connection = try await open()
    _ = try? await command("QUIT", connection)
    await connection.close()
  }

  /// Downloads messages whose UIDL isn't in `seen`, optionally deleting them from the server.
  /// Already seen messages listed in `expire` are deleted from the server too.
  public func download(
    skipping seen: Set<String>, deleteFromServer: Bool, expire: Set<String> = [], deliver: (Data) async -> Void
  ) async throws -> Set<String> {
    let connection = try await open()
    defer { Task { await connection.close() } }
    try await command("UIDL", connection)
    let listing = String(decoding: try await readMultiline(connection), as: UTF8.self)
    var current = Set<String>()
    for line in listing.split(separator: "\r\n") {
      let parts = line.split(separator: " ")
      guard parts.count == 2 else { continue }
      let uidl = String(parts[1])
      current.insert(uidl)
      guard !seen.contains(uidl) else {
        if deleteFromServer || expire.contains(uidl) { try await command("DELE \(parts[0])", connection) }
        continue
      }
      try await command("RETR \(parts[0])", connection)
      await deliver(try await readMultiline(connection))
      if deleteFromServer {
        try await command("DELE \(parts[0])", connection)
      }
    }
    try await command("QUIT", connection)
    return current
  }
}

/// A POP3 account: mail is downloaded into a local store and read from there.
public actor POP3Backend: MailBackend {
  public let account: MailAccount
  public nonisolated let accountID: UUID
  public nonisolated let capabilities = BackendCapabilities(
    canMoveAndDelete: true, canManageFolders: true, canAppend: true, canSearchServer: false)
  public let local: LocalBackend
  private var stateURL: URL { LocalBackend.storageRoot(for: accountID).appending(path: "pop3-seen.json") }
  private var datesURL: URL { LocalBackend.storageRoot(for: accountID).appending(path: "pop3-dates.json") }

  public init(account: MailAccount) {
    self.account = account
    self.accountID = account.id
    self.local = LocalBackend(
      accountID: account.id, root: LocalBackend.storageRoot(for: account.id), defaultFolders: LocalBackend.pop3Defaults)
  }

  public func cachedFolders() async -> [RemoteFolder] { await local.cachedFolders() }
  public func refreshFolders() async throws -> [RemoteFolder] { try await local.refreshFolders() }
  public func cachedMessages(in path: String) async -> [MessageSummary] { await local.cachedMessages(in: path) }

  public func sync(path: String, limit: Int) async throws -> SyncResult {
    var newMessages: [MessageSummary] = []
    if path == "Inbox" {
      let seen = (try? JSONDecoder().decode(Set<String>.self, from: Data(contentsOf: stateURL))) ?? []
      let credential = try await Credentials.resolve(account.incoming, key: account.incomingKeychainKey)
      let client = POP3Client(server: account.incoming, credential: credential)
      let local = local
      var firstSeen = (try? JSONDecoder().decode([String: Date].self, from: Data(contentsOf: datesURL))) ?? [:]
      var expire = Set<String>()
      if account.leaveMessagesOnServer, let days = account.options.popLeaveDays, days > 0 {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        expire = Set(firstSeen.filter { $0.value < cutoff }.keys)
      }
      let current = try await client.download(
        skipping: seen, deleteFromServer: !account.leaveMessagesOnServer, expire: expire
      ) { data in
        newMessages.append(await local.deliver(data, to: "Inbox", flags: []))
      }
      let remaining = current.subtracting(expire)
      let remembered = account.leaveMessagesOnServer ? remaining : seen.union(current)
      try? JSONEncoder().encode(remembered).write(to: stateURL, options: .atomic)
      let now = Date()
      firstSeen = firstSeen.filter { remaining.contains($0.key) }
      for uidl in remaining where firstSeen[uidl] == nil { firstSeen[uidl] = now }
      try? JSONEncoder().encode(firstSeen).write(to: datesURL, options: .atomic)
    }
    var result = try await local.sync(path: path, limit: limit)
    result.newMessages = newMessages
    return result
  }

  public func message(uid: UInt32, in path: String) async throws -> Data { try await local.message(uid: uid, in: path) }
  public func setFlags(_ flags: [String], on: Bool, uids: [UInt32], in path: String) async throws {
    try await local.setFlags(flags, on: on, uids: uids, in: path)
  }
  public func move(uids: [UInt32], from source: String, to destination: String) async throws -> [UInt32: UInt32] {
    try await local.move(uids: uids, from: source, to: destination)
  }
  public func copy(uids: [UInt32], from source: String, to destination: String) async throws -> [UInt32: UInt32] {
    try await local.copy(uids: uids, from: source, to: destination)
  }
  public func delete(uids: [UInt32], in path: String) async throws { try await local.delete(uids: uids, in: path) }
  public func emptyFolder(_ path: String) async throws { try await local.emptyFolder(path) }
  public func append(_ message: Data, to path: String, flags: [String]) async throws {
    try await local.append(message, to: path, flags: flags)
  }
  public func search(_ query: SearchQuery, in path: String, limit: Int) async throws -> [MessageSummary] {
    try await local.search(query, in: path, limit: limit)
  }
  public func findMessage(messageID: String, in path: String) async throws -> [UInt32] {
    try await local.findMessage(messageID: messageID, in: path)
  }
  public func createFolder(_ name: String, parent: String?) async throws -> String {
    try await local.createFolder(name, parent: parent)
  }
  public func renameFolder(_ path: String, to name: String) async throws { try await local.renameFolder(path, to: name) }
  public func deleteFolder(_ path: String) async throws { try await local.deleteFolder(path) }
  public func disconnect() async {}
}
