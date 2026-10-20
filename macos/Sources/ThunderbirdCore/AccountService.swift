/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation

/// Owns one account's IMAP connection, running operations one at a time and keeping the cache current.
public actor AccountService {
  public let account: MailAccount
  private let cache: MailCache
  private var client: IMAPClient?
  private var isBusy = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  public init(account: MailAccount, cache: MailCache) {
    self.account = account
    self.cache = cache
  }

  private func acquire() async {
    if !isBusy {
      isBusy = true
      return
    }
    await withCheckedContinuation { waiters.append($0) }
  }

  private func release() {
    if waiters.isEmpty {
      isBusy = false
    } else {
      waiters.removeFirst().resume()
    }
  }

  private func connectedClient() async throws -> IMAPClient {
    if let client, await client.isConnected {
      return client
    }
    guard let password = Keychain.password(for: account.incomingKeychainKey) else {
      throw MailError.missingPassword(account.incoming.host)
    }
    let client = IMAPClient(server: account.incoming, password: password)
    try await client.connect()
    self.client = client
    return client
  }

  /// Runs `operation` exclusively, reconnecting once if the connection had dropped.
  private func perform<T: Sendable>(_ operation: (IMAPClient) async throws -> T) async throws -> T {
    await acquire()
    defer { release() }
    do {
      return try await operation(try await connectedClient())
    } catch let error as MailError where error.isConnectionLoss {
      client = nil
      return try await operation(try await connectedClient())
    }
  }

  public func disconnect() async {
    await acquire()
    defer { release() }
    await client?.disconnect()
    client = nil
  }

  public static func testConnection(server: ServerConfig, password: String) async throws {
    let client = IMAPClient(server: server, password: password)
    try await client.connect()
    _ = try await client.listFolders()
    await client.disconnect()
  }

  // MARK: - Folders

  public func cachedFolders() -> [RemoteFolder] {
    cache.folders(account: account.id) ?? []
  }

  public func refreshFolders() async throws -> [RemoteFolder] {
    let folders = try await perform { try await $0.listFolders() }
    cache.saveFolders(folders, account: account.id)
    return folders
  }

  // MARK: - Messages

  public func cachedMessages(in path: String) -> [MessageSummary] {
    cache.snapshot(account: account.id, path: path)?.messages ?? []
  }

  /// Brings the cached summaries for the newest `limit` messages in a folder up to date.
  public func sync(path: String, limit: Int) async throws -> [MessageSummary] {
    let accountID = account.id
    let cache = cache
    return try await perform { client in
      let mailbox = try await client.select(path)
      var snapshot = cache.snapshot(account: accountID, path: path)
      if snapshot?.uidValidity != mailbox.uidValidity {
        cache.clearFolder(account: accountID, path: path)
        snapshot = nil
      }
      let flags = try await client.fetchFlags(newest: limit, exists: mailbox.exists)
      var known = Dictionary(
        (snapshot?.messages ?? []).map { ($0.uid, $0) }, uniquingKeysWith: { first, _ in first })
      let removed = known.keys.filter { flags[$0] == nil }
      cache.removeMessages(account: accountID, path: path, uids: removed)
      let missing = flags.keys.filter { known[$0] == nil }
      for summary in try await client.fetchSummaries(uids: missing, in: path) {
        known[summary.uid] = summary
      }
      let messages = flags.compactMap { uid, flags -> MessageSummary? in
        guard var summary = known[uid] else { return nil }
        summary.flags = flags
        return summary
      }.sorted { $0.date > $1.date }
      cache.saveSnapshot(FolderSnapshot(uidValidity: mailbox.uidValidity, messages: messages), account: accountID, path: path)
      return messages
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

  public func setFlag(_ flag: String, on: Bool, uids: [UInt32], in path: String) async throws {
    try await perform { try await $0.store(flags: [flag], add: on, uids: uids, in: path) }
    if var snapshot = cache.snapshot(account: account.id, path: path) {
      let targets = Set(uids)
      for index in snapshot.messages.indices where targets.contains(snapshot.messages[index].uid) {
        if on {
          snapshot.messages[index].flags.insert(flag)
        } else {
          snapshot.messages[index].flags.remove(flag)
        }
      }
      cache.saveSnapshot(snapshot, account: account.id, path: path)
    }
  }

  public func move(uids: [UInt32], from source: String, to destination: String) async throws {
    try await perform { try await $0.move(uids: uids, from: source, to: destination) }
    dropFromCache(uids: uids, path: source)
  }

  public func delete(uids: [UInt32], in path: String) async throws {
    try await perform { try await $0.expunge(uids: uids, in: path) }
    dropFromCache(uids: uids, path: path)
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

  public func send(_ message: OutgoingMessage) async throws -> Data {
    let messageID = OutgoingMessage.makeMessageID(domainOf: account.email)
    let data = message.render(messageID: messageID)
    let smtp = SMTPClient(server: account.outgoing, password: Keychain.password(for: account.outgoingKeychainKey))
    try await smtp.send(data, from: account.email, to: message.allRecipients.map(\.email))
    return data
  }
}
