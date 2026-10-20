/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import SwiftUI
import ThunderbirdCore

struct MainWindow: View {
  @Environment(MailStore.self) private var store
  @Environment(\.openWindow) private var openWindow
  @State private var showingAccountSetup = false
  @State private var columnVisibility = NavigationSplitViewVisibility.all

  var body: some View {
    @Bindable var store = store
    Group {
      if store.accounts.isEmpty {
        WelcomeView(onSetUp: { showingAccountSetup = true })
      } else {
        NavigationSplitView(columnVisibility: $columnVisibility) {
          FolderSidebar(onAddAccount: { showingAccountSetup = true })
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } content: {
          MessageListView()
            .navigationSplitViewColumnWidth(min: 300, ideal: 400)
        } detail: {
          MessageReaderView()
        }
        .searchable(text: $store.searchText, placement: .toolbar, prompt: "Quick Filter")
        .toolbar { toolbar }
      }
    }
    .overlay(alignment: .bottom) {
      if let activity = store.activity {
        ActivityPill(text: activity)
          .padding(.bottom, 16)
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .animation(.smooth, value: store.activity)
    .sheet(isPresented: $showingAccountSetup) {
      AccountSetupView()
    }
    .alert(item: $store.presentedError) { error in
      Alert(title: Text(error.title), message: Text(error.message))
    }
    .onOpenURL { url in
      guard url.scheme?.lowercased() == "mailto" else { return }
      let address = url.absoluteString.dropFirst("mailto:".count).split(separator: "?").first.map(String.init) ?? ""
      openWindow(id: WindowID.compose, value: store.newDraft(to: address.removingPercentEncoding ?? address))
    }
  }

  @ToolbarContentBuilder
  private var toolbar: some ToolbarContent {
    ToolbarItemGroup(placement: .navigation) {
      Button {
        Task { await store.refreshAll() }
      } label: {
        Label("Get Messages", systemImage: "arrow.down.circle")
      }
      .help("Get new messages for all accounts")
      .disabled(!store.refreshing.isEmpty)
    }

    ToolbarItem(placement: .primaryAction) {
      Button {
        openWindow(id: WindowID.compose, value: store.newDraft())
      } label: {
        Label("Write", systemImage: "square.and.pencil")
      }
      .help("Write a new message")
    }

    ToolbarSpacer(.fixed, placement: .primaryAction)

    ToolbarItemGroup(placement: .primaryAction) {
      Group {
        Button {
          if let draft = store.replyDraft(all: false) { openWindow(id: WindowID.compose, value: draft) }
        } label: {
          Label("Reply", systemImage: "arrowshape.turn.up.left")
        }
        .help("Reply to the sender")
        Button {
          if let draft = store.replyDraft(all: true) { openWindow(id: WindowID.compose, value: draft) }
        } label: {
          Label("Reply All", systemImage: "arrowshape.turn.up.left.2")
        }
        .help("Reply to everyone")
        Button {
          if let draft = store.forwardDraft() { openWindow(id: WindowID.compose, value: draft) }
        } label: {
          Label("Forward", systemImage: "arrowshape.turn.up.right")
        }
        .help("Forward this message")
      }
      .disabled(store.loadedMessage == nil)
    }

    ToolbarSpacer(.fixed, placement: .primaryAction)

    ToolbarItemGroup(placement: .primaryAction) {
      Group {
        Button {
          Task { await store.moveSelected(to: .archive) }
        } label: {
          Label("Archive", systemImage: "archivebox")
        }
        .help("Archive")
        .disabled(!store.hasFolder(.archive))
        Button {
          Task { await store.moveSelected(to: .junk) }
        } label: {
          Label("Junk", systemImage: "xmark.bin")
        }
        .help("Mark as junk")
        .disabled(!store.hasFolder(.junk))
        Button {
          Task { await store.deleteSelected() }
        } label: {
          Label("Delete", systemImage: "trash")
        }
        .help("Delete")
      }
      .disabled(store.selectedMessageIDs.isEmpty)
    }
  }
}

struct ActivityPill: View {
  let text: String

  var body: some View {
    HStack(spacing: 8) {
      ProgressView()
        .controlSize(.small)
      Text(text)
        .font(.callout)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .glassEffect(.regular, in: .capsule)
  }
}
