/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import AppKit
import CoreTransferable
import Foundation
import Observation
import ThunderbirdCore
import UniformTypeIdentifiers
import UserNotifications

struct FolderSelection: Hashable, Codable {
  var accountID: UUID
  var path: String
}

enum MailboxSource: Hashable, Codable {
  case folder(FolderSelection)
  case unified(FolderRole)
  case savedSearch(UUID)
  case searchResults
}

struct MessageItem: Identifiable, Hashable {
  var reference: MessageReference
  var summary: MessageSummary
  var id: MessageReference { reference }
}

struct SidebarFolder: Identifiable, Hashable {
  var folder: RemoteFolder
  var depth: Int
  var id: String { folder.path }
}

struct SearchScope: Codable, Hashable {
  enum Kind: String, Codable, CaseIterable {
    case currentFolder, account, allInboxes, everything

    var label: String {
      switch self {
      case .currentFolder: "This folder"
      case .account: "All folders in this account"
      case .allInboxes: "All inboxes"
      case .everything: "All folders in all accounts"
      }
    }
  }

  var kind: Kind
  var folder: FolderSelection?
}

struct SavedSearch: Codable, Hashable, Identifiable {
  var id = UUID()
  var name: String
  var query: SearchQuery
  var scope: SearchScope
}

struct LoadedMessage {
  var reference: MessageReference
  var summary: MessageSummary
  var parsed: ParsedMessage
  var raw: Data
  var account: MailAccount
  var security: MessageSecurityStatus?
  var folderRole: FolderRole
}

enum ReaderState {
  case empty
  case multiple(Int)
  case loading
  case loaded(LoadedMessage)
  case failed(String)
}

struct PresentedError: Identifiable {
  let id = UUID()
  var title: String
  var message: String
}

struct MessageDragPayload: Codable, Transferable {
  var references: [MessageReference]

  static var transferRepresentation: some TransferRepresentation {
    CodableRepresentation(contentType: .thunderbirdMessages)
  }
}

extension UTType {
  static let thunderbirdMessages = UTType(exportedAs: "net.thunderbird.mac.messages")
}

enum Preferences {
  static let syncLimit = "syncLimit"
  static let checkInterval = "checkIntervalMinutes"
  static let allowRemoteContent = "allowRemoteContent"
  static let markReadOnOpen = "markReadOnOpen"
  static let threaded = "threadedView"
  static let junkFilter = "junkFilterEnabled"
  static let notifications = "newMailNotifications"
  static let showTodayPane = "showTodayPane"

  static func register() {
    UserDefaults.standard.register(defaults: [
      syncLimit: 250,
      checkInterval: 10,
      allowRemoteContent: false,
      markReadOnOpen: true,
      threaded: false,
      junkFilter: true,
      notifications: true,
      showTodayPane: false,
    ])
  }
}

@MainActor
@Observable
final class MailStore {
  private(set) var accounts: [MailAccount] = []
  private(set) var folders: [UUID: [RemoteFolder]] = [:]
  private(set) var items: [MessageItem] = []
  private(set) var reader: ReaderState = .empty
  private(set) var refreshing: Set<UUID> = []
  private(set) var activity: String?
  private(set) var accountErrors: [UUID: String] = [:]
  private(set) var savedSearches: [SavedSearch] = []
  var presentedError: PresentedError?

  var searchText = ""
  var filterUnread = false
  var filterStarred = false
  var filterAttachments = false
  var filterTag: String?
  var threaded = UserDefaults.standard.bool(forKey: Preferences.threaded) {
    didSet { UserDefaults.standard.set(threaded, forKey: Preferences.threaded) }
  }

  var source: MailboxSource? {
    didSet {
      if oldValue != source { sourceDidChange() }
    }
  }

  var selection: Set<MessageReference> = [] {
    didSet {
      if oldValue != selection { selectionDidChange() }
    }
  }

  private var remoteContentAllowed: Set<MessageReference> = []
  @ObservationIgnored private var backends: [UUID: any MailBackend] = [:]
  @ObservationIgnored private let cache = MailCache()
  @ObservationIgnored private var loadTask: Task<Void, Never>?
  @ObservationIgnored private var syncTask: Task<Void, Never>?
  @ObservationIgnored private var checkTask: Task<Void, Never>?
  @ObservationIgnored private var idleTasks: [UUID: Task<Void, Never>] = [:]
  @ObservationIgnored var onAddressesUsed: (([MailAddress]) -> Void)?

  private static let accountsKey = "accounts"
  private static let savedSearchesKey = "savedSearches"

  init() {
    Preferences.register()
    if let data = UserDefaults.standard.data(forKey: Self.accountsKey),
      let stored = try? JSONDecoder().decode([MailAccount].self, from: data)
    {
      accounts = stored
    }
    if !accounts.contains(where: { $0.kind == .local }) {
      accounts.append(.localFolders())
      persistAccounts()
    }
    if let data = UserDefaults.standard.data(forKey: Self.savedSearchesKey),
      let stored = try? JSONDecoder().decode([SavedSearch].self, from: data)
    {
      savedSearches = stored
    }
    for account in accounts {
      startBackend(for: account)
    }
    Task {
      for account in accounts {
        folders[account.id] = await backends[account.id]?.cachedFolders() ?? []
      }
      if let first = mailAccounts.first {
        source = .folder(FolderSelection(accountID: first.id, path: inboxPath(for: first.id) ?? "INBOX"))
      }
      updateDockBadge()
      await refreshAll()
    }
    scheduleChecks()
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    #if DEBUG
      configureDemoAccounts(ProcessInfo.processInfo.environment["TB_DEMO_ACCOUNTS"])
    #endif
  }

  #if DEBUG
    /// Development aid: TB_DEMO_ACCOUNTS=1 adds accounts for Support/fake-mail-server.py,
    /// TB_DEMO_ACCOUNTS=remove takes them away again.
    private func configureDemoAccounts(_ mode: String?) {
      let demo = accounts.filter { $0.label.hasPrefix("Demo ") }
      if mode == "remove" {
        demo.forEach { removeAccount($0.id) }
        return
      }
      guard mode == "1", demo.isEmpty else { return }
      let smtp = ServerConfig(host: "127.0.0.1", port: 2025, security: .none, username: "demo")
      let imap = MailAccount(
        kind: .imap, fullName: "Demo User", email: "demo@example.com", label: "Demo IMAP",
        incoming: ServerConfig(host: "127.0.0.1", port: 2143, security: .none, username: "demo"), outgoing: smtp)
      let pop = MailAccount(
        kind: .pop3, fullName: "Demo User", email: "demo@example.com", label: "Demo POP3",
        incoming: ServerConfig(host: "127.0.0.1", port: 2110, security: .none, username: "demo"), outgoing: smtp)
      let news = MailAccount(
        kind: .nntp, fullName: "Demo User", email: "demo@example.com", label: "Demo News",
        incoming: ServerConfig(host: "127.0.0.1", port: 2119, security: .none, username: ""), outgoing: .none)
      try? addAccount(imap, incomingPassword: "demo", outgoingPassword: "demo")
      try? addAccount(pop, incomingPassword: "demo", outgoingPassword: "demo")
      try? addAccount(news, incomingPassword: nil, outgoingPassword: nil)
      Task { await setNewsgroup("local.thunderbird.test", subscribed: true, accountID: news.id) }
    }
  #endif

  private func startBackend(for account: MailAccount) {
    let backend: any MailBackend =
      switch account.kind {
      case .imap: IMAPBackend(account: account, cache: cache)
      case .pop3: POP3Backend(account: account)
      case .nntp: NNTPBackend(account: account, cache: cache)
      case .local:
        LocalBackend(
          accountID: account.id, root: LocalBackend.storageRoot(for: account.id),
          defaultFolders: LocalBackend.localFoldersDefaults)
      }
    backends[account.id] = backend
    if account.kind == .imap {
      startIdle(account.id)
    }
  }

  private func startIdle(_ accountID: UUID) {
    idleTasks[accountID]?.cancel()
    idleTasks[accountID] = Task { [weak self] in
      while !Task.isCancelled {
        guard let backend = self?.backends[accountID] else { return }
        do {
          if try await backend.waitForNewMail() {
            await self?.refresh(accountID: accountID)
          } else {
            return
          }
        } catch {
          try? await Task.sleep(for: .seconds(15))
        }
      }
    }
  }

  // MARK: - Lookups

  /// Accounts shown in the folder pane: mail and news first, Local Folders last.
  var mailAccounts: [MailAccount] {
    accounts.filter { $0.kind != .local } + accounts.filter { $0.kind == .local }
  }

  var sendingAccounts: [MailAccount] { accounts.filter(\.canSend) }

  func account(_ id: UUID?) -> MailAccount? {
    accounts.first { $0.id == id }
  }

  func backend(_ id: UUID) -> (any MailBackend)? { backends[id] }

  var selectedFolder: FolderSelection? {
    if case .folder(let selection) = source { return selection }
    return nil
  }

  var currentAccount: MailAccount? {
    if let selectedFolder { return account(selectedFolder.accountID) }
    return nil
  }

  var currentFolder: RemoteFolder? {
    guard let selection = selectedFolder else { return nil }
    return folder(selection)
  }

  func folder(_ selection: FolderSelection) -> RemoteFolder? {
    folders[selection.accountID]?.first { $0.path == selection.path }
  }

  func folder(role: FolderRole, in accountID: UUID) -> RemoteFolder? {
    folders[accountID]?.first { $0.role == role && $0.isSelectable }
  }

  func role(of reference: MessageReference) -> FolderRole {
    folders[reference.accountID]?.first { $0.path == reference.path }?.role ?? .normal
  }

  private func inboxPath(for accountID: UUID) -> String? {
    folder(role: .inbox, in: accountID)?.path ?? folders[accountID]?.first(where: \.isSelectable)?.path
  }

  var localFoldersID: UUID? { accounts.first { $0.kind == .local }?.id }

  var sourceTitle: String {
    switch source {
    case .folder: currentFolder?.displayName ?? "Thunderbird"
    case .unified(let role): "Unified \(role == .inbox ? "Inbox" : role.rawValue.capitalized)"
    case .savedSearch(let id): savedSearches.first { $0.id == id }?.name ?? "Saved Search"
    case .searchResults: "Search Results"
    case nil: "Thunderbird"
    }
  }

  /// True when the action applies to at least one selected message outside a folder of `role`.
  func canMoveSelection(to role: FolderRole) -> Bool {
    selection.contains { reference in
      folder(role: role, in: reference.accountID).map { $0.path != reference.path } ?? false
    }
  }

  var filteredItems: [MessageItem] {
    let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
    return items.filter { item in
      let message = item.summary
      if filterUnread && message.isRead { return false }
      if filterStarred && !message.isFlagged { return false }
      if filterAttachments && !message.hasAttachment { return false }
      if let filterTag, !message.flags.contains(filterTag) { return false }
      guard !query.isEmpty else { return true }
      return SearchQuery(text: query, field: .headers).matches(message)
    }
  }

  var isFiltering: Bool {
    filterUnread || filterStarred || filterAttachments || filterTag != nil
      || !searchText.trimmingCharacters(in: .whitespaces).isEmpty
  }

  var selectedItems: [MessageItem] {
    items.filter { selection.contains($0.reference) }
  }

  var loadedMessage: LoadedMessage? {
    if case .loaded(let message) = reader { return message }
    return nil
  }

  /// Folders for the sidebar: special folders first, then the remaining hierarchy in tree order.
  func sidebarFolders(for accountID: UUID) -> [SidebarFolder] {
    let all = folders[accountID] ?? []
    let special = all
      .filter { $0.role != .normal && $0.isSelectable }
      .sorted { ($0.role.sortRank, $0.displayName) < ($1.role.sortRank, $1.displayName) }
    var normal = all.filter { $0.role == .normal }
    let selectablePrefixes = Set(
      normal.filter(\.isSelectable).flatMap { folder in
        (1...folder.components.count).map { folder.components.prefix($0).joined(separator: "\u{1}") }
      })
    normal = normal.filter { $0.isSelectable || selectablePrefixes.contains($0.components.joined(separator: "\u{1}")) }
    let visible = Set(normal.map { $0.components.joined(separator: "\u{1}") })
    normal.sort {
      $0.components.map { $0.lowercased() }.lexicographicallyPrecedes($1.components.map { $0.lowercased() })
    }
    let tree = normal.map { folder in
      let depth = (1..<max(1, folder.components.count)).filter {
        visible.contains(folder.components.prefix($0).joined(separator: "\u{1}"))
      }.count
      return SidebarFolder(folder: folder, depth: depth)
    }
    return special.map { SidebarFolder(folder: $0, depth: 0) } + tree
  }

  func unifiedUnread(_ role: FolderRole) -> Int {
    accounts.compactMap { folder(role: role, in: $0.id)?.unseen }.reduce(0, +)
  }

  // MARK: - Syncing

  func refreshAll() async {
    await withTaskGroup(of: Void.self) { group in
      for account in accounts {
        group.addTask { await self.refresh(accountID: account.id) }
      }
    }
    await sendUnsentMessages(silently: true)
  }

  func refresh(accountID: UUID) async {
    guard let backend = backends[accountID], !refreshing.contains(accountID) else { return }
    refreshing.insert(accountID)
    defer { refreshing.remove(accountID) }
    do {
      folders[accountID] = try await backend.refreshFolders()
      if let inbox = folder(role: .inbox, in: accountID), account(accountID)?.kind != .nntp {
        let result = try await backend.sync(
          path: inbox.path, limit: max(50, UserDefaults.standard.integer(forKey: Preferences.syncLimit)))
        await processNewMail(result.newMessages, accountID: accountID, inboxPath: inbox.path)
        if case .folder(let selection) = source, selection == FolderSelection(accountID: accountID, path: inbox.path) {
          applySync(result.messages, accountID: accountID, path: inbox.path)
        }
        updateUnseenCount(FolderSelection(accountID: accountID, path: inbox.path)) { _ in
          result.messages.filter { !$0.isRead }.count
        }
      }
      if sourceIncludes(accountID: accountID) {
        await reloadSource(network: !(selectedFolder.map { folder(role: .inbox, in: accountID)?.path == $0.path } ?? false))
      }
      if case .folder(let selection) = source, selection.accountID == accountID, folder(selection) == nil,
        let inbox = inboxPath(for: accountID)
      {
        source = .folder(FolderSelection(accountID: accountID, path: inbox))
      }
      accountErrors[accountID] = nil
      updateDockBadge()
    } catch {
      if !(error is CancellationError) {
        accountErrors[accountID] = error.localizedDescription
      }
    }
  }

  private func sourceIncludes(accountID: UUID) -> Bool {
    switch source {
    case .folder(let selection): selection.accountID == accountID
    case .unified: true
    default: false
    }
  }

  private func applySync(_ messages: [MessageSummary], accountID: UUID, path: String) {
    let updated = messages.map {
      MessageItem(reference: MessageReference(accountID: accountID, path: path, uid: $0.uid), summary: $0)
    }
    switch source {
    case .folder:
      items = updated
    case .unified:
      items = (items.filter { !($0.reference.accountID == accountID && $0.reference.path == path) } + updated)
        .sorted { $0.summary.date > $1.summary.date }
    default:
      return
    }
    selection.formIntersection(items.map(\.reference))
  }

  /// Re-reads the current source, from the cache only or from the server too.
  func reloadSource(network: Bool = true) async {
    guard let source else { return }
    let current = source
    switch current {
    case .folder(let selection):
      guard let backend = backends[selection.accountID] else { return }
      let cached = await backend.cachedMessages(in: selection.path)
      if self.source == current && items.isEmpty {
        applySync(cached, accountID: selection.accountID, path: selection.path)
      }
      guard network else { return }
      activity = "Downloading messages…"
      defer { activity = nil }
      do {
        let limit = max(50, UserDefaults.standard.integer(forKey: Preferences.syncLimit))
        let result = try await backend.sync(path: selection.path, limit: limit)
        guard self.source == current else { return }
        applySync(result.messages, accountID: selection.accountID, path: selection.path)
        updateUnseenCount(selection) { _ in result.messages.filter { !$0.isRead }.count }
        accountErrors[selection.accountID] = nil
      } catch {
        guard self.source == current, !(error is CancellationError) else { return }
        accountErrors[selection.accountID] = error.localizedDescription
      }
    case .unified(let role):
      for account in accounts {
        guard let path = folder(role: role, in: account.id)?.path, let backend = backends[account.id] else { continue }
        let cached = await backend.cachedMessages(in: path)
        guard self.source == current else { return }
        applySync(cached, accountID: account.id, path: path)
        if network, let result = try? await backend.sync(path: path, limit: 200), self.source == current {
          applySync(result.messages, accountID: account.id, path: path)
        }
      }
    case .savedSearch(let id):
      guard let search = savedSearches.first(where: { $0.id == id }) else { return }
      await runSearch(search.query, scope: search.scope, into: current)
    case .searchResults:
      break
    }
  }

  private func sourceDidChange() {
    syncTask?.cancel()
    selection = []
    reader = .empty
    items = []
    guard source != nil else { return }
    syncTask = Task { await reloadSource() }
  }

  private func scheduleChecks() {
    checkTask?.cancel()
    checkTask = Task { [weak self] in
      while !Task.isCancelled {
        let minutes = max(1, UserDefaults.standard.integer(forKey: Preferences.checkInterval))
        try? await Task.sleep(for: .seconds(minutes * 60))
        guard let self, !Task.isCancelled else { return }
        await self.refreshAll()
      }
    }
  }

  private func updateUnseenCount(_ selection: FolderSelection, _ transform: (Int) -> Int) {
    guard let index = folders[selection.accountID]?.firstIndex(where: { $0.path == selection.path }) else { return }
    let current = folders[selection.accountID]![index].unseen ?? 0
    folders[selection.accountID]![index].unseen = max(0, transform(current))
    updateDockBadge()
  }

  private func updateDockBadge() {
    let unread = unifiedUnread(.inbox)
    NSApp?.dockTile.badgeLabel = unread > 0 ? "\(unread)" : nil
  }

  // MARK: - New mail: filters, junk and notifications

  private func processNewMail(_ messages: [MessageSummary], accountID: UUID, inboxPath: String) async {
    guard !messages.isEmpty, let backend = backends[accountID] else { return }
    let filters = FilterStore.filters(for: accountID)
    var remaining: [MessageSummary] = []
    for message in messages {
      var moved = false
      for action in FilterStore.actions(for: message, filters: filters) {
        moved = await apply(action, to: message, accountID: accountID, path: inboxPath) || moved
        if moved { break }
      }
      if !moved, UserDefaults.standard.bool(forKey: Preferences.junkFilter), let junk = folder(role: .junk, in: accountID),
        let data = try? await backend.message(uid: message.uid, in: inboxPath)
      {
        let body = ParsedMessage(data: data).plainText
        let probability = await JunkClassifier.shared.junkProbability(
          subject: message.subject, from: message.from.first?.email ?? "", body: body)
        if let probability, probability > 0.95 {
          try? await backend.setFlags([MessageFlag.junk], on: true, uids: [message.uid], in: inboxPath)
          try? await backend.move(uids: [message.uid], from: inboxPath, to: junk.path)
          moved = true
        }
      }
      if !moved { remaining.append(message) }
    }
    if UserDefaults.standard.bool(forKey: Preferences.notifications) {
      notify(remaining, account: account(accountID))
    }
  }

  @discardableResult
  private func apply(_ action: FilterAction, to message: MessageSummary, accountID: UUID, path: String) async -> Bool {
    guard let backend = backends[accountID] else { return false }
    do {
      switch action.kind {
      case .moveTo:
        guard let destination = action.folderPath, destination != path else { return false }
        try await backend.move(uids: [message.uid], from: path, to: destination)
        return true
      case .copyTo:
        if let destination = action.folderPath {
          try await backend.copy(uids: [message.uid], from: path, to: destination)
        }
      case .markRead:
        try await backend.setFlags([MessageFlag.seen], on: true, uids: [message.uid], in: path)
      case .star:
        try await backend.setFlags([MessageFlag.flagged], on: true, uids: [message.uid], in: path)
      case .addTag:
        if let tag = action.tag {
          try await backend.setFlags([tag], on: true, uids: [message.uid], in: path)
        }
      case .markJunk:
        try await backend.setFlags([MessageFlag.junk], on: true, uids: [message.uid], in: path)
        if let junk = folder(role: .junk, in: accountID), junk.path != path {
          try await backend.move(uids: [message.uid], from: path, to: junk.path)
          return true
        }
      case .delete:
        if let trash = folder(role: .trash, in: accountID), trash.path != path {
          try await backend.move(uids: [message.uid], from: path, to: trash.path)
        } else {
          try await backend.delete(uids: [message.uid], in: path)
        }
        return true
      case .stop:
        break
      }
    } catch {
      report(error, title: "A message filter couldn't run")
    }
    return false
  }

  /// Runs an account's filters over every message in the selected folder.
  func runFiltersOnCurrentFolder() async {
    guard let selection = selectedFolder else { return }
    let filters = FilterStore.filters(for: selection.accountID)
    guard !filters.isEmpty else { return }
    activity = "Running filters…"
    defer { activity = nil }
    for item in items {
      for action in FilterStore.actions(for: item.summary, filters: filters) {
        if await apply(action, to: item.summary, accountID: selection.accountID, path: selection.path) { break }
      }
    }
    await reloadSource()
  }

  private func notify(_ messages: [MessageSummary], account: MailAccount?) {
    guard !messages.isEmpty else { return }
    let content = UNMutableNotificationContent()
    if messages.count == 1, let message = messages.first {
      content.title = message.from.first?.displayName ?? "New message"
      content.body = message.subject
    } else {
      content.title = "\(messages.count) new messages"
      content.body = messages.prefix(3).map { "\($0.from.first?.displayName ?? ""): \($0.subject)" }.joined(separator: "\n")
    }
    content.subtitle = account?.label ?? ""
    content.sound = .default
    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
  }

  // MARK: - Reading

  private func selectionDidChange() {
    loadTask?.cancel()
    switch selection.count {
    case 0:
      reader = .empty
    case 1:
      load(selection.first!)
    default:
      reader = .multiple(selection.count)
    }
  }

  func loadMessage(_ reference: MessageReference) async throws -> LoadedMessage {
    guard let backend = backends[reference.accountID], let account = account(reference.accountID) else {
      throw MailError.server("The account for this message no longer exists.")
    }
    let raw = try await backend.message(uid: reference.uid, in: reference.path)
    let (display, security, parsed) = await Task.detached(priority: .userInitiated) {
      let (display, security) = MessageSecurity.unprotect(raw)
      return (display, security, ParsedMessage(data: display))
    }.value
    _ = display
    let summary = items.first { $0.reference == reference }?.summary
      ?? MessageSummary(uid: reference.uid, data: raw, flags: [MessageFlag.seen])
    return LoadedMessage(
      reference: reference, summary: summary, parsed: parsed, raw: raw, account: account, security: security,
      folderRole: role(of: reference))
  }

  private func load(_ reference: MessageReference) {
    if case .loaded(let current) = reader, current.reference == reference { return }
    reader = .loading
    loadTask = Task {
      do {
        let loaded = try await loadMessage(reference)
        guard !Task.isCancelled, selection == [reference] else { return }
        reader = .loaded(loaded)
        if !loaded.summary.isRead && UserDefaults.standard.bool(forKey: Preferences.markReadOnOpen) {
          await setFlag(MessageFlag.seen, on: true, references: [reference])
        }
      } catch {
        guard !Task.isCancelled, selection == [reference] else { return }
        reader = .failed(error.localizedDescription)
      }
    }
  }

  func allowsRemoteContent(_ reference: MessageReference) -> Bool {
    UserDefaults.standard.bool(forKey: Preferences.allowRemoteContent) || remoteContentAllowed.contains(reference)
  }

  func allowRemoteContent(_ reference: MessageReference) {
    remoteContentAllowed.insert(reference)
  }

  // MARK: - Message actions

  private func grouped(_ references: some Collection<MessageReference>) -> [(FolderSelection, [UInt32])] {
    Dictionary(grouping: references) { FolderSelection(accountID: $0.accountID, path: $0.path) }
      .map { ($0.key, $0.value.map(\.uid)) }
  }

  func setFlag(_ flag: String, on: Bool, references: Set<MessageReference>? = nil) async {
    let targets = references ?? selection
    guard !targets.isEmpty else { return }
    var unseenDelta: [FolderSelection: Int] = [:]
    for index in items.indices where targets.contains(items[index].reference) {
      let had = items[index].summary.flags.contains(flag)
      if on { items[index].summary.flags.insert(flag) } else { items[index].summary.flags.remove(flag) }
      if flag == MessageFlag.seen && had != on {
        let key = FolderSelection(accountID: items[index].reference.accountID, path: items[index].reference.path)
        unseenDelta[key, default: 0] += on ? -1 : 1
      }
    }
    if case .loaded(var loaded) = reader, targets.contains(loaded.reference) {
      if on { loaded.summary.flags.insert(flag) } else { loaded.summary.flags.remove(flag) }
      reader = .loaded(loaded)
    }
    for (folder, delta) in unseenDelta {
      updateUnseenCount(folder) { $0 + delta }
    }
    for (folder, uids) in grouped(targets) {
      do {
        try await backends[folder.accountID]?.setFlags([flag], on: on, uids: uids, in: folder.path)
      } catch {
        report(error, title: "Couldn't update the message")
      }
    }
  }

  func toggleRead() async {
    await setFlag(MessageFlag.seen, on: !selectedItems.allSatisfy(\.summary.isRead))
  }

  func toggleStar() async {
    await setFlag(MessageFlag.flagged, on: !selectedItems.allSatisfy(\.summary.isFlagged))
  }

  func toggleTag(_ keyword: String) async {
    await setFlag(keyword, on: !selectedItems.allSatisfy { $0.summary.flags.contains(keyword) })
  }

  func removeAllTags() async {
    for tag in MessageTag.defaults {
      await setFlag(tag.keyword, on: false)
    }
  }

  func markFolderRead(_ selection: FolderSelection) async {
    guard let backend = backends[selection.accountID] else { return }
    let unread = await backend.cachedMessages(in: selection.path).filter { !$0.isRead }.map(\.uid)
    guard !unread.isEmpty else { return }
    let references = Set(unread.map { MessageReference(accountID: selection.accountID, path: selection.path, uid: $0) })
    await setFlag(MessageFlag.seen, on: true, references: references)
    updateUnseenCount(selection) { _ in 0 }
  }

  func deleteSelected(permanently: Bool = false) async {
    await delete(selection, permanently: permanently)
  }

  func delete(_ targets: Set<MessageReference>, permanently: Bool = false) async {
    guard !targets.isEmpty else { return }
    removeFromList(targets)
    for (folder, uids) in grouped(targets) {
      guard let backend = backends[folder.accountID] else { continue }
      do {
        if !permanently, let trash = self.folder(role: .trash, in: folder.accountID), trash.path != folder.path {
          try await backend.move(uids: uids, from: folder.path, to: trash.path)
        } else {
          try await backend.delete(uids: uids, in: folder.path)
        }
      } catch {
        report(error, title: "Couldn't delete the message")
      }
    }
    await reloadSource(network: false)
  }

  func moveSelected(to role: FolderRole) async {
    await move(selection, to: role)
  }

  func move(_ targets: Set<MessageReference>, to role: FolderRole) async {
    removeFromList(targets.filter { reference in
      folder(role: role, in: reference.accountID).map { $0.path != reference.path } ?? false
    })
    for (folder, uids) in grouped(targets) {
      guard let destination = self.folder(role: role, in: folder.accountID), destination.path != folder.path else { continue }
      do {
        try await backends[folder.accountID]?.move(uids: uids, from: folder.path, to: destination.path)
      } catch {
        report(error, title: "Couldn't move the message")
      }
    }
  }

  /// Moves or copies messages to any folder, including across accounts.
  func transfer(_ references: [MessageReference], to destination: FolderSelection, copy: Bool) async {
    let targets = Set(references)
    if !copy {
      removeFromList(targets.filter { FolderSelection(accountID: $0.accountID, path: $0.path) != destination })
    }
    activity = copy ? "Copying messages…" : "Moving messages…"
    defer { activity = nil }
    for (folder, uids) in grouped(targets) where folder != destination {
      guard let source = backends[folder.accountID], let target = backends[destination.accountID] else { continue }
      do {
        if folder.accountID == destination.accountID {
          if copy {
            try await source.copy(uids: uids, from: folder.path, to: destination.path)
          } else {
            try await source.move(uids: uids, from: folder.path, to: destination.path)
          }
        } else {
          let flags = Dictionary(
            items.filter { $0.reference.accountID == folder.accountID && $0.reference.path == folder.path }
              .map { ($0.reference.uid, $0.summary.flags) }, uniquingKeysWith: { first, _ in first })
          for uid in uids {
            let data = try await source.message(uid: uid, in: folder.path)
            try await target.append(data, to: destination.path, flags: Array(flags[uid] ?? []))
          }
          if !copy {
            try await source.delete(uids: uids, in: folder.path)
          }
        }
      } catch {
        report(error, title: copy ? "Couldn't copy the messages" : "Couldn't move the messages")
      }
    }
    await refresh(accountID: destination.accountID)
  }

  func markJunk(_ isJunk: Bool) async {
    let targets = selectedItems
    for item in targets {
      guard let backend = backends[item.reference.accountID],
        let data = try? await backend.message(uid: item.reference.uid, in: item.reference.path)
      else { continue }
      await JunkClassifier.shared.train(
        subject: item.summary.subject, from: item.summary.from.first?.email ?? "",
        body: ParsedMessage(data: data).plainText, isJunk: isJunk)
    }
    await setFlag(isJunk ? MessageFlag.junk : MessageFlag.notJunk, on: true)
    await setFlag(isJunk ? MessageFlag.notJunk : MessageFlag.junk, on: false)
    if isJunk {
      await moveSelected(to: .junk)
    } else if targets.contains(where: { role(of: $0.reference) == .junk }) {
      await moveSelected(to: .inbox)
    }
  }

  /// Removes messages from the list and selects the one that took their place, as Thunderbird does.
  private func removeFromList(_ references: Set<MessageReference>) {
    guard !references.isEmpty else { return }
    let visible = filteredItems
    let firstIndex = visible.firstIndex { references.contains($0.reference) } ?? 0
    let remaining = visible.filter { !references.contains($0.reference) }
    for item in items where references.contains(item.reference) && !item.summary.isRead {
      updateUnseenCount(FolderSelection(accountID: item.reference.accountID, path: item.reference.path)) { $0 - 1 }
    }
    items.removeAll { references.contains($0.reference) }
    selection = remaining.isEmpty ? [] : [remaining[min(firstIndex, remaining.count - 1)].reference]
  }

  // MARK: - Folders

  func createFolder(named name: String, accountID: UUID, parentPath: String?) async {
    guard let backend = backends[accountID] else { return }
    do {
      _ = try await backend.createFolder(name, parent: parentPath)
      folders[accountID] = try await backend.refreshFolders()
    } catch {
      report(error, title: "Couldn't create the folder")
    }
  }

  func renameFolder(_ selection: FolderSelection, to name: String) async {
    guard let backend = backends[selection.accountID] else { return }
    do {
      try await backend.renameFolder(selection.path, to: name)
      folders[selection.accountID] = try await backend.refreshFolders()
      if source == .folder(selection) { source = nil }
    } catch {
      report(error, title: "Couldn't rename the folder")
    }
  }

  func deleteFolder(_ selection: FolderSelection) async {
    guard let backend = backends[selection.accountID] else { return }
    do {
      try await backend.deleteFolder(selection.path)
      folders[selection.accountID] = try await backend.refreshFolders()
      if source == .folder(selection) {
        source = inboxPath(for: selection.accountID).map { .folder(FolderSelection(accountID: selection.accountID, path: $0)) }
      }
    } catch {
      report(error, title: "Couldn't delete the folder")
    }
  }

  func emptyFolder(_ selection: FolderSelection) async {
    guard let backend = backends[selection.accountID] else { return }
    do {
      try await backend.emptyFolder(selection.path)
      updateUnseenCount(selection) { _ in 0 }
      if source == .folder(selection) {
        items = []
        self.selection = []
      }
    } catch {
      report(error, title: "Couldn't empty the folder")
    }
  }

  // MARK: - Search

  func searchTargets(_ scope: SearchScope) -> [FolderSelection] {
    let skip: Set<FolderRole> = [.trash, .junk, .all]
    switch scope.kind {
    case .currentFolder:
      return scope.folder.map { [$0] } ?? []
    case .account:
      guard let accountID = scope.folder?.accountID else { return [] }
      return (folders[accountID] ?? []).filter { $0.isSelectable && !skip.contains($0.role) }
        .map { FolderSelection(accountID: accountID, path: $0.path) }
    case .allInboxes:
      return accounts.compactMap { account in
        folder(role: .inbox, in: account.id).map { FolderSelection(accountID: account.id, path: $0.path) }
      }
    case .everything:
      return accounts.flatMap { account in
        (folders[account.id] ?? []).filter { $0.isSelectable && !skip.contains($0.role) }
          .map { FolderSelection(accountID: account.id, path: $0.path) }
      }
    }
  }

  func search(_ query: SearchQuery, scope: SearchScope) async {
    source = .searchResults
    await runSearch(query, scope: scope, into: .searchResults)
  }

  private func runSearch(_ query: SearchQuery, scope: SearchScope, into current: MailboxSource) async {
    activity = "Searching…"
    defer { activity = nil }
    var results: [MessageItem] = []
    for target in searchTargets(scope) {
      guard let backend = backends[target.accountID] else { continue }
      do {
        let found = try await backend.search(query, in: target.path, limit: 200)
        results += found.map {
          MessageItem(reference: MessageReference(accountID: target.accountID, path: target.path, uid: $0.uid), summary: $0)
        }
      } catch {
        let cached = await backend.cachedMessages(in: target.path).filter { query.matches($0) }
        results += cached.map {
          MessageItem(reference: MessageReference(accountID: target.accountID, path: target.path, uid: $0.uid), summary: $0)
        }
      }
      guard source == current else { return }
      items = results.sorted { $0.summary.date > $1.summary.date }
    }
  }

  func saveSearch(name: String, query: SearchQuery, scope: SearchScope) {
    let search = SavedSearch(name: name, query: query, scope: scope)
    savedSearches.append(search)
    persistSavedSearches()
    source = .savedSearch(search.id)
  }

  func deleteSavedSearch(_ id: UUID) {
    savedSearches.removeAll { $0.id == id }
    persistSavedSearches()
    if source == .savedSearch(id) { source = nil }
  }

  private func persistSavedSearches() {
    UserDefaults.standard.set(try? JSONEncoder().encode(savedSearches), forKey: Self.savedSearchesKey)
  }

  // MARK: - Composing

  func identity(for draft: ComposeDraft) -> (MailAccount, Identity)? {
    guard let account = account(draft.accountID) ?? sendingAccounts.first else { return nil }
    let identity = account.identities.first { $0.id == draft.identityID } ?? account.identity
    return (account, identity)
  }

  func newDraft(to address: String = "") -> ComposeDraft {
    let account = currentAccount.flatMap { $0.canSend ? $0 : nil } ?? sendingAccounts.first
    return ComposeDraft.new(account: account, to: address)
  }

  func replyDraft(all: Bool, to loaded: LoadedMessage? = nil) -> ComposeDraft? {
    guard let loaded = loaded ?? loadedMessage else { return nil }
    let account = loaded.account.canSend ? loaded.account : (sendingAccounts.first ?? loaded.account)
    return ComposeDraft.reply(to: loaded.parsed, reference: loaded.reference, account: account, all: all)
  }

  func forwardDraft(_ loaded: LoadedMessage? = nil) -> ComposeDraft? {
    guard let loaded = loaded ?? loadedMessage else { return nil }
    let urls = loaded.parsed.attachments.compactMap { try? AttachmentFiles.temporaryURL(for: $0) }
    let account = loaded.account.canSend ? loaded.account : (sendingAccounts.first ?? loaded.account)
    return ComposeDraft.forward(loaded.parsed, reference: loaded.reference, account: account, attachments: urls)
  }

  /// A compose window for a message in Drafts (edit) or Templates (new copy), else nil.
  func reopenDraft(_ loaded: LoadedMessage) -> ComposeDraft? {
    switch loaded.folderRole {
    case .drafts: ComposeDraft.reopen(loaded.parsed, reference: loaded.reference, account: loaded.account, asTemplate: false)
    case .templates: ComposeDraft.reopen(loaded.parsed, reference: loaded.reference, account: loaded.account, asTemplate: true)
    default: nil
    }
  }

  private func outgoingMessage(_ draft: ComposeDraft, forDraft: Bool) throws -> (MailAccount, OutgoingMessage) {
    guard let (account, identity) = identity(for: draft) else {
      throw MailError.server("Set up an account before sending mail.")
    }
    var message = OutgoingMessage(
      from: identity.address,
      to: MailAddress.parseList(draft.to),
      cc: MailAddress.parseList(draft.cc),
      bcc: MailAddress.parseList(draft.bcc),
      subject: draft.subject,
      body: draft.body,
      inReplyTo: draft.inReplyTo,
      references: draft.references,
      attachments: try draft.attachments.map { url in
        OutgoingAttachment(
          filename: url.lastPathComponent,
          mimeType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream",
          data: try Data(contentsOf: url))
      })
    message.htmlBody = draft.isHTML ? draft.htmlBody : nil
    message.newsgroups = draft.newsgroups.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
    message.replyTo = MailAddress.parseList(identity.replyTo)
    message.includeBccHeader = forDraft
    if !forDraft && (draft.encrypt || draft.sign) {
      message.security = OutgoingSecurity(
        technology: account.securityTechnology, sign: draft.sign, encrypt: draft.encrypt,
        signerKey: account.openPGPKeyID)
      message.protector = MessageSecurity()
    }
    if forDraft {
      message.extraHeaders.append(HeaderField(name: "X-Thunderbird-Account", value: account.id.uuidString))
    }
    return (account, message)
  }

  func send(_ draft: ComposeDraft) async throws {
    let (account, message) = try outgoingMessage(draft, forDraft: false)
    guard !message.allRecipients.isEmpty || !message.newsgroups.isEmpty else { throw MailError.invalidRecipients }
    activity = "Sending message…"
    defer { activity = nil }
    let rendered = try await MailSender.send(message, account: account)
    onAddressesUsed?(message.allRecipients)
    await afterSending(draft, account: account, rendered: rendered)
  }

  private func afterSending(_ draft: ComposeDraft, account: MailAccount, rendered: Data) async {
    let host = account.outgoing.host.lowercased()
    let serverSavesSent = host.hasSuffix("gmail.com") || host.hasSuffix("googlemail.com")
    let sentTarget = folder(role: .sent, in: account.id).map { (account.id, $0.path) }
    if !serverSavesSent, account.kind != .nntp, let (accountID, path) = sentTarget {
      try? await backends[accountID]?.append(rendered, to: path, flags: [MessageFlag.seen])
    }
    if let source = draft.source, let backend = backends[source.accountID] {
      let flag = draft.kind == .forward ? MessageFlag.forwarded : MessageFlag.answered
      try? await backend.setFlags([flag], on: true, uids: [source.uid], in: source.path)
      if let index = items.firstIndex(where: { $0.reference == source }) {
        items[index].summary.flags.insert(flag)
      }
    }
    if let saved = draft.savedDraft, let backend = backends[saved.accountID] {
      try? await backend.delete(uids: [saved.uid], in: saved.path)
      items.removeAll { $0.reference == saved }
    }
    if case .folder(let selection) = source, [.sent, .drafts].contains(folder(selection)?.role) {
      await reloadSource()
    }
  }

  /// Saves the draft to the account's Drafts folder, replacing the previous copy. Returns the draft's Message-ID.
  @discardableResult
  func saveDraft(_ draft: ComposeDraft, asTemplate: Bool = false) async throws -> String {
    let (account, message) = try outgoingMessage(draft, forDraft: true)
    let role: FolderRole = asTemplate ? .templates : .drafts
    let target = try await ensureFolder(role, in: account)
    let messageID = (asTemplate ? nil : draft.draftMessageID) ?? OutgoingMessage.makeMessageID(domainOf: account.email)
    let data = try message.render(messageID: messageID)
    guard let backend = backends[target.accountID] else { throw MailError.connectionClosed }
    let previous = asTemplate ? [] : ((try? await backend.findMessage(messageID: messageID, in: target.path)) ?? [])
    try await backend.append(data, to: target.path, flags: [MessageFlag.seen, MessageFlag.draft])
    if !previous.isEmpty {
      try? await backend.delete(uids: previous, in: target.path)
    }
    if source == .folder(target) {
      await reloadSource()
    }
    return messageID
  }

  /// Finds the account's folder for `role`, creating it (or falling back to Local Folders) if needed.
  private func ensureFolder(_ role: FolderRole, in account: MailAccount) async throws -> FolderSelection {
    if let existing = folder(role: role, in: account.id) {
      return FolderSelection(accountID: account.id, path: existing.path)
    }
    let name = role == .drafts ? "Drafts" : role == .templates ? "Templates" : role == .outbox ? "Unsent Messages" : "Sent"
    let owner = backends[account.id]?.capabilities.canManageFolders == true ? account.id : localFoldersID
    guard let owner, let backend = backends[owner] else { throw MailError.unsupported("Saving drafts") }
    if let existing = folder(role: role, in: owner) {
      return FolderSelection(accountID: owner, path: existing.path)
    }
    let path = try await backend.createFolder(name, parent: nil)
    folders[owner] = try await backend.refreshFolders()
    return FolderSelection(accountID: owner, path: path)
  }

  /// Queues a message in Local Folders › Unsent Messages to send later.
  func sendLater(_ draft: ComposeDraft) async throws {
    let (account, message) = try outgoingMessage(draft, forDraft: true)
    guard !message.allRecipients.isEmpty else { throw MailError.invalidRecipients }
    guard let localID = localFoldersID, let outbox = folder(role: .outbox, in: localID), let backend = backends[localID] else {
      throw MailError.unsupported("Send Later")
    }
    var queued = message
    queued.security = nil
    _ = account
    try await backend.append(
      try queued.render(messageID: OutgoingMessage.makeMessageID(domainOf: account.email)), to: outbox.path, flags: [])
    folders[localID] = try await backend.refreshFolders()
  }

  func sendUnsentMessages(silently: Bool = false) async {
    guard let localID = localFoldersID, let outbox = folder(role: .outbox, in: localID), let backend = backends[localID] else { return }
    let queued = await backend.cachedMessages(in: outbox.path)
    guard !queued.isEmpty else { return }
    activity = "Sending unsent messages…"
    defer { activity = nil }
    for summary in queued {
      do {
        let data = try await backend.message(uid: summary.uid, in: outbox.path)
        let headers = MIMEParser.parseHeaders(data)
        guard let accountID = headers["X-Thunderbird-Account"].flatMap(UUID.init(uuidString:)),
          let account = account(accountID)
        else { continue }
        let recipients = (["To", "Cc", "Bcc"].flatMap { MailAddress.parseList(headers[$0] ?? "") }).map(\.email)
        let cleaned = Self.removingHeaders(["Bcc", "X-Thunderbird-Account"], from: data)
        let credential: Credential? =
          account.outgoing.username.isEmpty
          ? nil : try await Credentials.resolve(account.outgoing, key: account.outgoingKeychainKey)
        let sender = MailAddress.parseList(headers["From"] ?? "").first?.email ?? account.email
        try await SMTPClient(server: account.outgoing, credential: credential).send(cleaned, from: sender, to: recipients)
        try await backend.delete(uids: [summary.uid], in: outbox.path)
        await afterSending(ComposeDraft(), account: account, rendered: cleaned)
      } catch {
        if !silently { report(error, title: "Couldn't send an unsent message") }
      }
    }
    folders[localID] = try? await backend.refreshFolders()
  }

  static func removingHeaders(_ names: [String], from data: Data) -> Data {
    let lowered = Set(names.map { $0.lowercased() })
    guard let split = data.range(of: Data("\r\n\r\n".utf8)) else { return data }
    let headerText = String(decoding: data[data.startIndex..<split.lowerBound], as: UTF8.self)
    var kept: [String] = []
    var skipping = false
    for line in headerText.components(separatedBy: "\r\n") {
      if line.first == " " || line.first == "\t" {
        if !skipping { kept.append(line) }
        continue
      }
      let name = line.split(separator: ":", maxSplits: 1).first.map { $0.lowercased() } ?? ""
      skipping = lowered.contains(name)
      if !skipping { kept.append(line) }
    }
    var output = Data(kept.joined(separator: "\r\n").utf8)
    output.append(data[split.lowerBound...])
    return output
  }

  /// Sends an iMIP reply to a calendar invitation.
  func respond(to invitation: CalendarInvitation, status: String, from loaded: LoadedMessage) async {
    guard let organizer = invitation.organizer else { return }
    let account = loaded.account.canSend ? loaded.account : (sendingAccounts.first ?? loaded.account)
    let own = Set(account.identities.map { $0.email.lowercased() })
    let attendee = invitation.attendees.first { own.contains($0.email.lowercased()) }
      .map { MailAddress(name: $0.name, email: $0.email) } ?? account.address
    var message = OutgoingMessage(
      from: account.address, to: [organizer],
      subject: "\(status == "ACCEPTED" ? "Accepted" : status == "DECLINED" ? "Declined" : "Tentative"): \(invitation.summary)",
      body: "\(attendee.displayName) has \(status.lowercased()) your invitation.")
    message.alternatives = [
      OutgoingAlternative(
        contentType: "text/calendar; charset=UTF-8; method=REPLY",
        text: ICalendar.reply(to: invitation, attendee: attendee, status: status))
    ]
    do {
      _ = try await MailSender.send(message, account: account)
    } catch {
      report(error, title: "Couldn't send your reply")
    }
  }

  // MARK: - Accounts

  private func persistAccounts() {
    if let data = try? JSONEncoder().encode(accounts) {
      UserDefaults.standard.set(data, forKey: Self.accountsKey)
    }
  }

  func addAccount(_ account: MailAccount, incomingPassword: String?, outgoingPassword: String?) throws {
    if let incomingPassword, !incomingPassword.isEmpty {
      try Keychain.setPassword(incomingPassword, for: account.incomingKeychainKey)
    }
    if let outgoingPassword, !outgoingPassword.isEmpty {
      try Keychain.setPassword(outgoingPassword, for: account.outgoingKeychainKey)
    }
    let localIndex = accounts.firstIndex { $0.kind == .local } ?? accounts.endIndex
    accounts.insert(account, at: localIndex)
    persistAccounts()
    startBackend(for: account)
    folders[account.id] = []
    Task {
      await refresh(accountID: account.id)
      if selectedFolder == nil || selectedFolder?.accountID == account.id || mailAccounts.first?.id == account.id {
        if let inbox = inboxPath(for: account.id) {
          source = .folder(FolderSelection(accountID: account.id, path: inbox))
        }
      }
    }
  }

  func updateAccount(_ account: MailAccount, incomingPassword: String?, outgoingPassword: String?) throws {
    guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
    if let incomingPassword, !incomingPassword.isEmpty {
      try Keychain.setPassword(incomingPassword, for: account.incomingKeychainKey)
    }
    if let outgoingPassword, !outgoingPassword.isEmpty {
      try Keychain.setPassword(outgoingPassword, for: account.outgoingKeychainKey)
    }
    accounts[index] = account
    persistAccounts()
    let old = backends[account.id]
    Task { await old?.disconnect() }
    startBackend(for: account)
    Task { await refresh(accountID: account.id) }
  }

  func moveAccount(_ id: UUID, by offset: Int) {
    guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
    let target = index + offset
    guard accounts.indices.contains(target), accounts[target].kind != .local, accounts[index].kind != .local else { return }
    accounts.swapAt(index, target)
    persistAccounts()
  }

  func removeAccount(_ id: UUID) {
    guard let account = account(id), account.kind != .local else { return }
    let backend = backends.removeValue(forKey: id)
    idleTasks.removeValue(forKey: id)?.cancel()
    Task { await backend?.disconnect() }
    Keychain.deletePassword(for: account.incomingKeychainKey)
    Keychain.deletePassword(for: account.outgoingKeychainKey)
    Keychain.deletePassword(for: Credentials.oauthKey(for: account.incomingKeychainKey))
    cache.removeAccount(id)
    try? FileManager.default.removeItem(at: LocalBackend.storageRoot(for: id))
    accounts.removeAll { $0.id == id }
    folders[id] = nil
    FilterStore.save([], for: id)
    persistAccounts()
    if selectedFolder?.accountID == id {
      source = mailAccounts.first.flatMap { first in
        inboxPath(for: first.id).map { .folder(FolderSelection(accountID: first.id, path: $0)) }
      }
    }
    updateDockBadge()
  }

  /// Subscribes to or unsubscribes from a newsgroup.
  func setNewsgroup(_ name: String, subscribed: Bool, accountID: UUID) async {
    guard let backend = backends[accountID] as? NNTPBackend else { return }
    await backend.setSubscribed(name, subscribed)
    folders[accountID] = await backend.cachedFolders()
  }

  // MARK: - Errors

  func report(_ error: Error, title: String) {
    if error is CancellationError { return }
    presentedError = PresentedError(title: title, message: error.localizedDescription)
  }
}
