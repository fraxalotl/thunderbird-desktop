/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation

/// Owns one IMAP account's connections, running operations one at a time and keeping the cache current.
public actor IMAPBackend: MailBackend {
  public let account: MailAccount
  public nonisolated let accountID: UUID
  public nonisolated let capabilities = BackendCapabilities(
    canMoveAndDelete: true, canManageFolders: true, canAppend: true, canSearchServer: true)
  private let cache: MailCache
  private var client: IMAPClient?
  private var idleClient: IMAPClient?
  private let lock = AsyncLock()

  public init(account: MailAccount, cache: MailCache) {
    self.account = account
    self.accountID = account.id
    self.cache = cache
  }

  private func connectedClient() async throws -> IMAPClient {
    if let client, await client.isConnected {
      return client
    }
    let credential = try await Credentials.resolve(account.incoming, key: account.incomingKeychainKey)
    let client = IMAPClient(server: account.incoming, credential: credential)
    try await client.connect()
    self.client = client
    return client
  }

  /// Runs `operation` exclusively, reconnecting once if the connection had dropped.
  private func perform<T: Sendable>(_ operation: (IMAPClient) async throws -> T) async throws -> T {
    await lock.acquire()
    do {
      let result: T
      do {
        result = try await operation(try await connectedClient())
      } catch let error as MailError where error.isConnectionLoss {
        client = nil
        result = try await operation(try await connectedClient())
      }
      await lock.release()
      return result
    } catch {
      await lock.release()
      throw error
    }
  }

  public func disconnect() async {
    await client?.disconnect()
    await idleClient?.disconnect()
    client = nil
    idleClient = nil
  }

  public static func testConnection(server: ServerConfig, credential: Credential) async throws {
    let client = IMAPClient(server: server, credential: credential)
    try await client.connect()
    _ = try await client.listFolders()
    await client.disconnect()
  }

  // MARK: - Folders

  public func cachedFolders() -> [RemoteFolder] {
    cache.folders(account: account.id) ?? []
  }

  /// Lists folders, showing only subscribed ones (plus the inbox) when the server tracks
  /// subscriptions, as Thunderbird does by default.
  public func refreshFolders() async throws -> [RemoteFolder] {
    let folders = try await perform { client -> [RemoteFolder] in
      let all = try await client.listFolders()
      let subscribed = (try? await client.subscribedPaths()) ?? []
      guard !subscribed.isEmpty else { return all }
      return all.filter { subscribed.contains($0.path) || $0.role == .inbox || !$0.isSelectable }
    }
    cache.saveFolders(folders, account: account.id)
    return folders
  }

  public func subscriptions() async throws -> [(path: String, subscribed: Bool)] {
    try await perform { client in
      let all = try await client.listFolders().filter(\.isSelectable)
      let subscribed = try await client.subscribedPaths()
      return all.map { ($0.path, subscribed.isEmpty || subscribed.contains($0.path)) }
    }
  }

  public func setSubscribed(_ path: String, _ subscribed: Bool) async throws {
    try await perform { try await $0.setSubscribed(path, subscribed) }
  }

  public func compact(_ path: String) async throws {
    try await perform { try await $0.expungeFolder(path) }
  }

  public func forgetCache(_ path: String) {
    cache.clearFolder(account: account.id, path: path)
  }

  private func delimiter() -> String {
    cachedFolders().compactMap(\.delimiter).first ?? "/"
  }

  public func createFolder(_ name: String, parent: String?) async throws -> String {
    let encoded = ModifiedUTF7.encode(name)
    let path = parent.map { "\($0)\(delimiter())\(encoded)" } ?? encoded
    try await perform { try await $0.create(path) }
    return path
  }

  public func renameFolder(_ path: String, to name: String) async throws {
    let delimiter = delimiter()
    var components = path.components(separatedBy: delimiter)
    components[components.count - 1] = ModifiedUTF7.encode(name)
    let newPath = components.joined(separator: delimiter)
    try await perform { try await $0.rename(path, to: newPath) }
    cache.clearFolder(account: account.id, path: path)
  }

  public func deleteFolder(_ path: String) async throws {
    try await perform { try await $0.delete(folder: path) }
    cache.clearFolder(account: account.id, path: path)
  }

  // MARK: - Messages

  public func cachedMessages(in path: String) -> [MessageSummary] {
    cache.snapshot(account: account.id, path: path)?.messages ?? []
  }

  /// Brings the cached summaries for the newest `limit` messages in a folder up to date.
  public func sync(path: String, limit: Int) async throws -> SyncResult {
    let accountID = account.id
    let cache = cache
    return try await perform { client in
      let mailbox = try await client.select(path)
      var snapshot = cache.snapshot(account: accountID, path: path)
      if snapshot?.uidValidity != mailbox.uidValidity {
        cache.clearFolder(account: accountID, path: path)
        snapshot = nil
      }
      let isFirstSync = snapshot == nil
      let flags = try await client.fetchFlags(newest: limit, exists: mailbox.exists)
      var known = Dictionary(
        (snapshot?.messages ?? []).map { ($0.uid, $0) }, uniquingKeysWith: { first, _ in first })
      let highestKnown = known.keys.max() ?? 0
      let removed = known.keys.filter { flags[$0] == nil }
      cache.removeMessages(account: accountID, path: path, uids: removed)
      let missing = flags.keys.filter { known[$0] == nil }
      var fetched: [MessageSummary] = []
      for summary in try await client.fetchSummaries(uids: missing, in: path) {
        known[summary.uid] = summary
        fetched.append(summary)
      }
      let messages = flags.compactMap { uid, flags -> MessageSummary? in
        guard var summary = known[uid] else { return nil }
        summary.flags = flags
        return summary
      }.sorted { $0.date > $1.date }
      cache.saveSnapshot(FolderSnapshot(uidValidity: mailbox.uidValidity, messages: messages), account: accountID, path: path)
      let new = isFirstSync ? [] : fetched.filter { $0.uid > highestKnown && !(flags[$0.uid]?.contains(MessageFlag.seen) ?? false) }
      return SyncResult(messages: messages, newMessages: new)
    }
  }

  public func message(uid: UInt32, in path: String) async throws -> Data {
    if let cached = cache.message(account: account.id, path: path, uid: uid) {
      return cached
    }
    let data = try await perform { try await $0.fetchMessage(uid: uid, in: path) }
    cache.saveMessage(data, account: account.id, path: path, uid: uid)
    return data
  }

  public func setFlags(_ flags: [String], on: Bool, uids: [UInt32], in path: String) async throws {
    try await perform { try await $0.store(flags: flags, add: on, uids: uids, in: path) }
    if var snapshot = cache.snapshot(account: account.id, path: path) {
      let targets = Set(uids)
      for index in snapshot.messages.indices where targets.contains(snapshot.messages[index].uid) {
        for flag in flags {
          if on {
            snapshot.messages[index].flags.insert(flag)
          } else {
            snapshot.messages[index].flags.remove(flag)
          }
        }
      }
      cache.saveSnapshot(snapshot, account: account.id, path: path)
    }
  }

  public func move(uids: [UInt32], from source: String, to destination: String) async throws -> [UInt32: UInt32] {
    let mapping = try await perform { try await $0.move(uids: uids, from: source, to: destination) }
    dropFromCache(uids: uids, path: source)
    return mapping
  }

  public func copy(uids: [UInt32], from source: String, to destination: String) async throws -> [UInt32: UInt32] {
    try await perform { try await $0.copy(uids: uids, from: source, to: destination) }
  }

  public func delete(uids: [UInt32], in path: String) async throws {
    try await perform { try await $0.expunge(uids: uids, in: path) }
    dropFromCache(uids: uids, path: path)
  }

  public func emptyFolder(_ path: String) async throws {
    try await perform { try await $0.expungeAll(in: path) }
    cache.clearFolder(account: account.id, path: path)
  }

  private func dropFromCache(uids: [UInt32], path: String) {
    cache.removeMessages(account: account.id, path: path, uids: uids)
    if var snapshot = cache.snapshot(account: account.id, path: path) {
      let targets = Set(uids)
      snapshot.messages.removeAll { targets.contains($0.uid) }
      cache.saveSnapshot(snapshot, account: account.id, path: path)
    }
  }

  public func append(_ message: Data, to path: String, flags: [String]) async throws {
    try await perform { try await $0.append(message, to: path, flags: flags) }
  }

  public func search(_ query: SearchQuery, in path: String, limit: Int) async throws -> [MessageSummary] {
    let accountID = account.id
    let cache = cache
    return try await perform { client in
      let uids = Array(try await client.search(query, in: path).sorted().suffix(limit))
      let cached = Dictionary(
        (cache.snapshot(account: accountID, path: path)?.messages ?? []).map { ($0.uid, $0) },
        uniquingKeysWith: { first, _ in first })
      let missing = uids.filter { cached[$0] == nil }
      var results = uids.compactMap { cached[$0] }
      results += try await client.fetchSummaries(uids: missing, in: path)
      return results.sorted { $0.date > $1.date }
    }
  }

  public func findMessage(messageID: String, in path: String) async throws -> [UInt32] {
    try await perform { try await $0.searchHeader("Message-ID", value: messageID, in: path) }
  }

  /// Holds a second connection in IDLE on the inbox; returns true when new mail may have arrived.
  public func waitForNewMail() async throws -> Bool {
    guard let inbox = cachedFolders().first(where: { $0.role == .inbox })?.path else {
      throw MailError.server("The folder list hasn't been downloaded yet.")
    }
    var needsConnection = true
    if let idleClient {
      needsConnection = !(await idleClient.isConnected)
    }
    if needsConnection {
      let credential = try await Credentials.resolve(account.incoming, key: account.incomingKeychainKey)
      let client = IMAPClient(server: account.incoming, credential: credential, timeout: 29 * 60)
      try await client.connect()
      idleClient = client
    }
    do {
      return try await idleClient!.idleUntilChange(in: inbox)
    } catch {
      await idleClient?.disconnect()
      idleClient = nil
      throw error
    }
  }
}

/// Sends mail for an identity, choosing SMTP or NNTP posting as appropriate.
public enum MailSender {
  public static func send(_ message: OutgoingMessage, account: MailAccount, requestDSN: Bool = false) async throws -> Data {
    let messageID = OutgoingMessage.makeMessageID(domainOf: message.from.email.isEmpty ? account.email : message.from.email)
    let data = try message.render(messageID: messageID)
    if account.kind == .nntp {
      let credential = try? await Credentials.resolve(account.incoming, key: account.incomingKeychainKey)
      try await NNTPClient(server: account.incoming, credential: credential).post(data)
      return data
    }
    let credential: Credential? =
      account.outgoing.username.isEmpty
      ? nil : try await Credentials.resolve(account.outgoing, key: account.outgoingKeychainKey)
    if !message.allRecipients.isEmpty {
      try await SMTPClient(server: account.outgoing, credential: credential)
        .send(data, from: message.from.email, to: message.allRecipients.map(\.email), requestDSN: requestDSN)
    }
    if !message.newsgroups.isEmpty {
      throw MailError.unsupported("Posting to newsgroups from a mail account")
    }
    return data
  }
}
