/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import AppKit
import SwiftUI
import ThunderbirdCore

struct FolderSidebar: View {
  @Environment(MailStore.self) private var store
  @Environment(\.openSettings) private var openSettings
  let onAddAccount: () -> Void
  let onNewFolder: (FolderSelection) -> Void
  @State private var renaming: FolderSelection?
  @State private var newName = ""
  @State private var deleting: FolderSelection?
  @State private var subscribingAccount: UUID?

  private let unifiedRoles: [FolderRole] = [.inbox, .drafts, .sent, .archive, .junk, .trash]

  var body: some View {
    @Bindable var store = store
    List(selection: $store.source) {
      if store.accounts.filter({ $0.kind == .imap || $0.kind == .pop3 }).count > 1 {
        Section("Unified Folders") {
          ForEach(unifiedRoles, id: \.self) { role in
            Label(role == .inbox ? "Inbox" : role.rawValue.capitalized, systemImage: role.symbolName)
              .badge(role == .inbox ? store.unifiedUnread(.inbox) : 0)
              .tag(MailboxSource.unified(role))
          }
        }
      }

      ForEach(store.mailAccounts) { account in
        Section {
          ForEach(store.sidebarFolders(for: account.id)) { item in
            let selection = FolderSelection(accountID: account.id, path: item.folder.path)
            FolderRow(item: item)
              .tag(MailboxSource.folder(selection))
              .selectionDisabled(!item.folder.isSelectable)
              .dropDestination(for: MessageDragPayload.self) { payloads, _ in
                let references = payloads.flatMap(\.references)
                let copy = NSEvent.modifierFlags.contains(.option)
                Task { await store.transfer(references, to: selection, copy: copy) }
                return !references.isEmpty
              }
              .contextMenu { folderMenu(account: account, folder: item.folder, selection: selection) }
          }
        } header: {
          AccountHeader(account: account, onSubscribe: { subscribingAccount = account.id }, onNewFolder: {
            onNewFolder(FolderSelection(accountID: account.id, path: ""))
          })
        }
      }

      if !store.savedSearches.isEmpty {
        Section("Saved Searches") {
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
  }

  @ViewBuilder
  private func folderMenu(account: MailAccount, folder: RemoteFolder, selection: FolderSelection) -> some View {
    Button("Get Messages") { Task { await store.refresh(accountID: account.id) } }
    Button("Mark Folder Read") { Task { await store.markFolderRead(selection) } }
    if folder.role == .trash || folder.role == .junk {
      Button(folder.role == .trash ? "Empty Trash" : "Empty Junk", role: .destructive) {
        Task { await store.emptyFolder(selection) }
      }
    }
    if account.kind == .nntp {
      Button("Unsubscribe", role: .destructive) {
        Task { await store.setNewsgroup(folder.path, subscribed: false, accountID: account.id) }
      }
    } else {
      Divider()
      Button("New Subfolder…") { onNewFolder(selection) }
      if folder.role == .normal {
        Button("Rename…") {
          newName = folder.displayName
          renaming = selection
        }
        Button("Delete…", role: .destructive) { deleting = selection }
      }
    }
  }
}

extension UUID: @retroactive Identifiable {
  public var id: UUID { self }
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
      }
    }
  }
}

private struct FolderRow: View {
  let item: SidebarFolder

  var body: some View {
    let folder = item.folder
    Label {
      Text(folder.displayName)
        .fontWeight((folder.unseen ?? 0) > 0 && folder.role != .trash && folder.role != .junk ? .semibold : .regular)
        .lineLimit(1)
    } icon: {
      Image(systemName: folder.role.symbolName)
    }
    .padding(.leading, CGFloat(item.depth) * 14)
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
