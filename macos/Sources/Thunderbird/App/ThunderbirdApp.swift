/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }
}

@main
struct ThunderbirdApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @State private var store = MailStore()

  var body: some Scene {
    Window("Thunderbird", id: WindowID.main) {
      MainWindow()
        .environment(store)
    }
    .defaultSize(width: 1280, height: 800)
    .commands {
      MailCommands(store: store)
    }

    WindowGroup("Write", id: WindowID.compose, for: ComposeDraft.self) { $draft in
      ComposeWindow(initial: draft ?? store.newDraft())
        .environment(store)
    }
    .defaultSize(width: 760, height: 640)
    .windowToolbarStyle(.unified)

    Settings {
      SettingsView()
        .environment(store)
    }
  }
}

enum WindowID {
  static let main = "main"
  static let compose = "compose"
}
