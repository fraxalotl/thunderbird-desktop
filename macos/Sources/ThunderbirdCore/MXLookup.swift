/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import dnssd

/// Looks up a domain's mail exchangers with the system resolver, as Thunderbird's account
/// setup does when no configuration file is published.
enum MXLookup {
  private final class Collector {
    var records: [(priority: Int, host: String)] = []
    var finished = false
  }

  /// Blocking; call off the main thread. Returns hosts ordered by preference.
  static func hosts(for domain: String, timeout: TimeInterval = 4) -> [String] {
    let collector = Collector()
    var reference: DNSServiceRef?
    let context = Unmanaged.passUnretained(collector).toOpaque()
    let status = DNSServiceQueryRecord(
      &reference, 0, 0, domain, UInt16(kDNSServiceType_MX), UInt16(kDNSServiceClass_IN),
      { _, flags, _, error, _, _, _, length, rdata, _, context in
        guard let context else { return }
        let collector = Unmanaged<Collector>.fromOpaque(context).takeUnretainedValue()
        if error == kDNSServiceErr_NoError, let rdata, let record = MXLookup.parse(rdata, length: Int(length)) {
          collector.records.append(record)
        }
        if flags & kDNSServiceFlagsMoreComing == 0 {
          collector.finished = true
        }
      }, context)
    guard status == kDNSServiceErr_NoError, let reference else { return [] }
    defer { DNSServiceRefDeallocate(reference) }

    let socket = DNSServiceRefSockFD(reference)
    let deadline = Date().addingTimeInterval(timeout)
    while !collector.finished, Date() < deadline {
      var descriptor = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
      let remaining = Int32(max(0, deadline.timeIntervalSinceNow) * 1000)
      guard poll(&descriptor, 1, remaining) > 0 else { break }
      if DNSServiceProcessResult(reference) != kDNSServiceErr_NoError { break }
    }
    return collector.records.sorted { $0.priority < $1.priority }.map(\.host)
  }

  /// MX RDATA: a 16-bit preference followed by an uncompressed domain name.
  static func parse(_ rdata: UnsafeRawPointer, length: Int) -> (priority: Int, host: String)? {
    let bytes = UnsafeRawBufferPointer(start: rdata, count: length)
    guard bytes.count > 3 else { return nil }
    let priority = Int(bytes[0]) << 8 | Int(bytes[1])
    var labels: [String] = []
    var index = 2
    while index < bytes.count {
      let size = Int(bytes[index])
      if size == 0 || size & 0xC0 != 0 { break }
      index += 1
      guard index + size <= bytes.count else { return nil }
      labels.append(String(decoding: bytes[index..<index + size], as: UTF8.self))
      index += size
    }
    return labels.isEmpty ? nil : (priority, labels.joined(separator: ".").lowercased())
  }
}
