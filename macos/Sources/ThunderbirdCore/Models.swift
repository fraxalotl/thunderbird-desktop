/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation

public enum ConnectionSecurity: String, Codable, Sendable, CaseIterable, Hashable {
  case tls
  case startTLS
  case none

  public var label: String {
    switch self {
    case .tls: "SSL/TLS"
    case .startTLS: "STARTTLS"
    case .none: "None"
    }
  }
}

public struct ServerConfig: Codable, Sendable, Hashable {
  public var host: String
  public var port: Int
  public var security: ConnectionSecurity
  public var username: String

  public init(host: String, port: Int, security: ConnectionSecurity, username: String) {
    self.host = host
    self.port = port
    self.security = security
    self.username = username
  }
}

public struct MailAccount: Codable, Sendable, Identifiable, Hashable {
  public var id: UUID
  public var fullName: String
  public var email: String
  public var label: String
  public var signature: String
  public var incoming: ServerConfig
  public var outgoing: ServerConfig

  public init(
    id: UUID = UUID(), fullName: String, email: String, label: String? = nil,
    signature: String = "", incoming: ServerConfig, outgoing: ServerConfig
  ) {
    self.id = id
    self.fullName = fullName
    self.email = email
    self.label = label ?? email
    self.signature = signature
    self.incoming = incoming
    self.outgoing = outgoing
  }

  public var address: MailAddress { MailAddress(name: fullName, email: email) }
  public var incomingKeychainKey: String { "\(id.uuidString).imap" }
  public var outgoingKeychainKey: String { "\(id.uuidString).smtp" }
}

public struct MailAddress: Codable, Sendable, Hashable {
  public var name: String?
  public var email: String

  public init(name: String? = nil, email: String) {
    let trimmed = name?.trimmingCharacters(in: .whitespaces)
    self.name = (trimmed?.isEmpty ?? true) ? nil : trimmed
    self.email = email.trimmingCharacters(in: .whitespaces)
  }

  public var displayName: String { name ?? email }

  public var formatted: String {
    guard let name else { return email }
    return "\(name) <\(email)>"
  }

  /// Parses a comma separated address list such as a To header or a compose field.
  public static func parseList(_ value: String) -> [MailAddress] {
    var tokens: [String] = []
    var current = ""
    var inQuotes = false
    var inAngle = false
    var previous: Character = " "
    for char in value {
      switch char {
      case "\"" where previous != "\\": inQuotes.toggle()
      case "<" where !inQuotes: inAngle = true
      case ">" where !inQuotes: inAngle = false
      case ",", ";":
        if !inQuotes && !inAngle {
          tokens.append(current)
          current = ""
          previous = char
          continue
        }
      default: break
      }
      current.append(char)
      previous = char
    }
    tokens.append(current)

    return tokens.compactMap { raw in
      var token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if let colon = token.firstIndex(of: ":"),
        !token[..<colon].contains(where: { "\"<@".contains($0) })
      {
        token = String(token[token.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
      }
      guard !token.isEmpty else { return nil }
      if let open = token.lastIndex(of: "<"), let close = token.lastIndex(of: ">"), open < close {
        let email = String(token[token.index(after: open)..<close])
        var name = token[..<open].trimmingCharacters(in: .whitespaces)
        if name.hasPrefix("\"") && name.hasSuffix("\"") && name.count >= 2 {
          name = String(name.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
        }
        guard email.contains("@") else { return nil }
        return MailAddress(name: MIMEDecoder.decodeEncodedWords(name), email: email)
      }
      guard token.contains("@") else { return nil }
      return MailAddress(email: token)
    }
  }
}

public enum FolderRole: String, Codable, Sendable, Hashable {
  case inbox, drafts, templates, sent, archive, junk, trash, all, flagged, normal

  public var sortRank: Int {
    switch self {
    case .inbox: 0
    case .drafts: 1
    case .templates: 2
    case .sent: 3
    case .archive: 4
    case .junk: 5
    case .trash: 6
    case .all: 7
    case .flagged: 8
    case .normal: 9
    }
  }

  public var symbolName: String {
    switch self {
    case .inbox: "tray"
    case .drafts: "doc"
    case .templates: "doc.on.doc"
    case .sent: "paperplane"
    case .archive: "archivebox"
    case .junk: "xmark.bin"
    case .trash: "trash"
    case .all: "tray.2"
    case .flagged: "star"
    case .normal: "folder"
    }
  }
}

public struct RemoteFolder: Codable, Sendable, Hashable, Identifiable {
  /// The mailbox name as the server knows it (modified UTF-7).
  public var path: String
  public var delimiter: String?
  public var attributes: Set<String>
  public var role: FolderRole
  public var unseen: Int?
  public var total: Int?

  public var id: String { path }

  public init(path: String, delimiter: String?, attributes: Set<String>, role: FolderRole? = nil) {
    self.path = path
    self.delimiter = delimiter
    self.attributes = attributes
    self.role = role ?? RemoteFolder.detectRole(path: path, delimiter: delimiter, attributes: attributes)
  }

  public var isSelectable: Bool {
    !attributes.contains("\\noselect") && !attributes.contains("\\nonexistent")
  }

  public var components: [String] {
    let decoded = ModifiedUTF7.decode(path)
    guard let delimiter, !delimiter.isEmpty else { return [decoded] }
    return decoded.components(separatedBy: delimiter)
  }

  public var displayName: String {
    role == .inbox ? "Inbox" : (components.last ?? path)
  }

  static func detectRole(path: String, delimiter: String?, attributes: Set<String>) -> FolderRole {
    if path.uppercased() == "INBOX" { return .inbox }
    let byAttribute: [(String, FolderRole)] = [
      ("\\sent", .sent), ("\\drafts", .drafts), ("\\trash", .trash), ("\\junk", .junk),
      ("\\archive", .archive), ("\\all", .all), ("\\flagged", .flagged),
    ]
    for (attribute, role) in byAttribute where attributes.contains(attribute) {
      return role
    }
    let leaf: String
    if let delimiter, !delimiter.isEmpty {
      leaf = ModifiedUTF7.decode(path).components(separatedBy: delimiter).last ?? path
    } else {
      leaf = path
    }
    switch leaf.lowercased() {
    case "sent", "sent items", "sent messages", "sent mail": return .sent
    case "drafts", "draft": return .drafts
    case "templates": return .templates
    case "trash", "deleted items", "deleted messages", "bin": return .trash
    case "junk", "spam", "junk e-mail", "junk email": return .junk
    case "archive", "archives": return .archive
    default: return .normal
    }
  }
}

public struct MessageSummary: Codable, Sendable, Hashable, Identifiable {
  public var uid: UInt32
  public var subject: String
  public var from: [MailAddress]
  public var to: [MailAddress]
  public var cc: [MailAddress]
  public var date: Date
  public var size: Int
  public var flags: Set<String>
  public var messageID: String?
  public var inReplyTo: String?
  public var hasAttachment: Bool

  public var id: UInt32 { uid }

  public init(
    uid: UInt32, subject: String, from: [MailAddress], to: [MailAddress], cc: [MailAddress],
    date: Date, size: Int, flags: Set<String>, messageID: String?, inReplyTo: String?,
    hasAttachment: Bool
  ) {
    self.uid = uid
    self.subject = subject
    self.from = from
    self.to = to
    self.cc = cc
    self.date = date
    self.size = size
    self.flags = flags
    self.messageID = messageID
    self.inReplyTo = inReplyTo
    self.hasAttachment = hasAttachment
  }

  public var isRead: Bool { flags.contains(MessageFlag.seen) }
  public var isFlagged: Bool { flags.contains(MessageFlag.flagged) }
  public var isAnswered: Bool { flags.contains(MessageFlag.answered) }
  public var isForwarded: Bool { flags.contains(MessageFlag.forwarded) }
}

public enum MessageFlag {
  public static let seen = "\\Seen"
  public static let flagged = "\\Flagged"
  public static let answered = "\\Answered"
  public static let deleted = "\\Deleted"
  public static let draft = "\\Draft"
  public static let forwarded = "$Forwarded"

  /// IMAP system flags are case-insensitive; normalise them so set lookups work.
  static func normalize(_ flag: String) -> String {
    switch flag.lowercased() {
    case "\\seen": seen
    case "\\flagged": flagged
    case "\\answered": answered
    case "\\deleted": deleted
    case "\\draft": draft
    case "$forwarded": forwarded
    default: flag
    }
  }
}

public enum MailError: LocalizedError, Sendable {
  case connectionClosed
  case timeout
  case protocolError(String)
  case server(String)
  case authenticationFailed(String)
  case missingPassword(String)
  case invalidRecipients

  public var errorDescription: String? {
    switch self {
    case .connectionClosed: "The server closed the connection."
    case .timeout: "The server did not respond in time."
    case .protocolError(let detail): "Unexpected response from the server: \(detail)"
    case .server(let detail): "The server reported an error: \(detail)"
    case .authenticationFailed(let detail): "Login failed: \(detail)"
    case .missingPassword(let host): "No password is saved for \(host)."
    case .invalidRecipients: "Add at least one valid recipient."
    }
  }

  public var isConnectionLoss: Bool {
    switch self {
    case .connectionClosed, .timeout: true
    default: false
    }
  }
}
