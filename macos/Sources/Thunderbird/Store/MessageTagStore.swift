/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import Observation
import ThunderbirdCore

/// The user's message tags. Starts with Thunderbird's five defaults; new tags get keywords like
/// Thunderbird's (the name, lowercased, with unsafe characters removed).
@MainActor
@Observable
final class MessageTagStore {
  static let shared = MessageTagStore()
  private static let key = "messageTags"

  private struct Stored: Codable {
    var keyword: String
    var name: String
    var colorHex: String
  }

  private(set) var tags: [MessageTag]

  private init() {
    if let data = UserDefaults.standard.data(forKey: Self.key),
      let stored = try? JSONDecoder().decode([Stored].self, from: data)
    {
      tags = stored.map { MessageTag(keyword: $0.keyword, name: $0.name, colorHex: $0.colorHex) }
    } else {
      tags = MessageTag.defaults
    }
  }

  func tag(_ keyword: String) -> MessageTag? {
    tags.first { $0.keyword.caseInsensitiveCompare(keyword) == .orderedSame }
  }

  func tags(for summary: MessageSummary) -> [MessageTag] {
    tags.filter { tag in summary.flags.contains { $0.caseInsensitiveCompare(tag.keyword) == .orderedSame } }
  }

  @discardableResult
  func add(name: String, colorHex: String) -> MessageTag {
    var keyword = name.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    if keyword.isEmpty || keyword.hasPrefix("$") { keyword = "tag\(tags.count + 1)" }
    while tag(keyword) != nil { keyword += "_" }
    let tag = MessageTag(keyword: keyword, name: name, colorHex: colorHex)
    tags.append(tag)
    persist()
    return tag
  }

  func update(_ keyword: String, name: String, colorHex: String) {
    guard let index = tags.firstIndex(where: { $0.keyword == keyword }) else { return }
    tags[index].name = name
    tags[index].colorHex = colorHex
    persist()
  }

  func remove(_ keyword: String) {
    tags.removeAll { $0.keyword == keyword }
    persist()
  }

  func move(from source: IndexSet, to destination: Int) {
    tags.move(fromOffsets: source, toOffset: destination)
    persist()
  }

  private func persist() {
    let stored = tags.map { Stored(keyword: $0.keyword, name: $0.name, colorHex: $0.colorHex) }
    UserDefaults.standard.set(try? JSONEncoder().encode(stored), forKey: Self.key)
  }
}
