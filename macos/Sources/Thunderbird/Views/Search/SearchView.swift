/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import EventKit
import SwiftUI
import ThunderbirdCore

struct SearchView: View {
  @Environment(MailStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  @State private var text = ""
  @State private var field = SearchQuery.Field.all
  @State private var scopeKind = SearchScope.Kind.account
  @State private var unreadOnly = false
  @State private var flaggedOnly = false
  @State private var limitDate = false
  @State private var since = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
  @State private var saveName = ""
  @State private var saving = false

  private var query: SearchQuery {
    SearchQuery(text: text, field: field, unreadOnly: unreadOnly, flaggedOnly: flaggedOnly, since: limitDate ? since : nil)
  }

  private var scope: SearchScope {
    SearchScope(kind: scopeKind, folder: store.selectedFolder ?? store.mailAccounts.first.flatMap { account in
      store.folder(role: .inbox, in: account.id).map { FolderSelection(accountID: account.id, path: $0.path) }
    })
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 12) {
        Image(systemName: "text.magnifyingglass")
          .font(.title2)
        TextField("Search messages", text: $text)
          .textFieldStyle(.plain)
          .font(.title3)
          .onSubmit(run)
      }
      .padding(14)
      .glassEffect(.regular, in: .capsule)
      .padding(20)

      Form {
        Picker("Look in", selection: $field) {
          ForEach(SearchQuery.Field.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        Picker("Search", selection: $scopeKind) {
          ForEach(SearchScope.Kind.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        Toggle("Unread only", isOn: $unreadOnly)
        Toggle("Starred only", isOn: $flaggedOnly)
        Toggle("Received since", isOn: $limitDate)
        if limitDate {
          DatePicker("Date", selection: $since, displayedComponents: .date)
        }
        if saving {
          TextField("Saved search name", text: $saveName)
        }
      }
      .formStyle(.grouped)
      .scrollContentBackground(.hidden)

      HStack {
        Toggle("Save as a Saved Search folder", isOn: $saving.animation())
          .toggleStyle(.checkbox)
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(saving ? "Save & Search" : "Search", action: run)
          .buttonStyle(.glassProminent)
          .keyboardShortcut(.defaultAction)
          .disabled(text.isEmpty && !unreadOnly && !flaggedOnly && !limitDate)
      }
      .padding(20)
    }
    .frame(width: 520)
  }

  private func run() {
    if saving {
      store.saveSearch(name: saveName.nilIfEmpty ?? text.nilIfEmpty ?? "Saved Search", query: query, scope: scope)
    } else {
      let query = query
      let scope = scope
      Task { await store.search(query, scope: scope) }
    }
    dismiss()
  }
}

struct TodayPane: View {
  @Environment(CalendarStore.self) private var calendar
  @State private var newEvent: EventDraft?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        VStack(alignment: .leading, spacing: 2) {
          Text(Date().formatted(.dateTime.weekday(.wide)))
            .font(.title2.weight(.semibold))
          Text(Date().formatted(date: .long, time: .omitted))
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))

        if !calendar.hasEventAccess {
          Button("Show My Calendar") { Task { await calendar.requestEventAccess() } }
            .buttonStyle(.glassProminent)
        } else {
          HStack {
            Text("Events")
              .font(.headline)
            Spacer()
            Button {
              newEvent = calendar.draft(for: nil)
            } label: {
              Image(systemName: "plus")
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .help("New event")
          }
          if calendar.upcoming.isEmpty {
            Text("Nothing in the next 7 days.")
              .foregroundStyle(.secondary)
              .font(.callout)
          }
          ForEach(groupedByDay, id: \.0) { day, events in
            Text(Calendar.current.isDateInToday(day) ? "Today" : Calendar.current.isDateInTomorrow(day) ? "Tomorrow" : day.formatted(.dateTime.weekday(.wide).day().month()))
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
            ForEach(events, id: \.self) { event in
              HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2)
                  .fill(CalendarStore.color(event.calendar))
                  .frame(width: 4)
                VStack(alignment: .leading, spacing: 1) {
                  Text(event.title ?? "")
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                  Text(event.isAllDay ? "All day" : event.startDate.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
              }
              .onTapGesture(count: 2) { newEvent = calendar.draft(for: event) }
            }
          }
        }

        TodayTasks()
      }
      .padding(12)
    }
    .sheet(item: $newEvent) { draft in
      EventEditor(initial: draft)
    }
  }

  private var groupedByDay: [(Date, [EKEvent])] {
    let groups = Dictionary(grouping: calendar.upcoming) { Calendar.current.startOfDay(for: $0.startDate) }
    return groups.keys.sorted().map { ($0, groups[$0]!) }
  }
}

private struct TodayTasks: View {
  @Environment(CalendarStore.self) private var calendar
  @State private var newTask = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Tasks")
        .font(.headline)
      if !calendar.hasReminderAccess {
        Button("Show My Tasks") { Task { await calendar.requestReminderAccess() } }
          .buttonStyle(.glass)
      } else {
        ForEach(calendar.reminders.prefix(8), id: \.calendarItemIdentifier) { reminder in
          HStack(spacing: 8) {
            Button {
              calendar.toggleCompleted(reminder)
            } label: {
              Image(systemName: reminder.isCompleted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(CalendarStore.color(reminder.calendar))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(reminder.isCompleted ? "Mark incomplete" : "Mark complete")
            Text(reminder.title ?? "")
              .font(.callout)
              .lineLimit(2)
          }
        }
        TextField("New task", text: $newTask)
          .textFieldStyle(.plain)
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
          .glassEffect(.regular, in: .capsule)
          .onSubmit {
            try? calendar.quickAddTask(newTask)
            newTask = ""
          }
      }
    }
  }
}
