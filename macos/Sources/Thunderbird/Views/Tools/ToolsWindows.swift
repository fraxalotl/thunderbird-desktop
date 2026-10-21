/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import AppKit
import SwiftUI
import ThunderbirdCore
import UniformTypeIdentifiers

/// Tools › Activity Manager.
struct ActivityManagerWindow: View {
  @Environment(MailStore.self) private var store

  var body: some View {
    VStack(spacing: 0) {
      List(store.activityLog) { entry in
        HStack {
          Image(systemName: "clock")
            .foregroundStyle(.secondary)
          Text(entry.text)
          Spacer()
          Text(entry.date.formatted(date: .omitted, time: .standard))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }
      .overlay {
        if store.activityLog.isEmpty {
          ContentUnavailableView("No Activity", systemImage: "clock", description: Text("Downloads, sends and other actions appear here."))
        }
      }
      HStack {
        if let current = store.activity {
          ProgressView().controlSize(.small)
          Text(current)
        }
        Spacer()
        Button("Clear List") { store.activityLog = [] }
          .buttonStyle(.glass)
      }
      .padding(10)
    }
  }
}

/// Tools › Saved Files.
struct SavedFilesWindow: View {
  @State private var files = AttachmentFiles.savedFiles

  var body: some View {
    List(files, id: \.self) { url in
      HStack {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
          .resizable()
          .frame(width: 24, height: 24)
        VStack(alignment: .leading) {
          Text(url.lastPathComponent)
          Text(url.deletingLastPathComponent().path)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
          .buttonStyle(.glass)
      }
      .opacity(FileManager.default.fileExists(atPath: url.path) ? 1 : 0.5)
      .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
    }
    .overlay {
      if files.isEmpty {
        ContentUnavailableView("No Saved Files", systemImage: "arrow.down.doc", description: Text("Attachments you save appear here."))
      }
    }
    .onAppear { files = AttachmentFiles.savedFiles }
  }
}

/// Help › Troubleshooting Information.
struct TroubleshootingWindow: View {
  @Environment(MailStore.self) private var store
  @Environment(ChatStore.self) private var chat

  private var report: String {
    let info = Bundle.main.infoDictionary ?? [:]
    var lines = [
      "Application: Zapdos \(info["CFBundleShortVersionString"] as? String ?? "") (\(info["CFBundleVersion"] as? String ?? ""))",
      "Bundle identifier: \(Bundle.main.bundleIdentifier ?? "")",
      "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
      "OpenPGP library: \(OpenPGP.shared.libraryPath ?? "not found") (\(OpenPGP.shared.isAvailable ? "available" : "unavailable"))",
      "OpenPGP keys: \(OpenPGP.shared.keys().count)",
      "Work offline: \(store.isOffline ? "yes" : "no")",
      "", "Accounts:",
    ]
    for account in store.mailAccounts {
      let folderCount = store.folders[account.id]?.count ?? 0
      lines.append(
        "  \(account.label) — \(account.kind.label), \(account.incoming.host):\(account.incoming.port) \(account.incoming.security.label), \(account.incoming.auth.label), \(folderCount) folders\(store.accountErrors[account.id].map { ", error: \($0)" } ?? "")")
    }
    lines.append("")
    lines.append("Chat accounts:")
    for account in chat.accounts {
      lines.append("  \(account.chatProtocol.label) \(account.title) — \(chat.status[account.id]?.label ?? "Offline")")
    }
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appending(path: "Thunderbird for macOS")
    lines.append("")
    lines.append("Data folder: \(support.path)")
    return lines.joined(separator: "\n")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ScrollView {
        Text(report)
          .font(.body.monospaced())
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(16)
      }
      HStack {
        Button("Copy to Clipboard") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(report, forType: .string)
        }
        Button("Open Data Folder") {
          let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Thunderbird for macOS")
          NSWorkspace.shared.open(support)
        }
        Spacer()
      }
      .buttonStyle(.glass)
      .padding([.horizontal, .bottom], 16)
    }
  }
}

/// Tools › Import… and Export…
struct ImportExportWindow: View {
  @Environment(MailStore.self) private var store
  @Environment(ContactsStore.self) private var contacts
  @Environment(CalendarStore.self) private var calendar
  @Environment(\.dismiss) private var dismiss
  let mode: String
  @State private var status: String?
  @State private var showingProfileImport = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(mode == "export" ? "Export" : "Import")
        .font(.title2.weight(.semibold))
      if mode == "export" {
        Text("Exports your accounts (without passwords), settings, filters, tags, local mail and caches as a zip file you can import on another Mac.")
          .foregroundStyle(.secondary)
        Button("Export to a Zip File…") { export() }
          .buttonStyle(.glassProminent)
      } else {
        importRow("Thunderbird profile", "Accounts and settings from Thunderbird for Windows, Mac or Linux.", symbol: "bird") {
          showingProfileImport = true
        }
        importRow("Mail", "Messages from mbox or .eml files into Local Folders.", symbol: "tray.and.arrow.down") { importMail() }
        importRow("Address book", "Contacts from vCard (.vcf) files.", symbol: "person.crop.rectangle.stack") { importContacts() }
        importRow("Calendar", "Events from iCalendar (.ics) files.", symbol: "calendar") { calendar.importCalendarFile() }
        importRow("Zapdos export", "A zip file made with Tools › Export.", symbol: "doc.zipper") { importExport() }
      }
      if let status {
        Text(status).foregroundStyle(.secondary)
      }
      Spacer()
    }
    .padding(24)
    .sheet(isPresented: $showingProfileImport) { AccountSetupView() }
  }

  private func importRow(_ title: String, _ detail: String, symbol: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 12) {
        Image(systemName: symbol).font(.title2).frame(width: 32)
        VStack(alignment: .leading, spacing: 2) {
          Text(title).font(.headline)
          Text(detail).font(.callout).foregroundStyle(.secondary)
        }
        Spacer()
        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
      }
      .padding(12)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))
  }

  private var supportFolder: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Thunderbird for macOS")
  }

  private func run(_ tool: String, _ arguments: [String]) -> Bool {
    let process = Process()
    process.executableURL = URL(filePath: tool)
    process.arguments = arguments
    guard (try? process.run()) != nil else { return false }
    process.waitUntilExit()
    return process.terminationStatus == 0
  }

  private func export() {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "Zapdos Export.zip"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let staging = FileManager.default.temporaryDirectory.appending(path: "tb-export-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    _ = run("/bin/cp", ["-R", supportFolder.path, staging.appending(path: "Data").path])
    _ = run("/usr/bin/defaults", ["export", "net.thunderbird.mac", staging.appending(path: "Preferences.plist").path])
    try? FileManager.default.removeItem(at: url)
    let ok = run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", staging.path, url.path])
    try? FileManager.default.removeItem(at: staging)
    status = ok ? "Exported to \(url.lastPathComponent)." : "The export failed."
  }

  private func importExport() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.zip]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let staging = FileManager.default.temporaryDirectory.appending(path: "tb-import-\(UUID().uuidString)")
    guard run("/usr/bin/ditto", ["-x", "-k", url.path, staging.path]) else {
      status = "That file couldn't be read."
      return
    }
    let data = staging.appending(path: "Data")
    if FileManager.default.fileExists(atPath: data.path) {
      try? FileManager.default.removeItem(at: supportFolder)
      try? FileManager.default.copyItem(at: data, to: supportFolder)
    }
    let preferences = staging.appending(path: "Preferences.plist")
    if FileManager.default.fileExists(atPath: preferences.path) {
      _ = run("/usr/bin/defaults", ["import", "net.thunderbird.mac", preferences.path])
    }
    status = "Imported. Quit and reopen Zapdos to finish. You'll be asked for account passwords."
  }

  private func importContacts() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.vCard]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task {
      if !contacts.isAuthorized { await contacts.requestAccess() }
      let count = (try? contacts.importVCards(from: url)) ?? 0
      status = "Imported \(count) contact\(count == 1 ? "" : "s")."
    }
  }

  /// Splits mbox files on "From " lines and stores each message (or .eml file) in Local Folders.
  private func importMail() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    guard panel.runModal() == .OK, let localID = store.localFoldersID,
      let local = store.backend(localID) as? LocalBackend
    else { return }
    let urls = panel.urls
    Task {
      var total = 0
      for url in urls {
        guard let data = try? Data(contentsOf: url) else { continue }
        let folderName = url.deletingPathExtension().lastPathComponent
        let path = (try? await local.createFolder(folderName, parent: nil)) ?? folderName
        let messages = url.pathExtension.lowercased() == "eml" ? [data] : MboxReader.split(data)
        for message in messages {
          await local.deliver(message, to: path, flags: [MessageFlag.seen])
          total += 1
        }
      }
      await store.refresh(accountID: localID)
      status = "Imported \(total) message\(total == 1 ? "" : "s") into Local Folders."
    }
  }
}

enum MboxReader {
  /// Splits an mbox file into messages, undoing ">From " quoting.
  static func split(_ data: Data) -> [Data] {
    let text = String(decoding: data, as: UTF8.self)
    var messages: [Data] = []
    var current: [Substring] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      if line.hasPrefix("From ") {
        if !current.isEmpty { messages.append(Data(current.joined(separator: "\r\n").utf8)) }
        current = []
        continue
      }
      current.append(line.hasPrefix(">From ") ? line.dropFirst() : line)
    }
    if current.contains(where: { !$0.isEmpty }) {
      messages.append(Data(current.joined(separator: "\r\n").utf8))
    }
    return messages.filter { !$0.isEmpty }
  }
}
