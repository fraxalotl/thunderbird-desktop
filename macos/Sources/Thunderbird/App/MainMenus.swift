/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import AppKit
import SwiftUI
import ThunderbirdCore
import UniformTypeIdentifiers

/// Thunderbird's menu bar (mail/base/content/messenger-menubar.inc.xhtml, helpMenu.inc.xhtml and
/// calendar-menu-events-tasks.inc.xhtml). Compose-window menus come from ComposeMenus.
struct MainMenus: Commands {
  let mail: MailStore
  let calendar: CalendarStore
  let chat: ChatStore
  let contacts: ContactsStore
  @Environment(\.openWindow) private var openWindow
  @Environment(\.openSettings) private var openSettings
  @Environment(\.openURL) private var openURL
  @FocusedValue(\.mailUI) private var ui
  @FocusedValue(\.spaceSelection) private var space
  @FocusedValue(\.focusSearch) private var focusSearch
  @FocusedValue(\.composer) private var composer

  @AppStorage(MailPreferences.layout) private var layout = PaneLayout.vertical
  @AppStorage(MailPreferences.showFolderPane) private var showFolderPane = true
  @AppStorage(MailPreferences.showMessagePane) private var showMessagePane = true
  @AppStorage(MailPreferences.showListHeader) private var showListHeader = true
  @AppStorage(MailPreferences.showQuickFilter) private var showQuickFilter = true
  @AppStorage(MailPreferences.showStatusBar) private var showStatusBar = true
  @AppStorage(MailPreferences.showSpacesToolbar) private var showSpaces = true
  @AppStorage(MailPreferences.density) private var density = Density.normal
  @AppStorage(MailPreferences.fontScale) private var fontScale = 0
  @AppStorage(MailPreferences.headerMode) private var headerMode = HeaderMode.normal
  @AppStorage(MailPreferences.bodyMode) private var bodyMode = BodyMode.original
  @AppStorage(MailPreferences.attachmentsInline) private var attachmentsInline = true
  @AppStorage(MailPreferences.feedBodyMode) private var feedBodyMode = "summary"
  @AppStorage(MailPreferences.listStyle) private var listStyle = ListStyle.cards
  @AppStorage(FolderPanePreferences.modes) private var folderModes = "all"
  @AppStorage(FolderPanePreferences.compact) private var folderCompact = false
  @AppStorage(FolderPanePreferences.header) private var folderHeader = true
  @AppStorage(Preferences.showTodayPane) private var showTodayPane = false
  @AppStorage("settingsTab") private var settingsTab = "general"
  @AppStorage("showUnifinder") private var showUnifinder = false

  private func compose(_ draft: ComposeDraft?) {
    if let draft { openWindow(id: WindowID.compose, value: draft) }
  }

  private func settings(_ tab: String) {
    settingsTab = tab
    openSettings()
  }

  private func switchTo(_ target: AppSpace) {
    space?.wrappedValue = target
  }

  var body: some Commands {
    fileMenu
    editMenu
    viewMenu
    CommandMenu("Go") { goMenu }
    CommandMenu("Message") {
      MessageMenuItems(store: mail, calendar: calendar, ui: ui, openWindow: openWindow, inMenuBar: true)
    }
    CommandMenu("Events and Tasks") { eventsMenu }
    CommandMenu("Tools") {
      if composer != nil {
        Button("Mail & Newsgroups") { openWindow(id: WindowID.main); switchTo(.mail) }
          .keyboardShortcut("1")
        Button("Address Book") { openWindow(id: WindowID.main); switchTo(.addressBook) }
          .keyboardShortcut("b", modifiers: [.command, .shift])
        Divider()
        Button("Account Settings") { settings("accounts") }
      } else {
        toolsMenu
      }
    }
    helpMenu
  }

  // MARK: - File

  @CommandsBuilder
  private var fileMenu: some Commands {
    CommandGroup(replacing: .newItem) {
      if let composer {
        ComposeFileMenu(composer: composer, openWindow: openWindow, mail: mail)
      } else {
        Menu("New") {
          Button("Message") { compose(mail.newDraft()) }
            .keyboardShortcut("n")
          Button("Event") {
            switchTo(.calendar)
            calendar.pendingEditor = calendar.draft(for: nil)
          }
          Button("Task") {
            switchTo(.tasks)
            calendar.taskFilter = .all
          }
          Divider()
          Button("Folder…") { if let folder = mail.selectedFolder { ui?.present(.newFolder(folder)) } }
            .disabled(mail.selectedFolder == nil || ui == nil)
          Button("Saved Search…") { ui?.present(.search) }
            .disabled(ui == nil)
          Divider()
          Button("Email Account…") { ui?.present(.accountSetup) }
            .disabled(ui == nil)
          Button("Calendar…") { calendar.promptNewCalendar() }
          Button("Address Book…") { openInternetAccounts() }
          Button("Chat Account…") {
            switchTo(.chat)
            chat.pendingAccountSetup = true
          }
          Button("Feed Account…") {
            switchTo(.mail)
            mail.pendingFeedSetup = true
          }
          Button("Newsgroup Account…") { ui?.present(.accountSetup) }
            .disabled(ui == nil)
          Divider()
          Button("Address Book Contact…") {
            switchTo(.addressBook)
            contacts.pendingNewContact = true
          }
          Button("Mailing List…") {
            switchTo(.addressBook)
            contacts.pendingNewList = true
          }
          Button("Chat Contact…") {
            switchTo(.chat)
            chat.pendingAddContact = true
          }
        }
        Menu("Open") {
          Button("Saved Message…") { openSavedMessage() }
            .keyboardShortcut("o", modifiers: [.command, .option])
          Button("Calendar File…") { calendar.importCalendarFile() }
        }
      }
    }
    CommandGroup(replacing: .saveItem) {
      if let composer {
        ComposeSaveMenu(composer: composer)
      } else {
        Menu("Save As") {
          Button("File…") { saveMessageAsFile() }
            .keyboardShortcut("s")
          Button("Template") { if let loaded = mail.loadedMessage { Task { await mail.saveAsTemplate(loaded) } } }
        }
        .disabled(mail.loadedMessage == nil)
        Divider()
        Menu("Get New Messages for") {
          Button("All Accounts") { Task { await mail.refreshAll() } }
            .keyboardShortcut("y", modifiers: [.command, .shift])
          Button("Current Account") { if let id = mail.currentAccount?.id { Task { await mail.refresh(accountID: id) } } }
            .keyboardShortcut("y")
          Divider()
          ForEach(mail.mailAccounts.filter { $0.kind != .local }) { account in
            Button(account.label) { Task { await mail.refresh(accountID: account.id) } }
          }
        }
        Button("Get Next 500 News Messages") { Task { await mail.getMoreNews() } }
          .disabled(mail.currentAccount?.kind != .nntp)
        Button("Send Unsent Messages") { Task { await mail.sendUnsentMessages() } }
        Button("Subscribe…") {
          guard let account = mail.currentAccount else { return }
          ui?.present(account.kind == .nntp ? .newsSubscribe(account.id) : .imapSubscribe(account.id))
        }
        .disabled(mail.currentAccount.map { $0.kind != .imap && $0.kind != .nntp } ?? true)
        Divider()
        Button("Delete Folder") { if let folder = mail.selectedFolder { confirmDeleteFolder(folder) } }
          .disabled(mail.currentFolder?.role != .normal)
        Button("Rename Folder…") { if let folder = mail.selectedFolder { renameFolder(folder) } }
          .disabled(mail.currentFolder?.role != .normal)
        Button("Compact Folder") { if let folder = mail.selectedFolder { Task { await mail.compactFolder(folder) } } }
          .disabled(mail.selectedFolder == nil)
        Button("Compact All Folders") { Task { await mail.compactAllFolders() } }
        Button("Empty Trash") { Task { await mail.emptyAllTrash() } }
        Divider()
        Menu("Offline") {
          Toggle("Work Offline", isOn: Binding(get: { mail.isOffline }, set: { mail.isOffline = $0 }))
          Divider()
          Button("Download/Sync Now…") { Task { await mail.downloadForOffline(.everything) } }
          Button("Offline Settings") { settings("general") }
          Divider()
          Button("Get Starred Messages") { Task { await mail.downloadForOffline(.starred) } }
          Button("Get Selected Messages") { Task { await mail.downloadForOffline(.selected) } }
            .disabled(mail.selection.isEmpty)
        }
      }
    }
    CommandGroup(replacing: .printItem) {
      Button("Print…") {
        if let composer { composer.print() } else { ui?.reader.print() }
      }
      .keyboardShortcut("p")
      .disabled(composer == nil && mail.loadedMessage == nil)
    }
  }

  // MARK: - Edit

  @CommandsBuilder
  private var editMenu: some Commands {
    CommandGroup(after: .pasteboard) {
      if let composer {
        ComposeEditMenu(composer: composer)
      } else {
        Menu("Select") {
          Button("All Messages") { mail.selectAll() }
          Divider()
          Button("Thread") { mail.selectThread() }
            .keyboardShortcut("a", modifiers: [.command, .shift])
          Button("Starred Messages") { mail.selectStarred() }
        }
        Divider()
        Button(mail.selectedFolder.map(mail.isFavorite) == true ? "Remove Favorite Folder" : "Favorite Folder") {
          if let folder = mail.selectedFolder { mail.toggleFavorite(folder) }
        }
        .disabled(mail.selectedFolder == nil)
        Button("Folder Properties…") { if let folder = mail.selectedFolder { ui?.present(.folderProperties(folder)) } }
          .disabled(mail.selectedFolder == nil || ui == nil)
        Divider()
        Button("Account Settings") { settings("accounts") }
      }
    }
    CommandGroup(replacing: .textEditing) {
      if let composer {
        ComposeFindMenu(composer: composer)
      } else {
        Menu("Find") {
          Button("Find in This Message…") { ui?.findVisible = true }
            .keyboardShortcut("f")
            .disabled(mail.loadedMessage == nil)
          Button("Find Again") { ui?.reader.find(ui?.findText ?? "", backwards: false) }
            .keyboardShortcut("g")
          Button("Find Previous") { ui?.reader.find(ui?.findText ?? "", backwards: true) }
            .keyboardShortcut("g", modifiers: [.command, .shift])
          Divider()
          Button("Search Messages…") { ui?.present(.search) }
            .keyboardShortcut("f", modifiers: [.command, .shift])
          Button("Global Search…") { focusSearch?() }
            .keyboardShortcut("k")
          Button("Search Addresses…") { switchTo(.addressBook) }
        }
      }
    }
  }

  // MARK: - View

  @CommandsBuilder
  private var viewMenu: some Commands {
    CommandGroup(replacing: .toolbar) {
      if let composer {
        ComposeViewMenu(composer: composer)
      } else {
        Menu("Toolbars") {
          Toggle("Quick Filter Bar", isOn: $showQuickFilter)
            .keyboardShortcut("k", modifiers: [.command, .shift])
          Toggle("Spaces Toolbar", isOn: $showSpaces)
          Toggle("Status Bar", isOn: $showStatusBar)
          Divider()
          Button("Customize…") { NSApp.sendAction(#selector(NSWindow.runToolbarCustomizationPalette(_:)), to: nil, from: nil) }
        }
        Menu("Layout") {
          Picker("Layout", selection: $layout) {
            ForEach(PaneLayout.allCases, id: \.self) { Text($0.title).tag($0) }
          }
          .pickerStyle(.inline)
          Divider()
          Toggle("Folder Pane", isOn: $showFolderPane)
          Toggle("Message List Header", isOn: $showListHeader)
          Toggle("Message Pane", isOn: $showMessagePane)
            .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF8FunctionKey)!)), modifiers: [])
        }
        Menu("Folders") {
          Toggle("Folder Pane Header", isOn: $folderHeader)
          Divider()
          ForEach(FolderMode.allCases.filter { $0 != .tags }) { mode in
            Toggle(
              mode.title,
              isOn: Binding(
                get: { FolderPanePreferences.enabledModes(folderModes).contains(mode) },
                set: { _ in folderModes = FolderPanePreferences.toggled(mode, in: folderModes) }))
          }
          Divider()
          Toggle(
            "Tags",
            isOn: Binding(
              get: { FolderPanePreferences.enabledModes(folderModes).contains(.tags) },
              set: { _ in folderModes = FolderPanePreferences.toggled(.tags, in: folderModes) }))
          Divider()
          Toggle("Compact View", isOn: $folderCompact)
        }
        Divider()
        Menu("Density") {
          Picker("Density", selection: $density) {
            ForEach(Density.allCases, id: \.self) { Text($0.title).tag($0) }
          }
          .pickerStyle(.inline)
        }
        Menu("Zoom") {
          Button("Zoom In") { ui?.reader.zoom(by: 0.1) }
            .keyboardShortcut("+")
          Button("Zoom Out") { ui?.reader.zoom(by: -0.1) }
            .keyboardShortcut("-")
          Divider()
          Button("Reset") { ui?.reader.resetZoom() }
            .keyboardShortcut("0")
        }
        Menu("Font Size") {
          Button("Increase Font Size") { fontScale = min(2, fontScale + 1) }
          Button("Reduce Font Size") { fontScale = max(-1, fontScale - 1) }
          Divider()
          Button("Reset Font Size") { fontScale = 0 }
        }
        Divider()
        Menu("Sort by") {
          Picker("Sort by", selection: Binding(get: { mail.sortKey }, set: { mail.sortKey = $0 })) {
            ForEach(SortKey.allCases) { Text($0.title).tag($0) }
          }
          .pickerStyle(.inline)
          Divider()
          Picker("Order", selection: Binding(get: { mail.sortAscending }, set: { mail.sortAscending = $0 })) {
            Text("Ascending").tag(true)
            Text("Descending").tag(false)
          }
          .pickerStyle(.inline)
          Divider()
          Picker("Threads", selection: Binding(get: { mail.threadMode }, set: { mail.threadMode = $0 })) {
            ForEach(ThreadMode.allCases, id: \.self) { Text($0.title).tag($0) }
          }
          .pickerStyle(.inline)
        }
        Menu("Messages") {
          Picker("Messages", selection: Binding(get: { mail.viewFilter }, set: { mail.viewFilter = $0 })) {
            Text("All").tag(MessageViewFilter.all)
            Text("Unread").tag(MessageViewFilter.unread)
            Text("Not Deleted").tag(MessageViewFilter.notDeleted)
          }
          .pickerStyle(.inline)
          Divider()
          Menu("Tags") {
            ForEach(MessageTagStore.shared.tags) { tag in
              Button(tag.name) { mail.viewFilter = .tag(tag.keyword) }
            }
          }
          Divider()
          Button("Save View as a Folder…") { ui?.present(.search) }
          Button("Customize…") { ui?.present(.manageTags) }
        }
        Menu("Threads") {
          Picker("Threads", selection: Binding(get: { mail.threadFilter }, set: { mail.threadFilter = $0 })) {
            ForEach(ThreadFilter.allCases.filter { $0 != .ignored }, id: \.self) { Text($0.title).tag($0) }
          }
          .pickerStyle(.inline)
          Divider()
          Toggle(
            "Ignored Threads",
            isOn: Binding(get: { mail.threadFilter == .ignored }, set: { mail.threadFilter = $0 ? .ignored : .all }))
          Divider()
          Button("Expand All Threads") { mail.expandAllThreads() }
          Button("Collapse All Threads") { mail.collapseAllThreads() }
        }
        Divider()
        Menu("Headers") {
          Picker("Headers", selection: $headerMode) {
            Text("All").tag(HeaderMode.all)
            Text("Normal").tag(HeaderMode.normal)
          }
          .pickerStyle(.inline)
        }
        Menu("Message Body As") {
          Picker("Body", selection: $bodyMode) {
            ForEach(BodyMode.allCases, id: \.self) { Text($0.title).tag($0) }
          }
          .pickerStyle(.inline)
        }
        Menu("Feed Message Body As") {
          Picker("Feed", selection: $feedBodyMode) {
            Text("Web Page").tag("webPage")
            Text("Summary").tag("summary")
          }
          .pickerStyle(.inline)
        }
        Toggle("Display Attachments Inline", isOn: $attachmentsInline)
        Divider()
        Button("Message Source") { if let loaded = mail.loadedMessage { ui?.present(.source(loaded.raw)) } }
          .keyboardShortcut("u")
          .disabled(mail.loadedMessage == nil)
        Toggle("Today Pane", isOn: $showTodayPane)
          .keyboardShortcut("r", modifiers: [.command, .option])
        Divider()
      }
    }
  }

  // MARK: - Go

  @ViewBuilder
  private var goMenu: some View {
    Menu("Next") {
      Button("Message") { mail.navigate(.message, forward: true) }
      Button("Unread Message") { mail.navigate(.unread, forward: true) }
      Button("Starred Message") { mail.navigate(.starred, forward: true) }
      Divider()
      Button("Unread Thread") { mail.navigate(.unreadThread, forward: true) }
    }
    Menu("Previous") {
      Button("Message") { mail.navigate(.message, forward: false) }
      Button("Unread Message") { mail.navigate(.unread, forward: false) }
      Button("Starred Message") { mail.navigate(.starred, forward: false) }
    }
    Button("Forward") { mail.goForward() }
      .keyboardShortcut("]")
      .disabled(!mail.canGoForward)
    Button("Back") { mail.goBack() }
      .keyboardShortcut("[")
      .disabled(!mail.canGoBack)
    Divider()
    Button("Today") {
      switchTo(.calendar)
      calendar.focusDate = Date()
    }
    Button("Chat") { switchTo(.chat) }
    Divider()
    FolderPickerMenu(title: "Folder", store: mail) { destination in
      switchTo(.mail)
      mail.source = .folder(destination)
    }
    Divider()
    Button("Mail Start Page") {
      switchTo(.mail)
      mail.selection = []
    }
    .keyboardShortcut(.home, modifiers: [.option])
  }

  // MARK: - Events and Tasks

  @ViewBuilder
  private var eventsMenu: some View {
    Button("New Event") {
      switchTo(.calendar)
      calendar.pendingEditor = calendar.draft(for: nil)
    }
    .keyboardShortcut("i", modifiers: [.command, .option])
    Button("New Task") {
      switchTo(.tasks)
      calendar.pendingTask = true
    }
    .keyboardShortcut("d", modifiers: [.command, .option])
    Divider()
    Button("Calendar") { switchTo(.calendar) }
      .keyboardShortcut("c", modifiers: [.command, .shift])
    Button("Tasks") { switchTo(.tasks) }
      .keyboardShortcut("d", modifiers: [.command, .shift])
    Divider()
    Button("Export…") { calendar.exportCalendar() }
    Button("Import…") { calendar.importCalendarFile() }
    Button("Publish…") { calendar.publishCalendar() }
    Button("Delete Selected Calendar…") { calendar.deleteSelectedCalendar() }
      .disabled(calendar.selectedCalendarID == nil)
    Divider()
    Button("Mark Completed") { calendar.markSelectedTask(completed: true) }
      .disabled(calendar.selectedTaskID == nil)
    Menu("Progress") {
      ForEach([0, 25, 50, 75, 100], id: \.self) { percent in
        Button("\(percent)% Complete") { calendar.setSelectedTaskProgress(percent) }
      }
    }
    .disabled(calendar.selectedTaskID == nil)
    Menu("Priority") {
      Button("Not Specified") { calendar.setSelectedTaskPriority(0) }
      Button("Low") { calendar.setSelectedTaskPriority(9) }
      Button("Normal") { calendar.setSelectedTaskPriority(5) }
      Button("High") { calendar.setSelectedTaskPriority(1) }
    }
    .disabled(calendar.selectedTaskID == nil)
    Menu("Postpone Task") {
      Button("1 Hour") { calendar.postponeSelectedTask(by: 3600) }
      Button("1 Day") { calendar.postponeSelectedTask(by: 86_400) }
      Button("1 Week") { calendar.postponeSelectedTask(by: 604_800) }
    }
    .disabled(calendar.selectedTaskID == nil)
    Divider()
    Toggle("Events Search", isOn: $showUnifinder)
  }

  // MARK: - Tools

  @ViewBuilder
  private var toolsMenu: some View {
    Button("Mail & Newsgroups") { switchTo(.mail) }
    Button("Address Book") { switchTo(.addressBook) }
      .keyboardShortcut("b", modifiers: [.command, .shift])
    Divider()
    Button("Saved Files") { openWindow(id: WindowID.savedFiles) }
      .keyboardShortcut("j")
    Button("Activity Manager") { openWindow(id: WindowID.activity) }
    Menu("Chat Status") {
      Button("Available") { chat.setAllOnline(true) }
      Button("Unavailable") { chat.setAway(true) }
      Divider()
      Button("Offline") { chat.setAllOnline(false) }
      Divider()
      Button("Show Accounts…") { switchTo(.chat) }
    }
    Button("Join Chat…") {
      switchTo(.chat)
      chat.pendingJoin = true
    }
    Divider()
    Button("Message Filters") { settings("filters") }
    Button("Run Filters on Folder") { Task { await mail.runFiltersOnCurrentFolder() } }
      .disabled(mail.selectedFolder == nil)
    Button("Run Filters on Message") { Task { await mail.runFiltersOnSelection() } }
      .disabled(mail.selection.isEmpty)
    Divider()
    Button("Run Spam Controls on Folder") { Task { await mail.runSpamControls() } }
      .disabled(mail.items.isEmpty)
    Button("Delete Mail Marked as Spam in Folder") { Task { await mail.deleteSpamInCurrentFolder() } }
      .disabled(mail.items.isEmpty)
    Divider()
    Button("Import…") { openWindow(id: WindowID.importExport, value: "import") }
    Button("Export…") { openWindow(id: WindowID.importExport, value: "export") }
    Button("OpenPGP Key Manager") { settings("encryption") }
    Button("Clear Recent History…") { mail.clearRecentHistory() }
    Divider()
    Button("Account Settings") { settings("accounts") }
  }

  // MARK: - Help

  @CommandsBuilder
  private var helpMenu: some Commands {
    CommandGroup(replacing: .help) {
      Button("Get Help") { openURL(URL(string: "https://support.mozilla.org/products/thunderbird")!) }
        .keyboardShortcut("?")
      Button("Keyboard Shortcuts") {
        openURL(URL(string: "https://support.mozilla.org/kb/keyboard-shortcuts-thunderbird")!)
      }
      Divider()
      Button("Get Involved") { openURL(URL(string: "https://www.thunderbird.net/participate/")!) }
      Button("Make a Donation") { openURL(URL(string: "https://www.thunderbird.net/donate/")!) }
      Button("Share Ideas and Feedback") { openURL(URL(string: "https://connect.mozilla.org/")!) }
      Divider()
      Button("Troubleshooting Information") { openWindow(id: WindowID.troubleshooting) }
    }
  }

  // MARK: - Helpers

  private func openInternetAccounts() {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension")!)
  }

  private func openSavedMessage() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [UTType(filenameExtension: "eml") ?? .data, .data]
    panel.allowsMultipleSelection = true
    guard panel.runModal() == .OK else { return }
    for url in panel.urls { openWindow(id: WindowID.savedMessage, value: url) }
  }

  private func saveMessageAsFile() {
    guard let loaded = mail.loadedMessage else { return }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = (loaded.parsed.subject.nilIfEmpty ?? "Message").replacingOccurrences(of: "/", with: "-") + ".eml"
    if panel.runModal() == .OK, let url = panel.url {
      try? loaded.raw.write(to: url)
    }
  }

  private func confirmDeleteFolder(_ folder: FolderSelection) {
    let alert = NSAlert()
    alert.messageText = "Delete “\(mail.folder(folder)?.displayName ?? folder.path)”?"
    alert.informativeText = "The folder and all the messages in it will be deleted."
    alert.addButton(withTitle: "Delete Folder")
    alert.addButton(withTitle: "Cancel")
    alert.buttons.first?.hasDestructiveAction = true
    if alert.runModal() == .alertFirstButtonReturn {
      Task { await mail.deleteFolder(folder) }
    }
  }

  private func renameFolder(_ folder: FolderSelection) {
    let alert = NSAlert()
    alert.messageText = "Rename Folder"
    let field = NSTextField(string: mail.folder(folder)?.displayName ?? "")
    field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
    alert.accessoryView = field
    alert.addButton(withTitle: "Rename")
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = field
    if alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty {
      Task { await mail.renameFolder(folder, to: field.stringValue) }
    }
  }
}
