/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import SwiftUI
import ThunderbirdCore

struct ServerConfigEditor: View {
  @Binding var config: ServerConfig
  let defaultPorts: [ConnectionSecurity: Int]

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
    if config.security == .none {
      Label("Your password and messages will be sent unencrypted.", systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
        .font(.callout)
    }
  }

  static let imapPorts: [ConnectionSecurity: Int] = [.tls: 993, .startTLS: 143, .none: 143]
  static let smtpPorts: [ConnectionSecurity: Int] = [.tls: 465, .startTLS: 587, .none: 25]
}
