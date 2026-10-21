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
  @AppStorage(MailPreferences.showSpacesToolbar) private var showSpaces = true

  var body: some View {
    @Bindable var mail = mail
    Group {
      switch space {
      case .mail: MailSpace(space: $space)
      case .addressBook: AddressBookSpace()
      case .calendar: CalendarSpace()
      case .tasks: TasksSpace()
      case .chat: ChatSpace()
      }
    }
    .toolbar {
      if space != .mail && showSpaces {
        ToolbarItem(placement: .navigation) {
          SpacesPicker(space: $space)
        }
      }
    }
    .focusedSceneValue(\.spaceSelection, $space)
    .overlay(alignment: .bottom) {
      if let activity = mail.activity {
        ActivityPill(text: activity)
          .padding(.bottom, 28)
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

/// Thunderbird's Spaces toolbar: Mail, Address Book, Calendar, Tasks and Chat.
struct SpacesPicker: View {
  @Binding var space: AppSpace
  @Environment(ChatStore.self) private var chat

  var body: some View {
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

extension FocusedValues {
  @Entry var spaceSelection: Binding<AppSpace>?
}

enum MailtoLink {
  static func address(_ url: URL) -> String {
    let address = url.absoluteString.dropFirst("mailto:".count).split(separator: "?").first.map(String.init) ?? ""
    return address.removingPercentEncoding ?? address
  }
}

struct MailSpace: View {
  @Environment(MailStore.self) private var store
  @Environment(ContactsStore.self) private var contacts
  @Environment(CalendarStore.self) private var calendar
  @Environment(\.openWindow) private var openWindow
  @Environment(\.undoManager) private var undoManager
  @Binding var space: AppSpace
  @AppStorage(Preferences.showTodayPane) private var showTodayPane = false
  @AppStorage(MailPreferences.layout) private var layout = PaneLayout.vertical
  @AppStorage(MailPreferences.showFolderPane) private var showFolderPane = true
  @AppStorage(MailPreferences.showMessagePane) private var showMessagePane = true
  @AppStorage(MailPreferences.showStatusBar) private var showStatusBar = true
  @AppStorage(MailPreferences.showSpacesToolbar) private var showSpaces = true
  @AppStorage(MailPreferences.listStyle) private var listStyle = ListStyle.cards
  @AppStorage(MailPreferences.fontScale) private var fontScale = 0
  @State private var ui = MailUIState()
  @State private var columnVisibility = NavigationSplitViewVisibility.all
  @FocusState private var searchFocused: Bool

  var body: some View {
    @Bindable var store = store
    @Bindable var ui = ui
    Group {
      if !store.accounts.contains(where: { $0.kind != .local }) {
        WelcomeView(onSetUp: { ui.present(.accountSetup) })
      } else {
        panes
          .searchable(text: $store.searchText, placement: .toolbar, prompt: "Search…")
          .searchFocused($searchFocused)
          .onSubmit(of: .search) {
            let query = store.searchText
            guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            Task { await store.search(SearchQuery(text: query, field: .all), scope: SearchScope(kind: .everything)) }
          }
          .toolbar(id: "mail") { toolbar }
          .inspector(isPresented: $showTodayPane) {
            TodayPane()
              .inspectorColumnWidth(min: 220, ideal: 260, max: 340)
          }
          .safeAreaInset(edge: .bottom, spacing: 0) {
            if showStatusBar { StatusBar() }
          }
      }
    }
    .environment(ui)
    .environment(ui.reader)
    .dynamicTypeSize(fontScale < 0 ? .small : fontScale == 0 ? .large : fontScale == 1 ? .xLarge : .xxLarge)
    .focusedSceneValue(\.mailUI, ui)
    .focusedSceneValue(\.focusSearch, { searchFocused = true })
    .onAppear {
      store.undoManager = undoManager
      store.knownContactEmails = Set(contacts.contacts.flatMap { $0.emails.map { $0.value.lowercased() } })
    }
    .onChange(of: contacts.contacts.count) {
      store.knownContactEmails = Set(contacts.contacts.flatMap { $0.emails.map { $0.value.lowercased() } })
    }
    .onChange(of: showFolderPane, initial: true) { updateColumns() }
    .onChange(of: showMessagePane) { updateColumns() }
    .sheet(item: $ui.sheet) { sheet in
      sheetView(sheet)
    }
    .onChange(of: store.pendingFeedSetup, initial: true) {
      if store.pendingFeedSetup {
        ui.present(.setup(.feeds))
        store.pendingFeedSetup = false
      }
    }
    .onChange(of: store.pendingFeedSubscriptions) { _, id in
      if let id {
        Task {
          try? await Task.sleep(for: .milliseconds(400))
          ui.present(.feedSubscriptions(id))
          store.pendingFeedSubscriptions = nil
        }
      }
    }
  }

  private func updateColumns() {
    columnVisibility = showFolderPane ? .all : .doubleColumn
  }

  @ViewBuilder
  private var panes: some View {
    let sidebar = FolderSidebar(
      onAddAccount: { ui.present(.accountSetup) },
      onNewFolder: { ui.present(.newFolder($0)) })
    switch layout {
    case .vertical:
      NavigationSplitView(columnVisibility: $columnVisibility) {
        sidebar.navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 380)
      } content: {
        MessageListView()
          .navigationSplitViewColumnWidth(min: 320, ideal: listStyle == .table ? 560 : 420)
      } detail: {
        if showMessagePane { MessageReaderView() } else { Color.clear }
      }
    case .classic:
      NavigationSplitView(columnVisibility: $columnVisibility) {
        sidebar.navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 380)
      } detail: {
        VSplitView {
          MessageListView()
            .frame(minHeight: 160, idealHeight: 300)
          if showMessagePane {
            MessageReaderView()
              .frame(minHeight: 200)
          }
        }
      }
    case .wide:
      VSplitView {
        MessageListView()
          .frame(minHeight: 160, idealHeight: 280)
        HSplitView {
          if showFolderPane {
            sidebar.frame(minWidth: 200, idealWidth: 250, maxWidth: 380)
          }
          if showMessagePane {
            MessageReaderView()
              .frame(minWidth: 320)
          }
        }
        .frame(minHeight: 200)
      }
    }
  }

  @ViewBuilder
  private func sheetView(_ sheet: MailUIState.Sheet) -> some View {
    switch sheet {
    case .accountSetup: AccountSetupView()
    case .setup(let mode): AccountSetupView(mode: mode)
    case .feedSubscriptions(let accountID): FeedSubscriptionsView(accountID: accountID)
    case .search: SearchView()
    case .source(let data): MessageSourceView(data: data)
    case .newFolder(let parent): NewFolderSheet(parent: parent)
    case .newSavedSearch: SearchView()
    case .markReadByDate: MarkReadByDateSheet()
    case .newTag: TagEditorSheet(tag: nil)
    case .manageTags: ManageTagsSheet()
    case .createFilter(let summary, let accountID): CreateFilterSheet(summary: summary, accountID: accountID)
    case .redirect(let loaded): RedirectSheet(loaded: loaded)
    case .imapSubscribe(let accountID): IMAPSubscribeView(accountID: accountID)
    case .newsSubscribe(let accountID): NewsgroupSubscribeView(accountID: accountID)
    case .folderProperties(let selection): FolderPropertiesView(selection: selection)
    case .event(let draft): EventEditor(initial: draft)
    case .moveTo: EmptyView()
    }
  }

  private func compose(_ draft: ComposeDraft?) {
    if let draft { openWindow(id: WindowID.compose, value: draft) }
  }

  /// Thunderbird's unified toolbar items (mail/components/unifiedtoolbar), customizable through
  /// View › Toolbars › Customize….
  @ToolbarContentBuilder
  private var toolbar: some CustomizableToolbarContent {
    messageToolbarItems
    navigationToolbarItems
    folderToolbarItems
    utilityToolbarItems
  }

  @ToolbarContentBuilder
  private var messageToolbarItems: some CustomizableToolbarContent {
    ToolbarItem(id: "spaces", placement: .navigation) {
      if showSpaces { SpacesPicker(space: $space) }
    }
    ToolbarItem(id: "get-messages", placement: .navigation) {
      Button {
        Task { await store.refreshAll() }
      } label: {
        Label("Get Messages", systemImage: "arrow.down.circle")
      }
      .help("Get new messages for all accounts")
      .disabled(!store.refreshing.isEmpty || store.isOffline)
    }
    ToolbarItem(id: "write-message", placement: .primaryAction) {
      Button {
        compose(store.newDraft())
      } label: {
        Label("Write", systemImage: "square.and.pencil")
      }
      .help("Write a new message")
      .disabled(store.sendingAccounts.isEmpty)
    }
    ToolbarItem(id: "reply", placement: .primaryAction) {
      Button { compose(store.replyDraft(.sender)) } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
        .help("Reply to the sender")
        .disabled(store.loadedMessage == nil)
    }
    ToolbarItem(id: "reply-all", placement: .primaryAction) {
      Button { compose(store.replyDraft(.all)) } label: { Label("Reply All", systemImage: "arrowshape.turn.up.left.2") }
        .help("Reply to everyone")
        .disabled(store.loadedMessage == nil)
    }
    ToolbarItem(id: "reply-to-list", placement: .primaryAction) {
      Button { compose(store.replyDraft(.list)) } label: { Label("Reply to List", systemImage: "person.3") }
        .disabled(!store.canReplyToList(store.loadedMessage))
    }
    .defaultCustomization(.hidden)
    ToolbarItem(id: "forward-inline", placement: .primaryAction) {
      Button { compose(store.forwardDraft(.preferred)) } label: { Label("Forward", systemImage: "arrowshape.turn.up.right") }
        .help("Forward this message")
        .disabled(store.loadedMessage == nil)
    }
    ToolbarItem(id: "forward-attachment", placement: .primaryAction) {
      Button { compose(store.forwardDraft(.attachment)) } label: {
        Label("Forward as Attachment", systemImage: "paperclip.badge.ellipsis")
      }
      .disabled(store.loadedMessage == nil)
    }
    .defaultCustomization(.hidden)
    ToolbarItem(id: "redirect", placement: .primaryAction) {
      Button {
        if let loaded = store.loadedMessage { ui.present(.redirect(loaded)) }
      } label: {
        Label("Redirect", systemImage: "arrowshape.bounce.right")
      }
      .disabled(store.loadedMessage == nil)
    }
    .defaultCustomization(.hidden)
  }

  @ToolbarContentBuilder
  private var navigationToolbarItems: some CustomizableToolbarContent {
    ToolbarItem(id: "archive", placement: .primaryAction) {
      Button { Task { await store.moveSelected(to: .archive) } } label: { Label("Archive", systemImage: "archivebox") }
        .help("Archive")
        .disabled(!store.canMoveSelection(to: .archive))
    }
    ToolbarItem(id: "spam", placement: .primaryAction) {
      Button { Task { await store.markJunk(true) } } label: { Label("Spam", systemImage: "xmark.bin") }
        .help("Mark as spam")
        .disabled(store.selection.isEmpty)
    }
    ToolbarItem(id: "delete", placement: .primaryAction) {
      Button { Task { await store.deleteSelected() } } label: { Label("Delete", systemImage: "trash") }
        .help("Delete")
        .disabled(store.selection.isEmpty)
    }
    ToolbarItem(id: "mark-as", placement: .primaryAction) {
      Menu {
        Button("As Read") { Task { await store.setFlag(MessageFlag.seen, on: true) } }
        Button("As Unread") { Task { await store.setFlag(MessageFlag.seen, on: false) } }
        Button("Thread As Read") { Task { await store.markThreadRead() } }
        Button("All Read") { Task { await store.markAllRead() } }
        Divider()
        Button("Add Star") { Task { await store.setFlag(MessageFlag.flagged, on: true) } }
      } label: {
        Label("Mark", systemImage: "envelope.open")
      }
      .disabled(store.selection.isEmpty)
    }
    .defaultCustomization(.hidden)
    ToolbarItem(id: "tag-message", placement: .primaryAction) {
      TagMenu(store: store, ui: ui)
        .labelStyle(.iconOnly)
        .disabled(store.selection.isEmpty)
    }
    .defaultCustomization(.hidden)
    ToolbarItem(id: "previous-unread", placement: .primaryAction) {
      Button { store.navigate(.unread, forward: false) } label: { Label("Previous Unread", systemImage: "chevron.up.circle") }
    }
    .defaultCustomization(.hidden)
    ToolbarItem(id: "next-unread", placement: .primaryAction) {
      Button { store.navigate(.unread, forward: true) } label: { Label("Next Unread", systemImage: "chevron.down.circle") }
    }
    .defaultCustomization(.hidden)
    ToolbarItem(id: "previous", placement: .primaryAction) {
      Button { store.navigate(.message, forward: false) } label: { Label("Previous", systemImage: "chevron.up") }
    }
    .defaultCustomization(.hidden)
    ToolbarItem(id: "next", placement: .primaryAction) {
      Button { store.navigate(.message, forward: true) } label: { Label("Next", systemImage: "chevron.down") }
    }
    .defaultCustomization(.hidden)
  }

  @ToolbarContentBuilder
  private var folderToolbarItems: some CustomizableToolbarContent {
    ToolbarItem(id: "conversation", placement: .primaryAction) {
      Button {
        if let reference = store.selection.first { openWindow(id: WindowID.conversation, value: reference) }
      } label: {
        Label("Conversation", systemImage: "bubble.left.and.text.bubble.right")
      }
      .disabled(store.selection.isEmpty)
    }
    .defaultCustomization(.hidden)
    ToolbarItem(id: "move-to", placement: .primaryAction) {
      FolderPickerMenu(title: "Move To", store: store) { destination in
        Task { await store.transfer(Array(store.selection), to: destination, copy: false) }
      }
      .disabled(store.selection.isEmpty)
    }
    .defaultCustomization(.hidden)
  }

  @ToolbarContentBuilder
  private var utilityToolbarItems: some CustomizableToolbarContent {
    ToolbarItem(id: "folder-location", placement: .primaryAction) {
      FolderPickerMenu(title: store.sourceTitle, store: store) { destination in store.source = .folder(destination) }
    }
    .defaultCustomization(.hidden)
    ToolbarItem(id: "compact", placement: .primaryAction) {
      Button {
        if let folder = store.selectedFolder { Task { await store.compactFolder(folder) } }
      } label: {
        Label("Compact", systemImage: "arrow.down.right.and.arrow.up.left")
      }
    }
    .defaultCustomization(.hidden)
    ToolbarItem(id: "add-as-event", placement: .primaryAction) {
      Button {
        if let loaded = store.loadedMessage { ui.present(.event(calendar.eventDraft(from: loaded))) }
      } label: {
        Label("Add as Event", systemImage: "calendar.badge.plus")
      }
      .disabled(store.loadedMessage == nil)
    }
    .defaultCustomization(.hidden)
    ToolbarItem(id: "add-as-task", placement: .primaryAction) {
      Button {
        if let loaded = store.loadedMessage { try? calendar.createTask(from: loaded) }
      } label: {
        Label("Add as Task", systemImage: "checklist")
      }
      .disabled(store.loadedMessage == nil)
    }
    .defaultCustomization(.hidden)
    ToolbarItem(id: "address-book", placement: .primaryAction) {
      Button { space = .addressBook } label: { Label("Address Book", systemImage: "person.crop.rectangle.stack") }
    }
    .defaultCustomization(.hidden)
    ToolbarItem(id: "calendar", placement: .primaryAction) {
      Button { space = .calendar } label: { Label("Calendar", systemImage: "calendar") }
    }
    .defaultCustomization(.hidden)
    ToolbarItem(id: "chat", placement: .primaryAction) {
      Button { space = .chat } label: { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
    }
    .defaultCustomization(.hidden)
    ToolbarItem(id: "quick-filter", placement: .primaryAction) {
      QuickFilterToggle()
    }
    ToolbarItem(id: "view-picker", placement: .primaryAction) {
      Picker("View", selection: $listStyle) {
        Label("Cards", systemImage: "rectangle.grid.1x2").tag(ListStyle.cards)
        Label("Table", systemImage: "tablecells").tag(ListStyle.table)
      }
      .pickerStyle(.segmented)
      .help("Cards or table view")
    }
    .defaultCustomization(.hidden)
    ToolbarItem(id: "today-pane", placement: .primaryAction) {
      Button {
        showTodayPane.toggle()
      } label: {
        Label("Today Pane", systemImage: "sidebar.right")
      }
      .help("Show today's events and tasks")
    }
  }
}

private struct QuickFilterToggle: View {
  @AppStorage(MailPreferences.showQuickFilter) private var showQuickFilter = true

  var body: some View {
    Toggle(isOn: $showQuickFilter) {
      Label("Quick Filter", systemImage: "line.3.horizontal.decrease.circle")
    }
    .help("Quick Filter (⇧⌘K)")
  }
}

/// View › Toolbars › Status Bar.
private struct StatusBar: View {
  @Environment(MailStore.self) private var store
  @AppStorage(Preferences.showTodayPane) private var showTodayPane = false

  var body: some View {
    @Bindable var store = store
    HStack(spacing: 12) {
      Button {
        store.isOffline.toggle()
      } label: {
        Image(systemName: store.isOffline ? "wifi.slash" : "wifi")
          .foregroundStyle(store.isOffline ? .orange : .secondary)
      }
      .buttonStyle(.plain)
      .help(store.isOffline ? "Thunderbird is offline. Click to go online." : "Thunderbird is online. Click to work offline.")
      .accessibilityLabel(store.isOffline ? "Go online" : "Work offline")
      Text(store.activity ?? (store.refreshing.isEmpty ? "Done" : "Checking for new messages…"))
        .lineLimit(1)
      Spacer()
      if store.selection.count > 1 {
        Text("Selected: \(store.selection.count)")
      }
      Text("Unread: \(store.items.filter { !$0.summary.isRead }.count)")
      Text("Total: \(store.items.count)")
      Button {
        showTodayPane.toggle()
      } label: {
        Label("Today Pane", systemImage: showTodayPane ? "sidebar.right" : "calendar")
          .labelStyle(.titleAndIcon)
      }
      .buttonStyle(.plain)
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .padding(.horizontal, 12)
    .padding(.vertical, 4)
    .background(.bar)
  }
}

extension FocusedValues {
  @Entry var focusSearch: (() -> Void)?
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
