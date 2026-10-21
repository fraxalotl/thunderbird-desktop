/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import AppKit
import Foundation
import ThunderbirdCore

enum ReplyKind {
  case sender, all, list, newsgroup
}

enum ForwardKind {
  case inline, attachment

  /// Composition › Forward messages.
  static var preferred: ForwardKind { Preferences.bool(Preferences.forwardAsAttachment) ? .attachment : .inline }
}

enum OfflineDownload {
  case selected, starred, everything
}

extension MailStore {
  // MARK: - Undo

  /// Registers an undo whose redo is registered while undoing, so Edit › Redo works too.
  func registerUndoPair(_ name: String, undo: @escaping @MainActor () async -> Void, redo: @escaping @MainActor () async -> Void) {
    guard let undoManager else { return }
    undoManager.registerUndo(withTarget: self) { store in
      MainActor.assumeIsolated {
        store.registerUndoPair(name, undo: redo, redo: undo)
        Task { @MainActor in await undo() }
      }
    }
    undoManager.setActionName(name)
  }

  /// Moving back needs the messages' new UIDs, which IMAP reports through COPYUID.
  func registerMoveUndo(_ name: String, mapping: [UInt32: UInt32], from source: FolderSelection, to destination: FolderSelection) {
    guard !mapping.isEmpty, let undoManager else { return }
    let moved = mapping.values.map { MessageReference(accountID: destination.accountID, path: destination.path, uid: $0) }
    let original = source
    undoManager.registerUndo(withTarget: self) { store in
      MainActor.assumeIsolated {
        let operation: @MainActor () async -> Void = { await store.transfer(moved, to: original, copy: false) }
        Task(operation: operation)
      }
    }
    undoManager.setActionName(name)
  }

  // MARK: - Composing from a message

  func replyDraft(_ kind: ReplyKind, to loaded: LoadedMessage? = nil) -> ComposeDraft? {
    guard let loaded = loaded ?? loadedMessage else { return nil }
    let account = loaded.account.canSend ? loaded.account : (sendingAccounts.first ?? loaded.account)
    var draft = ComposeDraft.reply(to: loaded.parsed, reference: loaded.reference, account: account, all: kind == .all)
    switch kind {
    case .list:
      if let list = loaded.summary.listPost ?? MessageSummary(uid: 0, data: loaded.raw, flags: []).listPost {
        draft.to = list
        draft.cc = ""
      }
    case .newsgroup:
      draft.newsgroups = loaded.parsed.headers["Followup-To"] ?? loaded.parsed.headers["Newsgroups"] ?? ""
      draft.to = ""
      draft.cc = ""
    case .sender:
      let replyTargets = loaded.parsed.replyTo.isEmpty ? loaded.parsed.from : loaded.parsed.replyTo
      draft.to = replyTargets.map(\.formatted).joined(separator: ", ")
      draft.cc = ""
      draft.newsgroups = ""
    case .all:
      break
    }
    return draft
  }

  /// The Local Folders templates offered by Reply with Template, sorted by subject.
  func reloadLocalTemplates() async {
    localTemplates = await fetchLocalTemplates()
  }

  private func fetchLocalTemplates() async -> [MessageItem] {
    guard let localID = localFoldersID, let folder = folder(role: .templates, in: localID), let backend = backend(localID)
    else { return [] }
    _ = try? await backend.sync(path: folder.path, limit: 500)
    return await backend.cachedMessages(in: folder.path)
      .map { MessageItem(reference: MessageReference(accountID: localID, path: folder.path, uid: $0.uid), summary: $0) }
      .sorted { $0.summary.subject.localizedCaseInsensitiveCompare($1.summary.subject) == .orderedAscending }
  }

  /// Reply with Template: a reply to `loaded` whose body and attachments come from the template.
  func replyWithTemplate(_ template: MessageReference, to loaded: LoadedMessage) async -> ComposeDraft? {
    guard var draft = replyDraft(.sender, to: loaded), let templateMessage = try? await loadMessage(template) else { return nil }
    let body = ComposeDraft.reopen(
      templateMessage.parsed, reference: template, account: templateMessage.account, asTemplate: true)
    draft.body = body.body
    draft.htmlBody = body.htmlBody
    draft.isHTML = body.isHTML
    draft.attachments = body.attachments
    // Like Thunderbird's database subject, without "Re:", so replies to replies don't get "Re: Re:".
    let subject = loaded.parsed.subject.replacing(#/^(?i)(\s*re\s*(\[\d+\])?\s*:)+\s*/#, with: "")
    draft.subject = "Re: " + subject
    let recipients = loaded.parsed.replyTo.isEmpty ? loaded.parsed.from : loaded.parsed.replyTo
    let reply = TemplateReply(
      recipientName: TemplatePlaceholders.firstName(recipients.first?.name ?? ""), originalSubject: subject)
    draft.templateReply = reply
    if !draft.isHTML {
      draft.body = TemplatePlaceholders.fill(draft.body, with: placeholderValues(reply, for: draft))
    }
    return draft
  }

  /// The values for a Reply with Template's placeholders, other than the preview text.
  func placeholderValues(_ reply: TemplateReply, for draft: ComposeDraft) -> [String: String] {
    [
      TemplatePlaceholders.name: reply.recipientName,
      TemplatePlaceholders.yourName: identity(for: draft)?.1.fullName ?? "",
      TemplatePlaceholders.subject: reply.originalSubject,
    ]
  }

  /// Organize › Create Decrypted Copy In.
  func copyDecrypted(_ loaded: LoadedMessage, to destination: FolderSelection) async {
    let (decrypted, _) = MessageSecurity.unprotect(loaded.raw)
    do {
      try await backend(destination.accountID)?.append(decrypted, to: destination.path, flags: [MessageFlag.seen])
    } catch {
      report(error, title: "Couldn't create the decrypted copy")
    }
  }

  func canReplyToList(_ loaded: LoadedMessage?) -> Bool {
    loaded.map { $0.summary.listPost != nil || $0.parsed.headers["List-Post"] != nil } ?? false
  }

  func forwardDraft(_ kind: ForwardKind, _ loaded: LoadedMessage? = nil) -> ComposeDraft? {
    guard let loaded = loaded ?? loadedMessage else { return nil }
    guard kind == .attachment else { return forwardDraft(loaded) }
    let account = loaded.account.canSend ? loaded.account : (sendingAccounts.first ?? loaded.account)
    var draft = ComposeDraft.new(account: account)
    draft.kind = .forward
    draft.source = loaded.reference
    let subject = loaded.parsed.subject
    draft.subject = subject.lowercased().hasPrefix("fwd:") ? subject : "Fwd: \(subject)"
    let file = MessageAttachment(
      id: 0, filename: "\(subject.isEmpty ? "Forwarded Message" : subject.replacingOccurrences(of: "/", with: "-")).eml",
      mimeType: "message/rfc822", data: loaded.raw)
    if let url = try? AttachmentFiles.temporaryURL(for: file) {
      draft.attachments = [url]
    }
    return draft
  }

  /// Message › Edit As New Message: same content, new message.
  func editAsNew(_ loaded: LoadedMessage? = nil) -> ComposeDraft? {
    guard let loaded = loaded ?? loadedMessage else { return nil }
    let account = loaded.account.canSend ? loaded.account : (sendingAccounts.first ?? loaded.account)
    var draft = ComposeDraft.reopen(loaded.parsed, reference: loaded.reference, account: account, asTemplate: true)
    draft.kind = .new
    return draft
  }

  /// Message › Edit Template: edits the template itself, replacing it when saved.
  func editTemplate(_ loaded: LoadedMessage? = nil) -> ComposeDraft? {
    guard let loaded = loaded ?? loadedMessage, loaded.folderRole == .templates else { return nil }
    var draft = ComposeDraft.reopen(loaded.parsed, reference: loaded.reference, account: loaded.account, asTemplate: false)
    draft.kind = .template
    draft.editingTemplate = true
    return draft
  }

  /// Message › Redirect: resends the original unchanged, with Resent-* headers.
  func redirect(_ loaded: LoadedMessage, to recipients: [MailAddress]) async throws {
    guard !recipients.isEmpty else { throw MailError.invalidRecipients }
    let account = loaded.account.canSend ? loaded.account : (sendingAccounts.first ?? loaded.account)
    let data = MessageRewriter.redirecting(
      loaded.raw, from: account.address, to: recipients, messageID: OutgoingMessage.makeMessageID(domainOf: account.email))
    let credential: Credential? =
      account.outgoing.username.isEmpty ? nil : try await Credentials.resolve(account.outgoing, key: account.outgoingKeychainKey)
    try await SMTPClient(server: account.outgoing, credential: credential)
      .send(data, from: account.email, to: recipients.map(\.email))
  }

  // MARK: - Attachments

  /// Replaces a message on the server with a rewritten copy (attachments removed).
  private func replace(_ loaded: LoadedMessage, with data: Data) async {
    guard let backend = backend(loaded.reference.accountID) else { return }
    do {
      try await backend.append(data, to: loaded.reference.path, flags: Array(loaded.summary.flags))
      try await backend.delete(uids: [loaded.reference.uid], in: loaded.reference.path)
      await reloadSource()
    } catch {
      report(error, title: "Couldn't update the message")
    }
  }

  func deleteAllAttachments(_ loaded: LoadedMessage) async {
    let data = MessageRewriter.replacingAttachments(in: loaded.raw) { name in
      "The attachment \(name) was deleted from this message on \(Date().formatted(date: .long, time: .shortened))."
    }
    await replace(loaded, with: data)
  }

  func detachAllAttachments(_ loaded: LoadedMessage, to folder: URL) async {
    for attachment in loaded.parsed.attachments {
      try? attachment.data.write(to: folder.appending(path: attachment.filename.replacingOccurrences(of: "/", with: "-")))
    }
    let data = MessageRewriter.replacingAttachments(in: loaded.raw) { name in
      "The attachment \(name) was detached to \(folder.appending(path: name).path)."
    }
    await replace(loaded, with: data)
  }

  // MARK: - Mark

  func markThreadRead() async {
    let threads = Threading.threads(items) { $0.summary }
    var targets = Set<MessageReference>()
    for thread in threads where thread.flattened().contains(where: { selection.contains($0.reference) }) {
      thread.flattened().forEach { targets.insert($0.reference) }
    }
    await setFlag(MessageFlag.seen, on: true, references: targets)
  }

  func markRead(from start: Date, to end: Date) async {
    let targets = Set(items.filter { $0.summary.date >= start && $0.summary.date <= end && !$0.summary.isRead }.map(\.reference))
    await setFlag(MessageFlag.seen, on: true, references: targets)
  }

  func markAllRead() async {
    if let selection = selectedFolder {
      await markFolderRead(selection)
    } else {
      await setFlag(MessageFlag.seen, on: true, references: Set(items.map(\.reference)))
    }
  }

  // MARK: - Spam and filters

  /// Message › Mark › Run Spam Controls, and Tools › Run Spam Controls on Folder.
  func runSpamControls(on references: Set<MessageReference>? = nil) async {
    let targets = items.filter { references?.contains($0.reference) ?? true }
    activity = "Running spam controls…"
    defer { activity = nil }
    var spam = Set<MessageReference>()
    for item in targets where !item.summary.flags.contains(MessageFlag.notJunk) {
      guard let backend = backend(item.reference.accountID),
        let data = try? await backend.message(uid: item.reference.uid, in: item.reference.path)
      else { continue }
      let probability = await JunkClassifier.shared.junkProbability(
        subject: item.summary.subject, from: item.summary.from.first?.email ?? "", body: ParsedMessage(data: data).plainText)
      if let probability, probability > 0.9 {
        spam.insert(item.reference)
      }
    }
    guard !spam.isEmpty else { return }
    await setFlag(MessageFlag.junk, on: true, references: spam, undoable: false)
    await move(spam, to: .junk)
  }

  func deleteSpamInCurrentFolder() async {
    let spam = Set(items.filter(\.summary.isJunk).map(\.reference))
    await delete(spam)
  }

  func runFiltersOnSelection() async {
    for item in selectedItems {
      let filters = FilterStore.filters(for: item.reference.accountID)
      for action in FilterStore.actions(for: item.summary, filters: filters) {
        if await applyFilterAction(action, to: item.summary, accountID: item.reference.accountID, path: item.reference.path) { break }
      }
    }
    await reloadSource()
  }

  // MARK: - News

  /// Message › Cancel Message: posts a control message cancelling one of your news articles.
  func cancelNewsMessage(_ loaded: LoadedMessage) async {
    guard loaded.account.kind == .nntp, let messageID = loaded.parsed.messageID else { return }
    var message = OutgoingMessage(
      from: loaded.parsed.from.first ?? loaded.account.address, to: [], subject: "cancel \(messageID)",
      body: "This message was cancelled from within Thunderbird.")
    message.newsgroups = (loaded.parsed.headers["Newsgroups"] ?? "").split(separator: ",").map {
      $0.trimmingCharacters(in: .whitespaces)
    }
    message.extraHeaders = [HeaderField(name: "Control", value: "cancel \(messageID)")]
    do {
      _ = try await MailSender.send(message, account: loaded.account)
    } catch {
      report(error, title: "Couldn't cancel the message")
    }
  }

  // MARK: - Offline

  /// File › Offline › Download/Sync Now, Get Starred Messages and Get Selected Messages.
  func downloadForOffline(_ which: OfflineDownload) async {
    let wasOffline = isOffline
    isOffline = false
    defer { isOffline = wasOffline }
    activity = "Downloading messages for offline use…"
    defer { activity = nil }
    switch which {
    case .selected, .starred:
      let targets = which == .selected ? selectedItems : items.filter(\.summary.isFlagged)
      for item in targets {
        _ = try? await backend(item.reference.accountID)?.message(uid: item.reference.uid, in: item.reference.path)
      }
    case .everything:
      for account in accounts {
        guard let backend = backend(account.id) else { continue }
        for folder in (folders[account.id] ?? []) where folder.isSelectable && folder.role != .trash && folder.role != .junk {
          let result = try? await backend.sync(path: folder.path, limit: 500)
          for summary in result?.messages ?? [] {
            _ = try? await backend.message(uid: summary.uid, in: folder.path)
          }
        }
      }
    }
  }

  func emptyAllTrash() async {
    for account in accounts {
      if let trash = folder(role: .trash, in: account.id) {
        await emptyFolder(FolderSelection(accountID: account.id, path: trash.path))
      }
    }
  }

  // MARK: - Files

  func saveAsTemplate(_ loaded: LoadedMessage) async {
    do {
      var draft = ComposeDraft.reopen(loaded.parsed, reference: loaded.reference, account: loaded.account, asTemplate: true)
      draft.accountID = loaded.account.canSend ? loaded.account.id : sendingAccounts.first?.id
      try await saveDraft(draft, asTemplate: true)
    } catch {
      report(error, title: "Couldn't save the template")
    }
  }

  /// File › Open › Saved Message…
  func openSavedMessage(_ url: URL) -> LoadedMessage? {
    guard let raw = try? Data(contentsOf: url) else { return nil }
    let (display, security) = MessageSecurity.unprotect(raw)
    let account = mailAccounts.first ?? .localFolders()
    return LoadedMessage(
      reference: MessageReference(accountID: UUID(), path: url.path, uid: 0),
      summary: MessageSummary(uid: 0, data: raw, flags: [MessageFlag.seen]), parsed: ParsedMessage(data: display), raw: raw,
      account: account, security: security, folderRole: .normal)
  }

  /// File › Get Next N News Messages.
  func getMoreNews() async {
    guard let selection = selectedFolder, account(selection.accountID)?.kind == .nntp, let backend = backend(selection.accountID)
    else { return }
    let current = items.count
    if let result = try? await backend.sync(path: selection.path, limit: current + 500) {
      items = result.messages.map {
        MessageItem(reference: MessageReference(accountID: selection.accountID, path: selection.path, uid: $0.uid), summary: $0)
      }
    }
  }
}
