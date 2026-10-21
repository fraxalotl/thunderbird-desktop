/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import AppKit
import SwiftUI
import ThunderbirdCore
import UniformTypeIdentifiers

struct AddressBookSpace: View {
  @Environment(ContactsStore.self) private var contacts
  @Environment(MailStore.self) private var mail
  @Environment(\.openWindow) private var openWindow
  @State private var selection: Set<String> = []
  @State private var editing: ContactCard?
  @State private var newGroupName = ""
  @State private var addingGroup = false
  @State private var importing = false

  var body: some View {
    @Bindable var contacts = contacts
    NavigationSplitView {
      List(selection: $contacts.selection) {
        Section {
          Label("All Contacts", systemImage: "person.2").tag(AddressBookSelection.all)
          Label("Collected Addresses", systemImage: "tray.full").tag(AddressBookSelection.collected)
        }
        if contacts.isAuthorized {
          Section("Address Books") {
            ForEach(contacts.containers, id: \.identifier) { container in
              Label(container.name.isEmpty ? "Contacts" : container.name, systemImage: "book.closed")
                .tag(AddressBookSelection.container(container.identifier))
            }
          }
          if !contacts.groups.isEmpty {
            Section("Lists") {
              ForEach(contacts.groups, id: \.identifier) { group in
                Label(group.name, systemImage: "person.3")
                  .tag(AddressBookSelection.group(group.identifier))
              }
            }
          }
        }
      }
      .listStyle(.sidebar)
      .safeAreaInset(edge: .bottom) {
        HStack {
          Button {
            addingGroup = true
          } label: {
            Label("New List", systemImage: "plus")
          }
          .buttonStyle(.glass)
          .disabled(!contacts.isAuthorized)
          Spacer()
        }
        .controlSize(.small)
        .padding(12)
      }
      .navigationSplitViewColumnWidth(min: 200, ideal: 230)
    } content: {
      List(contacts.visibleContacts, selection: $selection) { card in
        HStack(spacing: 10) {
          AvatarView(address: card.emails.first.map { MailAddress(name: card.displayName, email: $0.value) }, size: 30, image: card.thumbnail)
          VStack(alignment: .leading, spacing: 1) {
            Text(card.displayName)
            if let email = card.emails.first?.value {
              Text(email)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }
        .tag(card.id)
        .contextMenu {
          if let email = card.emails.first?.value {
            Button("Write Message") {
              openWindow(id: WindowID.compose, value: mail.newDraft(to: MailAddress(name: card.displayName, email: email).formatted))
            }
          }
          Button("Edit") { editing = card }
          Button("Delete", role: .destructive) { try? contacts.delete(card) }
        }
      }
      .listStyle(.inset)
      .searchable(text: $contacts.searchText, placement: .toolbar, prompt: "Search contacts")
      .overlay {
        if !contacts.isAuthorized && contacts.selection != .collected {
          PermissionView(
            title: "Use Your Contacts", symbol: "person.crop.rectangle.stack",
            message: "Thunderbird uses the contacts on this Mac, including iCloud, Google and CardDAV address books, and suggests them as you type.",
            action: { await contacts.requestAccess() })
        } else if contacts.visibleContacts.isEmpty {
          ContentUnavailableView("No Contacts", systemImage: "person.crop.circle.badge.questionmark")
        }
      }
      .navigationSplitViewColumnWidth(min: 260, ideal: 320)
    } detail: {
      let selected = contacts.visibleContacts.filter { selection.contains($0.id) }
      if selected.count == 1, let card = selected.first {
        ContactDetail(card: card, onEdit: { editing = card })
      } else if selected.count > 1 {
        VStack(spacing: 16) {
          ContentUnavailableView("\(selected.count) Contacts Selected", systemImage: "person.2")
          Button("Write to All") {
            let to = selected.compactMap { card in
              card.emails.first.map { MailAddress(name: card.displayName, email: $0.value).formatted }
            }.joined(separator: ", ")
            openWindow(id: WindowID.compose, value: mail.newDraft(to: to))
          }
          .buttonStyle(.glassProminent)
        }
      } else {
        ContentUnavailableView("No Contact Selected", systemImage: "person.crop.circle")
      }
    }
    .navigationTitle("Address Book")
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        Button {
          importing = true
        } label: {
          Label("Import vCard", systemImage: "square.and.arrow.down")
        }
        .help("Import contacts from a vCard file")
        .disabled(!contacts.isAuthorized)
        Button {
          exportSelected()
        } label: {
          Label("Export vCard", systemImage: "square.and.arrow.up")
        }
        .help("Export the selected contacts as vCard")
        .disabled(selection.isEmpty)
      }
      ToolbarSpacer(.fixed, placement: .primaryAction)
      ToolbarItem(placement: .primaryAction) {
        Button {
          editing = .empty
        } label: {
          Label("New Contact", systemImage: "person.badge.plus")
        }
        .buttonStyle(.glassProminent)
        .disabled(!contacts.isAuthorized)
      }
    }
    .sheet(item: $editing) { card in
      ContactEditor(initial: card)
    }
    .onChange(of: contacts.pendingNewContact, initial: true) {
      if contacts.pendingNewContact {
        editing = .empty
        contacts.pendingNewContact = false
      }
    }
    .onChange(of: contacts.pendingNewList, initial: true) {
      if contacts.pendingNewList {
        addingGroup = true
        contacts.pendingNewList = false
      }
    }
    .alert("New List", isPresented: $addingGroup) {
      TextField("Name", text: $newGroupName)
      Button("Create") {
        try? contacts.addGroup(named: newGroupName)
        newGroupName = ""
      }
      Button("Cancel", role: .cancel) {}
    }
    .fileImporter(isPresented: $importing, allowedContentTypes: [.vCard]) { result in
      if case .success(let url) = result {
        do { _ = try contacts.importVCards(from: url) } catch { mail.report(error, title: "Couldn't import contacts") }
      }
    }
  }

  private func exportSelected() {
    let cards = contacts.visibleContacts.filter { selection.contains($0.id) }
    guard let data = try? contacts.exportVCards(cards) else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.vCard]
    panel.nameFieldStringValue = cards.count == 1 ? "\(cards[0].displayName).vcf" : "Contacts.vcf"
    if panel.runModal() == .OK, let url = panel.url {
      try? data.write(to: url)
    }
  }
}

private struct ContactDetail: View {
  @Environment(MailStore.self) private var mail
  @Environment(\.openWindow) private var openWindow
  let card: ContactCard
  let onEdit: () -> Void

  var body: some View {
    ScrollView {
      VStack(spacing: 18) {
        VStack(spacing: 10) {
          AvatarView(
            address: card.emails.first.map { MailAddress(name: card.displayName, email: $0.value) }, size: 88,
            image: card.thumbnail)
          Text(card.displayName)
            .font(.title.weight(.semibold))
          if !card.organization.isEmpty || !card.jobTitle.isEmpty {
            Text([card.jobTitle, card.organization].filter { !$0.isEmpty }.joined(separator: ", "))
              .foregroundStyle(.secondary)
          }
          GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
              if let email = card.emails.first?.value {
                Button {
                  openWindow(id: WindowID.compose, value: mail.newDraft(to: MailAddress(name: card.displayName, email: email).formatted))
                } label: {
                  Label("Write", systemImage: "envelope")
                }
                .buttonStyle(.glassProminent)
              }
              Button(card.isCollected ? "Add to Contacts" : "Edit", action: onEdit)
                .buttonStyle(.glass)
            }
          }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))

        VStack(alignment: .leading, spacing: 12) {
          section("Email", card.emails, link: { URL(string: "mailto:\($0)") })
          section("Phone", card.phones, link: { URL(string: "tel:\($0.filter { !$0.isWhitespace })") })
          section("Address", card.addresses, link: { _ in nil })
          section("Website", card.urls, link: { URL(string: $0) })
          if let birthday = card.birthday, let date = Calendar.current.date(from: birthday) {
            labeled("birthday", date.formatted(date: .long, time: .omitted), link: nil)
          }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
      }
      .padding(20)
    }
  }

  @ViewBuilder
  private func section(_ title: String, _ values: [ContactCard.LabeledValue], link: @escaping (String) -> URL?) -> some View {
    ForEach(values) { value in
      labeled(value.label, value.value, link: link(value.value))
    }
  }

  private func labeled(_ label: String, _ value: String, link: URL?) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
      if let link {
        Link(value, destination: link)
      } else {
        Text(value)
          .textSelection(.enabled)
      }
    }
  }
}

private struct ContactEditor: View {
  @Environment(ContactsStore.self) private var contacts
  @Environment(MailStore.self) private var mail
  @Environment(\.dismiss) private var dismiss
  @State private var card: ContactCard
  @State private var hasBirthday: Bool
  @State private var birthday: Date

  init(initial: ContactCard) {
    _card = State(initialValue: initial)
    _hasBirthday = State(initialValue: initial.birthday != nil)
    _birthday = State(initialValue: initial.birthday.flatMap { Calendar.current.date(from: $0) } ?? Date())
  }

  var body: some View {
    VStack(spacing: 0) {
      Form {
        Section("Name") {
          TextField("First name", text: $card.givenName)
          TextField("Last name", text: $card.familyName)
          TextField("Nickname", text: $card.nickname)
          TextField("Organisation", text: $card.organization)
          TextField("Job title", text: $card.jobTitle)
        }
        Section("Email") {
          ForEach($card.emails) { $email in
            HStack {
              Picker("Type", selection: $email.label) {
                Text("work").tag("work")
                Text("home").tag("home")
                Text("other").tag("other")
                if !["work", "home", "other"].contains(email.label) { Text(email.label).tag(email.label) }
              }
              .labelsHidden()
              .fixedSize()
              TextField("Email", text: $email.value)
            }
          }
          Button("Add Email") { card.emails.append(.init(label: "home", value: "")) }
        }
        Section("Phone") {
          ForEach($card.phones) { $phone in
            HStack {
              Picker("Type", selection: $phone.label) {
                Text("mobile").tag("mobile")
                Text("work").tag("work")
                if !["mobile", "work"].contains(phone.label) { Text(phone.label).tag(phone.label) }
              }
              .labelsHidden()
              .fixedSize()
              TextField("Phone", text: $phone.value)
            }
          }
          Button("Add Phone") { card.phones.append(.init(label: "mobile", value: "")) }
        }
        Section("Other") {
          ForEach($card.urls) { $url in
            TextField("Website", text: $url.value)
          }
          Button("Add Website") { card.urls.append(.init(label: "homepage", value: "https://")) }
          Toggle("Birthday", isOn: $hasBirthday)
          if hasBirthday {
            DatePicker("Date", selection: $birthday, displayedComponents: .date)
          }
        }
      }
      .formStyle(.grouped)
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Save") {
          card.birthday = hasBirthday ? Calendar.current.dateComponents([.year, .month, .day], from: birthday) : nil
          do {
            try contacts.save(card)
            dismiss()
          } catch {
            mail.report(error, title: "Couldn't save the contact")
          }
        }
        .buttonStyle(.glassProminent)
        .keyboardShortcut(.defaultAction)
      }
      .padding(16)
    }
    .frame(width: 480, height: 620)
  }
}
