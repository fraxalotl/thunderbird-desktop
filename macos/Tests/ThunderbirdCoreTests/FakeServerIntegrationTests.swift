/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import Testing

@testable import ThunderbirdCore

/// Runs against Support/fake-mail-server.py. Start it, then run with TB_FAKE_SERVER=1.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TB_FAKE_SERVER"] == "1"), .serialized)
struct FakeServerIntegrationTests {
  let imap = ServerConfig(host: "127.0.0.1", port: 2143, security: .none, username: "fraser@example.com")
  let smtp = ServerConfig(host: "127.0.0.1", port: 2025, security: .none, username: "fraser@example.com")

  @Test func syncsReadsFlagsMovesAndSends() async throws {
    let client = IMAPClient(server: imap, password: "secret")
    try await client.connect()

    let folders = try await client.listFolders()
    let inbox = try #require(folders.first { $0.role == .inbox })
    #expect(folders.contains { $0.role == .trash && $0.path == "Trash" })
    #expect(folders.contains { $0.role == .sent })
    #expect((inbox.total ?? 0) >= 5)

    let mailbox = try await client.select("INBOX")
    let flags = try await client.fetchFlags(newest: 250, exists: mailbox.exists)
    #expect(flags.count == mailbox.exists)
    let summaries = try await client.fetchSummaries(uids: Array(flags.keys), in: "INBOX")
    #expect(summaries.count == flags.count)
    let report = try #require(summaries.first { $0.subject == "Quarterly report 📊" })
    #expect(report.from.first?.name == "Jörg Müller")
    #expect(report.hasAttachment)
    #expect(report.isFlagged)

    let parsed = ParsedMessage(data: try await client.fetchMessage(uid: report.uid, in: "INBOX"))
    #expect(parsed.attachments.first?.filename == "Q3 report.pdf")
    #expect(parsed.textBody?.contains("Grüße") == true)

    let welcome = try #require(summaries.first { $0.subject.hasPrefix("Welcome") })
    let welcomeParsed = ParsedMessage(data: try await client.fetchMessage(uid: welcome.uid, in: "INBOX"))
    #expect(welcomeParsed.htmlBody != nil)

    try await client.store(flags: [MessageFlag.seen], add: true, uids: [report.uid], in: "INBOX")
    let refreshed = try await client.fetchFlags(newest: 250, exists: mailbox.exists)
    #expect(refreshed[report.uid]?.contains(MessageFlag.seen) == true)

    let grace = try #require(summaries.first { $0.subject == "Compiler meetup" })
    try await client.move(uids: [grace.uid], from: "INBOX", to: "Archive")
    let archive = try await client.select("Archive")
    #expect(archive.exists >= 1)

    let outgoing = OutgoingMessage(
      from: MailAddress(name: "Fraser", email: "fraser@example.com"),
      to: [MailAddress(name: "Ada", email: "ada@analytical.example")],
      subject: "Integration test ✅",
      body: "Sent from the integration test.\n.dot line"
    )
    let data = try outgoing.render(messageID: "<it@example.com>")
    try await SMTPClient(server: smtp, password: "secret").send(
      data, from: "fraser@example.com", to: outgoing.allRecipients.map(\.email))
    try await client.append(data, to: "Sent", flags: [MessageFlag.seen])
    let sent = try await client.select("Sent")
    let sentFlags = try await client.fetchFlags(newest: 10, exists: sent.exists)
    let sentSummaries = try await client.fetchSummaries(uids: Array(sentFlags.keys), in: "Sent")
    #expect(sentSummaries.contains { $0.subject == "Integration test ✅" })

    await client.disconnect()
  }

  @Test func searchesManagesFoldersAndIdles() async throws {
    let client = IMAPClient(server: imap, password: "secret")
    try await client.connect()
    let hits = try await client.search(SearchQuery(text: "Thursday", field: .all), in: "INBOX")
    #expect(!hits.isEmpty)
    let unicodeHits = try await client.search(SearchQuery(text: "Grüße", field: .body), in: "INBOX")
    #expect(!unicodeHits.isEmpty)

    try await client.create("Receipts")
    try await client.rename("Receipts", to: "Bills")
    #expect(try await client.listFolders().contains { $0.path == "Bills" })
    try await client.delete(folder: "Bills")
    #expect(try await client.listFolders().contains { $0.path == "Bills" } == false)

    let idler = IMAPClient(server: imap, credential: .password("secret"), timeout: 30)
    try await idler.connect()
    async let changed = idler.idleUntilChange(in: "INBOX")
    try await Task.sleep(for: .milliseconds(300))
    let message = OutgoingMessage(
      from: MailAddress(email: "push@example.com"), to: [MailAddress(email: "fraser@example.com")],
      subject: "Pushed", body: "IDLE test")
    try await client.append(try message.render(messageID: "<idle@example.com>"), to: "INBOX", flags: [])
    #expect(try await changed)
    await idler.disconnect()
    await client.disconnect()
  }

  @Test func downloadsWithPOP3() async throws {
    let pop = POP3Client(
      server: ServerConfig(host: "127.0.0.1", port: 2110, security: .none, username: "fraser"), credential: .password("x"))
    try await pop.verify()
    var delivered: [Data] = []
    let seen = try await pop.download(skipping: [], deleteFromServer: false) { delivered.append($0) }
    #expect(delivered.count == seen.count)
    #expect(delivered.contains { ParsedMessage(data: $0).subject == "Quarterly report 📊" })
    var again: [Data] = []
    _ = try await pop.download(skipping: seen, deleteFromServer: false) { again.append($0) }
    #expect(again.isEmpty)
  }

  @Test func readsAndPostsNews() async throws {
    let news = NNTPClient(server: ServerConfig(host: "127.0.0.1", port: 2119, security: .none, username: ""), credential: nil)
    let groups = try await news.listGroups()
    #expect(groups.contains { $0.name == "local.thunderbird.test" })
    let info = try await news.group("local.thunderbird.test")
    let overview = try await news.overview(info.low...info.high)
    #expect(overview.contains { $0.subject == "Welcome to the newsgroup" })
    let reply = try #require(overview.first { $0.subject.hasPrefix("Re:") })
    #expect(ParsedMessage(data: try await news.article(reply.uid, in: "local.thunderbird.test")).textBody?.contains("Glad") == true)

    var post = OutgoingMessage(from: MailAddress(name: "Fraser", email: "fraser@example.com"), to: [], subject: "Hello news", body: "Posting from Swift.")
    post.newsgroups = ["local.thunderbird.test"]
    try await news.post(try post.render(messageID: "<news@example.com>"))
    let after = try await news.group("local.thunderbird.test")
    #expect(after.high == info.high + 1)
    await news.close()
  }

  @Test func rejectsMissingRecipients() async {
    await #expect(throws: MailError.self) {
      try await SMTPClient(server: smtp, password: "x").send(Data(), from: "a@b.c", to: [])
    }
  }
}
