/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import SwiftUI
import ThunderbirdCore
import UniformTypeIdentifiers

struct ComposeWindow: View {
  @Environment(MailStore.self) private var store
  @Environment(ContactsStore.self) private var contacts
  @Environment(\.dismissWindow) private var dismissWindow
  @State private var draft: ComposeDraft
  @State private var showCc: Bool
  @State private var showBcc: Bool
  @State private var isBusy = false
  @State private var sent = false
  @State private var isDirty = false
  @State private var lastSaved: Date?
  @State private var sendError: String?
  @State private var showingFileImporter = false
  @State private var confirmingNoAttachment = false
  @State private var editor = RichTextController()
  @FocusState private var focusedField: Field?

  private enum Field: Hashable {
    case to, cc, bcc, newsgroups, subject, body
  }

  init(initial: ComposeDraft) {
    _draft = State(initialValue: initial)
    _showCc = State(initialValue: !initial.cc.isEmpty)
    _showBcc = State(initialValue: !initial.bcc.isEmpty)
  }

  private var account: MailAccount? { store.identity(for: draft)?.0 }
  private var isNews: Bool { account?.kind == .nntp }

  private var canSend: Bool {
    !isBusy && (!MailAddress.parseList(draft.to + "," + draft.cc + "," + draft.bcc).isEmpty || !draft.newsgroups.isEmpty)
  }

  private var securityAvailable: Bool {
    guard let account, let identity = store.identity(for: draft)?.1 else { return false }
    switch account.securityTechnology {
    case .openPGP: return OpenPGP.shared.isAvailable && !OpenPGP.shared.keys(for: identity.email).filter(\.hasSecret).isEmpty
    case .smime: return SMIME.hasIdentity(for: identity.email)
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      header
        .padding(12)

      if draft.isHTML {
        FormatBar(controller: editor)
          .padding(.horizontal, 12)
          .padding(.bottom, 8)
          .frame(maxWidth: .infinity, alignment: .leading)
        RichTextEditor(controller: editor, initialHTML: draft.htmlBody ?? "") { isDirty = true }
          .clipShape(.rect(cornerRadius: 14))
          .padding(.horizontal, 12)
      } else {
        TextEditor(text: $draft.body)
          .font(.body.monospaced())
          .scrollContentBackground(.hidden)
          .contentMargins(.horizontal, 18, for: .scrollContent)
          .contentMargins(.vertical, 8, for: .scrollContent)
          .focused($focusedField, equals: .body)
          .onChange(of: draft.body) { isDirty = true }
      }

      if !draft.attachments.isEmpty {
        attachments
          .padding(12)
      } else {
        Spacer().frame(height: 12)
      }
    }
    .background(.background)
    .navigationTitle(draft.subject.nilIfEmpty ?? "Write")
    .navigationSubtitle(lastSaved.map { "Draft saved \($0.formatted(date: .omitted, time: .shortened))" } ?? "")
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
    .confirmationDialog("Did you forget an attachment?", isPresented: $confirmingNoAttachment) {
      Button("Attach Files…") { showingFileImporter = true }
      Button("Send Anyway") { Task { await send(skipReminder: true) } }
    } message: {
      Text("Your message mentions an attachment, but nothing is attached.")
    }
    .onAppear {
      if draft.accountID == nil {
        draft.accountID = store.sendingAccounts.first?.id
        draft.identityID = draft.accountID
      }
      focusedField = draft.to.isEmpty && draft.newsgroups.isEmpty ? .to : (draft.isHTML ? nil : .body)
    }
    .onDisappear {
      if isDirty && !sent {
        let snapshot = currentDraft()
        Task { try? await store.saveDraft(snapshot) }
      }
    }
    .task {
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(300))
        if isDirty && !sent { await saveDraft(silently: true) }
      }
    }
    .onChange(of: draft.to) { isDirty = true }
    .onChange(of: draft.subject) { isDirty = true }
    .disabled(isBusy)
  }

  @ToolbarContentBuilder
  private var toolbar: some ToolbarContent {
    ToolbarItemGroup(placement: .navigation) {
      Button {
        showingFileImporter = true
      } label: {
        Label("Attach", systemImage: "paperclip")
      }
      .help("Attach files")
      Menu {
        Button("Save Draft") { Task { await saveDraft(silently: false) } }
          .keyboardShortcut("s")
        Button("Save as Template") { Task { await saveTemplate() } }
      } label: {
        Label("Save", systemImage: "square.and.arrow.down")
      }
      .help("Save as draft or template")
    }

    ToolbarItemGroup(placement: .primaryAction) {
      Toggle(isOn: Binding(get: { draft.isHTML }, set: { switchFormat(toHTML: $0) })) {
        Label("Rich Text", systemImage: "textformat")
      }
      .help(draft.isHTML ? "Switch to plain text" : "Switch to rich text (HTML)")
      .disabled(isNews)
      if !isNews {
        Toggle(isOn: $showCc.animation(.smooth)) { Text("Cc") }
          .help("Show the Cc field")
        Toggle(isOn: $showBcc.animation(.smooth)) { Text("Bcc") }
          .help("Show the Bcc field")
      }
    }

    ToolbarSpacer(.fixed, placement: .primaryAction)

    ToolbarItemGroup(placement: .primaryAction) {
      Toggle(isOn: $draft.encrypt) {
        Label("Encrypt", systemImage: draft.encrypt ? "lock.fill" : "lock.open")
      }
      .help(securityAvailable ? "Encrypt with \(account?.securityTechnology.label ?? "")" : "Set up end-to-end encryption in Account Settings")
      .disabled(!securityAvailable || isNews)
      Toggle(isOn: $draft.sign) {
        Label("Sign", systemImage: draft.sign ? "checkmark.seal.fill" : "checkmark.seal")
      }
      .help("Digitally sign this message")
      .disabled(!securityAvailable)
    }

    ToolbarSpacer(.fixed, placement: .primaryAction)

    ToolbarItemGroup(placement: .primaryAction) {
      Menu {
        Button("Send Later") { Task { await sendLater() } }
      } label: {
        if isBusy {
          ProgressView().controlSize(.small)
        } else {
          Label("Send", systemImage: "paperplane.fill")
        }
      } primaryAction: {
        Task { await send(skipReminder: false) }
      }
      .buttonStyle(.glassProminent)
      .keyboardShortcut(.return, modifiers: .command)
      .disabled(!canSend)
      .help("Send (⌘↩)")
    }
  }

  private var identityTag: Binding<String> {
    Binding(
      get: { "\(draft.accountID?.uuidString ?? "")|\(draft.identityID?.uuidString ?? draft.accountID?.uuidString ?? "")" },
      set: { value in
        let parts = value.split(separator: "|").map(String.init)
        draft.accountID = parts.first.flatMap(UUID.init(uuidString:))
        draft.identityID = parts.count > 1 ? UUID(uuidString: parts[1]) : draft.accountID
      })
  }

  private var header: some View {
    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
      GridRow {
        fieldLabel("From")
        Picker("From", selection: identityTag) {
          ForEach(store.sendingAccounts) { account in
            Section(account.label) {
              ForEach(account.identities) { identity in
                Text(identity.address.formatted)
                  .tag("\(account.id.uuidString)|\(identity.id.uuidString)")
              }
            }
          }
        }
        .labelsHidden()
        .fixedSize()
        .gridColumnAlignment(.leading)
      }
      if isNews {
        Divider().gridCellUnsizedAxes(.horizontal)
        GridRow {
          fieldLabel("Newsgroups")
          TextField("Newsgroups", text: $draft.newsgroups, prompt: Text("comp.mail.misc"))
            .textFieldStyle(.plain)
            .focused($focusedField, equals: .newsgroups)
        }
      }
      Divider().gridCellUnsizedAxes(.horizontal)
      addressRow("To", text: $draft.to, field: .to)
      if showCc && !isNews {
        Divider().gridCellUnsizedAxes(.horizontal)
        addressRow("Cc", text: $draft.cc, field: .cc)
      }
      if showBcc && !isNews {
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
          .onSubmit { focusedField = draft.isHTML ? nil : .body }
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .glassEffect(.regular, in: .rect(cornerRadius: 18))
    .overlay(alignment: .topTrailing) {
      if draft.encrypt || draft.sign {
        Label(
          [draft.encrypt ? "Encrypted" : nil, draft.sign ? "Signed" : nil].compactMap { $0 }.joined(separator: " · "),
          systemImage: draft.encrypt ? "lock.fill" : "checkmark.seal.fill"
        )
        .font(.caption.weight(.medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .glassEffect(.regular.tint(.green.opacity(0.4)), in: .capsule)
        .padding(10)
      }
    }
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
        .textInputSuggestions {
          let parts = text.wrappedValue.components(separatedBy: ",")
          let fragment = parts.last ?? ""
          let prefix = parts.dropLast().map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
          ForEach(contacts.suggestions(for: fragment), id: \.email) { address in
            Text(address.formatted)
              .textInputCompletion((prefix + [address.formatted]).joined(separator: ", ") + ", ")
          }
        }
    }
  }

  private var attachments: some View {
    ScrollView(.horizontal) {
      GlassEffectContainer(spacing: 8) {
        HStack(spacing: 8) {
          ForEach(draft.attachments, id: \.self) { url in
            HStack(spacing: 6) {
              Image(systemName: AttachmentFiles.symbol(for: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? ""))
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

  // MARK: - Actions

  private func switchFormat(toHTML: Bool) {
    if toHTML {
      draft.htmlBody = "<pre style=\"font-family: Helvetica; white-space: pre-wrap\">\(ComposeDraft.escape(draft.body))</pre>"
      draft.isHTML = true
    } else {
      draft.body = editor.plainText
      draft.isHTML = false
    }
    isDirty = true
  }

  /// The draft with the editor's current contents copied in.
  private func currentDraft() -> ComposeDraft {
    var snapshot = draft
    if draft.isHTML {
      snapshot.htmlBody = editor.html
      snapshot.body = editor.plainText
    }
    return snapshot
  }

  private var mentionsAttachment: Bool {
    let text = (draft.isHTML ? editor.plainText : draft.body).lowercased()
    let ownText = text.components(separatedBy: "\n").filter { !$0.hasPrefix(">") }.joined(separator: "\n")
    return ["attach", "attached", "attachment", "enclosed", "see the file"].contains { ownText.contains($0) }
  }

  private func send(skipReminder: Bool) async {
    if !skipReminder && draft.attachments.isEmpty && mentionsAttachment {
      confirmingNoAttachment = true
      return
    }
    isBusy = true
    defer { isBusy = false }
    do {
      try await store.send(currentDraft())
      sent = true
      dismissWindow()
    } catch {
      sendError = error.localizedDescription
    }
  }

  private func sendLater() async {
    isBusy = true
    defer { isBusy = false }
    do {
      try await store.sendLater(currentDraft())
      sent = true
      dismissWindow()
    } catch {
      sendError = error.localizedDescription
    }
  }

  private func saveDraft(silently: Bool) async {
    do {
      draft.draftMessageID = try await store.saveDraft(currentDraft())
      isDirty = false
      lastSaved = Date()
    } catch {
      if !silently { sendError = error.localizedDescription }
    }
  }

  private func saveTemplate() async {
    do {
      try await store.saveDraft(currentDraft(), asTemplate: true)
    } catch {
      sendError = error.localizedDescription
    }
  }
}
