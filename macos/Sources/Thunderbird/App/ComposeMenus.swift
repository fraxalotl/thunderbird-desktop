/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import AppKit
import SwiftUI
import ThunderbirdCore

/// The compose window's Insert, Format, Options and Security menus
/// (mail/components/compose/content/messengercompose.xhtml). They are disabled unless a compose
/// window is focused.
struct ComposeMenus: Commands {
  let mail: MailStore
  @FocusedValue(\.composer) private var composer

  var body: some Commands {
    CommandMenu("Insert") {
      if let composer, composer.draft.isHTML {
        Button("Image…") { composer.insertImage() }
        Button("Table…") { composer.dialog = .table }
        Button("Link…") { composer.dialog = .link }
          .keyboardShortcut("k", modifiers: [.command, .shift])
        Button("Named Anchor…") { composer.dialog = .anchor }
        Button("Horizontal Line") { composer.exec("insertHorizontalRule") }
        Button("HTML…") { composer.dialog = .html }
        Button("Math…") { composer.dialog = .math }
        Button("Characters and Symbols…") { composer.insertCharacters() }
          .keyboardShortcut(" ", modifiers: [.command, .control])
        Menu("Table of Contents") {
          Button("Insert") { Task { _ = await composer.run("tb.toc('insert')") } }
          Button("Update") { Task { _ = await composer.run("tb.toc('update')") } }
          Button("Remove") { Task { _ = await composer.run("tb.toc('remove')") } }
        }
        Divider()
        Button("Break Below Image(s)") { composer.call("breakBelowImages") }
      } else {
        Button("Image…") {}.disabled(true)
        Button("Table…") {}.disabled(true)
        Button("Link…") {}.disabled(true)
        Button("HTML…") {}.disabled(true)
      }
    }

    CommandMenu("Format") {
      if let composer, composer.draft.isHTML {
        Menu("Font") {
          ForEach(FormatBar.fonts, id: \.1) { name, family in
            Button(name) { composer.exec("fontName", family) }
          }
          Divider()
          Button("Show Fonts…") { NSFontManager.shared.orderFrontFontPanel(nil) }
        }
        Menu("Size") {
          Button("Smaller") { composer.exec("decreaseFontSize") }
            .keyboardShortcut("-", modifiers: [.command, .option])
          Button("Larger") { composer.exec("increaseFontSize") }
            .keyboardShortcut("=", modifiers: [.command, .option])
          Divider()
          ForEach(FormatBar.sizes, id: \.1) { name, size in
            Button(name) { composer.exec("fontSize", size) }
          }
        }
        Menu("Text Style") {
          Button("Bold") { composer.exec("bold") }.keyboardShortcut("b")
          Button("Italic") { composer.exec("italic") }.keyboardShortcut("i")
          Button("Underline") { composer.exec("underline") }.keyboardShortcut("u")
          Button("Strikethrough") { composer.exec("strikeThrough") }
          Button("Superscript") { composer.exec("superscript") }
          Button("Subscript") { composer.exec("subscript") }
          Button("Fixed Width") { composer.wrap("tt") }.keyboardShortcut("t", modifiers: [.command, .control])
          Button("Nonbreaking") { composer.call("nonbreaking") }
          Divider()
          Button("Emphasis") { composer.wrap("em") }
          Button("Stronger Emphasis") { composer.wrap("strong") }
          Button("Citation") { composer.wrap("cite") }
          Button("Abbreviation") { composer.wrap("abbr") }
          Button("Acronym") { composer.wrap("abbr") }
          Button("Code") { composer.wrap("code") }
          Button("Sample Output") { composer.wrap("samp") }
          Button("Variable") { composer.wrap("var") }
        }
        Button("Text Color…") { NSColorPanel.shared.orderFront(nil) }
        Divider()
        Button("Remove All Text Styles") { composer.exec("removeFormat") }
          .keyboardShortcut("y", modifiers: [.command, .shift])
        Button("Remove Links") { composer.call("removeLinks") }
          .keyboardShortcut("k", modifiers: [.command, .option])
        Button("Remove Named Anchors") { composer.call("removeAnchors") }
        Divider()
        Menu("Paragraph") {
          ForEach(FormatBar.paragraphStyles, id: \.1) { name, tag in
            Button(name) { composer.exec("formatBlock", tag) }
          }
        }
        Menu("List") {
          Button("None") {
            if composer.isBulleted { composer.exec("insertUnorderedList") }
            if composer.isNumbered { composer.exec("insertOrderedList") }
          }
          Button("Bulleted") { composer.exec("insertUnorderedList") }
          Button("Numbered") { composer.exec("insertOrderedList") }
          Button("Term") { Task { _ = await composer.run("tb.definitionList('dt')") } }
          Button("Definition") { Task { _ = await composer.run("tb.definitionList('dd')") } }
          Divider()
          Button("List Properties…") { composer.dialog = .listProperties }
        }
        Divider()
        Button("Increase Indent") { composer.exec("indent") }
          .keyboardShortcut("]")
        Button("Decrease Indent") { composer.exec("outdent") }
          .keyboardShortcut("[")
        Menu("Align") {
          Button("Left") { composer.exec("justifyLeft") }
          Button("Center") { composer.exec("justifyCenter") }
          Button("Right") { composer.exec("justifyRight") }
          Button("Justify") { composer.exec("justifyFull") }
        }
        Divider()
        Menu("Table") {
          Menu("Insert") {
            Button("Table…") { composer.dialog = .table }
            Divider()
            Button("Row Above") { composer.tableOperation("rowAbove") }
            Button("Row Below") { composer.tableOperation("rowBelow") }
            Divider()
            Button("Column Before") { composer.tableOperation("colBefore") }
            Button("Column After") { composer.tableOperation("colAfter") }
            Divider()
            Button("Cell Before") { composer.tableOperation("cellBefore") }
            Button("Cell After") { composer.tableOperation("cellAfter") }
          }
          Menu("Select") {
            Button("Table") { composer.tableOperation("select", "table") }
            Button("Row") { composer.tableOperation("select", "row") }
            Button("Column") { composer.tableOperation("select", "column") }
            Button("Cell") { composer.tableOperation("select", "cell") }
            Button("All Cells") { composer.tableOperation("select", "all") }
          }
          Menu("Delete") {
            Button("Table") { composer.tableOperation("deleteTable") }
            Button("Row") { composer.tableOperation("deleteRow") }
            Button("Column") { composer.tableOperation("deleteColumn") }
            Button("Cell") { composer.tableOperation("deleteCell") }
            Button("Cell Contents") { composer.tableOperation("deleteContents") }
          }
          Divider()
          Button("Join with Cell to the Right") { composer.tableOperation("join") }
          Button("Split Cell") { composer.tableOperation("split") }
          Button("Create Table from Selection") { composer.call("tableFromSelection") }
          Divider()
          Button("Table or Cell Background Color…") { composer.dialog = .tableProperties }
          Button("Table Properties…") { composer.dialog = .tableProperties }
        }
        .disabled(!composer.inTable)
        Divider()
        Button("Image Properties…") { composer.dialog = .imageProperties }
        Button("Page Colors and Background…") { composer.dialog = .pageColors }
      } else {
        Button("Rich Text (HTML)") { composer?.switchFormat(toHTML: true) }
          .disabled(composer == nil || mail.identity(for: composer!.draft)?.0.kind == .nntp)
      }
    }

    CommandMenu("Options") {
      if let composer {
        Button("Check Spelling…") { composer.checkSpelling() }
          .keyboardShortcut("k", modifiers: [.command, .shift, .option])
        Toggle(
          "Spellcheck As You Type",
          isOn: Binding(get: { composer.spellcheckAsYouType }, set: { _ in composer.toggleSpellcheckAsYouType() }))
        Button("Quote Message") { Task { await composer.quoteMessage() } }
          .disabled(composer.draft.source == nil)
        Divider()
        Toggle(
          "Return Receipt",
          isOn: Binding(get: { composer.draft.requestReturnReceipt }, set: { composer.draft.requestReturnReceipt = $0 }))
        Toggle(
          "Delivery Status Notification",
          isOn: Binding(get: { composer.draft.requestDSN }, set: { composer.draft.requestDSN = $0 }))
        Divider()
        Menu("Sending Format") {
          Picker("Sending Format", selection: Binding(get: { composer.draft.sendFormat }, set: { composer.draft.sendFormat = $0 })) {
            ForEach(SendFormat.allCases, id: \.self) { Text($0.title).tag($0) }
          }
          .pickerStyle(.inline)
        }
        Menu("Priority") {
          PriorityMenuItems(controller: composer)
        }
        FolderPickerMenu(title: "Send a Copy To", store: mail) { folder in composer.draft.copyToFolder = folder }
        if composer.draft.copyToFolder != nil {
          Button("Send a Copy to Sent (default)") { composer.draft.copyToFolder = nil }
        }
        Divider()
        Toggle(
          "Rich Text (HTML)",
          isOn: Binding(get: { composer.draft.isHTML }, set: { composer.switchFormat(toHTML: $0) }))
      } else {
        Button("Check Spelling…") {}.disabled(true)
      }
    }

    CommandMenu("Security") {
      if let composer {
        SecurityMenuItems(controller: composer)
      } else {
        Button("Encrypt") {}.disabled(true)
      }
    }
  }
}

/// File menu items while a compose window is focused.
struct ComposeFileMenu: View {
  let composer: ComposerController
  let openWindow: OpenWindowAction
  let mail: MailStore

  var body: some View {
    Menu("New") {
      Button("Message") { openWindow(id: WindowID.compose, value: mail.newDraft()) }
        .keyboardShortcut("n")
      Divider()
      Button("Address Book Contact…") {
        NSWorkspace.shared.open(URL(filePath: "/System/Applications/Contacts.app"))
      }
    }
    Menu("Attach") {
      AttachMenuItems(controller: composer)
    }
  }
}

struct ComposeSaveMenu: View {
  let composer: ComposerController

  var body: some View {
    Button("Save") { Task { await composer.saveDraft() } }
      .keyboardShortcut("s")
    Menu("Save As") {
      Button("File…") { Task { await composer.saveAsFile() } }
      Divider()
      Button("Draft") { Task { await composer.saveDraft() } }
      Button("Template") { Task { await composer.saveTemplate() } }
    }
    Divider()
    Button("Send") {
      let viaShortcut = NSApp.currentEvent?.type == .keyDown
      Task { await composer.send(viaShortcut: viaShortcut) }
    }
      .keyboardShortcut(.return, modifiers: .command)
    Button("Send Later") { Task { await composer.sendLater() } }
      .keyboardShortcut(.return, modifiers: [.command, .shift])
  }
}

struct ComposeEditMenu: View {
  let composer: ComposerController

  var body: some View {
    Button("Paste Without Formatting") { composer.pasteWithoutFormatting() }
      .keyboardShortcut("v", modifiers: [.command, .shift, .option])
    Button("Paste As Quotation") { composer.pasteAsQuotation() }
      .keyboardShortcut("o", modifiers: [.command, .shift])
    Divider()
    Button("Rewrap") { composer.rewrap() }
      .keyboardShortcut("r")
      .disabled(composer.draft.isHTML)
    Button("Rename Attachment…") {
      composer.attachmentToRename = composer.draft.attachments.first
      composer.dialog = .renameAttachment
    }
    .disabled(composer.draft.attachments.isEmpty)
    Button("Reorder Attachments…") { composer.dialog = .reorderAttachments }
      .disabled(composer.draft.attachments.count < 2)
    Divider()
    Button("Account Settings") {
      UserDefaults.standard.set("accounts", forKey: "settingsTab")
      NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
  }
}

struct ComposeFindMenu: View {
  let composer: ComposerController

  var body: some View {
    Menu("Find") {
      Button("Find…") { composer.dialog = .findReplace }
        .keyboardShortcut("f")
      Button("Find and Replace…") { composer.dialog = .findReplace }
        .keyboardShortcut("f", modifiers: [.command, .option])
      Button("Find Again") { composer.find() }
        .keyboardShortcut("g")
      Button("Find Previous") { composer.find(backwards: true) }
        .keyboardShortcut("g", modifiers: [.command, .shift])
    }
  }
}

struct ComposeViewMenu: View {
  let composer: ComposerController

  var body: some View {
    Menu("Toolbars") {
      Toggle("Formatting Bar", isOn: Binding(get: { composer.showFormatBar }, set: { composer.showFormatBar = $0 }))
      Toggle("Status Bar", isOn: Binding(get: { composer.showStatusBar }, set: { composer.showStatusBar = $0 }))
      Divider()
      Button("Customize…") { NSApp.sendAction(#selector(NSWindow.runToolbarCustomizationPalette(_:)), to: nil, from: nil) }
    }
    Menu("Zoom") {
      Button("Zoom In") { composer.zoom = min(3, composer.zoom + 0.1) }
        .keyboardShortcut("+")
      Button("Zoom Out") { composer.zoom = max(0.5, composer.zoom - 0.1) }
        .keyboardShortcut("-")
      Divider()
      Button("Reset") { composer.zoom = 1 }
        .keyboardShortcut("0")
    }
    Divider()
    Toggle("To Field", isOn: .constant(true)).disabled(true)
    Toggle("Cc Field", isOn: Binding(get: { composer.showCc }, set: { composer.showCc = $0 }))
      .keyboardShortcut("c", modifiers: [.command, .shift])
    Toggle("Bcc Field", isOn: Binding(get: { composer.showBcc }, set: { composer.showBcc = $0 }))
      .keyboardShortcut("b", modifiers: [.command, .shift])
    Toggle("Reply-To Field", isOn: Binding(get: { composer.showReplyTo }, set: { composer.showReplyTo = $0 }))
    Toggle("Newsgroup Field", isOn: Binding(get: { composer.showNewsgroups }, set: { composer.showNewsgroups = $0 }))
    Toggle("Followup-To Field", isOn: Binding(get: { composer.showFollowupTo }, set: { composer.showFollowupTo = $0 }))
    Divider()
    Toggle("Contacts Sidebar", isOn: Binding(get: { composer.showContactsSidebar }, set: { composer.showContactsSidebar = $0 }))
      .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF9FunctionKey)!)), modifiers: [])
    Toggle("Attachment Pane", isOn: Binding(get: { composer.showAttachmentPane }, set: { composer.showAttachmentPane = $0 }))
      .keyboardShortcut("m", modifiers: [.command, .shift])
    Divider()
  }
}
