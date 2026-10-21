/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import AppKit
import SwiftUI
import ThunderbirdCore

/// The message list's context menu (mail/base/content/mailContext.inc.xhtml), which differs from
/// the menu bar's Message menu: a row of quick actions, then Open, Reply, Reply with Template and
/// Forward and Redirect submenus, Organize and Threads.
struct MessageContextMenu: View {
  let store: MailStore
  let calendar: CalendarStore
  let ui: MailUIState?
  let openWindow: OpenWindowAction

  private var loaded: LoadedMessage? { store.loadedMessage }
  private var isSingle: Bool { store.selection.count == 1 && loaded != nil }
  private var isNews: Bool { loaded?.account.kind == .nntp }
  private var allRead: Bool { store.selectedItems.allSatisfy(\.summary.isRead) }
  private var allJunk: Bool { store.selectedItems.allSatisfy(\.summary.isJunk) }

  private func compose(_ draft: ComposeDraft?) {
    if let draft { openWindow(id: WindowID.compose, value: draft) }
  }

  var body: some View {
    ControlGroup {
      if allRead {
        Button("Mark as Unread", systemImage: "envelope.badge") { Task { await store.setFlag(MessageFlag.seen, on: false) } }
      } else {
        Button("Mark as Read", systemImage: "envelope.open") { Task { await store.setFlag(MessageFlag.seen, on: true) } }
      }
      Button("Reply", systemImage: "arrowshape.turn.up.left") { compose(store.replyDraft(isNews ? .newsgroup : .sender)) }
        .disabled(!isSingle)
      Button("Archive", systemImage: "archivebox") { Task { await store.moveSelected(to: .archive) } }
        .disabled(!store.canMoveSelection(to: .archive))
      if allJunk {
        Button("Mark as not Spam", systemImage: "flame.slash") { Task { await store.markJunk(false) } }
      } else {
        Button("Mark as Spam", systemImage: "flame") { Task { await store.markJunk(true) } }
      }
      Button("Delete", systemImage: "trash", role: .destructive) { Task { await store.deleteSelected() } }
    }
    .controlGroupStyle(.palette)

    if isSingle, let loaded {
      if loaded.folderRole == .drafts {
        Button("Edit Draft Message") { compose(store.reopenDraft(loaded)) }
      }
      if loaded.folderRole == .templates {
        Button("New Message from Template") { compose(store.reopenDraft(loaded)) }
        Button("Edit Template") { compose(store.editTemplate()) }
      }
      if loaded.folderRole == .drafts || loaded.folderRole == .templates {
        Divider()
      }
    }

    Menu("Open") {
      Button("Open Message in New Window") {
        for reference in store.selection { store.openMessageWindow(reference, using: openWindow) }
      }
      Button("Open Message in Conversation") {
        if let reference = store.selection.first { openWindow(id: WindowID.conversation, value: reference) }
      }
      .disabled(!isSingle)
      if store.selectedFolder == nil || store.selectedItems.contains(where: { FolderSelection(accountID: $0.reference.accountID, path: $0.reference.path) != store.selectedFolder }) {
        Button("Open Message in Containing Folder") {
          if let reference = store.selection.first {
            store.source = .folder(FolderSelection(accountID: reference.accountID, path: reference.path))
          }
        }
        .disabled(!isSingle)
      }
    }

    Menu("Reply") {
      if isNews {
        Button("Followup to Newsgroup") { compose(store.replyDraft(.newsgroup)) }
      }
      Button("Reply to Sender Only") { compose(store.replyDraft(.sender)) }
      Button("Reply to All") { compose(store.replyDraft(.all)) }
      Button("Reply to List") { compose(store.replyDraft(.list)) }
        .disabled(!store.canReplyToList(loaded))
    }
    .disabled(!isSingle)

    Menu("Reply with Template") {
      if store.localTemplates.isEmpty {
        Button("No Templates in Local Folders") {}
          .disabled(true)
      }
      ForEach(store.localTemplates) { template in
        Button(template.summary.subject.nilIfEmpty ?? "(no subject)") {
          guard let loaded else { return }
          Task { compose(await store.replyWithTemplate(template.reference, to: loaded)) }
        }
      }
    }
    .disabled(!isSingle)

    Menu("Forward and Redirect") {
      Button("Forward") { compose(store.forwardDraft(.preferred)) }
      Button("Inline") { compose(store.forwardDraft(.inline)) }
      Button("As Attachment") { compose(store.forwardDraft(.attachment)) }
      Divider()
      Button("Redirect") { if let loaded { ui?.present(.redirect(loaded)) } }
        .disabled(ui == nil)
    }
    .disabled(!isSingle)

    if isNews, isSingle {
      Button("Cancel Message") { if let loaded { Task { await store.cancelNewsMessage(loaded) } } }
    }
    Button("Edit As New Message") { compose(store.editAsNew()) }
      .disabled(!isSingle)

    Divider()

    if store.lastMoveTarget != nil {
      Button("Move Again") { Task { await store.moveAgain() } }
    }
    FolderPickerMenu(title: "Move To", store: store) { destination in
      Task { await store.transfer(Array(store.selection), to: destination, copy: false) }
    }
    FolderPickerMenu(title: "Copy To", store: store) { destination in
      Task { await store.transfer(Array(store.selection), to: destination, copy: true) }
    }
    TagMenu(store: store, ui: ui)
    Menu("Mark") {
      Button("As Read") { Task { await store.setFlag(MessageFlag.seen, on: true) } }
      Button("As Unread") { Task { await store.setFlag(MessageFlag.seen, on: false) } }
      Button("Thread As Read") { Task { await store.markThreadRead() } }
      Button("As Read by Date…") { ui?.present(.markReadByDate) }
      Button("All Read") { Task { await store.markAllRead() } }
      Divider()
      Button(store.selectedItems.allSatisfy(\.summary.isFlagged) ? "Remove Star" : "Add Star") {
        Task { await store.toggleStar() }
      }
      Divider()
      Button("As Spam") { Task { await store.markJunk(true) } }
      Button("As Not Spam") { Task { await store.markJunk(false) } }
      Button("Run Spam Controls") { Task { await store.runSpamControls(on: store.selection) } }
    }
    Menu("Organise") {
      Button("Archive") { Task { await store.moveSelected(to: .archive) } }
        .disabled(!store.canMoveSelection(to: .archive))
      if loaded?.security?.encrypted == true {
        FolderPickerMenu(title: "Create Decrypted Copy In", store: store) { destination in
          if let loaded { Task { await store.copyDecrypted(loaded, to: destination) } }
        }
      }
      Menu("Convert To") {
        Button("Event…") { if let loaded { ui?.present(.event(calendar.eventDraft(from: loaded))) } }
        Button("Task…") {
          if let loaded {
            do { try calendar.createTask(from: loaded) } catch { store.report(error, title: "Couldn't create the task") }
          }
        }
      }
      .disabled(!isSingle)
      Button("Copy Message Link") {
        guard let id = loaded?.parsed.messageID else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("mid:" + id.trimmingCharacters(in: CharacterSet(charactersIn: "<>")), forType: .string)
      }
      .disabled(loaded?.parsed.messageID == nil || !isSingle)
    }

    Divider()

    Menu("Threads") {
      let ignored = store.selectedItems.contains { store.ignoredThreads.contains($0.summary.references.first ?? $0.summary.messageID ?? "") }
      Button(ignored ? "Stop Ignoring Thread" : "Ignore Thread") { store.toggleIgnoreThread() }
      Button("Ignore Subthread") { store.toggleIgnoreThread(subthread: true) }
      Button(store.selectedItems.contains { store.isWatched($0.summary) } ? "Stop Watching Thread" : "Watch Thread") {
        store.toggleWatchThread()
      }
    }

    Divider()

    Button("Save As…") { saveAs() }
    Button("Print…") { ui?.reader.print() }
      .disabled(!isSingle || ui == nil)
  }

  /// One message is saved as an .eml file; several go into a chosen folder.
  private func saveAs() {
    let references = Array(store.selection)
    if references.count == 1, let loaded {
      let panel = NSSavePanel()
      panel.nameFieldStringValue = (loaded.parsed.subject.nilIfEmpty ?? "Message").replacingOccurrences(of: "/", with: "-") + ".eml"
      if panel.runModal() == .OK, let url = panel.url { try? loaded.raw.write(to: url) }
      return
    }
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = "Save"
    guard panel.runModal() == .OK, let folder = panel.url else { return }
    Task {
      for reference in references {
        guard let message = try? await store.loadMessage(reference) else { continue }
        let name = (message.parsed.subject.nilIfEmpty ?? "Message \(reference.uid)").replacingOccurrences(of: "/", with: "-")
        try? message.raw.write(to: folder.appending(path: "\(name).eml"))
      }
    }
  }
}
