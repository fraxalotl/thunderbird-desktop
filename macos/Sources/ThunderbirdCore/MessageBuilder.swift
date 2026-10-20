/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation

public struct OutgoingAttachment: Sendable, Hashable {
  public var filename: String
  public var mimeType: String
  public var data: Data

  public init(filename: String, mimeType: String, data: Data) {
    self.filename = filename
    self.mimeType = mimeType
    self.data = data
  }
}

/// An extra body alternative, such as a `text/calendar` invitation reply.
public struct OutgoingAlternative: Sendable, Hashable {
  public var contentType: String
  public var text: String

  public init(contentType: String, text: String) {
    self.contentType = contentType
    self.text = text
  }
}

public struct OutgoingSecurity: Sendable, Hashable {
  public var technology: SecurityTechnology
  public var sign: Bool
  public var encrypt: Bool
  /// OpenPGP key ID or fingerprint of the sender; ignored for S/MIME, which uses the sender's email.
  public var signerKey: String?

  public init(technology: SecurityTechnology, sign: Bool, encrypt: Bool, signerKey: String? = nil) {
    self.technology = technology
    self.sign = sign
    self.encrypt = encrypt
    self.signerKey = signerKey
  }
}

/// Applies OpenPGP or S/MIME protection to a MIME entity. Implemented by `MessageSecurity`.
public protocol EntityProtector: Sendable {
  func protect(entity: Data, security: OutgoingSecurity, from: MailAddress, recipients: [MailAddress]) throws -> Data
}

public struct OutgoingMessage: Sendable {
  public var from: MailAddress
  public var to: [MailAddress]
  public var cc: [MailAddress]
  public var bcc: [MailAddress]
  public var replyTo: [MailAddress]
  public var newsgroups: [String]
  public var subject: String
  public var body: String
  public var htmlBody: String?
  public var alternatives: [OutgoingAlternative]
  public var inReplyTo: String?
  public var references: [String]
  public var attachments: [OutgoingAttachment]
  public var extraHeaders: [HeaderField]
  /// Drafts keep Bcc so it survives reopening; sent mail never includes it.
  public var includeBccHeader: Bool
  public var security: OutgoingSecurity?
  public var protector: (any EntityProtector)?

  public init(
    from: MailAddress, to: [MailAddress], cc: [MailAddress] = [], bcc: [MailAddress] = [], subject: String,
    body: String, inReplyTo: String? = nil, references: [String] = [], attachments: [OutgoingAttachment] = []
  ) {
    self.from = from
    self.to = to
    self.cc = cc
    self.bcc = bcc
    self.replyTo = []
    self.newsgroups = []
    self.subject = subject
    self.body = body
    self.htmlBody = nil
    self.alternatives = []
    self.inReplyTo = inReplyTo
    self.references = references
    self.attachments = attachments
    self.extraHeaders = []
    self.includeBccHeader = false
    self.security = nil
    self.protector = nil
  }

  public var allRecipients: [MailAddress] { to + cc + bcc }

  public static func makeMessageID(domainOf email: String) -> String {
    let domain = email.split(separator: "@").last.map(String.init) ?? "localhost"
    return "<\(UUID().uuidString.lowercased())@\(domain)>"
  }

  /// Renders the message as RFC 5322 bytes with CRLF line endings.
  public func render(date: Date = Date(), messageID: String) throws -> Data {
    var lines: [String] = [
      "Date: \(MailDate.format(date))",
      "From: \(Self.encodeAddress(from))",
    ]
    func addressHeader(_ name: String, _ list: [MailAddress]) {
      if !list.isEmpty {
        lines.append("\(name): \(list.map(Self.encodeAddress).joined(separator: ",\r\n "))")
      }
    }
    addressHeader("Reply-To", replyTo)
    addressHeader("To", to)
    addressHeader("Cc", cc)
    if includeBccHeader {
      addressHeader("Bcc", bcc)
    }
    if !newsgroups.isEmpty {
      lines.append("Newsgroups: \(newsgroups.joined(separator: ","))")
    }
    lines.append("Subject: \(Self.encodeHeaderText(subject))")
    lines.append("Message-ID: \(messageID)")
    if let inReplyTo {
      lines.append("In-Reply-To: \(inReplyTo)")
    }
    if !references.isEmpty {
      lines.append("References: \(references.joined(separator: "\r\n "))")
    }
    for header in extraHeaders {
      lines.append("\(header.name): \(header.value)")
    }
    lines.append("MIME-Version: 1.0")
    lines.append("User-Agent: Thunderbird for macOS")

    var entity = Data(bodyEntity().joined(separator: "\r\n").utf8)
    if let security, security.sign || security.encrypt {
      guard let protector else { throw MailError.unsupported("Message security") }
      entity = try protector.protect(entity: entity, security: security, from: from, recipients: allRecipients)
    }
    var output = Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    output.append(entity)
    if !output.ends(with: crlf) {
      output.append(crlf)
    }
    return output
  }

  /// The MIME entity (its own Content-Type headers, a blank line and the body).
  func bodyEntity() -> [String] {
    var textEntity: [String]
    let plain = Self.textPart(body, subtype: "plain")
    if htmlBody != nil || !alternatives.isEmpty {
      let boundary = Self.makeBoundary()
      textEntity = ["Content-Type: multipart/alternative; boundary=\"\(boundary)\"", "", "--\(boundary)"]
      textEntity += plain
      if let htmlBody {
        textEntity += ["--\(boundary)"] + Self.textPart(htmlBody, subtype: "html")
      }
      for alternative in alternatives {
        textEntity += ["--\(boundary)"] + Self.textPart(alternative.text, contentType: alternative.contentType)
      }
      textEntity.append("--\(boundary)--")
    } else {
      textEntity = plain
    }
    guard !attachments.isEmpty else { return textEntity }

    let boundary = Self.makeBoundary()
    var lines = [
      "Content-Type: multipart/mixed; boundary=\"\(boundary)\"", "",
      "This is a multi-part message in MIME format.", "--\(boundary)",
    ]
    lines += textEntity
    for attachment in attachments {
      lines.append("--\(boundary)")
      let name = Self.encodeHeaderText(attachment.filename)
      lines.append("Content-Type: \(attachment.mimeType); name=\"\(name)\"")
      lines.append("Content-Disposition: attachment; \(Self.filenameParameter(attachment.filename))")
      lines.append("Content-Transfer-Encoding: base64")
      lines.append("")
      lines.append(
        attachment.data.base64EncodedString(options: [
          .lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed,
        ]))
    }
    lines.append("--\(boundary)--")
    return lines
  }

  static func makeBoundary() -> String {
    "------------\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
  }

  private static func textPart(_ body: String, subtype: String) -> [String] {
    textPart(body, contentType: "text/\(subtype); charset=UTF-8")
  }

  private static func textPart(_ body: String, contentType: String) -> [String] {
    let normalized = body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    let needsEncoding = !normalized.allSatisfy(\.isASCII)
      || normalized.split(separator: "\n", omittingEmptySubsequences: false).contains { $0.utf8.count > 900 }
    if needsEncoding {
      return [
        "Content-Type: \(contentType)",
        "Content-Transfer-Encoding: quoted-printable",
        "",
        encodeQuotedPrintable(normalized),
      ]
    }
    return [
      "Content-Type: \(contentType)",
      "Content-Transfer-Encoding: 7bit",
      "",
      normalized.replacingOccurrences(of: "\n", with: "\r\n"),
    ]
  }

  static func encodeQuotedPrintable(_ text: String) -> String {
    var output: [String] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      var encodedLine = ""
      var lineLength = 0
      let bytes = Array(line.utf8)
      for (index, byte) in bytes.enumerated() {
        let isLast = index == bytes.count - 1
        let isPlain =
          (byte >= 33 && byte <= 126 && byte != UInt8(ascii: "="))
          || ((byte == 0x20 || byte == 0x09) && !isLast)
        let leadingDot = index == 0 && byte == UInt8(ascii: ".")
        let chunk = isPlain && !leadingDot ? String(UnicodeScalar(byte)) : String(format: "=%02X", byte)
        if lineLength + chunk.count > 75 {
          encodedLine += "=\r\n"
          lineLength = 0
        }
        encodedLine += chunk
        lineLength += chunk.count
      }
      output.append(encodedLine)
    }
    return output.joined(separator: "\r\n")
  }

  static func encodeAddress(_ address: MailAddress) -> String {
    guard let name = address.name else { return address.email }
    if !name.allSatisfy(\.isASCII) {
      return "\(encodeHeaderText(name)) <\(address.email)>"
    }
    if name.contains(where: { "()<>[]:;@\\,.\"".contains($0) }) {
      let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
      return "\"\(escaped)\" <\(address.email)>"
    }
    return "\(name) <\(address.email)>"
  }

  /// Encodes unstructured header text as RFC 2047 words when it isn't plain ASCII.
  public static func encodeHeaderText(_ text: String) -> String {
    guard !text.allSatisfy(\.isASCII) else { return text }
    var words: [String] = []
    var chunk = ""
    for character in text {
      if chunk.utf8.count + String(character).utf8.count > 45 {
        words.append(chunk)
        chunk = ""
      }
      chunk.append(character)
    }
    if !chunk.isEmpty {
      words.append(chunk)
    }
    return words.map { "=?UTF-8?B?\(Data($0.utf8).base64EncodedString())?=" }.joined(separator: "\r\n ")
  }

  private static func filenameParameter(_ filename: String) -> String {
    if filename.allSatisfy(\.isASCII) {
      return "filename=\"\(filename.replacingOccurrences(of: "\"", with: ""))\""
    }
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
    var encoded = ""
    for byte in filename.utf8 {
      let scalar = UnicodeScalar(byte)
      if byte < 0x80, allowed.contains(scalar) {
        encoded.append(Character(scalar))
      } else {
        encoded += String(format: "%%%02X", byte)
      }
    }
    return "filename*=UTF-8''\(encoded)"
  }
}
