/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import Testing

@testable import ThunderbirdCore

@Suite struct ScamAndReceiptTests {
  @Test func flagsMismatchedLinkText() {
    let html = #"<p>Log in at <a href="https://evil.example.net/login">www.mybank.com</a></p>"#
    #expect(ScamDetector.suspiciousReason(inHTML: html) != nil)
  }

  @Test func flagsNumericHosts() {
    let html = #"<a href="http://192.168.4.20/pay">Pay now</a>"#
    #expect(ScamDetector.suspiciousReason(inHTML: html)?.contains("192.168.4.20") == true)
  }

  @Test func acceptsMatchingLinks() {
    let html = #"<a href="https://www.example.com/a">example.com</a> <a href="https://news.example.com">Read more</a>"#
    #expect(ScamDetector.suspiciousReason(inHTML: html) == nil)
  }

  @Test func buildsDispositionNotification() {
    let raw = Data(
      "From: Ann <ann@example.com>\r\nTo: me@example.org\r\nSubject: Hi\r\nMessage-ID: <m1@example.com>\r\nDisposition-Notification-To: ann@example.com\r\n\r\nHello\r\n".utf8)
    let parsed = ParsedMessage(data: raw)
    let requested = ReturnReceipt.requestedAddress(in: parsed)
    #expect(requested?.email == "ann@example.com")
    let report = String(decoding: ReturnReceipt.report(
      for: parsed, from: MailAddress(email: "me@example.org"), to: requested!, messageID: "<r1@example.org>"), as: UTF8.self)
    #expect(report.contains("report-type=disposition-notification"))
    #expect(report.contains("Original-Message-ID: <m1@example.com>"))
    #expect(report.contains("Disposition: manual-action/MDN-sent-manually; displayed"))
  }
}

@Suite struct AccountOptionsTests {
  @Test func decodesOlderAccountsWithDefaults() throws {
    let options = try JSONDecoder().decode(AccountOptions.self, from: Data(#"{"checkIntervalMinutes": 30}"#.utf8))
    #expect(options.checkIntervalMinutes == 30)
    #expect(options.checkAtStartup)
    #expect(options.deleteModel == .moveToTrash)
    #expect(options.receiptPolicy == .ask)
    #expect(options.popLeaveDays == nil)
  }

  @Test func roundTrips() throws {
    var options = AccountOptions()
    options.archiveGranularity = .monthly
    options.junkPurgeDays = 30
    options.organization = "Example Ltd"
    let decoded = try JSONDecoder().decode(AccountOptions.self, from: JSONEncoder().encode(options))
    #expect(decoded.archiveGranularity == .monthly)
    #expect(decoded.junkPurgeDays == 30)
    #expect(decoded.organization == "Example Ltd")
  }
}

@Suite struct FeedParserTests {
  @Test func parsesRSS() throws {
    let rss = """
      <?xml version="1.0"?><rss version="2.0"><channel><title>News</title><link>https://example.com</link>
      <item><title>First</title><link>https://example.com/1</link><guid>1</guid><description>Hello &amp; welcome</description></item>
      </channel></rss>
      """
    let feed = try #require(FeedParser.parse(Data(rss.utf8)))
    #expect(feed.title == "News")
    #expect(feed.items.count == 1)
    #expect(feed.items.first?.title == "First")
  }

  @Test func parsesAtom() throws {
    let atom = """
      <?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom"><title>Blog</title>
      <entry><title>Post</title><id>urn:1</id><link href="https://example.com/p"/><updated>2026-10-01T10:00:00Z</updated><content>Body</content></entry>
      </feed>
      """
    let feed = try #require(FeedParser.parse(Data(atom.utf8)))
    #expect(feed.title == "Blog")
    #expect(feed.items.first?.title == "Post")
  }

  @Test func discoversFeedLinks() {
    let html = #"<head><link rel="alternate" type="application/rss+xml" href="/feed.xml"></head>"#
    #expect(FeedParser.discoverFeedURL(inHTML: html, base: URL(string: "https://example.com/blog/")!)?.absoluteString == "https://example.com/feed.xml")
  }
}

@Suite struct LocalFoldersTests {
  @Test func topLevelSpecialFoldersGetTheirRole() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "tb-local-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let backend = LocalBackend(accountID: UUID(), root: root, defaultFolders: LocalBackend.localFoldersDefaults)
    _ = try await backend.createFolder("Templates", parent: nil)
    _ = try await backend.createFolder("Templates", parent: "Trash")
    let folders = try await backend.refreshFolders()
    #expect(folders.first { $0.path == "Templates" }?.role == .templates)
    #expect(folders.first { $0.path == "Trash/Templates" }?.role == .normal)
  }
}
