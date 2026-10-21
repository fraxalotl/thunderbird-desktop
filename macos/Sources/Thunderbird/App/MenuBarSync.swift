/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import AppKit
import SwiftUI

/// Thunderbird's compose window has its own menu bar (File, Edit, View, Insert, Format, Options,
/// Security, Tools, Window, Help) while the main window has Go, Message and Events and Tasks.
/// SwiftUI menus are app-wide, so this shows and hides the top-level menus for the key window.
@MainActor
final class MenuBarSync {
  static let shared = MenuBarSync()

  static let mainOnly: Set<String> = ["Go", "Message", "Events and Tasks"]
  static let composeOnly: Set<String> = ["Insert", "Format", "Options", "Security"]

  private var composeWindows = NSHashTable<NSWindow>.weakObjects()
  private var observers: [NSObjectProtocol] = []
  /// Whether the Security menu applies (an identity has OpenPGP or S/MIME set up).
  var securityAvailable = false {
    didSet { apply() }
  }

  func start() {
    guard observers.isEmpty else { return }
    let center = NotificationCenter.default
    for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSMenu.didAddItemNotification] {
      observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { MenuBarSync.shared.scheduleApply() }
      })
    }
    scheduleApply()
  }

  func register(_ window: NSWindow) {
    composeWindows.add(window)
    scheduleApply()
  }

  private var pending = false

  private func scheduleApply() {
    guard !pending else { return }
    pending = true
    DispatchQueue.main.async {
      self.pending = false
      self.apply()
    }
  }

  private func apply() {
    guard let menu = NSApp.mainMenu else { return }
    let composing = NSApp.keyWindow.map { composeWindows.contains($0) } ?? false
    for item in menu.items {
      let hidden: Bool
      if Self.mainOnly.contains(item.title) {
        hidden = composing
      } else if item.title == "Security" {
        hidden = !composing || !securityAvailable
      } else if Self.composeOnly.contains(item.title) {
        hidden = !composing
      } else {
        continue
      }
      if item.isHidden != hidden { item.isHidden = hidden }
    }
  }
}

/// Registers the hosting window as a compose window for ``MenuBarSync``.
struct ComposeWindowMarker: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView {
    let view = MarkerView()
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {}

  private final class MarkerView: NSView {
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let window { MenuBarSync.shared.register(window) }
    }
  }
}
