/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation

public enum AccountKind: String, Codable, Sendable, CaseIterable, Hashable {
  case imap, pop3, local, nntp

  public var label: String {
    switch self {
    case .imap: "IMAP"
    case .pop3: "POP3"
    case .local: "Local Folders"
    case .nntp: "Newsgroups"
    }
  }
}

public enum AuthMethod: String, Codable, Sendable, CaseIterable, Hashable {
  case password
  case oauth2

  public var label: String {
    switch self {
    case .password: "Normal password"
    case .oauth2: "OAuth2"
    }
  }
}

public struct ServerConfig: Codable, Sendable, Hashable {
  public var host: String
  public var port: Int
  public var security: ConnectionSecurity
  public var username: String
  public var auth: AuthMethod

  public init(host: String, port: Int, security: ConnectionSecurity, username: String, auth: AuthMethod = .password) {
    self.host = host
    self.port = port
    self.security = security
    self.username = username
    self.auth = auth
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    host = try container.decode(String.self, forKey: .host)
    port = try container.decode(Int.self, forKey: .port)
    security = try container.decode(ConnectionSecurity.self, forKey: .security)
    username = try container.decode(String.self, forKey: .username)
    auth = try container.decodeIfPresent(AuthMethod.self, forKey: .auth) ?? .password
  }

  public static let none = ServerConfig(host: "", port: 0, security: .none, username: "")
}

public enum SecurityTechnology: String, Codable, Sendable, CaseIterable, Hashable {
  case openPGP
  case smime

  public var label: String {
    switch self {
    case .openPGP: "OpenPGP"
    case .smime: "S/MIME"
    }
  }
}

/// An address the user can send from. The account's primary identity is `MailAccount.identity`.
public struct Identity: Codable, Sendable, Hashable, Identifiable {
  public var id: UUID
  public var fullName: String
  public var email: String
  public var replyTo: String
  public var signature: String

  public init(id: UUID = UUID(), fullName: String, email: String, replyTo: String = "", signature: String = "") {
    self.id = id
    self.fullName = fullName
    self.email = email
    self.replyTo = replyTo
    self.signature = signature
  }

  public var address: MailAddress { MailAddress(name: fullName, email: email) }
}

public struct MailAccount: Codable, Sendable, Identifiable, Hashable {
  public var id: UUID
  public var kind: AccountKind
  public var fullName: String
  public var email: String
  public var label: String
  public var signature: String
  public var replyTo: String
  public var incoming: ServerConfig
  public var outgoing: ServerConfig
  public var extraIdentities: [Identity]
  public var composeHTML: Bool
  public var leaveMessagesOnServer: Bool
  public var openPGPKeyID: String?
  public var securityTechnology: SecurityTechnology
  public var encryptByDefault: Bool
  public var signByDefault: Bool

  public init(
    id: UUID = UUID(), kind: AccountKind = .imap, fullName: String, email: String, label: String? = nil,
    signature: String = "", incoming: ServerConfig, outgoing: ServerConfig
  ) {
    self.id = id
    self.kind = kind
    self.fullName = fullName
    self.email = email
    self.label = label ?? email
    self.signature = signature
    self.replyTo = ""
    self.incoming = incoming
    self.outgoing = outgoing
    self.extraIdentities = []
    self.composeHTML = true
    self.leaveMessagesOnServer = true
    self.openPGPKeyID = nil
    self.securityTechnology = .openPGP
    self.encryptByDefault = false
    self.signByDefault = false
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(UUID.self, forKey: .id)
    kind = try c.decodeIfPresent(AccountKind.self, forKey: .kind) ?? .imap
    fullName = try c.decode(String.self, forKey: .fullName)
    email = try c.decode(String.self, forKey: .email)
    label = try c.decode(String.self, forKey: .label)
    signature = try c.decodeIfPresent(String.self, forKey: .signature) ?? ""
    replyTo = try c.decodeIfPresent(String.self, forKey: .replyTo) ?? ""
    incoming = try c.decode(ServerConfig.self, forKey: .incoming)
    outgoing = try c.decode(ServerConfig.self, forKey: .outgoing)
    extraIdentities = try c.decodeIfPresent([Identity].self, forKey: .extraIdentities) ?? []
    composeHTML = try c.decodeIfPresent(Bool.self, forKey: .composeHTML) ?? true
    leaveMessagesOnServer = try c.decodeIfPresent(Bool.self, forKey: .leaveMessagesOnServer) ?? true
    openPGPKeyID = try c.decodeIfPresent(String.self, forKey: .openPGPKeyID)
    securityTechnology = try c.decodeIfPresent(SecurityTechnology.self, forKey: .securityTechnology) ?? .openPGP
    encryptByDefault = try c.decodeIfPresent(Bool.self, forKey: .encryptByDefault) ?? false
    signByDefault = try c.decodeIfPresent(Bool.self, forKey: .signByDefault) ?? false
  }

  public static func localFolders() -> MailAccount {
    MailAccount(kind: .local, fullName: "", email: "", label: "Local Folders", incoming: .none, outgoing: .none)
  }

  public var identity: Identity {
    Identity(id: id, fullName: fullName, email: email, replyTo: replyTo, signature: signature)
  }

  public var identities: [Identity] { kind == .local ? [] : [identity] + extraIdentities }
  public var canSend: Bool { kind == .imap || kind == .pop3 || kind == .nntp }
  public var address: MailAddress { MailAddress(name: fullName, email: email) }
  public var incomingKeychainKey: String { "\(id.uuidString).\(kind == .imap ? "imap" : kind.rawValue)" }
  public var outgoingKeychainKey: String { "\(id.uuidString).smtp" }
}

/// Thunderbird's default message tags, stored as IMAP keywords.
public struct MessageTag: Sendable, Hashable, Identifiable {
  public var keyword: String
  public var name: String
  public var colorHex: String
  public var id: String { keyword }

  public init(keyword: String, name: String, colorHex: String) {
    self.keyword = keyword
    self.name = name
    self.colorHex = colorHex
  }

  public static let defaults: [MessageTag] = [
    MessageTag(keyword: "$label1", name: "Important", colorHex: "#FF0000"),
    MessageTag(keyword: "$label2", name: "Work", colorHex: "#FF9900"),
    MessageTag(keyword: "$label3", name: "Personal", colorHex: "#009900"),
    MessageTag(keyword: "$label4", name: "To Do", colorHex: "#3333FF"),
    MessageTag(keyword: "$label5", name: "Later", colorHex: "#993399"),
  ]
}

public struct MessageReference: Codable, Sendable, Hashable {
  public var accountID: UUID
  public var path: String
  public var uid: UInt32

  public init(accountID: UUID, path: String, uid: UInt32) {
    self.accountID = accountID
    self.path = path
    self.uid = uid
  }
}
