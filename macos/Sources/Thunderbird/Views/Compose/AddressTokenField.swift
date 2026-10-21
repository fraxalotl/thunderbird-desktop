/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import AppKit
import SwiftUI
import ThunderbirdCore

/// An address row with Thunderbird-style pills, autocomplete from Contacts and Collected
/// Addresses, and a pill menu (edit, move to another row, expand list, copy).
struct AddressTokenField: NSViewRepresentable {
  @Binding var text: String
  let placeholder: String
  let suggestions: (String) -> [MailAddress]
  let expandList: (String) -> [MailAddress]
  var onMove: ((String, String) -> Void)?

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> NSTokenField {
    let field = NSTokenField()
    field.delegate = context.coordinator
    field.tokenStyle = .rounded
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.placeholderString = placeholder
    field.completionDelay = 0.1
    field.tokenizingCharacterSet = CharacterSet(charactersIn: ",;")
    field.lineBreakMode = .byWordWrapping
    field.cell?.wraps = true
    field.cell?.isScrollable = false
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    field.objectValue = Self.tokens(text)
    return field
  }

  func updateNSView(_ field: NSTokenField, context: Context) {
    context.coordinator.parent = self
    if context.coordinator.lastText != text {
      context.coordinator.lastText = text
      field.objectValue = Self.tokens(text)
    }
  }

  static func tokens(_ text: String) -> [String] {
    MailAddress.parseList(text).map(\.formatted)
  }

  final class Coordinator: NSObject, NSTokenFieldDelegate {
    var parent: AddressTokenField
    var lastText: String

    init(_ parent: AddressTokenField) {
      self.parent = parent
      self.lastText = parent.text
    }

    private func sync(_ field: NSTokenField) {
      let tokens = (field.objectValue as? [Any] ?? []).compactMap { $0 as? String }
      let text = tokens.joined(separator: ", ")
      lastText = text
      parent.text = text
    }

    func controlTextDidEndEditing(_ notification: Notification) {
      if let field = notification.object as? NSTokenField { sync(field) }
    }

    func controlTextDidChange(_ notification: Notification) {
      if let field = notification.object as? NSTokenField { sync(field) }
    }

    func tokenField(
      _ tokenField: NSTokenField, completionsForSubstring substring: String, indexOfToken tokenIndex: Int,
      indexOfSelectedItem selectedIndex: UnsafeMutablePointer<Int>?
    ) -> [Any]? {
      let completions: [String] = MainActor.assumeIsolated { parent.suggestions(substring).map(\.formatted) }
      return completions
    }

    func tokenField(_ tokenField: NSTokenField, displayStringForRepresentedObject representedObject: Any) -> String? {
      guard let token = representedObject as? String else { return nil }
      return MailAddress.parseList(token).first?.name ?? token
    }

    func tokenField(_ tokenField: NSTokenField, hasMenuForRepresentedObject representedObject: Any) -> Bool { true }

    func tokenField(_ tokenField: NSTokenField, menuForRepresentedObject representedObject: Any) -> NSMenu? {
      guard let token = representedObject as? String else { return nil }
      let menu = NSMenu()
      let address = MailAddress.parseList(token).first
      menu.addItem(withTitle: address?.formatted ?? token, action: nil, keyEquivalent: "").isEnabled = false
      menu.addItem(.separator())
      menu.addItem(ClosureMenuItem("Copy Address") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address?.email ?? token, forType: .string)
      })
      menu.addItem(ClosureMenuItem("Delete") { [weak self] in self?.remove(token, from: tokenField) })
      if let onMove = parent.onMove {
        menu.addItem(.separator())
        for row in ["To", "Cc", "Bcc"] {
          menu.addItem(ClosureMenuItem("Move to \(row)") { [weak self] in
            self?.remove(token, from: tokenField)
            onMove(token, row)
          })
        }
      }
      let members = MainActor.assumeIsolated { parent.expandList(token) }
      if !members.isEmpty {
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Expand List") { [weak self] in
          guard let self else { return }
          var tokens = (tokenField.objectValue as? [Any] ?? []).compactMap { $0 as? String }
          if let index = tokens.firstIndex(of: token) {
            tokens.replaceSubrange(index...index, with: members.map(\.formatted))
          }
          tokenField.objectValue = tokens
          self.sync(tokenField)
        })
      }
      return menu
    }

    private func remove(_ token: String, from field: NSTokenField) {
      var tokens = (field.objectValue as? [Any] ?? []).compactMap { $0 as? String }
      tokens.removeAll { $0 == token }
      field.objectValue = tokens
      sync(field)
    }
  }
}

/// An NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
  private let handler: () -> Void

  init(_ title: String, handler: @escaping () -> Void) {
    self.handler = handler
    super.init(title: title, action: #selector(run), keyEquivalent: "")
    target = self
  }

  required init(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  @objc private func run() { handler() }
}
