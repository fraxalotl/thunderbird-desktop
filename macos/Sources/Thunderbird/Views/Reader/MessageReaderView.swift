/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import AppKit
import Observation
import SwiftUI
import ThunderbirdCore
import WebKit

/// Gives menu commands access to the reader's web view for printing.
@MainActor
@Observable
final class ReaderController {
  @ObservationIgnored weak var webView: WKWebView? {
    didSet { webView?.pageZoom = zoom }
  }
  var zoom = UserDefaults.standard.object(forKey: MailPreferences.messageZoom) as? Double ?? 1 {
    didSet {
      UserDefaults.standard.set(zoom, forKey: MailPreferences.messageZoom)
      webView?.pageZoom = zoom
    }
  }
  var lastFindFound = true

  func zoom(by delta: Double) {
    zoom = min(3, max(0.5, zoom + delta))
  }

  func resetZoom() {
    zoom = 1
  }

  /// Edit › Find › Find in This Message.
  func find(_ text: String, backwards: Bool) {
    guard let webView, !text.isEmpty else { return }
    let configuration = WKFindConfiguration()
    configuration.backwards = backwards
    configuration.wraps = true
    Task { @MainActor in
      let result = try? await webView.find(text, configuration: configuration)
      lastFindFound = result?.matchFound ?? false
    }
  }

  func print() {
    guard let webView, let window = webView.window else { return }
    let operation = webView.printOperation(with: .shared)
    operation.view?.frame = webView.bounds
    operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
  }
}

struct MessageReaderView: View {
  @Environment(MailStore.self) private var store

  var body: some View {
    switch store.reader {
    case .empty:
      MailStartPage()
    case .multiple(let count):
      ContentUnavailableView(
        "\(count) Messages Selected", systemImage: "envelope.stack",
        description: Text("Use the toolbar to archive, delete or tag them all at once."))
    case .loading:
      ProgressView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .failed(let message):
      ContentUnavailableView("Couldn't Load Message", systemImage: "exclamationmark.triangle", description: Text(message))
    case .loaded(let message):
      LoadedMessageView(message: message, isStandalone: false)
        .id(message.reference)
    }
  }
}

struct MessageWindow: View {
  @Environment(MailStore.self) private var store
  let reference: MessageReference
  @State private var loaded: LoadedMessage?
  @State private var error: String?
  @State private var reader = ReaderController()

  var body: some View {
    Group {
      if let loaded {
        LoadedMessageView(message: loaded, isStandalone: true)
      } else if let error {
        ContentUnavailableView("Couldn't Load Message", systemImage: "exclamationmark.triangle", description: Text(error))
      } else {
        ProgressView()
      }
    }
    .environment(reader)
    .navigationTitle(loaded?.parsed.subject.nilIfEmpty ?? "Message")
    .toolbar {
      ToolbarItem {
        Button {
          reader.print()
        } label: {
          Label("Print", systemImage: "printer")
        }
        .disabled(loaded == nil)
      }
    }
    .task {
      do {
        loaded = try await store.loadMessage(reference)
        if loaded?.summary.isRead == false {
          await store.setFlag(MessageFlag.seen, on: true, references: [reference])
        }
      } catch {
        self.error = error.localizedDescription
      }
    }
  }
}

struct LoadedMessageView: View {
  @Environment(MailStore.self) private var store
  @Environment(MailUIState.self) private var ui: MailUIState?
  @Environment(ReaderController.self) private var reader
  @Environment(\.openWindow) private var openWindow
  @AppStorage(MailPreferences.bodyMode) private var bodyMode = BodyMode.original
  @AppStorage(MailPreferences.attachmentsInline) private var attachmentsInline = true
  let message: LoadedMessage
  let isStandalone: Bool

  private var invitations: [CalendarInvitation] {
    message.parsed.attachments
      .filter { $0.mimeType == "text/calendar" || $0.filename.lowercased().hasSuffix(".ics") }
      .flatMap { ICalendar.invitations(in: String(decoding: $0.data, as: UTF8.self)) }
  }

  var body: some View {
    let allowRemote = store.allowsRemoteContent(message.reference)
    let rendered = MessageHTML.render(
      message.parsed, allowRemote: allowRemote, mode: bodyMode, inlineAttachments: attachmentsInline)
    VStack(spacing: 12) {
      MessageHeaderCard(message: message, isStandalone: isStandalone)

      if let ui, ui.findVisible {
        FindInMessageBar(ui: ui, reader: reader)
      }

      if let security = message.security {
        SecurityBar(status: security)
      }

      ForEach(invitations, id: \.uid) { invitation in
        InvitationCard(invitation: invitation, message: message)
      }

      if rendered.hasRemoteContent && !allowRemote {
        RemoteContentBar {
          store.allowRemoteContent(message.reference)
        }
        .transition(.move(edge: .top).combined(with: .opacity))
      }

      MessageWebView(rendered: rendered) { url in
        openWindow(id: WindowID.compose, value: store.newDraft(to: MailtoLink.address(url)))
      }
      .clipShape(.rect(cornerRadius: rendered.isPlainText ? 0 : 14))

      let visibleAttachments = message.parsed.attachments.filter { $0.mimeType != "text/calendar" }
      if !visibleAttachments.isEmpty {
        AttachmentBar(attachments: visibleAttachments)
      }
    }
    .padding(12)
    .animation(.smooth, value: allowRemote)
  }
}

private struct MessageHeaderCard: View {
  @Environment(MailStore.self) private var store
  @AppStorage(MailPreferences.headerMode) private var headerMode = HeaderMode.normal
  @Environment(ContactsStore.self) private var contacts
  @Environment(CalendarStore.self) private var calendar
  @Environment(\.openWindow) private var openWindow
  let message: LoadedMessage
  let isStandalone: Bool
  @State private var showingSource = false
  @State private var eventDraft: EventDraft?

  private var parsed: ParsedMessage { message.parsed }
  private var summary: MessageSummary {
    store.items.first { $0.reference == message.reference }?.summary ?? message.summary
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top, spacing: 12) {
        let sender = parsed.from.first ?? summary.from.first
        AvatarView(address: sender, size: 40, image: sender.flatMap { contacts.card(forEmail: $0.email)?.thumbnail })
        VStack(alignment: .leading, spacing: 2) {
          Menu {
            if let sender {
              Button("Write Message") { openWindow(id: WindowID.compose, value: store.newDraft(to: sender.formatted)) }
              Button("Copy Email Address") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(sender.email, forType: .string)
              }
              if contacts.card(forEmail: sender.email) == nil {
                Button("Add to Address Book") {
                  do { try contacts.addToAddressBook(sender) } catch {
                    store.report(error, title: "Couldn't add the contact")
                  }
                }
              }
            }
          } label: {
            Text(sender?.displayName ?? "(no sender)")
              .font(.headline)
          }
          .menuStyle(.button)
          .buttonStyle(.plain)
          .fixedSize()
          if let email = sender?.email, sender?.name != nil {
            Text(email)
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
          }
        }
        Spacer()
        actions
      }

      HStack(alignment: .firstTextBaseline) {
        Text(parsed.subject.nilIfEmpty ?? summary.subject.nilIfEmpty ?? "(no subject)")
          .font(.title3.weight(.semibold))
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
        ForEach(summary.tags) { tag in
          Text(tag.name)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .glassEffect(.regular.tint(Color(hex: tag.colorHex).opacity(0.6)), in: .capsule)
        }
      }

      if headerMode == .all {
        ScrollView {
          Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 3) {
            ForEach(Array(parsed.headers.fields.enumerated()), id: \.offset) { _, field in
              headerRow(field.name, MIMEDecoder.decodeEncodedWords(field.value))
            }
          }
          .font(.caption.monospaced())
        }
        .frame(maxHeight: 180)
      } else {
      Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 3) {
        if !parsed.to.isEmpty {
          headerRow("To", parsed.to.map(\.formatted).joined(separator: ", "))
        }
        if !parsed.cc.isEmpty {
          headerRow("Cc", parsed.cc.map(\.formatted).joined(separator: ", "))
        }
        if let groups = parsed.headers["Newsgroups"] {
          headerRow("Newsgroups", groups)
        }
        headerRow("Date", (parsed.date ?? summary.date).formatted(date: .complete, time: .shortened))
      }
      .font(.callout)
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .glassEffect(.regular, in: .rect(cornerRadius: 20))
    .sheet(isPresented: $showingSource) {
      MessageSourceView(data: message.raw)
    }
    .sheet(item: $eventDraft) { draft in
      EventEditor(initial: draft)
    }
  }

  private func headerRow(_ label: String, _ value: String) -> some View {
    GridRow {
      Text(label)
        .foregroundStyle(.secondary)
      Text(value)
        .lineLimit(3)
        .textSelection(.enabled)
    }
  }

  private var references: Set<MessageReference> { [message.reference] }

  private var actions: some View {
    GlassEffectContainer(spacing: 6) {
      HStack(spacing: 6) {
        iconButton("Reply", "arrowshape.turn.up.left") {
          if let draft = store.replyDraft(all: false, to: message) { openWindow(id: WindowID.compose, value: draft) }
        }
        if parsed.to.count + parsed.cc.count > 1 {
          iconButton("Reply All", "arrowshape.turn.up.left.2") {
            if let draft = store.replyDraft(all: true, to: message) { openWindow(id: WindowID.compose, value: draft) }
          }
        }
        iconButton("Forward", "arrowshape.turn.up.right") {
          if let draft = store.forwardDraft(message) { openWindow(id: WindowID.compose, value: draft) }
        }
        iconButton(summary.isFlagged ? "Remove Star" : "Add Star", summary.isFlagged ? "star.fill" : "star") {
          Task { await store.setFlag(MessageFlag.flagged, on: !summary.isFlagged, references: references) }
        }
        .foregroundStyle(summary.isFlagged ? .yellow : .primary)
        if store.folder(role: .archive, in: message.reference.accountID).map({ $0.path != message.reference.path }) ?? false {
          iconButton("Archive", "archivebox") {
            Task { await store.move(references, to: .archive) }
          }
        }
        iconButton("Delete", "trash") {
          Task { await store.delete(references) }
        }
        Menu {
          Menu("Tag") {
            ForEach(MessageTag.defaults) { tag in
              Button {
                Task { await store.setFlag(tag.keyword, on: !summary.flags.contains(tag.keyword), references: references) }
              } label: {
                Label(tag.name, systemImage: summary.flags.contains(tag.keyword) ? "checkmark" : "circle.fill")
              }
            }
          }
          Button(summary.isRead ? "Mark as Unread" : "Mark as Read") {
            Task { await store.setFlag(MessageFlag.seen, on: !summary.isRead, references: references) }
          }
          Divider()
          if !isStandalone {
            Button("Open in New Window") { openWindow(id: WindowID.message, value: message.reference) }
          }
          Button("View Source") { showingSource = true }
          Button("Save As…") { saveMessage() }
          Divider()
          Button("Convert to Event…") { eventDraft = calendar.eventDraft(from: message) }
          Button("Convert to Task") {
            do { try calendar.createTask(from: message) } catch { store.report(error, title: "Couldn't create the task") }
          }
          if let draft = store.reopenDraft(message) {
            Divider()
            Button(message.folderRole == .templates ? "New Message from Template" : "Edit Draft") {
              openWindow(id: WindowID.compose, value: draft)
            }
          }
        } label: {
          Image(systemName: "ellipsis")
            .frame(width: 18, height: 18)
        }
        .menuIndicator(.hidden)
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .help("More actions")
      }
    }
  }

  private func saveMessage() {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = (parsed.subject.nilIfEmpty ?? "Message").replacingOccurrences(of: "/", with: "-") + ".eml"
    if panel.runModal() == .OK, let url = panel.url {
      try? message.raw.write(to: url)
    }
  }

  private func iconButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .frame(width: 18, height: 18)
    }
    .buttonStyle(.glass)
    .buttonBorderShape(.circle)
    .help(title)
    .accessibilityLabel(title)
  }
}

private struct SecurityBar: View {
  let status: MessageSecurityStatus

  var body: some View {
    let trustworthy = status.isTrustworthy
    HStack(spacing: 10) {
      Image(systemName: status.encrypted ? "lock.fill" : trustworthy ? "checkmark.seal.fill" : "exclamationmark.shield.fill")
      VStack(alignment: .leading, spacing: 1) {
        Text(status.technology.label)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Text(status.summary)
          .font(.callout)
          .lineLimit(2)
      }
      Spacer()
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .glassEffect(.regular.tint((trustworthy ? Color.green : Color.orange).opacity(0.3)), in: .rect(cornerRadius: 14))
    .accessibilityElement(children: .combine)
  }
}

private struct InvitationCard: View {
  @Environment(MailStore.self) private var store
  @Environment(CalendarStore.self) private var calendar
  let invitation: CalendarInvitation
  let message: LoadedMessage
  @State private var response: String?

  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      VStack(spacing: 0) {
        Text(invitation.start.formatted(.dateTime.month(.abbreviated)).uppercased())
          .font(.caption2.weight(.bold))
          .foregroundStyle(.red)
        Text(invitation.start.formatted(.dateTime.day()))
          .font(.title2.weight(.semibold))
      }
      .frame(width: 48, height: 52)
      .glassEffect(.regular, in: .rect(cornerRadius: 10))
      VStack(alignment: .leading, spacing: 4) {
        Text(invitation.summary)
          .font(.headline)
        Text(
          invitation.isAllDay
            ? invitation.start.formatted(date: .complete, time: .omitted)
            : "\(invitation.start.formatted(date: .abbreviated, time: .shortened)) – \(invitation.end.formatted(date: .omitted, time: .shortened))"
        )
        .font(.callout)
        if let location = invitation.location, !location.isEmpty {
          Label(location, systemImage: "mappin.and.ellipse")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        if let organizer = invitation.organizer {
          Text("Organiser: \(organizer.displayName)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        if let response {
          Text(response)
            .font(.caption.weight(.medium))
            .foregroundStyle(.green)
        }
      }
      Spacer()
      GlassEffectContainer(spacing: 6) {
        VStack(alignment: .trailing, spacing: 6) {
          if invitation.method == "REQUEST" {
            HStack(spacing: 6) {
              Button("Accept") { Task { await respond("ACCEPTED") } }
                .buttonStyle(.glassProminent)
              Button("Maybe") { Task { await respond("TENTATIVE") } }
                .buttonStyle(.glass)
              Button("Decline") { Task { await respond("DECLINED") } }
                .buttonStyle(.glass)
            }
          }
          Button("Add to Calendar") { addToCalendar() }
            .buttonStyle(.glass)
        }
      }
      .controlSize(.small)
    }
    .padding(14)
    .glassEffect(.regular.tint(.blue.opacity(0.15)), in: .rect(cornerRadius: 16))
  }

  private func addToCalendar() {
    Task {
      if !calendar.hasEventAccess { await calendar.requestEventAccess() }
      do {
        try calendar.importInvitation(invitation)
        response = "Added to your calendar."
      } catch {
        store.report(error, title: "Couldn't add the event")
      }
    }
  }

  private func respond(_ status: String) async {
    if status != "DECLINED" {
      if !calendar.hasEventAccess { await calendar.requestEventAccess() }
      try? calendar.importInvitation(invitation)
    }
    await store.respond(to: invitation, status: status, from: message)
    response = status == "ACCEPTED" ? "You accepted this invitation." : status == "DECLINED" ? "You declined this invitation." : "You replied Maybe."
  }
}

private struct RemoteContentBar: View {
  let onAllow: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "shield.lefthalf.filled")
      Text("Thunderbird blocked remote content in this message to protect your privacy.")
        .font(.callout)
        .lineLimit(2)
      Spacer()
      Button("Show Remote Content", action: onAllow)
        .buttonStyle(.glassProminent)
        .controlSize(.small)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .glassEffect(.regular.tint(.yellow.opacity(0.35)), in: .rect(cornerRadius: 14))
  }
}

private struct AttachmentBar: View {
  let attachments: [MessageAttachment]

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label(
          "\(attachments.count) attachment\(attachments.count == 1 ? "" : "s") · "
            + attachments.map(\.size).reduce(0, +).byteCountFormatted,
          systemImage: "paperclip"
        )
        .font(.callout.weight(.medium))
        Spacer()
        Button("Save All…") {
          AttachmentFiles.save(attachments)
        }
        .buttonStyle(.glass)
        .controlSize(.small)
      }
      ScrollView(.horizontal) {
        GlassEffectContainer(spacing: 8) {
          HStack(spacing: 8) {
            ForEach(attachments) { attachment in
              Button {
                AttachmentFiles.open(attachment)
              } label: {
                HStack(spacing: 6) {
                  Image(systemName: AttachmentFiles.symbol(for: attachment.mimeType))
                  VStack(alignment: .leading, spacing: 0) {
                    Text(attachment.filename)
                      .lineLimit(1)
                    Text(attachment.size.byteCountFormatted)
                      .font(.caption2)
                      .foregroundStyle(.secondary)
                  }
                }
                .padding(.vertical, 2)
              }
              .buttonStyle(.glass)
              .contextMenu {
                Button("Open") { AttachmentFiles.open(attachment) }
                Button("Save As…") { AttachmentFiles.save([attachment]) }
                if attachment.mimeType.contains("pgp-keys") || attachment.filename.hasSuffix(".asc") {
                  Button("Import OpenPGP Key") { _ = try? OpenPGP.shared.importKeys(attachment.data) }
                }
              }
              .help("Open \(attachment.filename)")
            }
          }
          .padding(2)
        }
      }
      .scrollIndicators(.never)
    }
  }
}

/// Edit › Find › Find in This Message.
private struct FindInMessageBar: View {
  let ui: MailUIState
  let reader: ReaderController

  var body: some View {
    @Bindable var ui = ui
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
      TextField("Find in this message", text: $ui.findText)
        .textFieldStyle(.plain)
        .onSubmit { reader.find(ui.findText, backwards: false) }
      if !reader.lastFindFound && !ui.findText.isEmpty {
        Text("Phrase not found").font(.caption).foregroundStyle(.secondary)
      }
      GlassEffectContainer(spacing: 4) {
        HStack(spacing: 4) {
          Button { reader.find(ui.findText, backwards: true) } label: { Image(systemName: "chevron.up") }
            .accessibilityLabel("Previous match")
          Button { reader.find(ui.findText, backwards: false) } label: { Image(systemName: "chevron.down") }
            .accessibilityLabel("Next match")
          Button { ui.findVisible = false } label: { Image(systemName: "xmark") }
            .accessibilityLabel("Close find bar")
            .keyboardShortcut(.cancelAction)
        }
        .buttonStyle(.glass)
        .controlSize(.small)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 6)
    .glassEffect(.regular, in: .capsule)
  }
}

/// Go › Mail Start Page: shown when no message is selected.
private struct MailStartPage: View {
  @Environment(MailStore.self) private var store

  var body: some View {
    VStack(spacing: 18) {
      Image(nsImage: NSApp.applicationIconImage)
        .resizable()
        .frame(width: 88, height: 88)
      Text("Thunderbird")
        .font(.largeTitle.weight(.semibold))
      let unread = store.unifiedUnread(.inbox)
      Text(unread > 0 ? "You have \(unread) unread message\(unread == 1 ? "" : "s") in your inboxes." : "No message selected.")
        .foregroundStyle(.secondary)
      if store.isOffline {
        Label("You're working offline.", systemImage: "wifi.slash")
          .foregroundStyle(.orange)
      }
    }
    .padding(40)
    .glassEffect(.regular, in: .rect(cornerRadius: 28))
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
