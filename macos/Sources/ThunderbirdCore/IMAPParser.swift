/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation

public indirect enum IMAPValue: Sendable, Equatable {
  case atom(String)
  case string(Data)
  case list([IMAPValue])
  case null

  public var text: String? {
    switch self {
    case .atom(let value): value
    case .string(let data): String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    default: nil
    }
  }

  public var data: Data? {
    switch self {
    case .string(let data): data
    case .atom(let value): Data(value.utf8)
    default: nil
    }
  }

  public var items: [IMAPValue]? {
    if case .list(let values) = self { return values }
    return nil
  }
}

struct IMAPParseError: Error {}

/// Parses a complete IMAP response (including any inline literals) into a token tree.
struct IMAPParser {
  private let bytes: [UInt8]
  private var position = 0

  init(_ data: Data) {
    bytes = Array(data)
  }

  static func parse(_ data: Data) throws -> [IMAPValue] {
    var parser = IMAPParser(data)
    return try parser.parseValues(until: nil)
  }

  private mutating func skipSpaces() {
    while position < bytes.count, bytes[position] == 0x20 || bytes[position] == 0x0D || bytes[position] == 0x0A {
      position += 1
    }
  }

  private mutating func parseValues(until terminator: UInt8?) throws -> [IMAPValue] {
    var values: [IMAPValue] = []
    while true {
      skipSpaces()
      guard position < bytes.count else {
        if terminator != nil { throw IMAPParseError() }
        return values
      }
      if let terminator, bytes[position] == terminator {
        position += 1
        return values
      }
      values.append(try parseValue())
    }
  }

  private mutating func parseValue() throws -> IMAPValue {
    switch bytes[position] {
    case UInt8(ascii: "("):
      position += 1
      return .list(try parseValues(until: UInt8(ascii: ")")))
    case UInt8(ascii: "\""):
      return .string(try parseQuoted())
    case UInt8(ascii: "{"):
      if let literal = try parseLiteral() {
        return .string(literal)
      }
      return .atom(parseAtom())
    default:
      let atom = parseAtom()
      return atom.uppercased() == "NIL" ? .null : .atom(atom)
    }
  }

  private mutating func parseQuoted() throws -> Data {
    position += 1
    var result = [UInt8]()
    while position < bytes.count {
      let byte = bytes[position]
      position += 1
      if byte == UInt8(ascii: "\\"), position < bytes.count {
        result.append(bytes[position])
        position += 1
      } else if byte == UInt8(ascii: "\"") {
        return Data(result)
      } else {
        result.append(byte)
      }
    }
    throw IMAPParseError()
  }

  private mutating func parseLiteral() throws -> Data? {
    var cursor = position + 1
    var length = 0
    var digits = 0
    while cursor < bytes.count, bytes[cursor] >= 0x30, bytes[cursor] <= 0x39 {
      length = length * 10 + Int(bytes[cursor] - 0x30)
      cursor += 1
      digits += 1
    }
    if cursor < bytes.count, bytes[cursor] == UInt8(ascii: "+") {
      cursor += 1
    }
    guard digits > 0, cursor < bytes.count, bytes[cursor] == UInt8(ascii: "}") else {
      return nil
    }
    cursor += 1
    if cursor + 1 < bytes.count, bytes[cursor] == 0x0D, bytes[cursor + 1] == 0x0A {
      cursor += 2
    }
    guard cursor + length <= bytes.count else { throw IMAPParseError() }
    position = cursor + length
    return Data(bytes[cursor..<cursor + length])
  }

  private mutating func parseAtom() -> String {
    let start = position
    var bracketDepth = 0
    while position < bytes.count {
      let byte = bytes[position]
      if byte == UInt8(ascii: "[") {
        bracketDepth += 1
      } else if byte == UInt8(ascii: "]") {
        bracketDepth = max(0, bracketDepth - 1)
      } else if bracketDepth == 0,
        byte == 0x20 || byte == UInt8(ascii: "(") || byte == UInt8(ascii: ")") || byte == 0x0D || byte == 0x0A
      {
        break
      }
      position += 1
    }
    if position == start {
      position += 1
    }
    return String(decoding: bytes[start..<position], as: UTF8.self)
  }
}

public struct IMAPResponse: Sendable {
  public let raw: Data
  public let values: [IMAPValue]

  init(raw: Data) {
    self.raw = raw
    values = (try? IMAPParser.parse(raw)) ?? []
  }

  public var line: String {
    let end = raw.firstRange(of: crlf)?.lowerBound ?? raw.endIndex
    return String(decoding: raw[raw.startIndex..<end], as: UTF8.self)
  }

  /// The keyword of an untagged response, e.g. `EXISTS` for `* 3 EXISTS` or `LIST` for `* LIST ...`.
  public var keyword: String? {
    guard values.count >= 2 else { return nil }
    if case .atom(let second) = values[1], Int(second) != nil, values.count >= 3, case .atom(let third) = values[2] {
      return third.uppercased()
    }
    return values[1].text?.uppercased()
  }

  public var number: Int? {
    guard values.count >= 2, case .atom(let value) = values[1] else { return nil }
    return Int(value)
  }

  /// The value of a response code such as `[UIDVALIDITY 1234]`.
  public func responseCode(_ name: String) -> String? {
    let text = line
    guard let range = text.range(of: "[\(name) ", options: .caseInsensitive) else { return nil }
    let rest = text[range.upperBound...]
    guard let end = rest.firstIndex(of: "]") else { return nil }
    return String(rest[..<end])
  }
}

/// RFC 3501 modified UTF-7, used for mailbox names.
public enum ModifiedUTF7 {
  public static func decode(_ name: String) -> String {
    guard name.contains("&") else { return name }
    var result = ""
    var index = name.startIndex
    while index < name.endIndex {
      let char = name[index]
      guard char == "&" else {
        result.append(char)
        index = name.index(after: index)
        continue
      }
      guard let end = name[index...].firstIndex(of: "-") else {
        result += name[index...]
        break
      }
      let encoded = name[name.index(after: index)..<end]
      if encoded.isEmpty {
        result.append("&")
      } else {
        var base64 = encoded.replacingOccurrences(of: ",", with: "/")
        while base64.count % 4 != 0 {
          base64.append("=")
        }
        if let data = Data(base64Encoded: base64), let decoded = String(data: data, encoding: .utf16BigEndian) {
          result += decoded
        } else {
          result += name[index...end]
        }
      }
      index = name.index(after: end)
    }
    return result
  }

  public static func encode(_ name: String) -> String {
    var result = ""
    var pending: [UInt16] = []
    func flush() {
      guard !pending.isEmpty else { return }
      let data = Data(pending.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] })
      let base64 = data.base64EncodedString()
        .replacingOccurrences(of: "/", with: ",")
        .trimmingCharacters(in: CharacterSet(charactersIn: "="))
      result += "&\(base64)-"
      pending.removeAll()
    }
    for scalar in name.unicodeScalars {
      if scalar.value >= 0x20 && scalar.value <= 0x7E {
        flush()
        result += scalar == "&" ? "&-" : String(scalar)
      } else {
        pending.append(contentsOf: String(scalar).utf16)
      }
    }
    flush()
    return result
  }
}
