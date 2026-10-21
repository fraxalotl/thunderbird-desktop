/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import ThunderbirdCore

enum QuickFilterScope: String, CaseIterable, Identifiable {
  case sender, recipients, subject, body
  var id: String { rawValue }
  var title: String { rawValue.capitalized }
}

enum ThreadMode: String, CaseIterable {
  case threaded, unthreaded, grouped

  var title: String {
    switch self {
    case .threaded: "Threaded"
    case .unthreaded: "Unthreaded"
    case .grouped: "Grouped By Sort"
    }
  }
}

/// View › Sort by.
enum SortKey: String, CaseIterable, Identifiable {
  case date, received, star, orderReceived, priority, from, recipient, correspondents, size, status, subject, read, tags,
    spam, attachments
  var id: String { rawValue }

  var title: String {
    switch self {
    case .date: "Date"
    case .received: "Received"
    case .star: "Star"
    case .orderReceived: "Order Received"
    case .priority: "Priority"
    case .from: "From"
    case .recipient: "Recipient"
    case .correspondents: "Correspondents"
    case .size: "Size"
    case .status: "Status"
    case .subject: "Subject"
    case .read: "Read"
    case .tags: "Tags"
    case .spam: "Spam Status"
    case .attachments: "Attachments"
    }
  }
}

/// View › Threads.
enum ThreadFilter: String, CaseIterable {
  case all, unread, threadsWithUnread, watchedWithUnread, ignored

  var title: String {
    switch self {
    case .all: "All"
    case .unread: "Unread"
    case .threadsWithUnread: "Threads with Unread"
    case .watchedWithUnread: "Watched Threads with Unread"
    case .ignored: "Ignored Threads"
    }
  }
}

/// View › Messages.
enum MessageViewFilter: Hashable {
  case all, unread, notDeleted
  case tag(String)
}

extension MailStore {
  var isFiltering: Bool {
    filterUnread || filterStarred || filterAttachments || filterContact || filterTag != nil
      || !filterText.trimmingCharacters(in: .whitespaces).isEmpty || viewFilter != .all || threadFilter != .all
  }

  func clearQuickFilter() {
    filterText = ""
    filterUnread = false
    filterStarred = false
    filterAttachments = false
    filterContact = false
    filterTag = nil
    bodyMatches = nil
  }

  /// The thread (root Message-ID) each message belongs to, from References.
  private func threadRoots(_ items: [MessageItem]) -> [MessageReference: String] {
    var roots: [MessageReference: String] = [:]
    for thread in Threading.threads(items, summary: { $0.summary }) {
      let root = thread.root.summary.messageID ?? "uid:\(thread.root.reference.uid)"
      for member in thread.flattened() {
        roots[member.reference] = root
      }
    }
    return roots
  }

  private func isIgnored(_ summary: MessageSummary) -> Bool {
    guard !ignoredThreads.isEmpty else { return false }
    return ([summary.messageID].compactMap { $0 } + summary.references).contains(where: ignoredThreads.contains)
  }

  func isWatched(_ summary: MessageSummary) -> Bool {
    guard !watchedThreads.isEmpty else { return false }
    return ([summary.messageID].compactMap { $0 } + summary.references).contains(where: watchedThreads.contains)
  }

  var filteredItems: [MessageItem] {
    let query = filterText.trimmingCharacters(in: .whitespaces).lowercased()
    var result = items.filter { item in
      let message = item.summary
      if filterUnread && message.isRead { return false }
      if filterStarred && !message.isFlagged { return false }
      if filterAttachments && !message.hasAttachment { return false }
      if filterContact && !message.from.contains(where: { knownContactEmails.contains($0.email.lowercased()) }) { return false }
      if let filterTag, !message.flags.contains(filterTag) { return false }
      switch viewFilter {
      case .all: break
      case .unread: if message.isRead { return false }
      case .notDeleted: if message.flags.contains(MessageFlag.deleted) { return false }
      case .tag(let keyword): if !message.flags.contains(keyword) { return false }
      }
      if threadFilter == .ignored {
        if !isIgnored(message) { return false }
      } else if isIgnored(message) {
        return false
      }
      guard !query.isEmpty else { return true }
      func addresses(_ list: [MailAddress]) -> Bool {
        list.contains { $0.email.lowercased().contains(query) || ($0.name?.lowercased().contains(query) ?? false) }
      }
      if filterScopes.contains(.subject) && message.subject.lowercased().contains(query) { return true }
      if filterScopes.contains(.sender) && addresses(message.from) { return true }
      if filterScopes.contains(.recipients) && addresses(message.to + message.cc) { return true }
      if filterScopes.contains(.body), bodyMatches?.contains(item.reference) == true { return true }
      return false
    }

    if threadFilter == .unread {
      result = result.filter { !$0.summary.isRead }
    } else if threadFilter == .threadsWithUnread || threadFilter == .watchedWithUnread {
      let roots = threadRoots(items)
      var unreadThreads = Set<String>()
      for item in items where !item.summary.isRead {
        if let root = roots[item.reference] { unreadThreads.insert(root) }
      }
      result = result.filter { item in
        guard let root = roots[item.reference], unreadThreads.contains(root) else { return false }
        return threadFilter == .threadsWithUnread || isWatched(item.summary)
      }
    }
    return sorted(result)
  }

  func sorted(_ items: [MessageItem]) -> [MessageItem] {
    let tags = MessageTagStore.shared
    let showRecipients = [.sent, .drafts, .outbox].contains(currentFolder?.role)
    func name(_ list: [MailAddress]) -> String { list.first?.displayName.lowercased() ?? "" }
    func less(_ a: MessageItem, _ b: MessageItem) -> Bool {
      let x = a.summary
      let y = b.summary
      switch sortKey {
      case .date: return x.date < y.date
      case .received: return (x.received ?? x.date) < (y.received ?? y.date)
      case .star: return (x.isFlagged ? 1 : 0, x.date) < (y.isFlagged ? 1 : 0, y.date)
      case .orderReceived: return x.uid < y.uid
      case .priority: return (x.priority == 0 ? 3 : x.priority, x.date) > (y.priority == 0 ? 3 : y.priority, y.date)
      case .from: return name(x.from) < name(y.from)
      case .recipient: return name(x.to) < name(y.to)
      case .correspondents: return name(showRecipients ? x.to : x.from) < name(showRecipients ? y.to : y.from)
      case .size: return x.size < y.size
      case .status:
        func rank(_ m: MessageSummary) -> Int { m.isAnswered ? 2 : m.isForwarded ? 3 : m.isRead ? 1 : 0 }
        return rank(x) < rank(y)
      case .subject:
        func base(_ s: String) -> String {
          s.lowercased().replacingOccurrences(of: #"^((re|fwd?|aw|sv|tr)\s*:\s*)+"#, with: "", options: .regularExpression)
        }
        return base(x.subject) < base(y.subject)
      case .read: return (x.isRead ? 1 : 0, x.date) < (y.isRead ? 1 : 0, y.date)
      case .tags: return (tags.tags(for: x).first?.name ?? "~") < (tags.tags(for: y).first?.name ?? "~")
      case .spam: return (x.isJunk ? 1 : 0) < (y.isJunk ? 1 : 0)
      case .attachments: return (x.hasAttachment ? 1 : 0, x.date) < (y.hasAttachment ? 1 : 0, y.date)
      }
    }
    return items.sorted { sortAscending ? less($0, $1) : less($1, $0) }
  }

  /// Heading for "Grouped By Sort" mode.
  func groupTitle(_ item: MessageItem) -> String {
    let summary = item.summary
    switch sortKey {
    case .date, .received:
      let date = sortKey == .received ? (summary.received ?? summary.date) : summary.date
      let calendar = Calendar.current
      if calendar.isDateInToday(date) { return "Today" }
      if calendar.isDateInYesterday(date) { return "Yesterday" }
      if let days = calendar.dateComponents([.day], from: date, to: .now).day, days < 7 { return "Last 7 Days" }
      if let days = calendar.dateComponents([.day], from: date, to: .now).day, days < 14 { return "Last 14 Days" }
      return "Older"
    case .from, .correspondents: return summary.from.first?.displayName ?? "(no sender)"
    case .recipient: return summary.to.first?.displayName ?? "(no recipient)"
    case .subject: return summary.subject.isEmpty ? "(no subject)" : summary.subject
    case .star: return summary.isFlagged ? "Starred" : "Not Starred"
    case .read: return summary.isRead ? "Read" : "Unread"
    case .attachments: return summary.hasAttachment ? "With Attachments" : "Without Attachments"
    case .priority: return ["None", "Highest", "High", "Normal", "Low", "Lowest"][summary.priority]
    case .tags: return MessageTagStore.shared.tags(for: summary).first?.name ?? "No Tag"
    case .spam: return summary.isJunk ? "Spam" : "Not Spam"
    case .status: return summary.isAnswered ? "Replied" : summary.isForwarded ? "Forwarded" : summary.isRead ? "Read" : "New"
    case .size, .orderReceived: return ""
    }
  }

  func updateBodyMatches() async {
    let query = filterText.trimmingCharacters(in: .whitespaces)
    guard filterScopes.contains(.body), !query.isEmpty, let selection = selectedFolder,
      let backend = backend(selection.accountID)
    else {
      bodyMatches = nil
      return
    }
    let found = (try? await backend.search(SearchQuery(text: query, field: .body), in: selection.path, limit: 500)) ?? []
    bodyMatches = Set(found.map { MessageReference(accountID: selection.accountID, path: selection.path, uid: $0.uid) })
  }

  // MARK: - Ignore and watch threads

  private func threadIDs(for references: Set<MessageReference>, subthread: Bool) -> [String] {
    let selected = items.filter { references.contains($0.reference) }
    if subthread {
      return selected.compactMap(\.summary.messageID)
    }
    return selected.compactMap { $0.summary.references.first ?? $0.summary.messageID }
  }

  func toggleIgnoreThread(subthread: Bool = false) {
    let ids = threadIDs(for: selection, subthread: subthread)
    let allIgnored = ids.allSatisfy(ignoredThreads.contains)
    var updated = ignoredThreads
    for id in ids {
      if allIgnored { updated.remove(id) } else { updated.insert(id) }
    }
    setIgnoredThreads(updated)
  }

  func toggleWatchThread() {
    let ids = threadIDs(for: selection, subthread: false)
    let allWatched = ids.allSatisfy(watchedThreads.contains)
    var updated = watchedThreads
    for id in ids {
      if allWatched { updated.remove(id) } else { updated.insert(id) }
    }
    setWatchedThreads(updated)
  }
}
