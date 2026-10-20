/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation

public struct FolderSnapshot: Codable, Sendable {
  public var uidValidity: UInt32
  public var messages: [MessageSummary]
}

/// On-disk cache of folder lists, message summaries and downloaded message sources.
public struct MailCache: Sendable {
  public let root: URL

  public init(root: URL? = nil) {
    if let root {
      self.root = root
    } else {
      let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      self.root = support.appending(path: "Thunderbird for macOS/Cache", directoryHint: .isDirectory)
    }
  }

  private func accountDirectory(_ account: UUID) -> URL {
    root.appending(path: account.uuidString, directoryHint: .isDirectory)
  }

  private func folderDirectory(_ account: UUID, path: String) -> URL {
    let name = Data(path.utf8).base64EncodedString()
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "+", with: "-")
    return accountDirectory(account).appending(path: name, directoryHint: .isDirectory)
  }

  private func write<T: Encodable>(_ value: T, to url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let data = try? JSONEncoder().encode(value) {
      try? data.write(to: url, options: .atomic)
    }
  }

  private func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(type, from: data)
  }

  public func folders(account: UUID) -> [RemoteFolder]? {
    read([RemoteFolder].self, from: accountDirectory(account).appending(path: "folders.json"))
  }

  public func saveFolders(_ folders: [RemoteFolder], account: UUID) {
    write(folders, to: accountDirectory(account).appending(path: "folders.json"))
  }

  public func snapshot(account: UUID, path: String) -> FolderSnapshot? {
    read(FolderSnapshot.self, from: folderDirectory(account, path: path).appending(path: "messages.json"))
  }

  public func saveSnapshot(_ snapshot: FolderSnapshot, account: UUID, path: String) {
    write(snapshot, to: folderDirectory(account, path: path).appending(path: "messages.json"))
  }

  public func message(account: UUID, path: String, uid: UInt32) -> Data? {
    try? Data(contentsOf: folderDirectory(account, path: path).appending(path: "\(uid).eml"))
  }

  public func saveMessage(_ data: Data, account: UUID, path: String, uid: UInt32) {
    let url = folderDirectory(account, path: path).appending(path: "\(uid).eml")
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: url, options: .atomic)
  }

  public func removeMessages(account: UUID, path: String, uids: [UInt32]) {
    let directory = folderDirectory(account, path: path)
    for uid in uids {
      try? FileManager.default.removeItem(at: directory.appending(path: "\(uid).eml"))
    }
  }

  public func clearFolder(account: UUID, path: String) {
    try? FileManager.default.removeItem(at: folderDirectory(account, path: path))
  }

  public func removeAccount(_ account: UUID) {
    try? FileManager.default.removeItem(at: accountDirectory(account))
  }
}
