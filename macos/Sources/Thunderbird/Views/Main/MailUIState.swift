/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import AppKit
import Observation
import SwiftUI
import ThunderbirdCore

/// View › Layout.
enum PaneLayout: String, CaseIterable {
  case classic, wide, vertical

  var title: String {
    switch self {
    case .classic: "Classic View"
    case .wide: "Wide View"
    case .vertical: "Vertical View"
    }
  }
}

/// The message list's card or table presentation (the toolbar's view picker).
enum ListStyle: String, CaseIterable {
  case cards, table
}

/// View › Density.
enum Density: String, CaseIterable {
  case compact, normal, relaxed

  var title: String {
    switch self {
    case .compact: "Compact"
    case .normal: "Default"
    case .relaxed: "Relaxed"
    }
  }

  var rowPadding: CGFloat {
    switch self {
    case .compact: 1
    case .normal: 4
    case .relaxed: 9
    }
  }
}

/// View › Headers.
enum HeaderMode: String, CaseIterable {
  case normal, all
}

/// View › Message Body As.
enum BodyMode: String, CaseIterable {
  case original, simple, plain, allParts

  var title: String {
    switch self {
    case .original: "Original HTML"
    case .simple: "Simple HTML"
    case .plain: "Plain Text"
    case .allParts: "All Body Parts"
    }
  }
}

enum MailPreferences {
  static let layout = "paneLayout"
  static let listStyle = "messageListStyle"
  static let density = "uiDensity"
  static let fontScale = "uiFontScale"
  static let showFolderPane = "showFolderPane"
  static let showMessagePane = "showMessagePane"
  static let showListHeader = "showMessageListHeader"
  static let showQuickFilter = "showQuickFilterBar"
  static let showStatusBar = "showStatusBar"
  static let showSpacesToolbar = "showSpacesToolbar"
  static let headerMode = "headerMode"
  static let bodyMode = "bodyMode"
  static let attachmentsInline = "attachmentsInline"
  static let messageZoom = "messageZoom"
  /// "summary" or "webPage", for View › Feed Message Body As.
  static let feedBodyMode = "feedBodyMode"
}

/// Sheets and transient UI for the mail space, shared with the menu bar through a focused value.
@MainActor
@Observable
final class MailUIState {
  enum Sheet: Identifiable {
    case accountSetup
    case setup(AccountSetupView.Mode)
    case feedSubscriptions(UUID)
    case search
    case source(Data)
    case newFolder(FolderSelection)
    case newSavedSearch
    case markReadByDate
    case newTag
    case manageTags
    case createFilter(MessageSummary, UUID)
    case redirect(LoadedMessage)
    case imapSubscribe(UUID)
    case newsSubscribe(UUID)
    case folderProperties(FolderSelection)
    case event(EventDraft)
    case moveTo(copy: Bool)

    var id: String {
      switch self {
      case .accountSetup: "accountSetup"
      case .setup(let mode): "setup\(mode.rawValue)"
      case .feedSubscriptions(let id): "feeds\(id.uuidString)"
      case .search: "search"
      case .source: "source"
      case .newFolder(let folder): "newFolder\(folder.id)"
      case .newSavedSearch: "newSavedSearch"
      case .markReadByDate: "markReadByDate"
      case .newTag: "newTag"
      case .manageTags: "manageTags"
      case .createFilter: "createFilter"
      case .redirect: "redirect"
      case .imapSubscribe: "imapSubscribe"
      case .newsSubscribe: "newsSubscribe"
      case .folderProperties(let folder): "properties\(folder.id)"
      case .event: "event"
      case .moveTo(let copy): "moveTo\(copy)"
      }
    }
  }

  var sheet: Sheet?
  var findVisible = false
  var findText = ""
  let reader = ReaderController()

  func present(_ sheet: Sheet) {
    self.sheet = sheet
  }
}

extension FocusedValues {
  @Entry var mailUI: MailUIState?
}

extension FolderSelection: Identifiable {
  var id: String { "\(accountID.uuidString)/\(path)" }
}
