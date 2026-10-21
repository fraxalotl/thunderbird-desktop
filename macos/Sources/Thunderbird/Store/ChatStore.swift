/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import Observation
import ThunderbirdCore
import UserNotifications

struct ConversationKey: Hashable, Codable {
  var accountID: UUID
  var conversationID: String
}

enum ChatStatus: Equatable {
  case offline, connecting, online
  case failed(String)

  var label: String {
    switch self {
    case .offline: "Offline"
    case .connecting: "Connecting…"
    case .online: "Online"
    case .failed(let message): message
    }
  }
}

@MainActor
@Observable
final class ChatStore {
  private(set) var accounts: [ChatAccount] = []
  private(set) var status: [UUID: ChatStatus] = [:]
  private(set) var ownNames: [UUID: String] = [:]
  private(set) var conversations: [UUID: [ChatConversation]] = [:]
  private(set) var messages: [ConversationKey: [ChatMessage]] = [:]
  private(set) var unread: [ConversationKey: Int] = [:]
  var selection: ConversationKey? {
    didSet {
      if let selection {
        unread[selection] = nil
        loadLog(selection)
      }
    }
  }

  var pendingAccountSetup = false
  var pendingAddContact = false
  var pendingJoin = false
  var isAway = false

  @ObservationIgnored private var connections: [UUID: any ChatConnection] = [:]
  @ObservationIgnored private var listeners: [UUID: Task<Void, Never>] = [:]
  private static let accountsKey = "chatAccounts"
  private static let logLimit = 1000

  init() {
    if let data = UserDefaults.standard.data(forKey: Self.accountsKey),
      let stored = try? JSONDecoder().decode([ChatAccount].self, from: data)
    {
      accounts = stored
    }
    for account in accounts where account.connectOnStartup {
      Task { await connect(account.id) }
    }
  }

  var totalUnread: Int { unread.values.reduce(0, +) }

  func account(_ id: UUID?) -> ChatAccount? { accounts.first { $0.id == id } }

  func conversation(_ key: ConversationKey) -> ChatConversation? {
    conversations[key.accountID]?.first { $0.id == key.conversationID }
  }

  private func persist() {
    UserDefaults.standard.set(try? JSONEncoder().encode(accounts), forKey: Self.accountsKey)
  }

  func add(_ account: ChatAccount, password: String) throws {
    if !password.isEmpty {
      try Keychain.setPassword(password, for: account.keychainKey)
    }
    accounts.append(account)
    persist()
    Task { await connect(account.id) }
  }

  func update(_ account: ChatAccount, password: String?) throws {
    guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
    if let password, !password.isEmpty {
      try Keychain.setPassword(password, for: account.keychainKey)
    }
    accounts[index] = account
    persist()
  }

  func remove(_ id: UUID) {
    Task { await disconnect(id) }
    if let account = account(id) {
      Keychain.deletePassword(for: account.keychainKey)
    }
    accounts.removeAll { $0.id == id }
    conversations[id] = nil
    try? FileManager.default.removeItem(at: logDirectory(id))
    persist()
  }

  // MARK: - Connections

  func connect(_ id: UUID) async {
    guard let account = account(id), connections[id] == nil else { return }
    status[id] = .connecting
    let connection = ChatClients.make(account, secret: Keychain.password(for: account.keychainKey) ?? "")
    connections[id] = connection
    listeners[id] = Task { [weak self] in
      for await event in connection.events {
        self?.handle(event, accountID: id)
      }
    }
    do {
      try await connection.connect()
    } catch {
      status[id] = .failed(error.localizedDescription)
      connections[id] = nil
      listeners.removeValue(forKey: id)?.cancel()
    }
  }

  func disconnect(_ id: UUID) async {
    await connections.removeValue(forKey: id)?.disconnect()
    listeners.removeValue(forKey: id)?.cancel()
    status[id] = .offline
  }

  private func handle(_ event: ChatEvent, accountID: UUID) {
    switch event {
    case .connected(let name):
      status[accountID] = .online
      ownNames[accountID] = name
    case .disconnected(let reason):
      status[accountID] = reason.map { .failed($0) } ?? .offline
      connections[accountID] = nil
    case .conversation(let conversation):
      var list = conversations[accountID] ?? []
      if let index = list.firstIndex(where: { $0.id == conversation.id }) {
        let existing = list[index]
        list[index] = conversation
        list[index].topic = conversation.topic ?? existing.topic
        if conversation.participants.isEmpty { list[index].participants = existing.participants }
      } else {
        list.append(conversation)
        loadLog(ConversationKey(accountID: accountID, conversationID: conversation.id))
      }
      conversations[accountID] = list.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    case .conversationRemoved(let id):
      conversations[accountID]?.removeAll { $0.id == id }
      if selection == ConversationKey(accountID: accountID, conversationID: id) { selection = nil }
    case .message(let message):
      let key = ConversationKey(accountID: accountID, conversationID: message.conversationID)
      var log = messages[key] ?? []
      guard !log.contains(where: { $0.id == message.id }) else { return }
      log.append(message)
      if log.count > Self.logLimit { log.removeFirst(log.count - Self.logLimit) }
      messages[key] = log
      saveLog(key)
      if selection != key && !message.isOutgoing && message.kind != .system {
        unread[key, default: 0] += 1
        let isMention = ownNames[accountID].map { message.text.localizedCaseInsensitiveContains($0) } ?? false
        let isDirect = conversation(key).map { !$0.isGroup } ?? false
        if isMention || isDirect {
          notify(message, in: conversation(key)?.title ?? message.conversationID)
        }
      }
    case .participants(let id, let names):
      if let index = conversations[accountID]?.firstIndex(where: { $0.id == id }) {
        conversations[accountID]?[index].participants = names.sorted { $0.lowercased() < $1.lowercased() }
      }
    case .topic(let id, let topic):
      if let index = conversations[accountID]?.firstIndex(where: { $0.id == id }) {
        conversations[accountID]?[index].topic = topic
      }
    }
  }

  private func notify(_ message: ChatMessage, in title: String) {
    let content = UNMutableNotificationContent()
    content.title = message.sender.isEmpty ? title : "\(message.sender) in \(title)"
    content.body = message.text
    content.sound = .default
    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
  }

  func send(_ text: String, to key: ConversationKey) async {
    guard let connection = connections[key.accountID] else {
      handle(.message(ChatMessage(conversationID: key.conversationID, sender: "", text: "Not connected.", kind: .system)), accountID: key.accountID)
      return
    }
    do {
      try await connection.send(text, to: key.conversationID)
    } catch {
      handle(
        .message(ChatMessage(conversationID: key.conversationID, sender: "", text: error.localizedDescription, kind: .system)),
        accountID: key.accountID)
    }
  }

  /// Tools › Chat Status › Available / Offline.
  func setAllOnline(_ online: Bool) {
    isAway = false
    for account in accounts {
      Task {
        if online { await connect(account.id) } else { await disconnect(account.id) }
      }
    }
  }

  /// Tools › Chat Status › Unavailable: tells contacts you're away where the protocol supports it.
  func setAway(_ away: Bool) {
    isAway = away
    for account in accounts {
      Task { try? await connections[account.id]?.setAway(away) }
    }
  }

  /// File › New › Chat Contact…: opens a direct conversation (and adds an XMPP roster entry).
  func addContact(_ name: String, accountID: UUID) async {
    guard let account = account(accountID) else { return }
    _ = account
    try? await connections[accountID]?.addContact(name)
  }

  func join(_ name: String, accountID: UUID) async {
    try? await connections[accountID]?.join(name)
  }

  func acceptInvitation(_ key: ConversationKey) async {
    try? await connections[key.accountID]?.join(key.conversationID)
  }

  func leave(_ key: ConversationKey) async {
    try? await connections[key.accountID]?.leave(key.conversationID)
  }

  // MARK: - Logs

  private func logDirectory(_ accountID: UUID) -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appending(path: "Thunderbird for macOS/Chat Logs/\(accountID.uuidString)", directoryHint: .isDirectory)
  }

  private func logURL(_ key: ConversationKey) -> URL {
    let name = Data(key.conversationID.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
    return logDirectory(key.accountID).appending(path: "\(name).json")
  }

  private func loadLog(_ key: ConversationKey) {
    guard messages[key] == nil, let data = try? Data(contentsOf: logURL(key)),
      let log = try? JSONDecoder().decode([ChatMessage].self, from: data)
    else { return }
    messages[key] = log
  }

  private func saveLog(_ key: ConversationKey) {
    guard let log = messages[key] else { return }
    try? FileManager.default.createDirectory(at: logDirectory(key.accountID), withIntermediateDirectories: true)
    try? JSONEncoder().encode(log).write(to: logURL(key), options: .atomic)
  }
}
