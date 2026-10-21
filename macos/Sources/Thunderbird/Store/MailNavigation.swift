/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import ThunderbirdCore

/// A row in the message list: a message, its place in its thread and whether it's expanded.
struct ListRow: Identifiable, Hashable {
  var item: MessageItem
  var depth: Int
  var descendants: Int
  var unreadInThread: Int
  var isExpanded: Bool
  var group: String?
  var id: MessageReference { item.reference }
}

enum NavigationTarget {
  case message, unread, starred, unreadThread
}

extension MailStore {
  /// The rows to show, honouring the thread mode, sort and expanded threads.
  var listRows: [ListRow] {
    let items = filteredItems
    switch threadMode {
    case .unthreaded:
      return items.map { ListRow(item: $0, depth: 0, descendants: 0, unreadInThread: 0, isExpanded: false) }
    case .grouped:
      return items.map {
        ListRow(item: $0, depth: 0, descendants: 0, unreadInThread: 0, isExpanded: false, group: groupTitle($0))
      }
    case .threaded:
      let order = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($1.reference, $0) })
      let threads = Threading.threads(items) { $0.summary }
        .sorted { (order[$0.root.reference] ?? 0) < (order[$1.root.reference] ?? 0) }
      var rows: [ListRow] = []
      func add(_ thread: MessageThread<MessageItem>, depth: Int) {
        let members = thread.flattened()
        let expanded = depth > 0 || expandedThreads.contains(thread.root.reference)
        rows.append(
          ListRow(
            item: thread.root, depth: depth, descendants: members.count - 1,
            unreadInThread: members.filter { !$0.summary.isRead }.count, isExpanded: expanded))
        if expanded {
          for reply in thread.replies { add(reply, depth: depth + 1) }
        }
      }
      threads.forEach { add($0, depth: 0) }
      return rows
    }
  }

  func toggleExpanded(_ reference: MessageReference) {
    if expandedThreads.contains(reference) {
      expandedThreads.remove(reference)
    } else {
      expandedThreads.insert(reference)
    }
  }

  func expandAllThreads() {
    expandedThreads = Set(Threading.threads(filteredItems) { $0.summary }.map(\.root.reference))
  }

  func collapseAllThreads() {
    expandedThreads = []
  }

  /// Go › Next/Previous. Unread and starred searches wrap around, as Thunderbird's do.
  func navigate(_ target: NavigationTarget, forward: Bool) {
    if threadMode == .threaded { expandAllThreads() }
    let rows = listRows
    guard !rows.isEmpty else { return }
    let current = selection.first.flatMap { reference in rows.firstIndex { $0.id == reference } }
    let indices = Array(rows.indices)
    let ordered: [Int]
    if let current {
      ordered = forward
        ? Array(indices[(current + 1)...]) + (target == .message ? [] : Array(indices[...current]))
        : Array(indices[..<current].reversed()) + (target == .message ? [] : Array(indices[current...].reversed()))
    } else {
      ordered = forward ? indices : indices.reversed()
    }
    let match = ordered.first { index in
      let summary = rows[index].item.summary
      switch target {
      case .message: return true
      case .unread: return !summary.isRead
      case .starred: return summary.isFlagged
      case .unreadThread: return rows[index].depth == 0 && rows[index].unreadInThread > 0 && index != current
      }
    }
    if let match {
      selection = [rows[match].id]
    }
  }

  var canGoBack: Bool { historyIndex > 0 }
  var canGoForward: Bool { historyIndex >= 0 && historyIndex < history.count - 1 }

  func goBack() { moveInHistory(by: -1) }
  func goForward() { moveInHistory(by: 1) }

  private func moveInHistory(by offset: Int) {
    let target = historyIndex + offset
    guard history.indices.contains(target) else { return }
    historyIndex = target
    let reference = history[target]
    navigatingHistory = true
    let folder = FolderSelection(accountID: reference.accountID, path: reference.path)
    if selectedFolder != folder, case .folder = source {
      source = .folder(folder)
      Task {
        try? await Task.sleep(for: .milliseconds(300))
        selection = [reference]
        navigatingHistory = false
      }
    } else {
      selection = [reference]
      navigatingHistory = false
    }
  }

  func selectThread() {
    let rows = Threading.threads(filteredItems) { $0.summary }
    var references = Set<MessageReference>()
    for thread in rows where thread.flattened().contains(where: { selection.contains($0.reference) }) {
      thread.flattened().forEach { references.insert($0.reference) }
    }
    selection = references
  }

  func selectStarred() {
    selection = Set(filteredItems.filter(\.summary.isFlagged).map(\.reference))
  }

  func selectAll() {
    selection = Set(filteredItems.map(\.reference))
  }

  func moveAgain() async {
    guard let target = lastMoveTarget else { return }
    await transfer(Array(selection), to: target.destination, copy: target.copy)
  }
}
