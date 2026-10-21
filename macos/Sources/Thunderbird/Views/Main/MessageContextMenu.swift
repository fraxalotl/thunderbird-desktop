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
  /// The messages the menu was opened on, which may not be the current selection yet.
  let targets: Set<MessageReference>

  private var targetItems: [MessageItem] { store.items.filter { targets.contains($0.reference) } }
  private var isSingle: Bool { targets.count == 1 }
  private var role: FolderRole { targets.first.map(store.role(of:)) ?? .normal }
  private var isNews: Bool { store.account(targets.first?.accountID)?.kind == .nntp }
  private var allRead: Bool { targetItems.allSatisfy(\.summary.isRead) }
  private var allJunk: Bool { targetItems.allSatisfy(\.summary.isJunk) }
  private var allStarred: Bool { targetItems.allSatisfy(\.summary.isFlagged) }
  private var canArchive: Bool { store.canMove(targets, to: .archive) }

  private func compose(_ draft: ComposeDraft?) {
    if let draft { openWindow(id: WindowID.compose, value: draft) }
  }

  /// Selects the clicked messages, then runs the command with the loaded message (if single).
  private func act(_ body: @escaping @MainActor (LoadedMessage?) async -> Void) {
    Task { @MainActor in
      await store.focusSelection(targets)
      await body(isSingle ? store.loadedMessage : nil)
    }
  }

  var body: some View {
    ControlGroup {
      if allRead {
        Button("Mark as Unread", systemImage: "envelope.badge") { act { _ in await store.setFlag(MessageFlag.seen, on: false) } }
      } else {
        Button("Mark as Read", systemImage: "envelope.open") { act { _ in await store.setFlag(MessageFlag.seen, on: true) } }
      }
      Button("Reply", systemImage: "arrowshape.turn.up.left") {
        act { loaded in compose(store.replyDraft(isNews ? .newsgroup : .sender, to: loaded)) }
      }
      .disabled(!isSingle)
      Button("Archive", systemImage: "archivebox") { act { _ in await store.moveSelected(to: .archive) } }
        .disabled(!canArchive)
      if allJunk {
        Button("Mark as not Spam", systemImage: "flame.slash") { act { _ in await store.markJunk(false) } }
      } else {
        Button("Mark as Spam", systemImage: "flame") { act { _ in await store.markJunk(true) } }
      }
      Button("Delete", systemImage: "trash", role: .destructive) { act { _ in await store.deleteSelected() } }
    }
    .controlGroupStyle(.palette)

    if isSingle {
      if role == .drafts {
        Button("Edit Draft Message") { act { loaded in compose(loaded.flatMap(store.reopenDraft)) } }
      }
      if role == .templates {
        Button("New Message from Template") { act { loaded in compose(loaded.flatMap(store.reopenDraft)) } }
        Button("Edit Template") { act { _ in compose(store.editTemplate()) } }
      }
      if role == .drafts || role == .templates {
        Divider()
      }
    }

    Menu("Open") {
      Button("Open Message in New Window") {
        for reference in targets { store.openMessageWindow(reference, using: openWindow) }
      }
      Button("Open Message in Conversation") {
        if let reference = targets.first { openWindow(id: WindowID.conversation, value: reference) }
      }
      .disabled(!isSingle)
      if store.selectedFolder == nil
        || targets.contains(where: { FolderSelection(accountID: $0.accountID, path: $0.path) != store.selectedFolder })
      {
        Button("Open Message in Containing Folder") {
          if let reference = targets.first {
            store.source = .folder(FolderSelection(accountID: reference.accountID, path: reference.path))
            store.selection = [reference]
          }
        }
        .disabled(!isSingle)
      }
    }

    Menu("Reply") {
      if isNews {
        Button("Followup to Newsgroup") { act { loaded in compose(store.replyDraft(.newsgroup, to: loaded)) } }
      }
      Button("Reply to Sender Only") { act { loaded in compose(store.replyDraft(.sender, to: loaded)) } }
      Button("Reply to All") { act { loaded in compose(store.replyDraft(.all, to: loaded)) } }
      Button("Reply to List") { act { loaded in compose(store.replyDraft(.list, to: loaded)) } }
        .disabled(targetItems.first?.summary.listPost == nil)
    }
    .disabled(!isSingle)

    Menu("Reply with Template") {
      if store.localTemplates.isEmpty {
        Button("No Templates in Local Folders") {}
          .disabled(true)
      }
      ForEach(store.localTemplates) { template in
        Button(template.summary.subject.nilIfEmpty ?? "(no subject)") {
          act { loaded in
            guard let loaded else { return }
            compose(await store.replyWithTemplate(template.reference, to: loaded))
          }
        }
      }
    }
    .disabled(!isSingle)

    Menu("Forward and Redirect") {
      Button("Forward") { act { loaded in compose(store.forwardDraft(.preferred, loaded)) } }
      Button("Inline") { act { loaded in compose(store.forwardDraft(.inline, loaded)) } }
      Button("As Attachment") { act { loaded in compose(store.forwardDraft(.attachment, loaded)) } }
      Divider()
      Button("Redirect") { act { loaded in if let loaded { ui?.present(.redirect(loaded)) } } }
        .disabled(ui == nil)
    }
    .disabled(!isSingle)

    if isNews, isSingle {
      Button("Cancel Message") { act { loaded in if let loaded { await store.cancelNewsMessage(loaded) } } }
    }
    Button("Edit As New Message") { act { _ in compose(store.editAsNew()) } }
      .disabled(!isSingle)

    Divider()

    if store.lastMoveTarget != nil {
      Button("Move Again") { act { _ in await store.moveAgain() } }
    }
    FolderPickerMenu(title: "Move To", store: store) { destination in
      Task { await store.transfer(Array(targets), to: destination, copy: false) }
    }
    FolderPickerMenu(title: "Copy To", store: store) { destination in
      Task { await store.transfer(Array(targets), to: destination, copy: true) }
    }
    Menu("Tag") {
      Button("New Tag…") { act { _ in ui?.present(.newTag) } }
        .disabled(ui == nil)
      Button("Manage Tags…") { ui?.present(.manageTags) }
        .disabled(ui == nil)
      Divider()
      Button("Remove All Tags") { act { _ in await store.removeAllTags() } }
      Divider()
      ForEach(Array(MessageTagStore.shared.tags.enumerated()), id: \.element.keyword) { index, tag in
        Toggle(
          isOn: Binding(
            get: { !targetItems.isEmpty && targetItems.allSatisfy { $0.summary.flags.contains(tag.keyword) } },
            set: { _ in act { _ in await store.toggleTag(tag.keyword) } })
        ) {
          Text("\(index < 9 ? "\(index + 1) " : "")\(tag.name)")
        }
      }
    }
    Menu("Mark") {
      Button("As Read") { act { _ in await store.setFlag(MessageFlag.seen, on: true) } }
      Button("As Unread") { act { _ in await store.setFlag(MessageFlag.seen, on: false) } }
      Button("Thread As Read") { act { _ in await store.markThreadRead() } }
      Button("As Read by Date…") { ui?.present(.markReadByDate) }
      Button("All Read") { Task { await store.markAllRead() } }
      Divider()
      Button(allStarred ? "Remove Star" : "Add Star") { act { _ in await store.toggleStar() } }
      Divider()
      Button("As Spam") { act { _ in await store.markJunk(true) } }
      Button("As Not Spam") { act { _ in await store.markJunk(false) } }
      Button("Run Spam Controls") { Task { await store.runSpamControls(on: targets) } }
    }
    Menu("Organise") {
      Button("Archive") { act { _ in await store.moveSelected(to: .archive) } }
        .disabled(!canArchive)
      if isSingle, store.loadedMessage?.reference == targets.first, store.loadedMessage?.security?.encrypted == true {
        FolderPickerMenu(title: "Create Decrypted Copy In", store: store) { destination in
          act { loaded in if let loaded { await store.copyDecrypted(loaded, to: destination) } }
        }
      }
      Menu("Convert To") {
        Button("Event…") { act { loaded in if let loaded { ui?.present(.event(calendar.eventDraft(from: loaded))) } } }
        Button("Task…") {
          act { loaded in
            guard let loaded else { return }
            do { try calendar.createTask(from: loaded) } catch { store.report(error, title: "Couldn't create the task") }
          }
        }
      }
      .disabled(!isSingle)
      Button("Copy Message Link") {
        guard let id = targetItems.first?.summary.messageID else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("mid:" + id.trimmingCharacters(in: CharacterSet(charactersIn: "<>")), forType: .string)
      }
      .disabled(!isSingle || targetItems.first?.summary.messageID == nil)
    }

    Divider()

    Menu("Threads") {
      let ignored = targetItems.contains { store.ignoredThreads.contains($0.summary.references.first ?? $0.summary.messageID ?? "") }
      Button(ignored ? "Stop Ignoring Thread" : "Ignore Thread") { act { _ in store.toggleIgnoreThread() } }
      Button("Ignore Subthread") { act { _ in store.toggleIgnoreThread(subthread: true) } }
      Button(targetItems.contains { store.isWatched($0.summary) } ? "Stop Watching Thread" : "Watch Thread") {
        act { _ in store.toggleWatchThread() }
      }
    }

    Divider()

    Button("Save As…") { saveAs() }
    Button("Print…") { act { _ in ui?.reader.print() } }
      .disabled(!isSingle || ui == nil)
  }

  /// One message is saved as an .eml file; several go into a chosen folder.
  private func saveAs() {
    let references = Array(targets)
    if references.count == 1, let reference = references.first {
      let subject = targetItems.first?.summary.subject.nilIfEmpty ?? "Message"
      let panel = NSSavePanel()
      panel.nameFieldStringValue = subject.replacingOccurrences(of: "/", with: "-") + ".eml"
      guard panel.runModal() == .OK, let url = panel.url else { return }
      Task { if let message = try? await store.loadMessage(reference) { try? message.raw.write(to: url) } }
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
