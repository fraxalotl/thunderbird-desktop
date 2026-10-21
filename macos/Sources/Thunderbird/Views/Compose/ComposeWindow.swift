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
  @State private var controller: ComposerController
  @FocusState private var subjectFocused: Bool

  init(initial: ComposeDraft) {
    _controller = State(initialValue: ComposerController(draft: initial))
  }

  private var account: MailAccount? { store.identity(for: controller.draft)?.0 }
  private var isNews: Bool { account?.kind == .nntp }

  private var canSend: Bool {
    let draft = controller.draft
    return !controller.isBusy
      && (!MailAddress.parseList(draft.to + "," + draft.cc + "," + draft.bcc).isEmpty || !draft.newsgroups.isEmpty)
  }

  var body: some View {
    @Bindable var controller = controller
    HStack(spacing: 0) {
      if controller.showContactsSidebar {
        ComposeContactsSidebar(controller: controller)
          .frame(width: 240)
        Divider()
      }
      VStack(spacing: 0) {
        header
          .padding(12)
        if controller.dialog == .findReplace {
          FindReplaceBar(controller: controller)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        if controller.draft.isHTML {
          if controller.showFormatBar {
            FormatBar(controller: controller)
              .padding(.bottom, 6)
          }
          HTMLEditorView(controller: controller)
            .clipShape(.rect(cornerRadius: 14))
            .padding(.horizontal, 12)
        } else {
          TextEditor(text: $controller.draft.body)
            .font(.body.monospaced())
            .scrollContentBackground(.hidden)
            .contentMargins(.horizontal, 18, for: .scrollContent)
            .contentMargins(.vertical, 8, for: .scrollContent)
            .onChange(of: controller.draft.body) { controller.isDirty = true }
        }
        if controller.showAttachmentPane && !controller.draft.attachments.isEmpty {
          ComposeAttachmentPane(controller: controller)
            .padding(12)
        } else {
          Spacer().frame(height: 12)
        }
        if controller.showStatusBar {
          ComposeStatusBar(controller: controller, account: account)
        }
      }
    }
    .background(.background)
    .navigationTitle(controller.draft.subject.nilIfEmpty ?? "Write")
    .toolbar(id: "compose") { toolbar }
    .focusedSceneValue(\.composer, controller)
    .background(ComposeWindowMarker())
    .dropDestination(for: URL.self) { urls, _ in
      let files = urls.filter(\.isFileURL)
      controller.draft.attachments.append(contentsOf: files)
      return !files.isEmpty
    }
    .alert(
      "Couldn't Send Message",
      isPresented: Binding(get: { controller.errorMessage != nil }, set: { if !$0 { controller.errorMessage = nil } }),
      presenting: controller.errorMessage
    ) { _ in
      Button("OK") {}
    } message: { error in
      Text(error)
    }
    .confirmationDialog("Did you forget an attachment?", isPresented: $controller.confirmingNoAttachment) {
      Button("Attach Files…") { controller.attachFiles() }
      Button("Send Anyway") { Task { await controller.send(skipReminder: true) } }
    } message: {
      Text("Your message mentions an attachment, but nothing is attached.")
    }
    .sheet(item: Binding(get: { controller.dialog == .findReplace ? nil : controller.dialog }, set: { controller.dialog = $0 })) {
      dialog in ComposeDialogView(dialog: dialog, controller: controller)
    }
    .onAppear {
      controller.store = store
      controller.closeWindow = { dismissWindow() }
      controller.startAutosave()
      MenuBarSync.shared.securityAvailable = controller.anySecurityConfigured
      if controller.draft.accountID == nil {
        controller.draft.accountID = store.sendingAccounts.first?.id
        controller.draft.identityID = controller.draft.accountID
      }
    }
    .onDisappear {
      controller.stopAutosave()
      if controller.isDirty && !controller.sent {
        Task { await controller.saveDraft(silently: true) }
      }
    }
    .onChange(of: controller.draft.to) { controller.isDirty = true }
    .onChange(of: controller.draft.subject) { controller.isDirty = true }
    .disabled(controller.isBusy)
  }

  // MARK: - Toolbar (messengercompose.xhtml's composeToolbar2)

  @ToolbarContentBuilder
  private var toolbar: some CustomizableToolbarContent {
    ToolbarItem(id: "send", placement: .navigation) {
      Button {
        Task { await controller.send() }
      } label: {
        if controller.isBusy {
          ProgressView().controlSize(.small)
        } else {
          Label("Send", systemImage: "paperplane.fill")
        }
      }
      .buttonStyle(.glassProminent)
      .disabled(!canSend)
      .help("Send this message now (⌘↩)")
    }
    ToolbarItem(id: "encryption", placement: .primaryAction) {
      Toggle(isOn: Binding(get: { controller.draft.encrypt }, set: { controller.draft.encrypt = $0 })) {
        Label("Encrypt", systemImage: controller.draft.encrypt ? "lock.fill" : "lock.open")
      }
      .help(controller.securityAvailable ? "Encrypt this message" : "Set up end-to-end encryption in Account Settings")
      .disabled(!controller.securityAvailable || isNews)
    }
    ToolbarItem(id: "encryption-options", placement: .primaryAction) {
      Menu {
        SecurityMenuItems(controller: controller)
      } label: {
        Label("Security", systemImage: "checkmark.shield")
      }
      .help("End-to-end encryption options")
    }
    ToolbarItem(id: "contacts", placement: .primaryAction) {
      Toggle(isOn: Binding(get: { controller.showContactsSidebar }, set: { controller.showContactsSidebar = $0 })) {
        Label("Contacts", systemImage: "person.crop.rectangle.stack")
      }
      .help("Show the contacts sidebar")
    }
    ToolbarItem(id: "spelling", placement: .primaryAction) {
      Menu {
        Button("Check Spelling…") { controller.checkSpelling() }
        Toggle("Spellcheck As You Type", isOn: Binding(get: { controller.spellcheckAsYouType }, set: { _ in controller.toggleSpellcheckAsYouType() }))
      } label: {
        Label("Spelling", systemImage: "textformat.abc.dottedunderline")
      }
      .help("Check spelling")
    }
    ToolbarItem(id: "save", placement: .primaryAction) {
      Menu {
        Button("File…") { Task { await controller.saveAsFile() } }
        Divider()
        Button("Draft") { Task { await controller.saveDraft() } }
        Button("Template") { Task { await controller.saveTemplate() } }
      } label: {
        Label("Save", systemImage: "square.and.arrow.down")
      } primaryAction: {
        Task { await controller.saveDraft() }
      }
      .help("Save this message as a draft")
    }
    ToolbarItem(id: "attach", placement: .primaryAction) {
      Menu {
        AttachMenuItems(controller: controller)
      } label: {
        Label("Attach", systemImage: "paperclip")
      } primaryAction: {
        controller.attachFiles()
      }
      .help("Attach files")
    }
    ToolbarItem(id: "print", placement: .primaryAction) {
      Button { controller.print() } label: { Label("Print", systemImage: "printer") }
    }
    .defaultCustomization(.hidden)
    ToolbarItem(id: "return-receipt", placement: .primaryAction) {
      Toggle(isOn: Binding(get: { controller.draft.requestReturnReceipt }, set: { controller.draft.requestReturnReceipt = $0 })) {
        Label("Return Receipt", systemImage: "envelope.open.badge.clock")
      }
    }
    .defaultCustomization(.hidden)
    ToolbarItem(id: "priority", placement: .primaryAction) {
      Menu {
        PriorityMenuItems(controller: controller)
      } label: {
        Label("Priority", systemImage: "exclamationmark.circle")
      }
    }
    .defaultCustomization(.hidden)
  }

  // MARK: - Header

  private var identityTag: Binding<String> {
    Binding(
      get: {
        "\(controller.draft.accountID?.uuidString ?? "")|\(controller.draft.identityID?.uuidString ?? controller.draft.accountID?.uuidString ?? "")"
      },
      set: { value in
        let parts = value.split(separator: "|").map(String.init)
        controller.draft.accountID = parts.first.flatMap(UUID.init(uuidString:))
        controller.draft.identityID = parts.count > 1 ? UUID(uuidString: parts[1]) : controller.draft.accountID
      })
  }

  private var header: some View {
    @Bindable var controller = controller
    return Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
      GridRow {
        fieldLabel("From")
        HStack {
          if let customFrom = controller.draft.customFrom {
            TextField(
              "From", text: Binding(get: { customFrom }, set: { controller.draft.customFrom = $0 }),
              prompt: Text("Enter custom From address to be used instead of \(store.identity(for: controller.draft)?.1.address.formatted ?? "")"))
              .textFieldStyle(.roundedBorder)
              .frame(minWidth: 320)
          } else {
            Picker("From", selection: identityTag) {
              ForEach(store.sendingAccounts) { account in
                Section(account.label) {
                  ForEach(account.identities) { identity in
                    Text(identity.address.formatted).tag("\(account.id.uuidString)|\(identity.id.uuidString)")
                  }
                }
              }
            }
            .labelsHidden()
            .fixedSize()
          }
          Spacer()
          GlassEffectContainer(spacing: 4) {
            HStack(spacing: 4) {
              rowToggle("Cc", $controller.showCc)
              rowToggle("Bcc", $controller.showBcc)
              Menu {
                Toggle("Reply-To", isOn: $controller.showReplyTo)
                Toggle("Newsgroup", isOn: $controller.showNewsgroups)
                Toggle("Followup-To", isOn: $controller.showFollowupTo)
              } label: {
                Image(systemName: "ellipsis")
              }
              .menuIndicator(.hidden)
              .fixedSize()
              .help("Other address fields")
            }
            .buttonStyle(.glass)
            .controlSize(.small)
          }
        }
        .gridColumnAlignment(.leading)
      }
      separator
      addressRow("To", $controller.draft.to)
      if controller.showCc {
        separator
        addressRow("Cc", $controller.draft.cc)
      }
      if controller.showBcc {
        separator
        addressRow("Bcc", $controller.draft.bcc)
      }
      if controller.showReplyTo {
        separator
        addressRow("Reply-To", $controller.draft.replyTo)
      }
      if controller.showNewsgroups || isNews {
        separator
        GridRow {
          fieldLabel("Newsgroup")
          TextField("Newsgroups", text: $controller.draft.newsgroups, prompt: Text("comp.mail.misc"))
            .textFieldStyle(.plain)
        }
      }
      if controller.showFollowupTo {
        separator
        GridRow {
          fieldLabel("Followup-To")
          TextField("Followup-To", text: $controller.draft.followupTo)
            .textFieldStyle(.plain)
        }
      }
      separator
      GridRow {
        fieldLabel("Subject")
        TextField("Subject", text: $controller.draft.subject)
          .textFieldStyle(.plain)
          .font(.body.weight(.medium))
          .focused($subjectFocused)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .glassEffect(.regular, in: .rect(cornerRadius: 18))
    .overlay(alignment: .bottomTrailing) {
      if controller.draft.encrypt || controller.draft.sign || controller.draft.priority > 0 && controller.draft.priority < 3 {
        HStack(spacing: 6) {
          if controller.draft.priority > 0 && controller.draft.priority < 3 {
            Label("High Priority", systemImage: "exclamationmark")
          }
          if controller.draft.encrypt || controller.draft.sign {
            Label(
              [controller.draft.encrypt ? "Encrypted" : nil, controller.draft.sign ? "Signed" : nil].compactMap { $0 }.joined(separator: " · "),
              systemImage: controller.draft.encrypt ? "lock.fill" : "checkmark.seal.fill")
          }
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .glassEffect(.regular.tint(.green.opacity(0.4)), in: .capsule)
        .padding(10)
      }
    }
  }

  private var separator: some View {
    Divider().gridCellUnsizedAxes(.horizontal)
  }

  private func rowToggle(_ title: String, _ binding: Binding<Bool>) -> some View {
    Toggle(isOn: binding.animation(.smooth)) { Text(title) }
      .toggleStyle(.button)
      .help("Show the \(title) field")
  }

  private func fieldLabel(_ text: String) -> some View {
    Text(text)
      .foregroundStyle(.secondary)
      .gridColumnAlignment(.trailing)
  }

  private func addressRow(_ label: String, _ text: Binding<String>) -> some View {
    GridRow {
      fieldLabel(label)
      AddressTokenField(
        text: text, placeholder: "name@example.com",
        suggestions: { contacts.suggestions(for: $0) },
        expandList: { contacts.members(ofList: $0) },
        onMove: { token, row in moveAddress(token, to: row) })
    }
  }

  private func moveAddress(_ token: String, to row: String) {
    func append(_ value: inout String) {
      value = value.isEmpty ? token : value + ", " + token
    }
    switch row {
    case "Cc":
      controller.showCc = true
      append(&controller.draft.cc)
    case "Bcc":
      controller.showBcc = true
      append(&controller.draft.bcc)
    default:
      append(&controller.draft.to)
    }
  }
}

/// File › Attach and the toolbar's Attach menu.
struct AttachMenuItems: View {
  let controller: ComposerController

  var body: some View {
    Button("File(s)…") { controller.attachFiles() }
    Button("Web Page…") { controller.dialog = .attachWebPage }
    Divider()
    Button("My vCard") { controller.attachVCard() }
    Button("My OpenPGP Public Key") { controller.attachPublicKey() }
    Divider()
    Toggle("Remind Me Later", isOn: Binding(get: { controller.remindLater }, set: { controller.remindLater = $0 }))
  }
}

/// Options › Priority.
struct PriorityMenuItems: View {
  let controller: ComposerController

  var body: some View {
    Picker("Priority", selection: Binding(get: { controller.draft.priority }, set: { controller.draft.priority = $0 })) {
      Text("Highest").tag(1)
      Text("High").tag(2)
      Text("Normal").tag(0)
      Text("Low").tag(4)
      Text("Lowest").tag(5)
    }
    .pickerStyle(.inline)
  }
}

/// The Security menu (menu bar and toolbar).
struct SecurityMenuItems: View {
  let controller: ComposerController

  var body: some View {
    let technology = controller.draft.securityTechnology ?? controller.store?.identity(for: controller.draft)?.0.securityTechnology ?? .openPGP
    if controller.openPGPConfigured && controller.smimeConfigured {
      Picker("Technology", selection: Binding(get: { technology }, set: { controller.draft.securityTechnology = $0 })) {
        Text("OpenPGP").tag(SecurityTechnology.openPGP)
        Text("S/MIME").tag(SecurityTechnology.smime)
      }
      .pickerStyle(.inline)
      Divider()
    }
    Toggle("Encrypt", isOn: Binding(get: { controller.draft.encrypt }, set: { controller.draft.encrypt = $0 }))
      .disabled(!controller.securityAvailable)
    Toggle("Encrypt Subject", isOn: Binding(get: { controller.draft.encryptSubject }, set: { controller.draft.encryptSubject = $0 }))
      .disabled(!controller.draft.encrypt)
    Toggle("Digitally Sign", isOn: Binding(get: { controller.draft.sign }, set: { controller.draft.sign = $0 }))
      .disabled(!controller.securityAvailable)
    Divider()
    Button("Key Assistant") { controller.dialog = .keyAssistant }
    Button("Key Manager") {
      UserDefaults.standard.set("encryption", forKey: "settingsTab")
      NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
  }
}

private struct ComposeAttachmentPane: View {
  let controller: ComposerController

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Label("\(controller.draft.attachments.count) attachment\(controller.draft.attachments.count == 1 ? "" : "s")", systemImage: "paperclip")
          .font(.callout.weight(.medium))
        Spacer()
        Button("Reorder…") { controller.dialog = .reorderAttachments }
          .buttonStyle(.glass)
          .controlSize(.small)
      }
      ScrollView(.horizontal) {
        GlassEffectContainer(spacing: 8) {
          HStack(spacing: 8) {
            ForEach(controller.draft.attachments, id: \.self) { url in
              HStack(spacing: 6) {
                Image(systemName: AttachmentFiles.symbol(for: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? ""))
                Text(url.lastPathComponent).lineLimit(1)
                Button {
                  controller.draft.attachments.removeAll { $0 == url }
                } label: {
                  Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(url.lastPathComponent)")
              }
              .padding(.horizontal, 12)
              .padding(.vertical, 7)
              .glassEffect(.regular, in: .capsule)
              .contextMenu {
                Button("Open") { NSWorkspace.shared.open(url) }
                Button("Rename…") {
                  controller.attachmentToRename = url
                  controller.dialog = .renameAttachment
                }
                Divider()
                Button("Remove Attachment", role: .destructive) { controller.draft.attachments.removeAll { $0 == url } }
              }
            }
          }
          .padding(2)
        }
      }
      .scrollIndicators(.never)
    }
  }
}

private struct ComposeStatusBar: View {
  let controller: ComposerController
  let account: MailAccount?

  var body: some View {
    HStack(spacing: 12) {
      Text(controller.draft.isHTML ? "HTML" : "Plain Text")
      if let account { Text(account.label) }
      Spacer()
      if let saved = controller.lastSaved {
        Text("Draft saved \(saved.formatted(date: .omitted, time: .shortened))")
      }
      if controller.draft.requestReturnReceipt { Image(systemName: "envelope.open.badge.clock").accessibilityLabel("Return receipt requested") }
      if controller.draft.encrypt { Image(systemName: "lock.fill").accessibilityLabel("Encrypted") }
      if controller.draft.sign { Image(systemName: "checkmark.seal.fill").accessibilityLabel("Signed") }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .padding(.horizontal, 12)
    .padding(.vertical, 4)
    .background(.bar)
  }
}

/// View › Contacts Sidebar.
private struct ComposeContactsSidebar: View {
  @Environment(ContactsStore.self) private var contacts
  let controller: ComposerController
  @State private var query = ""
  @State private var selection: Set<String> = []

  private var matches: [ContactCard] {
    let list = contacts.contacts.filter { !$0.emails.isEmpty }
    guard !query.isEmpty else { return list }
    return list.filter { $0.displayName.localizedCaseInsensitiveContains(query) || $0.emails.contains { $0.value.localizedCaseInsensitiveContains(query) } }
  }

  var body: some View {
    VStack(spacing: 8) {
      TextField("Search contacts", text: $query)
        .textFieldStyle(.roundedBorder)
        .padding([.horizontal, .top], 10)
      List(matches, selection: $selection) { card in
        VStack(alignment: .leading) {
          Text(card.displayName)
          Text(card.emails.first?.value ?? "").font(.caption).foregroundStyle(.secondary)
        }
        .tag(card.id)
      }
      .contextMenu(forSelectionType: String.self) { _ in
        Button("Add to To") { add(to: \.to) }
        Button("Add to Cc") { add(to: \.cc) }
        Button("Add to Bcc") { add(to: \.bcc) }
      } primaryAction: { _ in add(to: \.to) }
      HStack {
        Button("To") { add(to: \.to) }
        Button("Cc") { add(to: \.cc) }
        Button("Bcc") { add(to: \.bcc) }
      }
      .buttonStyle(.glass)
      .controlSize(.small)
      .disabled(selection.isEmpty)
      .padding(.bottom, 10)
    }
    .task { if !contacts.isAuthorized { await contacts.requestAccess() } }
  }

  private func add(to field: WritableKeyPath<ComposeDraft, String>) {
    let addresses = contacts.contacts.filter { selection.contains($0.id) }.compactMap { card in
      card.emails.first.map { MailAddress(name: card.displayName, email: $0.value).formatted }
    }
    guard !addresses.isEmpty else { return }
    let existing = controller.draft[keyPath: field]
    controller.draft[keyPath: field] = ([existing].filter { !$0.isEmpty } + addresses).joined(separator: ", ")
    if field == \.cc { controller.showCc = true }
    if field == \.bcc { controller.showBcc = true }
  }
}

private struct FindReplaceBar: View {
  let controller: ComposerController

  var body: some View {
    @Bindable var controller = controller
    HStack(spacing: 8) {
      TextField("Find", text: $controller.findText)
        .textFieldStyle(.roundedBorder)
        .onSubmit { controller.find() }
      TextField("Replace with", text: $controller.replaceText)
        .textFieldStyle(.roundedBorder)
      Toggle("Match case", isOn: $controller.findCaseSensitive)
        .toggleStyle(.checkbox)
      GlassEffectContainer(spacing: 4) {
        HStack(spacing: 4) {
          Button("Previous") { controller.find(backwards: true) }
          Button("Next") { controller.find() }
          Button("Replace") { controller.replace() }
          Button("Replace All") { controller.replaceAll() }
          Button {
            controller.dialog = nil
          } label: {
            Image(systemName: "xmark")
          }
          .accessibilityLabel("Close find bar")
        }
        .buttonStyle(.glass)
        .controlSize(.small)
      }
    }
  }
}
