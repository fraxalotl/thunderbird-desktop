/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation

public struct HeaderField: Sendable, Hashable {
  public var name: String
  public var value: String

  public init(name: String, value: String) {
    self.name = name
    self.value = value
  }
}

public struct MIMEHeaders: Sendable {
  public var fields: [HeaderField] = []

  public subscript(name: String) -> String? {
    fields.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
  }

  public func decoded(_ name: String) -> String? {
    self[name].map(MIMEDecoder.decodeEncodedWords)
  }

  /// Splits a structured header such as Content-Type into its value and parameters,
  /// including RFC 2231 extended and continued parameters.
  public static func parameters(of value: String) -> (value: String, parameters: [String: String]) {
    var segments: [String] = []
    var current = ""
    var inQuotes = false
    for char in value {
      if char == "\"" {
        inQuotes.toggle()
      }
      if char == ";" && !inQuotes {
        segments.append(current)
        current = ""
      } else {
        current.append(char)
      }
    }
    segments.append(current)

    let main = segments.first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
    var plain: [String: String] = [:]
    var continued: [String: [(Int, String, Bool)]] = [:]
    for segment in segments.dropFirst() {
      guard let equals = segment.firstIndex(of: "=") else { continue }
      var key = segment[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
      var raw = segment[segment.index(after: equals)...].trimmingCharacters(in: .whitespaces)
      if raw.hasPrefix("\"") && raw.hasSuffix("\"") && raw.count >= 2 {
        raw = String(raw.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
      }
      let extended = key.hasSuffix("*")
      if extended {
        key.removeLast()
      }
      if let star = key.lastIndex(of: "*"), let part = Int(key[key.index(after: star)...]) {
        continued[String(key[..<star]), default: []].append((part, raw, extended))
      } else if extended {
        plain[key] = decodeExtendedValue(raw, first: true)
      } else {
        plain[key] = raw
      }
    }
    for (key, parts) in continued {
      let ordered = parts.sorted { $0.0 < $1.0 }
      var bytes = Data()
      var charset: String?
      for (index, part) in ordered.enumerated() {
        var text = part.1
        if part.2 && index == 0, let quote = text.firstIndex(of: "'"),
          let second = text[text.index(after: quote)...].firstIndex(of: "'")
        {
          charset = String(text[..<quote])
          text = String(text[text.index(after: second)...])
        }
        if part.2 {
          bytes.append(percentDecode(text))
        } else {
          bytes.append(Data(text.utf8))
        }
      }
      plain[key] = MIMEDecoder.string(from: bytes, charset: charset ?? "utf-8")
    }
    return (main, plain)
  }

  private static func decodeExtendedValue(_ value: String, first: Bool) -> String {
    let parts = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
    guard parts.count == 3 else {
      return MIMEDecoder.string(from: percentDecode(value), charset: "utf-8")
    }
    return MIMEDecoder.string(from: percentDecode(String(parts[2])), charset: String(parts[0]))
  }

  private static func percentDecode(_ value: String) -> Data {
    var bytes = [UInt8]()
    var iterator = Array(value.utf8).makeIterator()
    while let byte = iterator.next() {
      if byte == UInt8(ascii: "%"), let high = iterator.next(), let low = iterator.next(),
        let value = UInt8(String(decoding: [high, low], as: UTF8.self), radix: 16)
      {
        bytes.append(value)
      } else {
        bytes.append(byte)
      }
    }
    return Data(bytes)
  }
}

public struct MIMEPart: Sendable {
  public var headers: MIMEHeaders
  public var contentType: String
  public var parameters: [String: String]
  public var body: Data
  public var children: [MIMEPart]
  /// The part's exact source bytes (headers and body), needed to verify signatures.
  public var raw: Data = Data()

  public var isMultipart: Bool { contentType.hasPrefix("multipart/") }
  public var charset: String? { parameters["charset"] }

  public var disposition: (value: String, parameters: [String: String])? {
    headers["Content-Disposition"].map(MIMEHeaders.parameters)
  }

  public var filename: String? {
    let name = disposition?.parameters["filename"] ?? parameters["name"]
    return name.map(MIMEDecoder.decodeEncodedWords)
  }

  public var contentID: String? {
    headers["Content-ID"]?.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t"))
  }

  public var isAttachment: Bool {
    if ["application/pgp-signature", "application/pkcs7-signature", "application/x-pkcs7-signature",
      "application/pgp-encrypted"].contains(contentType)
    {
      return false
    }
    if disposition?.value == "attachment" {
      return true
    }
    if contentType == "message/rfc822" {
      return true
    }
    return filename != nil && !contentType.hasPrefix("text/") && contentID == nil
  }

  public var text: String {
    MIMEDecoder.string(from: body, charset: charset)
  }
}

public enum MIMEParser {
  public static func parse(_ data: Data) -> MIMEPart {
    parse(bytes: Array(data)[...], defaultType: "text/plain")
  }

  public static func parseHeaders(_ data: Data) -> MIMEHeaders {
    let bytes = Array(data)[...]
    let (headerEnd, _) = splitHeaders(bytes)
    return parseHeaderBlock(bytes[bytes.startIndex..<headerEnd])
  }

  private static func splitHeaders(_ bytes: ArraySlice<UInt8>) -> (headerEnd: Int, bodyStart: Int) {
    var index = bytes.startIndex
    if index < bytes.endIndex, bytes[index] == 0x0A {
      return (index, index + 1)
    }
    if index + 1 < bytes.endIndex, bytes[index] == 0x0D, bytes[index + 1] == 0x0A {
      return (index, index + 2)
    }
    while index < bytes.endIndex {
      if bytes[index] == 0x0A {
        let next = index + 1
        if next < bytes.endIndex, bytes[next] == 0x0A {
          return (index, next + 1)
        }
        if next + 1 < bytes.endIndex, bytes[next] == 0x0D, bytes[next + 1] == 0x0A {
          return (index, next + 2)
        }
      }
      index += 1
    }
    return (bytes.endIndex, bytes.endIndex)
  }

  private static func parseHeaderBlock(_ bytes: ArraySlice<UInt8>) -> MIMEHeaders {
    let text = String(data: Data(bytes), encoding: .utf8) ?? String(decoding: bytes, as: UTF8.self)
    var headers = MIMEHeaders()
    for line in text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
      let line = line.hasSuffix("\r") ? line.dropLast() : line
      if let first = line.first, first == " " || first == "\t" {
        if !headers.fields.isEmpty {
          headers.fields[headers.fields.count - 1].value += " " + line.trimmingCharacters(in: .whitespaces)
        }
      } else if let colon = line.firstIndex(of: ":") {
        headers.fields.append(
          HeaderField(
            name: line[..<colon].trimmingCharacters(in: .whitespaces),
            value: line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
          ))
      }
    }
    return headers
  }

  private static func parse(bytes: ArraySlice<UInt8>, defaultType: String) -> MIMEPart {
    let (headerEnd, bodyStart) = splitHeaders(bytes)
    let headers = parseHeaderBlock(bytes[bytes.startIndex..<headerEnd])
    let rawBody = bytes[min(bodyStart, bytes.endIndex)...]
    let (type, parameters) = headers["Content-Type"].map(MIMEHeaders.parameters) ?? (defaultType, [:])
    let contentType = type.isEmpty ? defaultType : type

    if contentType.hasPrefix("multipart/"), let boundary = parameters["boundary"], !boundary.isEmpty {
      let childDefault = contentType == "multipart/digest" ? "message/rfc822" : "text/plain"
      let children = splitMultipart(rawBody, boundary: boundary).map { parse(bytes: $0, defaultType: childDefault) }
      return MIMEPart(
        headers: headers, contentType: contentType, parameters: parameters, body: Data(), children: children,
        raw: Data(bytes))
    }

    let encoding = headers["Content-Transfer-Encoding"]?.lowercased().trimmingCharacters(in: .whitespaces)
    let body: Data
    switch encoding {
    case "base64": body = MIMEDecoder.base64(Data(rawBody))
    case "quoted-printable": body = MIMEDecoder.quotedPrintable(Data(rawBody))
    default: body = Data(rawBody)
    }
    return MIMEPart(
      headers: headers, contentType: contentType, parameters: parameters, body: body, children: [], raw: Data(bytes))
  }

  private static func splitMultipart(_ body: ArraySlice<UInt8>, boundary: String) -> [ArraySlice<UInt8>] {
    let delimiter = Array("--\(boundary)".utf8)
    var parts: [ArraySlice<UInt8>] = []
    var partStart: Int?
    var lineStart = body.startIndex
    while lineStart < body.endIndex {
      var lineEnd = lineStart
      while lineEnd < body.endIndex, body[lineEnd] != 0x0A {
        lineEnd += 1
      }
      let line = body[lineStart..<lineEnd]
      if line.starts(with: delimiter) {
        if let start = partStart {
          var end = lineStart
          if end > start, body[end - 1] == 0x0A { end -= 1 }
          if end > start, body[end - 1] == 0x0D { end -= 1 }
          parts.append(body[start..<max(start, end)])
        }
        let rest = line.dropFirst(delimiter.count)
        if rest.starts(with: Array("--".utf8)) {
          return parts
        }
        partStart = min(lineEnd + 1, body.endIndex)
      }
      lineStart = lineEnd + 1
    }
    if let start = partStart, start < body.endIndex {
      parts.append(body[start...])
    }
    return parts
  }
}

public struct MessageAttachment: Sendable, Identifiable, Hashable {
  public var id: Int
  public var filename: String
  public var mimeType: String
  public var data: Data

  public var size: Int { data.count }
}

/// A fully parsed message, ready to display.
public struct ParsedMessage: Sendable {
  public var headers: MIMEHeaders
  public var subject: String
  public var from: [MailAddress]
  public var to: [MailAddress]
  public var cc: [MailAddress]
  public var replyTo: [MailAddress]
  public var date: Date?
  public var messageID: String?
  public var references: [String]
  public var htmlBody: String?
  public var textBody: String?
  public var attachments: [MessageAttachment] = []

  public init(data: Data) {
    let root = MIMEParser.parse(data)
    headers = root.headers
    subject = headers.decoded("Subject") ?? ""
    from = MailAddress.parseList(headers["From"] ?? "")
    to = MailAddress.parseList(headers["To"] ?? "")
    cc = MailAddress.parseList(headers["Cc"] ?? "")
    replyTo = MailAddress.parseList(headers["Reply-To"] ?? "")
    date = headers["Date"].flatMap(MailDate.parse)
    messageID = headers["Message-ID"]?.trimmingCharacters(in: .whitespaces)
    references = (headers["References"] ?? "")
      .split(whereSeparator: { $0 == " " || $0 == "\t" })
      .map(String.init)
      .filter { $0.hasPrefix("<") }

    var inline: [String: MIMEPart] = [:]
    collect(root, inline: &inline)

    if var html = htmlBody, !inline.isEmpty {
      for (contentID, part) in inline {
        let dataURL = "data:\(part.contentType);base64,\(part.body.base64EncodedString())"
        html = html.replacingOccurrences(of: "cid:\(contentID)", with: dataURL)
      }
      htmlBody = html
    }
  }

  private mutating func collect(_ part: MIMEPart, inline: inout [String: MIMEPart]) {
    if part.isMultipart {
      for child in part.children {
        collect(child, inline: &inline)
      }
      return
    }
    if part.isAttachment {
      appendAttachment(part)
      return
    }
    switch part.contentType {
    case "text/html" where htmlBody == nil:
      htmlBody = part.text
    case "text/plain" where textBody == nil:
      textBody = part.text
    case "text/html", "text/plain":
      appendAttachment(part)
    case "application/pgp-signature", "application/pkcs7-signature", "application/x-pkcs7-signature",
      "application/pgp-encrypted":
      break
    default:
      if let contentID = part.contentID {
        inline[contentID] = part
      } else if !part.body.isEmpty {
        appendAttachment(part)
      }
    }
  }

  private mutating func appendAttachment(_ part: MIMEPart) {
    let fallbackName = part.contentType == "message/rfc822" ? "Attached Message.eml" : "Attachment \(attachments.count + 1)"
    attachments.append(
      MessageAttachment(
        id: attachments.count,
        filename: part.filename ?? fallbackName,
        mimeType: part.contentType,
        data: part.body
      ))
  }

  /// The body as plain text, deriving it from HTML when needed (used for replies and forwards).
  public var plainText: String {
    if let textBody { return textBody }
    guard let htmlBody else { return "" }
    return Self.text(fromHTML: htmlBody)
  }

  public static func text(fromHTML html: String) -> String {
    var text = html
    for pattern in [#"(?is)<(style|script|head)\b.*?</\1>"#, #"(?s)<!--.*?-->"#] {
      text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }
    text = text.replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
    text = text.replacingOccurrences(of: #"(?i)</(p|div|tr|li|h[1-6]|blockquote)>"#, with: "\n", options: .regularExpression)
    text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
    text = MIMEDecoder.decodeHTMLEntities(text)
    text = text.replacingOccurrences(of: "\u{00A0}", with: " ")
    text = text.replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
    text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
