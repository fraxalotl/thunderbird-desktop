/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import AppKit
import SwiftUI
import ThunderbirdCore
import UniformTypeIdentifiers

struct SettingsView: View {
  @AppStorage("settingsTab") private var tab = "general"

  var body: some View {
    TabView(selection: $tab) {
      Tab("General", systemImage: "gearshape", value: "general") {
        GeneralSettings()
      }
      Tab("Composition", systemImage: "square.and.pencil", value: "composition") {
        CompositionSettings()
      }
      Tab("Privacy & Security", systemImage: "lock.shield", value: "privacy") {
        PrivacySettings()
      }
      Tab("Chat", systemImage: "bubble.left.and.bubble.right", value: "chat") {
        ChatSettings()
      }
      Tab("Calendar", systemImage: "calendar", value: "calendar") {
        CalendarSettings()
      }
      Tab("Accounts", systemImage: "at", value: "accounts") {
        AccountsSettings()
      }
      Tab("Filters", systemImage: "line.3.horizontal.decrease.circle", value: "filters") {
        FilterSettings()
      }
      Tab("Encryption", systemImage: "key", value: "encryption") {
        OpenPGPSettings()
      }
      Tab("OAuth", systemImage: "person.badge.key", value: "oauth") {
        OAuthSettings()
      }
    }
    .frame(width: 860, height: 640)
  }
}

private struct AccountsSettings: View {
  @Environment(MailStore.self) private var store
  @State private var selection: UUID?
  @State private var showingSetup = false
  @State private var confirmingRemoval = false

  var body: some View {
    HStack(spacing: 0) {
      VStack(spacing: 0) {
        List(store.mailAccounts, selection: $selection) { account in
          Label {
            VStack(alignment: .leading) {
              Text(account.label)
              Text(account.kind == .local ? "On this Mac" : "\(account.kind.label) · \(account.email)")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          } icon: {
            if account.kind == .local {
              Image(systemName: "internaldrive")
            } else {
              AvatarView(address: account.address, size: 24)
            }
          }
          .tag(account.id)
        }
        .listStyle(.sidebar)
        HStack(spacing: 4) {
          Button {
            showingSetup = true
          } label: {
            Image(systemName: "plus")
          }
          .accessibilityLabel("Add Account")
          Button {
            confirmingRemoval = true
          } label: {
            Image(systemName: "minus")
          }
          .accessibilityLabel("Remove Account")
          .disabled(store.account(selection)?.kind == .local || selection == nil)
          Spacer()
          Button {
            if let selection { store.moveAccount(selection, by: -1) }
          } label: {
            Image(systemName: "chevron.up")
          }
          .accessibilityLabel("Move Up")
          Button {
            if let selection { store.moveAccount(selection, by: 1) }
          } label: {
            Image(systemName: "chevron.down")
          }
          .accessibilityLabel("Move Down")
        }
        .buttonStyle(.glass)
        .controlSize(.small)
        .padding(8)
      }
      .frame(width: 230)

      Divider()

      if let account = store.account(selection) {
        AccountEditor(account: account)
          .id(account.id)
      } else {
        ContentUnavailableView("No Account Selected", systemImage: "at")
          .frame(maxWidth: .infinity)
      }
    }
    .onAppear {
      selection = selection ?? store.mailAccounts.first?.id
    }
    .sheet(isPresented: $showingSetup) {
      AccountSetupView()
    }
    .confirmationDialog(
      "Remove \(store.account(selection)?.label ?? "this account")?",
      isPresented: $confirmingRemoval
    ) {
      Button("Remove Account", role: .destructive) {
        if let selection { store.removeAccount(selection) }
        selection = store.mailAccounts.first?.id
      }
    } message: {
      Text("Downloaded messages and saved passwords will be removed from this Mac. Mail on the server is not affected.")
    }
  }
}

private struct AccountEditor: View {
  @Environment(MailStore.self) private var store
  @State private var account: MailAccount
  @State private var incomingPassword = ""
  @State private var outgoingPassword = ""
  @State private var status: String?
  @State private var generatingKey = false

  init(account: MailAccount) {
    _account = State(initialValue: account)
  }

  private var isDirty: Bool {
    account != store.account(account.id) || !incomingPassword.isEmpty || !outgoingPassword.isEmpty
  }

  var body: some View {
    Form {
      Section("Account") {
        TextField("Account name", text: $account.label)
      }
      if account.kind == .feed {
        Section("Feeds") {
          Text("Manage subscriptions from the account's Subscribe… menu in the folder pane.")
            .foregroundStyle(.secondary)
        }
      }
      if account.kind != .local && account.kind != .feed {
        Section("Default Identity") {
          TextField("Your name", text: $account.fullName)
          TextField("Email address", text: $account.email)
          TextField("Reply-to address", text: $account.replyTo)
          TextField("Signature", text: $account.signature, axis: .vertical)
            .lineLimit(3...6)
          if account.kind != .nntp {
            Toggle("Compose messages in HTML", isOn: $account.composeHTML)
          }
        }
        Section {
          ForEach($account.extraIdentities) { $identity in
            DisclosureGroup(identity.email.isEmpty ? "New Identity" : identity.address.formatted) {
              TextField("Name", text: $identity.fullName)
              TextField("Email", text: $identity.email)
              TextField("Reply-to", text: $identity.replyTo)
              TextField("Signature", text: $identity.signature, axis: .vertical)
              Button("Remove Identity", role: .destructive) {
                account.extraIdentities.removeAll { $0.id == identity.id }
              }
            }
          }
          Button("Add Identity") {
            account.extraIdentities.append(Identity(fullName: account.fullName, email: ""))
          }
        } header: {
          Text("Additional Identities")
        } footer: {
          Text("Other addresses you send from with this account.").foregroundStyle(.secondary)
        }
        Section("Incoming Server (\(account.kind.label))") {
          ServerConfigEditor(config: $account.incoming, defaultPorts: ServerConfigEditor.ports(for: account.kind))
          credentialRow(server: account.incoming, key: account.incomingKeychainKey, password: $incomingPassword)
          if account.kind == .pop3 {
            Toggle("Leave messages on the server", isOn: $account.leaveMessagesOnServer)
          }
        }
        if account.kind == .ews {
          securitySection
        }
        if account.kind == .imap || account.kind == .pop3 {
          Section("Outgoing Server (SMTP)") {
            ServerConfigEditor(config: $account.outgoing, defaultPorts: ServerConfigEditor.smtpPorts)
            credentialRow(server: account.outgoing, key: account.outgoingKeychainKey, password: $outgoingPassword)
          }
          securitySection
        }
      }
      AccountOptionsEditor(account: $account)
      Section {
        HStack {
          if let status {
            Text(status).foregroundStyle(.secondary)
          }
          Spacer()
          Button("Revert") {
            if let saved = store.account(account.id) { account = saved }
            incomingPassword = ""
            outgoingPassword = ""
          }
          .disabled(!isDirty)
          Button("Save") { save() }
            .buttonStyle(.glassProminent)
            .disabled(!isDirty)
        }
      }
    }
    .formStyle(.grouped)
    .sheet(isPresented: $generatingKey) {
      GenerateKeySheet(name: account.fullName, email: account.email) { key in
        account.openPGPKeyID = key.fingerprint
      }
    }
  }

  @ViewBuilder
  private func credentialRow(server: ServerConfig, key: String, password: Binding<String>) -> some View {
    if server.auth == .oauth2 {
      HStack {
        Text(Keychain.password(for: Credentials.oauthKey(for: key)) == nil ? "Not signed in" : "Signed in")
          .foregroundStyle(.secondary)
        Spacer()
        Button("Sign In Again") {
          Task {
            do {
              _ = try await Credentials.resolve(server, key: key, interactive: true)
              status = "Signed in."
            } catch {
              status = error.localizedDescription
            }
          }
        }
      }
    } else {
      SecureField("Password", text: password, prompt: Text(Keychain.password(for: key) == nil ? "Required" : "Unchanged"))
    }
  }

  private var securitySection: some View {
    Section {
      Picker("Technology", selection: $account.securityTechnology) {
        ForEach(SecurityTechnology.allCases, id: \.self) { Text($0.label).tag($0) }
      }
      switch account.securityTechnology {
      case .openPGP:
        if OpenPGP.shared.isAvailable {
          let keys = OpenPGP.shared.keys(for: account.email).filter(\.hasSecret)
          Picker("Personal key", selection: $account.openPGPKeyID) {
            Text("None").tag(String?.none)
            ForEach(keys) { key in
              Text("\(key.keyID) · \(key.userID)").tag(Optional(key.fingerprint))
            }
          }
          Button("Generate a New Key…") { generatingKey = true }
        } else {
          Label("OpenPGP needs librnp.dylib, which ships with Thunderbird. Build with build-app.sh to bundle it.", systemImage: "exclamationmark.triangle")
            .foregroundStyle(.orange)
        }
      case .smime:
        Label(
          SMIME.hasIdentity(for: account.email)
            ? "A personal certificate for \(account.email) is in your keychain."
            : "No personal certificate for \(account.email) was found. Import one into Keychain Access.",
          systemImage: SMIME.hasIdentity(for: account.email) ? "checkmark.seal.fill" : "exclamationmark.triangle")
      }
      Toggle("Encrypt new messages by default", isOn: $account.encryptByDefault)
      Toggle("Sign new messages by default", isOn: $account.signByDefault)
    } header: {
      Text("End-to-End Encryption")
    }
  }

  private func save() {
    do {
      try store.updateAccount(
        account,
        incomingPassword: incomingPassword.isEmpty ? nil : incomingPassword,
        outgoingPassword: outgoingPassword.isEmpty ? nil : outgoingPassword)
      incomingPassword = ""
      outgoingPassword = ""
      status = "Saved."
    } catch {
      status = error.localizedDescription
    }
  }
}

private struct FilterSettings: View {
  @Environment(MailStore.self) private var store
  @State private var accountID: UUID?
  @State private var filters: [MessageFilter] = []
  @State private var selection: UUID?

  var body: some View {
    let filterable = store.mailAccounts.filter { $0.kind == .imap || $0.kind == .pop3 || $0.kind == .local }
    HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 8) {
        Picker("Filters for", selection: $accountID) {
          ForEach(filterable) { Text($0.label).tag(Optional($0.id)) }
        }
        .labelsHidden()
        List(selection: $selection) {
          ForEach($filters) { $filter in
            Toggle(isOn: $filter.enabled) {
              Text(filter.name)
            }
            .tag(filter.id)
          }
          .onMove { filters.move(fromOffsets: $0, toOffset: $1) }
        }
        HStack(spacing: 4) {
          Button {
            let filter = MessageFilter(
              name: "New Filter", conditions: [FilterCondition(field: .subject, op: .contains, value: "")],
              actions: [FilterAction(kind: .markRead)])
            filters.append(filter)
            selection = filter.id
          } label: {
            Image(systemName: "plus")
          }
          .accessibilityLabel("Add Filter")
          Button {
            filters.removeAll { $0.id == selection }
            selection = nil
          } label: {
            Image(systemName: "minus")
          }
          .accessibilityLabel("Remove Filter")
          .disabled(selection == nil)
        }
        .buttonStyle(.glass)
        .controlSize(.small)
      }
      .padding(12)
      .frame(width: 240)

      Divider()

      if let index = filters.firstIndex(where: { $0.id == selection }), let accountID {
        FilterEditor(filter: $filters[index], folders: store.sidebarFolders(for: accountID).map(\.folder))
      } else {
        ContentUnavailableView(
          "No Filter Selected", systemImage: "line.3.horizontal.decrease.circle",
          description: Text("Filters run on new mail in the inbox, in order. Use Message › Run Filters on Folder to apply them to existing mail."))
          .frame(maxWidth: .infinity)
      }
    }
    .onAppear {
      accountID = accountID ?? filterable.first?.id
      if let accountID { filters = FilterStore.filters(for: accountID) }
    }
    .onChange(of: accountID) { _, new in
      if let new { filters = FilterStore.filters(for: new) }
      selection = nil
    }
    .onChange(of: filters) { _, new in
      if let accountID { FilterStore.save(new, for: accountID) }
    }
  }
}

struct FilterEditor: View {
  @Binding var filter: MessageFilter
  let folders: [RemoteFolder]

  var body: some View {
    Form {
      TextField("Filter name", text: $filter.name)
      Section {
        Picker("Match", selection: $filter.matchAll) {
          Text("all of the following").tag(true)
          Text("any of the following").tag(false)
        }
        ForEach($filter.conditions) { $condition in
          HStack {
            Picker("Field", selection: $condition.field) {
              ForEach(FilterCondition.Field.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            if condition.field.isBoolean {
              Picker("Value", selection: $condition.value) {
                Text("is true").tag("true")
                Text("is false").tag("false")
              }
              .labelsHidden()
            } else {
              Picker("Operator", selection: $condition.op) {
                ForEach(condition.field == .size ? [FilterCondition.Operator.greaterThan, .lessThan] : FilterCondition.Operator.allCases.filter { $0 != .greaterThan && $0 != .lessThan }, id: \.self) {
                  Text($0.label).tag($0)
                }
              }
              .labelsHidden()
              TextField("Value", text: $condition.value)
            }
            Button {
              filter.conditions.removeAll { $0.id == condition.id }
            } label: {
              Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove condition")
          }
        }
        Button("Add Condition") { filter.conditions.append(FilterCondition(field: .from, op: .contains, value: "")) }
      } header: {
        Text("Conditions")
      }
      Section("Actions") {
        ForEach($filter.actions) { $action in
          HStack {
            Picker("Action", selection: $action.kind) {
              ForEach(FilterAction.Kind.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            if action.kind.needsFolder {
              Picker("Folder", selection: $action.folderPath) {
                Text("Choose…").tag(String?.none)
                ForEach(folders.filter(\.isSelectable)) { Text($0.displayName).tag(Optional($0.path)) }
              }
              .labelsHidden()
            }
            if action.kind == .addTag {
              Picker("Tag", selection: $action.tag) {
                Text("Choose…").tag(String?.none)
                ForEach(MessageTag.defaults) { Text($0.name).tag(Optional($0.keyword)) }
              }
              .labelsHidden()
            }
            Button {
              filter.actions.removeAll { $0.id == action.id }
            } label: {
              Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove action")
          }
        }
        Button("Add Action") { filter.actions.append(FilterAction(kind: .moveTo)) }
      }
    }
    .formStyle(.grouped)
  }
}

private struct OpenPGPSettings: View {
  @State private var keys: [OpenPGPKey] = []
  @State private var selection: String?
  @State private var importing = false
  @State private var generating = false
  @State private var message: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if !OpenPGP.shared.isAvailable {
        Label(
          "OpenPGP uses librnp.dylib from Thunderbird. Build the app with build-app.sh to bundle it, or install Thunderbird in /Applications.",
          systemImage: "exclamationmark.triangle"
        )
        .foregroundStyle(.orange)
      }
      Table(keys, selection: $selection) {
        TableColumn("Name") { key in
          HStack {
            Image(systemName: key.hasSecret ? "key.fill" : "key")
              .foregroundStyle(key.hasSecret ? .yellow : .secondary)
              .accessibilityLabel(key.hasSecret ? "Personal key" : "Public key")
            Text(key.userID)
          }
        }
        TableColumn("Key ID") { Text($0.keyID).monospaced() }
          .width(150)
        TableColumn("Expires") { key in
          Text(key.isUsable ? (key.expires?.formatted(date: .abbreviated, time: .omitted) ?? "Never") : "Expired or revoked")
            .foregroundStyle(key.isUsable ? .primary : Color.red)
        }
        .width(130)
      }
      HStack {
        Button("Generate…") { generating = true }
        Button("Import…") { importing = true }
        Button("Export Public Key…") { export() }
          .disabled(selection == nil)
        Button("Delete", role: .destructive) {
          if let selection { try? OpenPGP.shared.deleteKey(selection) }
          reload()
        }
        .disabled(selection == nil)
        Spacer()
        if let message {
          Text(message).foregroundStyle(.secondary)
        }
      }
      .buttonStyle(.glass)
      .disabled(!OpenPGP.shared.isAvailable)
    }
    .padding(16)
    .onAppear(perform: reload)
    .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .text]) { result in
      if case .success(let url) = result, let data = try? Data(contentsOf: url) {
        do {
          let count = try OpenPGP.shared.importKeys(data)
          message = "Imported \(count) key\(count == 1 ? "" : "s")."
        } catch {
          message = error.localizedDescription
        }
        reload()
      }
    }
    .sheet(isPresented: $generating, onDismiss: reload) {
      GenerateKeySheet(name: NSFullUserName(), email: "") { _ in }
    }
  }

  private func reload() {
    keys = OpenPGP.shared.keys()
  }

  private func export() {
    guard let selection, let armored = try? OpenPGP.shared.exportPublicKey(selection) else { return }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "\(keys.first { $0.fingerprint == selection }?.keyID ?? "key")-public.asc"
    if panel.runModal() == .OK, let url = panel.url {
      try? armored.write(to: url, atomically: true, encoding: .utf8)
    }
  }
}

private struct GenerateKeySheet: View {
  @Environment(\.dismiss) private var dismiss
  @State var name: String
  @State var email: String
  let onCreated: (OpenPGPKey) -> Void
  @State private var passphrase = ""
  @State private var error: String?

  var body: some View {
    VStack(spacing: 0) {
      Form {
        Text("Generate an OpenPGP key (Ed25519 / Curve25519)")
          .font(.headline)
        TextField("Name", text: $name)
        TextField("Email", text: $email)
        SecureField("Passphrase (recommended)", text: $passphrase)
        if let error {
          Text(error).foregroundStyle(.red)
        }
      }
      .formStyle(.grouped)
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
        Button("Generate") {
          do {
            onCreated(try OpenPGP.shared.generateKey(name: name, email: email, passphrase: passphrase))
            dismiss()
          } catch {
            self.error = error.localizedDescription
          }
        }
        .buttonStyle(.glassProminent)
        .disabled(email.isEmpty || name.isEmpty)
      }
      .padding(16)
    }
    .frame(width: 420)
  }
}

private struct OAuthSettings: View {
  @State private var clients = OAuth2ClientRegistry.all()

  var body: some View {
    Form {
      Section {
        ForEach(OAuth2Provider.all) { provider in
          VStack(alignment: .leading, spacing: 6) {
            Text(provider.name)
              .font(.headline)
            TextField(
              "Client ID",
              text: Binding(
                get: { clients[provider.issuer]?.clientID ?? "" },
                set: { value in
                  var client = clients[provider.issuer] ?? OAuth2Client(clientID: "")
                  client.clientID = value
                  clients[provider.issuer] = client
                  OAuth2ClientRegistry.set(value.isEmpty ? nil : client, for: provider.issuer)
                }))
            SecureField(
              "Client secret (if the provider issued one)",
              text: Binding(
                get: { clients[provider.issuer]?.clientSecret ?? "" },
                set: { value in
                  var client = clients[provider.issuer] ?? OAuth2Client(clientID: "")
                  client.clientSecret = value
                  clients[provider.issuer] = client
                  OAuth2ClientRegistry.set(client.clientID.isEmpty ? nil : client, for: provider.issuer)
                }))
            Text("Redirect URI: http://\(provider.redirectHost) (any port) · Scopes: \(provider.scope)")
              .font(.caption)
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
          }
          .padding(.vertical, 4)
        }
      } header: {
        Text("OAuth Applications")
      } footer: {
        Text("Register a desktop (native) application with each provider you want to sign in to, then paste its client ID here. Thunderbird's own registrations belong to Mozilla and aren't reused by this app.")
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }
}
