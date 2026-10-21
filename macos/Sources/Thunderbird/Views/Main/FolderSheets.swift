/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import SwiftUI
import ThunderbirdCore

/// File › Subscribe… for IMAP accounts.
struct IMAPSubscribeView: View {
  @Environment(MailStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  let accountID: UUID
  @State private var folders: [(path: String, subscribed: Bool)] = []
  @State private var filter = ""
  @State private var loading = true
  @State private var error: String?

  private var visible: [(path: String, subscribed: Bool)] {
    let query = filter.lowercased()
    return folders.filter { query.isEmpty || ModifiedUTF7.decode($0.path).lowercased().contains(query) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Subscribe")
        .font(.title3.weight(.semibold))
      Text(store.account(accountID)?.label ?? "")
        .foregroundStyle(.secondary)
      TextField("Show items that contain", text: $filter)
        .textFieldStyle(.roundedBorder)
      List(visible, id: \.path) { folder in
        Toggle(
          isOn: Binding(
            get: { folder.subscribed },
            set: { value in
              if let index = folders.firstIndex(where: { $0.path == folder.path }) { folders[index].subscribed = value }
              Task { await store.setSubscribed(folder.path, value, accountID: accountID) }
            })
        ) {
          Text(ModifiedUTF7.decode(folder.path))
        }
      }
      .overlay {
        if loading {
          ProgressView()
        } else if let error {
          ContentUnavailableView("Couldn't List Folders", systemImage: "exclamationmark.triangle", description: Text(error))
        }
      }
      HStack {
        Spacer()
        Button("Done") { dismiss() }
          .buttonStyle(.glassProminent)
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 480, height: 520)
    .task {
      do {
        folders = try await store.backend(accountID)?.subscriptions() ?? []
      } catch {
        self.error = error.localizedDescription
      }
      loading = false
    }
  }
}

/// Folder › Properties…
struct FolderPropertiesView: View {
  @Environment(MailStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  let selection: FolderSelection
  @State private var messages: [MessageSummary] = []

  var body: some View {
    let folder = store.folder(selection)
    VStack(alignment: .leading, spacing: 0) {
      Form {
        Section("General Information") {
          LabeledContent("Name", value: folder?.displayName ?? selection.path)
          LabeledContent("Location", value: "\(store.account(selection.accountID)?.label ?? "") › \(ModifiedUTF7.decode(selection.path))")
          LabeledContent("Type", value: folder?.role == .normal ? "Folder" : folder?.role.unifiedTitle ?? "Folder")
          Toggle(
            "Favorite folder",
            isOn: Binding(get: { store.isFavorite(selection) }, set: { _ in store.toggleFavorite(selection) }))
        }
        Section("Messages") {
          LabeledContent("Total", value: "\(folder?.total ?? messages.count)")
          LabeledContent("Unread", value: "\(folder?.unseen ?? messages.filter { !$0.isRead }.count)")
          LabeledContent("Downloaded summaries", value: "\(messages.count)")
          LabeledContent("Size", value: messages.map(\.size).reduce(0, +).byteCountFormatted)
        }
        Section {
          Button("Repair Folder") {
            Task { await store.repairFolder(selection) }
            dismiss()
          }
        } footer: {
          Text("Discards the downloaded list of messages and fetches it again from the server.")
            .foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)
      HStack {
        Spacer()
        Button("Done") { dismiss() }
          .buttonStyle(.glassProminent)
          .keyboardShortcut(.defaultAction)
      }
      .padding(16)
    }
    .frame(width: 440, height: 480)
    .task {
      messages = await store.backend(selection.accountID)?.cachedMessages(in: selection.path) ?? []
    }
  }
}
