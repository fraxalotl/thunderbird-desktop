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
    let data = outgoing.render(messageID: "<it@example.com>")
    try await SMTPClient(server: smtp, password: "secret").send(
      data, from: "fraser@example.com", to: outgoing.allRecipients.map(\.email))
    try await client.append(data, to: "Sent", flags: [MessageFlag.seen])
    let sent = try await client.select("Sent")
    let sentFlags = try await client.fetchFlags(newest: 10, exists: sent.exists)
    let sentSummaries = try await client.fetchSummaries(uids: Array(sentFlags.keys), in: "Sent")
    #expect(sentSummaries.contains { $0.subject == "Integration test ✅" })

    await client.disconnect()
  }

  @Test func rejectsMissingRecipients() async {
    await #expect(throws: MailError.self) {
      try await SMTPClient(server: smtp, password: "x").send(Data(), from: "a@b.c", to: [])
    }
  }
}
