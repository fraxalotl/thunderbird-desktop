/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation

public struct DiscoveredConfig: Sendable, Hashable {
  public enum Source: String, Sendable {
    case provider = "your email provider"
    case wellKnown = "your email provider's well-known address"
    case ispdb = "the Thunderbird ISP database"
    case mx = "your domain's mail server (MX) records"
    case protonBridge = "Proton Mail Bridge"
    case probe = "the mail servers at your domain"
    case guess = "common server names"
  }

  public var incoming: ServerConfig
  public var outgoing: ServerConfig
  public var providerName: String?
  public var source: Source
  public var requiresOAuth: Bool
  /// Extra guidance for the user, such as which password to use.
  public var note: String? = nil
}

/// Looks up server settings the same way Thunderbird's account hub does.
public enum Autoconfig {
  /// Tries, in order: the provider's own autoconfig, its well-known URL, the ISP database, the
  /// same three keyed by the domain's MX host, then probing common server names.
  public static func discover(email: String) async -> DiscoveredConfig {
    let parts = email.split(separator: "@", maxSplits: 1)
    guard parts.count == 2 else { return guess(email: email, domain: "") }
    let domain = parts[1].lowercased()
    let encodedEmail = email.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? email
    let direct: [(DiscoveredConfig.Source, String)] = [
      (.provider, "https://autoconfig.\(domain)/mail/config-v1.1.xml?emailaddress=\(encodedEmail)"),
      (.wellKnown, "https://\(domain)/.well-known/autoconfig/mail/config-v1.1.xml?emailaddress=\(encodedEmail)"),
      (.ispdb, "https://autoconfig.thunderbird.net/v1.1/\(domain)"),
    ]
    if let config = await firstConfig(direct, email: email) {
      return finalized(config, email: email)
    }

    let exchangers = await Task.detached { MXLookup.hosts(for: domain) }.value
    if let exchanger = exchangers.first {
      let base = baseDomain(exchanger)
      if base != domain {
        var lookupDomains: [String] = []
        if let subdomain = nextSubDomain(exchanger, base: base), subdomain != base {
          lookupDomains.append(subdomain)
        }
        lookupDomains.append(base)
        let viaMX = lookupDomains.flatMap { lookup -> [(DiscoveredConfig.Source, String)] in
          [
            (.mx, "https://autoconfig.\(lookup)/mail/config-v1.1.xml?emailaddress=\(encodedEmail)"),
            (.mx, "https://autoconfig.thunderbird.net/v1.1/\(lookup)"),
          ]
        }
        if var config = await firstConfig(viaMX, email: email) {
          config.providerName = config.providerName ?? base
          return finalized(config, email: email)
        }
      }
    }
    if protonDomains.contains(domain)
      || exchangers.contains(where: { host in protonDomains.contains { host == $0 || host.hasSuffix(".\($0)") } })
    {
      return protonBridge(email: email)
    }
    if let probed = await probe(email: email, domain: domain) {
      return probed
    }
    return guess(email: email, domain: domain)
  }

  /// Fetches all candidates at once and returns the highest-priority one that succeeded.
  private static func firstConfig(_ candidates: [(DiscoveredConfig.Source, String)], email: String) async -> DiscoveredConfig? {
    let results = await withTaskGroup(of: (Int, DiscoveredConfig?).self) { group in
      for (index, (source, url)) in candidates.enumerated() {
        group.addTask {
          guard let url = URL(string: url) else { return (index, nil) }
          return (index, await fetch(url, email: email, source: source))
        }
      }
      var found: [Int: DiscoveredConfig] = [:]
      for await (index, config) in group {
        found[index] = config
      }
      return found
    }
    return candidates.indices.lazy.compactMap { results[$0] }.first
  }

  private static func finalized(_ config: DiscoveredConfig, email: String) -> DiscoveredConfig {
    var config = config
    if ConnectionTrust.isLoopback(config.incoming.host) {
      config.note = protonBridge(email: email).note
    }
    return config
  }

  /// The host one label below the base domain, e.g. aspmx.l.google.com → l.google.com.
  static func nextSubDomain(_ host: String, base: String) -> String? {
    let labels = host.lowercased().split(separator: ".").map(String.init)
    let baseCount = base.split(separator: ".").count
    guard labels.count > baseCount else { return nil }
    return labels.suffix(baseCount + 1).joined(separator: ".")
  }

  /// Like Thunderbird's GuessConfig: try common host names and ports, keeping only servers that answer.
  static func probe(email: String, domain: String) async -> DiscoveredConfig? {
    func candidates(_ prefixes: [String], _ secure: Int, _ startTLS: Int) -> [(String, Int, ConnectionSecurity)] {
      prefixes.flatMap { prefix in [(prefix + domain, secure, .tls), (prefix + domain, startTLS, .startTLS)] }
    }
    async let incoming = firstAnswering(candidates(["imap.", "mail.", ""], 993, 143), greeting: "* OK")
    async let outgoing = firstAnswering(candidates(["smtp.", "mail.", ""], 465, 587), greeting: "220")
    guard let (inHost, inPort, inSecurity) = await incoming, let (outHost, outPort, outSecurity) = await outgoing else {
      return nil
    }
    return DiscoveredConfig(
      incoming: ServerConfig(host: inHost, port: inPort, security: inSecurity, username: email),
      outgoing: ServerConfig(host: outHost, port: outPort, security: outSecurity, username: email),
      providerName: nil, source: .probe, requiresOAuth: false)
  }

  private static func firstAnswering(
    _ candidates: [(String, Int, ConnectionSecurity)], greeting: String
  ) async -> (String, Int, ConnectionSecurity)? {
    let answered = await withTaskGroup(of: (Int, Bool).self) { group in
      for (index, (host, port, security)) in candidates.enumerated() {
        group.addTask {
          let connection = LineConnection(host: host, port: port, implicitTLS: security == .tls, timeout: 6)
          let line = try? await connection.readLine()
          await connection.close()
          return (index, line.map { String(decoding: $0, as: UTF8.self).hasPrefix(greeting) } ?? false)
        }
      }
      var result = Set<Int>()
      for await (index, ok) in group where ok {
        result.insert(index)
      }
      return result
    }
    return answered.min().map { candidates[$0] }
  }

  static let protonDomains: Set<String> = ["protonmail.ch", "protonmail.com", "proton.me", "pm.me"]

  /// Proton Mail is only reachable over IMAP/SMTP through the Proton Mail Bridge app.
  static func protonBridge(email: String) -> DiscoveredConfig {
    DiscoveredConfig(
      incoming: ServerConfig(host: "127.0.0.1", port: 1143, security: .startTLS, username: email),
      outgoing: ServerConfig(host: "127.0.0.1", port: 1025, security: .startTLS, username: email),
      providerName: "Proton Mail",
      source: .protonBridge,
      requiresOAuth: false,
      note:
        "Proton Mail works through Proton Mail Bridge. Keep Bridge running, and use the password Bridge shows for this address, not your Proton password."
    )
  }

  /// The registrable part of a host name, e.g. aspmx.l.google.com → google.com, mx.example.co.uk → example.co.uk.
  static func baseDomain(_ host: String) -> String {
    let labels = host.lowercased().split(separator: ".").map(String.init)
    guard labels.count > 2 else { return labels.joined(separator: ".") }
    let secondLevel = labels[labels.count - 2]
    let take = labels.last!.count == 2 && ["co", "com", "net", "org", "ac", "gov", "ne", "or"].contains(secondLevel) ? 3 : 2
    return labels.suffix(take).joined(separator: ".")
  }

  private static func fetch(_ url: URL, email: String, source: DiscoveredConfig.Source) async -> DiscoveredConfig? {
    var request = URLRequest(url: url, timeoutInterval: 8)
    request.setValue("application/xml", forHTTPHeaderField: "Accept")
    guard let (data, response) = try? await URLSession.shared.data(for: request),
      (response as? HTTPURLResponse)?.statusCode == 200
    else { return nil }
    return parse(data, email: email, source: source)
  }

  public static func parse(_ data: Data, email: String, source: DiscoveredConfig.Source) -> DiscoveredConfig? {
    let delegate = AutoconfigXMLDelegate()
    let parser = XMLParser(data: data)
    parser.delegate = delegate
    guard parser.parse() else { return nil }
    guard let incoming = delegate.servers.first(where: { $0.isIncoming && $0.type == "imap" }),
      let outgoing = delegate.servers.first(where: { !$0.isIncoming && $0.type == "smtp" })
    else { return nil }

    func config(_ server: AutoconfigXMLDelegate.Server) -> ServerConfig? {
      guard let host = server.fields["hostname"], let port = server.fields["port"].flatMap({ Int($0) }) else {
        return nil
      }
      let security: ConnectionSecurity =
        switch server.fields["socketType"]?.uppercased() {
        case "SSL": .tls
        case "STARTTLS": .startTLS
        default: .none
        }
      return ServerConfig(
        host: substitute(host, email: email),
        port: port,
        security: security,
        username: substitute(server.fields["username"] ?? "%EMAILADDRESS%", email: email)
      )
    }
    guard let incomingConfig = config(incoming), let outgoingConfig = config(outgoing) else { return nil }
    let passwordAllowed = incoming.authentication.contains { $0.hasPrefix("password") }
    return DiscoveredConfig(
      incoming: incomingConfig,
      outgoing: outgoingConfig,
      providerName: delegate.displayName,
      source: source,
      requiresOAuth: !passwordAllowed && incoming.authentication.contains("OAuth2")
    )
  }

  private static func substitute(_ template: String, email: String) -> String {
    let parts = email.split(separator: "@", maxSplits: 1).map(String.init)
    return template
      .replacingOccurrences(of: "%EMAILADDRESS%", with: email)
      .replacingOccurrences(of: "%EMAILLOCALPART%", with: parts.first ?? email)
      .replacingOccurrences(of: "%EMAILDOMAIN%", with: parts.count > 1 ? parts[1] : "")
  }

  private static func guess(email: String, domain: String) -> DiscoveredConfig {
    DiscoveredConfig(
      incoming: ServerConfig(host: "imap.\(domain)", port: 993, security: .tls, username: email),
      outgoing: ServerConfig(host: "smtp.\(domain)", port: 465, security: .tls, username: email),
      providerName: nil,
      source: .guess,
      requiresOAuth: false
    )
  }
}

private final class AutoconfigXMLDelegate: NSObject, XMLParserDelegate {
  struct Server {
    var isIncoming: Bool
    var type: String
    var fields: [String: String] = [:]
    var authentication: [String] = []
  }

  var servers: [Server] = []
  var displayName: String?
  private var current: Server?
  private var text = ""

  func parser(
    _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
    attributes: [String: String] = [:]
  ) {
    text = ""
    if elementName == "incomingServer" || elementName == "outgoingServer" {
      current = Server(isIncoming: elementName == "incomingServer", type: attributes["type"]?.lowercased() ?? "")
    }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    text += string
  }

  func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    switch elementName {
    case "incomingServer", "outgoingServer":
      if let current {
        servers.append(current)
      }
      current = nil
    case "authentication":
      current?.authentication.append(value)
    case "displayName" where current == nil && displayName == nil:
      displayName = value
    default:
      if current != nil, current?.fields[elementName] == nil {
        current?.fields[elementName] = value
      }
    }
    text = ""
  }
}
