/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import Testing

@testable import ThunderbirdCore

private func summary(
  _ uid: UInt32, _ subject: String, id: String, refs: [String] = [], hours: Double = 0, from: String = "a@example.com"
) -> MessageSummary {
  MessageSummary(
    uid: uid, subject: subject, from: [MailAddress(email: from)], to: [], cc: [],
    date: Date(timeIntervalSince1970: 1_000_000 + hours * 3600), size: 2048, flags: [], messageID: id,
    inReplyTo: refs.last, hasAttachment: false, references: refs)
}

@Suite struct ThreadingAndFilterTests {
  @Test func buildsThreadsFromReferences() {
    let messages = [
      summary(1, "Plan", id: "<a>", hours: 0),
      summary(2, "Re: Plan", id: "<b>", refs: ["<a>"], hours: 1),
      summary(3, "Re: Plan", id: "<c>", refs: ["<a>", "<b>"], hours: 2),
      summary(4, "Other", id: "<d>", hours: 3),
      summary(5, "Orphan reply", id: "<e>", refs: ["<missing>"], hours: 0.5),
    ]
    let threads = Threading.threads(messages) { $0 }
    #expect(threads.count == 3)
    #expect(threads.first?.root.uid == 4)
    let plan = threads.first { $0.root.uid == 1 }
    #expect(plan?.count == 3)
    #expect(plan?.flattened().map(\.uid) == [1, 2, 3])
  }

  @Test func appliesFiltersInOrderAndStops() {
    let message = summary(1, "Invoice 42", id: "<x>", from: "billing@shop.example")
    let filters = [
      MessageFilter(
        name: "Invoices", conditions: [FilterCondition(field: .subject, op: .beginsWith, value: "invoice")],
        actions: [FilterAction(kind: .moveTo, folderPath: "Bills"), FilterAction(kind: .stop)]),
      MessageFilter(
        name: "Shop", conditions: [FilterCondition(field: .from, op: .contains, value: "shop.example")],
        actions: [FilterAction(kind: .markRead)]),
    ]
    let actions = FilterStore.actions(for: message, filters: filters)
    #expect(actions.map(\.kind) == [.moveTo])
    #expect(actions.first?.folderPath == "Bills")
    var any = filters[1]
    any.matchAll = false
    any.conditions.append(FilterCondition(field: .size, op: .greaterThan, value: "100"))
    #expect(any.matches(message))
  }

  @Test func classifiesJunkAfterTraining() async {
    let url = FileManager.default.temporaryDirectory.appending(path: "junk-\(UUID().uuidString).json")
    let classifier = JunkClassifier(url: url)
    for index in 0..<6 {
      await classifier.train(subject: "Cheap pills \(index)", from: "spam@pills.example", body: "buy cheap pills viagra casino winner now", isJunk: true)
      await classifier.train(subject: "Meeting notes \(index)", from: "colleague@work.example", body: "agenda for the project meeting tomorrow", isJunk: false)
    }
    let junk = await classifier.junkProbability(subject: "Cheap pills", from: "x@pills.example", body: "casino winner cheap pills")
    let good = await classifier.junkProbability(subject: "Project meeting", from: "y@work.example", body: "agenda for tomorrow")
    #expect((junk ?? 0) > 0.9)
    #expect((good ?? 1) < 0.1)
  }

  @Test func searchQueryMatchesLocally() {
    let message = summary(1, "Quarterly report", id: "<r>", from: "joerg@example.de")
    #expect(SearchQuery(text: "quarterly", field: .subject).matches(message))
    #expect(SearchQuery(text: "joerg", field: .from).matches(message))
    #expect(!SearchQuery(text: "joerg", field: .subject).matches(message))
    #expect(SearchQuery(text: "budget", field: .body).matches(message, body: "the budget is attached"))
  }
}

@Suite struct CalendarAndChatTests {
  let invite = """
    BEGIN:VCALENDAR\r
    METHOD:REQUEST\r
    BEGIN:VEVENT\r
    UID:abc-123\r
    SEQUENCE:2\r
    DTSTART;TZID=Europe/London:20261103T100000\r
    DTEND;TZID=Europe/London:20261103T110000\r
    SUMMARY:Design review\\, round 2\r
    LOCATION:Room 4\r
    DESCRIPTION:Bring the\\nmockups\r
    ORGANIZER;CN=Ada Lovelace:mailto:ada@example.org\r
    ATTENDEE;CN=Fraser;PARTSTAT=NEEDS-ACTION:mailto:fraser@example.com\r
    RRULE:FREQ=WEEKLY;INTERVAL=2;COUNT=4\r
    END:VEVENT\r
    END:VCALENDAR\r

    """

  @Test func parsesInvitation() throws {
    let invitation = try #require(ICalendar.invitations(in: invite).first)
    #expect(invitation.method == "REQUEST")
    #expect(invitation.summary == "Design review, round 2")
    #expect(invitation.details == "Bring the\nmockups")
    #expect(invitation.end.timeIntervalSince(invitation.start) == 3600)
    #expect(invitation.organizer?.email == "ada@example.org")
    #expect(invitation.attendees.first?.status == "NEEDS-ACTION")
    #expect(invitation.recurrence == ICalRecurrence(frequency: "WEEKLY", interval: 2, count: 4, until: nil))
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/London")!
    #expect(calendar.component(.hour, from: invitation.start) == 10)
  }

  @Test func buildsReply() throws {
    let invitation = try #require(ICalendar.invitations(in: invite).first)
    let reply = ICalendar.reply(
      to: invitation, attendee: MailAddress(name: "Fraser", email: "fraser@example.com"), status: "ACCEPTED")
    #expect(reply.contains("METHOD:REPLY"))
    #expect(reply.contains("ATTENDEE;PARTSTAT=ACCEPTED;CN=\"Fraser\":mailto:fraser@example.com"))
    #expect(reply.contains("UID:abc-123"))
    #expect(reply.contains("DTSTART;TZID=Europe/London:20261103T100000"))
    let parsed = try #require(ICalendar.invitations(in: reply).first)
    #expect(parsed.attendees.first?.status == "ACCEPTED")
  }

  @Test func parsesIRCLines() {
    let line = IRCLine.parse(":nick!user@host PRIVMSG #thunderbird :hello there: friend")
    #expect(line?.nick == "nick")
    #expect(line?.command == "PRIVMSG")
    #expect(line?.params == ["#thunderbird", "hello there: friend"])
    #expect(IRCLine.parse("PING :irc.example.net")?.params == ["irc.example.net"])
    #expect(IRCLine.parse("@time=2026 :srv 001 me :Welcome")?.command == "001")
  }

  @Test func splitsXMPPStanzas() {
    var splitter = XMPPStanzaSplitter()
    var stanzas = splitter.append("<?xml version='1.0'?><stream:stream from='x' id='1'><stream:features><starttls/>")
    #expect(stanzas == ["<stream:stream from='x' id='1'>"])
    stanzas = splitter.append("</stream:features><message to='a' body='1>2'><body>hi <b/></body></mess")
    #expect(stanzas == ["<stream:features><starttls/></stream:features>"])
    stanzas = splitter.append("age><presence/>")
    #expect(stanzas == ["<message to='a' body='1>2'><body>hi <b/></body></message>", "<presence/>"])
  }
}

@Suite struct LocalStoreTests {
  @Test func storesMovesAndSearchesLocally() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "local-\(UUID().uuidString)")
    let backend = LocalBackend(accountID: UUID(), root: root, defaultFolders: LocalBackend.pop3Defaults)
    defer { try? FileManager.default.removeItem(at: root) }
    let message = OutgoingMessage(
      from: MailAddress(email: "a@example.com"), to: [MailAddress(email: "b@example.com")],
      subject: "Local test", body: "The secret word is pineapple.")
    try await backend.append(try message.render(messageID: "<local@example.com>"), to: "Inbox", flags: [])
    #expect(await backend.cachedMessages(in: "Inbox").first?.subject == "Local test")
    let found = try await backend.search(SearchQuery(text: "pineapple", field: .body), in: "Inbox", limit: 10)
    #expect(found.count == 1)
    let uid = try #require(found.first?.uid)
    try await backend.setFlags([MessageFlag.seen], on: true, uids: [uid], in: "Inbox")
    try await backend.move(uids: [uid], from: "Inbox", to: "Archives")
    #expect(await backend.cachedMessages(in: "Inbox").isEmpty)
    #expect(await backend.cachedMessages(in: "Archives").first?.isRead == true)
    let path = try await backend.createFolder("Receipts", parent: nil)
    try await backend.renameFolder(path, to: "Bills")
    #expect(await backend.cachedFolders().contains { $0.path == "Bills" })
    #expect(try await backend.findMessage(messageID: "<local@example.com>", in: "Archives").count == 1)
  }
}

@Suite struct TemplatePlaceholderTests {
  @Test func takesTheFirstName() {
    #expect(TemplatePlaceholders.firstName("Ben Hoenes") == "Ben")
    #expect(TemplatePlaceholders.firstName("Hoenes, Ben") == "Ben")
    #expect(TemplatePlaceholders.firstName("\"Ben\"") == "Ben")
    #expect(TemplatePlaceholders.firstName("ben@example.com") == "")
    #expect(TemplatePlaceholders.firstName("") == "")
  }

  @Test func fillsKnownPlaceholders() {
    let values = ["name": "Ben", "your name": "Fraser", "subject": ""]
    let text = "Hi {{Name}}, from {{ YOUR\n  name }} about {{Subject}} and {{Other}}"
    #expect(TemplatePlaceholders.fill(text, with: values) == "Hi Ben, from Fraser about {{Subject}} and {{Other}}")
  }

  @Test func listsUnfilledPlaceholdersOnce() {
    let texts = ["Re: {{Subject}}", "{{First line\n of your reply}} {{Subject}}"]
    #expect(TemplatePlaceholders.unfilled(in: texts) == ["{{Subject}}", "{{First line of your reply}}"])
  }
}

@Suite(.serialized) struct OpenPGPTests {
  static let available: Bool = {
    let candidates = [
      ProcessInfo.processInfo.environment["TB_LIBRNP"],
      "/Applications/Thunderbird.app/Contents/MacOS/librnp.dylib",
    ]
    return candidates.compactMap { $0 }.contains { FileManager.default.fileExists(atPath: $0) }
      && ProcessInfo.processInfo.environment["TB_OPENPGP_DIR"] != nil
  }()

  @Test(.enabled(if: OpenPGPTests.available))
  func signsEncryptsAndRoundTripsPGPMIME() throws {
    let pgp = OpenPGP.shared
    #expect(pgp.isAvailable)
    let alice = try pgp.generateKey(name: "Alice Test", email: "alice@example.com", passphrase: nil)
    let bob = try pgp.generateKey(name: "Bob Test", email: "bob@example.com", passphrase: nil)
    #expect(pgp.keys(for: "alice@example.com").contains { $0.fingerprint == alice.fingerprint })
    #expect(try pgp.exportPublicKey(bob.fingerprint).contains("BEGIN PGP PUBLIC KEY BLOCK"))

    var message = OutgoingMessage(
      from: MailAddress(name: "Alice", email: "alice@example.com"), to: [MailAddress(email: "bob@example.com")],
      subject: "Secret plans", body: "Meet at noon.\nBring snacks.")
    message.security = OutgoingSecurity(technology: .openPGP, sign: true, encrypt: true)
    message.protector = MessageSecurity()
    let encrypted = try message.render(messageID: "<enc@example.com>")
    #expect(String(decoding: encrypted, as: UTF8.self).contains("multipart/encrypted"))
    #expect(!String(decoding: encrypted, as: UTF8.self).contains("Bring snacks"))

    let (plain, status) = MessageSecurity.unprotect(encrypted)
    #expect(status?.encrypted == true)
    #expect(status?.signatures.first?.status == .good)
    #expect(ParsedMessage(data: plain).textBody?.contains("Bring snacks") == true)

    message.security = OutgoingSecurity(technology: .openPGP, sign: true, encrypt: false)
    let signed = try message.render(messageID: "<sig@example.com>")
    let (_, signedStatus) = MessageSecurity.unprotect(signed)
    #expect(signedStatus?.signatures.first?.status == .good)
    #expect(ParsedMessage(data: signed).attachments.isEmpty)

    let tampered = Data(String(decoding: signed, as: UTF8.self).replacingOccurrences(of: "noon", with: "dawn").utf8)
    #expect(MessageSecurity.unprotect(tampered).status?.signatures.first?.status != .good)

    try pgp.deleteKey(bob.fingerprint)
    #expect(pgp.keys(for: "bob@example.com").isEmpty)
  }
}

/// Network-dependent checks; run with TB_NETWORK_TESTS=1.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TB_NETWORK_TESTS"] == "1"))
struct NetworkTests {
  @Test func looksUpMailExchangers() async {
    #expect(!MXLookup.hosts(for: "proton.me").isEmpty)
    #expect(Autoconfig.baseDomain("aspmx.l.google.com") == "google.com")
    #expect(Autoconfig.baseDomain("mx1.example.co.uk") == "example.co.uk")
  }

  @Test func findsProvidersThroughMXRecords() async {
    let custom = await Autoconfig.discover(email: "someone@sulfur-mercury.com")
    #expect(custom.source == .mx)
    #expect(custom.incoming.host == "127.0.0.1")
    #expect(custom.note != nil)
    let workspace = await Autoconfig.discover(email: "someone@thunderbird.net")
    #expect(workspace.incoming.host == "imap.gmail.com")
    #expect(Autoconfig.nextSubDomain("aspmx.l.google.com", base: "google.com") == "l.google.com")
  }

  @Test func probesServersWhenNothingIsPublished() async throws {
    let config = try #require(await Autoconfig.probe(email: "someone@gmail.com", domain: "gmail.com"))
    #expect(config.incoming == ServerConfig(host: "imap.gmail.com", port: 993, security: .tls, username: "someone@gmail.com"))
    #expect(config.outgoing.host == "smtp.gmail.com")
  }

  @Test func detectsProtonHostedDomains() async {
    let config = await Autoconfig.discover(email: "someone@proton.me")
    #expect(config.incoming.host == "127.0.0.1")
    #expect(config.incoming.port == 1143)
    #expect(config.note != nil)
  }

  @Test func reportsUnknownHosts() async {
    let client = IMAPClient(
      server: ServerConfig(host: "imap.does-not-exist.invalid", port: 993, security: .tls, username: "x"), password: "x")
    await #expect(throws: MailError.self) { try await client.connect() }
  }
}

/// Talks to a running Proton Mail Bridge; run with TB_PROTON_BRIDGE=1.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TB_PROTON_BRIDGE"] == "1"))
struct ProtonBridgeTests {
  @Test func upgradesToTLSWithBridgeCertificate() async throws {
    let connection = LineConnection(host: "127.0.0.1", port: 1143, implicitTLS: false)
    #expect(String(decoding: try await connection.readLine(), as: UTF8.self).hasPrefix("* OK"))
    try await connection.write("A1 STARTTLS\r\n")
    #expect(String(decoding: try await connection.readLine(), as: UTF8.self).hasPrefix("A1 OK"))
    await connection.startTLS()
    try await connection.write("A2 CAPABILITY\r\n")
    let capabilities = String(decoding: try await connection.readLine(), as: UTF8.self)
    #expect(capabilities.contains("AUTH=PLAIN"))
    await connection.close()
  }
}
