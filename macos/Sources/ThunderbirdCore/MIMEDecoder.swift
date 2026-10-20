/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation

public enum MIMEDecoder {
  public static func string(from data: Data, charset: String?) -> String {
    if var charset = charset?.lowercased().trimmingCharacters(in: .whitespaces), !charset.isEmpty {
      if let star = charset.firstIndex(of: "*") {
        charset = String(charset[..<star])
      }
      if charset == "utf-8" || charset == "utf8" || charset == "us-ascii" {
        if let value = String(data: data, encoding: .utf8) { return value }
      } else {
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
        if cfEncoding != kCFStringEncodingInvalidId {
          let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
          if let value = String(data: data, encoding: encoding) { return value }
        }
      }
    }
    if let value = String(data: data, encoding: .utf8) { return value }
    return String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
  }

  public static func quotedPrintable(_ data: Data, inHeader: Bool = false) -> Data {
    let bytes = Array(data)
    var output = [UInt8]()
    output.reserveCapacity(bytes.count)
    var index = 0
    while index < bytes.count {
      let byte = bytes[index]
      if byte == UInt8(ascii: "=") {
        if index + 1 < bytes.count, bytes[index + 1] == 0x0A {
          index += 2
          continue
        }
        if index + 2 < bytes.count, bytes[index + 1] == 0x0D, bytes[index + 2] == 0x0A {
          index += 3
          continue
        }
        if index + 2 < bytes.count, let high = hexValue(bytes[index + 1]), let low = hexValue(bytes[index + 2]) {
          output.append(high << 4 | low)
          index += 3
          continue
        }
        output.append(byte)
      } else if inHeader && byte == UInt8(ascii: "_") {
        output.append(0x20)
      } else {
        output.append(byte)
      }
      index += 1
    }
    return Data(output)
  }

  private static func hexValue(_ byte: UInt8) -> UInt8? {
    switch byte {
    case 0x30...0x39: byte - 0x30
    case 0x41...0x46: byte - 0x41 + 10
    case 0x61...0x66: byte - 0x61 + 10
    default: nil
    }
  }

  public static func base64(_ data: Data) -> Data {
    Data(base64Encoded: data, options: .ignoreUnknownCharacters) ?? Data()
  }

  /// Decodes RFC 2047 encoded words, dropping whitespace between adjacent encoded words.
  public static func decodeEncodedWords(_ value: String) -> String {
    guard value.contains("=?") else { return value }
    var result = ""
    var pendingWhitespace = ""
    var lastWasEncoded = false
    var index = value.startIndex
    while index < value.endIndex {
      if value[index...].hasPrefix("=?"), let (decoded, end) = decodeEncodedWord(value, at: index) {
        if !lastWasEncoded {
          result += pendingWhitespace
        }
        pendingWhitespace = ""
        result += decoded
        lastWasEncoded = true
        index = end
        continue
      }
      let char = value[index]
      if char == " " || char == "\t" || char == "\r" || char == "\n" {
        if char == " " || char == "\t" {
          pendingWhitespace.append(char)
        }
      } else {
        result += pendingWhitespace
        pendingWhitespace = ""
        result.append(char)
        lastWasEncoded = false
      }
      index = value.index(after: index)
    }
    return result + pendingWhitespace
  }

  private static func decodeEncodedWord(_ value: String, at start: String.Index) -> (String, String.Index)? {
    let afterPrefix = value.index(start, offsetBy: 2)
    guard let charsetEnd = value[afterPrefix...].firstIndex(of: "?") else { return nil }
    let charset = String(value[afterPrefix..<charsetEnd])
    let encodingIndex = value.index(after: charsetEnd)
    guard encodingIndex < value.endIndex else { return nil }
    let encoding = value[encodingIndex].uppercased()
    let separator = value.index(after: encodingIndex)
    guard separator < value.endIndex, value[separator] == "?" else { return nil }
    let textStart = value.index(after: separator)
    guard let textEnd = value[textStart...].range(of: "?=") else { return nil }
    let text = Data(value[textStart..<textEnd.lowerBound].utf8)
    let bytes: Data
    switch encoding {
    case "B": bytes = base64(text)
    case "Q": bytes = quotedPrintable(text, inHeader: true)
    default: return nil
    }
    return (string(from: bytes, charset: charset), textEnd.upperBound)
  }

  /// Decodes common HTML entities, used when deriving plain text from HTML bodies.
  public static func decodeHTMLEntities(_ value: String) -> String {
    guard value.contains("&") else { return value }
    let named: [String: String] = [
      "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
      "mdash": "\u{2014}", "ndash": "\u{2013}", "hellip": "\u{2026}", "copy": "\u{00A9}",
      "rsquo": "\u{2019}", "lsquo": "\u{2018}", "rdquo": "\u{201D}", "ldquo": "\u{201C}",
    ]
    var result = ""
    var index = value.startIndex
    while index < value.endIndex {
      if value[index] == "&", let semicolon = value[index...].prefix(12).firstIndex(of: ";") {
        let entity = value[value.index(after: index)..<semicolon]
        var replacement: String?
        if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
          replacement = UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String($0) }
        } else if entity.hasPrefix("#") {
          replacement = UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init).map { String($0) }
        } else {
          replacement = named[entity.lowercased()]
        }
        if let replacement {
          result += replacement
          index = value.index(after: semicolon)
          continue
        }
      }
      result.append(value[index])
      index = value.index(after: index)
    }
    return result
  }
}

public enum MailDate {
  private static let formats = [
    "EEE, d MMM yyyy HH:mm:ss Z",
    "d MMM yyyy HH:mm:ss Z",
    "EEE, d MMM yyyy HH:mm Z",
    "d MMM yyyy HH:mm Z",
    "EEE, d MMM yy HH:mm:ss Z",
    "EEE, d MMM yyyy HH:mm:ss zzz",
    "d MMM yyyy HH:mm:ss zzz",
  ]

  public static func parse(_ value: String) -> Date? {
    var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if let paren = text.firstIndex(of: "(") {
      text = text[..<paren].trimmingCharacters(in: .whitespaces)
    }
    text = text.replacingOccurrences(of: "  ", with: " ")
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    for format in formats {
      formatter.dateFormat = format
      if let date = formatter.date(from: text) {
        return date
      }
    }
    return nil
  }

  public static func parseInternalDate(_ value: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "d-MMM-yyyy HH:mm:ss Z"
    return formatter.date(from: value.trimmingCharacters(in: .whitespaces))
  }

  public static func format(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
    return formatter.string(from: date)
  }
}
