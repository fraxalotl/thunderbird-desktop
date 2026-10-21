/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation

/// Message disposition notifications (return receipts, RFC 8098).
public enum ReturnReceipt {
  /// The address a message asks receipts to be sent to, if any.
  public static func requestedAddress(in message: ParsedMessage) -> MailAddress? {
    message.headers["Disposition-Notification-To"].flatMap { MailAddress.parseList($0).first }
  }

  public static func report(for message: ParsedMessage, from sender: MailAddress, to recipient: MailAddress, messageID: String) -> Data {
    let boundary = OutgoingMessage.makeBoundary()
    let original = message.messageID ?? ""
    let lines = [
      "Date: \(MailDate.format(Date()))",
      "From: \(OutgoingMessage.encodeAddress(sender))",
      "To: \(OutgoingMessage.encodeAddress(recipient))",
      "Subject: \(OutgoingMessage.encodeHeaderText("Return Receipt (displayed) - \(message.subject)"))",
      "Message-ID: \(messageID)",
      "MIME-Version: 1.0",
      "Content-Type: multipart/report; report-type=disposition-notification; boundary=\"\(boundary)\"",
      "",
      "--\(boundary)",
      "Content-Type: text/plain; charset=UTF-8",
      "Content-Transfer-Encoding: 8bit",
      "",
      "This is a Return Receipt for the mail that you sent to \(sender.email).",
      "",
      "Note: This Return Receipt only acknowledges that the message was displayed on the recipient's computer. "
        + "There is no guarantee that the recipient has read or understood the message contents.",
      "--\(boundary)",
      "Content-Type: message/disposition-notification; name=\"MDNPart2.txt\"",
      "Content-Disposition: inline",
      "",
      "Reporting-UA: Thunderbird for macOS",
      "Final-Recipient: rfc822;\(sender.email)",
      "Original-Message-ID: \(original)",
      "Disposition: manual-action/MDN-sent-manually; displayed",
      "--\(boundary)--",
      "",
    ]
    return Data(lines.joined(separator: "\r\n").utf8)
  }
}

/// Thunderbird's scam (phishing) detection heuristics for HTML messages.
public enum ScamDetector {
  /// Returns a reason when a link's visible text names a different host than its target, or the
  /// target is a bare IP address.
  public static func suspiciousReason(inHTML html: String) -> String? {
    guard let regex = try? NSRegularExpression(
      pattern: #"<a\b[^>]*\bhref\s*=\s*["']([^"']+)["'][^>]*>(.*?)</a>"#, options: [.caseInsensitive, .dotMatchesLineSeparators])
    else { return nil }
    let range = NSRange(html.startIndex..., in: html)
    for match in regex.matches(in: html, range: range) {
      guard let hrefRange = Range(match.range(at: 1), in: html), let textRange = Range(match.range(at: 2), in: html),
        let target = URL(string: String(html[hrefRange])), let targetHost = target.host()?.lowercased(),
        ["http", "https"].contains(target.scheme?.lowercased())
      else { continue }
      if targetHost.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) != nil {
        return "A link goes to the numeric address \(targetHost) instead of a named website."
      }
      let text = String(html[textRange])
        .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard text.range(of: #"^(https?://)?[a-z0-9-]+(\.[a-z0-9-]+)+(/\S*)?$"#, options: [.regularExpression, .caseInsensitive]) != nil,
        let shown = URL(string: text.lowercased().hasPrefix("http") ? text : "https://\(text)")?.host()?.lowercased()
      else { continue }
      if !sameSite(shown, targetHost) {
        return "A link shows \(shown) but goes to \(targetHost)."
      }
    }
    return nil
  }

  static func sameSite(_ a: String, _ b: String) -> Bool {
    let first = Autoconfig.baseDomain(a)
    let second = Autoconfig.baseDomain(b)
    return first == second
  }
}
