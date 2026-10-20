/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import ThunderbirdCore

struct ComposeDraft: Codable, Hashable, Identifiable {
  enum Kind: String, Codable {
    case new, reply, replyAll, forward, draft, template
  }

  var id = UUID()
  var kind: Kind = .new
  var accountID: UUID?
  var identityID: UUID?
  var to = ""
  var cc = ""
  var bcc = ""
  var newsgroups = ""
  var subject = ""
  var body = ""
  var htmlBody: String?
  var isHTML = false
  var inReplyTo: String?
  var references: [String] = []
  var attachments: [URL] = []
  /// The message being replied to or forwarded, so it can be flagged once this is sent.
  var source: MessageReference?
  /// The saved copy in Drafts this was opened from, removed once the message is sent.
  var savedDraft: MessageReference?
  var draftMessageID: String?
  var encrypt = false
  var sign = false
}

extension ComposeDraft {
  static func new(account: MailAccount?, to: String = "") -> ComposeDraft {
    var draft = ComposeDraft(accountID: account?.id, identityID: account?.id, to: to)
    draft.isHTML = account?.composeHTML ?? true
    draft.encrypt = account?.encryptByDefault ?? false
    draft.sign = account?.signByDefault ?? false
    draft.body = signatureBlock(account?.signature)
    draft.htmlBody = draft.isHTML ? "<p><br></p>" + htmlSignature(account?.signature) : nil
    if account?.kind == .nntp {
      draft.isHTML = false
      draft.htmlBody = nil
    }
    return draft
  }

  static func reply(
    to message: ParsedMessage, reference: MessageReference, account: MailAccount, all: Bool
  ) -> ComposeDraft {
    var draft = new(account: account)
    draft.kind = all ? .replyAll : .reply
    draft.source = reference
    if account.kind == .nntp, let groups = message.headers["Newsgroups"], !all {
      draft.newsgroups = groups
    } else {
      let replyTargets = message.replyTo.isEmpty ? message.from : message.replyTo
      var recipients = replyTargets
      var ccList: [MailAddress] = []
      let own = Set(account.identities.map { $0.email.lowercased() })
      if all {
        recipients += message.to.filter { !own.contains($0.email.lowercased()) }
        ccList = message.cc.filter { !own.contains($0.email.lowercased()) }
        if recipients.isEmpty {
          recipients = message.to
        }
      }
      draft.to = unique(recipients).map(\.formatted).joined(separator: ", ")
      draft.cc = unique(ccList).map(\.formatted).joined(separator: ", ")
      if let recipient = (message.to + message.cc).first(where: { own.contains($0.email.lowercased()) }),
        let identity = account.identities.first(where: { $0.email.lowercased() == recipient.email.lowercased() })
      {
        draft.identityID = identity.id
      }
    }
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
    draft.body = "\n\n\(attribution)\n\(quoted)\n" + signatureBlock(account.signature)
    if draft.isHTML {
      let original = message.htmlBody.map(sanitizedQuote) ?? "<pre>\(escape(message.plainText))</pre>"
      draft.htmlBody =
        "<p><br></p><p>\(escape(attribution))</p><blockquote type=\"cite\">\(original)</blockquote>"
        + htmlSignature(account.signature)
    }
    return draft
  }

  static func forward(
    _ message: ParsedMessage, reference: MessageReference, account: MailAccount, attachments: [URL]
  ) -> ComposeDraft {
    var draft = new(account: account)
    draft.kind = .forward
    draft.source = reference
    draft.subject = prefixed(message.subject, with: "Fwd:")
    draft.attachments = attachments
    var header = ["-------- Forwarded Message --------", "Subject: \(message.subject)"]
    if let date = message.date {
      header.append("Date: \(date.formatted(date: .abbreviated, time: .shortened))")
    }
    header.append("From: \(message.from.map(\.formatted).joined(separator: ", "))")
    header.append("To: \(message.to.map(\.formatted).joined(separator: ", "))")
    draft.body = "\n\n" + header.joined(separator: "\n") + "\n\n" + message.plainText + "\n" + signatureBlock(account.signature)
    if draft.isHTML {
      let original = message.htmlBody.map(sanitizedQuote) ?? "<pre>\(escape(message.plainText))</pre>"
      draft.htmlBody =
        "<p><br></p><div>" + header.map(escape).joined(separator: "<br>") + "</div><br>" + original
        + htmlSignature(account.signature)
    }
    return draft
  }

  /// Reopens a saved draft or a template.
  static func reopen(_ message: ParsedMessage, reference: MessageReference, account: MailAccount, asTemplate: Bool) -> ComposeDraft {
    var draft = ComposeDraft(kind: asTemplate ? .template : .draft, accountID: account.id, identityID: account.id)
    draft.to = message.to.map(\.formatted).joined(separator: ", ")
    draft.cc = message.cc.map(\.formatted).joined(separator: ", ")
    draft.bcc = MailAddress.parseList(message.headers["Bcc"] ?? "").map(\.formatted).joined(separator: ", ")
    draft.newsgroups = message.headers["Newsgroups"] ?? ""
    draft.subject = message.subject
    draft.body = message.plainText
    draft.htmlBody = message.htmlBody
    draft.isHTML = message.htmlBody != nil
    draft.inReplyTo = asTemplate ? nil : message.headers["In-Reply-To"]
    draft.references = asTemplate ? [] : message.references
    draft.attachments = message.attachments.compactMap { try? AttachmentFiles.temporaryURL(for: $0) }
    if !asTemplate {
      draft.savedDraft = reference
      draft.draftMessageID = message.messageID
    }
    if let sender = message.from.first,
      let identity = account.identities.first(where: { $0.email.lowercased() == sender.email.lowercased() })
    {
      draft.identityID = identity.id
    }
    return draft
  }

  private static func signatureBlock(_ signature: String?) -> String {
    guard let signature, !signature.isEmpty else { return "" }
    return "\n\n-- \n\(signature)"
  }

  private static func htmlSignature(_ signature: String?) -> String {
    guard let signature, !signature.isEmpty else { return "" }
    return "<p>-- <br>\(escape(signature).replacingOccurrences(of: "\n", with: "<br>"))</p>"
  }

  static func escape(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
  }

  /// Strips scripts, styles and remote images from HTML that is going to be quoted.
  static func sanitizedQuote(_ html: String) -> String {
    var result = html
    for pattern in [#"(?is)<(script|style|head|title)\b.*?</\1>"#, #"(?is)<img\b[^>]*\bsrc\s*=\s*["']?https?:[^>]*>"#, #"(?is)</?(html|body|meta|link)\b[^>]*>"#] {
      result = result.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }
    return result
  }

  private static func prefixed(_ subject: String, with prefix: String) -> String {
    subject.lowercased().hasPrefix(prefix.lowercased()) ? subject : "\(prefix) \(subject)"
  }

  private static func unique(_ addresses: [MailAddress]) -> [MailAddress] {
    var seen = Set<String>()
    return addresses.filter { seen.insert($0.email.lowercased()).inserted }
  }
}
