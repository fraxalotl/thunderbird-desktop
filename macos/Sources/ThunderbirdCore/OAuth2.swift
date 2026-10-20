/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import AppKit
import CryptoKit
import Foundation
import Network

/// Endpoint and scope details for the OAuth2 issuers Thunderbird supports
/// (mirrors mailnews/base/src/OAuth2Providers.sys.mjs). Client registrations
/// are not included: register your own application with each provider and add
/// its client ID in Settings.
public struct OAuth2Provider: Sendable, Hashable, Identifiable {
  public var issuer: String
  public var name: String
  public var authorizationEndpoint: String
  public var tokenEndpoint: String
  public var scope: String
  public var hostSuffixes: [String]
  public var redirectHost: String
  public var id: String { issuer }

  public static let all: [OAuth2Provider] = [
    OAuth2Provider(
      issuer: "accounts.google.com", name: "Google",
      authorizationEndpoint: "https://accounts.google.com/o/oauth2/auth",
      tokenEndpoint: "https://www.googleapis.com/oauth2/v3/token",
      scope: "https://mail.google.com/ https://www.googleapis.com/auth/carddav https://www.googleapis.com/auth/calendar",
      hostSuffixes: ["gmail.com", "googlemail.com"], redirectHost: "localhost"),
    OAuth2Provider(
      issuer: "login.microsoftonline.com", name: "Microsoft",
      authorizationEndpoint: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize",
      tokenEndpoint: "https://login.microsoftonline.com/common/oauth2/v2.0/token",
      scope:
        "https://outlook.office.com/IMAP.AccessAsUser.All https://outlook.office.com/POP.AccessAsUser.All https://outlook.office.com/SMTP.Send offline_access",
      hostSuffixes: ["office365.com", "outlook.com", "hotmail.com"], redirectHost: "localhost"),
    OAuth2Provider(
      issuer: "www.fastmail.com", name: "Fastmail",
      authorizationEndpoint: "https://api.fastmail.com/oauth/authorize",
      tokenEndpoint: "https://api.fastmail.com/oauth/refresh",
      scope:
        "https://www.fastmail.com/dev/protocol-imap https://www.fastmail.com/dev/protocol-pop https://www.fastmail.com/dev/protocol-smtp",
      hostSuffixes: ["fastmail.com"], redirectHost: "localhost"),
    OAuth2Provider(
      issuer: "login.yahoo.com", name: "Yahoo",
      authorizationEndpoint: "https://api.login.yahoo.com/oauth2/request_auth",
      tokenEndpoint: "https://api.login.yahoo.com/oauth2/get_token",
      scope: "mail-w ycal-w sdct-w", hostSuffixes: ["yahoo.com", "att.net"], redirectHost: "127.0.0.1"),
    OAuth2Provider(
      issuer: "login.aol.com", name: "AOL",
      authorizationEndpoint: "https://api.login.aol.com/oauth2/request_auth",
      tokenEndpoint: "https://api.login.aol.com/oauth2/get_token",
      scope: "mail-w ycal-w sdct-w", hostSuffixes: ["aol.com"], redirectHost: "127.0.0.1"),
    OAuth2Provider(
      issuer: "oauth.yandex.com", name: "Yandex",
      authorizationEndpoint: "https://oauth.yandex.com/authorize",
      tokenEndpoint: "https://oauth.yandex.com/token",
      scope: "mail:imap_full mail:smtp", hostSuffixes: ["yandex.com"], redirectHost: "localhost"),
    OAuth2Provider(
      issuer: "comcast.net", name: "Comcast",
      authorizationEndpoint: "https://oauth.xfinity.com/oauth/authorize",
      tokenEndpoint: "https://oauth.xfinity.com/oauth/token",
      scope: "https://email.comcast.net/ profile openid", hostSuffixes: ["comcast.net"], redirectHost: "localhost"),
    OAuth2Provider(
      issuer: "auth.tb.pro", name: "Thundermail",
      authorizationEndpoint: "https://auth.tb.pro/realms/tbpro/protocol/openid-connect/auth",
      tokenEndpoint: "https://auth.tb.pro/realms/tbpro/protocol/openid-connect/token",
      scope: "openid profile email offline_access", hostSuffixes: ["thundermail.com"], redirectHost: "localhost"),
  ]

  public static func forHost(_ host: String) -> OAuth2Provider? {
    let host = host.lowercased()
    return all.first { provider in
      provider.hostSuffixes.contains { host == $0 || host.hasSuffix(".\($0)") }
    }
  }
}

public struct OAuth2Client: Codable, Sendable, Hashable {
  public var clientID: String
  public var clientSecret: String

  public init(clientID: String, clientSecret: String = "") {
    self.clientID = clientID
    self.clientSecret = clientSecret
  }
}

/// The user's own OAuth application registrations, keyed by issuer.
public enum OAuth2ClientRegistry {
  static let defaultsKey = "oauthClients"

  public static func all() -> [String: OAuth2Client] {
    guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return [:] }
    return (try? JSONDecoder().decode([String: OAuth2Client].self, from: data)) ?? [:]
  }

  public static func client(for issuer: String) -> OAuth2Client? {
    all()[issuer].flatMap { $0.clientID.isEmpty ? nil : $0 }
  }

  public static func set(_ client: OAuth2Client?, for issuer: String) {
    var clients = all()
    clients[issuer] = client
    if let data = try? JSONEncoder().encode(clients) {
      UserDefaults.standard.set(data, forKey: defaultsKey)
    }
  }
}

public enum Credential: Sendable {
  case password(String)
  case oauth(String)

  /// The SASL XOAUTH2 initial response.
  public func xoauth2(user: String) -> String? {
    guard case .oauth(let token) = self else { return nil }
    return Data("user=\(user)\u{1}auth=Bearer \(token)\u{1}\u{1}".utf8).base64EncodedString()
  }
}

public enum Credentials {
  public static func oauthKey(for keychainKey: String) -> String {
    "\(keychainKey.split(separator: ".").first ?? Substring(keychainKey)).oauth"
  }

  public static func resolve(_ server: ServerConfig, key: String, interactive: Bool = false) async throws -> Credential {
    switch server.auth {
    case .password:
      guard let password = Keychain.password(for: key) else { throw MailError.missingPassword(server.host) }
      return .password(password)
    case .oauth2:
      let token = try await OAuth2Manager.shared.accessToken(
        host: server.host, username: server.username, key: oauthKey(for: key), interactive: interactive)
      return .oauth(token)
    }
  }
}

public actor OAuth2Manager {
  public static let shared = OAuth2Manager()

  private struct CachedToken {
    var value: String
    var expiry: Date
  }

  private var cache: [String: CachedToken] = [:]

  public func accessToken(host: String, username: String, key: String, interactive: Bool) async throws -> String {
    if let cached = cache[key], cached.expiry > Date().addingTimeInterval(60) {
      return cached.value
    }
    guard let provider = OAuth2Provider.forHost(host) else {
      throw MailError.unsupported("OAuth2 for \(host)")
    }
    guard let client = OAuth2ClientRegistry.client(for: provider.issuer) else {
      throw MailError.server("Add your \(provider.name) OAuth client ID in Settings › Accounts › OAuth Applications.")
    }
    if let refresh = Keychain.password(for: key) {
      do {
        return try store(try await refreshToken(refresh, provider: provider, client: client), key: key)
      } catch {
        if !interactive { throw MailError.needsSignIn(host) }
      }
    }
    guard interactive else { throw MailError.needsSignIn(host) }
    return try store(try await authorize(provider: provider, client: client, loginHint: username), key: key)
  }

  public func signOut(key: String) {
    cache[key] = nil
    Keychain.deletePassword(for: key)
  }

  private struct TokenResponse: Decodable {
    var access_token: String
    var refresh_token: String?
    var expires_in: Double?
  }

  private func store(_ response: TokenResponse, key: String) throws -> String {
    if let refresh = response.refresh_token {
      try Keychain.setPassword(refresh, for: key)
    }
    cache[key] = CachedToken(value: response.access_token, expiry: Date().addingTimeInterval(response.expires_in ?? 3600))
    return response.access_token
  }

  private func refreshToken(_ refresh: String, provider: OAuth2Provider, client: OAuth2Client) async throws -> TokenResponse {
    var form = ["grant_type": "refresh_token", "refresh_token": refresh, "client_id": client.clientID]
    if !client.clientSecret.isEmpty { form["client_secret"] = client.clientSecret }
    return try await tokenRequest(provider.tokenEndpoint, form: form)
  }

  private func tokenRequest(_ endpoint: String, form: [String: String]) async throws -> TokenResponse {
    guard let url = URL(string: endpoint) else { throw MailError.protocolError(endpoint) }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = Data(Self.formEncode(form).utf8)
    let (data, response) = try await URLSession.shared.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      throw MailError.authenticationFailed(String(decoding: data, as: UTF8.self))
    }
    return try JSONDecoder().decode(TokenResponse.self, from: data)
  }

  static func formEncode(_ form: [String: String]) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return form.sorted { $0.key < $1.key }.map { key, value in
      "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
    }.joined(separator: "&")
  }

  static func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private func authorize(provider: OAuth2Provider, client: OAuth2Client, loginHint: String) async throws -> TokenResponse {
    let verifier = Self.base64URL(Data((0..<48).map { _ in UInt8.random(in: 0...255) }))
    let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    let state = UUID().uuidString
    let receiver = try await LoopbackReceiver.start()
    let redirect = "http://\(provider.redirectHost):\(receiver.port)/"

    var components = URLComponents(string: provider.authorizationEndpoint)!
    components.queryItems = [
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "client_id", value: client.clientID),
      URLQueryItem(name: "redirect_uri", value: redirect),
      URLQueryItem(name: "scope", value: provider.scope),
      URLQueryItem(name: "state", value: state),
      URLQueryItem(name: "code_challenge", value: challenge),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
      URLQueryItem(name: "login_hint", value: loginHint),
      URLQueryItem(name: "access_type", value: "offline"),
      URLQueryItem(name: "prompt", value: "consent"),
    ]
    guard let url = components.url else { throw MailError.protocolError(provider.authorizationEndpoint) }
    await MainActor.run { _ = NSWorkspace.shared.open(url) }

    let query = try await receiver.waitForRedirect()
    guard query["state"] == state else { throw MailError.authenticationFailed("The sign-in response didn't match.") }
    guard let code = query["code"] else {
      throw MailError.authenticationFailed(query["error_description"] ?? query["error"] ?? "Sign-in was cancelled.")
    }
    var form = [
      "grant_type": "authorization_code", "code": code, "redirect_uri": redirect,
      "client_id": client.clientID, "code_verifier": verifier,
    ]
    if !client.clientSecret.isEmpty { form["client_secret"] = client.clientSecret }
    return try await tokenRequest(provider.tokenEndpoint, form: form)
  }
}

final class OnceFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var done = false

  func claim() -> Bool {
    lock.withLock {
      defer { done = true }
      return !done
    }
  }
}

/// A one-shot local HTTP listener that receives the OAuth authorization redirect.
final class LoopbackReceiver: @unchecked Sendable {
  private let listener: NWListener
  private let queue = DispatchQueue(label: "oauth.loopback")
  private var continuation: CheckedContinuation<[String: String], Error>?
  private var finished = false
  private var pending: [String: String]?
  let port: UInt16

  private init(listener: NWListener, port: UInt16) {
    self.listener = listener
    self.port = port
  }

  static func start() async throws -> LoopbackReceiver {
    let parameters = NWParameters.tcp
    parameters.acceptLocalOnly = true
    let listener = try NWListener(using: parameters)
    let queue = DispatchQueue(label: "oauth.loopback.start")
    let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
      let once = OnceFlag()
      listener.stateUpdateHandler = { state in
        switch state {
        case .ready:
          if once.claim() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
        case .failed(let error):
          if once.claim() { continuation.resume(throwing: error) }
        default:
          break
        }
      }
      listener.newConnectionHandler = { _ in }
      listener.start(queue: queue)
    }
    let receiver = LoopbackReceiver(listener: listener, port: port)
    listener.newConnectionHandler = { [receiver] connection in receiver.handle(connection) }
    return receiver
  }

  func waitForRedirect(timeout: Duration = .seconds(300)) async throws -> [String: String] {
    try await withThrowingTaskGroup(of: [String: String].self) { group in
      group.addTask {
        try await withCheckedThrowingContinuation { continuation in
          self.queue.async {
            if let pending = self.pending {
              continuation.resume(returning: pending)
            } else {
              self.continuation = continuation
            }
          }
        }
      }
      group.addTask {
        try await Task.sleep(for: timeout)
        throw MailError.timeout
      }
      defer {
        group.cancelAll()
        listener.cancel()
      }
      let result = try await group.next()!
      return result
    }
  }

  private func handle(_ connection: NWConnection) {
    connection.start(queue: queue)
    connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [self] data, _, _, _ in
      let request = String(decoding: data ?? Data(), as: UTF8.self)
      let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
      let items = URLComponents(string: "http://localhost\(target)")?.queryItems ?? []
      let query = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
      let page = """
        <!doctype html><meta charset=utf-8><title>Thunderbird</title>
        <body style="font:16px -apple-system;text-align:center;padding-top:20vh">
        <h2>You're signed in.</h2><p>You can close this tab and return to Thunderbird.</p></body>
        """
      let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n\(page)"
      connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
      guard !query.isEmpty, !finished else { return }
      finished = true
      queue.async { [self] in
        if let continuation {
          continuation.resume(returning: query)
          self.continuation = nil
        } else {
          pending = query
        }
      }
    }
  }
}
