/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import Testing

@testable import ThunderbirdCore

@Suite struct IMAPParsingTests {
  @Test func parsesFetchWithEnvelopeAndLiteral() throws {
    let header = "Content-Type: multipart/mixed; boundary=x\r\n\r\n"
    let raw =
      #"* 12 FETCH (UID 4827 FLAGS (\Seen \Flagged) INTERNALDATE "17-Jul-2026 02:44:25 -0700" RFC822.SIZE 4286 ENVELOPE ("Fri, 17 Jul 2026 09:44:25 +0000" "=?UTF-8?B?SGVsbG8g8J+Riw==?=" (("Ada Lovelace" NIL "ada" "example.org")) NIL NIL (("Bob" NIL "bob" "example.com")("Carol" NIL "carol" "example.com")) NIL NIL "<parent@example.org>" "<msg@example.org>") BODY[HEADER.FIELDS (CONTENT-TYPE)] {\#(header.utf8.count)}"#
      + "\r\n" + header + ")"
    let response = IMAPResponse(raw: Data(raw.utf8))
    #expect(response.keyword == "FETCH")
    let summary = try #require(IMAPClient.summary(from: IMAPClient.fetchAttributes(response)))
    #expect(summary.uid == 4827)
    #expect(summary.subject == "Hello 👋")
    #expect(summary.from == [MailAddress(name: "Ada Lovelace", email: "ada@example.org")])
    #expect(summary.to.map(\.email) == ["bob@example.com", "carol@example.com"])
    #expect(summary.isRead && summary.isFlagged)
    #expect(summary.hasAttachment)
    #expect(summary.inReplyTo == "<parent@example.org>")
    #expect(summary.size == 4286)
  }

  @Test func parsesListResponse() {
    let response = IMAPResponse(raw: Data(#"* LIST (\HasNoChildren \Sent) "/" "[Gmail]/Sent Mail""#.utf8))
    #expect(response.keyword == "LIST")
    #expect(response.values[2] == .list([.atom("\\HasNoChildren"), .atom("\\Sent")]))
    #expect(response.values[4].text == "[Gmail]/Sent Mail")
  }

  @Test func readsResponseCodes() {
    let response = IMAPResponse(raw: Data("* OK [UIDVALIDITY 3857529045] UIDs valid".utf8))
    #expect(response.responseCode("UIDVALIDITY") == "3857529045")
  }

  @Test func compressesSequenceSets() {
    #expect(IMAPClient.sequenceSet([5, 1, 2, 3, 9, 10, 7]) == "1:3,5,7,9:10")
  }

  @Test func detectsLiteralLengths() {
    #expect(IMAPClient.literalLength(Data("* 1 FETCH (BODY[] {342}".utf8)) == 342)
    #expect(IMAPClient.literalLength(Data("A1 APPEND x {12+}".utf8)) == 12)
    #expect(IMAPClient.literalLength(Data("* OK done".utf8)) == nil)
  }

  @Test func decodesModifiedUTF7() {
    #expect(ModifiedUTF7.decode("Entw&APw-rfe") == "Entwürfe")
    #expect(ModifiedUTF7.decode("Tom &- Jerry") == "Tom & Jerry")
    #expect(ModifiedUTF7.decode(ModifiedUTF7.encode("日本語/メール")) == "日本語/メール")
  }

  @Test func detectsFolderRoles() {
    #expect(RemoteFolder(path: "INBOX", delimiter: "/", attributes: []).role == .inbox)
    #expect(RemoteFolder(path: "[Gmail]/All Mail", delimiter: "/", attributes: ["\\all"]).role == .all)
    #expect(RemoteFolder(path: "INBOX.Sent Items", delimiter: ".", attributes: []).role == .sent)
    #expect(RemoteFolder(path: "Projects", delimiter: "/", attributes: []).role == .normal)
  }
}

@Suite struct MIMETests {
  @Test func decodesEncodedWords() {
    #expect(MIMEDecoder.decodeEncodedWords("=?ISO-8859-1?Q?Andr=E9?= Pirard") == "André Pirard")
    #expect(MIMEDecoder.decodeEncodedWords("=?UTF-8?Q?a?= =?UTF-8?Q?b?=") == "ab")
    #expect(MIMEDecoder.decodeEncodedWords("=?UTF-8?Q?Caf=C3=A9_au_lait?=") == "Café au lait")
    #expect(MIMEDecoder.decodeEncodedWords("plain =? text") == "plain =? text")
  }

  @Test func decodesQuotedPrintable() {
    let decoded = MIMEDecoder.quotedPrintable(Data("caf=C3=A9 soft=\r\nbreak".utf8))
    #expect(String(data: decoded, encoding: .utf8) == "café softbreak")
  }

  @Test func parsesAddressLists() {
    let list = MailAddress.parseList(#""Doe, Jane" <jane@example.com>, bob@example.com; Group: carol@example.com"#)
    #expect(list.map(\.email) == ["jane@example.com", "bob@example.com", "carol@example.com"])
    #expect(list.first?.name == "Doe, Jane")
    #expect(MailAddress.parseList("undisclosed-recipients:;").isEmpty)
  }

  @Test func parsesMultipartMessage() throws {
    let message = """
      From: =?UTF-8?Q?J=C3=B6rg?= <jorg@example.de>\r
      To: you@example.com\r
      Subject: Report\r
      Date: Tue, 20 Oct 2026 10:15:00 +0200\r
      Message-ID: <abc@example.de>\r
      Content-Type: multipart/mixed; boundary="outer"\r
      \r
      preamble\r
      --outer\r
      Content-Type: multipart/related; boundary="inner"\r
      \r
      --inner\r
      Content-Type: multipart/alternative; boundary="alt"\r
      \r
      --alt\r
      Content-Type: text/plain; charset=utf-8\r
      Content-Transfer-Encoding: quoted-printable\r
      \r
      Gr=C3=BC=C3=9Fe\r
      --alt\r
      Content-Type: text/html; charset=utf-8\r
      \r
      <p>Hi <img src="cid:logo@x"></p>\r
      --alt--\r
      --inner\r
      Content-Type: image/png\r
      Content-ID: <logo@x>\r
      Content-Transfer-Encoding: base64\r
      \r
      iVBORw0KGgo=\r
      --inner--\r
      --outer\r
      Content-Type: application/pdf; name="report.pdf"\r
      Content-Disposition: attachment; filename*=UTF-8''r%C3%A9sum%C3%A9.pdf\r
      Content-Transfer-Encoding: base64\r
      \r
      JVBERi0xLjQ=\r
      --outer--\r

      """
    let parsed = ParsedMessage(data: Data(message.utf8))
    #expect(parsed.subject == "Report")
    #expect(parsed.from.first?.name == "Jörg")
    #expect(parsed.textBody == "Grüße")
    let html = try #require(parsed.htmlBody)
    #expect(html.contains("data:image/png;base64,iVBORw0KGgo="))
    #expect(parsed.attachments.count == 1)
    #expect(parsed.attachments.first?.filename == "résumé.pdf")
    #expect(parsed.attachments.first?.data == Data("%PDF-1.4".utf8))
    #expect(parsed.messageID == "<abc@example.de>")
    #expect(parsed.date != nil)
  }

  @Test func derivesTextFromHTML() {
    let text = ParsedMessage.text(fromHTML: "<style>p{}</style><p>One &amp; two</p><div>Three<br>Four</div>")
    #expect(text == "One & two\nThree\nFour")
  }

  @Test func rendersAndReparsesOutgoingMessage() throws {
    let outgoing = OutgoingMessage(
      from: MailAddress(name: "Zoë Example", email: "zoe@example.com"),
      to: [MailAddress(name: "Smith, John", email: "john@example.com")],
      bcc: [MailAddress(email: "secret@example.com")],
      subject: "Café plans ☕️",
      body: "Hello\n.leading dot\nnaïve",
      inReplyTo: "<parent@example.com>",
      references: ["<parent@example.com>"],
      attachments: [OutgoingAttachment(filename: "notes.txt", mimeType: "text/plain", data: Data("notes".utf8))]
    )
    let data = outgoing.render(messageID: "<id@example.com>")
    let text = try #require(String(data: data, encoding: .utf8))
    #expect(!text.contains("secret@example.com"))
    #expect(!text.replacingOccurrences(of: "\r\n", with: "").contains("\n"))

    let parsed = ParsedMessage(data: data)
    #expect(parsed.subject == "Café plans ☕️")
    #expect(parsed.from.first?.name == "Zoë Example")
    #expect(parsed.to.first?.name == "Smith, John")
    #expect(parsed.textBody?.replacingOccurrences(of: "\r\n", with: "\n") == "Hello\n.leading dot\nnaïve")
    #expect(parsed.attachments.first?.filename == "notes.txt")
    #expect(parsed.references == ["<parent@example.com>"])
  }

  @Test func dotStuffsSMTPData() {
    let stuffed = SMTPClient.dotStuffed(Data("a\n.b\r\n..c".utf8))
    #expect(String(decoding: stuffed, as: UTF8.self) == "a\r\n..b\r\n...c\r\n")
  }

  @Test func parsesAutoconfigXML() throws {
    let xml = """
      <clientConfig version="1.1"><emailProvider id="example.com">
      <displayName>Example Mail</displayName>
      <incomingServer type="pop3"><hostname>pop.example.com</hostname><port>995</port><socketType>SSL</socketType></incomingServer>
      <incomingServer type="imap"><hostname>imap.example.com</hostname><port>993</port><socketType>SSL</socketType>
      <username>%EMAILLOCALPART%</username><authentication>password-cleartext</authentication></incomingServer>
      <outgoingServer type="smtp"><hostname>smtp.example.com</hostname><port>587</port><socketType>STARTTLS</socketType>
      <username>%EMAILADDRESS%</username><authentication>password-cleartext</authentication></outgoingServer>
      </emailProvider></clientConfig>
      """
    let config = try #require(Autoconfig.parse(Data(xml.utf8), email: "me@example.com", source: .ispdb))
    #expect(config.incoming == ServerConfig(host: "imap.example.com", port: 993, security: .tls, username: "me"))
    #expect(config.outgoing.security == .startTLS)
    #expect(config.outgoing.username == "me@example.com")
    #expect(config.providerName == "Example Mail")
    #expect(!config.requiresOAuth)
  }
}
