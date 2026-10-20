/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation

public struct ICalProperty: Sendable, Hashable {
  public var name: String
  public var parameters: [String: String]
  public var value: String
}

public struct ICalComponent: Sendable, Hashable {
  public var name: String
  public var properties: [ICalProperty]
  public var children: [ICalComponent]

  public func property(_ name: String) -> ICalProperty? {
    properties.first { $0.name == name }
  }

  public func all(_ name: String) -> [ICalProperty] {
    properties.filter { $0.name == name }
  }
}

public struct ICalAttendee: Sendable, Hashable {
  public var email: String
  public var name: String?
  public var status: String
}

public struct ICalRecurrence: Sendable, Hashable {
  public var frequency: String
  public var interval: Int
  public var count: Int?
  public var until: Date?
}

/// A VEVENT from an invitation, decoded far enough to show and import it.
public struct CalendarInvitation: Sendable, Hashable {
  public var method: String
  public var uid: String
  public var summary: String
  public var location: String?
  public var details: String?
  public var start: Date
  public var end: Date
  public var isAllDay: Bool
  public var organizer: MailAddress?
  public var attendees: [ICalAttendee]
  public var sequence: Int
  public var recurrence: ICalRecurrence?
  public var url: URL?
  public var rawEvent: ICalComponent
}

public enum ICalendar {
  public static func parse(_ text: String) -> [ICalComponent] {
    var unfolded: [String] = []
    for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
      if let first = line.first, first == " " || first == "\t", !unfolded.isEmpty {
        unfolded[unfolded.count - 1] += line.dropFirst()
      } else if !line.isEmpty {
        unfolded.append(line)
      }
    }
    var stack: [ICalComponent] = []
    var roots: [ICalComponent] = []
    for line in unfolded {
      guard let property = parseLine(line) else { continue }
      if property.name == "BEGIN" {
        stack.append(ICalComponent(name: property.value.uppercased(), properties: [], children: []))
      } else if property.name == "END" {
        guard let finished = stack.popLast() else { continue }
        if stack.isEmpty {
          roots.append(finished)
        } else {
          stack[stack.count - 1].children.append(finished)
        }
      } else if !stack.isEmpty {
        stack[stack.count - 1].properties.append(property)
      }
    }
    return roots
  }

  static func parseLine(_ line: String) -> ICalProperty? {
    var inQuotes = false
    var colon: String.Index?
    for index in line.indices {
      let char = line[index]
      if char == "\"" { inQuotes.toggle() }
      if char == ":" && !inQuotes {
        colon = index
        break
      }
    }
    guard let colon else { return nil }
    let head = line[..<colon]
    let value = String(line[line.index(after: colon)...])
    var segments = head.split(separator: ";").map(String.init)
    guard !segments.isEmpty else { return nil }
    let name = segments.removeFirst().uppercased()
    var parameters: [String: String] = [:]
    for segment in segments {
      let pair = segment.split(separator: "=", maxSplits: 1).map(String.init)
      if pair.count == 2 {
        parameters[pair[0].uppercased()] = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
      }
    }
    return ICalProperty(name: name, parameters: parameters, value: value)
  }

  public static func unescape(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\\n", with: "\n")
      .replacingOccurrences(of: "\\N", with: "\n")
      .replacingOccurrences(of: "\\,", with: ",")
      .replacingOccurrences(of: "\\;", with: ";")
      .replacingOccurrences(of: "\\\\", with: "\\")
  }

  public static func escape(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: ";", with: "\\;")
      .replacingOccurrences(of: ",", with: "\\,")
      .replacingOccurrences(of: "\n", with: "\\n")
  }

  /// Parses DATE and DATE-TIME values, honouring UTC, TZID and floating times.
  public static func date(_ property: ICalProperty) -> (date: Date, allDay: Bool)? {
    let value = property.value.trimmingCharacters(in: .whitespaces)
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    if property.parameters["VALUE"] == "DATE" || value.count == 8 {
      formatter.dateFormat = "yyyyMMdd"
      formatter.timeZone = .current
      return formatter.date(from: value).map { ($0, true) }
    }
    if value.hasSuffix("Z") {
      formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
      formatter.timeZone = TimeZone(identifier: "UTC")
    } else {
      formatter.dateFormat = "yyyyMMdd'T'HHmmss"
      formatter.timeZone = property.parameters["TZID"].flatMap(timeZone) ?? .current
    }
    return formatter.date(from: value).map { ($0, false) }
  }

  private static func timeZone(_ identifier: String) -> TimeZone? {
    if let zone = TimeZone(identifier: identifier) { return zone }
    let windows: [String: String] = [
      "GMT Standard Time": "Europe/London", "W. Europe Standard Time": "Europe/Berlin",
      "Romance Standard Time": "Europe/Paris", "Central Europe Standard Time": "Europe/Budapest",
      "Eastern Standard Time": "America/New_York", "Central Standard Time": "America/Chicago",
      "Mountain Standard Time": "America/Denver", "Pacific Standard Time": "America/Los_Angeles",
      "AUS Eastern Standard Time": "Australia/Sydney", "Tokyo Standard Time": "Asia/Tokyo",
      "India Standard Time": "Asia/Kolkata", "China Standard Time": "Asia/Shanghai",
    ]
    return windows[identifier].flatMap(TimeZone.init(identifier:))
  }

  public static func formatUTC(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    return formatter.string(from: date)
  }

  static func duration(_ value: String) -> TimeInterval? {
    var seconds: TimeInterval = 0
    var number = ""
    var negative = false
    for char in value {
      switch char {
      case "-": negative = true
      case "+", "P", "T": break
      case "W": seconds += (Double(number) ?? 0) * 604_800; number = ""
      case "D": seconds += (Double(number) ?? 0) * 86_400; number = ""
      case "H": seconds += (Double(number) ?? 0) * 3_600; number = ""
      case "M": seconds += (Double(number) ?? 0) * 60; number = ""
      case "S": seconds += Double(number) ?? 0; number = ""
      default: number.append(char)
      }
    }
    return negative ? -seconds : seconds
  }

  public static func invitations(in text: String) -> [CalendarInvitation] {
    parse(text).filter { $0.name == "VCALENDAR" }.flatMap { calendar -> [CalendarInvitation] in
      let method = calendar.property("METHOD")?.value.uppercased() ?? "PUBLISH"
      return calendar.children.filter { $0.name == "VEVENT" }.compactMap { event in
        guard let startProperty = event.property("DTSTART"), let (start, allDay) = date(startProperty) else { return nil }
        var end = event.property("DTEND").flatMap(date)?.date
        if end == nil, let duration = event.property("DURATION").flatMap({ duration($0.value) }) {
          end = start.addingTimeInterval(duration)
        }
        let organizer = event.property("ORGANIZER").map { property in
          MailAddress(
            name: property.parameters["CN"],
            email: property.value.replacingOccurrences(of: "mailto:", with: "", options: .caseInsensitive))
        }
        let attendees = event.all("ATTENDEE").map { property in
          ICalAttendee(
            email: property.value.replacingOccurrences(of: "mailto:", with: "", options: .caseInsensitive),
            name: property.parameters["CN"],
            status: property.parameters["PARTSTAT"] ?? "NEEDS-ACTION")
        }
        return CalendarInvitation(
          method: method,
          uid: event.property("UID")?.value ?? UUID().uuidString,
          summary: unescape(event.property("SUMMARY")?.value ?? "Untitled event"),
          location: event.property("LOCATION").map { unescape($0.value) },
          details: event.property("DESCRIPTION").map { unescape($0.value) },
          start: start,
          end: end ?? start.addingTimeInterval(allDay ? 86_400 : 3_600),
          isAllDay: allDay,
          organizer: organizer,
          attendees: attendees,
          sequence: Int(event.property("SEQUENCE")?.value ?? "0") ?? 0,
          recurrence: event.property("RRULE").flatMap { recurrence($0.value) },
          url: event.property("URL").flatMap { URL(string: $0.value) },
          rawEvent: event)
      }
    }
  }

  static func recurrence(_ rule: String) -> ICalRecurrence? {
    var fields: [String: String] = [:]
    for part in rule.split(separator: ";") {
      let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
      if pair.count == 2 { fields[pair[0].uppercased()] = pair[1] }
    }
    guard let frequency = fields["FREQ"] else { return nil }
    return ICalRecurrence(
      frequency: frequency,
      interval: Int(fields["INTERVAL"] ?? "1") ?? 1,
      count: fields["COUNT"].flatMap { Int($0) },
      until: fields["UNTIL"].flatMap { date(ICalProperty(name: "UNTIL", parameters: [:], value: $0))?.date })
  }

  /// Builds an iMIP REPLY (RFC 6047) with the attendee's participation status.
  public static func reply(
    to invitation: CalendarInvitation, attendee: MailAddress, status: String, now: Date = Date()
  ) -> String {
    var lines = [
      "BEGIN:VCALENDAR",
      "PRODID:-//Mozilla.org/NONSGML Thunderbird for macOS//EN",
      "VERSION:2.0",
      "METHOD:REPLY",
      "BEGIN:VEVENT",
      "UID:\(invitation.uid)",
      "DTSTAMP:\(formatUTC(now))",
      "SEQUENCE:\(invitation.sequence)",
      "SUMMARY:\(escape(invitation.summary))",
    ]
    for name in ["DTSTART", "DTEND", "RECURRENCE-ID"] {
      if let property = invitation.rawEvent.property(name) {
        let parameters = property.parameters.map { ";\($0.key)=\($0.value)" }.sorted().joined()
        lines.append("\(name)\(parameters):\(property.value)")
      }
    }
    if let organizer = invitation.organizer {
      let name = organizer.name.map { ";CN=\"\($0)\"" } ?? ""
      lines.append("ORGANIZER\(name):mailto:\(organizer.email)")
    }
    let attendeeName = attendee.name.map { ";CN=\"\($0)\"" } ?? ""
    lines.append("ATTENDEE;PARTSTAT=\(status)\(attendeeName):mailto:\(attendee.email)")
    lines += ["END:VEVENT", "END:VCALENDAR"]
    return lines.map(fold).joined(separator: "\r\n") + "\r\n"
  }

  static func fold(_ line: String) -> String {
    var result = ""
    var count = 0
    for char in line {
      let size = String(char).utf8.count
      if count + size > 74 {
        result += "\r\n "
        count = 1
      }
      result.append(char)
      count += size
    }
    return result
  }
}
