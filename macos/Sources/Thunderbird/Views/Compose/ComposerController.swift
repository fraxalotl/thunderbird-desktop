/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

@preconcurrency import Contacts
import AppKit
import Observation
import SwiftUI
import ThunderbirdCore
import UniformTypeIdentifiers
import WebKit

/// Dialogs the composer's Insert, Format and Security menus open.
enum ComposeDialog: String, Identifiable {
  case link, anchor, image, table, html, math, tableProperties, pageColors, listProperties, imageProperties
  case findReplace, keyAssistant, attachWebPage, renameAttachment, reorderAttachments
  var id: String { rawValue }
}

/// The compose window's state and editing commands, shared with the menu bar, the toolbar and the
/// formatting bar.
@MainActor
@Observable
final class ComposerController {
  var draft: ComposeDraft
  var isDirty = false
  var isBusy = false
  var sent = false
  var lastSaved: Date?
  var errorMessage: String?
  var errorTitle = "Couldn't Send Message"
  var confirmingNoAttachment = false
  var dialog: ComposeDialog?
  var attachmentToRename: URL?

  // Editor state reported by the page.
  var isBold = false
  var isItalic = false
  var isUnderlined = false
  var isStruck = false
  var isBulleted = false
  var isNumbered = false
  var paragraph = "p"
  var fontName = ""
  var alignment = "left"
  var inTable = false

  // View menu toggles.
  var showCc: Bool
  var showBcc: Bool
  var showReplyTo: Bool
  var showNewsgroups: Bool
  var showFollowupTo: Bool
  var showFormatBar = UserDefaults.standard.object(forKey: "composeFormatBar") as? Bool ?? true {
    didSet { UserDefaults.standard.set(showFormatBar, forKey: "composeFormatBar") }
  }
  var showStatusBar = UserDefaults.standard.object(forKey: "composeStatusBar") as? Bool ?? true {
    didSet { UserDefaults.standard.set(showStatusBar, forKey: "composeStatusBar") }
  }
  var showContactsSidebar = UserDefaults.standard.bool(forKey: "composeContactsSidebar") {
    didSet { UserDefaults.standard.set(showContactsSidebar, forKey: "composeContactsSidebar") }
  }
  var showAttachmentPane = true
  var spellcheckAsYouType = true
  var remindLater = false
  var zoom: Double = 1 {
    didSet { applyZoom() }
  }
  var zoomTextOnly = false {
    didSet { applyZoom() }
  }

  private func applyZoom() {
    if zoomTextOnly {
      webView?.pageZoom = 1
      Task { _ = try? await webView?.callAsyncJavaScript("document.body.style.zoom = z", arguments: ["z": zoom], contentWorld: .page) }
    } else {
      Task { _ = try? await webView?.callAsyncJavaScript("document.body.style.zoom = ''", contentWorld: .page) }
      webView?.pageZoom = zoom
    }
  }

  var findText = ""
  var replaceText = ""
  var findCaseSensitive = false

  @ObservationIgnored weak var webView: WKWebView?
  @ObservationIgnored var store: MailStore?
  @ObservationIgnored var closeWindow: (() -> Void)?
  @ObservationIgnored private var editorReady = false
  @ObservationIgnored private var autosaveTask: Task<Void, Never>?

  init(draft: ComposeDraft) {
    self.draft = draft
    showCc = !draft.cc.isEmpty
    showBcc = !draft.bcc.isEmpty
    showReplyTo = !draft.replyTo.isEmpty
    showNewsgroups = !draft.newsgroups.isEmpty
    showFollowupTo = !draft.followupTo.isEmpty
  }

  // MARK: - Editor bridge

  func editorDidLoad() {
    editorReady = true
    Task {
      let html = draft.htmlBody ?? "<p><br></p>"
      _ = try? await webView?.callAsyncJavaScript("tb.setHTML(html)", arguments: ["html": html], contentWorld: .page)
      if draft.kind != .draft && draft.kind != .template {
        _ = try? await webView?.callAsyncJavaScript(
          "const s = document.body.style; if (font) s.fontFamily = font; s.fontSize = size + 'px'; s.color = color; s.backgroundColor = background;",
          arguments: [
            "font": Preferences.string(Preferences.composeFont), "size": max(9, Preferences.int(Preferences.composeFontSize)),
            "color": Preferences.string(Preferences.composeTextColor), "background": Preferences.string(Preferences.composeBackground),
          ], contentWorld: .page)
      }
      if !(draft.to.isEmpty && draft.newsgroups.isEmpty) {
        _ = try? await webView?.callAsyncJavaScript("tb.focusStart()", contentWorld: .page)
      }
    }
  }

  /// Composition › Auto Save every N minutes.
  func startAutosave() {
    autosaveTask?.cancel()
    let minutes = Preferences.int(Preferences.autosaveMinutes)
    guard minutes > 0 else { return }
    autosaveTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(minutes * 60))
        guard let self, !Task.isCancelled, !self.sent else { return }
        if self.isDirty { await self.saveDraft(silently: true) }
      }
    }
  }

  func stopAutosave() {
    autosaveTask?.cancel()
  }

  func receive(_ message: [String: Any]) {
    switch message["type"] as? String {
    case "dirty":
      isDirty = true
    case "state":
      isBold = message["bold"] as? Bool ?? false
      isItalic = message["italic"] as? Bool ?? false
      isUnderlined = message["underline"] as? Bool ?? false
      isStruck = message["strike"] as? Bool ?? false
      isBulleted = message["ul"] as? Bool ?? false
      isNumbered = message["ol"] as? Bool ?? false
      paragraph = message["block"] as? String ?? "p"
      fontName = message["font"] as? String ?? ""
      alignment = message["align"] as? String ?? "left"
      inTable = message["inTable"] as? Bool ?? false
    default:
      break
    }
  }

  @discardableResult
  func run(_ script: String, _ arguments: [String: Any] = [:]) async -> Any? {
    guard draft.isHTML, let webView else { return nil }
    return try? await webView.callAsyncJavaScript(script, arguments: arguments, contentWorld: .page)
  }

  func exec(_ command: String, _ value: String? = nil) {
    Task { _ = await run("tb.exec(command, value)", ["command": command, "value": value ?? NSNull()]) }
  }

  func insertHTML(_ html: String) {
    Task { _ = await run("tb.insertHTML(html)", ["html": html]) }
  }

  func wrap(_ tag: String, _ attributes: [String: String] = [:]) {
    Task { _ = await run("tb.wrap(tag, attrs)", ["tag": tag, "attrs": attributes]) }
  }

  func tableOperation(_ operation: String, _ argument: Any = NSNull()) {
    Task { _ = await run("tb.tableOp(op, arg)", ["op": operation, "arg": argument]) }
  }

  func call(_ function: String) {
    Task { _ = await run("tb.\(function)()") }
  }

  /// The draft with the editor's current contents copied in.
  func currentDraft() async -> ComposeDraft {
    var snapshot = draft
    if draft.isHTML {
      snapshot.htmlBody = await run("return tb.html()") as? String ?? draft.htmlBody
      snapshot.body = await run("return tb.text()") as? String ?? draft.body
    }
    return snapshot
  }

  // MARK: - Format

  func switchFormat(toHTML: Bool) {
    Task {
      if toHTML {
        draft.htmlBody = "<p>" + ComposeDraft.escape(draft.body).replacingOccurrences(of: "\n", with: "<br>") + "</p>"
        draft.isHTML = true
      } else {
        draft.body = await run("return tb.text()") as? String ?? draft.body
        draft.isHTML = false
      }
      isDirty = true
    }
  }

  /// Edit › Rewrap: reflows plain text paragraphs (and quoted ones) at 72 columns.
  func rewrap() {
    guard !draft.isHTML else { return }
    var output: [String] = []
    var paragraph: [String] = []
    var prefix = ""
    func flush() {
      guard !paragraph.isEmpty else { return }
      var line = prefix
      for word in paragraph.joined(separator: " ").split(separator: " ") {
        if line.count + word.count + 1 > 72 && line.count > prefix.count {
          output.append(line)
          line = prefix
        }
        line += (line.count > prefix.count ? " " : "") + word
      }
      output.append(line)
      paragraph = []
    }
    for raw in draft.body.components(separatedBy: "\n") {
      let quote = String(raw.prefix { $0 == ">" || $0 == " " }.filter { $0 == ">" })
      let linePrefix = quote.isEmpty ? "" : quote + " "
      let text = raw.dropFirst(raw.prefix { $0 == ">" || $0 == " " }.count).trimmingCharacters(in: .whitespaces)
      if text.isEmpty || raw == "-- " || linePrefix != prefix {
        flush()
        prefix = linePrefix
        if text.isEmpty || raw == "-- " {
          output.append(raw)
          continue
        }
      }
      paragraph.append(text)
    }
    flush()
    draft.body = output.joined(separator: "\n")
    isDirty = true
  }

  func pasteAsQuotation() {
    guard let text = NSPasteboard.general.string(forType: .string) else { return }
    if draft.isHTML {
      insertHTML("<blockquote type=\"cite\">\(ComposeDraft.escape(text).replacingOccurrences(of: "\n", with: "<br>"))</blockquote><p><br></p>")
    } else {
      draft.body += "\n" + text.components(separatedBy: "\n").map { "> \($0)" }.joined(separator: "\n") + "\n"
    }
  }

  func pasteWithoutFormatting() {
    NSApp.sendAction(Selector(("pasteAsPlainText:")), to: nil, from: nil)
  }

  /// Options › Quote Message: inserts the message being replied to.
  func quoteMessage() async {
    guard let store, let source = draft.source, let loaded = try? await store.loadMessage(source) else { return }
    let author = loaded.parsed.from.first?.displayName ?? "Someone"
    if draft.isHTML {
      let original = loaded.parsed.htmlBody.map(ComposeDraft.sanitizedQuote) ?? "<pre>\(ComposeDraft.escape(loaded.parsed.plainText))</pre>"
      insertHTML("<p>\(ComposeDraft.escape(author)) wrote:</p><blockquote type=\"cite\">\(original)</blockquote><p><br></p>")
    } else {
      draft.body += "\n\(author) wrote:\n" + loaded.parsed.plainText.components(separatedBy: "\n").map { "> \($0)" }.joined(separator: "\n")
    }
  }

  // MARK: - Spelling, find and print

  func checkSpelling() {
    NSApp.sendAction(#selector(NSText.showGuessPanel(_:)), to: nil, from: nil)
  }

  func toggleSpellcheckAsYouType() {
    spellcheckAsYouType.toggle()
    NSApp.sendAction(#selector(NSTextView.toggleContinuousSpellChecking(_:)), to: nil, from: nil)
  }

  func find(backwards: Bool = false) {
    guard !findText.isEmpty else { return }
    Task { _ = await run("return tb.find(text, back, cs)", ["text": findText, "back": backwards, "cs": findCaseSensitive]) }
  }

  func replace() {
    Task { _ = await run("return tb.replace(text, rep, cs)", ["text": findText, "rep": replaceText, "cs": findCaseSensitive]) }
  }

  func replaceAll() {
    if draft.isHTML {
      Task { _ = await run("return tb.replaceAll(text, rep, cs)", ["text": findText, "rep": replaceText, "cs": findCaseSensitive]) }
    } else {
      draft.body = draft.body.replacingOccurrences(
        of: findText, with: replaceText, options: findCaseSensitive ? [] : .caseInsensitive)
    }
  }

  func print() {
    guard let webView, let window = webView.window else { return }
    let operation = webView.printOperation(with: .shared)
    operation.view?.frame = webView.bounds
    operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
  }

  // MARK: - Attachments

  func attachFiles() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    if panel.runModal() == .OK {
      draft.attachments.append(contentsOf: panel.urls)
      isDirty = true
    }
  }

  func attachWebPage(_ address: String) async {
    guard let url = URL(string: address.hasPrefix("http") ? address : "https://\(address)"),
      let (data, _) = try? await URLSession.shared.data(from: url)
    else {
      errorMessage = "The web page couldn't be downloaded."
      return
    }
    let name = (url.host() ?? "page") + ".html"
    let file = MessageAttachment(id: 0, filename: name, mimeType: "text/html", data: data)
    if let local = try? AttachmentFiles.temporaryURL(for: file) {
      draft.attachments.append(local)
    }
  }

  /// File › Attach › My vCard: the "Me" card from Contacts, or one built from the identity.
  func attachVCard() {
    guard let (_, identity) = store?.identity(for: draft) else { return }
    var data: Data?
    let keys = [CNContactVCardSerialization.descriptorForRequiredKeys()]
    if let me = try? CNContactStore().unifiedMeContactWithKeys(toFetch: keys) {
      data = try? CNContactVCardSerialization.data(with: [me])
    }
    if data == nil {
      let contact = CNMutableContact()
      let parts = identity.fullName.split(separator: " ", maxSplits: 1).map(String.init)
      contact.givenName = parts.first ?? ""
      contact.familyName = parts.count > 1 ? parts[1] : ""
      contact.emailAddresses = [CNLabeledValue(label: CNLabelWork, value: identity.email as NSString)]
      data = try? CNContactVCardSerialization.data(with: [contact])
    }
    guard let data else { return }
    let file = MessageAttachment(
      id: 0, filename: "\(identity.fullName.isEmpty ? "contact" : identity.fullName).vcf", mimeType: "text/vcard", data: data)
    if let url = try? AttachmentFiles.temporaryURL(for: file) {
      draft.attachments.append(url)
    }
  }

  /// File › Attach › My OpenPGP Public Key.
  func attachPublicKey() {
    guard let (account, identity) = store?.identity(for: draft) else { return }
    let key = account.openPGPKeyID ?? OpenPGP.shared.keys(for: identity.email).first(where: \.hasSecret)?.fingerprint
    guard let key, let armored = try? OpenPGP.shared.exportPublicKey(key) else {
      errorMessage = "You don't have an OpenPGP key for \(identity.email)."
      return
    }
    let keyID = OpenPGP.shared.keys().first { $0.fingerprint == key }?.keyID ?? key
    let file = MessageAttachment(id: 0, filename: "OpenPGP_0x\(keyID).asc", mimeType: "application/pgp-keys", data: Data(armored.utf8))
    if let url = try? AttachmentFiles.temporaryURL(for: file) {
      draft.attachments.append(url)
    }
  }

  func renameAttachment(_ url: URL, to name: String) {
    guard let index = draft.attachments.firstIndex(of: url), !name.isEmpty else { return }
    let folder = FileManager.default.temporaryDirectory.appending(path: "Thunderbird Attachments/\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let target = folder.appending(path: name)
    if (try? FileManager.default.copyItem(at: url, to: target)) != nil {
      draft.attachments[index] = target
    }
  }

  // MARK: - Insert helpers

  func insertImage() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.image]
    guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
    let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/png"
    insertHTML("<img src=\"data:\(mime);base64,\(data.base64EncodedString())\" alt=\"\(ComposeDraft.escape(url.lastPathComponent))\">")
  }

  func insertCharacters() {
    NSApp.orderFrontCharacterPalette(nil)
  }

  // MARK: - Sending

  private var mentionsAttachment: Bool {
    let own = draft.body.lowercased().components(separatedBy: "\n").filter { !$0.hasPrefix(">") }.joined(separator: "\n")
    let keywords = Preferences.string(Preferences.attachmentKeywords).lowercased().split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    return keywords.contains { keyword in
      own.range(of: "\\b\(NSRegularExpression.escapedPattern(for: keyword))\\b", options: .regularExpression) != nil
    }
  }

  private var misspelledWordCount: Int {
    let checker = NSSpellChecker.shared
    let text = draft.body.components(separatedBy: "\n").filter { !$0.hasPrefix(">") }.joined(separator: "\n")
    var count = 0
    var offset = 0
    let length = (text as NSString).length
    while offset < length {
      let range = checker.checkSpelling(of: text, startingAt: offset)
      guard range.location != NSNotFound, range.location >= offset else { break }
      count += 1
      offset = range.location + max(range.length, 1)
    }
    return count
  }

  func send(skipReminder: Bool = false, viaShortcut: Bool = false) async {
    errorTitle = "Couldn't Send Message"
    guard let store else { return }
    if viaShortcut && Preferences.bool(Preferences.confirmSendShortcut) {
      let alert = NSAlert()
      alert.messageText = "Are you sure you are ready to send this message?"
      alert.addButton(withTitle: "Send")
      alert.addButton(withTitle: "Cancel")
      alert.showsSuppressionButton = true
      alert.suppressionButton?.title = "Don't ask me again"
      let response = alert.runModal()
      if alert.suppressionButton?.state == .on { UserDefaults.standard.set(false, forKey: Preferences.confirmSendShortcut) }
      guard response == .alertFirstButtonReturn else { return }
    }
    if let (account, _) = store.identity(for: draft), account.options.attachVCard,
      !draft.attachments.contains(where: { $0.pathExtension.lowercased() == "vcf" })
    {
      attachVCard()
    }
    let snapshot = await currentDraft()
    draft.body = snapshot.body
    if !skipReminder && !remindLater && Preferences.bool(Preferences.attachmentReminder) && draft.attachments.isEmpty
      && mentionsAttachment
    {
      confirmingNoAttachment = true
      return
    }
    if Preferences.bool(Preferences.spellcheckBeforeSend), misspelledWordCount > 0 {
      let alert = NSAlert()
      alert.messageText = "This message has \(misspelledWordCount) possible spelling mistakes."
      alert.informativeText = "Check the spelling before sending?"
      alert.addButton(withTitle: "Check Spelling")
      alert.addButton(withTitle: "Send Anyway")
      if alert.runModal() == .alertFirstButtonReturn {
        webView?.window?.makeFirstResponder(webView)
        NSApp.sendAction(#selector(NSText.showGuessPanel(_:)), to: nil, from: nil)
        return
      }
    }
    isBusy = true
    defer { isBusy = false }
    do {
      try await store.send(snapshot)
      sent = true
      closeWindow?()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func sendLater() async {
    errorTitle = "Couldn't Send Message"
    guard let store else { return }
    isBusy = true
    defer { isBusy = false }
    do {
      try await store.sendLater(await currentDraft())
      sent = true
      closeWindow?()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func saveDraft(silently: Bool = false) async {
    guard let store else { return }
    do {
      draft.draftMessageID = try await store.saveDraft(await currentDraft())
      isDirty = false
      lastSaved = Date()
    } catch {
      if !silently {
        errorTitle = "Couldn't Save Draft"
        errorMessage = error.localizedDescription
      }
    }
  }

  func saveTemplate() async {
    do {
      try await store?.saveDraft(await currentDraft(), asTemplate: true)
    } catch {
      errorTitle = "Couldn't Save Template"
      errorMessage = error.localizedDescription
    }
  }

  /// File › Save As › File…: the message as an .eml file.
  func saveAsFile() async {
    guard let store else { return }
    let snapshot = await currentDraft()
    guard let data = try? store.renderForFile(snapshot) else { return }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = (snapshot.subject.nilIfEmpty ?? "Message").replacingOccurrences(of: "/", with: "-") + ".eml"
    if panel.runModal() == .OK, let url = panel.url {
      try? data.write(to: url)
    }
  }

  var openPGPConfigured: Bool {
    guard OpenPGP.shared.isAvailable, let store else { return false }
    return store.sendingAccounts.flatMap(\.identities).contains { !OpenPGP.shared.keys(for: $0.email).filter(\.hasSecret).isEmpty }
  }

  var smimeConfigured: Bool {
    store?.sendingAccounts.flatMap(\.identities).contains { SMIME.hasIdentity(for: $0.email) } ?? false
  }

  var anySecurityConfigured: Bool { openPGPConfigured || smimeConfigured }

  var securityAvailable: Bool {
    guard let (account, identity) = store?.identity(for: draft) else { return false }
    switch draft.securityTechnology ?? account.securityTechnology {
    case .openPGP: return OpenPGP.shared.isAvailable && !OpenPGP.shared.keys(for: identity.email).filter(\.hasSecret).isEmpty
    case .smime: return SMIME.hasIdentity(for: identity.email)
    }
  }
}

extension FocusedValues {
  @Entry var composer: ComposerController?
}
