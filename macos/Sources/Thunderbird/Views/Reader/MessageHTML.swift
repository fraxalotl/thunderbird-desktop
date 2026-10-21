/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import ThunderbirdCore

/// Builds the document shown in the reader. Scripts are always disabled and remote loads are
/// blocked by a Content-Security-Policy unless the user allows remote content.
enum MessageHTML {
  struct Rendered: Equatable {
    var html: String
    var isPlainText: Bool
    var hasRemoteContent: Bool
  }

  static func render(
    _ message: ParsedMessage, allowRemote: Bool, mode: BodyMode = .original, inlineAttachments: Bool = false
  ) -> Rendered {
    var rendered = renderBody(message, allowRemote: allowRemote, mode: mode)
    var extra = ""
    if mode == .allParts {
      for attachment in message.attachments where attachment.mimeType.hasPrefix("text/") && attachment.mimeType != "text/calendar" {
        extra += "<hr><p style=\"color:gray\">\(escape(attachment.filename))</p><pre style=\"white-space:pre-wrap\">"
          + escape(MIMEDecoder.string(from: attachment.data, charset: nil)) + "</pre>"
      }
    }
    if inlineAttachments {
      for attachment in message.attachments where attachment.mimeType.hasPrefix("image/") && attachment.data.count < 15_000_000 {
        extra += "<hr><p style=\"color:gray;font:12px -apple-system\">\(escape(attachment.filename))</p>"
          + "<img style=\"max-width:100%\" src=\"data:\(attachment.mimeType);base64,\(attachment.data.base64EncodedString())\">"
      }
    }
    if !extra.isEmpty {
      rendered.html += rendered.isPlainText ? extra : "<div>\(extra)</div>"
    }
    return rendered
  }

  /// Simple HTML: Thunderbird's "View › Message Body As › Simple HTML" drops styling, scripts and
  /// remote resources while keeping structure.
  static func simplified(_ html: String) -> String {
    var output = html
    for pattern in [
      #"(?is)<(script|style|head|title|object|embed|iframe)\b.*?</\1>"#, #"(?is)<(link|meta|base)\b[^>]*>"#,
      #"(?i)\s(style|class|bgcolor|background|color|face|size|width|height)\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)"#,
      #"(?is)<img\b[^>]*\bsrc\s*=\s*["']?https?:[^>]*>"#,
    ] {
      output = output.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }
    return output
  }

  private static func renderBody(_ message: ParsedMessage, allowRemote: Bool, mode: BodyMode) -> Rendered {
    var message = message
    switch mode {
    case .plain:
      if message.textBody == nil { message.textBody = message.plainText }
      message.htmlBody = nil
    case .simple:
      message.htmlBody = message.htmlBody.map(simplified)
    case .original, .allParts:
      break
    }
    let policy =
      allowRemote
      ? "default-src 'none'; img-src * data:; style-src * 'unsafe-inline' data:; font-src * data:; media-src *"
      : "default-src 'none'; img-src data:; style-src 'unsafe-inline' data:; font-src data:"
    let meta = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\">"
    let viewport = "<meta name=\"viewport\" content=\"width=device-width\">"

    if let html = message.htmlBody {
      let style = """
        <style>
        :root { color-scheme: light; }
        html { background: #fff; }
        body { margin: 16px; font: 14px -apple-system, system-ui, sans-serif; color: #1d1d1f; word-wrap: break-word; }
        img { max-width: 100%; height: auto; }
        blockquote[type=cite] { margin: 0 0 0 4px; padding-left: 10px; border-left: 2px solid #3a7bd5; color: #3a7bd5; }
        </style>
        """
      return Rendered(
        html: meta + viewport + style + html,
        isPlainText: false,
        hasRemoteContent: containsRemoteReferences(html)
      )
    }

    let style = """
      <style>
      :root { color-scheme: light dark; }
      html, body { background: transparent; }
      body { margin: 20px; font: 14px -apple-system, system-ui, sans-serif; line-height: 1.45; white-space: pre-wrap; word-wrap: break-word; }
      a { color: -apple-system-control-accent; }
      blockquote { margin: 4px 0; padding-left: 10px; border-left: 2px solid; }
      blockquote.l1 { color: #3a7bd5; border-color: #3a7bd5; }
      blockquote.l2 { color: #2e9d57; border-color: #2e9d57; }
      blockquote.l3 { color: #a2462d; border-color: #a2462d; }
      .sig { color: gray; }
      </style>
      """
    return Rendered(
      html: meta + viewport + style + "<body>" + plainTextToHTML(message.textBody ?? "") + "</body>",
      isPlainText: true,
      hasRemoteContent: false
    )
  }

  static func containsRemoteReferences(_ html: String) -> Bool {
    let pattern =
      #"(?i)(\b(src|background|srcset|poster)\s*=\s*["']?\s*(https?:)?//)|(url\(\s*["']?\s*(https?:)?//)|(<link\b[^>]*\bhref\s*=\s*["']?\s*(https?:)?//)"#
    return html.range(of: pattern, options: .regularExpression) != nil
  }

  static func escape(_ text: String) -> String {
    text
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
  }

  private static func linkify(_ escaped: String) -> String {
    escaped.replacingOccurrences(
      of: #"(https?://[^\s<>"]+[^\s<>".,;:!?)\]'])"#,
      with: "<a href=\"$1\">$1</a>",
      options: .regularExpression
    )
  }

  /// Converts plain text to HTML, nesting `>` quoted lines and dimming the signature.
  static func plainTextToHTML(_ text: String) -> String {
    var output = ""
    var depth = 0
    var inSignature = false
    let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    for line in lines {
      var level = 0
      var content = Substring(line)
      while content.hasPrefix(">") {
        level += 1
        content = content.dropFirst()
        if content.hasPrefix(" ") {
          content = content.dropFirst()
        }
      }
      while depth < level {
        depth += 1
        output += "<blockquote class=\"l\((depth - 1) % 3 + 1)\">"
      }
      while depth > level {
        depth -= 1
        output += "</blockquote>"
      }
      if level == 0 && line == "-- " && !inSignature {
        inSignature = true
        output += "<span class=\"sig\">"
      }
      output += linkify(escape(String(content))) + "\n"
    }
    output += String(repeating: "</blockquote>", count: depth)
    if inSignature {
      output += "</span>"
    }
    return output
  }
}
