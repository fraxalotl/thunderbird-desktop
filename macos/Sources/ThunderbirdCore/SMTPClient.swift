/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation

public struct SMTPClient: Sendable {
  private let server: ServerConfig
  private let credential: Credential?

  public init(server: ServerConfig, credential: Credential?) {
    self.server = server
    self.credential = credential
  }

  public init(server: ServerConfig, password: String?) {
    self.init(server: server, credential: password.map(Credential.password))
  }

  private struct Reply {
    var code: Int
    var lines: [String]
    var text: String { lines.joined(separator: " ") }
  }

  private func readReply(_ connection: LineConnection) async throws -> Reply {
    var lines: [String] = []
    while true {
      let line = String(decoding: try await connection.readLine(), as: UTF8.self)
      guard line.count >= 3, let code = Int(line.prefix(3)) else {
        throw MailError.protocolError(line)
      }
      lines.append(String(line.dropFirst(4)))
      if line.count == 3 || line[line.index(line.startIndex, offsetBy: 3)] != "-" {
        return Reply(code: code, lines: lines)
      }
    }
  }

  @discardableResult
  private func send(_ command: String, on connection: LineConnection, expect codes: Set<Int>) async throws -> Reply {
    try await connection.write("\(command)\r\n")
    let reply = try await readReply(connection)
    guard codes.contains(reply.code) else {
      if reply.code == 535 || reply.code == 534 {
        throw MailError.authenticationFailed(reply.text)
      }
      throw MailError.server("\(reply.code) \(reply.text)")
    }
    return reply
  }

  private func open() async throws -> (LineConnection, [String]) {
    let connection = LineConnection(host: server.host, port: server.port, implicitTLS: server.security == .tls)
    do {
      let greeting = try await readReply(connection)
      guard greeting.code == 220 else { throw MailError.server(greeting.text) }
      var extensions = try await send("EHLO [127.0.0.1]", on: connection, expect: [250]).lines
      if server.security == .startTLS {
        try await send("STARTTLS", on: connection, expect: [220])
        await connection.startTLS()
        extensions = try await send("EHLO [127.0.0.1]", on: connection, expect: [250]).lines
      }
      if !server.username.isEmpty {
        try await authenticate(connection, extensions: extensions)
      }
      return (connection, extensions)
    } catch {
      await connection.close()
      throw error
    }
  }

  private func authenticate(_ connection: LineConnection, extensions: [String]) async throws {
    guard let credential else { throw MailError.missingPassword(server.host) }
    if let token = credential.xoauth2(user: server.username) {
      let reply = try await send("AUTH XOAUTH2 \(token)", on: connection, expect: [235, 334])
      if reply.code == 334 {
        _ = try? await send("", on: connection, expect: [535])
        throw MailError.authenticationFailed(reply.text)
      }
      return
    }
    guard case .password(let password) = credential else { return }
    let mechanisms = extensions
      .first { $0.uppercased().hasPrefix("AUTH") }?
      .uppercased()
      .split(separator: " ")
      .dropFirst()
      .map(String.init) ?? ["PLAIN"]
    if mechanisms.contains("PLAIN") || !mechanisms.contains("LOGIN") {
      let token = Data("\0\(server.username)\0\(password)".utf8).base64EncodedString()
      try await send("AUTH PLAIN \(token)", on: connection, expect: [235])
    } else {
      try await send("AUTH LOGIN", on: connection, expect: [334])
      try await send(Data(server.username.utf8).base64EncodedString(), on: connection, expect: [334])
      try await send(Data(password.utf8).base64EncodedString(), on: connection, expect: [235])
    }
  }

  /// Connects and authenticates without sending anything, to validate settings.
  public func verify() async throws {
    let (connection, _) = try await open()
    _ = try? await send("QUIT", on: connection, expect: [221])
    await connection.close()
  }

  public func send(_ message: Data, from sender: String, to recipients: [String], requestDSN: Bool = false) async throws {
    guard !recipients.isEmpty else { throw MailError.invalidRecipients }
    let (connection, extensions) = try await open()
    let supportsDSN = extensions.contains { $0.uppercased().hasPrefix("DSN") }
    do {
      try await send("MAIL FROM:<\(sender)>", on: connection, expect: [250])
      let notify = requestDSN && supportsDSN ? " NOTIFY=SUCCESS,FAILURE,DELAY" : ""
      for recipient in recipients {
        try await send("RCPT TO:<\(recipient)>\(notify)", on: connection, expect: [250, 251])
      }
      try await send("DATA", on: connection, expect: [354])
      try await connection.write(Self.dotStuffed(message))
      try await send(".", on: connection, expect: [250])
      _ = try? await send("QUIT", on: connection, expect: [221])
      await connection.close()
    } catch {
      await connection.close()
      throw error
    }
  }

  static func dotStuffed(_ message: Data) -> Data {
    var output = Data(capacity: message.count + 64)
    var atLineStart = true
    var previous: UInt8 = 0
    for byte in message {
      if byte == 0x0A && previous != 0x0D {
        output.append(0x0D)
      }
      if atLineStart && byte == UInt8(ascii: ".") {
        output.append(UInt8(ascii: "."))
      }
      output.append(byte)
      atLineStart = byte == 0x0A
      previous = byte
    }
    if !output.isEmpty && !output.ends(with: crlf) {
      output.append(crlf)
    }
    return output
  }
}

extension Data {
  func ends(with suffix: Data) -> Bool {
    count >= suffix.count && self[index(endIndex, offsetBy: -suffix.count)...].elementsEqual(suffix)
  }
}
