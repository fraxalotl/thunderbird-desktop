/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation

let crlf = Data("\r\n".utf8)

/// Accepts self-signed certificates only for connections that never leave this Mac, such as
/// Proton Mail Bridge on 127.0.0.1. Everything else gets the system's normal TLS evaluation.
final class ConnectionTrust: NSObject, URLSessionTaskDelegate {
  static let session = URLSession(configuration: .default, delegate: ConnectionTrust(), delegateQueue: nil)

  static func isLoopback(_ host: String) -> Bool {
    let host = host.lowercased()
    return host == "localhost" || host == "::1" || host.hasPrefix("127.")
  }

  private func evaluate(_ challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
    let space = challenge.protectionSpace
    guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = space.serverTrust,
      Self.isLoopback(space.host)
    else { return (.performDefaultHandling, nil) }
    return (.useCredential, URLCredential(trust: trust))
  }

  func urlSession(
    _ session: URLSession, didReceive challenge: URLAuthenticationChallenge
  ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
    evaluate(challenge)
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge
  ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
    evaluate(challenge)
  }
}

/// A buffered, line oriented TCP connection that can be upgraded to TLS mid-stream for STARTTLS.
actor LineConnection {
  private let task: URLSessionStreamTask
  private var buffer = Data()
  private let timeout: TimeInterval
  private let host: String
  private let port: Int

  init(host: String, port: Int, implicitTLS: Bool, timeout: TimeInterval = 60) {
    task = ConnectionTrust.session.streamTask(withHostName: host, port: port)
    self.timeout = timeout
    self.host = host
    self.port = port
    task.resume()
    if implicitTLS {
      task.startSecureConnection()
    }
  }

  func startTLS() {
    buffer.removeAll()
    task.startSecureConnection()
  }

  /// Turns low-level networking errors into messages that name the server involved.
  private func describe(_ error: Error) -> Error {
    if error is MailError { return error }
    let nsError = error as NSError
    switch (nsError.domain, nsError.code) {
    case ("kCFErrorDomainCFNetwork", 2), (NSURLErrorDomain, NSURLErrorCannotFindHost),
      (NSURLErrorDomain, NSURLErrorDNSLookupFailed):
      return MailError.hostNotFound(host)
    case (NSPOSIXErrorDomain, 61), (NSURLErrorDomain, NSURLErrorCannotConnectToHost):
      return MailError.cannotConnect(host, port)
    case (NSURLErrorDomain, NSURLErrorTimedOut), (NSPOSIXErrorDomain, 60):
      return MailError.timeout
    case (NSURLErrorDomain, NSURLErrorSecureConnectionFailed), (NSURLErrorDomain, NSURLErrorServerCertificateUntrusted),
      (NSURLErrorDomain, NSURLErrorServerCertificateHasBadDate), (NSURLErrorDomain, NSURLErrorServerCertificateHasUnknownRoot),
      (NSURLErrorDomain, NSURLErrorServerCertificateNotYetValid), (NSOSStatusErrorDomain, _):
      return MailError.tlsFailed(host)
    case (NSURLErrorDomain, NSURLErrorNotConnectedToInternet):
      return MailError.offline
    default:
      return error
    }
  }

  private func fill() async throws {
    let data: Data?
    let atEOF: Bool
    do {
      (data, atEOF) = try await task.readData(ofMinLength: 1, maxLength: 1 << 16, timeout: timeout)
    } catch {
      throw describe(error)
    }
    if let data, !data.isEmpty {
      buffer.append(data)
      return
    }
    throw atEOF ? MailError.connectionClosed : MailError.timeout
  }

  func readLine() async throws -> Data {
    var searchFrom = buffer.startIndex
    while true {
      if let range = buffer.range(of: crlf, in: searchFrom..<buffer.endIndex) {
        let line = Data(buffer[buffer.startIndex..<range.lowerBound])
        buffer.removeSubrange(buffer.startIndex..<range.upperBound)
        return line
      }
      searchFrom = max(buffer.startIndex, buffer.endIndex - 1)
      try await fill()
    }
  }

  func readBytes(_ count: Int) async throws -> Data {
    while buffer.count < count {
      try await fill()
    }
    let end = buffer.index(buffer.startIndex, offsetBy: count)
    let bytes = Data(buffer[buffer.startIndex..<end])
    buffer.removeSubrange(buffer.startIndex..<end)
    return bytes
  }

  /// Returns whatever bytes are buffered, or waits for the next chunk from the network.
  func readChunk() async throws -> Data {
    if buffer.isEmpty {
      try await fill()
    }
    let chunk = buffer
    buffer.removeAll()
    return chunk
  }

  func write(_ data: Data) async throws {
    do {
      try await task.write(data, timeout: timeout)
    } catch {
      throw describe(error)
    }
  }

  func write(_ string: String) async throws {
    try await write(Data(string.utf8))
  }

  func close() {
    task.cancel()
  }
}
