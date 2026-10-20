/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import SwiftUI
import ThunderbirdCore

struct MailCommands: Commands {
  let store: MailStore
  @Environment(\.openWindow) private var openWindow

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button("New Message") {
        openWindow(id: WindowID.compose, value: store.newDraft())
      }
      .keyboardShortcut("n")
      .disabled(store.accounts.isEmpty)
    }

    CommandMenu("Message") {
      Button("Get New Messages") {
        Task { await store.refreshAll() }
      }
      .keyboardShortcut("t", modifiers: [.command, .shift])

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

      Divider()

      Button("Toggle Read") {
        Task { await store.toggleRead() }
      }
      .keyboardShortcut("u", modifiers: [.command, .shift])
      .disabled(store.selectedMessageIDs.isEmpty)

      Button("Toggle Star") {
        Task { await store.toggleStar() }
      }
      .keyboardShortcut("s", modifiers: [.command, .option])
      .disabled(store.selectedMessageIDs.isEmpty)

      Divider()

      Button("Archive") {
        Task { await store.moveSelected(to: .archive) }
      }
      .keyboardShortcut("a", modifiers: [.command, .control])
      .disabled(store.selectedMessageIDs.isEmpty || !store.hasFolder(.archive))

      Button("Mark as Junk") {
        Task { await store.moveSelected(to: .junk) }
      }
      .keyboardShortcut("j", modifiers: [.command, .shift])
      .disabled(store.selectedMessageIDs.isEmpty || !store.hasFolder(.junk))

      Button("Delete") {
        Task { await store.deleteSelected() }
      }
      .keyboardShortcut(.delete)
      .disabled(store.selectedMessageIDs.isEmpty)
    }
  }
}
