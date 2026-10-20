/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import SwiftUI
import ThunderbirdCore

struct MessageReaderView: View {
  @Environment(MailStore.self) private var store

  var body: some View {
    switch store.reader {
    case .empty:
      ContentUnavailableView("No Message Selected", systemImage: "envelope")
    case .multiple(let count):
      ContentUnavailableView(
        "\(count) Messages Selected", systemImage: "envelope.stack",
        description: Text("Use the toolbar to archive, delete or mark them all at once."))
    case .loading:
      ProgressView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .failed(let message):
      ContentUnavailableView("Couldn't Load Message", systemImage: "exclamationmark.triangle", description: Text(message))
    case .loaded(let message):
      LoadedMessageView(message: message)
        .id(message.reference)
    }
  }
}

private struct LoadedMessageView: View {
  @Environment(MailStore.self) private var store
  @Environment(\.openWindow) private var openWindow
  let message: LoadedMessage

  var body: some View {
    let allowRemote = store.allowsRemoteContent(message.reference)
    let rendered = MessageHTML.render(message.parsed, allowRemote: allowRemote)
    VStack(spacing: 12) {
      MessageHeaderCard(message: message)

      if rendered.hasRemoteContent && !allowRemote {
        RemoteContentBar {
          store.allowRemoteContent(message.reference)
        }
        .transition(.move(edge: .top).combined(with: .opacity))
      }

      MessageWebView(rendered: rendered) { url in
        let address = url.absoluteString.dropFirst("mailto:".count).split(separator: "?").first.map(String.init) ?? ""
        openWindow(id: WindowID.compose, value: store.newDraft(to: address.removingPercentEncoding ?? address))
      }
      .clipShape(.rect(cornerRadius: rendered.isPlainText ? 0 : 14))

      if !message.parsed.attachments.isEmpty {
        AttachmentBar(attachments: message.parsed.attachments)
      }
    }
    .padding(12)
    .animation(.smooth, value: allowRemote)
  }
}

private struct MessageHeaderCard: View {
  @Environment(MailStore.self) private var store
  @Environment(\.openWindow) private var openWindow
  let message: LoadedMessage

  private var parsed: ParsedMessage { message.parsed }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top, spacing: 12) {
        AvatarView(address: parsed.from.first ?? message.summary.from.first, size: 40)
        VStack(alignment: .leading, spacing: 2) {
          let sender = parsed.from.first ?? message.summary.from.first
          Text(sender?.displayName ?? "(no sender)")
            .font(.headline)
            .textSelection(.enabled)
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

      Text(parsed.subject.nilIfEmpty ?? message.summary.subject.nilIfEmpty ?? "(no subject)")
        .font(.title3.weight(.semibold))
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)

      Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 3) {
        if !parsed.to.isEmpty {
          headerRow("To", parsed.to)
        }
        if !parsed.cc.isEmpty {
          headerRow("Cc", parsed.cc)
        }
        GridRow {
          Text("Date")
            .foregroundStyle(.secondary)
          Text((parsed.date ?? message.summary.date).formatted(date: .complete, time: .shortened))
        }
      }
      .font(.callout)
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .glassEffect(.regular, in: .rect(cornerRadius: 20))
  }

  private func headerRow(_ label: String, _ addresses: [MailAddress]) -> some View {
    GridRow {
      Text(label)
        .foregroundStyle(.secondary)
      Text(addresses.map(\.formatted).joined(separator: ", "))
        .lineLimit(3)
        .textSelection(.enabled)
    }
  }

  private var actions: some View {
    GlassEffectContainer(spacing: 6) {
      HStack(spacing: 6) {
        iconButton("Reply", "arrowshape.turn.up.left") {
          if let draft = store.replyDraft(all: false) { openWindow(id: WindowID.compose, value: draft) }
        }
        if parsed.to.count + parsed.cc.count > 1 {
          iconButton("Reply All", "arrowshape.turn.up.left.2") {
            if let draft = store.replyDraft(all: true) { openWindow(id: WindowID.compose, value: draft) }
          }
        }
        iconButton("Forward", "arrowshape.turn.up.right") {
          if let draft = store.forwardDraft() { openWindow(id: WindowID.compose, value: draft) }
        }
        iconButton(message.summary.isFlagged ? "Remove Star" : "Add Star", message.summary.isFlagged ? "star.fill" : "star") {
          Task { await store.toggleStar() }
        }
        .foregroundStyle(message.summary.isFlagged ? .yellow : .primary)
        if store.hasFolder(.archive) {
          iconButton("Archive", "archivebox") {
            Task { await store.moveSelected(to: .archive) }
          }
        }
        iconButton("Delete", "trash") {
          Task { await store.deleteSelected() }
        }
      }
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
