/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import SwiftUI
import ThunderbirdCore

/// Message › Mark › As Read by Date…
struct MarkReadByDateSheet: View {
  @Environment(MailStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  @State private var start = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
  @State private var end = Date()

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Mark Messages as Read by Date")
        .font(.title3.weight(.semibold))
      DatePicker("From", selection: $start, displayedComponents: .date)
      DatePicker("To", selection: $end, in: start..., displayedComponents: .date)
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Mark as Read") {
          let to = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: end) ?? end
          let from = Calendar.current.startOfDay(for: start)
          Task { await store.markRead(from: from, to: to) }
          dismiss()
        }
        .buttonStyle(.glassProminent)
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(22)
    .frame(width: 360)
  }
}

/// Message › Tag › New Tag… (and editing from Manage Tags).
struct TagEditorSheet: View {
  @Environment(\.dismiss) private var dismiss
  let tag: MessageTag?
  @State private var name = ""
  @State private var color = Color.blue

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(tag == nil ? "New Tag" : "Edit Tag")
        .font(.title3.weight(.semibold))
      TextField("Tag name", text: $name)
        .textFieldStyle(.roundedBorder)
      ColorPicker("Colour", selection: $color, supportsOpacity: false)
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(tag == nil ? "Create" : "Save") {
          let hex = color.hexString
          if let tag {
            MessageTagStore.shared.update(tag.keyword, name: name, colorHex: hex)
          } else {
            MessageTagStore.shared.add(name: name, colorHex: hex)
          }
          dismiss()
        }
        .buttonStyle(.glassProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
    .padding(22)
    .frame(width: 340)
    .onAppear {
      name = tag?.name ?? ""
      color = tag.map { Color(hex: $0.colorHex) } ?? .blue
    }
  }
}

/// Message › Tag › Manage Tags…
struct ManageTagsSheet: View {
  @Environment(\.dismiss) private var dismiss
  @State private var editing: MessageTag?
  @State private var adding = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Tags")
        .font(.title3.weight(.semibold))
      List {
        ForEach(MessageTagStore.shared.tags) { tag in
          HStack {
            Image(systemName: "tag.fill").foregroundStyle(Color(hex: tag.colorHex))
            Text(tag.name)
            Spacer()
            Text(tag.keyword).font(.caption).foregroundStyle(.secondary)
            Button("Edit") { editing = tag }
            Button {
              MessageTagStore.shared.remove(tag.keyword)
            } label: {
              Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete \(tag.name)")
          }
        }
        .onMove { MessageTagStore.shared.move(from: $0, to: $1) }
      }
      HStack {
        Button("New Tag…") { adding = true }
          .buttonStyle(.glass)
        Spacer()
        Button("Done") { dismiss() }
          .buttonStyle(.glassProminent)
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 440, height: 400)
    .sheet(item: $editing) { tag in TagEditorSheet(tag: tag) }
    .sheet(isPresented: $adding) { TagEditorSheet(tag: nil) }
  }
}

/// Message › Create Filter From Message…
struct CreateFilterSheet: View {
  @Environment(MailStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  let summary: MessageSummary
  let accountID: UUID
  @State private var filter: MessageFilter

  init(summary: MessageSummary, accountID: UUID) {
    self.summary = summary
    self.accountID = accountID
    let sender = summary.from.first?.email ?? ""
    _filter = State(
      initialValue: MessageFilter(
        name: sender.isEmpty ? "New Filter" : "From \(sender)",
        conditions: [FilterCondition(field: .from, op: .contains, value: sender)],
        actions: [FilterAction(kind: .moveTo)]))
  }

  var body: some View {
    VStack(spacing: 0) {
      FilterEditor(filter: $filter, folders: store.sidebarFolders(for: accountID).map(\.folder))
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Save Filter") {
          FilterStore.save(FilterStore.filters(for: accountID) + [filter], for: accountID)
          dismiss()
        }
        .buttonStyle(.glassProminent)
        .keyboardShortcut(.defaultAction)
      }
      .padding(16)
    }
    .frame(width: 620, height: 520)
  }
}

/// Message › Redirect.
struct RedirectSheet: View {
  @Environment(MailStore.self) private var store
  @Environment(ContactsStore.self) private var contacts
  @Environment(\.dismiss) private var dismiss
  let loaded: LoadedMessage
  @State private var recipients = ""
  @State private var sending = false
  @State private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Redirect “\(loaded.parsed.subject)”")
        .font(.title3.weight(.semibold))
      Text("The message is resent unchanged, keeping the original sender, with Resent- headers added.")
        .font(.callout)
        .foregroundStyle(.secondary)
      TextField("To", text: $recipients, prompt: Text("name@example.com"))
        .textFieldStyle(.roundedBorder)
        .textInputSuggestions {
          let parts = recipients.components(separatedBy: ",")
          let prefix = parts.dropLast().map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
          ForEach(contacts.suggestions(for: parts.last ?? ""), id: \.email) { address in
            Text(address.formatted).textInputCompletion((prefix + [address.formatted]).joined(separator: ", ") + ", ")
          }
        }
      if let error {
        Text(error).foregroundStyle(.red)
      }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Redirect") {
          sending = true
          Task {
            do {
              try await store.redirect(loaded, to: MailAddress.parseList(recipients))
              dismiss()
            } catch {
              self.error = error.localizedDescription
            }
            sending = false
          }
        }
        .buttonStyle(.glassProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(MailAddress.parseList(recipients).isEmpty || sending)
      }
    }
    .padding(22)
    .frame(width: 460)
  }
}

extension MessageTag: @retroactive Identifiable {}

extension Color {
  var hexString: String {
    let color = NSColor(self).usingColorSpace(.sRGB) ?? .systemBlue
    return String(
      format: "#%02X%02X%02X", Int(color.redComponent * 255), Int(color.greenComponent * 255), Int(color.blueComponent * 255))
  }
}
