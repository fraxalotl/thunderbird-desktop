/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import EventKit
import SwiftUI
import ThunderbirdCore

struct CalendarSpace: View {
  @Environment(CalendarStore.self) private var calendar
  @State private var editing: EventDraft?
  @AppStorage("showUnifinder") private var showUnifinder = false

  var body: some View {
    @Bindable var calendar = calendar
    Group {
      if !calendar.hasEventAccess {
        PermissionView(
          title: "Use Your Calendars", symbol: "calendar",
          message: "Thunderbird shows and edits the calendars you already use on this Mac, including iCloud, Google, Exchange and CalDAV calendars.",
          action: { await calendar.requestEventAccess() })
      } else {
        NavigationSplitView {
          CalendarSidebar()
            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
          VStack(spacing: 0) {
            if showUnifinder {
              EventSearchPane(onEdit: { editing = $0 })
                .frame(height: 220)
              Divider()
            }
            Group {
              switch calendar.mode {
              case .day: TimeGridView(days: 1, onEdit: { editing = $0 })
              case .week: TimeGridView(days: 7, onEdit: { editing = $0 })
              case .multiweek: MonthGridView(weeks: 4, onEdit: { editing = $0 })
              case .month: MonthGridView(weeks: 6, onEdit: { editing = $0 })
              }
            }
          }
          .navigationTitle(title)
        }
        .toolbar {
          ToolbarItemGroup(placement: .primaryAction) {
            Button {
              calendar.step(-1)
            } label: {
              Label("Previous", systemImage: "chevron.left")
            }
            Button("Today") { calendar.focusDate = Date() }
            Button {
              calendar.step(1)
            } label: {
              Label("Next", systemImage: "chevron.right")
            }
          }
          ToolbarSpacer(.fixed, placement: .primaryAction)
          ToolbarItem(placement: .primaryAction) {
            Picker("View", selection: $calendar.mode) {
              ForEach(CalendarViewMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
          }
          ToolbarSpacer(.fixed, placement: .primaryAction)
          ToolbarItem(placement: .primaryAction) {
            Button {
              editing = calendar.draft(for: nil, defaultStart: calendar.focusDate)
            } label: {
              Label("New Event", systemImage: "plus")
            }
            .buttonStyle(.glassProminent)
            .keyboardShortcut("n", modifiers: [.command, .option])
          }
        }
      }
    }
    .sheet(item: $editing) { draft in
      EventEditor(initial: draft)
    }
    .onChange(of: calendar.pendingEditor?.start, initial: true) {
      if let pending = calendar.pendingEditor {
        editing = pending
        calendar.pendingEditor = nil
      }
    }
  }

  private var title: String {
    switch calendar.mode {
    case .day: calendar.focusDate.formatted(date: .complete, time: .omitted)
    case .week, .multiweek:
      "\(calendar.visibleRange.start.formatted(.dateTime.day().month())) – \(calendar.visibleRange.end.addingTimeInterval(-1).formatted(.dateTime.day().month().year()))"
    case .month: calendar.focusDate.formatted(.dateTime.month(.wide).year())
    }
  }
}

struct PermissionView: View {
  let title: String
  let symbol: String
  let message: String
  let action: () async -> Void

  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: symbol)
        .font(.system(size: 48))
        .foregroundStyle(.tint)
      Text(title)
        .font(.title2.weight(.semibold))
      Text(message)
        .multilineTextAlignment(.center)
        .foregroundStyle(.secondary)
        .frame(maxWidth: 420)
      Button("Allow Access") { Task { await action() } }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
    }
    .padding(40)
    .glassEffect(.regular, in: .rect(cornerRadius: 28))
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct CalendarSidebar: View {
  @Environment(CalendarStore.self) private var calendar

  var body: some View {
    @Bindable var calendar = calendar
    List(selection: $calendar.selectedCalendarID) {
      DatePicker("Date", selection: $calendar.focusDate, displayedComponents: .date)
        .datePickerStyle(.graphical)
        .labelsHidden()
        .padding(8)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .listRowSeparator(.hidden)

      let grouped = Dictionary(grouping: calendar.calendars) { $0.source.title }
      ForEach(grouped.keys.sorted(), id: \.self) { source in
        Section(source) {
          ForEach(grouped[source] ?? [], id: \.calendarIdentifier) { item in
            Toggle(
              isOn: Binding(
                get: { !calendar.hiddenCalendars.contains(item.calendarIdentifier) },
                set: { visible in
                  if visible {
                    calendar.hiddenCalendars.remove(item.calendarIdentifier)
                  } else {
                    calendar.hiddenCalendars.insert(item.calendarIdentifier)
                  }
                })
            ) {
              Text(item.title)
            }
            .toggleStyle(.checkbox)
            .tint(CalendarStore.color(item))
            .tag(item.calendarIdentifier)
            .contextMenu {
              Button("Delete Calendar…") {
                calendar.selectedCalendarID = item.calendarIdentifier
                calendar.deleteSelectedCalendar()
              }
            }
          }
        }
      }
    }
    .listStyle(.sidebar)
  }
}

struct MonthGridView: View {
  @Environment(CalendarStore.self) private var calendar
  @AppStorage(Preferences.showWeekNumbers) private var showWeekNumbers = false
  let weeks: Int
  let onEdit: (EventDraft) -> Void

  private var days: [Date] {
    let start = calendar.visibleRange.start
    return (0..<(weeks * 7)).compactMap { Preferences.calendar.date(byAdding: .day, value: $0, to: start) }
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 0) {
        if showWeekNumbers {
          Color.clear.frame(width: 28)
        }
        ForEach(Array(days.prefix(7)), id: \.self) { day in
          Text(day.formatted(.dateTime.weekday(.abbreviated)))
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
        }
      }
      .padding(.vertical, 6)
      Grid(horizontalSpacing: 1, verticalSpacing: 1) {
        ForEach(0..<weeks, id: \.self) { week in
          GridRow {
            if showWeekNumbers {
              Text("\(Preferences.calendar.component(.weekOfYear, from: days[week * 7]))")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 28)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 6)
                .background(.background)
            }
            ForEach(days[(week * 7)..<(week * 7 + 7)], id: \.self) { day in
              DayCell(day: day, onEdit: onEdit)
            }
          }
        }
      }
      .background(.separator)
    }
    .padding(8)
  }
}

private struct DayCell: View {
  @Environment(CalendarStore.self) private var calendar
  @Environment(MailStore.self) private var mail
  let day: Date
  let onEdit: (EventDraft) -> Void

  var body: some View {
    let events = calendar.events(on: day)
    let isToday = Calendar.current.isDateInToday(day)
    let inMonth = calendar.mode != .month || Calendar.current.isDate(day, equalTo: calendar.focusDate, toGranularity: .month)
    VStack(alignment: .leading, spacing: 3) {
      HStack {
        Text(day.formatted(.dateTime.day()))
          .font(.callout.weight(isToday ? .bold : .regular))
          .foregroundStyle(isToday ? Color.white : inMonth ? Color.primary : Color.secondary)
          .frame(minWidth: 24, minHeight: 24)
          .background(isToday ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), in: Circle())
        Spacer()
      }
      ForEach(events.prefix(4), id: \.self) { event in
        EventChip(event: event)
          .onTapGesture { onEdit(calendar.draft(for: event)) }
          .draggable(event.eventIdentifier ?? "")
      }
      if events.count > 4 {
        Text("+\(events.count - 4) more")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
    .padding(4)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(.background)
    .contentShape(.rect)
    .onTapGesture(count: 2) {
      let start = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
      onEdit(calendar.draft(for: nil, defaultStart: start))
    }
    .onTapGesture { calendar.focusDate = day }
    .dropDestination(for: String.self) { identifiers, _ in
      guard let id = identifiers.first, let event = calendar.store.event(withIdentifier: id) else { return false }
      do { try calendar.move(event, to: day) } catch { mail.report(error, title: "Couldn't move the event") }
      return true
    }
  }
}

private struct EventChip: View {
  let event: EKEvent

  var body: some View {
    let color = CalendarStore.color(event.calendar)
    HStack(spacing: 4) {
      if !event.isAllDay {
        Text(event.startDate.formatted(date: .omitted, time: .shortened))
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      Text(event.title ?? "")
        .font(.caption)
        .lineLimit(1)
    }
    .padding(.horizontal, 5)
    .padding(.vertical, 2)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(color.opacity(event.isAllDay ? 0.85 : 0.18), in: .rect(cornerRadius: 5))
    .foregroundStyle(event.isAllDay ? .white : .primary)
  }
}

struct TimeGridView: View {
  @Environment(CalendarStore.self) private var calendar
  let days: Int
  let onEdit: (EventDraft) -> Void
  private let hourHeight: CGFloat = 48

  private var dates: [Date] {
    let start = calendar.visibleRange.start
    return (0..<days).compactMap { Preferences.calendar.date(byAdding: .day, value: $0, to: start) }
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 0) {
        Color.clear.frame(width: 52)
        ForEach(dates, id: \.self) { day in
          VStack(spacing: 2) {
            Text(day.formatted(.dateTime.weekday(.abbreviated)))
              .font(.caption)
              .foregroundStyle(.secondary)
            Text(day.formatted(.dateTime.day()))
              .font(.title3.weight(Calendar.current.isDateInToday(day) ? .bold : .regular))
              .foregroundStyle(Calendar.current.isDateInToday(day) ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            ForEach(calendar.events(on: day).filter(\.isAllDay), id: \.self) { event in
              EventChip(event: event)
                .onTapGesture { onEdit(calendar.draft(for: event)) }
            }
          }
          .frame(maxWidth: .infinity)
        }
      }
      .padding(.vertical, 8)
      Divider()
      ScrollViewReader { proxy in
        ScrollView {
          HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) {
              ForEach(0..<24, id: \.self) { hour in
                Text(Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date())!.formatted(.dateTime.hour()))
                  .font(.caption2)
                  .foregroundStyle(.secondary)
                  .frame(width: 52, height: hourHeight, alignment: .topTrailing)
                  .padding(.trailing, 6)
                  .id(hour)
              }
            }
            ForEach(dates, id: \.self) { day in
              DayColumn(day: day, hourHeight: hourHeight, onEdit: onEdit)
            }
          }
        }
        .onAppear { proxy.scrollTo(max(0, min(23, Preferences.int(Preferences.dayStartHour))), anchor: .top) }
      }
    }
  }
}

private struct DayColumn: View {
  @Environment(CalendarStore.self) private var calendar
  let day: Date
  let hourHeight: CGFloat
  let onEdit: (EventDraft) -> Void

  /// Greedy column assignment so overlapping events sit side by side.
  private func layout(_ events: [EKEvent]) -> [(EKEvent, Int, Int)] {
    var columns: [[EKEvent]] = []
    var placement: [(EKEvent, Int)] = []
    for event in events.sorted(by: { $0.startDate < $1.startDate }) {
      if let index = columns.firstIndex(where: { $0.last.map { $0.endDate <= event.startDate } ?? true }) {
        columns[index].append(event)
        placement.append((event, index))
      } else {
        columns.append([event])
        placement.append((event, columns.count - 1))
      }
    }
    return placement.map { ($0.0, $0.1, max(1, columns.count)) }
  }

  var body: some View {
    let start = Calendar.current.startOfDay(for: day)
    let timed = calendar.events(on: day).filter { !$0.isAllDay }
    GeometryReader { geometry in
      ZStack(alignment: .topLeading) {
        VStack(spacing: 0) {
          ForEach(0..<24, id: \.self) { hour in
            let working = hour >= Preferences.int(Preferences.dayStartHour) && hour < Preferences.int(Preferences.dayEndHour)
            Rectangle()
              .fill(.separator)
              .frame(height: 0.5)
              .frame(maxWidth: .infinity, maxHeight: hourHeight, alignment: .top)
              .background(working ? Color.clear : Color.secondary.opacity(0.06))
          }
        }
        .contentShape(.rect)
        .onTapGesture(count: 2, coordinateSpace: .local) { location in
          let hour = Int(location.y / hourHeight)
          let date = Calendar.current.date(bySettingHour: min(23, hour), minute: 0, second: 0, of: day) ?? day
          onEdit(calendar.draft(for: nil, defaultStart: date))
        }
        if Calendar.current.isDateInToday(day) {
          let minutes = Date().timeIntervalSince(start) / 60
          Rectangle()
            .fill(.red)
            .frame(height: 1.5)
            .offset(y: minutes / 60 * hourHeight)
        }
        ForEach(layout(timed), id: \.0) { event, column, columns in
          let top = max(0, event.startDate.timeIntervalSince(start)) / 3600 * hourHeight
          let bottom = min(86_400, event.endDate.timeIntervalSince(start)) / 3600 * hourHeight
          let width = (geometry.size.width - 4) / CGFloat(columns)
          VStack(alignment: .leading, spacing: 1) {
            Text(event.title ?? "")
              .font(.caption.weight(.semibold))
            Text(event.startDate.formatted(date: .omitted, time: .shortened))
              .font(.caption2)
            if let location = event.location {
              Text(location)
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          }
          .padding(4)
          .frame(width: width - 2, height: max(20, bottom - top), alignment: .topLeading)
          .background(CalendarStore.color(event.calendar).opacity(0.22), in: .rect(cornerRadius: 6))
          .overlay(alignment: .leading) {
            Rectangle()
              .fill(CalendarStore.color(event.calendar))
              .frame(width: 3)
          }
          .clipShape(.rect(cornerRadius: 6))
          .offset(x: 2 + CGFloat(column) * width, y: top)
          .onTapGesture { onEdit(calendar.draft(for: event)) }
        }
      }
    }
    .frame(height: hourHeight * 24)
    .frame(maxWidth: .infinity)
    .overlay(alignment: .leading) {
      Rectangle().fill(.separator).frame(width: 0.5)
    }
  }
}

struct EventEditor: View {
  @Environment(CalendarStore.self) private var calendar
  @Environment(MailStore.self) private var mail
  @Environment(\.dismiss) private var dismiss
  @State private var draft: EventDraft
  @State private var confirmingDelete = false

  init(initial: EventDraft) {
    _draft = State(initialValue: initial)
  }

  var body: some View {
    VStack(spacing: 0) {
      Form {
        TextField("Title", text: $draft.title, prompt: Text("New Event"))
          .font(.title3)
        TextField("Location", text: $draft.location)
        Toggle("All-day", isOn: $draft.isAllDay)
        DatePicker("Starts", selection: $draft.start, displayedComponents: draft.isAllDay ? .date : [.date, .hourAndMinute])
          .onChange(of: draft.start) { old, new in
            draft.end = draft.end.addingTimeInterval(new.timeIntervalSince(old))
          }
        DatePicker("Ends", selection: $draft.end, in: draft.start..., displayedComponents: draft.isAllDay ? .date : [.date, .hourAndMinute])
        Picker("Calendar", selection: $draft.calendarID) {
          ForEach(calendar.writableCalendars, id: \.calendarIdentifier) { item in
            Label {
              Text(item.title)
            } icon: {
              Image(systemName: "circle.fill").foregroundStyle(CalendarStore.color(item))
            }
            .tag(item.calendarIdentifier)
          }
        }
        Picker("Repeat", selection: $draft.repeatRule) {
          ForEach(EventDraft.repeatOptions, id: \.self) { option in
            Text(option == "none" ? "Never" : option.capitalized).tag(option)
          }
        }
        Picker("Reminder", selection: $draft.alertMinutes) {
          ForEach(EventDraft.alertOptions, id: \.self) { minutes in
            Text(minutes.map { $0 == 0 ? "At time of event" : $0 >= 1440 ? "1 day before" : $0 >= 60 ? "\($0 / 60) hour\($0 >= 120 ? "s" : "") before" : "\($0) minutes before" } ?? "None")
              .tag(minutes)
          }
        }
        TextField("URL", text: $draft.url)
        TextField("Description", text: $draft.notes, axis: .vertical)
          .lineLimit(3...8)
      }
      .formStyle(.grouped)
      HStack {
        if !draft.id.isEmpty {
          Button("Delete Event", role: .destructive) { confirmingDelete = true }
        }
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Save") { save() }
          .buttonStyle(.glassProminent)
          .keyboardShortcut(.defaultAction)
      }
      .padding(16)
    }
    .frame(width: 460)
    .task {
      if !calendar.hasEventAccess { await calendar.requestEventAccess() }
      if draft.calendarID.isEmpty { draft.calendarID = calendar.draft(for: nil).calendarID }
    }
    .confirmationDialog("Delete this event?", isPresented: $confirmingDelete) {
      Button("Delete This Event Only", role: .destructive) { delete(span: .thisEvent) }
      Button("Delete All Future Events", role: .destructive) { delete(span: .futureEvents) }
    }
  }

  private func save() {
    do {
      try calendar.save(draft)
      dismiss()
    } catch {
      mail.report(error, title: "Couldn't save the event")
    }
  }

  private func delete(span: EKSpan) {
    do {
      try calendar.delete(eventID: draft.id, span: span)
      dismiss()
    } catch {
      mail.report(error, title: "Couldn't delete the event")
    }
  }
}

/// Events and Tasks › Events Search (Thunderbird's unifinder).
private struct EventSearchPane: View {
  @Environment(CalendarStore.self) private var calendar
  let onEdit: (EventDraft) -> Void
  @State private var query = ""

  var body: some View {
    VStack(spacing: 0) {
      TextField("Search events", text: $query)
        .textFieldStyle(.roundedBorder)
        .padding(8)
      Table(calendar.searchEvents(query)) {
        TableColumn("Title") { (event: EKEvent) in Text(event.title ?? "") }
        TableColumn("Start") { (event: EKEvent) in Text(event.startDate.formatted(date: .abbreviated, time: event.isAllDay ? .omitted : .shortened)) }
        TableColumn("Location") { (event: EKEvent) in Text(event.location ?? "") }
        TableColumn("Calendar") { (event: EKEvent) in Text(event.calendar.title) }
      }
      .contextMenu(forSelectionType: EKEvent.ID.self) { _ in } primaryAction: { ids in
        if let id = ids.first, let event = calendar.searchEvents(query).first(where: { $0.id == id }) {
          onEdit(calendar.draft(for: event))
        }
      }
    }
  }
}

extension EKEvent: @retroactive Identifiable {
  public var id: ObjectIdentifier { ObjectIdentifier(self) }
}
