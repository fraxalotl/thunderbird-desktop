/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import SwiftUI
import ThunderbirdCore

struct AccountSetupView: View {
  @Environment(MailStore.self) private var store
  @Environment(\.dismiss) private var dismiss

  private enum Step {
    case details, lookingUp, review, testing
  }

  @State private var step = Step.details
  @State private var fullName = NSFullUserName()
  @State private var email = ""
  @State private var password = ""
  @State private var discovered: DiscoveredConfig?
  @State private var incoming = ServerConfig(host: "", port: 993, security: .tls, username: "")
  @State private var outgoing = ServerConfig(host: "", port: 465, security: .tls, username: "")
  @State private var editingManually = false
  @State private var errorMessage: String?

  private var emailLooksValid: Bool {
    let parts = email.split(separator: "@")
    return parts.count == 2 && parts[1].contains(".") && !parts[0].isEmpty
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 14) {
        Image(nsImage: NSApp.applicationIconImage)
          .resizable()
          .frame(width: 52, height: 52)
        VStack(alignment: .leading, spacing: 2) {
          Text("Set Up Your Existing Email Address")
            .font(.title2.weight(.semibold))
          Text("Thunderbird will look up your provider's settings for you.")
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
      .padding([.horizontal, .top], 24)
      .padding(.bottom, 8)

      Form {
        Section {
          TextField("Your full name", text: $fullName)
          TextField("Email address", text: $email, prompt: Text("you@example.com"))
            .textContentType(.emailAddress)
            .autocorrectionDisabled()
            .disabled(step != .details)
          SecureField("Password", text: $password)
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
          Text(step == .lookingUp ? "Looking up configuration…" : "Checking your password…")
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        if step == .details || step == .lookingUp {
          Button("Continue") { Task { await lookUp() } }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!emailLooksValid || password.isEmpty || fullName.isEmpty || step == .lookingUp)
        } else {
          Button("Back") {
            step = .details
            errorMessage = nil
          }
          .disabled(step == .testing)
          Button("Done") { Task { await finish() } }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(step == .testing || incoming.host.isEmpty || outgoing.host.isEmpty)
        }
      }
      .padding(20)
    }
    .frame(width: 560)
    .frame(minHeight: 380)
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
        if discovered.requiresOAuth {
          Label(
            "This provider normally uses OAuth sign-in, which isn't supported yet. Use an app password instead.",
            systemImage: "key.fill"
          )
          .foregroundStyle(.orange)
        }
        if !editingManually {
          serverSummary("Incoming", "IMAP", incoming)
          serverSummary("Outgoing", "SMTP", outgoing)
        }
        Toggle("Configure manually", isOn: $editingManually.animation(.smooth))
      }
      if editingManually {
        Section("Incoming Server (IMAP)") {
          ServerConfigEditor(config: $incoming, defaultPorts: ServerConfigEditor.imapPorts)
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
        Text("\(protocolName) · \(config.security.label) · \(config.username)")
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
    editingManually = config.source == .guess
    step = .review
  }

  private func finish() async {
    errorMessage = nil
    step = .testing
    do {
      try await AccountService.testConnection(server: incoming, password: password)
      try await SMTPClient(server: outgoing, password: password).verify()
      let account = MailAccount(
        fullName: fullName,
        email: email.trimmingCharacters(in: .whitespaces),
        incoming: incoming,
        outgoing: outgoing
      )
      try store.addAccount(account, incomingPassword: password, outgoingPassword: password)
      dismiss()
    } catch {
      errorMessage = error.localizedDescription
      editingManually = true
      step = .review
    }
  }
}
