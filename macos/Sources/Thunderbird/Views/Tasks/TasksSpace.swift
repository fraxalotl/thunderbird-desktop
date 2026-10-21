/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import EventKit
import SwiftUI
import ThunderbirdCore

struct TasksSpace: View {
  @Environment(CalendarStore.self) private var calendar
  @State private var newTitle = ""
  @FocusState private var addFocused: Bool

  var body: some View {
    @Bindable var calendar = calendar
    if !calendar.hasReminderAccess {
      PermissionView(
        title: "Use Your Tasks", symbol: "checklist",
        message: "Zapdos shows and edits the reminder lists you already use on this Mac, including iCloud and CalDAV task lists.",
        action: { await calendar.requestReminderAccess() })
    } else {
      NavigationSplitView {
        List(selection: $calendar.taskFilter) {
          Section {
            Label("Today", systemImage: "sun.max").tag(TaskFilter.today)
            Label("Scheduled", systemImage: "calendar").tag(TaskFilter.scheduled)
            Label("All", systemImage: "tray").tag(TaskFilter.all)
            Label("Completed", systemImage: "checkmark.circle").tag(TaskFilter.completed)
          }
          Section("Lists") {
            ForEach(calendar.reminderLists, id: \.calendarIdentifier) { list in
              Label {
                Text(list.title)
              } icon: {
                Image(systemName: "list.bullet.circle.fill").foregroundStyle(CalendarStore.color(list))
              }
              .tag(TaskFilter.list(list.calendarIdentifier))
            }
          }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 230)
      } content: {
        List(calendar.reminders, id: \.calendarItemIdentifier, selection: $calendar.selectedTaskID) { reminder in
          TaskRow(reminder: reminder)
            .tag(reminder.calendarItemIdentifier)
        }
        .listStyle(.inset)
        .overlay {
          if calendar.reminders.isEmpty {
            ContentUnavailableView("No Tasks", systemImage: "checklist")
          }
        }
        .safeAreaBar(edge: .bottom) {
          HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill")
              .foregroundStyle(.tint)
            TextField("Add a task", text: $newTitle)
              .textFieldStyle(.plain)
              .focused($addFocused)
              .onSubmit(addTask)
          }
          .padding(.horizontal, 14)
          .padding(.vertical, 10)
          .glassEffect(.regular.interactive(), in: .capsule)
          .padding(12)
        }
        .navigationSplitViewColumnWidth(min: 300, ideal: 380)
      } detail: {
        if let selection = calendar.selectedTaskID, let reminder = calendar.reminders.first(where: { $0.calendarItemIdentifier == selection }) {
          TaskEditor(initial: calendar.taskDraft(for: reminder))
            .id(selection)
        } else {
          ContentUnavailableView("No Task Selected", systemImage: "checkmark.circle")
        }
      }
      .navigationTitle("Tasks")
      .onChange(of: calendar.pendingTask, initial: true) {
        if calendar.pendingTask {
          addFocused = true
          calendar.pendingTask = false
        }
      }
    }
  }

  private func addTask() {
    let title = newTitle.trimmingCharacters(in: .whitespaces)
    guard !title.isEmpty else { return }
    try? calendar.quickAddTask(title)
    newTitle = ""
  }
}

private struct TaskRow: View {
  @Environment(CalendarStore.self) private var calendar
  let reminder: EKReminder

  var body: some View {
    HStack(spacing: 10) {
      Button {
        calendar.toggleCompleted(reminder)
      } label: {
        Image(systemName: reminder.isCompleted ? "checkmark.circle.fill" : "circle")
          .font(.title3)
          .foregroundStyle(CalendarStore.color(reminder.calendar))
      }
      .buttonStyle(.plain)
      .accessibilityLabel(reminder.isCompleted ? "Mark incomplete" : "Mark complete")
      VStack(alignment: .leading, spacing: 2) {
        Text(reminder.title ?? "")
          .strikethrough(reminder.isCompleted)
          .foregroundStyle(reminder.isCompleted ? .secondary : .primary)
        if let due = reminder.dueDateComponents?.date {
          Text(due.formatted(date: .abbreviated, time: reminder.dueDateComponents?.hour == nil ? .omitted : .shortened))
            .font(.caption)
            .foregroundStyle(due < Date() && !reminder.isCompleted ? .red : .secondary)
        }
      }
      Spacer()
      if reminder.priority > 0 {
        Text(String(repeating: "!", count: reminder.priority <= 4 ? 3 : reminder.priority == 5 ? 2 : 1))
          .font(.callout.weight(.bold))
          .foregroundStyle(.orange)
          .accessibilityLabel("Priority")
      }
    }
    .padding(.vertical, 3)
  }
}

private struct TaskEditor: View {
  @Environment(CalendarStore.self) private var calendar
  @Environment(MailStore.self) private var mail
  @State private var draft: TaskDraft

  init(initial: TaskDraft) {
    _draft = State(initialValue: initial)
  }

  var body: some View {
    Form {
      TextField("Title", text: $draft.title)
        .font(.title3)
      Toggle("Completed", isOn: $draft.isCompleted)
      Toggle("Due date", isOn: $draft.hasDueDate)
      if draft.hasDueDate {
        DatePicker("Due", selection: $draft.due)
      }
      Picker("Priority", selection: $draft.priority) {
        Text("None").tag(0)
        Text("Low").tag(9)
        Text("Medium").tag(5)
        Text("High").tag(1)
      }
      Picker("List", selection: $draft.listID) {
        ForEach(calendar.reminderLists, id: \.calendarIdentifier) { Text($0.title).tag($0.calendarIdentifier) }
      }
      TextField("Notes", text: $draft.notes, axis: .vertical)
        .lineLimit(4...12)
      HStack {
        Button("Delete Task", role: .destructive) {
          try? calendar.delete(taskID: draft.id)
        }
        Spacer()
        Button("Save") {
          do { try calendar.save(draft) } catch { mail.report(error, title: "Couldn't save the task") }
        }
        .buttonStyle(.glassProminent)
        .keyboardShortcut("s")
      }
    }
    .formStyle(.grouped)
  }
}
