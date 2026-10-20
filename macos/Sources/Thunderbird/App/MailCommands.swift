/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import SwiftUI
import ThunderbirdCore

struct MailCommands: Commands {
  let store: MailStore
  @Environment(\.openWindow) private var openWindow
  @FocusedValue(\.mailSpaceActions) private var actions

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button("New Message") {
        openWindow(id: WindowID.compose, value: store.newDraft())
      }
      .keyboardShortcut("n")
      .disabled(store.sendingAccounts.isEmpty)

      Button("New Folder…") { actions?.newFolder() }
        .disabled(store.selectedFolder == nil)
    }

    CommandGroup(after: .textEditing) {
      Button("Search Messages…") { actions?.search() }
        .keyboardShortcut("f", modifiers: [.command, .shift])
    }

    CommandGroup(after: .toolbar) {
      Toggle("Threaded View", isOn: Binding(get: { store.threaded }, set: { store.threaded = $0 }))
        .keyboardShortcut("t", modifiers: [.command, .option])
      Toggle(
        "Today Pane",
        isOn: Binding(
          get: { UserDefaults.standard.bool(forKey: Preferences.showTodayPane) },
          set: { UserDefaults.standard.set($0, forKey: Preferences.showTodayPane) })
      )
      .keyboardShortcut("r", modifiers: [.command, .option])
      Divider()
    }

    CommandMenu("Message") {
      Button("Get New Messages") {
        Task { await store.refreshAll() }
      }
      .keyboardShortcut("t", modifiers: [.command, .shift])
      Button("Send Unsent Messages") {
        Task { await store.sendUnsentMessages() }
      }

      Divider()

      Button("Reply") {
        if let draft = store.replyDraft(all: false) { openWindow(id: WindowID.compose, value: draft) }
      }
      .keyboardShortcut("r")
      .disabled(store.loadedMessage == nil)

      Button("Reply All") {
        if let draft = store.replyDraft(all: true) { openWindow(id: WindowID.compose, value: draft) }
      }
      .keyboardShortcut("r", modifiers: [.command, .shift])
      .disabled(store.loadedMessage == nil)

      Button("Forward") {
        if let draft = store.forwardDraft() { openWindow(id: WindowID.compose, value: draft) }
      }
      .keyboardShortcut("l", modifiers: [.command, .shift])
      .disabled(store.loadedMessage == nil)

      Button("Open in New Window") {
        if let reference = store.loadedMessage?.reference { openWindow(id: WindowID.message, value: reference) }
      }
      .keyboardShortcut("o")
      .disabled(store.loadedMessage == nil)

      Button("View Source") { actions?.viewSource() }
        .keyboardShortcut("u")
        .disabled(store.loadedMessage == nil)

      Button("Print…") { actions?.print() }
        .keyboardShortcut("p")
        .disabled(store.loadedMessage == nil)

      Divider()

      Button("Toggle Read") {
        Task { await store.toggleRead() }
      }
      .keyboardShortcut("u", modifiers: [.command, .shift])
      .disabled(store.selection.isEmpty)

      Button("Toggle Star") {
        Task { await store.toggleStar() }
      }
      .keyboardShortcut("s", modifiers: [.command, .option])
      .disabled(store.selection.isEmpty)

      Menu("Tag") {
        ForEach(Array(MessageTag.defaults.enumerated()), id: \.element.keyword) { index, tag in
          Button(tag.name) { Task { await store.toggleTag(tag.keyword) } }
            .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.control])
        }
        Divider()
        Button("Remove All Tags") { Task { await store.removeAllTags() } }
          .keyboardShortcut("0", modifiers: [.control])
      }
      .disabled(store.selection.isEmpty)

      Divider()

      Button("Archive") {
        Task { await store.moveSelected(to: .archive) }
      }
      .keyboardShortcut("a", modifiers: [.command, .control])
      .disabled(!store.canMoveSelection(to: .archive))

      Button("Mark as Junk") {
        Task { await store.markJunk(true) }
      }
      .keyboardShortcut("j", modifiers: [.command, .shift])
      .disabled(store.selection.isEmpty)

      Button("Mark as Not Junk") {
        Task { await store.markJunk(false) }
      }
      .keyboardShortcut("j", modifiers: [.command, .shift, .option])
      .disabled(store.selection.isEmpty)

      Button("Delete") {
        Task { await store.deleteSelected() }
      }
      .keyboardShortcut(.delete)
      .disabled(store.selection.isEmpty)

      Divider()

      Button("Run Filters on Folder") {
        Task { await store.runFiltersOnCurrentFolder() }
      }
      .disabled(store.selectedFolder == nil)
    }
  }
}

/// Actions the menu bar triggers in the focused main window.
struct MailSpaceActions {
  var newFolder: () -> Void
  var search: () -> Void
  var viewSource: () -> Void
  var print: () -> Void
}

extension FocusedValues {
  @Entry var mailSpaceActions: MailSpaceActions?
}
