/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation

public struct SearchQuery: Codable, Sendable, Hashable {
  public enum Field: String, Codable, Sendable, CaseIterable, Hashable {
    case all, headers, subject, from, recipients, body

    public var label: String {
      switch self {
      case .all: "Entire Message"
      case .headers: "Subject, From or To"
      case .subject: "Subject"
      case .from: "From"
      case .recipients: "To or Cc"
      case .body: "Body"
      }
    }
  }

  public var text: String
  public var field: Field
  public var unreadOnly: Bool
  public var flaggedOnly: Bool
  public var since: Date?

  public init(text: String, field: Field = .all, unreadOnly: Bool = false, flaggedOnly: Bool = false, since: Date? = nil) {
    self.text = text
    self.field = field
    self.unreadOnly = unreadOnly
    self.flaggedOnly = flaggedOnly
    self.since = since
  }

  /// Local evaluation, used for cached summaries and local stores.
  public func matches(_ summary: MessageSummary, body: String? = nil) -> Bool {
    if unreadOnly && summary.isRead { return false }
    if flaggedOnly && !summary.isFlagged { return false }
    if let since, summary.date < since { return false }
    let needle = text.trimmingCharacters(in: .whitespaces).lowercased()
    guard !needle.isEmpty else { return true }
    func addresses(_ list: [MailAddress]) -> Bool {
      list.contains { $0.email.lowercased().contains(needle) || ($0.name?.lowercased().contains(needle) ?? false) }
    }
    let subject = summary.subject.lowercased().contains(needle)
    switch field {
    case .subject: return subject
    case .from: return addresses(summary.from)
    case .recipients: return addresses(summary.to + summary.cc)
    case .headers: return subject || addresses(summary.from + summary.to + summary.cc)
    case .body: return body?.lowercased().contains(needle) ?? false
    case .all:
      return subject || addresses(summary.from + summary.to + summary.cc)
        || (body?.lowercased().contains(needle) ?? false)
    }
  }
}

public struct SyncResult: Sendable {
  public var messages: [MessageSummary]
  /// Unread messages that appeared since the previous sync (empty on a first sync).
  public var newMessages: [MessageSummary]

  public init(messages: [MessageSummary], newMessages: [MessageSummary]) {
    self.messages = messages
    self.newMessages = newMessages
  }
}

public struct BackendCapabilities: Sendable {
  public var canMoveAndDelete: Bool
  public var canManageFolders: Bool
  public var canAppend: Bool
  public var canSearchServer: Bool
}

/// One account's message store: IMAP, POP3 (into local storage), Local Folders or NNTP.
public protocol MailBackend: Sendable {
  var accountID: UUID { get }
  var capabilities: BackendCapabilities { get }

  func cachedFolders() async -> [RemoteFolder]
  func refreshFolders() async throws -> [RemoteFolder]
  func cachedMessages(in path: String) async -> [MessageSummary]
  func sync(path: String, limit: Int) async throws -> SyncResult
  func message(uid: UInt32, in path: String) async throws -> Data
  func setFlags(_ flags: [String], on: Bool, uids: [UInt32], in path: String) async throws
  func move(uids: [UInt32], from source: String, to destination: String) async throws
  func copy(uids: [UInt32], from source: String, to destination: String) async throws
  func delete(uids: [UInt32], in path: String) async throws
  func emptyFolder(_ path: String) async throws
  func append(_ message: Data, to path: String, flags: [String]) async throws
  func search(_ query: SearchQuery, in path: String, limit: Int) async throws -> [MessageSummary]
  func findMessage(messageID: String, in path: String) async throws -> [UInt32]
  func createFolder(_ name: String, parent: String?) async throws -> String
  func renameFolder(_ path: String, to name: String) async throws
  func deleteFolder(_ path: String) async throws
  func waitForNewMail() async throws -> Bool
  func disconnect() async
}

extension MailBackend {
  public func waitForNewMail() async throws -> Bool { false }
}

/// Serialises async operations on an actor, which otherwise interleave at each suspension point.
actor AsyncLock {
  private var isLocked = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func acquire() async {
    if !isLocked {
      isLocked = true
      return
    }
    await withCheckedContinuation { waiters.append($0) }
  }

  func release() {
    if waiters.isEmpty {
      isLocked = false
    } else {
      waiters.removeFirst().resume()
    }
  }
}
