/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation

public enum ChatProtocol: String, Codable, Sendable, CaseIterable, Hashable {
  case irc, matrix, xmpp

  public var label: String {
    switch self {
    case .irc: "IRC"
    case .matrix: "Matrix"
    case .xmpp: "XMPP"
    }
  }
}

public struct ChatAccount: Codable, Sendable, Identifiable, Hashable {
  public var id = UUID()
  public var chatProtocol: ChatProtocol
  /// IRC nickname, Matrix user ID (@user:server) or XMPP JID (user@server).
  public var username: String
  /// IRC server, Matrix homeserver URL override or XMPP server override.
  public var server: String
  public var port: Int
  public var useTLS: Bool
  public var autoJoin: [String]
  public var connectOnStartup: Bool

  public init(
    chatProtocol: ChatProtocol, username: String, server: String = "", port: Int = 0, useTLS: Bool = true,
    autoJoin: [String] = []
  ) {
    self.chatProtocol = chatProtocol
    self.username = username
    self.server = server
    self.port = port
    self.useTLS = useTLS
    self.autoJoin = autoJoin
    self.connectOnStartup = true
  }

  public var title: String {
    switch chatProtocol {
    case .irc: "\(username)@\(server)"
    case .matrix, .xmpp: username
    }
  }

  public var keychainKey: String { "chat.\(id.uuidString)" }
}

public struct ChatMessage: Codable, Sendable, Identifiable, Hashable {
  public enum Kind: String, Codable, Sendable {
    case normal, action, system, notice
  }

  public var id: String
  public var conversationID: String
  public var sender: String
  public var text: String
  public var date: Date
  public var isOutgoing: Bool
  public var kind: Kind

  public init(
    id: String = UUID().uuidString, conversationID: String, sender: String, text: String, date: Date = Date(),
    isOutgoing: Bool = false, kind: Kind = .normal
  ) {
    self.id = id
    self.conversationID = conversationID
    self.sender = sender
    self.text = text
    self.date = date
    self.isOutgoing = isOutgoing
    self.kind = kind
  }
}

public struct ChatConversation: Codable, Sendable, Identifiable, Hashable {
  public var id: String
  public var title: String
  public var isGroup: Bool
  public var topic: String?
  public var participants: [String]
  public var isInvitation: Bool

  public init(id: String, title: String, isGroup: Bool, topic: String? = nil, participants: [String] = [], isInvitation: Bool = false) {
    self.id = id
    self.title = title
    self.isGroup = isGroup
    self.topic = topic
    self.participants = participants
    self.isInvitation = isInvitation
  }
}

public enum ChatEvent: Sendable {
  case connected(ownName: String)
  case disconnected(String?)
  case conversation(ChatConversation)
  case conversationRemoved(String)
  case message(ChatMessage)
  case participants(conversationID: String, names: [String])
  case topic(conversationID: String, topic: String)
}

public protocol ChatConnection: Sendable {
  var events: AsyncStream<ChatEvent> { get }
  func connect() async throws
  func send(_ text: String, to conversationID: String) async throws
  func join(_ name: String) async throws
  func leave(_ conversationID: String) async throws
  func disconnect() async
  func addContact(_ name: String) async throws
  func setAway(_ away: Bool) async throws
}

extension ChatConnection {
  public func addContact(_ name: String) async throws {}
  public func setAway(_ away: Bool) async throws {}
}

public enum ChatClients {
  public static func make(_ account: ChatAccount, secret: String) -> any ChatConnection {
    switch account.chatProtocol {
    case .irc: IRCClient(account: account, password: secret)
    case .matrix: MatrixClient(account: account, password: secret)
    case .xmpp: XMPPClient(account: account, password: secret)
    }
  }
}

// MARK: - IRC

public struct IRCLine: Sendable, Hashable {
  public var prefix: String?
  public var command: String
  public var params: [String]

  public var nick: String? {
    prefix.map { String($0.split(separator: "!").first ?? Substring($0)) }
  }

  public static func parse(_ raw: String) -> IRCLine? {
    var rest = Substring(raw)
    if rest.hasPrefix("@"), let space = rest.firstIndex(of: " ") {
      rest = rest[rest.index(after: space)...]
    }
    var prefix: String?
    if rest.hasPrefix(":"), let space = rest.firstIndex(of: " ") {
      prefix = String(rest[rest.index(after: rest.startIndex)..<space])
      rest = rest[rest.index(after: space)...]
    }
    var params: [String] = []
    var trailing: String?
    if let range = rest.range(of: " :") {
      trailing = String(rest[range.upperBound...])
      rest = rest[..<range.lowerBound]
    }
    let words = rest.split(separator: " ").map(String.init)
    guard let command = words.first else { return nil }
    params = Array(words.dropFirst())
    if let trailing { params.append(trailing) }
    return IRCLine(prefix: prefix, command: command.uppercased(), params: params)
  }
}

public actor IRCClient: ChatConnection {
  public nonisolated let events: AsyncStream<ChatEvent>
  private let continuation: AsyncStream<ChatEvent>.Continuation
  private let account: ChatAccount
  private let password: String
  private var connection: LineConnection?
  private var nick: String
  private var pendingNames: [String: [String]] = [:]
  private var readTask: Task<Void, Never>?
  static let serverConversation = ".server"

  public init(account: ChatAccount, password: String) {
    self.account = account
    self.password = password
    self.nick = account.username
    (events, continuation) = AsyncStream.makeStream()
  }

  private func write(_ line: String) async throws {
    try await connection?.write("\(line)\r\n")
  }

  public func connect() async throws {
    let port = account.port > 0 ? account.port : (account.useTLS ? 6697 : 6667)
    let connection = LineConnection(host: account.server, port: port, implicitTLS: account.useTLS, timeout: 600)
    self.connection = connection
    continuation.yield(.conversation(ChatConversation(id: Self.serverConversation, title: account.server, isGroup: false)))
    if !password.isEmpty {
      try await write("CAP REQ :sasl")
    }
    try await write("NICK \(nick)")
    try await write("USER \(account.username) 0 * :Zapdos")
    readTask = Task { await self.readLoop() }
  }

  private func readLoop() async {
    while let connection {
      do {
        let raw = String(decoding: try await connection.readLine(), as: UTF8.self)
        if let line = IRCLine.parse(raw) {
          try await handle(line)
        }
      } catch {
        if case MailError.timeout = error {
          try? await write("PING :keepalive")
          continue
        }
        self.connection = nil
        continuation.yield(.disconnected(error.localizedDescription))
        return
      }
    }
  }

  private func system(_ text: String, in conversation: String = IRCClient.serverConversation) {
    continuation.yield(.message(ChatMessage(conversationID: conversation, sender: "", text: text, kind: .system)))
  }

  private func handle(_ line: IRCLine) async throws {
    let params = line.params
    switch line.command {
    case "PING":
      try await write("PONG :\(params.last ?? "")")
    case "CAP":
      let subcommand = params.count >= 2 ? params[1].uppercased() : ""
      if subcommand == "ACK" {
        try await write("AUTHENTICATE PLAIN")
      } else if subcommand == "NAK" {
        try await write("CAP END")
      }
    case "AUTHENTICATE":
      guard params.first == "+" else { return }
      let token = Data("\(account.username)\0\(account.username)\0\(password)".utf8).base64EncodedString()
      try await write("AUTHENTICATE \(token)")
    case "903", "904", "905", "906", "907":
      if line.command != "903" { system("SASL authentication failed: \(params.last ?? "")") }
      try await write("CAP END")
    case "001":
      nick = params.first ?? nick
      continuation.yield(.connected(ownName: nick))
      for channel in account.autoJoin where !channel.isEmpty {
        try await write("JOIN \(channel)")
      }
    case "433":
      nick += "_"
      try await write("NICK \(nick)")
    case "JOIN":
      guard let channel = params.first else { return }
      if line.nick == nick {
        continuation.yield(.conversation(ChatConversation(id: channel, title: channel, isGroup: true)))
      } else {
        system("\(line.nick ?? "Someone") joined", in: channel)
      }
    case "PART", "KICK":
      guard let channel = params.first else { return }
      let target = line.command == "KICK" ? params.dropFirst().first : line.nick
      if target == nick {
        continuation.yield(.conversationRemoved(channel))
      } else {
        system("\(target ?? "Someone") left", in: channel)
      }
    case "PRIVMSG", "NOTICE":
      guard params.count >= 2, let sender = line.nick else {
        system(params.last ?? "")
        return
      }
      let target = params[0]
      var text = params[1]
      var kind: ChatMessage.Kind = line.command == "NOTICE" ? .notice : .normal
      if text.hasPrefix("\u{1}ACTION ") {
        text = String(text.dropFirst(8).dropLast(text.hasSuffix("\u{1}") ? 1 : 0))
        kind = .action
      } else if text.hasPrefix("\u{1}") {
        return
      }
      let isChannel = target.hasPrefix("#") || target.hasPrefix("&")
      let conversation = isChannel ? target : (sender.contains(".") && !sender.contains("!") ? IRCClient.serverConversation : sender)
      if !isChannel && conversation != IRCClient.serverConversation {
        continuation.yield(.conversation(ChatConversation(id: sender, title: sender, isGroup: false)))
      }
      continuation.yield(.message(ChatMessage(conversationID: conversation, sender: sender, text: text, kind: kind)))
    case "332":
      if params.count >= 3 { continuation.yield(.topic(conversationID: params[1], topic: params[2])) }
    case "TOPIC":
      if params.count >= 2 { continuation.yield(.topic(conversationID: params[0], topic: params[1])) }
    case "353":
      guard params.count >= 4 else { return }
      let names = params[3].split(separator: " ").map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "@+%~&")) }
      pendingNames[params[2], default: []] += names
    case "366":
      guard params.count >= 2 else { return }
      continuation.yield(.participants(conversationID: params[1], names: pendingNames[params[1]] ?? []))
      pendingNames[params[1]] = nil
    case "NICK":
      if line.nick == nick, let newNick = params.first { nick = newNick }
    case "ERROR":
      connection = nil
      continuation.yield(.disconnected(params.last))
    default:
      if Int(line.command) != nil, params.count >= 2 {
        system(params.dropFirst().joined(separator: " "))
      }
    }
  }

  public func send(_ text: String, to conversationID: String) async throws {
    if text.hasPrefix("/") {
      let parts = text.dropFirst().split(separator: " ", maxSplits: 1).map(String.init)
      let argument = parts.count > 1 ? parts[1] : ""
      switch parts.first?.lowercased() {
      case "join": try await join(argument)
      case "part", "leave": try await leave(argument.isEmpty ? conversationID : argument)
      case "nick": try await write("NICK \(argument)")
      case "topic": try await write("TOPIC \(conversationID) :\(argument)")
      case "me":
        try await write("PRIVMSG \(conversationID) :\u{1}ACTION \(argument)\u{1}")
        continuation.yield(.message(ChatMessage(conversationID: conversationID, sender: nick, text: argument, isOutgoing: true, kind: .action)))
      case "msg", "query":
        let target = argument.split(separator: " ", maxSplits: 1).map(String.init)
        guard let first = target.first else { return }
        continuation.yield(.conversation(ChatConversation(id: first, title: first, isGroup: false)))
        if target.count > 1 { try await send(target[1], to: first) }
      default: try await write(String(text.dropFirst()))
      }
      return
    }
    guard conversationID != IRCClient.serverConversation else {
      try await write(text)
      return
    }
    for line in text.components(separatedBy: .newlines) where !line.isEmpty {
      try await write("PRIVMSG \(conversationID) :\(line)")
      continuation.yield(.message(ChatMessage(conversationID: conversationID, sender: nick, text: line, isOutgoing: true)))
    }
  }

  public func setAway(_ away: Bool) async throws {
    try await write(away ? "AWAY :Away" : "AWAY")
  }

  public func addContact(_ name: String) async throws {
    continuation.yield(.conversation(ChatConversation(id: name, title: name, isGroup: false)))
  }

  public func join(_ name: String) async throws {
    let channel = name.hasPrefix("#") || name.hasPrefix("&") ? name : "#\(name)"
    try await write("JOIN \(channel)")
  }

  public func leave(_ conversationID: String) async throws {
    if conversationID.hasPrefix("#") || conversationID.hasPrefix("&") {
      try await write("PART \(conversationID)")
    } else {
      continuation.yield(.conversationRemoved(conversationID))
    }
  }

  public func disconnect() async {
    try? await write("QUIT :Zapdos")
    readTask?.cancel()
    await connection?.close()
    connection = nil
    continuation.yield(.disconnected(nil))
  }
}

// MARK: - Matrix

public actor MatrixClient: ChatConnection {
  public nonisolated let events: AsyncStream<ChatEvent>
  private let continuation: AsyncStream<ChatEvent>.Continuation
  private let account: ChatAccount
  private let password: String
  private var homeserver: URL?
  private var accessToken: String?
  private var userID = ""
  private var since: String?
  private var syncTask: Task<Void, Never>?
  private var displayNames: [String: [String: String]] = [:]
  private var roomNames: [String: String] = [:]

  public init(account: ChatAccount, password: String) {
    self.account = account
    self.password = password
    (events, continuation) = AsyncStream.makeStream()
  }

  private func discoverHomeserver() async throws -> URL {
    if !account.server.isEmpty {
      return URL(string: account.server.hasPrefix("http") ? account.server : "https://\(account.server)")!
    }
    guard let domain = account.username.split(separator: ":", maxSplits: 1).last.map(String.init),
      account.username.contains(":")
    else { throw MailError.server("Enter a full Matrix ID such as @you:matrix.org.") }
    struct WellKnown: Decodable {
      struct Homeserver: Decodable { var base_url: String }
      var homeserver: Homeserver
      enum CodingKeys: String, CodingKey { case homeserver = "m.homeserver" }
    }
    if let url = URL(string: "https://\(domain)/.well-known/matrix/client"),
      let (data, _) = try? await URLSession.shared.data(from: url),
      let known = try? JSONDecoder().decode(WellKnown.self, from: data),
      let base = URL(string: known.homeserver.base_url)
    {
      return base
    }
    return URL(string: "https://\(domain)")!
  }

  private func request(_ method: String, _ path: String, body: [String: Any]? = nil, query: [URLQueryItem] = [], timeout: TimeInterval = 60) async throws -> [String: Any] {
    guard let homeserver else { throw MailError.connectionClosed }
    var components = URLComponents(url: homeserver.appending(path: path), resolvingAgainstBaseURL: false)!
    if !query.isEmpty { components.queryItems = query }
    var request = URLRequest(url: components.url!, timeoutInterval: timeout)
    request.httpMethod = method
    if let accessToken { request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      let message = json["error"] as? String ?? "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"
      throw (response as? HTTPURLResponse)?.statusCode == 403
        ? MailError.authenticationFailed(message) : MailError.server(message)
    }
    return json
  }

  public func connect() async throws {
    homeserver = try await discoverHomeserver()
    let localpart = account.username.hasPrefix("@")
      ? String(account.username.dropFirst().split(separator: ":").first ?? "") : account.username
    let login = try await request(
      "POST", "_matrix/client/v3/login",
      body: [
        "type": "m.login.password",
        "identifier": ["type": "m.id.user", "user": localpart],
        "password": password,
        "initial_device_display_name": "Zapdos",
      ])
    accessToken = login["access_token"] as? String
    userID = login["user_id"] as? String ?? account.username
    continuation.yield(.connected(ownName: userID))
    syncTask = Task { await self.syncLoop() }
  }

  private func syncLoop() async {
    let filter = #"{"room":{"timeline":{"limit":30},"state":{"lazy_load_members":true}}}"#
    while !Task.isCancelled, accessToken != nil {
      do {
        var query = [URLQueryItem(name: "timeout", value: "30000"), URLQueryItem(name: "filter", value: filter)]
        if let since { query.append(URLQueryItem(name: "since", value: since)) }
        let response = try await request("GET", "_matrix/client/v3/sync", query: query, timeout: 90)
        let isInitial = since == nil
        since = response["next_batch"] as? String
        process(response, initial: isInitial)
      } catch {
        if Task.isCancelled { return }
        if case MailError.authenticationFailed = error {
          continuation.yield(.disconnected(error.localizedDescription))
          return
        }
        try? await Task.sleep(for: .seconds(5))
      }
    }
  }

  private func process(_ response: [String: Any], initial: Bool) {
    let rooms = response["rooms"] as? [String: Any] ?? [:]
    for (roomID, value) in rooms["join"] as? [String: [String: Any]] ?? [:] {
      let stateEvents = ((value["state"] as? [String: Any])?["events"] as? [[String: Any]]) ?? []
      let timeline = ((value["timeline"] as? [String: Any])?["events"] as? [[String: Any]]) ?? []
      for event in stateEvents + timeline {
        applyState(event, room: roomID)
      }
      let summary = value["summary"] as? [String: Any]
      let memberCount = summary?["m.joined_member_count"] as? Int ?? displayNames[roomID]?.count ?? 0
      let heroes = (summary?["m.heroes"] as? [String] ?? []).map { displayNames[roomID]?[$0] ?? $0 }
      let title = roomNames[roomID] ?? (heroes.isEmpty ? roomID : heroes.joined(separator: ", "))
      continuation.yield(
        .conversation(ChatConversation(id: roomID, title: title, isGroup: memberCount > 2)))
      for event in timeline where event["type"] as? String == "m.room.message" || event["type"] as? String == "m.room.encrypted" {
        guard let sender = event["sender"] as? String else { continue }
        let content = event["content"] as? [String: Any] ?? [:]
        let encrypted = event["type"] as? String == "m.room.encrypted"
        let msgtype = content["msgtype"] as? String
        let text = encrypted ? "[Encrypted message: end-to-end encryption isn't supported yet]" : (content["body"] as? String ?? "")
        let timestamp = (event["origin_server_ts"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
        continuation.yield(
          .message(
            ChatMessage(
              id: event["event_id"] as? String ?? UUID().uuidString, conversationID: roomID,
              sender: displayNames[roomID]?[sender] ?? sender, text: text, date: timestamp,
              isOutgoing: sender == userID,
              kind: encrypted ? .system : (msgtype == "m.emote" ? .action : msgtype == "m.notice" ? .notice : .normal))))
      }
      if let names = displayNames[roomID] {
        continuation.yield(.participants(conversationID: roomID, names: names.values.sorted()))
      }
    }
    for (roomID, value) in rooms["invite"] as? [String: [String: Any]] ?? [:] {
      let events = ((value["invite_state"] as? [String: Any])?["events"] as? [[String: Any]]) ?? []
      for event in events { applyState(event, room: roomID) }
      continuation.yield(
        .conversation(ChatConversation(id: roomID, title: roomNames[roomID] ?? roomID, isGroup: true, isInvitation: true)))
    }
    for roomID in (rooms["leave"] as? [String: Any] ?? [:]).keys {
      continuation.yield(.conversationRemoved(roomID))
    }
  }

  private func applyState(_ event: [String: Any], room: String) {
    let content = event["content"] as? [String: Any] ?? [:]
    switch event["type"] as? String {
    case "m.room.name":
      if let name = content["name"] as? String, !name.isEmpty { roomNames[room] = name }
    case "m.room.canonical_alias":
      if roomNames[room] == nil, let alias = content["alias"] as? String { roomNames[room] = alias }
    case "m.room.topic":
      if let topic = content["topic"] as? String { continuation.yield(.topic(conversationID: room, topic: topic)) }
    case "m.room.member":
      guard let member = event["state_key"] as? String else { return }
      if content["membership"] as? String == "join" {
        displayNames[room, default: [:]][member] = content["displayname"] as? String ?? member
      } else {
        displayNames[room]?[member] = nil
      }
    default:
      break
    }
  }

  public func send(_ text: String, to conversationID: String) async throws {
    var body: [String: Any] = ["msgtype": "m.text", "body": text]
    if text.hasPrefix("/me ") {
      body = ["msgtype": "m.emote", "body": String(text.dropFirst(4))]
    } else if text.hasPrefix("/join ") {
      try await join(String(text.dropFirst(6)))
      return
    }
    let room = conversationID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? conversationID
    _ = try await request("PUT", "_matrix/client/v3/rooms/\(room)/send/m.room.message/\(UUID().uuidString)", body: body)
  }

  public func setAway(_ away: Bool) async throws {
    let user = userID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? userID
    _ = try await request("PUT", "_matrix/client/v3/presence/\(user)/status", body: ["presence": away ? "unavailable" : "online"])
  }

  /// Starts a direct conversation by creating a room and inviting the user.
  public func addContact(_ name: String) async throws {
    _ = try await request("POST", "_matrix/client/v3/createRoom", body: ["is_direct": true, "invite": [name], "preset": "trusted_private_chat"])
  }

  public func join(_ name: String) async throws {
    let target = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name
    _ = try await request("POST", "_matrix/client/v3/join/\(target)", body: [:])
  }

  public func leave(_ conversationID: String) async throws {
    let room = conversationID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? conversationID
    _ = try await request("POST", "_matrix/client/v3/rooms/\(room)/leave", body: [:])
    continuation.yield(.conversationRemoved(conversationID))
  }

  public func disconnect() async {
    syncTask?.cancel()
    if accessToken != nil {
      _ = try? await request("POST", "_matrix/client/v3/logout", body: [:])
    }
    accessToken = nil
    continuation.yield(.disconnected(nil))
  }
}

// MARK: - XMPP

/// Splits an XMPP stream into complete top-level stanzas.
struct XMPPStanzaSplitter {
  private var buffer = ""

  mutating func append(_ text: String) -> [String] {
    buffer += text
    var stanzas: [String] = []
    while let stanza = nextStanza() {
      stanzas.append(stanza)
    }
    return stanzas
  }

  private mutating func nextStanza() -> String? {
    var index = buffer.startIndex
    while index < buffer.endIndex, buffer[index].isWhitespace {
      index = buffer.index(after: index)
    }
    buffer.removeSubrange(buffer.startIndex..<index)
    guard buffer.first == "<" else { return nil }
    if buffer.hasPrefix("<?") {
      guard let end = buffer.range(of: "?>") else { return nil }
      buffer.removeSubrange(buffer.startIndex..<end.upperBound)
      return nextStanza()
    }
    if buffer.hasPrefix("<stream:stream") {
      guard let end = buffer.firstIndex(of: ">") else { return nil }
      let header = String(buffer[...end])
      buffer.removeSubrange(...end)
      return header
    }
    if buffer.hasPrefix("</stream:stream") {
      buffer.removeAll()
      return "</stream:stream>"
    }
    var depth = 0
    var cursor = buffer.startIndex
    var quote: Character?
    var tagStart: String.Index?
    while cursor < buffer.endIndex {
      let char = buffer[cursor]
      if let current = quote {
        if char == current { quote = nil }
      } else if tagStart != nil {
        if char == "\"" || char == "'" {
          quote = char
        } else if char == ">" {
          let tag = buffer[tagStart!...cursor]
          if tag.hasPrefix("</") {
            depth -= 1
          } else if !tag.hasSuffix("/>") {
            depth += 1
          }
          tagStart = nil
          if depth == 0 {
            let stanza = String(buffer[...cursor])
            buffer.removeSubrange(...cursor)
            return stanza
          }
        }
      } else if char == "<" {
        tagStart = cursor
      }
      cursor = buffer.index(after: cursor)
    }
    return nil
  }
}

public actor XMPPClient: ChatConnection {
  public nonisolated let events: AsyncStream<ChatEvent>
  private let continuation: AsyncStream<ChatEvent>.Continuation
  private let account: ChatAccount
  private let password: String
  private var connection: LineConnection?
  private var splitter = XMPPStanzaSplitter()
  private var queued: [XMLElement] = []
  private var jid = ""
  private var readTask: Task<Void, Never>?
  private var rooms: Set<String> = []

  public init(account: ChatAccount, password: String) {
    self.account = account
    self.password = password
    (events, continuation) = AsyncStream.makeStream()
  }

  private var domain: String { String(account.username.split(separator: "@").last ?? "") }
  private var localpart: String { String(account.username.split(separator: "@").first ?? "") }

  private func send(raw: String) async throws {
    try await connection?.write(raw)
  }

  private func openStream() async throws {
    try await send(
      raw:
        "<?xml version='1.0'?><stream:stream to='\(domain)' xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams' version='1.0'>"
    )
  }

  private func nextElement() async throws -> XMLElement {
    while queued.isEmpty {
      guard let connection else { throw MailError.connectionClosed }
      let chunk = String(decoding: try await connection.readChunk(), as: UTF8.self)
      for stanza in splitter.append(chunk) {
        if stanza.hasPrefix("<stream:stream") { continue }
        if stanza.hasPrefix("</stream:stream") { throw MailError.connectionClosed }
        let normalized = stanza.replacingOccurrences(of: "<stream:", with: "<stream_")
          .replacingOccurrences(of: "</stream:", with: "</stream_")
        if let element = try? XMLElement(xmlString: normalized) {
          queued.append(element)
        }
      }
    }
    return queued.removeFirst()
  }

  private func waitFor(_ name: String) async throws -> XMLElement {
    while true {
      let element = try await nextElement()
      if element.name == name || element.localName == name { return element }
      if element.localName == "failure" || element.name == "stream_error" {
        throw MailError.authenticationFailed(element.xmlString)
      }
    }
  }

  public func connect() async throws {
    let host = account.server.isEmpty ? domain : account.server
    let directTLS = account.useTLS && account.port == 5223
    let connection = LineConnection(
      host: host, port: account.port > 0 ? account.port : 5222, implicitTLS: directTLS, timeout: 600)
    self.connection = connection
    try await openStream()
    var features = try await waitFor("stream_features")
    if !directTLS, features.elements(forName: "starttls").isEmpty == false {
      try await send(raw: "<starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>")
      _ = try await waitFor("proceed")
      await connection.startTLS()
      splitter = XMPPStanzaSplitter()
      try await openStream()
      features = try await waitFor("stream_features")
    } else if account.useTLS && !directTLS {
      throw MailError.server("The server doesn't offer an encrypted connection.")
    }
    let token = Data("\0\(localpart)\0\(password)".utf8).base64EncodedString()
    try await send(raw: "<auth xmlns='urn:ietf:params:xml:ns:xmpp-sasl' mechanism='PLAIN'>\(token)</auth>")
    _ = try await waitFor("success")
    splitter = XMPPStanzaSplitter()
    try await openStream()
    _ = try await waitFor("stream_features")
    try await send(
      raw: "<iq type='set' id='bind'><bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'><resource>Zapdos</resource></bind></iq>")
    let bound = try await waitFor("iq")
    jid = bound.elements(forName: "bind").first?.elements(forName: "jid").first?.stringValue ?? account.username
    try await send(raw: "<iq type='get' id='roster'><query xmlns='jabber:iq:roster'/></iq>")
    try await send(raw: "<presence/>")
    continuation.yield(.connected(ownName: jid))
    for room in account.autoJoin where !room.isEmpty {
      try await join(room)
    }
    readTask = Task { await self.readLoop() }
  }

  private func readLoop() async {
    while connection != nil {
      do {
        handle(try await nextElement())
      } catch {
        if case MailError.timeout = error {
          try? await send(raw: " ")
          continue
        }
        connection = nil
        continuation.yield(.disconnected(error.localizedDescription))
        return
      }
    }
  }

  private static func bare(_ jid: String) -> String {
    String(jid.split(separator: "/").first ?? Substring(jid))
  }

  private func handle(_ element: XMLElement) {
    switch element.localName {
    case "iq":
      if let query = element.elements(forName: "query").first {
        for item in query.elements(forName: "item") {
          guard let contact = item.attribute(forName: "jid")?.stringValue else { continue }
          let name = item.attribute(forName: "name")?.stringValue ?? contact
          continuation.yield(.conversation(ChatConversation(id: contact, title: name, isGroup: false)))
        }
      }
    case "message":
      guard let from = element.attribute(forName: "from")?.stringValue,
        let body = element.elements(forName: "body").first?.stringValue
      else { return }
      let type = element.attribute(forName: "type")?.stringValue ?? "chat"
      if type == "groupchat" {
        let room = Self.bare(from)
        let nick = from.split(separator: "/", maxSplits: 1).dropFirst().first.map(String.init) ?? room
        let isDelayed = !element.elements(forName: "delay").isEmpty
        continuation.yield(
          .message(
            ChatMessage(
              conversationID: room, sender: nick, text: body, isOutgoing: nick == localpart && !isDelayed,
              kind: body.hasPrefix("/me ") ? .action : .normal)))
        if let subject = element.elements(forName: "subject").first?.stringValue {
          continuation.yield(.topic(conversationID: room, topic: subject))
        }
      } else {
        let contact = Self.bare(from)
        continuation.yield(.conversation(ChatConversation(id: contact, title: contact, isGroup: false)))
        continuation.yield(.message(ChatMessage(conversationID: contact, sender: contact, text: body)))
      }
    case "presence":
      guard let from = element.attribute(forName: "from")?.stringValue else { return }
      let room = Self.bare(from)
      if rooms.contains(room), let nick = from.split(separator: "/", maxSplits: 1).dropFirst().first {
        let unavailable = element.attribute(forName: "type")?.stringValue == "unavailable"
        continuation.yield(
          .message(
            ChatMessage(conversationID: room, sender: "", text: "\(nick) \(unavailable ? "left" : "is here")", kind: .system)))
      }
    default:
      break
    }
  }

  private static func escape(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "'", with: "&apos;")
  }

  public func send(_ text: String, to conversationID: String) async throws {
    if text.hasPrefix("/join ") {
      try await join(String(text.dropFirst(6)))
      return
    }
    let isRoom = rooms.contains(conversationID)
    try await send(
      raw:
        "<message to='\(Self.escape(conversationID))' type='\(isRoom ? "groupchat" : "chat")' id='\(UUID().uuidString)'><body>\(Self.escape(text))</body></message>"
    )
    if !isRoom {
      continuation.yield(
        .message(ChatMessage(conversationID: conversationID, sender: localpart, text: text, isOutgoing: true)))
    }
  }

  public func setAway(_ away: Bool) async throws {
    try await send(raw: away ? "<presence><show>away</show></presence>" : "<presence/>")
  }

  /// Adds the contact to the roster and asks to see their presence.
  public func addContact(_ name: String) async throws {
    let jid = Self.escape(Self.bare(name))
    try await send(raw: "<iq type='set' id='\(UUID().uuidString)'><query xmlns='jabber:iq:roster'><item jid='\(jid)'/></query></iq>")
    try await send(raw: "<presence to='\(jid)' type='subscribe'/>")
    continuation.yield(.conversation(ChatConversation(id: Self.bare(name), title: Self.bare(name), isGroup: false)))
  }

  public func join(_ name: String) async throws {
    let room = Self.bare(name)
    rooms.insert(room)
    continuation.yield(.conversation(ChatConversation(id: room, title: room, isGroup: true)))
    try await send(
      raw: "<presence to='\(Self.escape(room))/\(Self.escape(localpart))'><x xmlns='http://jabber.org/protocol/muc'/></presence>")
  }

  public func leave(_ conversationID: String) async throws {
    if rooms.remove(conversationID) != nil {
      try await send(raw: "<presence to='\(Self.escape(conversationID))/\(Self.escape(localpart))' type='unavailable'/>")
    }
    continuation.yield(.conversationRemoved(conversationID))
  }

  public func disconnect() async {
    try? await send(raw: "<presence type='unavailable'/></stream:stream>")
    readTask?.cancel()
    await connection?.close()
    connection = nil
    continuation.yield(.disconnected(nil))
  }
}
