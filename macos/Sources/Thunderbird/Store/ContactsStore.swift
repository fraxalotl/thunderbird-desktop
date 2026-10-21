/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

@preconcurrency import Contacts
import Foundation
import Observation
import ThunderbirdCore

struct CollectedAddress: Codable, Hashable, Identifiable {
  var address: MailAddress
  var lastUsed: Date
  var timesUsed: Int
  var id: String { address.email.lowercased() }
}

enum AddressBookSelection: Hashable {
  case all
  case container(String)
  case group(String)
  case collected
}

/// A contact as shown in the address book, flattened from CNContact.
struct ContactCard: Identifiable, Hashable {
  var id: String
  var givenName: String
  var familyName: String
  var nickname: String
  var organization: String
  var jobTitle: String
  var emails: [LabeledValue]
  var phones: [LabeledValue]
  var addresses: [LabeledValue]
  var urls: [LabeledValue]
  var birthday: DateComponents?
  var thumbnail: Data?
  var isCollected = false

  struct LabeledValue: Hashable, Identifiable {
    var id = UUID()
    var label: String
    var value: String
  }

  var displayName: String {
    let name = [givenName, familyName].filter { !$0.isEmpty }.joined(separator: " ")
    if !name.isEmpty { return name }
    if !organization.isEmpty { return organization }
    return emails.first?.value ?? "No Name"
  }

  var sortKey: String { (familyName.isEmpty ? displayName : familyName + givenName).lowercased() }

  static let empty = ContactCard(
    id: "", givenName: "", familyName: "", nickname: "", organization: "", jobTitle: "",
    emails: [LabeledValue(label: "work", value: "")], phones: [], addresses: [], urls: [], birthday: nil, thumbnail: nil)
}

@MainActor
@Observable
final class ContactsStore {
  private(set) var authorization: CNAuthorizationStatus = CNContactStore.authorizationStatus(for: .contacts)
  private(set) var containers: [CNContainer] = []
  private(set) var groups: [CNGroup] = []
  private(set) var contacts: [ContactCard] = []
  private(set) var collected: [CollectedAddress] = []
  var selection: AddressBookSelection = .all {
    didSet { reload() }
  }
  var searchText = ""
  var pendingNewContact = false
  var pendingNewList = false

  @ObservationIgnored private let store = CNContactStore()
  @ObservationIgnored private var changeObserver: NSObjectProtocol?
  private static let collectedKey = "collectedAddresses"

  private static let keys: [CNKeyDescriptor] =
    [
      CNContactIdentifierKey, CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey,
      CNContactOrganizationNameKey, CNContactJobTitleKey, CNContactEmailAddressesKey, CNContactPhoneNumbersKey,
      CNContactPostalAddressesKey, CNContactUrlAddressesKey, CNContactBirthdayKey, CNContactThumbnailImageDataKey,
    ].map { $0 as CNKeyDescriptor } + [CNContactVCardSerialization.descriptorForRequiredKeys()]

  init() {
    if let data = UserDefaults.standard.data(forKey: Self.collectedKey),
      let stored = try? JSONDecoder().decode([CollectedAddress].self, from: data)
    {
      collected = stored
    }
    changeObserver = NotificationCenter.default.addObserver(
      forName: .CNContactStoreDidChange, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.reload() }
    }
    if authorization == .authorized {
      reload()
    }
  }

  var isAuthorized: Bool { authorization == .authorized }

  func requestAccess() async {
    _ = try? await store.requestAccess(for: .contacts)
    authorization = CNContactStore.authorizationStatus(for: .contacts)
    reload()
  }

  func reload() {
    guard isAuthorized else {
      contacts = selection == .collected ? collectedCards : []
      return
    }
    containers = (try? store.containers(matching: nil)) ?? []
    groups = (try? store.groups(matching: nil)) ?? []
    if selection == .collected {
      contacts = collectedCards
      return
    }
    let request = CNContactFetchRequest(keysToFetch: Self.keys)
    switch selection {
    case .container(let id): request.predicate = CNContact.predicateForContactsInContainer(withIdentifier: id)
    case .group(let id): request.predicate = CNContact.predicateForContactsInGroup(withIdentifier: id)
    default: break
    }
    var result: [ContactCard] = []
    try? store.enumerateContacts(with: request) { contact, _ in
      result.append(Self.card(contact))
    }
    contacts = result.sorted { $0.sortKey < $1.sortKey }
  }

  private var collectedCards: [ContactCard] {
    collected.sorted { $0.lastUsed > $1.lastUsed }.map { entry in
      let parts = (entry.address.name ?? "").split(separator: " ", maxSplits: 1).map(String.init)
      var card = ContactCard.empty
      card.id = "collected:\(entry.id)"
      card.givenName = parts.first ?? ""
      card.familyName = parts.count > 1 ? parts[1] : ""
      card.emails = [ContactCard.LabeledValue(label: "email", value: entry.address.email)]
      card.isCollected = true
      return card
    }
  }

  var visibleContacts: [ContactCard] {
    let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
    guard !query.isEmpty else { return contacts }
    return contacts.filter { card in
      card.displayName.lowercased().contains(query) || card.organization.lowercased().contains(query)
        || card.emails.contains { $0.value.lowercased().contains(query) }
        || card.phones.contains { $0.value.contains(query) }
    }
  }

  private static func label(_ raw: String?) -> String {
    guard let raw else { return "other" }
    return CNLabeledValue<NSString>.localizedString(forLabel: raw)
  }

  static func card(_ contact: CNContact) -> ContactCard {
    let formatter = CNPostalAddressFormatter()
    return ContactCard(
      id: contact.identifier,
      givenName: contact.givenName,
      familyName: contact.familyName,
      nickname: contact.nickname,
      organization: contact.organizationName,
      jobTitle: contact.jobTitle,
      emails: contact.emailAddresses.map { .init(label: label($0.label), value: $0.value as String) },
      phones: contact.phoneNumbers.map { .init(label: label($0.label), value: $0.value.stringValue) },
      addresses: contact.postalAddresses.map { .init(label: label($0.label), value: formatter.string(from: $0.value)) },
      urls: contact.urlAddresses.map { .init(label: label($0.label), value: $0.value as String) },
      birthday: contact.birthday,
      thumbnail: contact.thumbnailImageData)
  }

  // MARK: - Editing

  private func mutable(for card: ContactCard) -> CNMutableContact? {
    guard !card.id.isEmpty, !card.isCollected else { return CNMutableContact() }
    let contact = try? store.unifiedContact(withIdentifier: card.id, keysToFetch: Self.keys)
    return contact?.mutableCopy() as? CNMutableContact
  }

  func save(_ card: ContactCard) throws {
    guard let contact = mutable(for: card) else { return }
    contact.givenName = card.givenName
    contact.familyName = card.familyName
    contact.nickname = card.nickname
    contact.organizationName = card.organization
    contact.jobTitle = card.jobTitle
    contact.emailAddresses = card.emails.filter { !$0.value.isEmpty }.map {
      CNLabeledValue(label: $0.label == "work" ? CNLabelWork : $0.label == "home" ? CNLabelHome : CNLabelOther, value: $0.value as NSString)
    }
    contact.phoneNumbers = card.phones.filter { !$0.value.isEmpty }.map {
      CNLabeledValue(label: $0.label == "mobile" ? CNLabelPhoneNumberMobile : CNLabelWork, value: CNPhoneNumber(stringValue: $0.value))
    }
    contact.urlAddresses = card.urls.filter { !$0.value.isEmpty }.map {
      CNLabeledValue(label: CNLabelURLAddressHomePage, value: $0.value as NSString)
    }
    contact.birthday = card.birthday
    let request = CNSaveRequest()
    if card.id.isEmpty || card.isCollected {
      var containerID: String?
      if case .container(let id) = selection { containerID = id }
      request.add(contact, toContainerWithIdentifier: containerID)
      if case .group(let groupID) = selection, let group = groups.first(where: { $0.identifier == groupID }) {
        request.addMember(contact, to: group)
      }
    } else {
      request.update(contact)
    }
    try store.execute(request)
    if card.isCollected {
      collected.removeAll { "collected:\($0.id)" == card.id }
      persistCollected()
    }
    reload()
  }

  func delete(_ card: ContactCard) throws {
    if card.isCollected {
      collected.removeAll { "collected:\($0.id)" == card.id }
      persistCollected()
      reload()
      return
    }
    guard let contact = mutable(for: card) else { return }
    let request = CNSaveRequest()
    request.delete(contact)
    try store.execute(request)
    reload()
  }

  func addGroup(named name: String) throws {
    let group = CNMutableGroup()
    group.name = name
    let request = CNSaveRequest()
    request.add(group, toContainerWithIdentifier: nil)
    try store.execute(request)
    reload()
  }

  func importVCards(from url: URL) throws -> Int {
    let data = try Data(contentsOf: url)
    let imported = try CNContactVCardSerialization.contacts(with: data)
    let request = CNSaveRequest()
    for contact in imported {
      if let mutable = contact.mutableCopy() as? CNMutableContact {
        request.add(mutable, toContainerWithIdentifier: nil)
      }
    }
    try store.execute(request)
    reload()
    return imported.count
  }

  func exportVCards(_ cards: [ContactCard]) throws -> Data {
    let ids = cards.filter { !$0.isCollected }.map(\.id)
    let fetched = try store.unifiedContacts(
      matching: CNContact.predicateForContacts(withIdentifiers: ids), keysToFetch: Self.keys)
    return try CNContactVCardSerialization.data(with: fetched)
  }

  // MARK: - Collected addresses and autocomplete

  func collect(_ addresses: [MailAddress]) {
    let known = Set(contacts.flatMap { $0.emails.map { $0.value.lowercased() } })
    for address in addresses where !known.contains(address.email.lowercased()) {
      if let index = collected.firstIndex(where: { $0.id == address.email.lowercased() }) {
        collected[index].lastUsed = Date()
        collected[index].timesUsed += 1
        if address.name != nil { collected[index].address = address }
      } else {
        collected.append(CollectedAddress(address: address, lastUsed: Date(), timesUsed: 1))
      }
    }
    persistCollected()
  }

  private func persistCollected() {
    UserDefaults.standard.set(try? JSONEncoder().encode(collected), forKey: Self.collectedKey)
  }

  func suggestions(for fragment: String, limit: Int = 8) -> [MailAddress] {
    let query = fragment.trimmingCharacters(in: .whitespaces).lowercased()
    guard query.count >= 1 else { return [] }
    var results: [MailAddress] = []
    var seen = Set<String>()
    if isAuthorized {
      let predicate = CNContact.predicateForContacts(matchingName: query)
      let byName = (try? store.unifiedContacts(matching: predicate, keysToFetch: Self.keys)) ?? []
      let byEmail = (try? store.unifiedContacts(
        matching: CNContact.predicateForContacts(matchingEmailAddress: query), keysToFetch: Self.keys)) ?? []
      for contact in byName + byEmail {
        let name = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
        for email in contact.emailAddresses {
          let address = MailAddress(name: name, email: email.value as String)
          if seen.insert(address.email.lowercased()).inserted { results.append(address) }
        }
      }
      for card in contacts where results.count < limit {
        for email in card.emails where email.value.lowercased().hasPrefix(query) {
          let address = MailAddress(name: card.displayName, email: email.value)
          if seen.insert(address.email.lowercased()).inserted { results.append(address) }
        }
      }
    }
    for entry in collected.sorted(by: { $0.timesUsed > $1.timesUsed })
    where entry.address.email.lowercased().contains(query) || (entry.address.name?.lowercased().contains(query) ?? false) {
      if seen.insert(entry.id).inserted { results.append(entry.address) }
    }
    return Array(results.prefix(limit))
  }

  /// Members of a contact group (mailing list) by name, for Expand List.
  func members(ofList name: String) -> [MailAddress] {
    let listName = name.hasPrefix("list:") ? String(name.dropFirst(5)) : name
    guard isAuthorized, let group = groups.first(where: { $0.name.caseInsensitiveCompare(listName) == .orderedSame }) else { return [] }
    let request = CNContactFetchRequest(keysToFetch: Self.keys)
    request.predicate = CNContact.predicateForContactsInGroup(withIdentifier: group.identifier)
    var result: [MailAddress] = []
    try? store.enumerateContacts(with: request) { contact, _ in
      let card = Self.card(contact)
      if let email = card.emails.first?.value {
        result.append(MailAddress(name: card.displayName, email: email))
      }
    }
    return result
  }

  func card(forEmail email: String) -> ContactCard? {
    contacts.first { $0.emails.contains { $0.value.caseInsensitiveCompare(email) == .orderedSame } }
  }

  func addToAddressBook(_ address: MailAddress) throws {
    var card = ContactCard.empty
    let parts = (address.name ?? "").split(separator: " ", maxSplits: 1).map(String.init)
    card.givenName = parts.first ?? ""
    card.familyName = parts.count > 1 ? parts[1] : ""
    card.emails = [ContactCard.LabeledValue(label: "other", value: address.email)]
    try save(card)
  }
}
