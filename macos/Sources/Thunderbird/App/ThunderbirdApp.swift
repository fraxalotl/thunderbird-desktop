/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import AppKit
import SwiftUI
import ThunderbirdCore
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate()
    UNUserNotificationCenter.current().delegate = self
    OpenPGP.passphraseProvider = { label in
      DispatchQueue.main.sync {
        let alert = NSAlert()
        alert.messageText = "Enter the passphrase for your OpenPGP key"
        alert.informativeText = label
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Unlock")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
      }
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    [.banner, .sound]
  }
}

@main
struct ThunderbirdApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @State private var mail = MailStore()
  @State private var contacts = ContactsStore()
  @State private var calendar = CalendarStore()
  @State private var chat = ChatStore()

  var body: some Scene {
    Window("Thunderbird", id: WindowID.main) {
      MainWindow()
        .environments(mail, contacts, calendar, chat)
        .onAppear {
          mail.onAddressesUsed = { [contacts] in contacts.collect($0) }
        }
    }
    .defaultSize(width: 1320, height: 820)
    .commands {
      MainMenus(mail: mail, calendar: calendar, chat: chat, contacts: contacts)
      ComposeMenus(mail: mail)
    }

    WindowGroup("Write", id: WindowID.compose, for: ComposeDraft.self) { $draft in
      ComposeWindow(initial: draft ?? mail.newDraft())
        .environments(mail, contacts, calendar, chat)
    }
    .defaultSize(width: 820, height: 680)
    .windowToolbarStyle(.unified)

    WindowGroup("Message", id: WindowID.message, for: MessageReference.self) { $reference in
      if let reference {
        MessageWindow(reference: reference)
          .environments(mail, contacts, calendar, chat)
      }
    }
    .defaultSize(width: 860, height: 760)

    WindowGroup("Conversation", id: WindowID.conversation, for: MessageReference.self) { $reference in
      if let reference {
        ConversationWindow(reference: reference)
          .environments(mail, contacts, calendar, chat)
      }
    }
    .defaultSize(width: 1000, height: 760)

    WindowGroup("Message", id: WindowID.savedMessage, for: URL.self) { $url in
      if let url {
        SavedMessageWindow(url: url)
          .environments(mail, contacts, calendar, chat)
      }
    }
    .defaultSize(width: 860, height: 760)

    Window("Activity Manager", id: WindowID.activity) {
      ActivityManagerWindow()
        .environments(mail, contacts, calendar, chat)
    }
    .defaultSize(width: 520, height: 420)

    Window("Saved Files", id: WindowID.savedFiles) {
      SavedFilesWindow()
    }
    .defaultSize(width: 520, height: 420)

    Window("Troubleshooting Information", id: WindowID.troubleshooting) {
      TroubleshootingWindow()
        .environments(mail, contacts, calendar, chat)
    }
    .defaultSize(width: 640, height: 560)

    WindowGroup("Import and Export", id: WindowID.importExport, for: String.self) { $mode in
      ImportExportWindow(mode: mode ?? "import")
        .environments(mail, contacts, calendar, chat)
    }
    .defaultSize(width: 560, height: 480)

    Settings {
      SettingsView()
        .environments(mail, contacts, calendar, chat)
    }
  }
}

enum WindowID {
  static let main = "main"
  static let compose = "compose"
  static let message = "message"
  static let conversation = "conversation"
  static let savedMessage = "savedMessage"
  static let activity = "activity"
  static let troubleshooting = "troubleshooting"
  static let savedFiles = "savedFiles"
  static let importExport = "importExport"
}

extension View {
  func environments(_ mail: MailStore, _ contacts: ContactsStore, _ calendar: CalendarStore, _ chat: ChatStore) -> some View {
    environment(mail).environment(contacts).environment(calendar).environment(chat)
  }
}
