/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import SwiftUI
import ThunderbirdCore

struct SettingsView: View {
  var body: some View {
    TabView {
      Tab("General", systemImage: "gearshape") {
        GeneralSettings()
      }
      Tab("Accounts", systemImage: "at") {
        AccountsSettings()
      }
    }
    .frame(width: 720, height: 520)
  }
}

private struct GeneralSettings: View {
  @AppStorage(Preferences.checkInterval) private var checkInterval = 10
  @AppStorage(Preferences.syncLimit) private var syncLimit = 250
  @AppStorage(Preferences.markReadOnOpen) private var markReadOnOpen = true
  @AppStorage(Preferences.allowRemoteContent) private var allowRemoteContent = false

  var body: some View {
    Form {
      Section("Checking for Mail") {
        Picker("Check for new messages every", selection: $checkInterval) {
          ForEach([1, 5, 10, 15, 30, 60], id: \.self) { minutes in
            Text(minutes == 1 ? "minute" : "\(minutes) minutes")
              .tag(minutes)
          }
        }
        Picker("Keep this many recent messages per folder", selection: $syncLimit) {
          ForEach([100, 250, 500, 1000, 2500], id: \.self) { count in
            Text(count.formatted())
              .tag(count)
          }
        }
      }
      Section("Reading") {
        Toggle("Mark messages as read when displayed", isOn: $markReadOnOpen)
      }
      Section {
        Toggle("Allow remote content in messages", isOn: $allowRemoteContent)
      } header: {
        Text("Privacy")
      } footer: {
        Text("Remote images and styles can tell senders when and where you read their messages.")
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
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
        List(store.accounts, selection: $selection) { account in
          Label {
            VStack(alignment: .leading) {
              Text(account.label)
              Text(account.email)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          } icon: {
            AvatarView(address: account.address, size: 24)
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
          .disabled(selection == nil)
          Spacer()
        }
        .buttonStyle(.glass)
        .controlSize(.small)
        .padding(8)
      }
      .frame(width: 220)

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
      selection = selection ?? store.accounts.first?.id
    }
    .sheet(isPresented: $showingSetup) {
      AccountSetupView()
    }
    .confirmationDialog(
      "Remove \(store.account(selection)?.label ?? "this account")?",
      isPresented: $confirmingRemoval
    ) {
      Button("Remove Account", role: .destructive) {
        if let selection {
          store.removeAccount(selection)
        }
        selection = store.accounts.first?.id
      }
    } message: {
      Text("Downloaded messages and the saved password will be removed from this Mac. Mail on the server is not affected.")
    }
  }
}

private struct AccountEditor: View {
  @Environment(MailStore.self) private var store
  @State private var account: MailAccount
  @State private var incomingPassword = ""
  @State private var outgoingPassword = ""
  @State private var status: String?

  init(account: MailAccount) {
    _account = State(initialValue: account)
  }

  private var isDirty: Bool {
    account != store.account(account.id) || !incomingPassword.isEmpty || !outgoingPassword.isEmpty
  }

  var body: some View {
    Form {
      Section("Identity") {
        TextField("Account name", text: $account.label)
        TextField("Your name", text: $account.fullName)
        TextField("Email address", text: $account.email)
        TextField("Signature", text: $account.signature, axis: .vertical)
          .lineLimit(3...6)
      }
      Section("Incoming Server (IMAP)") {
        ServerConfigEditor(config: $account.incoming, defaultPorts: ServerConfigEditor.imapPorts)
        SecureField("Password", text: $incomingPassword, prompt: Text("Unchanged"))
      }
      Section("Outgoing Server (SMTP)") {
        ServerConfigEditor(config: $account.outgoing, defaultPorts: ServerConfigEditor.smtpPorts)
        SecureField("Password", text: $outgoingPassword, prompt: Text("Unchanged"))
      }
      Section {
        HStack {
          if let status {
            Text(status)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Button("Revert") {
            if let saved = store.account(account.id) {
              account = saved
            }
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
  }

  private func save() {
    do {
      try store.updateAccount(
        account,
        incomingPassword: incomingPassword.isEmpty ? nil : incomingPassword,
        outgoingPassword: outgoingPassword.isEmpty ? nil : outgoingPassword
      )
      incomingPassword = ""
      outgoingPassword = ""
      status = "Saved."
    } catch {
      status = error.localizedDescription
    }
  }
}
