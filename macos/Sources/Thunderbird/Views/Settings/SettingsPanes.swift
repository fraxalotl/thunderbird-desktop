/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import AppKit
import SwiftUI
import ThunderbirdCore

/// Settings › General (preferences/general.inc.xhtml).
struct GeneralSettings: View {
  @AppStorage(Preferences.showStartPage) private var showStartPage = true
  @AppStorage(Preferences.checkInterval) private var checkInterval = 10
  @AppStorage(Preferences.syncLimit) private var syncLimit = 250
  @AppStorage(Preferences.notifications) private var notifications = true
  @AppStorage(Preferences.notificationSound) private var notificationSound = true
  @AppStorage(Preferences.markReadOnOpen) private var markReadOnOpen = true
  @AppStorage(Preferences.markReadDelay) private var markReadDelay = 0
  @AppStorage(Preferences.threaded) private var threaded = false
  @AppStorage(Preferences.openInExistingWindow) private var openInExistingWindow = false
  @AppStorage(Preferences.closeOnMoveDelete) private var closeOnMoveDelete = false
  @AppStorage(Preferences.displayNameOnly) private var displayNameOnly = true
  @AppStorage(Preferences.alwaysAskWhereToSave) private var alwaysAsk = true
  @AppStorage(Preferences.downloadFolder) private var downloadFolder = ""

  var body: some View {
    Form {
      Section("Thunderbird Start Page") {
        Toggle("When Thunderbird launches, show the Start Page in the message area", isOn: $showStartPage)
      }
      Section("Incoming Mail") {
        Picker("Default check for new messages every", selection: $checkInterval) {
          ForEach([1, 5, 10, 15, 30, 60], id: \.self) { minutes in
            Text(minutes == 1 ? "minute" : "\(minutes) minutes").tag(minutes)
          }
        }
        Picker("Keep this many recent messages per folder", selection: $syncLimit) {
          ForEach([100, 250, 500, 1000, 2500], id: \.self) { Text($0.formatted()).tag($0) }
        }
        Toggle("Show an alert when new messages arrive", isOn: $notifications)
        Toggle("Play a sound", isOn: $notificationSound)
          .disabled(!notifications)
      }
      Section("Reading & Display") {
        Toggle("Automatically mark messages as read", isOn: $markReadOnOpen)
        Picker("Mark as read", selection: $markReadDelay) {
          Text("Immediately on display").tag(0)
          ForEach([1, 2, 5, 10, 30], id: \.self) { Text("After displaying for \($0) seconds").tag($0) }
        }
        .disabled(!markReadOnOpen)
        Toggle("Group messages by conversation (threaded view)", isOn: $threaded)
        Picker("Open messages in", selection: $openInExistingWindow) {
          Text("A new message window").tag(false)
          Text("An existing message window").tag(true)
        }
        Toggle("Close message window on move or delete", isOn: $closeOnMoveDelete)
        Toggle("Show only display name for people in my address book", isOn: $displayNameOnly)
      }
      Section("Files & Attachments") {
        Picker("Downloads", selection: $alwaysAsk) {
          Text("Always ask me where to save files").tag(true)
          Text("Save files to a folder").tag(false)
        }
        .pickerStyle(.radioGroup)
        if !alwaysAsk {
          HStack {
            Text(downloadFolder.isEmpty ? "Downloads" : (downloadFolder as NSString).abbreviatingWithTildeInPath)
              .foregroundStyle(.secondary)
            Spacer()
            Button("Choose…") {
              let panel = NSOpenPanel()
              panel.canChooseDirectories = true
              panel.canChooseFiles = false
              panel.canCreateDirectories = true
              if panel.runModal() == .OK, let url = panel.url { downloadFolder = url.path }
            }
          }
        }
      }
    }
    .formStyle(.grouped)
  }
}

/// Settings › Composition (preferences/compose.inc.xhtml).
struct CompositionSettings: View {
  @AppStorage(Preferences.forwardAsAttachment) private var forwardAsAttachment = false
  @AppStorage(Preferences.autosaveMinutes) private var autosaveMinutes = 5
  @AppStorage(Preferences.confirmSendShortcut) private var confirmSendShortcut = true
  @AppStorage(Preferences.attachmentReminder) private var attachmentReminder = true
  @AppStorage(Preferences.attachmentKeywords) private var attachmentKeywords = ""
  @AppStorage(Preferences.defaultHTML) private var defaultHTML = true
  @AppStorage(Preferences.composeFont) private var composeFont = ""
  @AppStorage(Preferences.composeFontSize) private var composeFontSize = 14
  @AppStorage(Preferences.composeTextColor) private var textColor = "#1D1D1F"
  @AppStorage(Preferences.composeBackground) private var background = "#FFFFFF"
  @AppStorage(Preferences.collectAddresses) private var collectAddresses = true
  @AppStorage(Preferences.spellcheckBeforeSend) private var spellcheckBeforeSend = false

  private static let fonts = ["", "Helvetica", "Arial", "Times New Roman", "Georgia", "Menlo", "Courier New", "Verdana"]

  var body: some View {
    Form {
      Section("Composition") {
        Picker("Forward messages", selection: $forwardAsAttachment) {
          Text("Inline").tag(false)
          Text("As Attachment").tag(true)
        }
        Picker("Auto Save every", selection: $autosaveMinutes) {
          Text("Never").tag(0)
          ForEach([1, 2, 5, 10, 15, 30], id: \.self) { Text($0 == 1 ? "minute" : "\($0) minutes").tag($0) }
        }
        Toggle("Confirm when using a keyboard shortcut to send a message", isOn: $confirmSendShortcut)
      }
      Section("Attachments") {
        Toggle("Check for missing attachments", isOn: $attachmentReminder)
        TextField("Keywords", text: $attachmentKeywords, prompt: Text("attach, attached, attachment"))
          .disabled(!attachmentReminder)
      }
      Section("HTML Style") {
        Toggle("Compose new messages in HTML by default", isOn: $defaultHTML)
        Picker("Font", selection: $composeFont) {
          ForEach(Self.fonts, id: \.self) { Text($0.isEmpty ? "Variable Width" : $0).tag($0) }
        }
        Picker("Size", selection: $composeFontSize) {
          ForEach([10, 12, 13, 14, 16, 18, 24], id: \.self) { Text("\($0) pt").tag($0) }
        }
        ColorPicker("Text color", selection: hexBinding($textColor), supportsOpacity: false)
        ColorPicker("Background color", selection: hexBinding($background), supportsOpacity: false)
        Button("Restore Default") {
          composeFont = ""
          composeFontSize = 14
          textColor = "#1D1D1F"
          background = "#FFFFFF"
        }
      }
      Section("Addressing") {
        Toggle("Automatically add outgoing email addresses to my Collected Addresses", isOn: $collectAddresses)
      }
      Section("Spelling") {
        Toggle("Check spelling before sending", isOn: $spellcheckBeforeSend)
      }
    }
    .formStyle(.grouped)
  }

  private func hexBinding(_ value: Binding<String>) -> Binding<Color> {
    Binding(
      get: { Color(hex: value.wrappedValue) },
      set: { color in
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
        value.wrappedValue = String(
          format: "#%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
      })
  }
}

/// Settings › Privacy & Security (preferences/privacy.inc.xhtml).
struct PrivacySettings: View {
  @AppStorage(Preferences.allowRemoteContent) private var allowRemoteContent = false
  @AppStorage(Preferences.junkFilter) private var junkFilter = true
  @AppStorage(Preferences.junkMarkRead) private var junkMarkRead = true
  @AppStorage(Preferences.junkDelete) private var junkDelete = false
  @AppStorage(Preferences.scamDetection) private var scamDetection = true
  @State private var exceptions = UserDefaults.standard.stringArray(forKey: Preferences.remoteContentExceptions) ?? []
  @State private var newException = ""
  @State private var selectedException: String?

  var body: some View {
    Form {
      Section {
        Toggle("Allow remote content in messages", isOn: $allowRemoteContent)
        DisclosureGroup("Exceptions (\(exceptions.count))") {
          List(exceptions, id: \.self, selection: $selectedException) { Text($0) }
            .frame(height: 110)
          HStack {
            TextField("Address or domain", text: $newException)
              .onSubmit(addException)
            Button("Allow", action: addException)
              .disabled(newException.isEmpty)
            Button("Remove") {
              exceptions.removeAll { $0 == selectedException }
              save()
            }
            .disabled(selectedException == nil)
          }
        }
      } header: {
        Text("Mail Content")
      } footer: {
        Text("Remote content can tell senders when and where you read their messages.").foregroundStyle(.secondary)
      }
      Section("Junk") {
        Toggle("Enable adaptive junk filter logging and detection", isOn: $junkFilter)
        Toggle("When I mark messages as junk, also mark them as read", isOn: $junkMarkRead)
        Picker("When I mark messages as junk", selection: $junkDelete) {
          Text("Move them to the account's Junk folder").tag(false)
          Text("Delete them").tag(true)
        }
        Button("Reset Training Data") {
          Task { await JunkClassifier.shared.reset() }
        }
      }
      Section("Scam Detection") {
        Toggle("Tell me if the message I'm reading is a suspected email scam", isOn: $scamDetection)
      }
      Section("Passwords") {
        Text("Thunderbird stores account passwords in your login keychain.")
          .foregroundStyle(.secondary)
        Button("Open Keychain Access") {
          NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Keychain Access.app"))
        }
      }
    }
    .formStyle(.grouped)
  }

  private func addException() {
    let value = newException.trimmingCharacters(in: .whitespaces).lowercased()
    guard !value.isEmpty, !exceptions.contains(value) else { return }
    exceptions.append(value)
    newException = ""
    save()
  }

  private func save() {
    UserDefaults.standard.set(exceptions, forKey: Preferences.remoteContentExceptions)
  }
}

/// Settings › Chat (preferences/chat.inc.xhtml).
struct ChatSettings: View {
  @AppStorage(Preferences.chatNotifications) private var notifications = true
  @AppStorage(Preferences.chatAwayMinutes) private var awayMinutes = 5

  var body: some View {
    Form {
      Section("Status") {
        Picker("Change my status to Away after", selection: $awayMinutes) {
          Text("Never").tag(0)
          ForEach([1, 5, 10, 15, 30, 60], id: \.self) { Text("\($0) minutes of inactivity").tag($0) }
        }
      }
      Section("Notifications") {
        Toggle("When messages directed at you arrive, show a notification", isOn: $notifications)
      }
    }
    .formStyle(.grouped)
  }
}

/// Settings › Calendar (calendar-views and calendar-alarms panes).
struct CalendarSettings: View {
  @Environment(CalendarStore.self) private var calendar
  @AppStorage(Preferences.weekStart) private var weekStart = Calendar.current.firstWeekday
  @AppStorage(Preferences.showWeekNumbers) private var showWeekNumbers = false
  @AppStorage(Preferences.dayStartHour) private var dayStartHour = 8
  @AppStorage(Preferences.dayEndHour) private var dayEndHour = 17
  @AppStorage(Preferences.defaultEventMinutes) private var eventMinutes = 60
  @AppStorage(Preferences.defaultReminderMinutes) private var reminderMinutes = 15
  @AppStorage(Preferences.showTodayPane) private var showTodayPane = false

  var body: some View {
    Form {
      Section("Views") {
        Picker("Start the week on", selection: $weekStart) {
          ForEach(1...7, id: \.self) { Text(Calendar.current.weekdaySymbols[$0 - 1]).tag($0) }
        }
        Toggle("Show week numbers in views and minimonths", isOn: $showWeekNumbers)
        Picker("Day starts at", selection: $dayStartHour) {
          ForEach(0..<24, id: \.self) { Text(hour($0)).tag($0) }
        }
        Picker("Day ends at", selection: $dayEndHour) {
          ForEach(1...24, id: \.self) { Text(hour($0 % 24)).tag($0) }
        }
        Toggle("Show the Today Pane", isOn: $showTodayPane)
      }
      Section("Events and Tasks") {
        Picker("Default event length", selection: $eventMinutes) {
          ForEach([15, 30, 45, 60, 90, 120, 240], id: \.self) { Text(Duration.seconds($0 * 60).formatted(.units(allowed: [.hours, .minutes]))).tag($0) }
        }
        Picker("Default reminder", selection: $reminderMinutes) {
          Text("None").tag(-1)
          Text("At start time").tag(0)
          ForEach([5, 15, 30, 60, 120, 1440], id: \.self) {
            Text("\(Duration.seconds($0 * 60).formatted(.units(allowed: [.days, .hours, .minutes]))) before").tag($0)
          }
        }
      }
    }
    .formStyle(.grouped)
    .onChange(of: weekStart) { calendar.reloadEvents() }
  }

  private func hour(_ value: Int) -> String {
    Calendar.current.date(bySettingHour: value, minute: 0, second: 0, of: Date())!.formatted(date: .omitted, time: .shortened)
  }
}

/// The per-account panes of Thunderbird's Account Settings: Server Settings, Copies & Folders,
/// Composition & Addressing, Junk Settings, Synchronization & Storage and Return Receipts.
struct AccountOptionsEditor: View {
  @Environment(MailStore.self) private var store
  @Binding var account: MailAccount

  private var folders: [RemoteFolder] {
    store.sidebarFolders(for: account.id).map(\.folder).filter(\.isSelectable)
  }

  var body: some View {
    let isMail = account.kind == .imap || account.kind == .pop3 || account.kind == .ews
    if account.kind != .local {
      Section("Server Settings") {
        Toggle("Check for new messages at startup", isOn: $account.options.checkAtStartup)
        Picker("Check for new messages every", selection: $account.options.checkIntervalMinutes) {
          Text("Never").tag(0)
          ForEach([1, 5, 10, 15, 30, 60], id: \.self) { Text($0 == 1 ? "minute" : "\($0) minutes").tag($0) }
        }
        if account.kind == .imap {
          Toggle("Allow immediate server notifications when new messages arrive", isOn: $account.options.usePush)
          Picker("When I delete a message", selection: $account.options.deleteModel) {
            Text("Move it to the Trash folder").tag(AccountOptions.DeleteModel.moveToTrash)
            Text("Just mark it as deleted").tag(AccountOptions.DeleteModel.markDeleted)
            Text("Remove it immediately").tag(AccountOptions.DeleteModel.removeImmediately)
          }
          Toggle("Clean up (\"Expunge\") Inbox on Exit", isOn: $account.options.expungeInboxOnExit)
        }
        if account.kind == .pop3 {
          Toggle(
            "For at most",
            isOn: Binding(
              get: { account.options.popLeaveDays != nil },
              set: { account.options.popLeaveDays = $0 ? 14 : nil }))
          .disabled(!account.leaveMessagesOnServer)
          if let days = account.options.popLeaveDays {
            Stepper("\(days) days on the server", value: Binding(get: { days }, set: { account.options.popLeaveDays = $0 }), in: 1...365)
          }
        }
        if isMail {
          Toggle("Empty Trash on Exit", isOn: $account.options.emptyTrashOnExit)
        }
      }
    }
    if isMail || account.kind == .nntp {
      Section("Copies & Folders") {
        if account.kind != .nntp {
          Toggle("Place a copy of sent messages in", isOn: $account.options.saveSentCopy)
          folderPicker("Sent folder", $account.options.sentFolder, role: .sent)
            .disabled(!account.options.saveSentCopy)
        }
        TextField("Bcc these email addresses", text: $account.options.bccAddresses, prompt: Text("None"))
        folderPicker("Keep message archives in", $account.options.archiveFolder, role: .archive)
        Picker("Archive granularity", selection: $account.options.archiveGranularity) {
          Text("A single folder").tag(AccountOptions.ArchiveGranularity.single)
          Text("Yearly archived folders").tag(AccountOptions.ArchiveGranularity.yearly)
          Text("Monthly archived folders").tag(AccountOptions.ArchiveGranularity.monthly)
        }
        folderPicker("Keep message drafts in", $account.options.draftsFolder, role: .drafts)
        folderPicker("Keep message templates in", $account.options.templatesFolder, role: .templates)
      }
      Section("Composition & Addressing") {
        Toggle("Automatically quote the original message when replying", isOn: $account.options.quoteOnReply)
        Picker("Then", selection: $account.options.replyAboveQuote) {
          Text("Start my reply below the quote").tag(false)
          Text("Start my reply above the quote").tag(true)
        }
        .disabled(!account.options.quoteOnReply)
        Picker("And place my signature", selection: $account.options.signatureBelowQuote) {
          Text("Below my reply (above the quote)").tag(false)
          Text("Below the quote (recommended)").tag(true)
        }
        .disabled(!account.options.quoteOnReply || !account.options.replyAboveQuote)
        Toggle("Include signature for replies", isOn: $account.options.signatureInReplies)
        HStack {
          Text("Attach the signature from a file instead")
          Spacer()
          Text(account.options.signatureFile.map { ($0 as NSString).lastPathComponent } ?? "None")
            .foregroundStyle(.secondary)
          Button("Choose…") {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.plainText, .html]
            if panel.runModal() == .OK { account.options.signatureFile = panel.url?.path }
          }
          if account.options.signatureFile != nil {
            Button("Clear") { account.options.signatureFile = nil }
          }
        }
        Toggle("Attach my vCard to messages", isOn: $account.options.attachVCard)
        TextField("Organization", text: $account.options.organization)
        Toggle("Request a return receipt for new messages by default", isOn: $account.options.requestReceiptByDefault)
      }
    }
    if isMail {
      Section("Junk Settings") {
        Toggle("Enable adaptive junk mail controls for this account", isOn: $account.options.junkEnabled)
        Toggle("Trust junk mail headers set by the server (SpamAssassin)", isOn: $account.options.trustSpamHeaders)
        Toggle("Move new junk messages to the Junk folder", isOn: $account.options.moveJunk)
        daysToggle("Automatically delete junk messages older than", $account.options.junkPurgeDays, default: 14)
      }
      Section("Synchronization & Storage") {
        if account.kind != .pop3 {
          Toggle("Keep messages for this account on this computer", isOn: $account.options.keepMessagesOffline)
        }
        daysToggle("Delete messages more than", $account.options.deleteOlderThanDays, default: 365, suffix: "days old")
        Toggle("Always keep starred messages", isOn: $account.options.keepStarred)
          .disabled(account.options.deleteOlderThanDays == nil)
      }
      Section("Return Receipts") {
        Picker("When I receive a request for a return receipt", selection: $account.options.receiptPolicy) {
          Text("Never send a return receipt").tag(AccountOptions.ReceiptPolicy.never)
          Text("Always send").tag(AccountOptions.ReceiptPolicy.always)
          Text("Ask me").tag(AccountOptions.ReceiptPolicy.ask)
        }
      }
    }
  }

  private func folderPicker(_ title: String, _ value: Binding<String?>, role: FolderRole) -> some View {
    Picker(title, selection: value) {
      Text("Default (\(store.folder(role: role, in: account.id).map(\.displayName) ?? role.rawValue.capitalized))").tag(String?.none)
      Divider()
      ForEach(folders) { Text($0.displayName).tag(Optional($0.path)) }
    }
  }

  @ViewBuilder
  private func daysToggle(_ title: String, _ value: Binding<Int?>, default fallback: Int, suffix: String = "days") -> some View {
    Toggle(title, isOn: Binding(get: { value.wrappedValue != nil }, set: { value.wrappedValue = $0 ? fallback : nil }))
    if let days = value.wrappedValue {
      Stepper("\(days) \(suffix)", value: Binding(get: { days }, set: { value.wrappedValue = $0 }), in: 1...3650)
    }
  }
}
