/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import ThunderbirdCore

/// Reads account settings from an existing Thunderbird profile's prefs.js. Passwords live in
/// Thunderbird's encrypted logins store and aren't imported; they're asked for on first use.
enum ProfileImporter {
  struct Profile: Identifiable, Hashable {
    var name: String
    var url: URL
    var id: URL { url }
  }

  static func profiles() -> [Profile] {
    let base = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Thunderbird")
    guard let ini = try? String(contentsOf: base.appending(path: "profiles.ini"), encoding: .utf8) else { return [] }
    var result: [Profile] = []
    var name: String?
    var path: String?
    var relative = true
    func flush() {
      if let path {
        let url = relative ? base.appending(path: path) : URL(filePath: path)
        if FileManager.default.fileExists(atPath: url.appending(path: "prefs.js").path) {
          result.append(Profile(name: name ?? url.lastPathComponent, url: url))
        }
      }
      name = nil
      path = nil
      relative = true
    }
    for line in ini.components(separatedBy: .newlines) {
      if line.hasPrefix("[") {
        flush()
      } else if line.hasPrefix("Name=") {
        name = String(line.dropFirst(5))
      } else if line.hasPrefix("Path=") {
        path = String(line.dropFirst(5))
      } else if line.hasPrefix("IsRelative=") {
        relative = line.hasSuffix("1")
      }
    }
    flush()
    return result
  }

  static func preferences(in profile: URL) -> [String: String] {
    guard let text = try? String(contentsOf: profile.appending(path: "prefs.js"), encoding: .utf8) else { return [:] }
    var prefs: [String: String] = [:]
    let pattern = #/user_pref\("([^"]+)",\s*(.+)\);/#
    for line in text.components(separatedBy: .newlines) {
      guard let match = line.firstMatch(of: pattern) else { continue }
      var value = String(match.2).trimmingCharacters(in: .whitespaces)
      if value.hasPrefix("\"") && value.hasSuffix("\"") {
        value = String(value.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
          .replacingOccurrences(of: "\\\\", with: "\\")
      }
      prefs[String(match.1)] = value
    }
    return prefs
  }

  static func security(_ socketType: String?) -> ConnectionSecurity {
    switch socketType {
    case "3": .tls
    case "2": .startTLS
    default: .none
    }
  }

  static func accounts(in profile: URL) -> [MailAccount] {
    let prefs = preferences(in: profile)
    let order = (prefs["mail.accountmanager.accounts"] ?? "").split(separator: ",").map(String.init)
    var result: [MailAccount] = []
    for key in order {
      guard let serverKey = prefs["mail.account.\(key).server"] else { continue }
      let server = "mail.server.\(serverKey)"
      let type = prefs["\(server).type"] ?? ""
      let kind: AccountKind
      switch type {
      case "imap": kind = .imap
      case "pop3": kind = .pop3
      case "nntp": kind = .nntp
      default: continue
      }
      let identityKey = (prefs["mail.account.\(key).identities"] ?? "").split(separator: ",").first.map(String.init) ?? ""
      let identity = "mail.identity.\(identityKey)"
      let email = prefs["\(identity).useremail"] ?? prefs["\(server).userName"] ?? ""
      let host = prefs["\(server).hostname"] ?? ""
      let socket = prefs["\(server).socketType"]
      let defaultPort: Int =
        switch (kind, security(socket)) {
        case (.imap, .tls): 993
        case (.imap, _): 143
        case (.pop3, .tls): 995
        case (.pop3, _): 110
        case (.nntp, .tls): 563
        default: 119
        }
      let incoming = ServerConfig(
        host: host, port: Int(prefs["\(server).port"] ?? "") ?? defaultPort, security: security(socket),
        username: prefs["\(server).userName"] ?? email,
        auth: prefs["\(server).authMethod"] == "10" ? .oauth2 : .password)

      var outgoing = ServerConfig.none
      if kind != .nntp {
        let smtpKey = prefs["\(identity).smtpServer"] ?? prefs["mail.smtp.defaultserver"] ?? ""
        let smtp = "mail.smtpserver.\(smtpKey)"
        let smtpSecurity = security(prefs["\(smtp).try_ssl"])
        outgoing = ServerConfig(
          host: prefs["\(smtp).hostname"] ?? "",
          port: Int(prefs["\(smtp).port"] ?? "") ?? (smtpSecurity == .tls ? 465 : 587),
          security: smtpSecurity, username: prefs["\(smtp).username"] ?? email,
          auth: prefs["\(smtp).authMethod"] == "10" ? .oauth2 : .password)
      }

      var account = MailAccount(
        kind: kind, fullName: prefs["\(identity).fullName"] ?? "", email: email,
        label: prefs["\(server).name"] ?? email, signature: prefs["\(identity).htmlSigText"] ?? "",
        incoming: incoming, outgoing: outgoing)
      account.replyTo = prefs["\(identity).reply_to"] ?? ""
      account.composeHTML = prefs["\(identity).compose_html"] != "false"
      account.leaveMessagesOnServer = prefs["\(server).leave_on_server"] != "false"
      account.openPGPKeyID = prefs["\(identity).openpgp_key_id"].map { $0.hasPrefix("0x") ? String($0.dropFirst(2)) : $0 }
      for extraKey in (prefs["mail.account.\(key).identities"] ?? "").split(separator: ",").dropFirst() {
        let extra = "mail.identity.\(extraKey)"
        if let extraEmail = prefs["\(extra).useremail"] {
          account.extraIdentities.append(
            Identity(
              fullName: prefs["\(extra).fullName"] ?? account.fullName, email: extraEmail,
              replyTo: prefs["\(extra).reply_to"] ?? "", signature: prefs["\(extra).htmlSigText"] ?? ""))
        }
      }
      result.append(account)
    }
    return result
  }
}
