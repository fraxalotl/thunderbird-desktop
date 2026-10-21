/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import SwiftUI
import ThunderbirdCore

/// Message › Open in Conversation: every message in the thread, including your replies in Sent.
struct ConversationWindow: View {
  @Environment(MailStore.self) private var store
  let reference: MessageReference
  @State private var members: [MessageItem] = []
  @State private var selection: MessageReference?
  @State private var loaded: LoadedMessage?
  @State private var reader = ReaderController()

  var body: some View {
    NavigationSplitView {
      List(members, selection: $selection) { item in
        VStack(alignment: .leading, spacing: 2) {
          HStack {
            Text(item.summary.from.first?.displayName ?? "")
              .fontWeight(item.summary.isRead ? .regular : .semibold)
            Spacer()
            Text(item.summary.date.listFormatted).font(.caption).foregroundStyle(.secondary)
          }
          Text(store.folder(FolderSelection(accountID: item.reference.accountID, path: item.reference.path))?.displayName ?? "")
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .tag(item.reference)
      }
      .navigationSplitViewColumnWidth(min: 220, ideal: 260)
    } detail: {
      if let loaded {
        LoadedMessageView(message: loaded, isStandalone: true)
          .id(loaded.reference)
      } else {
        ProgressView()
      }
    }
    .environment(reader)
    .navigationTitle(members.first?.summary.subject ?? "Conversation")
    .task { await gather() }
    .onChange(of: selection) { _, new in
      guard let new else { return }
      Task { loaded = try? await store.loadMessage(new) }
    }
  }

  private func gather() async {
    let anchor = store.items.first { $0.reference == reference }?.summary
    let ids = Set(([anchor?.messageID].compactMap { $0 }) + (anchor?.references ?? []))
    var found: [MessageItem] = []
    var seen = Set<MessageReference>()
    func consider(_ item: MessageItem) {
      let summary = item.summary
      let related = ids.contains(summary.messageID ?? "-") || !ids.isDisjoint(with: summary.references)
      if related, seen.insert(item.reference).inserted { found.append(item) }
    }
    store.items.forEach(consider)
    for account in store.accounts {
      guard let backend = store.backend(account.id) else { continue }
      for folder in (store.folders[account.id] ?? []) where [.sent, .inbox, .archive].contains(folder.role) {
        for summary in await backend.cachedMessages(in: folder.path) {
          consider(MessageItem(reference: MessageReference(accountID: account.id, path: folder.path, uid: summary.uid), summary: summary))
        }
      }
    }
    if !seen.contains(reference), let anchor {
      found.append(MessageItem(reference: reference, summary: anchor))
    }
    members = found.sorted { $0.summary.date < $1.summary.date }
    selection = reference
  }
}

/// File › Open › Saved Message…
struct SavedMessageWindow: View {
  @Environment(MailStore.self) private var store
  let url: URL
  @State private var reader = ReaderController()

  var body: some View {
    Group {
      if let loaded = store.openSavedMessage(url) {
        LoadedMessageView(message: loaded, isStandalone: true)
      } else {
        ContentUnavailableView("Couldn't Open Message", systemImage: "exclamationmark.triangle", description: Text(url.lastPathComponent))
      }
    }
    .environment(reader)
    .navigationTitle(url.lastPathComponent)
  }
}
