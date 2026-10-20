/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import ThunderbirdCore

struct ComposeDraft: Codable, Hashable, Identifiable {
  enum Kind: String, Codable {
    case new, reply, replyAll, forward
  }

  var id = UUID()
  var kind: Kind = .new
  var accountID: UUID?
  var to = ""
  var cc = ""
  var bcc = ""
  var subject = ""
  var body = ""
  var inReplyTo: String?
  var references: [String] = []
  var attachments: [URL] = []
  /// The message being replied to or forwarded, so it can be flagged once this is sent.
  var source: MessageReference?
}

struct MessageReference: Codable, Hashable {
  var accountID: UUID
  var path: String
  var uid: UInt32
}

extension ComposeDraft {
  static func new(account: MailAccount?, to: String = "") -> ComposeDraft {
    var draft = ComposeDraft(accountID: account?.id, to: to)
    draft.body = signatureBlock(account)
    return draft
  }

  static func reply(
    to message: ParsedMessage, reference: MessageReference, account: MailAccount, all: Bool
  ) -> ComposeDraft {
    var draft = ComposeDraft(kind: all ? .replyAll : .reply, accountID: account.id, source: reference)
    let replyTargets = message.replyTo.isEmpty ? message.from : message.replyTo
    var recipients = replyTargets
    var ccList: [MailAddress] = []
    if all {
      let own = account.email.lowercased()
      recipients += message.to.filter { $0.email.lowercased() != own }
      ccList = message.cc.filter { $0.email.lowercased() != own }
      if recipients.isEmpty {
        recipients = message.to
      }
    }
    draft.to = unique(recipients).map(\.formatted).joined(separator: ", ")
    draft.cc = unique(ccList).map(\.formatted).joined(separator: ", ")
    draft.subject = prefixed(message.subject, with: "Re:")
    draft.inReplyTo = message.messageID
    draft.references = message.references + (message.messageID.map { [$0] } ?? [])

    let author = message.from.first?.displayName ?? "Someone"
    let date = message.date.map { $0.formatted(date: .abbreviated, time: .shortened) }
    let attribution = date.map { "On \($0), \(author) wrote:" } ?? "\(author) wrote:"
    let quoted = message.plainText
      .components(separatedBy: .newlines)
      .map { $0.hasPrefix(">") ? ">\($0)" : "> \($0)" }
      .joined(separator: "\n")
    draft.body = "\n\n\(attribution)\n\(quoted)\n" + signatureBlock(account)
    return draft
  }

  static func forward(
    _ message: ParsedMessage, reference: MessageReference, account: MailAccount, attachments: [URL]
  ) -> ComposeDraft {
    var draft = ComposeDraft(kind: .forward, accountID: account.id, source: reference)
    draft.subject = prefixed(message.subject, with: "Fwd:")
    draft.attachments = attachments
    var header = ["-------- Forwarded Message --------", "Subject: \(message.subject)"]
    if let date = message.date {
      header.append("Date: \(date.formatted(date: .abbreviated, time: .shortened))")
    }
    header.append("From: \(message.from.map(\.formatted).joined(separator: ", "))")
    header.append("To: \(message.to.map(\.formatted).joined(separator: ", "))")
    draft.body = "\n\n" + header.joined(separator: "\n") + "\n\n" + message.plainText + "\n" + signatureBlock(account)
    return draft
  }

  private static func signatureBlock(_ account: MailAccount?) -> String {
    guard let signature = account?.signature, !signature.isEmpty else { return "" }
    return "\n\n-- \n\(signature)"
  }

  private static func prefixed(_ subject: String, with prefix: String) -> String {
    subject.lowercased().hasPrefix(prefix.lowercased()) ? subject : "\(prefix) \(subject)"
  }

  private static func unique(_ addresses: [MailAddress]) -> [MailAddress] {
    var seen = Set<String>()
    return addresses.filter { seen.insert($0.email.lowercased()).inserted }
  }
}
