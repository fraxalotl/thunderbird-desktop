/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import SwiftUI
import ThunderbirdCore

struct ServerConfigEditor: View {
  @Binding var config: ServerConfig
  let defaultPorts: [ConnectionSecurity: Int]
  var showsAuthentication = true

  var body: some View {
    TextField("Server", text: $config.host, prompt: Text("imap.example.com"))
      .autocorrectionDisabled()
    Picker("Connection security", selection: $config.security) {
      ForEach(ConnectionSecurity.allCases, id: \.self) { security in
        Text(security.label)
          .tag(security)
      }
    }
    .onChange(of: config.security) { old, new in
      if config.port == defaultPorts[old], let port = defaultPorts[new] {
        config.port = port
      }
    }
    TextField("Port", value: $config.port, format: .number.grouping(.never))
    TextField("Username", text: $config.username)
      .autocorrectionDisabled()
    if showsAuthentication {
      Picker("Authentication", selection: $config.auth) {
        ForEach(AuthMethod.allCases, id: \.self) { Text($0.label).tag($0) }
      }
      if config.auth == .oauth2 && OAuth2Provider.forHost(config.host) == nil {
        Label("OAuth2 isn't available for this server.", systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
          .font(.callout)
      }
    }
    if config.security == .none {
      Label("Your password and messages will be sent unencrypted.", systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
        .font(.callout)
    }
  }

  static let imapPorts: [ConnectionSecurity: Int] = [.tls: 993, .startTLS: 143, .none: 143]
  static let pop3Ports: [ConnectionSecurity: Int] = [.tls: 995, .startTLS: 110, .none: 110]
  static let smtpPorts: [ConnectionSecurity: Int] = [.tls: 465, .startTLS: 587, .none: 25]
  static let nntpPorts: [ConnectionSecurity: Int] = [.tls: 563, .startTLS: 119, .none: 119]

  static func ports(for kind: AccountKind) -> [ConnectionSecurity: Int] {
    switch kind {
    case .pop3: pop3Ports
    case .nntp: nntpPorts
    default: imapPorts
    }
  }
}
