/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation

/// Reply with Template placeholders such as {{Name}}. Inside the braces, case and whitespace
/// (including line breaks from the template's source) are ignored. The HTML editor has the same
/// rules in EditorScript.
public enum TemplatePlaceholders {
  public static let name = "name"
  public static let yourName = "your name"
  public static let subject = "subject"

  private static var pattern: Regex<(Substring, Substring)> { #/\{\{([^{}]+)\}\}/# }

  /// The first name from a display name, e.g. "Ben" from "Ben Hoenes" or "Hoenes, Ben", or an
  /// empty string for senders who use their address as the display name.
  public static func firstName(_ displayName: String) -> String {
    guard !displayName.contains("@") else { return "" }
    var name = Substring(displayName)
    if let comma = name.firstIndex(of: ",") {
      name = name[name.index(after: comma)...]
    }
    let first = name.split(whereSeparator: \.isWhitespace).first ?? ""
    return String(first).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
  }

  public static func normalizedKey(_ key: some StringProtocol) -> String {
    key.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
  }

  /// Replaces the placeholders that have a non-empty value, keyed by normalized key. Others are
  /// left as they are.
  public static func fill(_ text: String, with values: [String: String]) -> String {
    text.replacing(pattern) { match in
      let value = values[normalizedKey(match.output.1)] ?? ""
      return value.isEmpty ? String(match.output.0) : value
    }
  }

  /// The unique placeholders left in `texts`, with whitespace collapsed, in order of appearance.
  public static func unfilled(in texts: [String]) -> [String] {
    var found: [String] = []
    for text in texts {
      for match in text.matches(of: pattern) {
        let placeholder = match.output.0.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if !found.contains(placeholder) { found.append(placeholder) }
      }
    }
    return found
  }
}
