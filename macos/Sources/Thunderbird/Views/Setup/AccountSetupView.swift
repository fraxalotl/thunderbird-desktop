/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import SwiftUI
import ThunderbirdCore

struct AccountSetupView: View {
  enum Mode: String, CaseIterable, Identifiable {
    case email = "Email"
    case news = "Newsgroups"
    case importProfile = "Import"
    var id: String { rawValue }
  }

  @Environment(\.dismiss) private var dismiss
  @State private var mode = Mode.email

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 14) {
        Image(nsImage: NSApp.applicationIconImage)
          .resizable()
          .frame(width: 52, height: 52)
        VStack(alignment: .leading, spacing: 2) {
          Text(mode == .email ? "Set Up Your Existing Email Address" : mode == .news ? "Add a Newsgroup Account" : "Import from Thunderbird")
            .font(.title2.weight(.semibold))
          Text(
            mode == .email
              ? "Thunderbird will look up your provider's settings for you."
              : mode == .news ? "Read and post to Usenet newsgroups." : "Bring over the accounts from an existing Thunderbird profile."
          )
          .foregroundStyle(.secondary)
        }
        Spacer()
      }
      .padding([.horizontal, .top], 24)
      Picker("Account type", selection: $mode) {
        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .padding(.horizontal, 24)
      .padding(.vertical, 12)

      switch mode {
      case .email: EmailSetup(onDone: { dismiss() })
      case .news: NewsSetup(onDone: { dismiss() })
      case .importProfile: ProfileImportView(onDone: { dismiss() })
      }
    }
    .frame(width: 580)
    .frame(minHeight: 440)
  }
}

private struct EmailSetup: View {
  @Environment(MailStore.self) private var store
  let onDone: () -> Void

  private enum Step {
    case details, lookingUp, review, testing
  }

  @State private var step = Step.details
  @State private var fullName = NSFullUserName()
  @State private var email = ""
  @State private var password = ""
  @State private var kind = AccountKind.imap
  @State private var discovered: DiscoveredConfig?
  @State private var incoming = ServerConfig(host: "", port: 993, security: .tls, username: "")
  @State private var outgoing = ServerConfig(host: "", port: 465, security: .tls, username: "")
  @State private var editingManually = false
  @State private var errorMessage: String?

  private var emailLooksValid: Bool {
    let parts = email.split(separator: "@")
    return parts.count == 2 && parts[1].contains(".") && !parts[0].isEmpty
  }

  private var usesOAuth: Bool { incoming.auth == .oauth2 }

  var body: some View {
    VStack(spacing: 0) {
      Form {
        Section {
          TextField("Your full name", text: $fullName)
          TextField("Email address", text: $email, prompt: Text("you@example.com"))
            .textContentType(.emailAddress)
            .autocorrectionDisabled()
            .disabled(step != .details)
          if !usesOAuth {
            SecureField(discovered?.source == .protonBridge ? "Bridge password" : "Password", text: $password)
          }
        }

        if step == .review || step == .testing, discovered != nil {
          reviewSections
        }

        if let errorMessage {
          Section {
            Label(errorMessage, systemImage: "exclamationmark.octagon.fill")
              .foregroundStyle(.red)
          }
        }
      }
      .formStyle(.grouped)
      .scrollContentBackground(.hidden)

      HStack {
        if step == .lookingUp || step == .testing {
          ProgressView()
            .controlSize(.small)
          Text(step == .lookingUp ? "Looking up configuration…" : usesOAuth ? "Waiting for you to sign in in your browser…" : "Checking your password…")
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Cancel", role: .cancel, action: onDone)
          .keyboardShortcut(.cancelAction)
        if step == .details || step == .lookingUp {
          Button("Continue") { Task { await lookUp() } }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!emailLooksValid || fullName.isEmpty || step == .lookingUp)
        } else {
          Button("Back") {
            step = .details
            errorMessage = nil
          }
          .disabled(step == .testing)
          Button(usesOAuth ? "Sign In" : "Done") { Task { await finish() } }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(step == .testing || incoming.host.isEmpty || outgoing.host.isEmpty || (!usesOAuth && password.isEmpty))
        }
      }
      .padding(20)
    }
    .animation(.smooth, value: step)
  }

  @ViewBuilder
  private var reviewSections: some View {
    if let discovered {
      Section {
        Label(
          discovered.source == .guess
            ? "No configuration was found, so Thunderbird guessed common settings. Check them before continuing."
            : "Configuration found using \(discovered.source.rawValue)\(discovered.providerName.map { " (\($0))" } ?? "").",
          systemImage: discovered.source == .guess ? "questionmark.circle" : "checkmark.seal.fill"
        )
        .foregroundStyle(discovered.source == .guess ? Color.orange : Color.green)
        if let note = discovered.note {
          Label(note, systemImage: "info.circle")
        }
        if discovered.requiresOAuth, let provider = OAuth2Provider.forHost(incoming.host),
          OAuth2ClientRegistry.client(for: provider.issuer) == nil
        {
          Label(
            "\(provider.name) uses OAuth2 sign-in. Add your OAuth client ID in Settings › OAuth, or use an app password here.",
            systemImage: "key.fill"
          )
          .foregroundStyle(.orange)
        }
        Picker("Incoming protocol", selection: $kind) {
          Text("IMAP (keep folders in sync)").tag(AccountKind.imap)
          Text("POP3 (download to this Mac)").tag(AccountKind.pop3)
        }
        .onChange(of: kind) { _, new in
          if new == .pop3 {
            incoming.host = incoming.host.replacingOccurrences(of: "imap.", with: "pop.")
            incoming.port = incoming.security == .tls ? 995 : 110
          } else {
            incoming.host = incoming.host.replacingOccurrences(of: "pop.", with: "imap.")
            incoming.port = incoming.security == .tls ? 993 : 143
          }
        }
        if !editingManually {
          serverSummary("Incoming", kind.label, incoming)
          serverSummary("Outgoing", "SMTP", outgoing)
        }
        Toggle("Configure manually", isOn: $editingManually.animation(.smooth))
      }
      if editingManually {
        Section("Incoming Server (\(kind.label))") {
          ServerConfigEditor(config: $incoming, defaultPorts: ServerConfigEditor.ports(for: kind))
        }
        Section("Outgoing Server (SMTP)") {
          ServerConfigEditor(config: $outgoing, defaultPorts: ServerConfigEditor.smtpPorts)
        }
      }
    }
  }

  private func serverSummary(_ title: String, _ protocolName: String, _ config: ServerConfig) -> some View {
    LabeledContent {
      VStack(alignment: .trailing, spacing: 2) {
        Text("\(config.host):\(config.port.formatted(.number.grouping(.never)))")
          .monospaced()
        Text("\(protocolName) · \(config.security.label) · \(config.auth.label) · \(config.username)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    } label: {
      Text(title)
    }
  }

  private func lookUp() async {
    errorMessage = nil
    step = .lookingUp
    let config = await Autoconfig.discover(email: email.trimmingCharacters(in: .whitespaces))
    discovered = config
    incoming = config.incoming
    outgoing = config.outgoing
    if config.requiresOAuth, let provider = OAuth2Provider.forHost(config.incoming.host),
      OAuth2ClientRegistry.client(for: provider.issuer) != nil
    {
      incoming.auth = .oauth2
      outgoing.auth = .oauth2
    }
    editingManually = config.source == .guess
    step = .review
  }

  private func finish() async {
    errorMessage = nil
    step = .testing
    let account = MailAccount(
      kind: kind, fullName: fullName, email: email.trimmingCharacters(in: .whitespaces),
      incoming: incoming, outgoing: outgoing)
    do {
      let incomingCredential: Credential
      let outgoingCredential: Credential
      if usesOAuth {
        incomingCredential = try await Credentials.resolve(incoming, key: account.incomingKeychainKey, interactive: true)
        outgoingCredential =
          outgoing.auth == .oauth2
          ? try await Credentials.resolve(outgoing, key: account.outgoingKeychainKey, interactive: true) : .password(password)
      } else {
        incomingCredential = .password(password)
        outgoingCredential = .password(password)
      }
      if kind == .pop3 {
        try await POP3Client(server: incoming, credential: incomingCredential).verify()
      } else {
        try await IMAPBackend.testConnection(server: incoming, credential: incomingCredential)
      }
      try await SMTPClient(server: outgoing, credential: outgoingCredential).verify()
      try store.addAccount(account, incomingPassword: usesOAuth ? nil : password, outgoingPassword: usesOAuth ? nil : password)
      onDone()
    } catch {
      errorMessage = error.localizedDescription
      editingManually = true
      step = .review
    }
  }
}

private struct NewsSetup: View {
  @Environment(MailStore.self) private var store
  let onDone: () -> Void
  @State private var fullName = NSFullUserName()
  @State private var email = ""
  @State private var server = ServerConfig(host: "", port: 563, security: .tls, username: "")
  @State private var password = ""
  @State private var error: String?

  var body: some View {
    VStack(spacing: 0) {
      Form {
        Section("Identity") {
          TextField("Your full name", text: $fullName)
          TextField("Email address (shown in your posts)", text: $email)
        }
        Section("News Server") {
          ServerConfigEditor(config: $server, defaultPorts: ServerConfigEditor.nntpPorts, showsAuthentication: false)
          SecureField("Password (if required)", text: $password)
        }
        if let error {
          Text(error).foregroundStyle(.red)
        }
      }
      .formStyle(.grouped)
      .scrollContentBackground(.hidden)
      HStack {
        Spacer()
        Button("Cancel", role: .cancel, action: onDone)
          .keyboardShortcut(.cancelAction)
        Button("Add Account") {
          let account = MailAccount(
            kind: .nntp, fullName: fullName, email: email, label: server.host, incoming: server, outgoing: .none)
          do {
            try store.addAccount(account, incomingPassword: password, outgoingPassword: nil)
            onDone()
          } catch {
            self.error = error.localizedDescription
          }
        }
        .buttonStyle(.glassProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(server.host.isEmpty || fullName.isEmpty)
      }
      .padding(20)
    }
  }
}

private struct ProfileImportView: View {
  @Environment(MailStore.self) private var store
  let onDone: () -> Void
  @State private var profiles = ProfileImporter.profiles()
  @State private var profile: ProfileImporter.Profile?
  @State private var found: [MailAccount] = []
  @State private var chosen: Set<UUID> = []

  var body: some View {
    VStack(spacing: 0) {
      Form {
        if profiles.isEmpty {
          Text("No Thunderbird profile was found in ~/Library/Thunderbird.")
            .foregroundStyle(.secondary)
        } else {
          Picker("Profile", selection: $profile) {
            Text("Choose a profile").tag(ProfileImporter.Profile?.none)
            ForEach(profiles) { Text($0.name).tag(Optional($0)) }
          }
          .onChange(of: profile, initial: false) { _, new in
            let existing = Set(store.accounts.map { "\($0.kind.rawValue):\($0.incoming.host):\($0.incoming.username)" })
            found = new.map { ProfileImporter.accounts(in: $0.url) }?.filter {
              !existing.contains("\($0.kind.rawValue):\($0.incoming.host):\($0.incoming.username)")
            } ?? []
            chosen = Set(found.map(\.id))
          }
          if !found.isEmpty {
            Section("Accounts") {
              ForEach(found) { account in
                Toggle(
                  isOn: Binding(
                    get: { chosen.contains(account.id) },
                    set: { if $0 { chosen.insert(account.id) } else { chosen.remove(account.id) } })
                ) {
                  VStack(alignment: .leading) {
                    Text(account.label)
                    Text("\(account.kind.label) · \(account.incoming.host)")
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                }
              }
            }
            Text("Passwords aren't imported. You'll be asked for them in Settings › Accounts.")
              .font(.callout)
              .foregroundStyle(.secondary)
          } else if profile != nil {
            Text("No new accounts were found in this profile.")
              .foregroundStyle(.secondary)
          }
        }
      }
      .formStyle(.grouped)
      .scrollContentBackground(.hidden)
      HStack {
        Spacer()
        Button("Cancel", role: .cancel, action: onDone)
          .keyboardShortcut(.cancelAction)
        Button("Import \(chosen.count) Account\(chosen.count == 1 ? "" : "s")") {
          for account in found where chosen.contains(account.id) {
            try? store.addAccount(account, incomingPassword: nil, outgoingPassword: nil)
          }
          onDone()
        }
        .buttonStyle(.glassProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(chosen.isEmpty)
      }
      .padding(20)
    }
  }
}
