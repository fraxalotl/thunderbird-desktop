/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import CryptoKit
import Foundation

public struct FeedItem: Sendable, Hashable {
  public var id: String
  public var title: String
  public var link: String?
  public var html: String
  public var author: String?
  public var date: Date?
}

public struct Feed: Sendable, Hashable {
  public var title: String
  public var link: String?
  public var items: [FeedItem]
}

public struct FeedSubscription: Codable, Sendable, Hashable, Identifiable {
  public var url: String
  public var title: String
  public var folder: String
  public var id: String { url }

  public init(url: String, title: String, folder: String) {
    self.url = url
    self.title = title
    self.folder = folder
  }
}

/// Parses RSS 2.0, RSS 1.0 (RDF) and Atom feeds, like Thunderbird's newsblog support.
public enum FeedParser {
  public static func parse(_ data: Data) -> Feed? {
    let delegate = FeedXMLDelegate()
    let parser = XMLParser(data: data)
    parser.shouldProcessNamespaces = false
    parser.delegate = delegate
    guard parser.parse(), delegate.sawFeed else { return nil }
    return Feed(title: delegate.feedTitle.isEmpty ? "Untitled Feed" : delegate.feedTitle, link: delegate.feedLink, items: delegate.items)
  }

  /// Finds a feed advertised by an HTML page (`<link rel="alternate" type="application/rss+xml">`).
  public static func discoverFeedURL(inHTML html: String, base: URL) -> URL? {
    let pattern = #"<link[^>]+type=["']application/(rss|atom)\+xml["'][^>]*>"#
    guard let range = html.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
    let tag = String(html[range])
    guard let hrefRange = tag.range(of: #"href=["']([^"']+)["']"#, options: .regularExpression) else { return nil }
    let href = tag[hrefRange].dropFirst(6).dropLast()
    return URL(string: String(href), relativeTo: base)?.absoluteURL
  }

  /// Turns a feed item into an RFC 5322 message, the way Thunderbird stores feed items.
  public static func message(for item: FeedItem, feed: Feed, subscription: FeedSubscription) -> Data {
    let digest = SHA256.hash(data: Data((subscription.url + item.id).utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    var lines = [
      "From: \(OutgoingMessage.encodeHeaderText(item.author ?? feed.title)) <feed@\(URL(string: subscription.url)?.host() ?? "feeds.local")>",
      "Subject: \(OutgoingMessage.encodeHeaderText(item.title))",
      "Date: \(MailDate.format(item.date ?? Date()))",
      "Message-ID: <\(digest)@feeds.thunderbird.local>",
      "MIME-Version: 1.0",
      "Content-Type: text/html; charset=UTF-8",
      "Content-Transfer-Encoding: 8bit",
    ]
    if let link = item.link {
      lines.insert("Content-Base: \(link)", at: 4)
    }
    let heading = item.link.map { "<h2><a href=\"\($0)\">\(escape(item.title))</a></h2>" } ?? "<h2>\(escape(item.title))</h2>"
    let body = "<html><body>\(heading)\(item.html)</body></html>"
    return Data((lines.joined(separator: "\r\n") + "\r\n\r\n" + body + "\r\n").utf8)
  }

  static func escape(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
  }

  static func date(_ text: String) -> Date? {
    if let date = MailDate.parse(text) { return date }
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = iso.date(from: text) { return date }
    iso.formatOptions = [.withInternetDateTime]
    return iso.date(from: text)
  }
}

private final class FeedXMLDelegate: NSObject, XMLParserDelegate {
  var sawFeed = false
  var feedTitle = ""
  var feedLink: String?
  var items: [FeedItem] = []

  private var stack: [String] = []
  private var text = ""
  private var current: [String: String]?
  private var currentLink: String?

  func parser(
    _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
    attributes: [String: String] = [:]
  ) {
    let name = elementName.lowercased()
    stack.append(name)
    text = ""
    switch name {
    case "rss", "feed", "rdf:rdf": sawFeed = true
    case "item", "entry":
      current = [:]
      currentLink = nil
    case "link":
      if let href = attributes["href"], attributes["rel"] == nil || attributes["rel"] == "alternate" {
        if current != nil { currentLink = currentLink ?? href } else { feedLink = feedLink ?? href }
      }
    default: break
    }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    text += string
  }

  func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
    text += String(decoding: CDATABlock, as: UTF8.self)
  }

  func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
    let name = elementName.lowercased()
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    defer {
      stack.removeLast()
      text = ""
    }
    if name == "item" || name == "entry", let fields = current {
      let link = currentLink ?? fields["link"]
      let html = fields["content:encoded"] ?? fields["content"] ?? fields["description"] ?? fields["summary"] ?? ""
      let id = fields["guid"] ?? fields["id"] ?? link ?? fields["title"] ?? UUID().uuidString
      items.append(
        FeedItem(
          id: id, title: fields["title"].map(MIMEDecoder.decodeHTMLEntities) ?? "(no title)", link: link, html: html,
          author: fields["dc:creator"] ?? fields["name"] ?? fields["author"],
          date: (fields["pubdate"] ?? fields["published"] ?? fields["updated"] ?? fields["dc:date"]).flatMap(FeedParser.date)))
      current = nil
      return
    }
    if current != nil {
      if current?[name] == nil && !value.isEmpty { current?[name] = value }
    } else if name == "title", feedTitle.isEmpty, stack.count <= 3 {
      feedTitle = value
    } else if name == "link", feedLink == nil, !value.isEmpty {
      feedLink = value
    }
  }
}

/// A Blogs & News Feeds account: subscriptions are fetched into local folders.
public actor FeedBackend: MailBackend {
  public nonisolated let accountID: UUID
  public nonisolated let capabilities = BackendCapabilities(
    canMoveAndDelete: true, canManageFolders: true, canAppend: true, canSearchServer: false)
  public let local: LocalBackend
  private var stateURL: URL { LocalBackend.storageRoot(for: accountID).appending(path: "feeds.json") }

  private struct State: Codable {
    var subscriptions: [FeedSubscription] = []
    var seen: [String: Set<String>] = [:]
  }

  public init(accountID: UUID) {
    self.accountID = accountID
    self.local = LocalBackend(
      accountID: accountID, root: LocalBackend.storageRoot(for: accountID), defaultFolders: [("Trash", .trash)])
  }

  private func loadState() -> State {
    (try? JSONDecoder().decode(State.self, from: Data(contentsOf: stateURL))) ?? State()
  }

  private func saveState(_ state: State) {
    try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
  }

  public var subscriptions: [FeedSubscription] { loadState().subscriptions }

  /// Fetches a feed URL (or finds the feed a web page links to) and subscribes to it.
  public func subscribe(to address: String) async throws -> FeedSubscription {
    guard var url = URL(string: address.contains("://") ? address : "https://\(address)") else {
      throw MailError.server("That isn't a valid address.")
    }
    var (data, _) = try await URLSession.shared.data(from: url)
    var feed = FeedParser.parse(data)
    if feed == nil, let discovered = FeedParser.discoverFeedURL(inHTML: String(decoding: data, as: UTF8.self), base: url) {
      url = discovered
      (data, _) = try await URLSession.shared.data(from: url)
      feed = FeedParser.parse(data)
    }
    guard let feed else { throw MailError.server("No feed was found at that address.") }
    let folder = try await local.createFolder(feed.title.replacingOccurrences(of: "/", with: "-"), parent: nil)
    let subscription = FeedSubscription(url: url.absoluteString, title: feed.title, folder: folder)
    var state = loadState()
    state.subscriptions.removeAll { $0.url == subscription.url }
    state.subscriptions.append(subscription)
    saveState(state)
    _ = try await fetch(subscription)
    return subscription
  }

  public func unsubscribe(_ url: String) {
    var state = loadState()
    state.subscriptions.removeAll { $0.url == url }
    state.seen[url] = nil
    saveState(state)
  }

  private func fetch(_ subscription: FeedSubscription) async throws -> [MessageSummary] {
    guard let url = URL(string: subscription.url) else { return [] }
    let (data, _) = try await URLSession.shared.data(from: url)
    guard let feed = FeedParser.parse(data) else { return [] }
    var state = loadState()
    var seen = state.seen[subscription.url] ?? []
    var delivered: [MessageSummary] = []
    for item in feed.items.reversed() where !seen.contains(item.id) {
      delivered.append(await local.deliver(FeedParser.message(for: item, feed: feed, subscription: subscription), to: subscription.folder, flags: []))
      seen.insert(item.id)
    }
    state.seen[subscription.url] = seen
    saveState(state)
    return delivered
  }

  public func cachedFolders() async -> [RemoteFolder] { await local.cachedFolders() }
  public func refreshFolders() async throws -> [RemoteFolder] { try await local.refreshFolders() }
  public func cachedMessages(in path: String) async -> [MessageSummary] { await local.cachedMessages(in: path) }

  public func sync(path: String, limit: Int) async throws -> SyncResult {
    var newMessages: [MessageSummary] = []
    for subscription in loadState().subscriptions where subscription.folder == path {
      newMessages += (try? await fetch(subscription)) ?? []
    }
    var result = try await local.sync(path: path, limit: limit)
    result.newMessages = newMessages
    return result
  }

  /// Checks every subscription; used by Get Messages for feed accounts.
  public func updateAll() async -> [MessageSummary] {
    var delivered: [MessageSummary] = []
    for subscription in loadState().subscriptions {
      delivered += (try? await fetch(subscription)) ?? []
    }
    return delivered
  }

  public func message(uid: UInt32, in path: String) async throws -> Data { try await local.message(uid: uid, in: path) }
  public func setFlags(_ flags: [String], on: Bool, uids: [UInt32], in path: String) async throws {
    try await local.setFlags(flags, on: on, uids: uids, in: path)
  }
  public func move(uids: [UInt32], from source: String, to destination: String) async throws -> [UInt32: UInt32] {
    try await local.move(uids: uids, from: source, to: destination)
  }
  public func copy(uids: [UInt32], from source: String, to destination: String) async throws -> [UInt32: UInt32] {
    try await local.copy(uids: uids, from: source, to: destination)
  }
  public func delete(uids: [UInt32], in path: String) async throws { try await local.delete(uids: uids, in: path) }
  public func emptyFolder(_ path: String) async throws { try await local.emptyFolder(path) }
  public func append(_ message: Data, to path: String, flags: [String]) async throws {
    try await local.append(message, to: path, flags: flags)
  }
  public func search(_ query: SearchQuery, in path: String, limit: Int) async throws -> [MessageSummary] {
    try await local.search(query, in: path, limit: limit)
  }
  public func findMessage(messageID: String, in path: String) async throws -> [UInt32] {
    try await local.findMessage(messageID: messageID, in: path)
  }
  public func createFolder(_ name: String, parent: String?) async throws -> String { try await local.createFolder(name, parent: parent) }
  public func renameFolder(_ path: String, to name: String) async throws { try await local.renameFolder(path, to: name) }
  public func deleteFolder(_ path: String) async throws {
    var state = loadState()
    state.subscriptions.removeAll { $0.folder == path }
    saveState(state)
    try await local.deleteFolder(path)
  }
  public func disconnect() async {}
}
