/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import SwiftUI
import ThunderbirdCore

enum AppSpace: String, CaseIterable, Identifiable {
  case mail, addressBook, calendar, tasks, chat
  var id: String { rawValue }

  var title: String {
    switch self {
    case .mail: "Mail"
    case .addressBook: "Address Book"
    case .calendar: "Calendar"
    case .tasks: "Tasks"
    case .chat: "Chat"
    }
  }

  var symbol: String {
    switch self {
    case .mail: "envelope"
    case .addressBook: "person.crop.rectangle.stack"
    case .calendar: "calendar"
    case .tasks: "checklist"
    case .chat: "bubble.left.and.bubble.right"
    }
  }
}

struct MainWindow: View {
  @Environment(MailStore.self) private var mail
  @Environment(ChatStore.self) private var chat
  @Environment(\.openWindow) private var openWindow
  @SceneStorage("space") private var space = AppSpace.mail

  var body: some View {
    @Bindable var mail = mail
    Group {
      switch space {
      case .mail: MailSpace()
      case .addressBook: AddressBookSpace()
      case .calendar: CalendarSpace()
      case .tasks: TasksSpace()
      case .chat: ChatSpace()
      }
    }
    .toolbar {
      ToolbarItem(placement: .navigation) {
        Picker("Space", selection: $space) {
          ForEach(AppSpace.allCases) { space in
            Label(space.title, systemImage: space.symbol)
              .labelStyle(.iconOnly)
              .help(space.title)
              .tag(space)
          }
        }
        .pickerStyle(.segmented)
        .badge(chat.totalUnread)
      }
    }
    .overlay(alignment: .bottom) {
      if let activity = mail.activity {
        ActivityPill(text: activity)
          .padding(.bottom, 16)
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .animation(.smooth, value: mail.activity)
    .alert(item: $mail.presentedError) { error in
      Alert(title: Text(error.title), message: Text(error.message))
    }
    .onOpenURL { url in
      guard url.scheme?.lowercased() == "mailto" else { return }
      openWindow(id: WindowID.compose, value: mail.newDraft(to: MailtoLink.address(url)))
    }
    .onChange(of: chat.totalUnread) { _, unread in
      NSApp.dockTile.badgeLabel = mail.unifiedUnread(.inbox) + unread > 0 ? "\(mail.unifiedUnread(.inbox) + unread)" : nil
    }
  }
}

enum MailtoLink {
  static func address(_ url: URL) -> String {
    let address = url.absoluteString.dropFirst("mailto:".count).split(separator: "?").first.map(String.init) ?? ""
    return address.removingPercentEncoding ?? address
  }
}

struct MailSpace: View {
  @Environment(MailStore.self) private var store
  @Environment(\.openWindow) private var openWindow
  @AppStorage(Preferences.showTodayPane) private var showTodayPane = false
  @State private var showingAccountSetup = false
  @State private var showingSearch = false
  @State private var showingSource = false
  @State private var newFolderParent: FolderSelection?
  @State private var reader = ReaderController()
  @State private var columnVisibility = NavigationSplitViewVisibility.all

  var body: some View {
    @Bindable var store = store
    Group {
      if !store.accounts.contains(where: { $0.kind != .local }) {
        WelcomeView(onSetUp: { showingAccountSetup = true })
      } else {
        NavigationSplitView(columnVisibility: $columnVisibility) {
          FolderSidebar(
            onAddAccount: { showingAccountSetup = true },
            onNewFolder: { newFolderParent = $0 })
            .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 380)
        } content: {
          MessageListView()
            .navigationSplitViewColumnWidth(min: 320, ideal: 420)
        } detail: {
          MessageReaderView()
        }
        .searchable(text: $store.searchText, placement: .toolbar, prompt: "Quick Filter")
        .toolbar { toolbar }
        .inspector(isPresented: $showTodayPane) {
          TodayPane()
            .inspectorColumnWidth(min: 220, ideal: 260, max: 340)
        }
      }
    }
    .environment(reader)
    .focusedSceneValue(
      \.mailSpaceActions,
      MailSpaceActions(
        newFolder: { newFolderParent = store.selectedFolder },
        search: { showingSearch = true },
        viewSource: { showingSource = true },
        print: { reader.print() }))
    .sheet(isPresented: $showingAccountSetup) {
      AccountSetupView()
    }
    .sheet(isPresented: $showingSearch) {
      SearchView()
    }
    .sheet(isPresented: $showingSource) {
      if let loaded = store.loadedMessage {
        MessageSourceView(data: loaded.raw)
      }
    }
    .sheet(item: $newFolderParent) { parent in
      NewFolderSheet(parent: parent)
    }
  }

  @ToolbarContentBuilder
  private var toolbar: some ToolbarContent {
    ToolbarItemGroup(placement: .navigation) {
      Button {
        Task { await store.refreshAll() }
      } label: {
        Label("Get Messages", systemImage: "arrow.down.circle")
      }
      .help("Get new messages for all accounts")
      .disabled(!store.refreshing.isEmpty)
    }

    ToolbarItem(placement: .primaryAction) {
      Button {
        openWindow(id: WindowID.compose, value: store.newDraft())
      } label: {
        Label("Write", systemImage: "square.and.pencil")
      }
      .help("Write a new message")
      .disabled(store.sendingAccounts.isEmpty)
    }

    ToolbarSpacer(.fixed, placement: .primaryAction)

    ToolbarItemGroup(placement: .primaryAction) {
      Group {
        Button {
          if let draft = store.replyDraft(all: false) { openWindow(id: WindowID.compose, value: draft) }
        } label: {
          Label("Reply", systemImage: "arrowshape.turn.up.left")
        }
        .help("Reply to the sender")
        Button {
          if let draft = store.replyDraft(all: true) { openWindow(id: WindowID.compose, value: draft) }
        } label: {
          Label("Reply All", systemImage: "arrowshape.turn.up.left.2")
        }
        .help("Reply to everyone")
        Button {
          if let draft = store.forwardDraft() { openWindow(id: WindowID.compose, value: draft) }
        } label: {
          Label("Forward", systemImage: "arrowshape.turn.up.right")
        }
        .help("Forward this message")
      }
      .disabled(store.loadedMessage == nil)
    }

    ToolbarSpacer(.fixed, placement: .primaryAction)

    ToolbarItemGroup(placement: .primaryAction) {
      Group {
        Button {
          Task { await store.moveSelected(to: .archive) }
        } label: {
          Label("Archive", systemImage: "archivebox")
        }
        .help("Archive")
        .disabled(!store.canMoveSelection(to: .archive))
        Button {
          Task { await store.markJunk(true) }
        } label: {
          Label("Junk", systemImage: "xmark.bin")
        }
        .help("Mark as junk")
        Button {
          Task { await store.deleteSelected() }
        } label: {
          Label("Delete", systemImage: "trash")
        }
        .help("Delete")
      }
      .disabled(store.selection.isEmpty)
    }

    ToolbarSpacer(.fixed, placement: .primaryAction)

    ToolbarItemGroup(placement: .primaryAction) {
      Button {
        showingSearch = true
      } label: {
        Label("Search", systemImage: "text.magnifyingglass")
      }
      .help("Search messages (⇧⌘F)")
      Button {
        showTodayPane.toggle()
      } label: {
        Label("Today Pane", systemImage: "sidebar.right")
      }
      .help("Show today's events and tasks")
    }
  }
}

extension FolderSelection: Identifiable {
  var id: String { "\(accountID.uuidString)/\(path)" }
}

struct ActivityPill: View {
  let text: String

  var body: some View {
    HStack(spacing: 8) {
      ProgressView()
        .controlSize(.small)
      Text(text)
        .font(.callout)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .glassEffect(.regular, in: .capsule)
  }
}

struct NewFolderSheet: View {
  @Environment(MailStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  let parent: FolderSelection
  @State private var name = ""
  @State private var asSubfolder = true

  var body: some View {
    let parentFolder = store.folder(parent)
    VStack(alignment: .leading, spacing: 16) {
      Text("New Folder")
        .font(.title3.weight(.semibold))
      TextField("Name", text: $name)
        .textFieldStyle(.roundedBorder)
        .onSubmit(create)
      if let parentFolder {
        Toggle("Create inside “\(parentFolder.displayName)”", isOn: $asSubfolder)
      }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Create", action: create)
          .buttonStyle(.glassProminent)
          .keyboardShortcut(.defaultAction)
          .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
    .padding(24)
    .frame(width: 380)
  }

  private func create() {
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return }
    let parentPath = asSubfolder && store.folder(parent) != nil ? parent.path : nil
    Task { await store.createFolder(named: trimmed, accountID: parent.accountID, parentPath: parentPath) }
    dismiss()
  }
}

struct MessageSourceView: View {
  @Environment(\.dismiss) private var dismiss
  let data: Data

  var body: some View {
    VStack(spacing: 0) {
      ScrollView([.vertical, .horizontal]) {
        Text(String(decoding: data, as: UTF8.self))
          .font(.system(.body, design: .monospaced))
          .textSelection(.enabled)
          .padding(16)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      HStack {
        Text(data.count.byteCountFormatted)
          .foregroundStyle(.secondary)
        Spacer()
        Button("Done") { dismiss() }
          .buttonStyle(.glassProminent)
          .keyboardShortcut(.defaultAction)
      }
      .padding(12)
    }
    .frame(minWidth: 720, minHeight: 520)
  }
}
