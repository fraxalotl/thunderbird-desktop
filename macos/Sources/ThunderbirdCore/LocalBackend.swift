/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation

/// Messages stored on this Mac, one `.eml` file per message plus a JSON index per folder.
/// Used for Local Folders and as the store POP3 accounts download into.
public actor LocalBackend: MailBackend {
  public nonisolated let accountID: UUID
  public nonisolated let capabilities = BackendCapabilities(
    canMoveAndDelete: true, canManageFolders: true, canAppend: true, canSearchServer: false)
  private let root: URL
  private let defaultFolders: [(String, FolderRole)]

  private struct Index: Codable {
    var nextUID: UInt32
    var messages: [MessageSummary]
  }

  public init(accountID: UUID, root: URL, defaultFolders: [(String, FolderRole)]) {
    self.accountID = accountID
    self.root = root
    self.defaultFolders = defaultFolders
  }

  public static func storageRoot(for accountID: UUID) -> URL {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return support.appending(path: "Thunderbird for macOS/Mail/\(accountID.uuidString)", directoryHint: .isDirectory)
  }

  public static let localFoldersDefaults: [(String, FolderRole)] = [("Trash", .trash), ("Unsent Messages", .outbox)]
  public static let pop3Defaults: [(String, FolderRole)] = [
    ("Inbox", .inbox), ("Drafts", .drafts), ("Templates", .templates), ("Sent", .sent),
    ("Archives", .archive), ("Junk", .junk), ("Trash", .trash),
  ]

  // MARK: - Storage

  private var foldersURL: URL { root.appending(path: "folders.json") }

  private func directory(_ path: String) -> URL {
    let safe = Data(path.utf8).base64EncodedString()
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "+", with: "-")
    return root.appending(path: safe, directoryHint: .isDirectory)
  }

  private func loadFolders() -> [RemoteFolder] {
    if let data = try? Data(contentsOf: foldersURL),
      var folders = try? JSONDecoder().decode([RemoteFolder].self, from: data)
    {
      // Top-level folders named Drafts, Templates, Sent and so on are special folders, as in
      // Thunderbird's Local Folders; older stores saved them as plain folders.
      var changed = false
      for index in folders.indices where folders[index].role == .normal && !folders[index].path.contains("/") {
        let role = RemoteFolder.detectRole(path: folders[index].path, delimiter: "/", attributes: [])
        if role != .normal {
          folders[index].role = role
          changed = true
        }
      }
      if changed { saveFolders(folders) }
      return folders
    }
    let folders = defaultFolders.map { RemoteFolder(path: $0.0, delimiter: "/", attributes: [], role: $0.1) }
    saveFolders(folders)
    return folders
  }

  private func saveFolders(_ folders: [RemoteFolder]) {
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    if let data = try? JSONEncoder().encode(folders) {
      try? data.write(to: foldersURL, options: .atomic)
    }
  }

  private func loadIndex(_ path: String) -> Index {
    let url = directory(path).appending(path: "index.json")
    if let data = try? Data(contentsOf: url), let index = try? JSONDecoder().decode(Index.self, from: data) {
      return index
    }
    return Index(nextUID: 1, messages: [])
  }

  private func saveIndex(_ index: Index, _ path: String) {
    let folder = directory(path)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    if let data = try? JSONEncoder().encode(index) {
      try? data.write(to: folder.appending(path: "index.json"), options: .atomic)
    }
  }

  private func counted(_ folder: RemoteFolder) -> RemoteFolder {
    var folder = folder
    let index = loadIndex(folder.path)
    folder.total = index.messages.count
    folder.unseen = index.messages.filter { !$0.isRead }.count
    return folder
  }

  // MARK: - MailBackend

  public func cachedFolders() -> [RemoteFolder] {
    loadFolders().map(counted)
  }

  public func refreshFolders() async throws -> [RemoteFolder] {
    cachedFolders()
  }

  public func cachedMessages(in path: String) -> [MessageSummary] {
    loadIndex(path).messages.sorted { $0.date > $1.date }
  }

  public func sync(path: String, limit: Int) async throws -> SyncResult {
    SyncResult(messages: Array(cachedMessages(in: path).prefix(max(limit, 5000))), newMessages: [])
  }

  public func message(uid: UInt32, in path: String) async throws -> Data {
    guard let data = try? Data(contentsOf: directory(path).appending(path: "\(uid).eml")) else {
      throw MailError.server("The message file is missing.")
    }
    return data
  }

  /// Stores a message and returns its summary.
  @discardableResult
  public func deliver(_ data: Data, to path: String, flags: Set<String>) -> MessageSummary {
    var index = loadIndex(path)
    let uid = index.nextUID
    index.nextUID += 1
    let folder = directory(path)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try? data.write(to: folder.appending(path: "\(uid).eml"), options: .atomic)
    let summary = MessageSummary(uid: uid, data: data, flags: flags)
    index.messages.append(summary)
    saveIndex(index, path)
    return summary
  }

  public func append(_ message: Data, to path: String, flags: [String]) async throws {
    deliver(message, to: path, flags: Set(flags))
  }

  public func setFlags(_ flags: [String], on: Bool, uids: [UInt32], in path: String) async throws {
    var index = loadIndex(path)
    let targets = Set(uids)
    for position in index.messages.indices where targets.contains(index.messages[position].uid) {
      for flag in flags {
        if on {
          index.messages[position].flags.insert(flag)
        } else {
          index.messages[position].flags.remove(flag)
        }
      }
    }
    saveIndex(index, path)
  }

  public func copy(uids: [UInt32], from source: String, to destination: String) async throws -> [UInt32: UInt32] {
    let index = loadIndex(source)
    var mapping: [UInt32: UInt32] = [:]
    for summary in index.messages where uids.contains(summary.uid) {
      let data = try await message(uid: summary.uid, in: source)
      mapping[summary.uid] = deliver(data, to: destination, flags: summary.flags).uid
    }
    return mapping
  }

  public func move(uids: [UInt32], from source: String, to destination: String) async throws -> [UInt32: UInt32] {
    let mapping = try await copy(uids: uids, from: source, to: destination)
    try await delete(uids: uids, in: source)
    return mapping
  }

  public func delete(uids: [UInt32], in path: String) async throws {
    var index = loadIndex(path)
    let targets = Set(uids)
    index.messages.removeAll { targets.contains($0.uid) }
    for uid in uids {
      try? FileManager.default.removeItem(at: directory(path).appending(path: "\(uid).eml"))
    }
    saveIndex(index, path)
  }

  public func emptyFolder(_ path: String) async throws {
    let index = loadIndex(path)
    try await delete(uids: index.messages.map(\.uid), in: path)
  }

  public func search(_ query: SearchQuery, in path: String, limit: Int) async throws -> [MessageSummary] {
    var results: [MessageSummary] = []
    let needsBody = query.field == .body || query.field == .all
    for summary in cachedMessages(in: path) {
      var body: String?
      if needsBody, let data = try? await message(uid: summary.uid, in: path) {
        body = ParsedMessage(data: data).plainText
      }
      if query.matches(summary, body: body) {
        results.append(summary)
        if results.count >= limit { break }
      }
    }
    return results
  }

  public func findMessage(messageID: String, in path: String) async throws -> [UInt32] {
    loadIndex(path).messages.filter { $0.messageID == messageID }.map(\.uid)
  }

  public func createFolder(_ name: String, parent: String?) async throws -> String {
    var folders = loadFolders()
    let path = parent.map { "\($0)/\(name)" } ?? name
    guard !folders.contains(where: { $0.path == path }) else { return path }
    let role = parent == nil ? RemoteFolder.detectRole(path: path, delimiter: "/", attributes: []) : .normal
    folders.append(RemoteFolder(path: path, delimiter: "/", attributes: [], role: role))
    saveFolders(folders)
    return path
  }

  public func renameFolder(_ path: String, to name: String) async throws {
    var folders = loadFolders()
    guard let position = folders.firstIndex(where: { $0.path == path }) else { return }
    var components = path.components(separatedBy: "/")
    components[components.count - 1] = name
    let newPath = components.joined(separator: "/")
    try? FileManager.default.moveItem(at: directory(path), to: directory(newPath))
    folders[position] = RemoteFolder(path: newPath, delimiter: "/", attributes: [], role: folders[position].role)
    saveFolders(folders)
  }

  public func deleteFolder(_ path: String) async throws {
    var folders = loadFolders()
    folders.removeAll { $0.path == path || $0.path.hasPrefix(path + "/") }
    try? FileManager.default.removeItem(at: directory(path))
    saveFolders(folders)
  }

  public func disconnect() async {}

  public func removeAllData() {
    try? FileManager.default.removeItem(at: root)
  }
}
