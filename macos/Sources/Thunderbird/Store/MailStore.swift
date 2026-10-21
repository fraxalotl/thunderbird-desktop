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
import WebKit

struct FolderSelection: Hashable, Codable {
  var accountID: UUID
  var path: String
}

enum MailboxSource: Hashable, Codable {
  case folder(FolderSelection)
  case unified(FolderRole)
  case savedSearch(UUID)
  case searchResults
  case tag(String)
}

struct MessageItem: Identifiable, Hashable {
  var reference: MessageReference
  var summary: MessageSummary
  var id: MessageReference { reference }
}

/// A folder and its subfolders, for the collapsible folder tree.
struct FolderNode: Identifiable, Hashable {
  var folder: RemoteFolder
  var children: [FolderNode]?
  var id: String { folder.path }
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

struct ActivityEntry: Identifiable, Hashable {
  let id = UUID()
  var date: Date
  var text: String
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
  // General › Reading & Display
  static let markReadDelay = "markReadDelaySeconds"
  static let openInExistingWindow = "openInExistingWindow"
  static let closeOnMoveDelete = "closeWindowOnMoveDelete"
  static let displayNameOnly = "showDisplayNameOnly"
  static let showStartPage = "showStartPage"
  static let notificationSound = "newMailSound"
  // General › Files & Attachments
  static let downloadFolder = "downloadFolder"
  static let alwaysAskWhereToSave = "alwaysAskWhereToSave"
  // Composition
  static let forwardAsAttachment = "forwardAsAttachment"
  static let autosaveMinutes = "autosaveMinutes"
  static let confirmSendShortcut = "confirmSendShortcut"
  static let attachmentReminder = "attachmentReminder"
  static let attachmentKeywords = "attachmentKeywords"
  static let composeFont = "composeFont"
  static let composeFontSize = "composeFontSize"
  static let composeTextColor = "composeTextColor"
  static let composeBackground = "composeBackground"
  static let collectAddresses = "collectAddresses"
  static let spellcheckBeforeSend = "spellcheckBeforeSend"
  static let defaultHTML = "composeHTMLByDefault"
  // Privacy & Security
  static let remoteContentExceptions = "remoteContentExceptions"
  static let junkMarkRead = "junkMarkRead"
  static let junkDelete = "junkDeleteInsteadOfMove"
  static let scamDetection = "scamDetection"
  // Chat
  static let chatNotifications = "chatNotifications"
  static let chatAwayMinutes = "chatAwayMinutes"
  // Calendar
  static let weekStart = "calendarWeekStart"
  static let defaultEventMinutes = "defaultEventMinutes"
  static let showWeekNumbers = "showWeekNumbers"
  static let dayStartHour = "dayStartHour"
  static let dayEndHour = "dayEndHour"
  static let defaultReminderMinutes = "defaultReminderMinutes"

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
      markReadDelay: 0,
      openInExistingWindow: false,
      closeOnMoveDelete: false,
      displayNameOnly: true,
      showStartPage: true,
      notificationSound: true,
      downloadFolder: "",
      alwaysAskWhereToSave: true,
      forwardAsAttachment: false,
      autosaveMinutes: 5,
      confirmSendShortcut: true,
      attachmentReminder: true,
      attachmentKeywords: "attach, attached, attachment, enclosed, CV, resume, PDF",
      composeFont: "",
      composeFontSize: 14,
      composeTextColor: "#1D1D1F",
      composeBackground: "#FFFFFF",
      collectAddresses: true,
      spellcheckBeforeSend: false,
      defaultHTML: true,
      remoteContentExceptions: [String](),
      junkMarkRead: true,
      junkDelete: false,
      scamDetection: true,
      chatNotifications: true,
      chatAwayMinutes: 5,
      weekStart: Calendar.current.firstWeekday,
      defaultEventMinutes: 60,
      showWeekNumbers: false,
      dayStartHour: 8,
      dayEndHour: 17,
      defaultReminderMinutes: 15,
    ])
  }

  static var defaults: UserDefaults { .standard }
  static func bool(_ key: String) -> Bool { defaults.bool(forKey: key) }
  static func int(_ key: String) -> Int { defaults.integer(forKey: key) }
  static func string(_ key: String) -> String { defaults.string(forKey: key) ?? "" }

  /// The calendar the Calendar space uses, honouring the first-day-of-week preference.
  static var calendar: Calendar {
    var calendar = Calendar.current
    calendar.firstWeekday = max(1, min(7, int(weekStart)))
    return calendar
  }
}

@MainActor
@Observable
final class MailStore {
  private(set) var accounts: [MailAccount] = []
  private(set) var folders: [UUID: [RemoteFolder]] = [:]
  var items: [MessageItem] = []
  private(set) var reader: ReaderState = .empty
  /// A displayed message whose sender asked for a return receipt, when the account policy is "ask".
  var pendingReceipt: LoadedMessage?
  /// Local Folders › Templates, for the message context menu's Reply with Template.
  var localTemplates: [MessageItem] = []
  /// Reading & Display › Open messages in an existing window: the newest message window shows this.
  var messageWindowRequest: MessageReference?
  var openMessageWindows: [UUID] = []
  private(set) var refreshing: Set<UUID> = []
  var activity: String? {
    didSet {
      if let activity, activity != oldValue {
        activityLog.insert(ActivityEntry(date: Date(), text: activity), at: 0)
        if activityLog.count > 500 { activityLog.removeLast() }
      }
    }
  }
  /// Tools › Activity Manager.
  var activityLog: [ActivityEntry] = []
  private(set) var accountErrors: [UUID: String] = [:]
  private(set) var savedSearches: [SavedSearch] = []
  private(set) var favoriteFolders: [FolderSelection] =
    (try? JSONDecoder().decode([FolderSelection].self, from: UserDefaults.standard.data(forKey: "favoriteFolders") ?? Data())) ?? []
  private(set) var recentFolders: [FolderSelection] =
    (try? JSONDecoder().decode([FolderSelection].self, from: UserDefaults.standard.data(forKey: "recentFolders") ?? Data())) ?? []
  var presentedError: PresentedError?

  /// The toolbar's global search text.
  var searchText = ""
  // Quick filter bar
  var filterText = ""
  var filterScopes: Set<QuickFilterScope> = [.sender, .recipients, .subject]
  var filterUnread = false
  var filterStarred = false
  var filterAttachments = false
  var filterContact = false
  var filterSticky = false
  var filterTag: String?
  var knownContactEmails: Set<String> = []
  var bodyMatches: Set<MessageReference>?
  // View menu
  var threadMode = ThreadMode(rawValue: UserDefaults.standard.string(forKey: Preferences.threaded) ?? "") ?? .unthreaded {
    didSet { UserDefaults.standard.set(threadMode.rawValue, forKey: Preferences.threaded) }
  }
  var sortKey = SortKey(rawValue: UserDefaults.standard.string(forKey: "sortKey") ?? "") ?? .date {
    didSet { UserDefaults.standard.set(sortKey.rawValue, forKey: "sortKey") }
  }
  var sortAscending = UserDefaults.standard.bool(forKey: "sortAscending") {
    didSet { UserDefaults.standard.set(sortAscending, forKey: "sortAscending") }
  }
  var threadFilter = ThreadFilter.all
  var expandedThreads: Set<MessageReference> = []
  var pendingFeedSetup = false
  var pendingFeedSubscriptions: UUID?
  var isOffline = UserDefaults.standard.bool(forKey: "workOffline") {
    didSet { UserDefaults.standard.set(isOffline, forKey: "workOffline") }
  }
  var lastMoveTarget: (destination: FolderSelection, copy: Bool)?
  @ObservationIgnored var undoManager: UndoManager?
  @ObservationIgnored var history: [MessageReference] = []
  @ObservationIgnored var historyIndex = -1
  @ObservationIgnored var navigatingHistory = false
  var viewFilter = MessageViewFilter.all
  private(set) var ignoredThreads = Set(UserDefaults.standard.stringArray(forKey: "ignoredThreads") ?? [])
  private(set) var watchedThreads = Set(UserDefaults.standard.stringArray(forKey: "watchedThreads") ?? [])

  var threaded: Bool {
    get { threadMode == .threaded }
    set { threadMode = newValue ? .threaded : .unthreaded }
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
  /// Expands an address book mailing list token into its members when sending.
  @ObservationIgnored var expandMailingList: ((String) -> [MailAddress])?

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
      await reloadLocalTemplates()
      await withTaskGroup(of: Void.self) { group in
        for account in accounts where account.options.checkAtStartup {
          group.addTask { await self.refresh(accountID: account.id) }
        }
      }
      await sendUnsentMessages(silently: true)
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
      case .feed: FeedBackend(accountID: account.id)
      case .ews: EWSBackend(account: account, cache: cache)
      case .local:
        LocalBackend(
          accountID: account.id, root: LocalBackend.storageRoot(for: account.id),
          defaultFolders: LocalBackend.localFoldersDefaults)
      }
    backends[account.id] = backend
    if account.kind == .imap && account.options.usePush {
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
    if let options = account(accountID)?.options {
      let override: String? =
        switch role {
        case .sent: options.sentFolder
        case .drafts: options.draftsFolder
        case .templates: options.templatesFolder
        case .archive: options.archiveFolder
        default: nil
        }
      if let override, let folder = folders[accountID]?.first(where: { $0.path == override }) {
        return folder
      }
    }
    return folders[accountID]?.first { $0.role == role && $0.isSelectable }
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
    case .folder: currentFolder?.displayName ?? "Zapdos"
    case .unified(let role): "Unified \(role == .inbox ? "Inbox" : role.rawValue.capitalized)"
    case .savedSearch(let id): savedSearches.first { $0.id == id }?.name ?? "Saved Search"
    case .searchResults: "Search Results"
    case .tag(let keyword): MessageTagStore.shared.tag(keyword)?.name ?? keyword
    case nil: "Zapdos"
    }
  }

  /// True when the action applies to at least one selected message outside a folder of `role`.
  /// Selects `targets` (the right-clicked messages) and waits for a single message to load, so
  /// context menu commands act on what was clicked.
  func focusSelection(_ targets: Set<MessageReference>) async {
    if selection != targets { selection = targets }
    guard targets.count == 1, let target = targets.first else { return }
    for _ in 0..<60 {
      if loadedMessage?.reference == target { return }
      if case .failed = reader { return }
      try? await Task.sleep(for: .milliseconds(50))
    }
  }

  func canMove(_ references: Set<MessageReference>, to role: FolderRole) -> Bool {
    references.contains { reference in
      folder(role: role, in: reference.accountID).map { $0.path != reference.path } ?? false
    }
  }

  func canMoveSelection(to role: FolderRole) -> Bool {
    selection.contains { reference in
      folder(role: role, in: reference.accountID).map { $0.path != reference.path } ?? false
    }
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
    guard !isOffline, let backend = backends[accountID], !refreshing.contains(accountID) else { return }
    refreshing.insert(accountID)
    defer { refreshing.remove(accountID) }
    do {
      if let feeds = backend as? FeedBackend {
        let delivered = await feeds.updateAll()
        if UserDefaults.standard.bool(forKey: Preferences.notifications) {
          notifyFeeds(delivered, account: account(accountID))
        }
      }
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
      if account(accountID)?.kind == .local { await reloadLocalTemplates() }
      Task { await self.applyStoragePolicies(accountID) }
    } catch {
      if !(error is CancellationError) {
        accountErrors[accountID] = error.localizedDescription
      }
    }
  }

  /// Account Settings › Junk (purge after N days) and Synchronization & Storage (retention, offline copies).
  private func applyStoragePolicies(_ accountID: UUID) async {
    guard let account = account(accountID), let backend = backends[accountID] else { return }
    let options = account.options
    if let days = options.junkPurgeDays, days > 0, let junk = folder(role: .junk, in: accountID) {
      let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
      let old = await backend.cachedMessages(in: junk.path).filter { $0.date < cutoff }.map(\.uid)
      if !old.isEmpty { try? await backend.delete(uids: old, in: junk.path) }
    }
    if let days = options.deleteOlderThanDays, days > 0 {
      let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
      for folder in (folders[accountID] ?? []) where folder.isSelectable && ![.drafts, .templates].contains(folder.role) {
        let old = await backend.cachedMessages(in: folder.path)
          .filter { $0.date < cutoff && !(options.keepStarred && $0.isFlagged) }.map(\.uid)
        if !old.isEmpty { try? await backend.delete(uids: old, in: folder.path) }
      }
    }
    if options.keepMessagesOffline, account.kind == .imap || account.kind == .ews {
      for folder in (folders[accountID] ?? []) where folder.isSelectable && folder.role != .trash && folder.role != .junk {
        for summary in await backend.cachedMessages(in: folder.path) {
          _ = try? await backend.message(uid: summary.uid, in: folder.path)
        }
      }
    }
  }

  /// Runs Server Settings' "Empty Trash on Exit" and "Clean up (Expunge) Inbox on Exit".
  func prepareForQuit() async {
    for account in accounts {
      if account.options.emptyTrashOnExit, let trash = folder(role: .trash, in: account.id) {
        try? await backends[account.id]?.emptyFolder(trash.path)
      }
      if account.options.expungeInboxOnExit, let inbox = folder(role: .inbox, in: account.id) {
        try? await backends[account.id]?.compact(inbox.path)
      }
    }
  }

  var needsQuitCleanup: Bool {
    accounts.contains { $0.options.emptyTrashOnExit || $0.options.expungeInboxOnExit }
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
      guard network, !isOffline else { return }
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
    case .tag(let keyword):
      var found: [MessageItem] = []
      for account in accounts {
        guard let backend = backends[account.id] else { continue }
        for folder in (folders[account.id] ?? []) where folder.isSelectable && folder.role != .trash {
          for summary in await backend.cachedMessages(in: folder.path) where summary.flags.contains(keyword) {
            found.append(
              MessageItem(
                reference: MessageReference(accountID: account.id, path: folder.path, uid: summary.uid), summary: summary))
          }
        }
      }
      guard self.source == current else { return }
      items = found.sorted { $0.summary.date > $1.summary.date }
    }
  }

  func setIgnoredThreads(_ threads: Set<String>) {
    ignoredThreads = threads
    UserDefaults.standard.set(Array(threads), forKey: "ignoredThreads")
  }

  func setWatchedThreads(_ threads: Set<String>) {
    watchedThreads = threads
    UserDefaults.standard.set(Array(threads), forKey: "watchedThreads")
  }

  // MARK: - Favorite and recent folders

  func isFavorite(_ folder: FolderSelection) -> Bool { favoriteFolders.contains(folder) }

  func toggleFavorite(_ folder: FolderSelection) {
    if let index = favoriteFolders.firstIndex(of: folder) {
      favoriteFolders.remove(at: index)
    } else {
      favoriteFolders.append(folder)
    }
    UserDefaults.standard.set(try? JSONEncoder().encode(favoriteFolders), forKey: "favoriteFolders")
  }

  private func noteRecent(_ folder: FolderSelection) {
    recentFolders.removeAll { $0 == folder }
    recentFolders.insert(folder, at: 0)
    recentFolders = Array(recentFolders.prefix(15))
    UserDefaults.standard.set(try? JSONEncoder().encode(recentFolders), forKey: "recentFolders")
  }

  /// The account's folders as a tree: special folders first, then the user's hierarchy.
  func folderTree(for accountID: UUID) -> [FolderNode] {
    let flat = sidebarFolders(for: accountID)
    var index = 0
    func build(depth: Int) -> [FolderNode] {
      var nodes: [FolderNode] = []
      while index < flat.count, flat[index].depth >= depth {
        guard flat[index].depth == depth else { break }
        let folder = flat[index].folder
        index += 1
        let isSpecial = folder.role != .normal
        let children = isSpecial ? [] : build(depth: depth + 1)
        nodes.append(FolderNode(folder: folder, children: children.isEmpty ? nil : children))
      }
      return nodes
    }
    var roots: [FolderNode] = []
    while index < flat.count {
      let before = index
      roots += build(depth: flat[index].depth)
      if index == before { index += 1 }
    }
    return roots
  }

  private func sourceDidChange() {
    syncTask?.cancel()
    selection = []
    reader = .empty
    items = []
    bodyMatches = nil
    if !filterSticky {
      clearQuickFilter()
    }
    guard let source else { return }
    if case .folder(let folder) = source {
      noteRecent(folder)
    }
    syncTask = Task { await reloadSource() }
  }

  /// Checks each account on its own interval (Account Settings › Server Settings).
  private func scheduleChecks() {
    checkTask?.cancel()
    checkTask = Task { [weak self] in
      var lastChecked: [UUID: Date] = [:]
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(60))
        guard let self, !Task.isCancelled else { return }
        let now = Date()
        for account in self.accounts where account.options.checkIntervalMinutes > 0 {
          let last = lastChecked[account.id] ?? .distantPast
          if now.timeIntervalSince(last) >= Double(account.options.checkIntervalMinutes * 60) {
            lastChecked[account.id] = now
            Task { await self.refresh(accountID: account.id) }
          }
        }
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
        moved = await applyFilterAction(action, to: message, accountID: accountID, path: inboxPath) || moved
        if moved { break }
      }
      let options = account(accountID)?.options ?? AccountOptions()
      if !moved, UserDefaults.standard.bool(forKey: Preferences.junkFilter), options.junkEnabled,
        let data = try? await backend.message(uid: message.uid, in: inboxPath)
      {
        let parsed = ParsedMessage(data: data)
        var isJunk = false
        if options.trustSpamHeaders {
          let flag = parsed.headers["X-Spam-Flag"]?.lowercased() ?? ""
          let status = parsed.headers["X-Spam-Status"]?.lowercased() ?? ""
          isJunk = flag.hasPrefix("yes") || status.hasPrefix("yes")
        }
        if !isJunk {
          let probability = await JunkClassifier.shared.junkProbability(
            subject: message.subject, from: message.from.first?.email ?? "", body: parsed.plainText)
          isJunk = (probability ?? 0) > 0.95
        }
        if isJunk {
          try? await backend.setFlags([MessageFlag.junk], on: true, uids: [message.uid], in: inboxPath)
          if options.moveJunk, let junk = folder(role: .junk, in: accountID) {
            _ = try? await backend.move(uids: [message.uid], from: inboxPath, to: junk.path)
            moved = true
          }
        }
      }
      if !moved { remaining.append(message) }
    }
    if UserDefaults.standard.bool(forKey: Preferences.notifications) {
      notify(remaining, account: account(accountID))
    }
  }

  @discardableResult
  func applyFilterAction(_ action: FilterAction, to message: MessageSummary, accountID: UUID, path: String) async -> Bool {
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
        if await applyFilterAction(action, to: item.summary, accountID: selection.accountID, path: selection.path) { break }
      }
    }
    await reloadSource()
  }

  private func notifyFeeds(_ messages: [MessageSummary], account: MailAccount?) {
    guard !messages.isEmpty else { return }
    notify(messages, account: account)
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
    content.sound = Preferences.bool(Preferences.notificationSound) ? .default : nil
    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
  }

  // MARK: - Reading

  private func selectionDidChange() {
    loadTask?.cancel()
    if selection.count == 1, let reference = selection.first, !navigatingHistory {
      if historyIndex < history.count - 1 { history.removeSubrange((historyIndex + 1)...) }
      if history.last != reference {
        history.append(reference)
        historyIndex = history.count - 1
      }
    }
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
          let delay = Preferences.int(Preferences.markReadDelay)
          if delay > 0 {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, selection == [reference] else { return }
          }
          await setFlag(MessageFlag.seen, on: true, references: [reference], undoable: false)
        }
        await handleReturnReceipt(loaded)
      } catch {
        guard !Task.isCancelled, selection == [reference] else { return }
        reader = .failed(error.localizedDescription)
      }
    }
  }

  func allowsRemoteContent(_ reference: MessageReference, sender: MailAddress? = nil) -> Bool {
    if UserDefaults.standard.bool(forKey: Preferences.allowRemoteContent) || remoteContentAllowed.contains(reference) {
      return true
    }
    guard let sender else { return false }
    let exceptions = Set((UserDefaults.standard.stringArray(forKey: Preferences.remoteContentExceptions) ?? []).map { $0.lowercased() })
    let email = sender.email.lowercased()
    let domain = String(email.split(separator: "@").last ?? "")
    return exceptions.contains(email) || exceptions.contains(domain)
  }

  private func handleReturnReceipt(_ loaded: LoadedMessage) async {
    pendingReceipt = nil
    guard loaded.account.kind != .nntp, loaded.account.kind != .feed, loaded.folderRole == .inbox || loaded.folderRole == .normal,
      ReturnReceipt.requestedAddress(in: loaded.parsed) != nil, !loaded.summary.flags.contains(MessageFlag.mdnSent)
    else { return }
    switch loaded.account.options.receiptPolicy {
    case .never: await markReceiptHandled(loaded)
    case .always: await sendReturnReceipt(loaded)
    case .ask: pendingReceipt = loaded
    }
  }

  func sendReturnReceipt(_ loaded: LoadedMessage) async {
    pendingReceipt = nil
    guard let recipient = ReturnReceipt.requestedAddress(in: loaded.parsed) else { return }
    let recipients = Set(loaded.parsed.to.map { $0.email.lowercased() } + loaded.parsed.cc.map { $0.email.lowercased() })
    let identity = loaded.account.identities.first { recipients.contains($0.email.lowercased()) } ?? loaded.account.identity
    let sender = MailAddress(name: identity.fullName, email: identity.email)
    let messageID = OutgoingMessage.makeMessageID(domainOf: sender.email)
    let data = ReturnReceipt.report(for: loaded.parsed, from: sender, to: recipient, messageID: messageID)
    do {
      try await MailSender.sendRaw(data, from: sender.email, to: [recipient.email], account: loaded.account)
      activity = "Sent a return receipt to \(recipient.email)"
    } catch {
      report(error, title: "Couldn't send the return receipt")
      return
    }
    await markReceiptHandled(loaded)
  }

  func ignoreReturnReceipt(_ loaded: LoadedMessage) async {
    pendingReceipt = nil
    await markReceiptHandled(loaded)
  }

  private func markReceiptHandled(_ loaded: LoadedMessage) async {
    await setFlag(MessageFlag.mdnSent, on: true, references: [loaded.reference], undoable: false)
  }

  /// "Allow remote content from …" in the remote content bar adds a sender or domain exception.
  func addRemoteContentException(_ value: String) {
    var list = UserDefaults.standard.stringArray(forKey: Preferences.remoteContentExceptions) ?? []
    if !list.contains(value.lowercased()) { list.append(value.lowercased()) }
    UserDefaults.standard.set(list, forKey: Preferences.remoteContentExceptions)
    remoteContentAllowed.formUnion([])
  }

  func allowRemoteContent(_ reference: MessageReference) {
    remoteContentAllowed.insert(reference)
  }

  // MARK: - Message actions

  private func grouped(_ references: some Collection<MessageReference>) -> [(FolderSelection, [UInt32])] {
    Dictionary(grouping: references) { FolderSelection(accountID: $0.accountID, path: $0.path) }
      .map { ($0.key, $0.value.map(\.uid)) }
  }

  func setFlag(_ flag: String, on: Bool, references: Set<MessageReference>? = nil, undoable: Bool = true) async {
    let targets = references ?? selection
    guard !targets.isEmpty else { return }
    if undoable {
      let name =
        flag == MessageFlag.seen ? (on ? "Mark as Read" : "Mark as Unread")
        : flag == MessageFlag.flagged ? (on ? "Add Star" : "Remove Star") : "Tag"
      registerUndoPair(
        name,
        undo: { [weak self] in await self?.setFlag(flag, on: !on, references: targets, undoable: false) },
        redo: { [weak self] in await self?.setFlag(flag, on: on, references: targets, undoable: false) })
    }
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
    if !permanently {
      let markOnly = targets.filter { account($0.accountID)?.options.deleteModel == .markDeleted }
      if !markOnly.isEmpty {
        await setFlag(MessageFlag.deleted, on: true, references: Set(markOnly))
      }
      let immediate = Set(targets.filter { account($0.accountID)?.options.deleteModel == .removeImmediately })
      if !immediate.isEmpty {
        await delete(immediate, permanently: true)
      }
      let rest = targets.subtracting(markOnly).subtracting(immediate)
      guard !rest.isEmpty else { return }
      await deleteToTrash(rest)
      return
    }
    await deleteToTrash(targets, permanently: true)
  }

  private func deleteToTrash(_ targets: Set<MessageReference>, permanently: Bool = false) async {
    removeFromList(targets)
    for (folder, uids) in grouped(targets) {
      guard let backend = backends[folder.accountID] else { continue }
      do {
        if !permanently, let trash = self.folder(role: .trash, in: folder.accountID), trash.path != folder.path {
          let mapping = try await backend.move(uids: uids, from: folder.path, to: trash.path)
          registerMoveUndo("Delete", mapping: mapping, from: folder, to: FolderSelection(accountID: folder.accountID, path: trash.path))
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
    if role == .archive {
      let byGranularity = Dictionary(grouping: targets) { account($0.accountID)?.options.archiveGranularity ?? .single }
      if let dated = byGranularity.filter({ $0.key != .single }).values.first, !dated.isEmpty {
        await archiveIntoSubfolders(Set(byGranularity.filter { $0.key != .single }.values.flatMap { $0 }))
        let single = Set(byGranularity[.single] ?? [])
        if single.isEmpty { return }
        await move(single, to: role)
        return
      }
    }
    removeFromList(targets.filter { reference in
      folder(role: role, in: reference.accountID).map { $0.path != reference.path } ?? false
    })
    for (folder, uids) in grouped(targets) {
      guard let destination = self.folder(role: role, in: folder.accountID), destination.path != folder.path else { continue }
      do {
        let mapping = try await backends[folder.accountID]?.move(uids: uids, from: folder.path, to: destination.path) ?? [:]
        registerMoveUndo(
          role == .archive ? "Archive" : role == .junk ? "Mark as Spam" : "Move", mapping: mapping, from: folder,
          to: FolderSelection(accountID: folder.accountID, path: destination.path))
      } catch {
        report(error, title: "Couldn't move the message")
      }
    }
  }

  /// Archives into Archives/2026 or Archives/2026/2026-10 folders, as Thunderbird's archive options do.
  private func archiveIntoSubfolders(_ targets: Set<MessageReference>) async {
    for (folder, uids) in grouped(targets) {
      guard let account = account(folder.accountID), let archive = self.folder(role: .archive, in: folder.accountID),
        let backend = backends[folder.accountID]
      else { continue }
      let delimiter = archive.delimiter ?? "/"
      var byDestination: [String: [UInt32]] = [:]
      for uid in uids {
        let date = items.first { $0.reference.accountID == folder.accountID && $0.reference.path == folder.path && $0.reference.uid == uid }?.summary.date ?? Date()
        let year = Calendar.current.component(.year, from: date)
        let month = Calendar.current.component(.month, from: date)
        var path = "\(archive.path)\(delimiter)\(year)"
        if account.options.archiveGranularity == .monthly {
          path += "\(delimiter)\(year)-\(String(format: "%02d", month))"
        }
        byDestination[path, default: []].append(uid)
      }
      for (destination, group) in byDestination {
        if folders[folder.accountID]?.contains(where: { $0.path == destination }) != true {
          var parent = archive.path
          for component in destination.dropFirst(archive.path.count + delimiter.count).components(separatedBy: delimiter) {
            let child = "\(parent)\(delimiter)\(component)"
            if folders[folder.accountID]?.contains(where: { $0.path == child }) != true {
              _ = try? await backend.createFolder(component, parent: parent)
              folders[folder.accountID] = (try? await backend.refreshFolders()) ?? folders[folder.accountID]
            }
            parent = child
          }
        }
        removeFromList(Set(group.map { MessageReference(accountID: folder.accountID, path: folder.path, uid: $0) }))
        _ = try? await backend.move(uids: group, from: folder.path, to: destination)
      }
    }
  }

  /// Moves or copies messages to any folder, including across accounts.
  func transfer(_ references: [MessageReference], to destination: FolderSelection, copy: Bool) async {
    lastMoveTarget = (destination, copy)
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
            let mapping = try await source.move(uids: uids, from: folder.path, to: destination.path)
            registerMoveUndo("Move", mapping: mapping, from: folder, to: destination)
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
    if isJunk && Preferences.bool(Preferences.junkMarkRead) {
      await setFlag(MessageFlag.seen, on: true, undoable: false)
    }
    if isJunk && Preferences.bool(Preferences.junkDelete) {
      await deleteSelected()
    } else if isJunk {
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

  func compactFolder(_ selection: FolderSelection) async {
    do {
      try await backends[selection.accountID]?.compact(selection.path)
    } catch {
      report(error, title: "Couldn't compact the folder")
    }
  }

  func compactAllFolders() async {
    activity = "Compacting folders…"
    defer { activity = nil }
    for account in accounts {
      for folder in (folders[account.id] ?? []) where folder.isSelectable {
        try? await backends[account.id]?.compact(folder.path)
      }
    }
  }

  /// Thunderbird's "Repair Folder": throw away the local summary and download it again.
  func repairFolder(_ selection: FolderSelection) async {
    await backends[selection.accountID]?.forgetCache(selection.path)
    if source == .folder(selection) {
      items = []
      await reloadSource()
    }
  }

  func setSubscribed(_ path: String, _ subscribed: Bool, accountID: UUID) async {
    do {
      try await backends[accountID]?.setSubscribed(path, subscribed)
      if let backend = backends[accountID] {
        folders[accountID] = try await backend.refreshFolders()
      }
    } catch {
      report(error, title: "Couldn't change the subscription")
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

  private func expandingLists(_ field: String) -> [MailAddress] {
    MailAddress.parseList(field).flatMap { address -> [MailAddress] in
      guard !address.email.contains("@"), let members = expandMailingList?(address.email), !members.isEmpty else { return [address] }
      return members
    }
  }

  private func outgoingMessage(_ draft: ComposeDraft, forDraft: Bool) throws -> (MailAccount, OutgoingMessage) {
    guard let (account, identity) = identity(for: draft) else {
      throw MailError.server("Set up an account before sending mail.")
    }
    var message = OutgoingMessage(
      from: draft.customFrom.flatMap { MailAddress.parseList($0).first } ?? identity.address,
      to: forDraft ? MailAddress.parseList(draft.to) : expandingLists(draft.to),
      cc: forDraft ? MailAddress.parseList(draft.cc) : expandingLists(draft.cc),
      bcc: forDraft ? MailAddress.parseList(draft.bcc) : expandingLists(draft.bcc),
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
    if draft.isHTML, let html = draft.htmlBody {
      let (rewritten, images) = Self.extractInlineImages(html, domain: identity.email)
      message.htmlBody = forDraft ? html : rewritten
      message.inlineImages = forDraft ? [] : images
    }
    switch draft.sendFormat {
    case .plain: message.plainTextOnly = true
    case .html: message.htmlOnly = draft.isHTML
    case .automatic, .both: break
    }
    message.newsgroups = draft.newsgroups.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
    let replyTo = MailAddress.parseList(draft.replyTo)
    message.replyTo = replyTo.isEmpty ? MailAddress.parseList(identity.replyTo) : replyTo
    if !draft.followupTo.isEmpty {
      message.extraHeaders.append(HeaderField(name: "Followup-To", value: draft.followupTo))
    }
    if !account.options.organization.isEmpty {
      message.extraHeaders.append(HeaderField(name: "Organization", value: account.options.organization))
    }
    message.bcc += MailAddress.parseList(account.options.bccAddresses)
    message.priority = draft.priority
    message.requestReturnReceipt = draft.requestReturnReceipt
    message.includeBccHeader = forDraft
    if !forDraft && (draft.encrypt || draft.sign) {
      message.security = OutgoingSecurity(
        technology: draft.securityTechnology ?? account.securityTechnology, sign: draft.sign, encrypt: draft.encrypt,
        signerKey: account.openPGPKeyID)
      message.protector = MessageSecurity()
      message.encryptSubject = draft.encryptSubject
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
    let rendered = try await MailSender.send(message, account: account, requestDSN: draft.requestDSN)
    if Preferences.bool(Preferences.collectAddresses) {
      onAddressesUsed?(message.allRecipients)
    }
    await afterSending(draft, account: account, rendered: rendered)
  }

  private func afterSending(_ draft: ComposeDraft, account: MailAccount, rendered: Data) async {
    let host = account.outgoing.host.lowercased()
    let serverSavesSent = host.hasSuffix("gmail.com") || host.hasSuffix("googlemail.com")
    let sentTarget =
      draft.copyToFolder.map { ($0.accountID, $0.path) } ?? folder(role: .sent, in: account.id).map { (account.id, $0.path) }
    if !serverSavesSent, account.kind != .nntp, account.kind != .ews, account.options.saveSentCopy || draft.copyToFolder != nil,
      let (accountID, path) = sentTarget
    {
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

  /// Turns data: URL images in composed HTML into cid: references with matching inline parts.
  static func extractInlineImages(_ html: String, domain email: String) -> (String, [InlineImage]) {
    let pattern = #"src\s*=\s*"data:([a-zA-Z0-9.+/-]+);base64,([A-Za-z0-9+/=\s]+)""#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return (html, []) }
    var images: [InlineImage] = []
    var output = html
    let domain = email.split(separator: "@").last.map(String.init) ?? "localhost"
    for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).reversed() {
      guard let whole = Range(match.range, in: html), let typeRange = Range(match.range(at: 1), in: html),
        let dataRange = Range(match.range(at: 2), in: html),
        let data = Data(base64Encoded: String(html[dataRange]), options: .ignoreUnknownCharacters)
      else { continue }
      let contentID = "part\(images.count + 1).\(UUID().uuidString.prefix(8))@\(domain)"
      images.append(InlineImage(contentID: contentID, mimeType: String(html[typeRange]), data: data))
      if let outputRange = output.range(of: String(html[whole])) {
        output.replaceSubrange(outputRange, with: "src=\"cid:\(contentID)\"")
      }
    }
    return (output, images)
  }

  /// File › Save As › File… from the composer.
  func renderForFile(_ draft: ComposeDraft) throws -> Data {
    let (account, message) = try outgoingMessage(draft, forDraft: false)
    var plain = message
    plain.security = nil
    return try plain.render(messageID: OutgoingMessage.makeMessageID(domainOf: account.email))
  }

  /// Saves the draft to the account's Drafts folder, replacing the previous copy. Returns the draft's Message-ID.
  @discardableResult
  func saveDraft(_ draft: ComposeDraft, asTemplate requestedTemplate: Bool = false) async throws -> String {
    let asTemplate = requestedTemplate || draft.editingTemplate
    let (account, message) = try outgoingMessage(draft, forDraft: true)
    let role: FolderRole = asTemplate ? .templates : .drafts
    let target: FolderSelection
    if asTemplate, let existing = draft.savedDraft, draft.editingTemplate {
      target = FolderSelection(accountID: existing.accountID, path: existing.path)
    } else if asTemplate, account.options.templatesFolder == nil, let localID = localFoldersID,
      let localAccount = self.account(localID)
    {
      // Templates live in Local Folders unless the account names its own Templates folder.
      target = try await ensureFolder(.templates, in: localAccount)
    } else {
      target = try await ensureFolder(role, in: account)
    }
    let messageID = (asTemplate ? nil : draft.draftMessageID) ?? OutgoingMessage.makeMessageID(domainOf: account.email)
    let data = try message.render(messageID: messageID)
    guard let backend = backends[target.accountID] else { throw MailError.connectionClosed }
    let previous = asTemplate ? [] : ((try? await backend.findMessage(messageID: messageID, in: target.path)) ?? [])
    try await backend.append(data, to: target.path, flags: [MessageFlag.seen, MessageFlag.draft])
    if !previous.isEmpty {
      try? await backend.delete(uids: previous, in: target.path)
    }
    if draft.editingTemplate, let template = draft.savedDraft {
      try? await backends[template.accountID]?.delete(uids: [template.uid], in: template.path)
    }
    if source == .folder(target) {
      await reloadSource()
    }
    if asTemplate { await reloadLocalTemplates() }
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
    if let existing = folders[owner]?.first(where: { $0.isSelectable && !$0.path.hasPrefix("Labels") && ($0.path.components(separatedBy: $0.delimiter ?? "/").last ?? "").caseInsensitiveCompare(name) == .orderedSame }) {
      return FolderSelection(accountID: owner, path: existing.path)
    }
    do {
      let path = try await backend.createFolder(name, parent: nil)
      folders[owner] = try await backend.refreshFolders()
      return FolderSelection(accountID: owner, path: path)
    } catch {
      // Some servers (Proton Mail Bridge) only allow new mailboxes inside a "Folders" parent.
      if let parent = folders[owner]?.first(where: { $0.path.caseInsensitiveCompare("Folders") == .orderedSame }),
        let path = try? await backend.createFolder(name, parent: parent.path)
      {
        folders[owner] = (try? await backend.refreshFolders()) ?? folders[owner]
        return FolderSelection(accountID: owner, path: path)
      }
      guard owner != localFoldersID, let localID = localFoldersID, let local = backends[localID] else { throw error }
      if let existing = folder(role: role, in: localID) {
        return FolderSelection(accountID: localID, path: existing.path)
      }
      let path = try await local.createFolder(name, parent: nil)
      folders[localID] = try await local.refreshFolders()
      return FolderSelection(accountID: localID, path: path)
    }
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
    await backend.updateSubscription(name, subscribed)
    folders[accountID] = await backend.cachedFolders()
  }

  /// Tools › Clear Recent History…
  func clearRecentHistory() {
    let alert = NSAlert()
    alert.messageText = "Clear Recent History"
    alert.informativeText = "This clears recent folders, Back/Forward history, the activity log and cached web content."
    alert.addButton(withTitle: "Clear Now")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    recentFolders = []
    UserDefaults.standard.removeObject(forKey: "recentFolders")
    history = []
    historyIndex = -1
    activityLog = []
    WKWebsiteDataStore.default().removeData(
      ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
  }

  // MARK: - Errors

  func report(_ error: Error, title: String) {
    if error is CancellationError { return }
    presentedError = PresentedError(title: title, message: error.localizedDescription)
  }
}
