/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import SwiftUI
import ThunderbirdCore

struct FolderSidebar: View {
  @Environment(MailStore.self) private var store
  @Environment(\.openSettings) private var openSettings
  let onAddAccount: () -> Void

  var body: some View {
    @Bindable var store = store
    List(selection: $store.selectedFolder) {
      ForEach(store.accounts) { account in
        Section {
          ForEach(store.sidebarFolders(for: account.id)) { item in
            FolderRow(item: item)
              .tag(FolderSelection(accountID: account.id, path: item.folder.path))
              .selectionDisabled(!item.folder.isSelectable)
          }
        } header: {
          AccountHeader(account: account)
        }
      }
    }
    .listStyle(.sidebar)
    .safeAreaInset(edge: .bottom) {
      HStack {
        Button(action: onAddAccount) {
          Label("Add Account", systemImage: "plus")
        }
        .buttonStyle(.glass)
        Spacer()
        Button {
          openSettings()
        } label: {
          Label("Account Settings", systemImage: "gearshape")
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.glass)
        .help("Account Settings")
      }
      .controlSize(.small)
      .padding(12)
    }
  }
}

private struct AccountHeader: View {
  @Environment(MailStore.self) private var store
  let account: MailAccount

  var body: some View {
    HStack(spacing: 6) {
      Text(account.label)
        .lineLimit(1)
      Spacer()
      if store.refreshing.contains(account.id) {
        ProgressView()
          .controlSize(.mini)
      } else if let error = store.accountErrors[account.id] {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.yellow)
          .help(error)
      }
    }
    .contextMenu {
      Button("Get Messages") {
        Task { await store.refresh(accountID: account.id) }
      }
    }
  }
}

private struct FolderRow: View {
  let item: SidebarFolder

  var body: some View {
    let folder = item.folder
    Label {
      Text(folder.displayName)
        .fontWeight(folder.role == .inbox && (folder.unseen ?? 0) > 0 ? .semibold : .regular)
        .lineLimit(1)
    } icon: {
      Image(systemName: folder.role.symbolName)
    }
    .padding(.leading, CGFloat(item.depth) * 14)
    .foregroundStyle(folder.isSelectable ? .primary : .secondary)
    .badge(folder.role == .trash || folder.role == .junk || folder.role == .sent ? 0 : folder.unseen ?? 0)
  }
}
