/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation

public struct FilterCondition: Codable, Sendable, Hashable, Identifiable {
  public enum Field: String, Codable, Sendable, CaseIterable {
    case subject, from, to, toOrCc, anyRecipient, size, hasAttachment, isFlagged

    public var label: String {
      switch self {
      case .subject: "Subject"
      case .from: "From"
      case .to: "To"
      case .toOrCc: "To or Cc"
      case .anyRecipient: "From, To or Cc"
      case .size: "Size (KB)"
      case .hasAttachment: "Has attachment"
      case .isFlagged: "Is starred"
      }
    }

    public var isBoolean: Bool { self == .hasAttachment || self == .isFlagged }
  }

  public enum Operator: String, Codable, Sendable, CaseIterable {
    case contains, doesNotContain, isEqual, beginsWith, endsWith, greaterThan, lessThan

    public var label: String {
      switch self {
      case .contains: "contains"
      case .doesNotContain: "doesn't contain"
      case .isEqual: "is"
      case .beginsWith: "begins with"
      case .endsWith: "ends with"
      case .greaterThan: "is greater than"
      case .lessThan: "is less than"
      }
    }
  }

  public var id = UUID()
  public var field: Field
  public var op: Operator
  public var value: String

  public init(field: Field, op: Operator, value: String) {
    self.field = field
    self.op = op
    self.value = value
  }

  func matches(_ message: MessageSummary) -> Bool {
    func text(_ candidate: String) -> Bool {
      let haystack = candidate.lowercased()
      let needle = value.lowercased()
      switch op {
      case .contains: return haystack.contains(needle)
      case .doesNotContain: return !haystack.contains(needle)
      case .isEqual: return haystack == needle
      case .beginsWith: return haystack.hasPrefix(needle)
      case .endsWith: return haystack.hasSuffix(needle)
      case .greaterThan, .lessThan: return false
      }
    }
    func addresses(_ list: [MailAddress]) -> Bool {
      let joined = list.map(\.formatted).joined(separator: ", ")
      if op == .doesNotContain { return text(joined) }
      return list.contains { text($0.email) || text($0.formatted) || ($0.name.map(text) ?? false) }
    }
    switch field {
    case .subject: return text(message.subject)
    case .from: return addresses(message.from)
    case .to: return addresses(message.to)
    case .toOrCc: return addresses(message.to + message.cc)
    case .anyRecipient: return addresses(message.from + message.to + message.cc)
    case .size:
      let kilobytes = message.size / 1024
      let limit = Int(value) ?? 0
      return op == .lessThan ? kilobytes < limit : kilobytes > limit
    case .hasAttachment: return message.hasAttachment == (value != "false")
    case .isFlagged: return message.isFlagged == (value != "false")
    }
  }
}

public struct FilterAction: Codable, Sendable, Hashable, Identifiable {
  public enum Kind: String, Codable, Sendable, CaseIterable {
    case moveTo, copyTo, markRead, star, addTag, markJunk, delete, stop

    public var label: String {
      switch self {
      case .moveTo: "Move message to"
      case .copyTo: "Copy message to"
      case .markRead: "Mark as read"
      case .star: "Add star"
      case .addTag: "Tag message"
      case .markJunk: "Mark as junk"
      case .delete: "Delete message"
      case .stop: "Stop filter execution"
      }
    }

    public var needsFolder: Bool { self == .moveTo || self == .copyTo }
  }

  public var id = UUID()
  public var kind: Kind
  public var folderPath: String?
  public var tag: String?

  public init(kind: Kind, folderPath: String? = nil, tag: String? = nil) {
    self.kind = kind
    self.folderPath = folderPath
    self.tag = tag
  }
}

public struct MessageFilter: Codable, Sendable, Hashable, Identifiable {
  public var id = UUID()
  public var name: String
  public var enabled = true
  public var matchAll = true
  public var conditions: [FilterCondition]
  public var actions: [FilterAction]

  public init(name: String, conditions: [FilterCondition], actions: [FilterAction]) {
    self.name = name
    self.conditions = conditions
    self.actions = actions
  }

  public func matches(_ message: MessageSummary) -> Bool {
    guard enabled, !conditions.isEmpty else { return false }
    return matchAll ? conditions.allSatisfy { $0.matches(message) } : conditions.contains { $0.matches(message) }
  }
}

public enum FilterStore {
  private static func key(_ accountID: UUID) -> String { "filters.\(accountID.uuidString)" }

  public static func filters(for accountID: UUID) -> [MessageFilter] {
    guard let data = UserDefaults.standard.data(forKey: key(accountID)) else { return [] }
    return (try? JSONDecoder().decode([MessageFilter].self, from: data)) ?? []
  }

  public static func save(_ filters: [MessageFilter], for accountID: UUID) {
    UserDefaults.standard.set(try? JSONEncoder().encode(filters), forKey: key(accountID))
  }

  /// The actions to apply to a message, in filter order, honouring "Stop filter execution".
  public static func actions(for message: MessageSummary, filters: [MessageFilter]) -> [FilterAction] {
    var result: [FilterAction] = []
    for filter in filters where filter.matches(message) {
      for action in filter.actions {
        if action.kind == .stop { return result }
        result.append(action)
      }
    }
    return result
  }
}

/// Thunderbird-style adaptive junk filter: a naive Bayes classifier trained by marking messages.
public actor JunkClassifier {
  public static let shared = JunkClassifier()

  private struct Model: Codable {
    var junkTokens: [String: Int] = [:]
    var goodTokens: [String: Int] = [:]
    var junkMessages = 0
    var goodMessages = 0
  }

  private var model: Model
  private let url: URL

  public init(url: URL? = nil) {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    self.url = url ?? support.appending(path: "Thunderbird for macOS/training.json")
    model = (try? JSONDecoder().decode(Model.self, from: Data(contentsOf: self.url))) ?? Model()
  }

  static func tokens(subject: String, from: String, body: String) -> Set<String> {
    var result = Set<String>()
    let text = "\(subject) \(body.prefix(20_000))".lowercased()
    for word in text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "$" && $0 != "'" }) {
      if (3...24).contains(word.count) { result.insert(String(word)) }
    }
    for word in subject.lowercased().split(separator: " ") where word.count >= 2 {
      result.insert("subject:\(word)")
    }
    if let domain = from.split(separator: "@").last {
      result.insert("from-domain:\(domain.lowercased())")
    }
    return result
  }

  /// Privacy & Security › Reset Training Data.
  public func reset() {
    model = Model()
    try? FileManager.default.removeItem(at: url)
  }

  public func train(subject: String, from: String, body: String, isJunk: Bool) {
    for token in Self.tokens(subject: subject, from: from, body: body) {
      if isJunk {
        model.junkTokens[token, default: 0] += 1
      } else {
        model.goodTokens[token, default: 0] += 1
      }
    }
    if isJunk { model.junkMessages += 1 } else { model.goodMessages += 1 }
    persist()
  }

  /// Probability that a message is junk, or nil until there is enough training data.
  public func junkProbability(subject: String, from: String, body: String) -> Double? {
    guard model.junkMessages >= 5, model.goodMessages >= 5 else { return nil }
    let junkTotal = Double(model.junkMessages)
    let goodTotal = Double(model.goodMessages)
    var probabilities: [Double] = []
    for token in Self.tokens(subject: subject, from: from, body: body) {
      let junk = Double(model.junkTokens[token] ?? 0)
      let good = Double(model.goodTokens[token] ?? 0)
      guard junk + good >= 2 else { continue }
      let junkRatio = min(1, junk / junkTotal)
      let goodRatio = min(1, 2 * good / goodTotal)
      let p = max(0.01, min(0.99, junkRatio / (junkRatio + goodRatio)))
      probabilities.append(p)
    }
    guard !probabilities.isEmpty else { return nil }
    let interesting = probabilities.sorted { abs($0 - 0.5) > abs($1 - 0.5) }.prefix(15)
    let logJunk = interesting.reduce(0) { $0 + log($1) }
    let logGood = interesting.reduce(0) { $0 + log(1 - $1) }
    return 1 / (1 + exp(logGood - logJunk))
  }

  private func persist() {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? JSONEncoder().encode(model).write(to: url, options: .atomic)
  }
}

/// A conversation thread for the message list.
public struct MessageThread<Item: Sendable>: Sendable {
  public var root: Item
  public var replies: [MessageThread<Item>]

  public var count: Int { 1 + replies.reduce(0) { $0 + $1.count } }

  public func flattened() -> [Item] {
    [root] + replies.flatMap { $0.flattened() }
  }
}

public enum Threading {
  /// Groups messages into threads using References and In-Reply-To. Threads are ordered by
  /// their newest message; replies are ordered by date.
  public static func threads<Item>(
    _ items: [Item], summary: (Item) -> MessageSummary
  ) -> [MessageThread<Item>] {
    var byMessageID: [String: Int] = [:]
    for (index, item) in items.enumerated() {
      if let id = summary(item).messageID { byMessageID[id] = index }
    }
    var parent = [Int?](repeating: nil, count: items.count)
    for (index, item) in items.enumerated() {
      let message = summary(item)
      let candidates = (message.references + [message.inReplyTo].compactMap { $0 }).reversed()
      if let parentIndex = candidates.lazy.compactMap({ byMessageID[$0] }).first(where: { $0 != index }) {
        parent[index] = parentIndex
      }
    }
    for index in parent.indices {
      var seen: Set<Int> = [index]
      var cursor = parent[index]
      while let current = cursor {
        if seen.contains(current) {
          parent[index] = nil
          break
        }
        seen.insert(current)
        cursor = parent[current]
      }
    }
    var children: [Int: [Int]] = [:]
    var roots: [Int] = []
    for index in items.indices {
      if let p = parent[index] { children[p, default: []].append(index) } else { roots.append(index) }
    }
    func build(_ index: Int) -> MessageThread<Item> {
      let replies = (children[index] ?? []).sorted { summary(items[$0]).date < summary(items[$1]).date }
      return MessageThread(root: items[index], replies: replies.map(build))
    }
    func newest(_ thread: MessageThread<Item>) -> Date {
      thread.flattened().map { summary($0).date }.max() ?? .distantPast
    }
    return roots.map(build).sorted { newest($0) > newest($1) }
  }
}
