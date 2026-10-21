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
  case inbox, drafts, templates, sent, archive, junk, trash, all, flagged, outbox, normal

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
    case .outbox: 9
    case .normal: 10
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
    case .outbox: "tray.and.arrow.up"
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
  /// A display name that differs from the path, for stores whose folders are identified by ID.
  public var name: String?

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
    if let name { return name }
    return role == .inbox ? "Inbox" : (components.last ?? path)
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
    case "unsent messages", "outbox": return .outbox
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
  public var references: [String]
  /// X-Priority, 1 (highest) to 5 (lowest); 0 when the message doesn't say.
  public var priority: Int = 0
  /// When the server received the message (IMAP INTERNALDATE), if known.
  public var received: Date?
  /// The List-Post address, for Reply to List.
  public var listPost: String?

  public var id: UInt32 { uid }

  public init(
    uid: UInt32, subject: String, from: [MailAddress], to: [MailAddress], cc: [MailAddress],
    date: Date, size: Int, flags: Set<String>, messageID: String?, inReplyTo: String?,
    hasAttachment: Bool, references: [String] = []
  ) {
    self.references = references
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
  public var isJunk: Bool { flags.contains(MessageFlag.junk) }
  public var tags: [MessageTag] { MessageTag.defaults.filter { flags.contains($0.keyword) } }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    uid = try c.decode(UInt32.self, forKey: .uid)
    subject = try c.decode(String.self, forKey: .subject)
    from = try c.decode([MailAddress].self, forKey: .from)
    to = try c.decode([MailAddress].self, forKey: .to)
    cc = try c.decode([MailAddress].self, forKey: .cc)
    date = try c.decode(Date.self, forKey: .date)
    size = try c.decode(Int.self, forKey: .size)
    flags = try c.decode(Set<String>.self, forKey: .flags)
    messageID = try c.decodeIfPresent(String.self, forKey: .messageID)
    inReplyTo = try c.decodeIfPresent(String.self, forKey: .inReplyTo)
    hasAttachment = try c.decode(Bool.self, forKey: .hasAttachment)
    references = try c.decodeIfPresent([String].self, forKey: .references) ?? []
    priority = try c.decodeIfPresent(Int.self, forKey: .priority) ?? 0
    received = try c.decodeIfPresent(Date.self, forKey: .received)
    listPost = try c.decodeIfPresent(String.self, forKey: .listPost)
  }

  static func parsePriority(_ value: String?) -> Int {
    guard let value = value?.trimmingCharacters(in: .whitespaces).lowercased(), !value.isEmpty else { return 0 }
    if let digit = value.first?.wholeNumberValue { return min(5, max(1, digit)) }
    if value.contains("highest") { return 1 }
    if value.contains("high") || value.contains("urgent") { return 2 }
    if value.contains("lowest") { return 5 }
    if value.contains("low") { return 4 }
    return 3
  }

  static func parseListPost(_ value: String?) -> String? {
    guard let value, let start = value.range(of: "<mailto:", options: .caseInsensitive),
      let end = value[start.upperBound...].firstIndex(of: ">")
    else { return nil }
    return String(value[start.upperBound..<end]).components(separatedBy: "?").first
  }

  /// Builds a summary from a raw message, for stores that keep whole messages locally.
  public init(uid: UInt32, data: Data, flags: Set<String>, fallbackDate: Date = Date()) {
    let headers = MIMEParser.parseHeaders(data)
    let contentType = headers["Content-Type"]?.lowercased() ?? ""
    self.init(
      uid: uid,
      subject: headers.decoded("Subject") ?? "",
      from: MailAddress.parseList(headers["From"] ?? ""),
      to: MailAddress.parseList(headers["To"] ?? headers["Newsgroups"] ?? ""),
      cc: MailAddress.parseList(headers["Cc"] ?? ""),
      date: headers["Date"].flatMap(MailDate.parse) ?? fallbackDate,
      size: data.count,
      flags: flags,
      messageID: headers["Message-ID"]?.trimmingCharacters(in: .whitespaces),
      inReplyTo: headers["In-Reply-To"]?.trimmingCharacters(in: .whitespaces),
      hasAttachment: contentType.contains("multipart/mixed"),
      references: MessageSummary.parseReferences(headers["References"])
    )
    priority = Self.parsePriority(headers["X-Priority"] ?? headers["Importance"])
    listPost = Self.parseListPost(headers["List-Post"])
  }

  public static func parseReferences(_ value: String?) -> [String] {
    guard let value else { return [] }
    var result: [String] = []
    var current = ""
    var inside = false
    for char in value {
      if char == "<" {
        inside = true
        current = "<"
      } else if char == ">" && inside {
        current.append(">")
        result.append(current)
        inside = false
      } else if inside {
        current.append(char)
      }
    }
    return result
  }
}

public enum MessageFlag {
  public static let seen = "\\Seen"
  public static let flagged = "\\Flagged"
  public static let answered = "\\Answered"
  public static let deleted = "\\Deleted"
  public static let draft = "\\Draft"
  public static let forwarded = "$Forwarded"
  public static let junk = "$Junk"
  public static let notJunk = "$NotJunk"
  public static let mdnSent = "$MDNSent"

  /// IMAP system flags are case-insensitive; normalise them so set lookups work.
  static func normalize(_ flag: String) -> String {
    switch flag.lowercased() {
    case "\\seen": seen
    case "\\flagged": flagged
    case "\\answered": answered
    case "\\deleted": deleted
    case "\\draft": draft
    case "$forwarded": forwarded
    case "$junk", "junk": junk
    case "$notjunk", "nonjunk", "notjunk": notJunk
    default: flag.hasPrefix("$label") ? flag.lowercased() : flag
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
  case unsupported(String)
  case needsSignIn(String)
  case hostNotFound(String)
  case cannotConnect(String, Int)
  case tlsFailed(String)
  case offline

  public var errorDescription: String? {
    switch self {
    case .connectionClosed: "The server closed the connection."
    case .timeout: "The server did not respond in time."
    case .protocolError(let detail): "Unexpected response from the server: \(detail)"
    case .server(let detail): "The server reported an error: \(detail)"
    case .authenticationFailed(let detail): "Login failed: \(detail)"
    case .missingPassword(let host): "No password is saved for \(host)."
    case .invalidRecipients: "Add at least one valid recipient."
    case .unsupported(let what): "\(what) isn't supported for this account."
    case .needsSignIn(let host): "Sign in to \(host) again from Account Settings."
    case .hostNotFound(let host): "Couldn't find the server “\(host)”. Check the server name."
    case .cannotConnect(let host, let port):
      "Couldn't connect to \(host) on port \(port). Check the port, or that the server (or Proton Mail Bridge) is running."
    case .tlsFailed(let host): "Couldn't make a secure connection to \(host). Check the connection security setting."
    case .offline: "You're offline."
    }
  }

  public var isConnectionLoss: Bool {
    switch self {
    case .connectionClosed, .timeout: true
    default: false
    }
  }
}
