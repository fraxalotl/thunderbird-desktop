/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation

let crlf = Data("\r\n".utf8)

/// A buffered, line oriented TCP connection that can be upgraded to TLS mid-stream for STARTTLS.
actor LineConnection {
  private let task: URLSessionStreamTask
  private var buffer = Data()
  private let timeout: TimeInterval

  init(host: String, port: Int, implicitTLS: Bool, timeout: TimeInterval = 60) {
    task = URLSession.shared.streamTask(withHostName: host, port: port)
    self.timeout = timeout
    task.resume()
    if implicitTLS {
      task.startSecureConnection()
    }
  }

  func startTLS() {
    buffer.removeAll()
    task.startSecureConnection()
  }

  private func fill() async throws {
    let (data, atEOF) = try await task.readData(ofMinLength: 1, maxLength: 1 << 16, timeout: timeout)
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
    try await task.write(data, timeout: timeout)
  }

  func write(_ string: String) async throws {
    try await write(Data(string.utf8))
  }

  func close() {
    task.cancel()
  }
}
