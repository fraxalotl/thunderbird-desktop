/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import SwiftUI
import ThunderbirdCore

/// A row in the threaded list: a message and its replies.
struct ThreadNode: Identifiable, Hashable {
  var item: MessageItem
  var children: [ThreadNode]?
  var id: MessageReference { item.reference }

  init(_ thread: MessageThread<MessageItem>) {
    item = thread.root
    children = thread.replies.isEmpty ? nil : thread.replies.map(ThreadNode.init)
  }

  var unreadCount: Int {
    (item.summary.isRead ? 0 : 1) + (children ?? []).reduce(0) { $0 + $1.unreadCount }
  }

  var messageCount: Int { 1 + (children ?? []).reduce(0) { $0 + $1.messageCount } }
}

struct MessageListView: View {
  @Environment(MailStore.self) private var store
  @Environment(CalendarStore.self) private var calendar
  @Environment(\.openWindow) private var openWindow
  @State private var eventDraft: EventDraft?

  var body: some View {
    @Bindable var store = store
    let items = store.filteredItems
    let showRecipients = [.sent, .drafts, .outbox].contains(store.currentFolder?.role)
    let showFolder = store.selectedFolder == nil
    Group {
      if store.threaded {
        let nodes = Threading.threads(items) { $0.summary }.map(ThreadNode.init)
        List(nodes, children: \.children, selection: $store.selection) { node in
          MessageRow(
            item: node.item, showRecipients: showRecipients, showFolder: showFolder,
            threadCount: node.children == nil ? nil : node.messageCount)
            .tag(node.item.reference)
            .draggable(MessageDragPayload(references: dragReferences(node.item.reference)))
        }
      } else {
        List(items, selection: $store.selection) { item in
          MessageRow(item: item, showRecipients: showRecipients, showFolder: showFolder, threadCount: nil)
            .tag(item.reference)
            .draggable(MessageDragPayload(references: dragReferences(item.reference)))
        }
      }
    }
    .listStyle(.inset)
    .contextMenu(forSelectionType: MessageReference.self) { selection in
      if !selection.isEmpty {
        contextMenu
      }
    } primaryAction: { selection in
      guard selection.count == 1, let reference = selection.first else { return }
      Task { await open(reference) }
    }
    .safeAreaBar(edge: .top) {
      QuickFilterBar()
    }
    .overlay {
      if items.isEmpty {
        if store.isFiltering {
          ContentUnavailableView.search(text: store.searchText)
        } else if store.activity == nil {
          ContentUnavailableView("No Messages", systemImage: "tray", description: Text("This folder is empty."))
        }
      }
    }
    .navigationTitle(store.sourceTitle)
    .navigationSubtitle(subtitle)
    .sheet(item: $eventDraft) { draft in
      EventEditor(initial: draft)
    }
  }

  private func dragReferences(_ reference: MessageReference) -> [MessageReference] {
    store.selection.contains(reference) ? Array(store.selection) : [reference]
  }

  private var subtitle: String {
    let unread = store.items.filter { !$0.summary.isRead }.count
    let total = store.items.count
    return unread > 0 ? "\(unread) unread of \(total)" : "\(total) messages"
  }

  /// Double-click: drafts and templates open for editing, other messages open in their own window.
  private func open(_ reference: MessageReference) async {
    let role = store.role(of: reference)
    if role == .drafts || role == .templates || role == .outbox {
      if let loaded = try? await store.loadMessage(reference), let draft = store.reopenDraft(loaded) {
        openWindow(id: WindowID.compose, value: draft)
        return
      }
    }
    openWindow(id: WindowID.message, value: reference)
  }

  @ViewBuilder
  private var contextMenu: some View {
    Button("Open in New Window") {
      for reference in store.selection { openWindow(id: WindowID.message, value: reference) }
    }
    Divider()
    Button("Reply") {
      if let draft = store.replyDraft(all: false) { openWindow(id: WindowID.compose, value: draft) }
    }
    .disabled(store.loadedMessage == nil)
    Button("Reply All") {
      if let draft = store.replyDraft(all: true) { openWindow(id: WindowID.compose, value: draft) }
    }
    .disabled(store.loadedMessage == nil)
    Button("Forward") {
      if let draft = store.forwardDraft() { openWindow(id: WindowID.compose, value: draft) }
    }
    .disabled(store.loadedMessage == nil)
    Divider()
    Button(store.selectedItems.allSatisfy(\.summary.isRead) ? "Mark as Unread" : "Mark as Read") {
      Task { await store.toggleRead() }
    }
    Button(store.selectedItems.allSatisfy(\.summary.isFlagged) ? "Remove Star" : "Add Star") {
      Task { await store.toggleStar() }
    }
    Menu("Tag") {
      ForEach(MessageTag.defaults) { tag in
        Button {
          Task { await store.toggleTag(tag.keyword) }
        } label: {
          Label(tag.name, systemImage: store.selectedItems.allSatisfy { $0.summary.flags.contains(tag.keyword) } ? "checkmark" : "circle.fill")
        }
      }
      Divider()
      Button("Remove All Tags") { Task { await store.removeAllTags() } }
    }
    Divider()
    folderMenu("Move To", copy: false)
    folderMenu("Copy To", copy: true)
    if store.canMoveSelection(to: .archive) {
      Button("Archive") { Task { await store.moveSelected(to: .archive) } }
    }
    Divider()
    Menu("Convert To") {
      Button("Event…") {
        if let loaded = store.loadedMessage { eventDraft = calendar.eventDraft(from: loaded) }
      }
      Button("Task") {
        if let loaded = store.loadedMessage {
          do { try calendar.createTask(from: loaded) } catch { store.report(error, title: "Couldn't create the task") }
        }
      }
    }
    .disabled(store.loadedMessage == nil)
    Divider()
    Button("Mark as Junk") { Task { await store.markJunk(true) } }
    Button("Mark as Not Junk") { Task { await store.markJunk(false) } }
    Button("Delete", role: .destructive) { Task { await store.deleteSelected() } }
  }

  private func folderMenu(_ title: String, copy: Bool) -> some View {
    Menu(title) {
      ForEach(store.mailAccounts.filter { $0.kind != .nntp }) { account in
        Menu(account.label) {
          ForEach(store.sidebarFolders(for: account.id).filter(\.folder.isSelectable)) { item in
            Button(String(repeating: "   ", count: item.depth) + item.folder.displayName) {
              Task {
                await store.transfer(
                  Array(store.selection), to: FolderSelection(accountID: account.id, path: item.folder.path), copy: copy)
              }
            }
          }
        }
      }
    }
  }
}

struct MessageRow: View {
  @Environment(MailStore.self) private var store
  let item: MessageItem
  let showRecipients: Bool
  let showFolder: Bool
  let threadCount: Int?

  private var message: MessageSummary { item.summary }

  private var correspondent: String {
    let addresses = showRecipients ? message.to : message.from
    return addresses.map(\.displayName).joined(separator: ", ").nilIfEmpty ?? "(no sender)"
  }

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Circle()
        .fill(.tint)
        .frame(width: 8, height: 8)
        .padding(.top, 5)
        .opacity(message.isRead ? 0 : 1)
        .accessibilityLabel(message.isRead ? "" : "Unread")

      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(correspondent)
            .fontWeight(message.isRead ? .regular : .semibold)
            .lineLimit(1)
          if let threadCount {
            Text("\(threadCount)")
              .font(.caption2.weight(.semibold))
              .padding(.horizontal, 6)
              .padding(.vertical, 1)
              .glassEffect(.regular, in: .capsule)
              .accessibilityLabel("\(threadCount) messages in thread")
          }
          Spacer(minLength: 4)
          if message.isJunk {
            Image(systemName: "xmark.bin.fill")
              .foregroundStyle(.orange)
              .imageScale(.small)
              .accessibilityLabel("Junk")
          }
          if message.hasAttachment {
            Image(systemName: "paperclip")
              .foregroundStyle(.secondary)
              .imageScale(.small)
              .accessibilityLabel("Has attachment")
          }
          Text(message.date.listFormatted)
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        HStack(spacing: 4) {
          if message.isAnswered {
            Image(systemName: "arrowshape.turn.up.left.fill")
              .foregroundStyle(.purple)
              .imageScale(.small)
              .accessibilityLabel("Replied")
          } else if message.isForwarded {
            Image(systemName: "arrowshape.turn.up.right.fill")
              .foregroundStyle(.blue)
              .imageScale(.small)
              .accessibilityLabel("Forwarded")
          }
          Text(message.subject.nilIfEmpty ?? "(no subject)")
            .font(.callout)
            .foregroundStyle(message.tags.first.map { Color(hex: $0.colorHex) } ?? (message.isRead ? .secondary : .primary))
            .lineLimit(1)
          Spacer(minLength: 4)
          ForEach(message.tags) { tag in
            Circle()
              .fill(Color(hex: tag.colorHex))
              .frame(width: 7, height: 7)
              .help(tag.name)
          }
          if message.isFlagged {
            Image(systemName: "star.fill")
              .foregroundStyle(.yellow)
              .imageScale(.small)
              .accessibilityLabel("Starred")
          }
        }
        if showFolder {
          Text("\(store.account(item.reference.accountID)?.label ?? "") › \(store.folder(FolderSelection(accountID: item.reference.accountID, path: item.reference.path))?.displayName ?? item.reference.path)")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
      }
    }
    .padding(.vertical, 4)
  }
}

struct QuickFilterBar: View {
  @Environment(MailStore.self) private var store
  @Namespace private var namespace

  var body: some View {
    @Bindable var store = store
    GlassEffectContainer(spacing: 8) {
      HStack(spacing: 8) {
        FilterToggle(title: "Unread", symbol: "envelope.badge", activeSymbol: "envelope.badge.fill", isOn: $store.filterUnread, namespace: namespace)
        FilterToggle(title: "Starred", symbol: "star", activeSymbol: "star.fill", isOn: $store.filterStarred, namespace: namespace)
        FilterToggle(title: "Attachment", symbol: "paperclip", activeSymbol: "paperclip", isOn: $store.filterAttachments, namespace: namespace)
        Menu {
          Button("Any Tag") { store.filterTag = nil }
          Divider()
          ForEach(MessageTag.defaults) { tag in
            Button(tag.name) { store.filterTag = tag.keyword }
          }
        } label: {
          Label(MessageTag.defaults.first { $0.keyword == store.filterTag }?.name ?? "Tags", systemImage: "tag")
            .font(.callout)
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .fixedSize()
        Spacer(minLength: 0)
        Toggle(isOn: $store.threaded) {
          Label("Threads", systemImage: "text.line.first.and.arrowtriangle.forward")
            .labelStyle(.iconOnly)
        }
        .toggleStyle(.button)
        .buttonStyle(.glass)
        .help("Group messages into conversations")
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .animation(.bouncy, value: [store.filterUnread, store.filterStarred, store.filterAttachments])
  }
}

private struct FilterToggle: View {
  let title: String
  let symbol: String
  let activeSymbol: String
  @Binding var isOn: Bool
  let namespace: Namespace.ID

  var body: some View {
    Button {
      isOn.toggle()
    } label: {
      Label(title, systemImage: isOn ? activeSymbol : symbol)
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .foregroundStyle(isOn ? Color.white : Color.primary)
    }
    .buttonStyle(.plain)
    .glassEffect(isOn ? .regular.tint(.accentColor).interactive() : .regular.interactive(), in: .capsule)
    .glassEffectID(title, in: namespace)
    .accessibilityAddTraits(isOn ? .isSelected : [])
    .help("Show only \(title.lowercased()) messages")
  }
}

extension String {
  var nilIfEmpty: String? {
    trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
  }
}

extension Color {
  init(hex: String) {
    let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
    self.init(
      red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
      blue: Double(value & 0xFF) / 255)
  }
}
