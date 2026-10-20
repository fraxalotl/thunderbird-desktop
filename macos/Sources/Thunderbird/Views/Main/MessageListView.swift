/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import SwiftUI
import ThunderbirdCore

struct MessageListView: View {
  @Environment(MailStore.self) private var store
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    @Bindable var store = store
    let messages = store.filteredMessages
    let showRecipients = [.sent, .drafts].contains(store.currentFolder?.role)
    List(messages, selection: $store.selectedMessageIDs) { message in
      MessageRow(message: message, showRecipients: showRecipients)
        .tag(message.uid)
    }
    .listStyle(.inset)
    .contextMenu(forSelectionType: UInt32.self) { selection in
      if !selection.isEmpty {
        contextMenu
      }
    }
    .safeAreaBar(edge: .top) {
      QuickFilterBar()
    }
    .overlay {
      if messages.isEmpty {
        if store.isFiltering {
          ContentUnavailableView.search(text: store.searchText)
        } else if store.activity == nil {
          ContentUnavailableView("No Messages", systemImage: "tray", description: Text("This folder is empty."))
        }
      }
    }
    .navigationTitle(store.currentFolder?.displayName ?? "Thunderbird")
    .navigationSubtitle(subtitle)
  }

  private var subtitle: String {
    let unread = store.messages.filter { !$0.isRead }.count
    let total = store.messages.count
    return unread > 0 ? "\(unread) unread of \(total)" : "\(total) messages"
  }

  @ViewBuilder
  private var contextMenu: some View {
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
    Button(store.selectedSummaries.allSatisfy(\.isRead) ? "Mark as Unread" : "Mark as Read") {
      Task { await store.toggleRead() }
    }
    Button(store.selectedSummaries.allSatisfy(\.isFlagged) ? "Remove Star" : "Add Star") {
      Task { await store.toggleStar() }
    }
    Divider()
    if store.hasFolder(.archive) {
      Button("Archive") { Task { await store.moveSelected(to: .archive) } }
    }
    if store.hasFolder(.junk) {
      Button("Mark as Junk") { Task { await store.moveSelected(to: .junk) } }
    }
    Button("Delete", role: .destructive) { Task { await store.deleteSelected() } }
  }
}

struct MessageRow: View {
  let message: MessageSummary
  let showRecipients: Bool

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
          Spacer(minLength: 4)
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
            .foregroundStyle(message.isRead ? .secondary : .primary)
            .lineLimit(1)
          Spacer(minLength: 4)
          if message.isFlagged {
            Image(systemName: "star.fill")
              .foregroundStyle(.yellow)
              .imageScale(.small)
              .accessibilityLabel("Starred")
          }
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
        Spacer(minLength: 0)
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
