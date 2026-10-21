/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation

/// A minimal Exchange Web Services client (SOAP over HTTPS), covering what Thunderbird's native
/// Exchange support uses: folders, items as MIME, flags, categories, moves, search and sending.
public actor EWSClient {
  private let endpoint: URL
  private let username: String
  private let credential: Credential

  public init(endpoint: URL, username: String, credential: Credential) {
    self.endpoint = endpoint
    self.username = username
    self.credential = credential
  }

  static func escape(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
  }

  @discardableResult
  func call(_ body: String) async throws -> XMLElement {
    let envelope = """
      <?xml version="1.0" encoding="utf-8"?>
      <soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" \
      xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types" \
      xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages">
      <soap:Header><t:RequestServerVersion Version="Exchange2013_SP1"/></soap:Header>
      <soap:Body>\(body)</soap:Body></soap:Envelope>
      """
    var request = URLRequest(url: endpoint, timeoutInterval: 90)
    request.httpMethod = "POST"
    request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
    switch credential {
    case .password(let password):
      request.setValue("Basic \(Data("\(username):\(password)".utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
    case .oauth(let token):
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    request.httpBody = Data(envelope.utf8)
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    if status == 401 || status == 403 {
      throw MailError.authenticationFailed("The Exchange server refused the credentials (HTTP \(status)).")
    }
    guard let document = try? XMLDocument(data: data), let root = document.rootElement() else {
      throw MailError.protocolError("The Exchange server sent an unreadable response (HTTP \(status)).")
    }
    if let fault = Self.first(root, "faultstring")?.stringValue {
      throw MailError.server(fault)
    }
    for message in Self.all(root, "*") where message.attribute(forName: "ResponseClass")?.stringValue == "Error" {
      let code = Self.first(message, "ResponseCode")?.stringValue ?? ""
      if code == "ErrorItemNotFound" || code == "ErrorFolderNotFound" { continue }
      throw MailError.server(Self.first(message, "MessageText")?.stringValue ?? code)
    }
    return root
  }

  static func all(_ element: XMLElement, _ name: String) -> [XMLElement] {
    let query = name == "*" ? ".//*[@ResponseClass]" : ".//*[local-name()='\(name)']"
    return ((try? element.nodes(forXPath: query)) ?? []).compactMap { $0 as? XMLElement }
  }

  static func first(_ element: XMLElement, _ name: String) -> XMLElement? {
    all(element, name).first
  }

  static func child(_ element: XMLElement, _ name: String) -> XMLElement? {
    element.children?.compactMap { $0 as? XMLElement }.first { $0.localName == name }
  }

  // MARK: - Folders

  public struct FolderInfo: Sendable {
    public var id: String
    public var parentID: String?
    public var name: String
    public var total: Int
    public var unread: Int
  }

  public func folders() async throws -> (folders: [FolderInfo], rootID: String?, distinguished: [String: String]) {
    let response = try await call("""
      <m:FindFolder Traversal="Deep"><m:FolderShape><t:BaseShape>Default</t:BaseShape><t:AdditionalProperties>
      <t:FieldURI FieldURI="folder:ParentFolderId"/><t:FieldURI FieldURI="folder:FolderClass"/></t:AdditionalProperties>
      </m:FolderShape><m:ParentFolderIds><t:DistinguishedFolderId Id="msgfolderroot"/></m:ParentFolderIds></m:FindFolder>
      """)
    var folders: [FolderInfo] = []
    for folder in Self.all(response, "Folder") {
      let folderClass = Self.child(folder, "FolderClass")?.stringValue
      guard folderClass == nil || folderClass?.hasPrefix("IPF.Note") == true,
        let id = Self.child(folder, "FolderId")?.attribute(forName: "Id")?.stringValue
      else { continue }
      folders.append(
        FolderInfo(
          id: id, parentID: Self.child(folder, "ParentFolderId")?.attribute(forName: "Id")?.stringValue,
          name: Self.child(folder, "DisplayName")?.stringValue ?? "Folder",
          total: Int(Self.child(folder, "TotalCount")?.stringValue ?? "") ?? 0,
          unread: Int(Self.child(folder, "UnreadCount")?.stringValue ?? "") ?? 0))
    }
    let names = ["msgfolderroot", "inbox", "drafts", "sentitems", "deleteditems", "junkemail", "archive", "outbox"]
    let ids = names.map { "<t:DistinguishedFolderId Id=\"\($0)\"/>" }.joined()
    let known = try await call("""
      <m:GetFolder><m:FolderShape><t:BaseShape>IdOnly</t:BaseShape></m:FolderShape><m:FolderIds>\(ids)</m:FolderIds></m:GetFolder>
      """)
    var distinguished: [String: String] = [:]
    for (name, message) in zip(names, Self.all(known, "GetFolderResponseMessage")) {
      if let id = Self.first(message, "FolderId")?.attribute(forName: "Id")?.stringValue {
        distinguished[name] = id
      }
    }
    return (folders, distinguished["msgfolderroot"], distinguished)
  }

  public func createFolder(_ name: String, parentID: String?) async throws -> String {
    let parent = parentID.map { "<t:FolderId Id=\"\(Self.escape($0))\"/>" } ?? "<t:DistinguishedFolderId Id=\"msgfolderroot\"/>"
    let response = try await call("""
      <m:CreateFolder><m:ParentFolderId>\(parent)</m:ParentFolderId><m:Folders><t:Folder>
      <t:FolderClass>IPF.Note</t:FolderClass><t:DisplayName>\(Self.escape(name))</t:DisplayName></t:Folder></m:Folders></m:CreateFolder>
      """)
    return Self.first(response, "FolderId")?.attribute(forName: "Id")?.stringValue ?? ""
  }

  public func renameFolder(_ id: String, to name: String) async throws {
    try await call("""
      <m:UpdateFolder><m:FolderChanges><t:FolderChange><t:FolderId Id="\(Self.escape(id))"/><t:Updates><t:SetFolderField>
      <t:FieldURI FieldURI="folder:DisplayName"/><t:Folder><t:DisplayName>\(Self.escape(name))</t:DisplayName></t:Folder>
      </t:SetFolderField></t:Updates></t:FolderChange></m:FolderChanges></m:UpdateFolder>
      """)
  }

  public func deleteFolder(_ id: String) async throws {
    try await call("<m:DeleteFolder DeleteType=\"HardDelete\"><m:FolderIds><t:FolderId Id=\"\(Self.escape(id))\"/></m:FolderIds></m:DeleteFolder>")
  }

  public func emptyFolder(_ id: String) async throws {
    try await call("""
      <m:EmptyFolder DeleteType="HardDelete" DeleteSubFolders="false"><m:FolderIds><t:FolderId Id="\(Self.escape(id))"/></m:FolderIds></m:EmptyFolder>
      """)
  }

  // MARK: - Items

  public struct ItemInfo: Sendable {
    public var id: String
    public var subject: String
    public var from: MailAddress?
    public var displayTo: String
    public var received: Date
    public var sent: Date?
    public var isRead: Bool
    public var isFlagged: Bool
    public var hasAttachments: Bool
    public var size: Int
    public var messageID: String?
    public var inReplyTo: String?
    public var categories: [String]
    public var importance: String
  }

  private static let itemProperties = """
    <t:FieldURI FieldURI="item:Subject"/><t:FieldURI FieldURI="message:From"/><t:FieldURI FieldURI="item:DisplayTo"/>
    <t:FieldURI FieldURI="item:DateTimeReceived"/><t:FieldURI FieldURI="item:DateTimeSent"/><t:FieldURI FieldURI="message:IsRead"/>
    <t:FieldURI FieldURI="item:HasAttachments"/><t:FieldURI FieldURI="item:Size"/><t:FieldURI FieldURI="message:InternetMessageId"/>
    <t:FieldURI FieldURI="item:InReplyTo"/><t:FieldURI FieldURI="item:Categories"/><t:FieldURI FieldURI="item:Importance"/>
    <t:ExtendedFieldURI PropertyTag="0x1090" PropertyType="Integer"/>
    """

  public func items(in folderID: String, limit: Int, query: String? = nil) async throws -> [ItemInfo] {
    let search = query.map { "<m:QueryString>\(Self.escape($0))</m:QueryString>" } ?? ""
    let response = try await call("""
      <m:FindItem Traversal="Shallow"><m:ItemShape><t:BaseShape>IdOnly</t:BaseShape><t:AdditionalProperties>\(Self.itemProperties)
      </t:AdditionalProperties></m:ItemShape><m:IndexedPageItemView MaxEntriesReturned="\(limit)" Offset="0" BasePoint="Beginning"/>
      <m:SortOrder><t:FieldOrder Order="Descending"><t:FieldURI FieldURI="item:DateTimeReceived"/></t:FieldOrder></m:SortOrder>
      <m:ParentFolderIds><t:FolderId Id="\(Self.escape(folderID))"/></m:ParentFolderIds>\(search)</m:FindItem>
      """)
    let iso = ISO8601DateFormatter()
    return Self.all(response, "Message").compactMap { message in
      guard let id = Self.child(message, "ItemId")?.attribute(forName: "Id")?.stringValue else { return nil }
      let mailbox = Self.first(message, "Mailbox")
      let flag = Self.all(message, "ExtendedProperty").first.flatMap { Self.child($0, "Value")?.stringValue }
      return ItemInfo(
        id: id,
        subject: Self.child(message, "Subject")?.stringValue ?? "",
        from: mailbox.map {
          MailAddress(name: Self.child($0, "Name")?.stringValue, email: Self.child($0, "EmailAddress")?.stringValue ?? "")
        },
        displayTo: Self.child(message, "DisplayTo")?.stringValue ?? "",
        received: Self.child(message, "DateTimeReceived")?.stringValue.flatMap(iso.date) ?? Date(),
        sent: Self.child(message, "DateTimeSent")?.stringValue.flatMap(iso.date),
        isRead: Self.child(message, "IsRead")?.stringValue == "true",
        isFlagged: flag == "2",
        hasAttachments: Self.child(message, "HasAttachments")?.stringValue == "true",
        size: Int(Self.child(message, "Size")?.stringValue ?? "") ?? 0,
        messageID: Self.child(message, "InternetMessageId")?.stringValue,
        inReplyTo: Self.child(message, "InReplyTo")?.stringValue,
        categories: Self.all(message, "String").compactMap(\.stringValue),
        importance: Self.child(message, "Importance")?.stringValue ?? "Normal")
    }
  }

  public func mimeContent(_ itemID: String) async throws -> Data {
    let response = try await call("""
      <m:GetItem><m:ItemShape><t:BaseShape>IdOnly</t:BaseShape><t:IncludeMimeContent>true</t:IncludeMimeContent></m:ItemShape>
      <m:ItemIds><t:ItemId Id="\(Self.escape(itemID))"/></m:ItemIds></m:GetItem>
      """)
    guard let base64 = Self.first(response, "MimeContent")?.stringValue,
      let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters)
    else { throw MailError.server("The message is no longer on the server.") }
    return data
  }

  private static func itemIDs(_ ids: [String]) -> String {
    ids.map { "<t:ItemId Id=\"\(escape($0))\"/>" }.joined()
  }

  public func setRead(_ read: Bool, items ids: [String]) async throws {
    guard !ids.isEmpty else { return }
    let changes = ids.map { id in
      """
      <t:ItemChange><t:ItemId Id="\(Self.escape(id))"/><t:Updates><t:SetItemField><t:FieldURI FieldURI="message:IsRead"/>
      <t:Message><t:IsRead>\(read)</t:IsRead></t:Message></t:SetItemField></t:Updates></t:ItemChange>
      """
    }.joined()
    try await call("""
      <m:UpdateItem MessageDisposition="SaveOnly" ConflictResolution="AlwaysOverwrite" SuppressReadReceipts="true">
      <m:ItemChanges>\(changes)</m:ItemChanges></m:UpdateItem>
      """)
  }

  public func setFlagged(_ flagged: Bool, items ids: [String]) async throws {
    guard !ids.isEmpty else { return }
    let field = "<t:ExtendedFieldURI PropertyTag=\"0x1090\" PropertyType=\"Integer\"/>"
    let changes = ids.map { id in
      let update =
        flagged
        ? "<t:SetItemField>\(field)<t:Message><t:ExtendedProperty>\(field)<t:Value>2</t:Value></t:ExtendedProperty></t:Message></t:SetItemField>"
        : "<t:DeleteItemField>\(field)</t:DeleteItemField>"
      return "<t:ItemChange><t:ItemId Id=\"\(Self.escape(id))\"/><t:Updates>\(update)</t:Updates></t:ItemChange>"
    }.joined()
    try await call("""
      <m:UpdateItem MessageDisposition="SaveOnly" ConflictResolution="AlwaysOverwrite"><m:ItemChanges>\(changes)</m:ItemChanges></m:UpdateItem>
      """)
  }

  public func setCategories(_ categories: [String], item id: String) async throws {
    let strings = categories.map { "<t:String>\(Self.escape($0))</t:String>" }.joined()
    let update =
      categories.isEmpty
      ? "<t:DeleteItemField><t:FieldURI FieldURI=\"item:Categories\"/></t:DeleteItemField>"
      : "<t:SetItemField><t:FieldURI FieldURI=\"item:Categories\"/><t:Message><t:Categories>\(strings)</t:Categories></t:Message></t:SetItemField>"
    try await call("""
      <m:UpdateItem MessageDisposition="SaveOnly" ConflictResolution="AlwaysOverwrite"><m:ItemChanges><t:ItemChange>
      <t:ItemId Id="\(Self.escape(id))"/><t:Updates>\(update)</t:Updates></t:ItemChange></m:ItemChanges></m:UpdateItem>
      """)
  }

  /// Moves or copies items and returns their new IDs in the same order.
  public func transfer(_ ids: [String], to folderID: String, copy: Bool) async throws -> [String?] {
    guard !ids.isEmpty else { return [] }
    let operation = copy ? "CopyItem" : "MoveItem"
    let response = try await call("""
      <m:\(operation)><m:ToFolderId><t:FolderId Id="\(Self.escape(folderID))"/></m:ToFolderId>
      <m:ItemIds>\(Self.itemIDs(ids))</m:ItemIds></m:\(operation)>
      """)
    return Self.all(response, "\(operation)ResponseMessage").map {
      Self.first($0, "ItemId")?.attribute(forName: "Id")?.stringValue
    }
  }

  public func delete(_ ids: [String]) async throws {
    guard !ids.isEmpty else { return }
    try await call("<m:DeleteItem DeleteType=\"HardDelete\"><m:ItemIds>\(Self.itemIDs(ids))</m:ItemIds></m:DeleteItem>")
  }

  /// Stores a MIME message in a folder. `draft` keeps it marked unsent so it opens as a draft.
  public func save(_ message: Data, in folderID: String, read: Bool, draft: Bool) async throws {
    let flags = (read ? 1 : 0) | (draft ? 8 : 0)
    try await call("""
      <m:CreateItem MessageDisposition="SaveOnly"><m:SavedItemFolderId><t:FolderId Id="\(Self.escape(folderID))"/></m:SavedItemFolderId>
      <m:Items><t:Message><t:MimeContent CharacterSet="UTF-8">\(message.base64EncodedString())</t:MimeContent>
      <t:ExtendedProperty><t:ExtendedFieldURI PropertyTag="0x0E07" PropertyType="Integer"/><t:Value>\(flags)</t:Value></t:ExtendedProperty>
      </t:Message></m:Items></m:CreateItem>
      """)
  }

  /// Sends a MIME message through Exchange, which also files it in Sent Items.
  public func send(_ message: Data) async throws {
    try await call("""
      <m:CreateItem MessageDisposition="SendAndSaveCopy"><m:SavedItemFolderId><t:DistinguishedFolderId Id="sentitems"/>
      </m:SavedItemFolderId><m:Items><t:Message><t:MimeContent CharacterSet="UTF-8">\(message.base64EncodedString())</t:MimeContent>
      </t:Message></m:Items></m:CreateItem>
      """)
  }

  // MARK: - Autodiscover

  /// Finds the EWS endpoint: Microsoft 365 by MX record, otherwise POX Autodiscover.
  public static func discoverEndpoint(email: String, username: String, password: String?) async -> URL? {
    let domain = String(email.split(separator: "@").last ?? "")
    let exchangers = await Task.detached { MXLookup.hosts(for: domain) }.value
    if exchangers.contains(where: { $0.hasSuffix("protection.outlook.com") || $0.hasSuffix("outlook.com") }) {
      return URL(string: "https://outlook.office365.com/EWS/Exchange.asmx")
    }
    let body = """
      <?xml version="1.0" encoding="utf-8"?><Autodiscover xmlns="http://schemas.microsoft.com/exchange/autodiscover/outlook/requestschema/2006">
      <Request><EMailAddress>\(escape(email))</EMailAddress>
      <AcceptableResponseSchema>http://schemas.microsoft.com/exchange/autodiscover/outlook/responseschema/2006a</AcceptableResponseSchema>
      </Request></Autodiscover>
      """
    for candidate in ["https://autodiscover.\(domain)/autodiscover/autodiscover.xml", "https://\(domain)/autodiscover/autodiscover.xml"] {
      guard let url = URL(string: candidate) else { continue }
      var request = URLRequest(url: url, timeoutInterval: 10)
      request.httpMethod = "POST"
      request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
      if let password {
        request.setValue("Basic \(Data("\(username):\(password)".utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
      }
      request.httpBody = Data(body.utf8)
      guard let (data, _) = try? await URLSession.shared.data(for: request), let document = try? XMLDocument(data: data),
        let root = document.rootElement()
      else { continue }
      if let ews = all(root, "EwsUrl").first?.stringValue, let endpoint = URL(string: ews) {
        return endpoint
      }
    }
    return nil
  }
}

/// An Exchange account. EWS identifies folders and items by opaque IDs; this maps them to the
/// folder paths and numeric UIDs the rest of the app uses.
public actor EWSBackend: MailBackend {
  public let account: MailAccount
  public nonisolated let accountID: UUID
  public nonisolated let capabilities = BackendCapabilities(
    canMoveAndDelete: true, canManageFolders: true, canAppend: true, canSearchServer: true)
  private let cache: MailCache
  private var client: EWSClient?
  /// Folder path → EWS folder ID, plus distinguished roles.
  private var folderIDs: [String: String] = [:]
  private var mapsURL: URL { LocalBackend.storageRoot(for: accountID).appending(path: "ews-ids.json") }

  /// Maps tag keywords to Exchange category names (Thunderbird's default tags by name).
  public nonisolated(unsafe) static var categoryName: (String) -> String = { keyword in
    MessageTag.defaults.first { $0.keyword == keyword }?.name ?? keyword
  }
  public nonisolated(unsafe) static var keyword: (String) -> String = { category in
    MessageTag.defaults.first { $0.name == category }?.keyword ?? category.lowercased()
  }

  private struct IDMaps: Codable {
    var folders: [String: String] = [:]
    var nextUID: [String: UInt32] = [:]
    var uidToItem: [String: [UInt32: String]] = [:]
  }

  public init(account: MailAccount, cache: MailCache) {
    self.account = account
    self.accountID = account.id
    self.cache = cache
  }

  private func loadMaps() -> IDMaps {
    (try? JSONDecoder().decode(IDMaps.self, from: Data(contentsOf: mapsURL))) ?? IDMaps()
  }

  private func saveMaps(_ maps: IDMaps) {
    try? FileManager.default.createDirectory(at: mapsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? JSONEncoder().encode(maps).write(to: mapsURL, options: .atomic)
  }

  private func connected() async throws -> EWSClient {
    if let client { return client }
    guard let endpoint = URL(string: account.ewsURL) else { throw MailError.server("The Exchange server address is invalid.") }
    let credential = try await Credentials.resolve(account.incoming, key: account.incomingKeychainKey)
    let client = EWSClient(endpoint: endpoint, username: account.incoming.username, credential: credential)
    self.client = client
    return client
  }

  private func folderID(_ path: String) throws -> String {
    if let id = folderIDs[path] ?? loadMaps().folders[path] { return id }
    throw MailError.server("The folder \(path) wasn't found on the Exchange server.")
  }

  /// Gives an item a stable numeric UID within its folder.
  private func uid(for itemID: String, in path: String, maps: inout IDMaps) -> UInt32 {
    if let existing = maps.uidToItem[path]?.first(where: { $0.value == itemID })?.key { return existing }
    let next = maps.nextUID[path] ?? 1
    maps.nextUID[path] = next + 1
    maps.uidToItem[path, default: [:]][next] = itemID
    return next
  }

  private func itemIDs(_ uids: [UInt32], in path: String) -> [String] {
    let map = loadMaps().uidToItem[path] ?? [:]
    return uids.compactMap { map[$0] }
  }

  public static func testConnection(account: MailAccount, credential: Credential) async throws {
    guard let endpoint = URL(string: account.ewsURL) else { throw MailError.server("The Exchange server address is invalid.") }
    _ = try await EWSClient(endpoint: endpoint, username: account.incoming.username, credential: credential).folders()
  }

  // MARK: - Folders

  public func cachedFolders() -> [RemoteFolder] { cache.folders(account: accountID) ?? [] }

  public func refreshFolders() async throws -> [RemoteFolder] {
    let (infos, rootID, distinguished) = try await connected().folders()
    let byID = Dictionary(uniqueKeysWithValues: infos.map { ($0.id, $0) })
    func path(_ info: EWSClient.FolderInfo) -> String {
      var components = [info.name.replacingOccurrences(of: "/", with: "-")]
      var parent = info.parentID
      while let id = parent, id != rootID, let next = byID[id] {
        components.insert(next.name.replacingOccurrences(of: "/", with: "-"), at: 0)
        parent = next.parentID
      }
      return components.joined(separator: "/")
    }
    let roles: [String: FolderRole] = [
      "inbox": .inbox, "drafts": .drafts, "sentitems": .sent, "deleteditems": .trash, "junkemail": .junk,
      "archive": .archive, "outbox": .outbox,
    ]
    var maps = loadMaps()
    var folders: [RemoteFolder] = []
    for info in infos {
      let folderPath = path(info)
      let role = distinguished.first { $0.value == info.id }.flatMap { roles[$0.key] } ?? .normal
      var folder = RemoteFolder(path: folderPath, delimiter: "/", attributes: [], role: role)
      folder.total = info.total
      folder.unseen = info.unread
      folders.append(folder)
      folderIDs[folderPath] = info.id
      maps.folders[folderPath] = info.id
    }
    saveMaps(maps)
    cache.saveFolders(folders, account: accountID)
    return folders
  }

  public func createFolder(_ name: String, parent: String?) async throws -> String {
    let parentID = try parent.map { try folderID($0) }
    _ = try await connected().createFolder(name, parentID: parentID)
    return parent.map { "\($0)/\(name)" } ?? name
  }

  public func renameFolder(_ path: String, to name: String) async throws {
    try await connected().renameFolder(try folderID(path), to: name)
  }

  public func deleteFolder(_ path: String) async throws {
    try await connected().deleteFolder(try folderID(path))
    cache.clearFolder(account: accountID, path: path)
  }

  public func emptyFolder(_ path: String) async throws {
    try await connected().emptyFolder(try folderID(path))
    cache.clearFolder(account: accountID, path: path)
  }

  // MARK: - Messages

  public func cachedMessages(in path: String) -> [MessageSummary] {
    cache.snapshot(account: accountID, path: path)?.messages ?? []
  }

  private func summaries(_ items: [EWSClient.ItemInfo], in path: String) -> [MessageSummary] {
    var maps = loadMaps()
    let result = items.map { item -> MessageSummary in
      var flags = Set<String>()
      if item.isRead { flags.insert(MessageFlag.seen) }
      if item.isFlagged { flags.insert(MessageFlag.flagged) }
      for category in item.categories { flags.insert(Self.keyword(category)) }
      var summary = MessageSummary(
        uid: uid(for: item.id, in: path, maps: &maps), subject: item.subject, from: item.from.map { [$0] } ?? [],
        to: item.displayTo.split(separator: ";").map { MailAddress(name: $0.trimmingCharacters(in: .whitespaces), email: "") },
        cc: [], date: item.sent ?? item.received, size: item.size, flags: flags, messageID: item.messageID,
        inReplyTo: item.inReplyTo, hasAttachment: item.hasAttachments, references: item.inReplyTo.map { [$0] } ?? [])
      summary.received = item.received
      summary.priority = item.importance == "High" ? 2 : item.importance == "Low" ? 4 : 0
      return summary
    }
    saveMaps(maps)
    return result
  }

  public func sync(path: String, limit: Int) async throws -> SyncResult {
    let previous = Set(cachedMessages(in: path).map(\.uid))
    let items = try await connected().items(in: try folderID(path), limit: limit)
    let messages = summaries(items, in: path)
    cache.saveSnapshot(FolderSnapshot(uidValidity: 1, messages: messages), account: accountID, path: path)
    let new = previous.isEmpty ? [] : messages.filter { !previous.contains($0.uid) && !$0.isRead }
    return SyncResult(messages: messages, newMessages: new)
  }

  public func message(uid: UInt32, in path: String) async throws -> Data {
    if let cached = cache.message(account: accountID, path: path, uid: uid) { return cached }
    guard let id = itemIDs([uid], in: path).first else { throw MailError.server("The message is no longer on the server.") }
    let data = try await connected().mimeContent(id)
    cache.saveMessage(data, account: accountID, path: path, uid: uid)
    return data
  }

  public func setFlags(_ flags: [String], on: Bool, uids: [UInt32], in path: String) async throws {
    let ids = itemIDs(uids, in: path)
    let client = try await connected()
    for flag in flags {
      switch flag {
      case MessageFlag.seen: try await client.setRead(on, items: ids)
      case MessageFlag.flagged: try await client.setFlagged(on, items: ids)
      default:
        let snapshot = cachedMessages(in: path)
        for uid in uids {
          guard let id = itemIDs([uid], in: path).first else { continue }
          var current = Set(snapshot.first { $0.uid == uid }?.flags.filter { $0.hasPrefix("$label") || !$0.hasPrefix("\\") && !$0.hasPrefix("$") } ?? [])
          if on { current.insert(flag) } else { current.remove(flag) }
          try await client.setCategories(current.map(Self.categoryName).sorted(), item: id)
        }
      }
    }
  }

  private func remap(_ uids: [UInt32], from source: String, to destination: String, newIDs: [String?]) -> [UInt32: UInt32] {
    var maps = loadMaps()
    var mapping: [UInt32: UInt32] = [:]
    for (uid, newID) in zip(uids, newIDs) {
      if let newID { mapping[uid] = self.uid(for: newID, in: destination, maps: &maps) }
    }
    saveMaps(maps)
    return mapping
  }

  public func move(uids: [UInt32], from source: String, to destination: String) async throws -> [UInt32: UInt32] {
    let ids = itemIDs(uids, in: source)
    let newIDs = try await connected().transfer(ids, to: try folderID(destination), copy: false)
    cache.removeMessages(account: accountID, path: source, uids: uids)
    return remap(uids, from: source, to: destination, newIDs: newIDs)
  }

  public func copy(uids: [UInt32], from source: String, to destination: String) async throws -> [UInt32: UInt32] {
    let ids = itemIDs(uids, in: source)
    let newIDs = try await connected().transfer(ids, to: try folderID(destination), copy: true)
    return remap(uids, from: source, to: destination, newIDs: newIDs)
  }

  public func delete(uids: [UInt32], in path: String) async throws {
    try await connected().delete(itemIDs(uids, in: path))
    cache.removeMessages(account: accountID, path: path, uids: uids)
  }

  public func append(_ message: Data, to path: String, flags: [String]) async throws {
    try await connected().save(
      message, in: try folderID(path), read: flags.contains(MessageFlag.seen), draft: flags.contains(MessageFlag.draft))
  }

  public func search(_ query: SearchQuery, in path: String, limit: Int) async throws -> [MessageSummary] {
    let text = query.text.trimmingCharacters(in: .whitespaces)
    let aqs: String =
      switch query.field {
      case .subject: "subject:\(text)"
      case .from: "from:\(text)"
      case .recipients: "to:\(text)"
      case .body: "body:\(text)"
      default: text
      }
    let items = try await connected().items(in: try folderID(path), limit: limit, query: text.isEmpty ? nil : aqs)
    return summaries(items, in: path).filter { query.matches($0, body: query.field == .body || query.field == .all ? text : nil) }
  }

  public func findMessage(messageID: String, in path: String) async throws -> [UInt32] {
    cachedMessages(in: path).filter { $0.messageID == messageID }.map(\.uid)
  }

  public func forgetCache(_ path: String) {
    cache.clearFolder(account: accountID, path: path)
  }

  public func send(_ message: Data) async throws {
    try await connected().send(message)
  }

  public func disconnect() async {
    client = nil
  }
}
