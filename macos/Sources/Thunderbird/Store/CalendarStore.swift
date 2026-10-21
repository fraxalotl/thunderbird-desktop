/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

@preconcurrency import EventKit
import Foundation
import Observation
import SwiftUI
import ThunderbirdCore
import UniformTypeIdentifiers
import AppKit

enum CalendarViewMode: String, CaseIterable, Identifiable {
  case day, week, multiweek, month
  var id: String { rawValue }

  var label: String {
    switch self {
    case .day: "Day"
    case .week: "Week"
    case .multiweek: "Multiweek"
    case .month: "Month"
    }
  }
}

enum TaskFilter: Hashable {
  case today, scheduled, all, completed
  case list(String)
}

/// An editable copy of an event, so forms don't mutate EventKit objects directly.
struct EventDraft: Identifiable {
  var id: String
  var title: String
  var location: String
  var notes: String
  var url: String
  var isAllDay: Bool
  var start: Date
  var end: Date
  var calendarID: String
  var repeatRule: String
  var alertMinutes: Int?

  static let repeatOptions = ["none", "daily", "weekdays", "weekly", "biweekly", "monthly", "yearly"]
  static let alertOptions: [Int?] = [nil, 0, 5, 15, 30, 60, 120, 1440]
}

struct TaskDraft: Identifiable {
  var id: String
  var title: String
  var notes: String
  var hasDueDate: Bool
  var due: Date
  var priority: Int
  var listID: String
  var isCompleted: Bool
}

struct UncheckedSendable<Value>: @unchecked Sendable {
  let value: Value
}

@MainActor
@Observable
final class CalendarStore {
  private(set) var eventAccess = EKEventStore.authorizationStatus(for: .event)
  private(set) var reminderAccess = EKEventStore.authorizationStatus(for: .reminder)
  private(set) var calendars: [EKCalendar] = []
  private(set) var reminderLists: [EKCalendar] = []
  private(set) var events: [EKEvent] = []
  private(set) var reminders: [EKReminder] = []
  private(set) var upcoming: [EKEvent] = []
  var hiddenCalendars: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "hiddenCalendars") ?? []) {
    didSet {
      UserDefaults.standard.set(Array(hiddenCalendars), forKey: "hiddenCalendars")
      reloadEvents()
    }
  }
  var focusDate = Date() {
    didSet { reloadEvents() }
  }
  var mode: CalendarViewMode = .month {
    didSet { reloadEvents() }
  }
  var taskFilter: TaskFilter = .all {
    didSet { Task { await reloadReminders() } }
  }
  /// Set by File › New › Event and Events and Tasks › New Event; the calendar space opens it.
  var pendingEditor: EventDraft?
  var pendingTask = false
  var selectedCalendarID: String?
  var selectedTaskID: String?

  @ObservationIgnored let store = EKEventStore()
  @ObservationIgnored private var observer: NSObjectProtocol?

  init() {
    observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
      Task { @MainActor in
        self?.reloadAll()
      }
    }
    reloadAll()
  }

  var hasEventAccess: Bool { eventAccess == .fullAccess }
  var hasReminderAccess: Bool { reminderAccess == .fullAccess }

  func requestEventAccess() async {
    _ = try? await store.requestFullAccessToEvents()
    eventAccess = EKEventStore.authorizationStatus(for: .event)
    reloadAll()
  }

  func requestReminderAccess() async {
    _ = try? await store.requestFullAccessToReminders()
    reminderAccess = EKEventStore.authorizationStatus(for: .reminder)
    reloadAll()
  }

  func reloadAll() {
    if hasEventAccess {
      calendars = store.calendars(for: .event).sorted { $0.title < $1.title }
      reloadEvents()
    }
    if hasReminderAccess {
      reminderLists = store.calendars(for: .reminder).sorted { $0.title < $1.title }
      Task { await reloadReminders() }
    }
  }

  var visibleCalendars: [EKCalendar] {
    calendars.filter { !hiddenCalendars.contains($0.calendarIdentifier) }
  }

  var writableCalendars: [EKCalendar] { calendars.filter(\.allowsContentModifications) }

  /// The date range the current view mode shows.
  var visibleRange: DateInterval {
    let calendar = Preferences.calendar
    switch mode {
    case .day:
      let start = calendar.startOfDay(for: focusDate)
      return DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: start)!)
    case .week:
      let start = calendar.dateInterval(of: .weekOfYear, for: focusDate)!.start
      return DateInterval(start: start, end: calendar.date(byAdding: .day, value: 7, to: start)!)
    case .multiweek:
      let start = calendar.dateInterval(of: .weekOfYear, for: focusDate)!.start
      return DateInterval(start: start, end: calendar.date(byAdding: .day, value: 28, to: start)!)
    case .month:
      let month = calendar.dateInterval(of: .month, for: focusDate)!
      let start = calendar.dateInterval(of: .weekOfYear, for: month.start)!.start
      return DateInterval(start: start, end: calendar.date(byAdding: .day, value: 42, to: start)!)
    }
  }

  func reloadEvents() {
    guard hasEventAccess else { return }
    let range = visibleRange
    let visible = visibleCalendars
    events =
      visible.isEmpty
      ? [] : store.events(matching: store.predicateForEvents(withStart: range.start, end: range.end, calendars: visible))
    let now = Date()
    upcoming =
      visible.isEmpty
      ? []
      : store.events(
        matching: store.predicateForEvents(
          withStart: Calendar.current.startOfDay(for: now), end: now.addingTimeInterval(7 * 86_400), calendars: visible)
      ).filter { $0.endDate > now }.sorted { $0.startDate < $1.startDate }
  }

  func events(on day: Date) -> [EKEvent] {
    let calendar = Calendar.current
    let start = calendar.startOfDay(for: day)
    let end = calendar.date(byAdding: .day, value: 1, to: start)!
    return events.filter { $0.startDate < end && $0.endDate > start }
      .sorted { ($0.isAllDay ? 0 : 1, $0.startDate) < ($1.isAllDay ? 0 : 1, $1.startDate) }
  }

  func step(_ direction: Int) {
    let component: Calendar.Component =
      switch mode {
      case .day: .day
      case .week: .weekOfYear
      case .multiweek: .weekOfYear
      case .month: .month
      }
    focusDate = Preferences.calendar.date(byAdding: component, value: direction, to: focusDate) ?? focusDate
  }

  // MARK: - Events

  func draft(for event: EKEvent?, defaultStart: Date = Date()) -> EventDraft {
    if let event {
      return EventDraft(
        id: event.eventIdentifier ?? UUID().uuidString, title: event.title ?? "", location: event.location ?? "",
        notes: event.notes ?? "", url: event.url?.absoluteString ?? "", isAllDay: event.isAllDay,
        start: event.startDate, end: event.endDate, calendarID: event.calendar.calendarIdentifier,
        repeatRule: Self.repeatName(event.recurrenceRules?.first),
        alertMinutes: event.alarms?.first.map { Int(-$0.relativeOffset / 60) })
    }
    let calendar = Calendar.current
    let rounded = calendar.date(bySetting: .minute, value: 0, of: defaultStart) ?? defaultStart
    let start = rounded < defaultStart ? calendar.date(byAdding: .hour, value: 1, to: rounded)! : rounded
    return EventDraft(
      id: "", title: "", location: "", notes: "", url: "", isAllDay: false, start: start,
      end: start.addingTimeInterval(Double(max(5, Preferences.int(Preferences.defaultEventMinutes)) * 60)),
      calendarID: (store.defaultCalendarForNewEvents ?? writableCalendars.first)?.calendarIdentifier ?? "",
      repeatRule: "none",
      alertMinutes: Preferences.int(Preferences.defaultReminderMinutes) < 0 ? nil : Preferences.int(Preferences.defaultReminderMinutes))
  }

  private static func repeatName(_ rule: EKRecurrenceRule?) -> String {
    guard let rule else { return "none" }
    switch rule.frequency {
    case .daily: return "daily"
    case .weekly:
      if rule.daysOfTheWeek?.count == 5 { return "weekdays" }
      return rule.interval == 2 ? "biweekly" : "weekly"
    case .monthly: return "monthly"
    case .yearly: return "yearly"
    @unknown default: return "none"
    }
  }

  private static func rule(_ name: String) -> EKRecurrenceRule? {
    switch name {
    case "daily": EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil)
    case "weekdays":
      EKRecurrenceRule(
        recurrenceWith: .weekly, interval: 1,
        daysOfTheWeek: [.monday, .tuesday, .wednesday, .thursday, .friday].map { EKRecurrenceDayOfWeek($0) },
        daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil, end: nil)
    case "weekly": EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: nil)
    case "biweekly": EKRecurrenceRule(recurrenceWith: .weekly, interval: 2, end: nil)
    case "monthly": EKRecurrenceRule(recurrenceWith: .monthly, interval: 1, end: nil)
    case "yearly": EKRecurrenceRule(recurrenceWith: .yearly, interval: 1, end: nil)
    default: nil
    }
  }

  func save(_ draft: EventDraft, span: EKSpan = .thisEvent) throws {
    let event = draft.id.isEmpty ? EKEvent(eventStore: store) : (store.event(withIdentifier: draft.id) ?? EKEvent(eventStore: store))
    event.title = draft.title.isEmpty ? "New Event" : draft.title
    event.location = draft.location.isEmpty ? nil : draft.location
    event.notes = draft.notes.isEmpty ? nil : draft.notes
    event.url = URL(string: draft.url)
    event.isAllDay = draft.isAllDay
    event.startDate = draft.start
    event.endDate = max(draft.end, draft.start)
    event.calendar = store.calendar(withIdentifier: draft.calendarID) ?? store.defaultCalendarForNewEvents
    event.recurrenceRules = Self.rule(draft.repeatRule).map { [$0] }
    event.alarms = draft.alertMinutes.map { [EKAlarm(relativeOffset: TimeInterval(-$0 * 60))] }
    try store.save(event, span: span, commit: true)
    reloadEvents()
  }

  func delete(eventID: String, span: EKSpan = .thisEvent) throws {
    guard let event = store.event(withIdentifier: eventID) else { return }
    try store.remove(event, span: span, commit: true)
    reloadEvents()
  }

  func move(_ event: EKEvent, to day: Date) throws {
    let calendar = Calendar.current
    let duration = event.endDate.timeIntervalSince(event.startDate)
    let time = calendar.dateComponents([.hour, .minute], from: event.startDate)
    let start = calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: 0, of: day) ?? day
    event.startDate = start
    event.endDate = start.addingTimeInterval(duration)
    try store.save(event, span: .thisEvent, commit: true)
    reloadEvents()
  }

  /// Adds an invitation from an email to the default calendar.
  func importInvitation(_ invitation: CalendarInvitation) throws {
    if !hasEventAccess { throw MailError.server("Allow Zapdos to use your calendars first.") }
    let existing = store.events(
      matching: store.predicateForEvents(withStart: invitation.start.addingTimeInterval(-60), end: invitation.end.addingTimeInterval(60), calendars: nil)
    ).first { $0.title == invitation.summary }
    let event = existing ?? EKEvent(eventStore: store)
    event.title = invitation.summary
    event.startDate = invitation.start
    event.endDate = invitation.end
    event.isAllDay = invitation.isAllDay
    event.location = invitation.location
    event.notes = invitation.details
    event.url = invitation.url
    if event.calendar == nil {
      event.calendar = store.defaultCalendarForNewEvents
    }
    if let recurrence = invitation.recurrence {
      let frequency: EKRecurrenceFrequency =
        switch recurrence.frequency {
        case "DAILY": .daily
        case "WEEKLY": .weekly
        case "MONTHLY": .monthly
        default: .yearly
        }
      let end = recurrence.count.map { EKRecurrenceEnd(occurrenceCount: $0) } ?? recurrence.until.map { EKRecurrenceEnd(end: $0) }
      event.recurrenceRules = [EKRecurrenceRule(recurrenceWith: frequency, interval: recurrence.interval, end: end)]
    }
    try store.save(event, span: .futureEvents, commit: true)
    reloadEvents()
  }

  // MARK: - Tasks

  func reloadReminders() async {
    guard hasReminderAccess else { return }
    let lists: [EKCalendar]
    if case .list(let id) = taskFilter {
      lists = reminderLists.filter { $0.calendarIdentifier == id }
    } else {
      lists = reminderLists
    }
    guard !lists.isEmpty else {
      reminders = []
      return
    }
    let predicate: NSPredicate =
      switch taskFilter {
      case .completed: store.predicateForCompletedReminders(withCompletionDateStarting: nil, ending: nil, calendars: lists)
      case .today:
        store.predicateForIncompleteReminders(
          withDueDateStarting: nil, ending: Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date())),
          calendars: lists)
      case .scheduled:
        store.predicateForIncompleteReminders(withDueDateStarting: Date.distantPast, ending: Date.distantFuture, calendars: lists)
      default: store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: lists)
      }
    let fetched: [EKReminder] = await withCheckedContinuation { (continuation: CheckedContinuation<UncheckedSendable<[EKReminder]>, Never>) in
      store.fetchReminders(matching: predicate) { continuation.resume(returning: UncheckedSendable(value: $0 ?? [])) }
    }.value
    reminders = fetched.sorted { lhs, rhs in
      let left = lhs.dueDateComponents?.date ?? .distantFuture
      let right = rhs.dueDateComponents?.date ?? .distantFuture
      return left == right ? (lhs.title ?? "") < (rhs.title ?? "") : left < right
    }
  }

  func taskDraft(for reminder: EKReminder?) -> TaskDraft {
    guard let reminder else {
      var listID = (store.defaultCalendarForNewReminders() ?? reminderLists.first)?.calendarIdentifier ?? ""
      if case .list(let id) = taskFilter { listID = id }
      return TaskDraft(
        id: "", title: "", notes: "", hasDueDate: taskFilter == .today, due: Date(), priority: 0, listID: listID,
        isCompleted: false)
    }
    return TaskDraft(
      id: reminder.calendarItemIdentifier, title: reminder.title ?? "", notes: reminder.notes ?? "",
      hasDueDate: reminder.dueDateComponents != nil, due: reminder.dueDateComponents?.date ?? Date(),
      priority: reminder.priority, listID: reminder.calendar.calendarIdentifier, isCompleted: reminder.isCompleted)
  }

  func save(_ draft: TaskDraft) throws {
    let reminder =
      draft.id.isEmpty
      ? EKReminder(eventStore: store) : (store.calendarItem(withIdentifier: draft.id) as? EKReminder ?? EKReminder(eventStore: store))
    reminder.title = draft.title.isEmpty ? "New Task" : draft.title
    reminder.notes = draft.notes.isEmpty ? nil : draft.notes
    reminder.priority = draft.priority
    reminder.dueDateComponents =
      draft.hasDueDate ? Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: draft.due) : nil
    reminder.calendar = store.calendar(withIdentifier: draft.listID) ?? store.defaultCalendarForNewReminders()
    reminder.isCompleted = draft.isCompleted
    try store.save(reminder, commit: true)
    Task { await reloadReminders() }
  }

  func quickAddTask(_ title: String) throws {
    var draft = taskDraft(for: nil)
    draft.title = title
    try save(draft)
  }

  func toggleCompleted(_ reminder: EKReminder) {
    reminder.isCompleted.toggle()
    try? store.save(reminder, commit: true)
    Task { await reloadReminders() }
  }

  func delete(taskID: String) throws {
    guard let reminder = store.calendarItem(withIdentifier: taskID) as? EKReminder else { return }
    try store.remove(reminder, commit: true)
    Task { await reloadReminders() }
  }

  /// Creates a task from an email, as Thunderbird's "Convert To › Task" does.
  func createTask(from loaded: LoadedMessage) throws {
    if !hasReminderAccess { throw MailError.server("Allow Zapdos to use your reminders first.") }
    var draft = taskDraft(for: nil)
    draft.title = loaded.parsed.subject
    draft.notes = String(loaded.parsed.plainText.prefix(4000))
    try save(draft)
  }

  /// Creates an event from an email, as Thunderbird's "Convert To › Event" does.
  func eventDraft(from loaded: LoadedMessage) -> EventDraft {
    var draft = draft(for: nil)
    draft.title = loaded.parsed.subject
    draft.notes = String(loaded.parsed.plainText.prefix(4000))
    return draft
  }

  // MARK: - Events and Tasks menu

  /// File › New › Calendar…
  func promptNewCalendar() {
    let alert = NSAlert()
    alert.messageText = "New Calendar"
    let field = NSTextField(string: "")
    field.placeholderString = "Calendar name"
    field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
    alert.accessoryView = field
    alert.addButton(withTitle: "Create")
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = field
    guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return }
    let calendar = EKCalendar(for: .event, eventStore: store)
    calendar.title = field.stringValue
    calendar.source = store.defaultCalendarForNewEvents?.source ?? store.sources.first { $0.sourceType == .local } ?? store.sources.first
    do {
      try store.saveCalendar(calendar, commit: true)
      reloadAll()
    } catch {
      showError(error)
    }
  }

  /// Events and Tasks › Import… and File › Open › Calendar File…
  func importCalendarFile() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [UTType(filenameExtension: "ics") ?? .calendarEvent, .calendarEvent]
    panel.allowsMultipleSelection = true
    guard panel.runModal() == .OK else { return }
    var imported = 0
    for url in panel.urls {
      guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
      for invitation in ICalendar.invitations(in: text) {
        if (try? importInvitation(invitation)) != nil { imported += 1 }
      }
    }
    let alert = NSAlert()
    alert.messageText = "Imported \(imported) event\(imported == 1 ? "" : "s")."
    alert.runModal()
  }

  /// Events and Tasks › Export…: the visible calendars' events as an .ics file.
  func exportCalendar() {
    guard let text = icsForVisibleCalendars() else { return }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "Calendar.ics"
    if panel.runModal() == .OK, let url = panel.url {
      try? text.write(to: url, atomically: true, encoding: .utf8)
    }
  }

  /// Events and Tasks › Publish…: uploads the .ics to a WebDAV/HTTP URL with PUT, as Thunderbird does.
  func publishCalendar() {
    guard let text = icsForVisibleCalendars() else { return }
    let alert = NSAlert()
    alert.messageText = "Publish Calendar"
    alert.informativeText = "Enter the address to upload the calendar to (for example a WebDAV URL)."
    let field = NSTextField(string: "https://")
    field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
    alert.accessoryView = field
    alert.addButton(withTitle: "Publish")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn, let url = URL(string: field.stringValue) else { return }
    var request = URLRequest(url: url)
    request.httpMethod = "PUT"
    request.setValue("text/calendar; charset=utf-8", forHTTPHeaderField: "Content-Type")
    request.httpBody = Data(text.utf8)
    Task {
      do {
        let (_, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if !(200..<300).contains(status) { throw MailError.server("The server answered \(status).") }
      } catch {
        showError(error)
      }
    }
  }

  private func icsForVisibleCalendars() -> String? {
    guard hasEventAccess else { return nil }
    let start = Calendar.current.date(byAdding: .year, value: -1, to: Date())!
    let end = Calendar.current.date(byAdding: .year, value: 2, to: Date())!
    let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: visibleCalendars))
    var lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Mozilla.org/NONSGML Zapdos//EN"]
    for event in events {
      lines += ["BEGIN:VEVENT", "UID:\(event.calendarItemExternalIdentifier ?? UUID().uuidString)",
        "DTSTAMP:\(ICalendar.formatUTC(Date()))"]
      if event.isAllDay {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        lines += ["DTSTART;VALUE=DATE:\(formatter.string(from: event.startDate))", "DTEND;VALUE=DATE:\(formatter.string(from: event.endDate))"]
      } else {
        lines += ["DTSTART:\(ICalendar.formatUTC(event.startDate))", "DTEND:\(ICalendar.formatUTC(event.endDate))"]
      }
      lines.append("SUMMARY:\(ICalendar.escape(event.title ?? ""))")
      if let location = event.location { lines.append("LOCATION:\(ICalendar.escape(location))") }
      if let notes = event.notes { lines.append("DESCRIPTION:\(ICalendar.escape(notes))") }
      lines.append("END:VEVENT")
    }
    lines.append("END:VCALENDAR")
    return lines.joined(separator: "\r\n") + "\r\n"
  }

  /// Events and Tasks › Delete Selected Calendar…
  func deleteSelectedCalendar() {
    guard let id = selectedCalendarID, let calendar = store.calendar(withIdentifier: id) else { return }
    let alert = NSAlert()
    alert.messageText = "Delete the calendar “\(calendar.title)”?"
    alert.informativeText = "All of its events will be deleted from every device that uses it."
    alert.addButton(withTitle: "Delete")
    alert.addButton(withTitle: "Cancel")
    alert.buttons.first?.hasDestructiveAction = true
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    do {
      try store.removeCalendar(calendar, commit: true)
      selectedCalendarID = nil
      reloadAll()
    } catch {
      showError(error)
    }
  }

  private var selectedReminder: EKReminder? {
    selectedTaskID.flatMap { store.calendarItem(withIdentifier: $0) as? EKReminder }
  }

  func markSelectedTask(completed: Bool) {
    guard let reminder = selectedReminder else { return }
    reminder.isCompleted = completed
    try? store.save(reminder, commit: true)
    Task { await reloadReminders() }
  }

  /// Reminders have no partial progress; 100% completes the task and anything less reopens it.
  func setSelectedTaskProgress(_ percent: Int) {
    markSelectedTask(completed: percent >= 100)
  }

  func setSelectedTaskPriority(_ priority: Int) {
    guard let reminder = selectedReminder else { return }
    reminder.priority = priority
    try? store.save(reminder, commit: true)
    Task { await reloadReminders() }
  }

  func postponeSelectedTask(by interval: TimeInterval) {
    guard let reminder = selectedReminder else { return }
    let current = reminder.dueDateComponents?.date ?? Date()
    reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: current.addingTimeInterval(interval))
    try? store.save(reminder, commit: true)
    Task { await reloadReminders() }
  }

  /// The Events Search (unifinder): events in the next and previous year matching the text.
  func searchEvents(_ text: String) -> [EKEvent] {
    guard hasEventAccess, !text.isEmpty else { return [] }
    let start = Calendar.current.date(byAdding: .year, value: -1, to: Date())!
    let end = Calendar.current.date(byAdding: .year, value: 1, to: Date())!
    return store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: visibleCalendars))
      .filter { ($0.title ?? "").localizedCaseInsensitiveContains(text) || ($0.location ?? "").localizedCaseInsensitiveContains(text)
        || ($0.notes ?? "").localizedCaseInsensitiveContains(text) }
      .sorted { $0.startDate < $1.startDate }
  }

  private func showError(_ error: Error) {
    let alert = NSAlert(error: error)
    alert.runModal()
  }

  static func color(_ calendar: EKCalendar?) -> Color {
    guard let cgColor = calendar?.cgColor else { return .accentColor }
    return Color(cgColor: cgColor)
  }
}
