/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import AppKit
import SwiftUI
import ThunderbirdCore

/// Thunderbird's Message menu (messenger-menubar.inc.xhtml), shared by the menu bar and the
/// message list's context menu.
struct MessageMenuItems: View {
  let store: MailStore
  let calendar: CalendarStore
  let ui: MailUIState?
  let openWindow: OpenWindowAction
  var inMenuBar = false

  private var loaded: LoadedMessage? { store.loadedMessage }
  private var hasSelection: Bool { !store.selection.isEmpty }
  private var isNews: Bool { loaded?.account.kind == .nntp }

  private func compose(_ draft: ComposeDraft?) {
    if let draft { openWindow(id: WindowID.compose, value: draft) }
  }

  var body: some View {
    if inMenuBar {
      Button("New Message") { compose(store.newDraft()) }
        .keyboardShortcut("m", modifiers: [.command, .shift])
    }
    Button("Reply") { compose(store.replyDraft(isNews ? .newsgroup : .sender)) }
      .shortcut("r", [.command], inMenuBar)
      .disabled(loaded == nil)
    if isNews {
      Button("Followup to Newsgroup") { compose(store.replyDraft(.newsgroup)) }
        .disabled(loaded == nil)
    }
    Button("Reply to Sender Only") { compose(store.replyDraft(.sender)) }
      .disabled(loaded == nil)
    Button("Reply to All") { compose(store.replyDraft(.all)) }
      .shortcut("r", [.command, .shift], inMenuBar)
      .disabled(loaded == nil)
    Button("Reply to List") { compose(store.replyDraft(.list)) }
      .shortcut("l", [.command, .shift], inMenuBar)
      .disabled(!store.canReplyToList(loaded))
    Button("Forward") { compose(store.forwardDraft(.inline)) }
      .shortcut("l", [.command], inMenuBar)
      .disabled(loaded == nil)
    Menu("Forward As") {
      Button("Inline") { compose(store.forwardDraft(.inline)) }
      Button("Attachment") { compose(store.forwardDraft(.attachment)) }
    }
    .disabled(loaded == nil)
    Button("Redirect") {
      if let loaded { ui?.present(.redirect(loaded)) }
    }
    .disabled(loaded == nil || ui == nil)
    Button("Edit As New Message") { compose(store.editAsNew()) }
      .shortcut("e", [.command], inMenuBar)
      .disabled(loaded == nil)
    if loaded?.folderRole == .drafts {
      Button("Edit Draft Message") { compose(loaded.flatMap(store.reopenDraft)) }
    }
    if loaded?.folderRole == .templates {
      Button("New Message from Template") { compose(loaded.flatMap(store.reopenDraft)) }
      Button("Edit Template") { compose(store.editTemplate()) }
    }

    Divider()

    Button("Open Message") {
      for reference in store.selection { openWindow(id: WindowID.message, value: reference) }
    }
    .shortcut("o", [.command], inMenuBar)
    .disabled(!hasSelection)
    Button("Open in Conversation") {
      if let reference = store.selection.first { openWindow(id: WindowID.conversation, value: reference) }
    }
    .shortcut("o", [.command, .shift], inMenuBar)
    .disabled(!hasSelection)

    Divider()

    Menu("Attachments") {
      ForEach(loaded?.parsed.attachments ?? []) { attachment in
        Button(attachment.filename) { AttachmentFiles.open(attachment) }
      }
      Divider()
      Button("Open All…") { loaded?.parsed.attachments.forEach(AttachmentFiles.open) }
      Button("Save All…") { if let loaded { AttachmentFiles.save(loaded.parsed.attachments) } }
      Button("Detach All…") { detachAll() }
      Button("Delete All…") { deleteAll() }
    }
    .disabled(loaded?.parsed.attachments.isEmpty ?? true)

    Divider()

    TagMenu(store: store, ui: ui, inMenuBar: inMenuBar)
      .disabled(!hasSelection)

    Menu("Mark") {
      Button("As Read") { Task { await store.setFlag(MessageFlag.seen, on: true) } }
      Button("As Unread") { Task { await store.setFlag(MessageFlag.seen, on: false) } }
      Button("Thread As Read") { Task { await store.markThreadRead() } }
      Button("As Read by Date…") { ui?.present(.markReadByDate) }
      Button("All Read") { Task { await store.markAllRead() } }
        .shortcut("c", [.command, .shift, .option], inMenuBar)
      Divider()
      Button(store.selectedItems.allSatisfy(\.summary.isFlagged) ? "Remove Star" : "Add Star") {
        Task { await store.toggleStar() }
      }
      Divider()
      Button("As Spam") { Task { await store.markJunk(true) } }
      Button("As Not Spam") { Task { await store.markJunk(false) } }
      Button("Run Spam Controls") { Task { await store.runSpamControls(on: store.selection) } }
    }
    .disabled(!hasSelection)

    Divider()

    Button("Archive") { Task { await store.moveSelected(to: .archive) } }
      .shortcut("a", [.command, .control], inMenuBar)
      .disabled(!store.canMoveSelection(to: .archive))
    if isNews {
      Button("Cancel Message") { if let loaded { Task { await store.cancelNewsMessage(loaded) } } }
    }
    FolderPickerMenu(title: "Move To", store: store) { destination in
      Task { await store.transfer(Array(store.selection), to: destination, copy: false) }
    }
    .disabled(!hasSelection)
    FolderPickerMenu(title: "Copy To", store: store) { destination in
      Task { await store.transfer(Array(store.selection), to: destination, copy: true) }
    }
    .disabled(!hasSelection)
    Button("Move Again") { Task { await store.moveAgain() } }
      .shortcut("m", [.command, .option], inMenuBar)
      .disabled(!hasSelection || store.lastMoveTarget == nil)

    Divider()

    Button("Create Filter From Message…") {
      if let item = store.selectedItems.first { ui?.present(.createFilter(item.summary, item.reference.accountID)) }
    }
    .disabled(!hasSelection || ui == nil)
    Menu("Convert To") {
      Button("Event…") { if let loaded { ui?.present(.event(calendar.eventDraft(from: loaded))) } }
      Button("Task") {
        if let loaded {
          do { try calendar.createTask(from: loaded) } catch { store.report(error, title: "Couldn't create the task") }
        }
      }
    }
    .disabled(loaded == nil)

    Divider()

    let ignored = store.selectedItems.contains { store.ignoredThreads.contains($0.summary.references.first ?? $0.summary.messageID ?? "") }
    Button(ignored ? "Stop Ignoring Thread" : "Ignore Thread") { store.toggleIgnoreThread() }
      .disabled(!hasSelection)
    Button("Ignore Subthread") { store.toggleIgnoreThread(subthread: true) }
      .disabled(!hasSelection)
    Button(store.selectedItems.contains { store.isWatched($0.summary) } ? "Stop Watching Thread" : "Watch Thread") {
      store.toggleWatchThread()
    }
    .disabled(!hasSelection)

    if !inMenuBar {
      Divider()
      Button("Delete", role: .destructive) { Task { await store.deleteSelected() } }
    }
  }

  private func detachAll() {
    guard let loaded else { return }
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = "Detach"
    guard panel.runModal() == .OK, let folder = panel.url else { return }
    Task { await store.detachAllAttachments(loaded, to: folder) }
  }

  private func deleteAll() {
    guard let loaded else { return }
    let alert = NSAlert()
    alert.messageText = "Delete all attachments from this message?"
    alert.informativeText = "This can't be undone. The message itself is kept."
    alert.addButton(withTitle: "Delete")
    alert.addButton(withTitle: "Cancel")
    alert.buttons.first?.hasDestructiveAction = true
    if alert.runModal() == .alertFirstButtonReturn {
      Task { await store.deleteAllAttachments(loaded) }
    }
  }
}

/// Message › Tag.
struct TagMenu: View {
  let store: MailStore
  let ui: MailUIState?
  var inMenuBar = false

  var body: some View {
    Menu("Tag") {
      Button("New Tag…") { ui?.present(.newTag) }
        .disabled(ui == nil)
      Button("Manage Tags…") { ui?.present(.manageTags) }
        .disabled(ui == nil)
      Divider()
      Button("Remove All Tags") { Task { await store.removeAllTags() } }
        .shortcut("0", [.control], inMenuBar)
      Divider()
      ForEach(Array(MessageTagStore.shared.tags.enumerated()), id: \.element.keyword) { index, tag in
        Toggle(
          isOn: Binding(
            get: { !store.selectedItems.isEmpty && store.selectedItems.allSatisfy { $0.summary.flags.contains(tag.keyword) } },
            set: { _ in Task { await store.toggleTag(tag.keyword) } })
        ) {
          Text("\(index < 9 ? "\(index + 1) " : "")\(tag.name)")
        }
        .shortcut(KeyEquivalent(Character("\(min(index + 1, 9))")), [.control], inMenuBar && index < 9)
      }
    }
  }
}

/// A Move To / Copy To style folder picker for every account.
struct FolderPickerMenu: View {
  let title: String
  let store: MailStore
  let action: (FolderSelection) -> Void

  var body: some View {
    Menu(title) {
      if !store.recentFolders.isEmpty {
        Menu("Recent") {
          ForEach(store.recentFolders.prefix(10), id: \.self) { selection in
            if let folder = store.folder(selection) {
              Button("\(folder.displayName) — \(store.account(selection.accountID)?.label ?? "")") { action(selection) }
            }
          }
        }
        Divider()
      }
      ForEach(store.mailAccounts.filter { $0.kind != .nntp }) { account in
        Menu(account.label) {
          ForEach(store.sidebarFolders(for: account.id).filter(\.folder.isSelectable)) { item in
            Button(String(repeating: "   ", count: item.depth) + item.folder.displayName) {
              action(FolderSelection(accountID: account.id, path: item.folder.path))
            }
          }
        }
      }
    }
  }
}

extension View {
  /// Adds a keyboard shortcut only where it applies (the menu bar), so context menus stay plain.
  @ViewBuilder
  func shortcut(_ key: KeyEquivalent, _ modifiers: EventModifiers, _ enabled: Bool) -> some View {
    if enabled {
      keyboardShortcut(key, modifiers: modifiers)
    } else {
      self
    }
  }
}
