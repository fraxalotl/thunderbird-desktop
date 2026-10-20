/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import SwiftUI
import ThunderbirdCore
import UniformTypeIdentifiers

struct ComposeWindow: View {
  @Environment(MailStore.self) private var store
  @Environment(\.dismissWindow) private var dismissWindow
  @State private var draft: ComposeDraft
  @State private var showCc: Bool
  @State private var showBcc: Bool
  @State private var isSending = false
  @State private var sendError: String?
  @State private var showingFileImporter = false
  @FocusState private var focusedField: Field?

  private enum Field: Hashable {
    case to, cc, bcc, subject, body
  }

  init(initial: ComposeDraft) {
    _draft = State(initialValue: initial)
    _showCc = State(initialValue: !initial.cc.isEmpty)
    _showBcc = State(initialValue: !initial.bcc.isEmpty)
  }

  private var canSend: Bool {
    !isSending && !MailAddress.parseList(draft.to + "," + draft.cc + "," + draft.bcc).isEmpty
  }

  var body: some View {
    VStack(spacing: 0) {
      header
        .padding(12)

      TextEditor(text: $draft.body)
        .font(.body)
        .scrollContentBackground(.hidden)
        .contentMargins(.horizontal, 18, for: .scrollContent)
        .contentMargins(.vertical, 8, for: .scrollContent)
        .focused($focusedField, equals: .body)

      if !draft.attachments.isEmpty {
        attachments
          .padding(12)
      }
    }
    .background(.background)
    .navigationTitle(draft.subject.nilIfEmpty ?? "Write")
    .toolbar { toolbar }
    .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) {
      result in
      if case .success(let urls) = result {
        draft.attachments.append(contentsOf: urls)
      }
    }
    .dropDestination(for: URL.self) { urls, _ in
      let files = urls.filter(\.isFileURL)
      draft.attachments.append(contentsOf: files)
      return !files.isEmpty
    }
    .alert(
      "Couldn't Send Message",
      isPresented: Binding(get: { sendError != nil }, set: { if !$0 { sendError = nil } }),
      presenting: sendError
    ) { _ in
      Button("OK") {}
    } message: { error in
      Text(error)
    }
    .onAppear {
      if draft.accountID == nil {
        draft.accountID = store.currentAccount?.id ?? store.accounts.first?.id
      }
      focusedField = draft.to.isEmpty ? .to : .body
    }
    .disabled(isSending)
  }

  @ToolbarContentBuilder
  private var toolbar: some ToolbarContent {
    ToolbarItem(placement: .navigation) {
      Button {
        showingFileImporter = true
      } label: {
        Label("Attach", systemImage: "paperclip")
      }
      .help("Attach files")
    }

    ToolbarItemGroup(placement: .primaryAction) {
      Toggle(isOn: $showCc.animation(.smooth)) {
        Text("Cc")
      }
      .help("Show the Cc field")
      Toggle(isOn: $showBcc.animation(.smooth)) {
        Text("Bcc")
      }
      .help("Show the Bcc field")
    }

    ToolbarSpacer(.fixed, placement: .primaryAction)

    ToolbarItem(placement: .primaryAction) {
      Button {
        Task { await send() }
      } label: {
        if isSending {
          ProgressView()
            .controlSize(.small)
        } else {
          Label("Send", systemImage: "paperplane.fill")
        }
      }
      .buttonStyle(.glassProminent)
      .keyboardShortcut(.return, modifiers: .command)
      .disabled(!canSend)
      .help("Send (⌘↩)")
    }
  }

  private var header: some View {
    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
      GridRow {
        fieldLabel("From")
        Picker("From", selection: $draft.accountID) {
          ForEach(store.accounts) { account in
            Text(account.address.formatted)
              .tag(Optional(account.id))
          }
        }
        .labelsHidden()
        .fixedSize()
        .gridColumnAlignment(.leading)
      }
      Divider().gridCellUnsizedAxes(.horizontal)
      addressRow("To", text: $draft.to, field: .to)
      if showCc {
        Divider().gridCellUnsizedAxes(.horizontal)
        addressRow("Cc", text: $draft.cc, field: .cc)
      }
      if showBcc {
        Divider().gridCellUnsizedAxes(.horizontal)
        addressRow("Bcc", text: $draft.bcc, field: .bcc)
      }
      Divider().gridCellUnsizedAxes(.horizontal)
      GridRow {
        fieldLabel("Subject")
        TextField("Subject", text: $draft.subject)
          .textFieldStyle(.plain)
          .font(.body.weight(.medium))
          .focused($focusedField, equals: .subject)
          .onSubmit { focusedField = .body }
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .glassEffect(.regular, in: .rect(cornerRadius: 18))
  }

  private func fieldLabel(_ text: String) -> some View {
    Text(text)
      .foregroundStyle(.secondary)
      .gridColumnAlignment(.trailing)
  }

  private func addressRow(_ label: String, text: Binding<String>, field: Field) -> some View {
    GridRow {
      fieldLabel(label)
      TextField(label, text: text, prompt: Text("name@example.com"))
        .textFieldStyle(.plain)
        .focused($focusedField, equals: field)
        .textContentType(.emailAddress)
        .autocorrectionDisabled()
    }
  }

  private var attachments: some View {
    ScrollView(.horizontal) {
      GlassEffectContainer(spacing: 8) {
        HStack(spacing: 8) {
          ForEach(draft.attachments, id: \.self) { url in
            HStack(spacing: 6) {
              Image(systemName: "doc")
              Text(url.lastPathComponent)
                .lineLimit(1)
              Button {
                draft.attachments.removeAll { $0 == url }
              } label: {
                Image(systemName: "xmark.circle.fill")
                  .foregroundStyle(.secondary)
              }
              .buttonStyle(.plain)
              .accessibilityLabel("Remove \(url.lastPathComponent)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .glassEffect(.regular, in: .capsule)
          }
        }
        .padding(2)
      }
    }
    .scrollIndicators(.never)
  }

  private func send() async {
    isSending = true
    defer { isSending = false }
    do {
      try await store.send(draft)
      dismissWindow()
    } catch {
      sendError = error.localizedDescription
    }
  }
}
