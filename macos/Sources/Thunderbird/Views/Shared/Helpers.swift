/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import AppKit
import SwiftUI
import ThunderbirdCore
import UniformTypeIdentifiers

enum AttachmentFiles {
  private static let directory = FileManager.default.temporaryDirectory.appending(
    path: "Thunderbird Attachments", directoryHint: .isDirectory)

  static func temporaryURL(for attachment: MessageAttachment) throws -> URL {
    let folder = directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let safeName = attachment.filename.replacingOccurrences(of: "/", with: "-")
    let url = folder.appending(path: safeName.isEmpty ? "attachment" : safeName)
    try attachment.data.write(to: url)
    return url
  }

  @MainActor
  static func open(_ attachment: MessageAttachment) {
    if let url = try? temporaryURL(for: attachment) {
      NSWorkspace.shared.open(url)
    }
  }

  /// Tools › Saved Files: attachments the user has saved.
  static var savedFiles: [URL] {
    (UserDefaults.standard.stringArray(forKey: "savedFiles") ?? []).map { URL(filePath: $0) }
  }

  static func recordSaved(_ url: URL) {
    var list = UserDefaults.standard.stringArray(forKey: "savedFiles") ?? []
    list.removeAll { $0 == url.path }
    list.insert(url.path, at: 0)
    UserDefaults.standard.set(Array(list.prefix(200)), forKey: "savedFiles")
  }

  @MainActor
  static func save(_ attachments: [MessageAttachment]) {
    if attachments.count == 1, let attachment = attachments.first {
      let panel = NSSavePanel()
      panel.nameFieldStringValue = attachment.filename
      if panel.runModal() == .OK, let url = panel.url {
        try? attachment.data.write(to: url)
        recordSaved(url)
      }
      return
    }
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = "Save Attachments"
    guard panel.runModal() == .OK, let folder = panel.url else { return }
    for attachment in attachments {
      let url = folder.appending(path: attachment.filename)
      try? attachment.data.write(to: url)
      recordSaved(url)
    }
  }

  static func symbol(for mimeType: String) -> String {
    let type = UTType(mimeType: mimeType)
    if type?.conforms(to: .image) == true { return "photo" }
    if type?.conforms(to: .pdf) == true { return "doc.richtext" }
    if type?.conforms(to: .audio) == true { return "waveform" }
    if type?.conforms(to: .movie) == true { return "film" }
    if type?.conforms(to: .archive) == true { return "doc.zipper" }
    if type?.conforms(to: .calendarEvent) == true || mimeType == "text/calendar" { return "calendar" }
    if mimeType == "message/rfc822" { return "envelope" }
    return "doc"
  }
}

extension Date {
  /// Thunderbird-style list date: time for today, weekday this week, otherwise a short date.
  var listFormatted: String {
    let calendar = Calendar.current
    if calendar.isDateInToday(self) {
      return formatted(date: .omitted, time: .shortened)
    }
    if calendar.isDateInYesterday(self) {
      return "Yesterday"
    }
    if let days = calendar.dateComponents([.day], from: self, to: .now).day, days < 7 {
      return formatted(.dateTime.weekday(.wide))
    }
    if calendar.isDate(self, equalTo: .now, toGranularity: .year) {
      return formatted(.dateTime.day().month(.abbreviated))
    }
    return formatted(date: .numeric, time: .omitted)
  }
}

struct AvatarView: View {
  let address: MailAddress?
  var size: CGFloat = 36
  var image: Data?

  private var initials: String {
    let source = address?.name ?? address?.email ?? "?"
    let words = source.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "@" }).prefix(2)
    return words.compactMap { $0.first.map { String($0).uppercased() } }.joined()
  }

  private var color: Color {
    let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green, .mint, .cyan, .brown]
    let hash = (address?.email ?? "").unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7FFF_FFFF }
    return palette[hash % palette.count]
  }

  var body: some View {
    if let image, let nsImage = NSImage(data: image) {
      Image(nsImage: nsImage)
        .resizable()
        .scaledToFill()
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    } else {
      initialsView
    }
  }

  private var initialsView: some View {
    Text(initials.isEmpty ? "?" : initials)
      .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
      .foregroundStyle(.white)
      .frame(width: size, height: size)
      .background(color.gradient, in: Circle())
      .accessibilityHidden(true)
  }
}

extension Int {
  var byteCountFormatted: String {
    ByteCountFormatter.string(fromByteCount: Int64(self), countStyle: .file)
  }
}
