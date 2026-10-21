/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import SwiftUI
import ThunderbirdCore

struct MessageListView: View {
  @Environment(MailStore.self) private var store
  @Environment(CalendarStore.self) private var calendar
  @Environment(MailUIState.self) private var ui
  @Environment(\.openWindow) private var openWindow
  @AppStorage(MailPreferences.listStyle) private var listStyle = ListStyle.cards
  @AppStorage(MailPreferences.density) private var density = Density.normal
  @AppStorage(MailPreferences.showListHeader) private var showHeader = true
  @AppStorage(MailPreferences.showQuickFilter) private var showQuickFilter = true
  @SceneStorage("messageTableColumns") private var columns = TableColumnCustomization<ListRow>()
  @FocusState private var focused: Bool

  private var showRecipients: Bool { [.sent, .drafts, .outbox].contains(store.currentFolder?.role) }

  var body: some View {
    @Bindable var store = store
    let rows = store.listRows
    Group {
      if listStyle == .table {
        table(rows)
      } else {
        cards(rows)
      }
    }
    .focused($focused)
    .contextMenu(forSelectionType: MessageReference.self) { selection in
      if !selection.isEmpty {
        MessageContextMenu(store: store, calendar: calendar, ui: ui, openWindow: openWindow)
      }
    } primaryAction: { selection in
      guard selection.count == 1, let reference = selection.first else { return }
      Task { await open(reference) }
    }
    .onKeyPress(phases: .down) { press in handleKey(press) }
    .safeAreaBar(edge: .top) {
      VStack(spacing: 0) {
        if showHeader {
          MessageListHeader(count: store.items.count, unread: store.items.filter { !$0.summary.isRead }.count)
        }
        if showQuickFilter {
          QuickFilterBar()
        }
      }
    }
    .overlay {
      if rows.isEmpty {
        if store.isFiltering {
          ContentUnavailableView(
            "No Matching Messages", systemImage: "line.3.horizontal.decrease.circle",
            description: Text("No messages match the quick filter."))
        } else if store.activity == nil {
          ContentUnavailableView("No Messages", systemImage: "tray", description: Text("This folder is empty."))
        }
      }
    }
    .navigationTitle(store.sourceTitle)
    .task(id: [store.filterText, store.filterScopes.contains(.body) ? "body" : ""]) {
      try? await Task.sleep(for: .milliseconds(400))
      await store.updateBodyMatches()
    }
  }

  // MARK: - Cards

  @ViewBuilder
  private func cards(_ rows: [ListRow]) -> some View {
    @Bindable var store = store
    if store.threadMode == .grouped {
      let groups = Dictionary(grouping: rows) { $0.group ?? "" }
      let order = rows.map { $0.group ?? "" }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
      List(selection: $store.selection) {
        ForEach(order, id: \.self) { group in
          Section(group) {
            ForEach(groups[group] ?? []) { row in cardRow(row) }
          }
        }
      }
      .listStyle(.inset)
    } else {
      List(rows, selection: $store.selection) { row in cardRow(row) }
        .listStyle(.inset)
    }
  }

  private func cardRow(_ row: ListRow) -> some View {
    MessageRow(
      row: row, showRecipients: showRecipients, showFolder: store.selectedFolder == nil, density: density,
      onToggleThread: { store.toggleExpanded(row.id) }
    )
    .tag(row.id)
    .draggable(MessageDragPayload(references: dragReferences(row.id)))
  }

  // MARK: - Table

  private func table(_ rows: [ListRow]) -> some View {
    @Bindable var store = store
    return Table(of: ListRow.self, selection: $store.selection, columnCustomization: $columns) {
      Group {
      TableColumn("") { (row: ListRow) in ThreadToggle(row: row) { store.toggleExpanded(row.id) } }
        .width(store.threadMode == .threaded ? 28 : 0)
        .customizationID("thread")
      TableColumn("Star") { (row: ListRow) in StarCell(row: row) }
        .width(26)
        .customizationID("star")
      TableColumn("Attachment") { (row: ListRow) in AttachmentCell(row: row) }
        .width(26)
        .customizationID("attachment")
      TableColumn("Subject") { (row: ListRow) in SubjectCell(row: row) }
        .customizationID("subject")
      TableColumn(showRecipients ? "Recipient" : "Correspondents") { (row: ListRow) in
        CorrespondentCell(row: row, showRecipients: showRecipients)
      }
      .customizationID("correspondent")
      TableColumn("Date") { (row: ListRow) in DateCell(date: row.item.summary.date) }
        .width(min: 70, ideal: 110)
        .customizationID("date")
      }
      Group {
      TableColumn("Received") { (row: ListRow) in DateCell(date: row.item.summary.received ?? row.item.summary.date) }
        .customizationID("received")
        .defaultVisibility(.hidden)
      TableColumn("Size") { (row: ListRow) in DetailCell(text: row.item.summary.size.byteCountFormatted) }
        .width(min: 50, ideal: 70)
        .customizationID("size")
        .defaultVisibility(.hidden)
      TableColumn("Priority") { (row: ListRow) in DetailCell(text: PriorityName.of(row.item.summary.priority)) }
        .customizationID("priority")
        .defaultVisibility(.hidden)
      TableColumn("Tags") { (row: ListRow) in TagsCell(row: row) }
        .customizationID("tags")
        .defaultVisibility(.hidden)
      TableColumn("Account") { (row: ListRow) in LocationCell(row: row, showAccount: true) }
        .customizationID("account")
        .defaultVisibility(.hidden)
      TableColumn("Location") { (row: ListRow) in LocationCell(row: row, showAccount: false) }
        .customizationID("location")
        .defaultVisibility(.hidden)
      }
    } rows: {
      ForEach(rows) { row in
        TableRow(row)
          .draggable(MessageDragPayload(references: dragReferences(row.id)))
      }
    }
    .environment(\.defaultMinListRowHeight, 18 + density.rowPadding * 2)
  }

  // MARK: - Actions

  private func dragReferences(_ reference: MessageReference) -> [MessageReference] {
    store.selection.contains(reference) ? Array(store.selection) : [reference]
  }

  /// Double-click: drafts and templates open for editing, other messages open in their own window.
  private func open(_ reference: MessageReference) async {
    let role = store.role(of: reference)
    if role == .drafts || role == .templates || role == .outbox {
      if let loaded = try? await store.loadMessage(reference), let draft = store.reopenDraft(loaded) {
        openWindow(id: WindowID.compose, value: draft)
        return
      }
    }
    store.openMessageWindow(reference, using: openWindow)
  }

  /// Thunderbird's single-key shortcuts for the message list (mainKeySet.inc.xhtml).
  private func handleKey(_ press: KeyPress) -> KeyPress.Result {
    let shift = press.modifiers.contains(.shift)
    guard !press.modifiers.contains(.command), !press.modifiers.contains(.control) else { return .ignored }
    if press.key == .delete || press.key == .deleteForward {
      Task { await store.deleteSelected(permanently: shift) }
      return .handled
    }
    if press.key == .return, store.selection.count == 1, let reference = store.selection.first {
      Task { await open(reference) }
      return .handled
    }
    let character = press.characters.lowercased()
    if let digit = Int(character), (0...9).contains(digit) {
      if digit == 0 {
        Task { await store.removeAllTags() }
      } else if MessageTagStore.shared.tags.indices.contains(digit - 1) {
        let keyword = MessageTagStore.shared.tags[digit - 1].keyword
        Task { await store.toggleTag(keyword) }
      }
      return .handled
    }
    switch character {
    case "m": Task { await store.toggleRead() }
    case "s": Task { await store.toggleStar() }
    case "j": Task { await store.markJunk(!shift) }
    case "a": Task { await store.moveSelected(to: .archive) }
    case "r": Task { await store.markThreadRead() }
    case "c": if shift { Task { await store.markAllRead() } } else { ui.present(.markReadByDate) }
    case "f": store.navigate(.message, forward: true)
    case "b": store.navigate(.message, forward: false)
    case "n": store.navigate(.unread, forward: true)
    case "p": store.navigate(.unread, forward: false)
    case "t": store.navigate(.unreadThread, forward: true)
    case "w": store.toggleWatchThread()
    case "k": store.toggleIgnoreThread(subthread: shift)
    case "*": store.expandAllThreads()
    case "\\": store.collapseAllThreads()
    case "]": store.goForward()
    case "[": store.goBack()
    default: return .ignored
    }
    return .handled
  }
}

private struct ThreadToggle: View {
  let row: ListRow
  let toggle: () -> Void

  var body: some View {
    if row.depth == 0 && row.descendants > 0 {
      Button(action: toggle) {
        Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(row.isExpanded ? "Collapse thread" : "Expand thread")
    }
  }
}

/// The message list header (View › Layout › Message List Header).
private struct MessageListHeader: View {
  @Environment(MailStore.self) private var store
  @AppStorage(MailPreferences.showQuickFilter) private var showQuickFilter = true
  @AppStorage(MailPreferences.listStyle) private var listStyle = ListStyle.cards
  let count: Int
  let unread: Int

  var body: some View {
    @Bindable var store = store
    HStack(spacing: 8) {
      VStack(alignment: .leading, spacing: 0) {
        Text(store.sourceTitle)
          .font(.headline)
          .lineLimit(1)
        Text(unread > 0 ? "\(count) messages, \(unread) unread" : "\(count) messages")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 4)
      GlassEffectContainer(spacing: 6) {
        HStack(spacing: 6) {
          Toggle(isOn: $showQuickFilter) {
            Image(systemName: "line.3.horizontal.decrease")
          }
          .toggleStyle(.button)
          .help("Quick Filter (⇧⌘K)")
          Menu {
            Picker("List", selection: $listStyle) {
              Label("Cards View", systemImage: "rectangle.grid.1x2").tag(ListStyle.cards)
              Label("Table View", systemImage: "tablecells").tag(ListStyle.table)
            }
            .pickerStyle(.inline)
            Picker("Threads", selection: $store.threadMode) {
              ForEach(ThreadMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            Picker("Sort by", selection: $store.sortKey) {
              ForEach(SortKey.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Ascending", isOn: $store.sortAscending)
            Divider()
            Button("Expand All Threads") { store.expandAllThreads() }
            Button("Collapse All Threads") { store.collapseAllThreads() }
          } label: {
            Image(systemName: "list.bullet.indent")
          }
          .menuIndicator(.hidden)
          .fixedSize()
          .help("Message list display options")
        }
        .buttonStyle(.glass)
        .controlSize(.small)
      }
    }
    .padding(.horizontal, 12)
    .padding(.top, 6)
  }
}

struct MessageRow: View {
  @Environment(MailStore.self) private var store
  let row: ListRow
  let showRecipients: Bool
  let showFolder: Bool
  var density = Density.normal
  var onToggleThread: () -> Void = {}

  private var message: MessageSummary { row.item.summary }

  private var correspondent: String {
    let addresses = showRecipients ? message.to : message.from
    return addresses.map(\.displayName).joined(separator: ", ").nilIfEmpty ?? "(no sender)"
  }

  var body: some View {
    let tags = MessageTagStore.shared.tags(for: message)
    HStack(alignment: .top, spacing: 8) {
      if row.depth > 0 {
        Spacer().frame(width: CGFloat(row.depth) * 16)
      }
      if row.depth == 0 && row.descendants > 0 {
        ThreadToggle(row: row, toggle: onToggleThread)
          .padding(.top, 2)
      }
      Circle()
        .fill(.tint)
        .frame(width: 8, height: 8)
        .padding(.top, 5)
        .opacity((row.isExpanded || row.descendants == 0 ? !message.isRead : row.unreadInThread > 0) ? 1 : 0)
        .accessibilityLabel(message.isRead ? "" : "Unread")

      VStack(alignment: .leading, spacing: density == .compact ? 1 : 3) {
        HStack(spacing: 6) {
          Text(correspondent)
            .fontWeight(message.isRead ? .regular : .semibold)
            .lineLimit(1)
          if row.descendants > 0 && !row.isExpanded {
            Text("\(row.descendants + 1)")
              .font(.caption2.weight(.semibold))
              .padding(.horizontal, 6)
              .padding(.vertical, 1)
              .glassEffect(.regular, in: .capsule)
              .accessibilityLabel("\(row.descendants + 1) messages in thread")
          }
          if store.isWatched(message) {
            Image(systemName: "eye").foregroundStyle(.secondary).imageScale(.small).accessibilityLabel("Watched thread")
          }
          Spacer(minLength: 4)
          if message.priority > 0 && message.priority < 3 {
            Image(systemName: "exclamationmark").foregroundStyle(.red).imageScale(.small).accessibilityLabel("High priority")
          }
          if message.isJunk {
            Image(systemName: "xmark.bin.fill").foregroundStyle(.orange).imageScale(.small).accessibilityLabel("Spam")
          }
          if message.hasAttachment {
            Image(systemName: "paperclip").foregroundStyle(.secondary).imageScale(.small).accessibilityLabel("Has attachment")
          }
          Text(message.date.listFormatted)
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        HStack(spacing: 4) {
          if message.isAnswered {
            Image(systemName: "arrowshape.turn.up.left.fill").foregroundStyle(.purple).imageScale(.small)
              .accessibilityLabel("Replied")
          } else if message.isForwarded {
            Image(systemName: "arrowshape.turn.up.right.fill").foregroundStyle(.blue).imageScale(.small)
              .accessibilityLabel("Forwarded")
          }
          Text(message.subject.nilIfEmpty ?? "(no subject)")
            .font(.callout)
            .foregroundStyle(tags.first.map { Color(hex: $0.colorHex) } ?? (message.isRead ? .secondary : .primary))
            .lineLimit(1)
          Spacer(minLength: 4)
          ForEach(tags) { tag in
            Circle().fill(Color(hex: tag.colorHex)).frame(width: 7, height: 7).help(tag.name)
          }
          if message.isFlagged {
            Image(systemName: "star.fill").foregroundStyle(.yellow).imageScale(.small).accessibilityLabel("Starred")
          }
        }
        if showFolder {
          Text(
            "\(store.account(row.item.reference.accountID)?.label ?? "") › \(store.folder(FolderSelection(accountID: row.item.reference.accountID, path: row.item.reference.path))?.displayName ?? row.item.reference.path)"
          )
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .lineLimit(1)
        }
      }
    }
    .padding(.vertical, density.rowPadding)
  }
}

/// Thunderbird's quick filter bar: sticky, unread, starred, contact, tags, attachment and a
/// text filter scoped to sender, recipients, subject or body.
struct QuickFilterBar: View {
  @Environment(MailStore.self) private var store
  @Namespace private var namespace

  var body: some View {
    @Bindable var store = store
    VStack(alignment: .leading, spacing: 6) {
      ViewThatFits(in: .horizontal) {
        toggles(labels: true)
        toggles(labels: false)
      }
      HStack(spacing: 8) {
        Image(systemName: "line.3.horizontal.decrease")
          .foregroundStyle(.secondary)
        TextField("Filter these messages…", text: $store.filterText)
          .textFieldStyle(.plain)
        if !store.filterText.isEmpty {
          Button {
            store.filterText = ""
          } label: {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Clear filter")
        }
        Menu {
          ForEach(QuickFilterScope.allCases) { scope in
            Toggle(
              scope.title,
              isOn: Binding(
                get: { store.filterScopes.contains(scope) },
                set: { on in
                  if on { store.filterScopes.insert(scope) } else if store.filterScopes.count > 1 { store.filterScopes.remove(scope) }
                }))
          }
        } label: {
          Text(QuickFilterScope.allCases.filter(store.filterScopes.contains).map(\.title).joined(separator: ", "))
            .font(.caption)
            .lineLimit(1)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .help("Choose what the text filter searches")
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .glassEffect(.regular.interactive(), in: .capsule)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .animation(.bouncy, value: [store.filterUnread, store.filterStarred, store.filterAttachments, store.filterContact, store.filterSticky])
  }

  private func toggles(labels: Bool) -> some View {
    @Bindable var store = store
    return GlassEffectContainer(spacing: 6) {
      HStack(spacing: 6) {
        FilterToggle(title: "Sticky", symbol: "pin", activeSymbol: "pin.fill", isOn: $store.filterSticky, showsLabel: false, namespace: namespace)
          .help("Keep filters when switching folders")
        FilterToggle(title: "Unread", symbol: "envelope.badge", activeSymbol: "envelope.badge.fill", isOn: $store.filterUnread, showsLabel: labels, namespace: namespace)
        FilterToggle(title: "Starred", symbol: "star", activeSymbol: "star.fill", isOn: $store.filterStarred, showsLabel: labels, namespace: namespace)
        FilterToggle(title: "Contact", symbol: "person.crop.circle", activeSymbol: "person.crop.circle.fill", isOn: $store.filterContact, showsLabel: labels, namespace: namespace)
        Menu {
          Button("Any Tag") { store.filterTag = nil }
          Divider()
          ForEach(MessageTagStore.shared.tags) { tag in
            Button(tag.name) { store.filterTag = tag.keyword }
          }
        } label: {
          Label(
            MessageTagStore.shared.tag(store.filterTag ?? "")?.name ?? "Tags",
            systemImage: store.filterTag == nil ? "tag" : "tag.fill")
            .labelStyle(labels ? AnyLabelStyle(.titleAndIcon) : AnyLabelStyle(.iconOnly))
            .font(.callout)
            .fixedSize()
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .fixedSize()
        FilterToggle(title: "Attachment", symbol: "paperclip", activeSymbol: "paperclip", isOn: $store.filterAttachments, showsLabel: labels, namespace: namespace)
        Spacer(minLength: 0)
      }
    }
  }
}

struct AnyLabelStyle: LabelStyle {
  private let make: (Configuration) -> AnyView

  init<S: LabelStyle>(_ style: S) {
    make = { AnyView(style.makeBody(configuration: $0)) }
  }

  func makeBody(configuration: Configuration) -> some View {
    make(configuration)
  }
}

private struct FilterToggle: View {
  let title: String
  let symbol: String
  let activeSymbol: String
  @Binding var isOn: Bool
  var showsLabel = true
  let namespace: Namespace.ID

  var body: some View {
    Button {
      isOn.toggle()
    } label: {
      Group {
        if showsLabel {
          Label(title, systemImage: isOn ? activeSymbol : symbol)
        } else {
          Image(systemName: isOn ? activeSymbol : symbol)
        }
      }
      .font(.callout)
      .lineLimit(1)
      .fixedSize()
      .padding(.horizontal, 10)
      .padding(.vertical, 5)
      .foregroundStyle(isOn ? Color.white : Color.primary)
    }
    .buttonStyle(.plain)
    .glassEffect(isOn ? .regular.tint(.accentColor).interactive() : .regular.interactive(), in: .capsule)
    .glassEffectID(title, in: namespace)
    .accessibilityLabel(title)
    .accessibilityAddTraits(isOn ? .isSelected : [])
    .help(title)
  }
}

extension String {
  var nilIfEmpty: String? {
    trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
  }
}

extension Color {
  init(hex: String) {
    let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
    self.init(
      red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
      blue: Double(value & 0xFF) / 255)
  }
}

enum PriorityName {
  static func of(_ priority: Int) -> String {
    switch priority {
    case 1: "Highest"
    case 2: "High"
    case 4: "Low"
    case 5: "Lowest"
    default: ""
    }
  }
}

private struct StarCell: View {
  @Environment(MailStore.self) private var store
  let row: ListRow

  var body: some View {
    let flagged = row.item.summary.isFlagged
    Button {
      Task { await store.setFlag(MessageFlag.flagged, on: !flagged, references: [row.id]) }
    } label: {
      Image(systemName: flagged ? "star.fill" : "star")
        .foregroundStyle(flagged ? AnyShapeStyle(.yellow) : AnyShapeStyle(.tertiary))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(flagged ? "Remove star" : "Add star")
  }
}

private struct AttachmentCell: View {
  let row: ListRow

  var body: some View {
    if row.item.summary.hasAttachment {
      Image(systemName: "paperclip").foregroundStyle(.secondary).accessibilityLabel("Has attachment")
    }
  }
}

private struct SubjectCell: View {
  let row: ListRow

  var body: some View {
    let summary = row.item.summary
    let tagColor = MessageTagStore.shared.tags(for: summary).first.map { Color(hex: $0.colorHex) }
    HStack(spacing: 4) {
      if row.depth > 0 {
        Spacer().frame(width: CGFloat(row.depth) * 14)
      }
      Circle().fill(.tint).frame(width: 6, height: 6).opacity(summary.isRead ? 0 : 1)
      Text(summary.subject.nilIfEmpty ?? "(no subject)")
        .fontWeight(summary.isRead ? .regular : .semibold)
        .foregroundStyle(tagColor ?? .primary)
      if row.descendants > 0 && !row.isExpanded {
        Text("\(row.descendants + 1)").font(.caption2).foregroundStyle(.secondary)
      }
    }
    .lineLimit(1)
  }
}

private struct CorrespondentCell: View {
  let row: ListRow
  let showRecipients: Bool

  var body: some View {
    let summary = row.item.summary
    let addresses = showRecipients ? summary.to : summary.from
    Text(addresses.map(\.displayName).joined(separator: ", "))
      .fontWeight(summary.isRead ? .regular : .semibold)
      .lineLimit(1)
  }
}

private struct DateCell: View {
  let date: Date

  var body: some View {
    Text(date.listFormatted).monospacedDigit().foregroundStyle(.secondary)
  }
}

private struct DetailCell: View {
  let text: String

  var body: some View {
    Text(text).monospacedDigit().foregroundStyle(.secondary)
  }
}

private struct TagsCell: View {
  let row: ListRow

  var body: some View {
    Text(MessageTagStore.shared.tags(for: row.item.summary).map(\.name).joined(separator: ", "))
  }
}

private struct LocationCell: View {
  @Environment(MailStore.self) private var store
  let row: ListRow
  let showAccount: Bool

  var body: some View {
    let reference = row.item.reference
    if showAccount {
      Text(store.account(reference.accountID)?.label ?? "")
    } else {
      Text(store.folder(FolderSelection(accountID: reference.accountID, path: reference.path))?.displayName ?? "")
    }
  }
}
