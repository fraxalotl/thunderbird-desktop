/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import AppKit
import Foundation
import Observation
import ThunderbirdCore
import UniformTypeIdentifiers

struct FolderSelection: Hashable, Codable {
  var accountID: UUID
  var path: String
}

struct SidebarFolder: Identifiable, Hashable {
  var folder: RemoteFolder
  var depth: Int
  var id: String { folder.path }
}

struct LoadedMessage {
  var reference: MessageReference
  var summary: MessageSummary
  var parsed: ParsedMessage
  var account: MailAccount
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

enum Preferences {
  static let syncLimit = "syncLimit"
  static let checkInterval = "checkIntervalMinutes"
  static let allowRemoteContent = "allowRemoteContent"
  static let markReadOnOpen = "markReadOnOpen"

  static func register() {
    UserDefaults.standard.register(defaults: [
      syncLimit: 250,
      checkInterval: 10,
      allowRemoteContent: false,
      markReadOnOpen: true,
    ])
  }
}

@MainActor
@Observable
final class MailStore {
  private(set) var accounts: [MailAccount] = []
  private(set) var folders: [UUID: [RemoteFolder]] = [:]
  private(set) var messages: [MessageSummary] = []
  private(set) var reader: ReaderState = .empty
  private(set) var refreshing: Set<UUID> = []
  private(set) var activity: String?
  private(set) var accountErrors: [UUID: String] = [:]
  var presentedError: PresentedError?

  var searchText = ""
  var filterUnread = false
  var filterStarred = false
  var filterAttachments = false

  var selectedFolder: FolderSelection? {
    didSet {
      if oldValue != selectedFolder { folderDidChange() }
    }
  }

  var selectedMessageIDs: Set<UInt32> = [] {
    didSet {
      if oldValue != selectedMessageIDs { messageSelectionDidChange() }
    }
  }

  private var remoteContentAllowed: Set<MessageReference> = []
  @ObservationIgnored private var services: [UUID: AccountService] = [:]
  @ObservationIgnored private let cache = MailCache()
  @ObservationIgnored private var loadTask: Task<Void, Never>?
  @ObservationIgnored private var syncTask: Task<Void, Never>?
  @ObservationIgnored private var checkTask: Task<Void, Never>?

  private static let accountsKey = "accounts"

  init() {
    Preferences.register()
    if let data = UserDefaults.standard.data(forKey: Self.accountsKey),
      let stored = try? JSONDecoder().decode([MailAccount].self, from: data)
    {
      accounts = stored
    }
    for account in accounts {
      let service = AccountService(account: account, cache: cache)
      services[account.id] = service
      folders[account.id] = cache.folders(account: account.id) ?? []
    }
    if let first = accounts.first {
      selectedFolder = FolderSelection(accountID: first.id, path: inboxPath(for: first.id) ?? "INBOX")
      folderDidChange()
    }
    updateDockBadge()
    Task { await refreshAll() }
    scheduleChecks()
  }

  // MARK: - Lookups

  func account(_ id: UUID?) -> MailAccount? {
    accounts.first { $0.id == id }
  }

  var currentAccount: MailAccount? { account(selectedFolder?.accountID) }

  var currentFolder: RemoteFolder? {
    guard let selection = selectedFolder else { return nil }
    return folders[selection.accountID]?.first { $0.path == selection.path }
  }

  private func folder(role: FolderRole, in accountID: UUID) -> RemoteFolder? {
    folders[accountID]?.first { $0.role == role && $0.isSelectable }
  }

  private func inboxPath(for accountID: UUID) -> String? {
    folder(role: .inbox, in: accountID)?.path
  }

  func hasFolder(_ role: FolderRole) -> Bool {
    guard let selection = selectedFolder else { return false }
    return folder(role: role, in: selection.accountID).map { $0.path != selection.path } ?? false
  }

  var filteredMessages: [MessageSummary] {
    let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
    return messages.filter { message in
      if filterUnread && message.isRead { return false }
      if filterStarred && !message.isFlagged { return false }
      if filterAttachments && !message.hasAttachment { return false }
      guard !query.isEmpty else { return true }
      if message.subject.lowercased().contains(query) { return true }
      return (message.from + message.to + message.cc).contains {
        $0.email.lowercased().contains(query) || ($0.name?.lowercased().contains(query) ?? false)
      }
    }
  }

  var isFiltering: Bool {
    filterUnread || filterStarred || filterAttachments || !searchText.trimmingCharacters(in: .whitespaces).isEmpty
  }

  var selectedSummaries: [MessageSummary] {
    messages.filter { selectedMessageIDs.contains($0.uid) }
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

  // MARK: - Syncing

  func refreshAll() async {
    await withTaskGroup(of: Void.self) { group in
      for account in accounts {
        group.addTask { await self.refresh(accountID: account.id) }
      }
    }
  }

  func refresh(accountID: UUID) async {
    guard let service = services[accountID], !refreshing.contains(accountID) else { return }
    refreshing.insert(accountID)
    defer { refreshing.remove(accountID) }
    do {
      folders[accountID] = try await service.refreshFolders()
      if let selection = selectedFolder, selection.accountID == accountID {
        if folders[accountID]?.contains(where: { $0.path == selection.path }) == false,
          let inbox = inboxPath(for: accountID)
        {
          selectedFolder = FolderSelection(accountID: accountID, path: inbox)
        } else {
          await syncSelectedFolder()
        }
      }
      accountErrors[accountID] = nil
      updateDockBadge()
    } catch {
      if !(error is CancellationError) {
        accountErrors[accountID] = error.localizedDescription
      }
    }
  }

  func syncSelectedFolder() async {
    guard let selection = selectedFolder, let service = services[selection.accountID] else { return }
    activity = "Downloading messages…"
    defer { activity = nil }
    do {
      let limit = UserDefaults.standard.integer(forKey: Preferences.syncLimit)
      let updated = try await service.sync(path: selection.path, limit: max(50, limit))
      guard selectedFolder == selection else { return }
      messages = updated
      selectedMessageIDs.formIntersection(updated.map(\.uid))
      updateUnseenCount(selection) { _ in updated.filter { !$0.isRead }.count }
      accountErrors[selection.accountID] = nil
    } catch {
      guard selectedFolder == selection, !(error is CancellationError) else { return }
      accountErrors[selection.accountID] = error.localizedDescription
    }
  }

  private func folderDidChange() {
    syncTask?.cancel()
    selectedMessageIDs = []
    reader = .empty
    guard let selection = selectedFolder else {
      messages = []
      return
    }
    messages = []
    if let service = services[selection.accountID] {
      syncTask = Task {
        let cached = await service.cachedMessages(in: selection.path)
        if selectedFolder == selection && messages.isEmpty {
          messages = cached
        }
        await syncSelectedFolder()
      }
    }
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
    let unread = accounts.compactMap { folder(role: .inbox, in: $0.id)?.unseen }.reduce(0, +)
    NSApp?.dockTile.badgeLabel = unread > 0 ? "\(unread)" : nil
  }

  // MARK: - Reading

  private func messageSelectionDidChange() {
    loadTask?.cancel()
    switch selectedMessageIDs.count {
    case 0:
      reader = .empty
    case 1:
      load(uid: selectedMessageIDs.first!)
    default:
      reader = .multiple(selectedMessageIDs.count)
    }
  }

  private func load(uid: UInt32) {
    guard let selection = selectedFolder, let service = services[selection.accountID],
      let account = account(selection.accountID), let summary = messages.first(where: { $0.uid == uid })
    else { return }
    let reference = MessageReference(accountID: selection.accountID, path: selection.path, uid: uid)
    if case .loaded(let current) = reader, current.reference == reference { return }
    reader = .loading
    loadTask = Task {
      do {
        let data = try await service.message(uid: uid, in: selection.path)
        let parsed = await Task.detached(priority: .userInitiated) { ParsedMessage(data: data) }.value
        guard !Task.isCancelled, selectedMessageIDs == [uid], selectedFolder == selection else { return }
        reader = .loaded(LoadedMessage(reference: reference, summary: summary, parsed: parsed, account: account))
        if !summary.isRead && UserDefaults.standard.bool(forKey: Preferences.markReadOnOpen) {
          await setFlag(MessageFlag.seen, on: true, uids: [uid])
        }
      } catch {
        guard !Task.isCancelled, selectedMessageIDs == [uid] else { return }
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

  private var actionTargets: [UInt32] { Array(selectedMessageIDs) }

  func setFlag(_ flag: String, on: Bool, uids: [UInt32]? = nil) async {
    guard let selection = selectedFolder, let service = services[selection.accountID] else { return }
    let targets = uids ?? actionTargets
    guard !targets.isEmpty else { return }
    let set = Set(targets)
    var unseenDelta = 0
    for index in messages.indices where set.contains(messages[index].uid) {
      let had = messages[index].flags.contains(flag)
      if on {
        messages[index].flags.insert(flag)
      } else {
        messages[index].flags.remove(flag)
      }
      if flag == MessageFlag.seen && had != on {
        unseenDelta += on ? -1 : 1
      }
    }
    if case .loaded(var loaded) = reader, set.contains(loaded.summary.uid) {
      if on { loaded.summary.flags.insert(flag) } else { loaded.summary.flags.remove(flag) }
      reader = .loaded(loaded)
    }
    if unseenDelta != 0 {
      updateUnseenCount(selection) { $0 + unseenDelta }
    }
    do {
      try await service.setFlag(flag, on: on, uids: targets, in: selection.path)
    } catch {
      report(error, title: "Couldn't update the message")
    }
  }

  func toggleRead() async {
    let allRead = selectedSummaries.allSatisfy(\.isRead)
    await setFlag(MessageFlag.seen, on: !allRead)
  }

  func toggleStar() async {
    let allStarred = selectedSummaries.allSatisfy(\.isFlagged)
    await setFlag(MessageFlag.flagged, on: !allStarred)
  }

  func deleteSelected() async {
    guard let selection = selectedFolder, let service = services[selection.accountID] else { return }
    let targets = actionTargets
    guard !targets.isEmpty else { return }
    let trash = folder(role: .trash, in: selection.accountID)
    removeFromList(targets)
    do {
      if let trash, trash.path != selection.path {
        try await service.move(uids: targets, from: selection.path, to: trash.path)
      } else {
        try await service.delete(uids: targets, in: selection.path)
      }
    } catch {
      report(error, title: "Couldn't delete the message")
      await syncSelectedFolder()
    }
  }

  func moveSelected(to role: FolderRole) async {
    guard let selection = selectedFolder, let service = services[selection.accountID],
      let destination = folder(role: role, in: selection.accountID)
    else { return }
    let targets = actionTargets
    guard !targets.isEmpty else { return }
    removeFromList(targets)
    do {
      try await service.move(uids: targets, from: selection.path, to: destination.path)
    } catch {
      report(error, title: "Couldn't move the message")
      await syncSelectedFolder()
    }
  }

  /// Removes messages from the list and selects the one that took their place, as Thunderbird does.
  private func removeFromList(_ uids: [UInt32]) {
    let set = Set(uids)
    let visible = filteredMessages
    let firstIndex = visible.firstIndex { set.contains($0.uid) } ?? 0
    let remaining = visible.filter { !set.contains($0.uid) }
    let unreadRemoved = messages.filter { set.contains($0.uid) && !$0.isRead }.count
    messages.removeAll { set.contains($0.uid) }
    if let selection = selectedFolder, unreadRemoved > 0 {
      updateUnseenCount(selection) { $0 - unreadRemoved }
    }
    if remaining.isEmpty {
      selectedMessageIDs = []
    } else {
      selectedMessageIDs = [remaining[min(firstIndex, remaining.count - 1)].uid]
    }
  }

  // MARK: - Composing

  func newDraft(to address: String = "") -> ComposeDraft {
    ComposeDraft.new(account: currentAccount ?? accounts.first, to: address)
  }

  func replyDraft(all: Bool) -> ComposeDraft? {
    guard let loaded = loadedMessage else { return nil }
    return ComposeDraft.reply(to: loaded.parsed, reference: loaded.reference, account: loaded.account, all: all)
  }

  func forwardDraft() -> ComposeDraft? {
    guard let loaded = loadedMessage else { return nil }
    let urls = loaded.parsed.attachments.compactMap { try? AttachmentFiles.temporaryURL(for: $0) }
    return ComposeDraft.forward(loaded.parsed, reference: loaded.reference, account: loaded.account, attachments: urls)
  }

  func send(_ draft: ComposeDraft) async throws {
    guard let account = account(draft.accountID) ?? accounts.first, let service = services[account.id] else {
      throw MailError.server("Set up an account before sending mail.")
    }
    let message = OutgoingMessage(
      from: account.address,
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
          data: try Data(contentsOf: url)
        )
      }
    )
    guard !message.allRecipients.isEmpty else { throw MailError.invalidRecipients }

    activity = "Sending message…"
    defer { activity = nil }
    let rendered = try await service.send(message)

    let host = account.outgoing.host.lowercased()
    let serverSavesSent = host.hasSuffix("gmail.com") || host.hasSuffix("googlemail.com")
    if !serverSavesSent, let sent = folder(role: .sent, in: account.id) {
      try? await service.append(rendered, to: sent.path, flags: [MessageFlag.seen])
    }
    if let source = draft.source, let sourceService = services[source.accountID] {
      let flag = draft.kind == .forward ? MessageFlag.forwarded : MessageFlag.answered
      try? await sourceService.setFlag(flag, on: true, uids: [source.uid], in: source.path)
      if let index = messages.firstIndex(where: { $0.uid == source.uid }), selectedFolder?.path == source.path {
        messages[index].flags.insert(flag)
      }
    }
    if let selection = selectedFolder, folders[account.id]?.first(where: { $0.path == selection.path })?.role == .sent {
      await syncSelectedFolder()
    }
  }

  // MARK: - Accounts

  private func persistAccounts() {
    if let data = try? JSONEncoder().encode(accounts) {
      UserDefaults.standard.set(data, forKey: Self.accountsKey)
    }
  }

  func addAccount(_ account: MailAccount, incomingPassword: String, outgoingPassword: String) throws {
    try Keychain.setPassword(incomingPassword, for: account.incomingKeychainKey)
    try Keychain.setPassword(outgoingPassword, for: account.outgoingKeychainKey)
    accounts.append(account)
    persistAccounts()
    services[account.id] = AccountService(account: account, cache: cache)
    folders[account.id] = []
    Task {
      await refresh(accountID: account.id)
      if selectedFolder == nil || selectedFolder?.accountID == account.id {
        selectedFolder = FolderSelection(accountID: account.id, path: inboxPath(for: account.id) ?? "INBOX")
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
    let previous = accounts[index]
    accounts[index] = account
    persistAccounts()
    if previous.incoming != account.incoming || incomingPassword?.isEmpty == false {
      let old = services[account.id]
      Task { await old?.disconnect() }
    }
    services[account.id] = AccountService(account: account, cache: cache)
    Task { await refresh(accountID: account.id) }
  }

  func removeAccount(_ id: UUID) {
    guard let account = account(id) else { return }
    let service = services.removeValue(forKey: id)
    Task { await service?.disconnect() }
    Keychain.deletePassword(for: account.incomingKeychainKey)
    Keychain.deletePassword(for: account.outgoingKeychainKey)
    cache.removeAccount(id)
    accounts.removeAll { $0.id == id }
    folders[id] = nil
    persistAccounts()
    if selectedFolder?.accountID == id {
      selectedFolder = accounts.first.map { FolderSelection(accountID: $0.id, path: inboxPath(for: $0.id) ?? "INBOX") }
    }
    updateDockBadge()
  }

  // MARK: - Errors

  func report(_ error: Error, title: String) {
    if error is CancellationError { return }
    presentedError = PresentedError(title: title, message: error.localizedDescription)
  }
}
