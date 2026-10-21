/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import AppKit
import SwiftUI
import ThunderbirdCore

/// Thunderbird's folder pane modes (View › Folders).
enum FolderMode: String, CaseIterable, Identifiable {
  case all, unified, unread, favorite, recent, tags
  var id: String { rawValue }

  var title: String {
    switch self {
    case .all: "All Folders"
    case .unified: "Unified Folders"
    case .unread: "Unread Folders"
    case .favorite: "Favorite Folders"
    case .recent: "Recent Folders"
    case .tags: "Tags"
    }
  }
}

/// Folder pane settings shared by the sidebar and the View menu.
enum FolderPanePreferences {
  static let modes = "folderModes"
  static let compact = "folderCompactView"
  static let header = "folderPaneHeader"
  static let collapsed = "collapsedFolders"

  static func enabledModes(_ raw: String) -> Set<FolderMode> {
    let modes = Set(raw.split(separator: ",").compactMap { FolderMode(rawValue: String($0)) })
    return modes.isEmpty ? [.all] : modes
  }

  static func toggled(_ mode: FolderMode, in raw: String) -> String {
    var modes = enabledModes(raw)
    if modes.contains(mode) { modes.remove(mode) } else { modes.insert(mode) }
    if modes.isEmpty { modes = [.all] }
    return FolderMode.allCases.filter(modes.contains).map(\.rawValue).joined(separator: ",")
  }
}

struct FolderSidebar: View {
  @Environment(MailStore.self) private var store
  @Environment(MailUIState.self) private var ui
  @Environment(\.openSettings) private var openSettings
  @Environment(\.openWindow) private var openWindow
  let onAddAccount: () -> Void
  let onNewFolder: (FolderSelection) -> Void
  @AppStorage(FolderPanePreferences.modes) private var modesRaw = "all"
  @AppStorage(FolderPanePreferences.compact) private var compact = false
  @AppStorage(FolderPanePreferences.header) private var showHeader = true
  @AppStorage(FolderPanePreferences.collapsed) private var collapsedRaw = ""
  @State private var renaming: FolderSelection?
  @State private var newName = ""
  @State private var deleting: FolderSelection?
  @State private var subscribingAccount: UUID?
  @State private var subscribingIMAP: UUID?
  @State private var properties: FolderSelection?

  private let unifiedRoles: [FolderRole] = [.inbox, .drafts, .templates, .sent, .archive, .junk, .trash]

  private var modes: Set<FolderMode> { FolderPanePreferences.enabledModes(modesRaw) }

  private var collapsed: Set<String> {
    Set(collapsedRaw.split(separator: "\n").map(String.init))
  }

  private func expansion(_ key: String) -> Binding<Bool> {
    Binding(
      get: { !collapsed.contains(key) },
      set: { expanded in
        var set = collapsed
        if expanded { set.remove(key) } else { set.insert(key) }
        collapsedRaw = set.sorted().joined(separator: "\n")
      })
  }

  var body: some View {
    @Bindable var store = store
    List(selection: $store.source) {
      if modes.contains(.unified) {
        Section("Unified Folders", isExpanded: expansion("section:unified")) {
          ForEach(unifiedRoles, id: \.self) { role in
            Label(role.unifiedTitle, systemImage: role.symbolName)
              .badge(role == .inbox ? store.unifiedUnread(.inbox) : 0)
              .tag(MailboxSource.unified(role))
          }
        }
      }

      if modes.contains(.favorite) {
        Section("Favorite Folders", isExpanded: expansion("section:favorite")) {
          ForEach(store.favoriteFolders.filter { store.folder($0) != nil }, id: \.self) { selection in
            flatRow(selection)
          }
        }
      }

      if modes.contains(.unread) {
        Section("Unread Folders", isExpanded: expansion("section:unread")) {
          ForEach(unreadFolders, id: \.self) { selection in
            flatRow(selection)
          }
        }
      }

      if modes.contains(.recent) {
        Section("Recent Folders", isExpanded: expansion("section:recent")) {
          ForEach(store.recentFolders.filter { store.folder($0) != nil }.prefix(15), id: \.self) { selection in
            flatRow(selection)
          }
        }
      }

      if modes.contains(.tags) {
        Section("Tags", isExpanded: expansion("section:tags")) {
          ForEach(MessageTagStore.shared.tags) { tag in
            Label {
              Text(tag.name)
            } icon: {
              Image(systemName: "tag.fill").foregroundStyle(Color(hex: tag.colorHex))
            }
            .tag(MailboxSource.tag(tag.keyword))
          }
        }
      }

      if modes.contains(.all) {
        ForEach(store.mailAccounts) { account in
          Section(isExpanded: expansion("account:\(account.id.uuidString)")) {
            if compact {
              ForEach(store.sidebarFolders(for: account.id)) { item in
                folderRow(account: account, folder: item.folder)
              }
            } else {
              ForEach(store.folderTree(for: account.id)) { node in
                FolderTreeRow(node: node, account: account, expansion: expansion) { folder in
                  AnyView(folderRow(account: account, folder: folder))
                }
              }
            }
          } header: {
            AccountHeader(
              account: account,
              onSubscribe: {
                switch account.kind {
                case .nntp: subscribingAccount = account.id
                case .feed: ui.present(.feedSubscriptions(account.id))
                default: subscribingIMAP = account.id
                }
              },
              onNewFolder: { onNewFolder(FolderSelection(accountID: account.id, path: "")) })
          }
        }
      }

      if !store.savedSearches.isEmpty {
        Section("Saved Searches", isExpanded: expansion("section:saved")) {
          ForEach(store.savedSearches) { search in
            Label(search.name, systemImage: "magnifyingglass.circle")
              .tag(MailboxSource.savedSearch(search.id))
              .contextMenu {
                Button("Delete Saved Search", role: .destructive) { store.deleteSavedSearch(search.id) }
              }
          }
        }
      }
    }
    .listStyle(.sidebar)
    .safeAreaInset(edge: .top) {
      if showHeader {
        FolderPaneHeader(modesRaw: $modesRaw, compact: $compact, onNewMessage: {
          openWindow(id: WindowID.compose, value: store.newDraft())
        })
      }
    }
    .safeAreaInset(edge: .bottom) {
      HStack {
        Button(action: onAddAccount) {
          Label("Add Account", systemImage: "plus")
        }
        .buttonStyle(.glass)
        Spacer()
        Button {
          openSettings()
        } label: {
          Label("Account Settings", systemImage: "gearshape")
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.glass)
        .help("Account Settings")
      }
      .controlSize(.small)
      .padding(12)
    }
    .alert("Rename Folder", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
      TextField("Name", text: $newName)
      Button("Rename") {
        if let renaming { Task { await store.renameFolder(renaming, to: newName) } }
      }
      Button("Cancel", role: .cancel) {}
    }
    .confirmationDialog(
      "Delete “\(deleting.flatMap { store.folder($0)?.displayName } ?? "")”?",
      isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    ) {
      Button("Delete Folder", role: .destructive) {
        if let deleting { Task { await store.deleteFolder(deleting) } }
      }
    } message: {
      Text("The folder and all the messages in it will be deleted.")
    }
    .sheet(item: $subscribingAccount) { accountID in
      NewsgroupSubscribeView(accountID: accountID)
    }
    .sheet(item: $subscribingIMAP) { accountID in
      IMAPSubscribeView(accountID: accountID)
    }
    .sheet(item: $properties) { selection in
      FolderPropertiesView(selection: selection)
    }
  }

  private var unreadFolders: [FolderSelection] {
    store.mailAccounts.flatMap { account in
      (store.folders[account.id] ?? []).filter { ($0.unseen ?? 0) > 0 && $0.role != .trash && $0.role != .junk }
        .map { FolderSelection(accountID: account.id, path: $0.path) }
    }
  }

  @ViewBuilder
  private func flatRow(_ selection: FolderSelection) -> some View {
    if let account = store.account(selection.accountID), let folder = store.folder(selection) {
      folderRow(account: account, folder: folder, subtitle: account.label)
    }
  }

  private func folderRow(account: MailAccount, folder: RemoteFolder, subtitle: String? = nil) -> some View {
    let selection = FolderSelection(accountID: account.id, path: folder.path)
    return FolderRow(folder: folder, subtitle: subtitle, isFavorite: store.isFavorite(selection))
      .tag(MailboxSource.folder(selection))
      .selectionDisabled(!folder.isSelectable)
      .dropDestination(for: MessageDragPayload.self) { payloads, _ in
        let references = payloads.flatMap(\.references)
        let copy = NSEvent.modifierFlags.contains(.option)
        Task { await store.transfer(references, to: selection, copy: copy) }
        return !references.isEmpty
      }
      .contextMenu { folderMenu(account: account, folder: folder, selection: selection) }
  }

  @ViewBuilder
  private func folderMenu(account: MailAccount, folder: RemoteFolder, selection: FolderSelection) -> some View {
    Button("Get Messages") { Task { await store.refresh(accountID: account.id) } }
    Button("Mark Folder Read") { Task { await store.markFolderRead(selection) } }
    Button(store.isFavorite(selection) ? "Remove from Favorites" : "Favorite Folder") { store.toggleFavorite(selection) }
    if folder.role == .trash || folder.role == .junk {
      Button(folder.role == .trash ? "Empty Trash" : "Empty Spam", role: .destructive) {
        Task { await store.emptyFolder(selection) }
      }
    }
    if account.kind == .nntp {
      Button("Unsubscribe", role: .destructive) {
        Task { await store.setNewsgroup(folder.path, subscribed: false, accountID: account.id) }
      }
    } else {
      Button("Compact") { Task { await store.compactFolder(selection) } }
      Divider()
      Button("New Subfolder…") { onNewFolder(selection) }
      if folder.role == .normal {
        Button("Rename…") {
          newName = folder.displayName
          renaming = selection
        }
        Button("Delete…", role: .destructive) { deleting = selection }
      }
      if account.kind == .imap {
        Button("Subscribe…") { subscribingIMAP = account.id }
      }
    }
    Divider()
    Button("Properties…") { properties = selection }
  }
}

extension FolderRole {
  var unifiedTitle: String {
    switch self {
    case .inbox: "Inbox"
    case .junk: "Spam"
    case .archive: "Archives"
    default: rawValue.capitalized
    }
  }
}

extension UUID: @retroactive Identifiable {
  public var id: UUID { self }
}

/// A folder with collapsible subfolders.
private struct FolderTreeRow: View {
  let node: FolderNode
  let account: MailAccount
  let expansion: (String) -> Binding<Bool>
  let row: (RemoteFolder) -> AnyView

  var body: some View {
    if let children = node.children {
      DisclosureGroup(isExpanded: expansion("folder:\(account.id.uuidString):\(node.folder.path)")) {
        ForEach(children) { child in
          FolderTreeRow(node: child, account: account, expansion: expansion, row: row)
        }
      } label: {
        row(node.folder)
      }
    } else {
      row(node.folder)
    }
  }
}

private struct FolderPaneHeader: View {
  @Environment(MailStore.self) private var store
  @Binding var modesRaw: String
  @Binding var compact: Bool
  let onNewMessage: () -> Void

  var body: some View {
    GlassEffectContainer(spacing: 6) {
      HStack(spacing: 6) {
        Button {
          Task { await store.refreshAll() }
        } label: {
          Image(systemName: "arrow.down.circle")
        }
        .help("Get Messages")
        .accessibilityLabel("Get Messages")
        Button(action: onNewMessage) {
          Label("New Message", systemImage: "plus")
            .fixedSize()
        }
        .buttonStyle(.glassProminent)
        .disabled(store.sendingAccounts.isEmpty)
        Spacer(minLength: 0)
        Menu {
          ForEach(FolderMode.allCases) { mode in
            Toggle(
              mode.title,
              isOn: Binding(
                get: { FolderPanePreferences.enabledModes(modesRaw).contains(mode) },
                set: { _ in modesRaw = FolderPanePreferences.toggled(mode, in: modesRaw) }))
          }
          Divider()
          Toggle("Compact View", isOn: $compact)
        } label: {
          Image(systemName: "ellipsis")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Folder pane options")
      }
      .buttonStyle(.glass)
      .controlSize(.small)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
  }
}

private struct AccountHeader: View {
  @Environment(MailStore.self) private var store
  let account: MailAccount
  let onSubscribe: () -> Void
  let onNewFolder: () -> Void

  var body: some View {
    HStack(spacing: 6) {
      Text(account.label)
        .lineLimit(1)
      Spacer()
      if store.refreshing.contains(account.id) {
        ProgressView()
          .controlSize(.mini)
      } else if let error = store.accountErrors[account.id] {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.yellow)
          .help(error)
      }
    }
    .contextMenu {
      if account.kind != .local {
        Button("Get Messages") { Task { await store.refresh(accountID: account.id) } }
      }
      if account.kind == .nntp {
        Button("Subscribe to Newsgroups…", action: onSubscribe)
      } else {
        Button("New Folder…", action: onNewFolder)
        if account.kind == .imap || account.kind == .feed {
          Button("Subscribe…", action: onSubscribe)
        }
      }
    }
  }
}

private struct FolderRow: View {
  let folder: RemoteFolder
  var subtitle: String?
  var isFavorite = false

  var body: some View {
    Label {
      HStack(spacing: 4) {
        Text(folder.displayName)
          .fontWeight((folder.unseen ?? 0) > 0 && folder.role != .trash && folder.role != .junk ? .semibold : .regular)
          .lineLimit(1)
        if let subtitle {
          Text(subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
    } icon: {
      Image(systemName: isFavorite && folder.role == .normal ? "star.square" : folder.role.symbolName)
    }
    .foregroundStyle(folder.isSelectable ? .primary : .secondary)
    .badge([.trash, .junk, .sent, .drafts, .templates].contains(folder.role) ? 0 : folder.unseen ?? 0)
  }
}

struct NewsgroupSubscribeView: View {
  @Environment(MailStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  let accountID: UUID
  @State private var pattern = ""
  @State private var groups: [NewsgroupInfo] = []
  @State private var loading = false
  @State private var error: String?

  private var subscribed: Set<String> { Set((store.folders[accountID] ?? []).map(\.path)) }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Subscribe to Newsgroups")
        .font(.title3.weight(.semibold))
      HStack {
        TextField("Show groups matching, e.g. comp.lang.*", text: $pattern)
          .textFieldStyle(.roundedBorder)
          .onSubmit { Task { await load() } }
        Button("Search") { Task { await load() } }
          .buttonStyle(.glass)
      }
      List(groups) { group in
        Toggle(
          isOn: Binding(
            get: { subscribed.contains(group.name) },
            set: { value in Task { await store.setNewsgroup(group.name, subscribed: value, accountID: accountID) } })
        ) {
          HStack {
            Text(group.name)
            Spacer()
            Text("\(group.estimatedCount) articles")
              .foregroundStyle(.secondary)
              .font(.caption)
          }
        }
      }
      .overlay {
        if loading {
          ProgressView()
        } else if let error {
          ContentUnavailableView("Couldn't List Groups", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if groups.isEmpty {
          ContentUnavailableView("Search for Newsgroups", systemImage: "newspaper", description: Text("Enter a pattern such as gmane.* and press Return."))
        }
      }
      HStack {
        Spacer()
        Button("Done") {
          Task { await store.refresh(accountID: accountID) }
          dismiss()
        }
        .buttonStyle(.glassProminent)
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 560, height: 520)
  }

  private func load() async {
    guard let backend = store.backend(accountID) as? NNTPBackend else { return }
    loading = true
    error = nil
    defer { loading = false }
    do {
      let wildcard = pattern.trimmingCharacters(in: .whitespaces)
      groups = try await backend.availableGroups(matching: wildcard.isEmpty ? "*" : (wildcard.contains("*") ? wildcard : "*\(wildcard)*"))
        .sorted { $0.name < $1.name }
    } catch {
      self.error = error.localizedDescription
    }
  }
}
