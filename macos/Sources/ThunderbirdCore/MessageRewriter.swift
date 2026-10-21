/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation

/// Rebuilds a message with its attachments replaced, for Detach All / Delete All Attachments.
public enum MessageRewriter {
  /// `note` receives each attachment's filename and returns the text that replaces it.
  public static func replacingAttachments(in data: Data, note: (String) -> String) -> Data {
    let root = MIMEParser.parse(data)
    guard root.isMultipart else { return data }
    return rebuild(root, note: note)
  }

  private static func headerBlock(_ raw: Data) -> Data {
    if let range = raw.range(of: Data("\r\n\r\n".utf8)) {
      return raw[raw.startIndex..<range.lowerBound]
    }
    if let range = raw.range(of: Data("\n\n".utf8)) {
      return Data(String(decoding: raw[raw.startIndex..<range.lowerBound], as: UTF8.self)
        .replacingOccurrences(of: "\n", with: "\r\n").utf8)
    }
    return raw
  }

  private static func rebuild(_ part: MIMEPart, note: (String) -> String) -> Data {
    if !part.isMultipart {
      guard part.isAttachment else { return part.raw }
      let name = part.filename ?? "attachment"
      let text = note(name)
      var placeholder = "Content-Type: text/x-moz-deleted; name=\"Deleted: \(name)\"\r\n"
      placeholder += "Content-Transfer-Encoding: 8bit\r\nContent-Disposition: inline; filename=\"Deleted: \(name)\"\r\n"
      placeholder += "X-Mozilla-Altered: AttachmentDeleted; date=\"\(MailDate.format(Date()))\"\r\n\r\n\(text)\r\n"
      return Data(placeholder.utf8)
    }
    guard let boundary = part.parameters["boundary"] else { return part.raw }
    var output = headerBlock(part.raw)
    output.append(Data("\r\n\r\n".utf8))
    for child in part.children {
      output.append(Data("--\(boundary)\r\n".utf8))
      output.append(rebuild(child, note: note))
      output.append(crlf)
    }
    output.append(Data("--\(boundary)--\r\n".utf8))
    return output
  }

  /// Resent-* headers for Message › Redirect (RFC 5322 section 3.6.6).
  public static func redirecting(_ data: Data, from sender: MailAddress, to recipients: [MailAddress], messageID: String) -> Data {
    var headers = "Resent-From: \(OutgoingMessage.encodeAddress(sender))\r\n"
    headers += "Resent-To: \(recipients.map(OutgoingMessage.encodeAddress).joined(separator: ", "))\r\n"
    headers += "Resent-Date: \(MailDate.format(Date()))\r\n"
    headers += "Resent-Message-ID: \(messageID)\r\n"
    var output = Data(headers.utf8)
    output.append(data)
    return output
  }
}
