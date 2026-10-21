/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import SwiftUI
import ThunderbirdCore
import UniformTypeIdentifiers

/// The composer's dialogs (mail/components/compose/content/dialogs).
struct ComposeDialogView: View {
  @Environment(\.dismiss) private var dismiss
  let dialog: ComposeDialog
  let controller: ComposerController

  @State private var text = ""
  @State private var secondary = ""
  @State private var rows = 2
  @State private var columns = 2
  @State private var border = 1
  @State private var width = "100%"
  @State private var padding = 4
  @State private var display = false
  @State private var color1 = Color.black
  @State private var color2 = Color.white
  @State private var color3 = Color.blue
  @State private var choice = "disc"
  @State private var targetTable = false

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(title).font(.title3.weight(.semibold))
      content
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        if dialog != .keyAssistant && dialog != .reorderAttachments {
          Button(confirmTitle) {
            apply()
            dismiss()
          }
          .buttonStyle(.glassProminent)
          .keyboardShortcut(.defaultAction)
        } else {
          Button("Done") { dismiss() }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.defaultAction)
        }
      }
    }
    .padding(22)
    .frame(width: dialog == .html || dialog == .math || dialog == .keyAssistant ? 560 : 420)
    .onAppear(perform: prepare)
  }

  private var title: String {
    switch dialog {
    case .link: "Link Properties"
    case .anchor: "Named Anchor Properties"
    case .image: "Image Properties"
    case .table: "Insert Table"
    case .html: "Insert HTML"
    case .math: "Insert Math"
    case .tableProperties: "Table Properties"
    case .pageColors: "Page Colors and Background"
    case .listProperties: "List Properties"
    case .imageProperties: "Image Properties"
    case .findReplace: "Find and Replace"
    case .keyAssistant: "OpenPGP Key Assistant"
    case .attachWebPage: "Attach Web Page"
    case .renameAttachment: "Rename Attachment"
    case .reorderAttachments: "Reorder Attachments"
    }
  }

  private var confirmTitle: String {
    switch dialog {
    case .attachWebPage: "Attach"
    case .renameAttachment: "Rename"
    case .tableProperties, .pageColors, .listProperties, .imageProperties: "Apply"
    default: "Insert"
    }
  }

  private func prepare() {
    switch dialog {
    case .link:
      Task { text = (await controller.run("return tb.selectedText()") as? String) ?? "" }
      secondary = "https://"
    case .renameAttachment:
      text = controller.attachmentToRename?.lastPathComponent ?? ""
    case .math:
      text = "\\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}"
    default:
      break
    }
  }

  @ViewBuilder
  private var content: some View {
    switch dialog {
    case .link:
      TextField("Link text", text: $text)
      TextField("Link location (URL or #anchor)", text: $secondary)
    case .anchor:
      TextField("Anchor name", text: $text)
    case .table:
      Stepper("Rows: \(rows)", value: $rows, in: 1...50)
      Stepper("Columns: \(columns)", value: $columns, in: 1...20)
      Stepper("Border: \(border) px", value: $border, in: 0...10)
      TextField("Width", text: $width)
    case .html:
      Text("Enter HTML tags and text:").foregroundStyle(.secondary)
      TextEditor(text: $text)
        .font(.body.monospaced())
        .frame(height: 220)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
    case .math:
      Text("Enter LaTeX source:").foregroundStyle(.secondary)
      TextEditor(text: $text)
        .font(.body.monospaced())
        .frame(height: 120)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
      Toggle("Display mode", isOn: $display)
      Text("Supports fractions, roots, sub- and superscripts, Greek letters and common operators.")
        .font(.caption)
        .foregroundStyle(.secondary)
    case .tableProperties:
      Stepper("Border: \(border) px", value: $border, in: 0...10)
      Stepper("Cell padding: \(padding) px", value: $padding, in: 0...20)
      TextField("Width", text: $width)
      ColorPicker("Background colour", selection: $color2, supportsOpacity: false)
      Picker("Apply colour to", selection: $targetTable) {
        Text("Cell").tag(false)
        Text("Table").tag(true)
      }
      .pickerStyle(.segmented)
    case .pageColors:
      ColorPicker("Normal text", selection: $color1, supportsOpacity: false)
      ColorPicker("Background", selection: $color2, supportsOpacity: false)
      ColorPicker("Link text", selection: $color3, supportsOpacity: false)
    case .listProperties:
      Picker("Bullet style", selection: $choice) {
        Text("Solid circle").tag("disc")
        Text("Open circle").tag("circle")
        Text("Solid square").tag("square")
        Text("1, 2, 3…").tag("decimal")
        Text("A, B, C…").tag("upper-alpha")
        Text("a, b, c…").tag("lower-alpha")
        Text("I, II, III…").tag("upper-roman")
        Text("i, ii, iii…").tag("lower-roman")
      }
    case .imageProperties, .image:
      TextField("Alternate text", text: $text)
      TextField("Width (e.g. 300px or 50%)", text: $secondary)
    case .attachWebPage:
      TextField("Web page address", text: $text, prompt: Text("https://example.com"))
    case .renameAttachment:
      TextField("New name", text: $text)
    case .reorderAttachments:
      ReorderAttachmentsList(controller: controller)
    case .keyAssistant:
      KeyAssistantView(controller: controller)
    case .findReplace:
      EmptyView()
    }
  }

  private func apply() {
    switch dialog {
    case .link:
      let label = text.isEmpty ? secondary : text
      controller.insertHTML("<a href=\"\(ComposeDraft.escape(secondary))\">\(ComposeDraft.escape(label))</a>")
    case .anchor:
      let name = text.replacingOccurrences(of: " ", with: "_")
      controller.insertHTML("<a name=\"\(ComposeDraft.escape(name))\"></a>")
    case .table:
      Task {
        _ = await controller.run(
          "tb.insertTable(r, c, b, w)", ["r": rows, "c": columns, "b": border, "w": width.isEmpty ? "100%" : width])
      }
    case .html:
      controller.insertHTML(text)
    case .math:
      controller.insertHTML(LaTeX.mathML(text, display: display))
    case .tableProperties:
      controller.tableOperation("properties", ["border": border, "width": width, "padding": padding])
      controller.tableOperation("color", ["target": targetTable ? "table" : "cell", "color": color2.hexString])
    case .pageColors:
      Task {
        _ = await controller.run(
          "tb.pageColors(t, b, l)", ["t": color1.hexString, "b": color2.hexString, "l": color3.hexString])
      }
    case .listProperties:
      Task { _ = await controller.run("tb.listStyle(t)", ["t": choice]) }
    case .imageProperties, .image:
      Task { _ = await controller.run("tb.imageProperties(a, w)", ["a": text, "w": secondary]) }
    case .attachWebPage:
      let address = text
      Task { await controller.attachWebPage(address) }
    case .renameAttachment:
      if let url = controller.attachmentToRename {
        controller.renameAttachment(url, to: text)
      }
    case .keyAssistant, .reorderAttachments, .findReplace:
      break
    }
  }
}

private struct ReorderAttachmentsList: View {
  let controller: ComposerController

  var body: some View {
    List {
      ForEach(controller.draft.attachments, id: \.self) { url in
        Label(url.lastPathComponent, systemImage: "doc")
      }
      .onMove { controller.draft.attachments.move(fromOffsets: $0, toOffset: $1) }
    }
    .frame(height: 220)
    HStack {
      Button("Sort A–Z") {
        controller.draft.attachments.sort { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
      }
      Button("Sort Z–A") {
        controller.draft.attachments.sort { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedDescending }
      }
    }
    .buttonStyle(.glass)
  }
}

/// Security › Key Assistant: shows which recipients have usable OpenPGP keys and finds missing ones.
private struct KeyAssistantView: View {
  let controller: ComposerController
  @State private var status: [String: String] = [:]
  @State private var refresh = 0

  private var recipients: [MailAddress] {
    MailAddress.parseList([controller.draft.to, controller.draft.cc, controller.draft.bcc].joined(separator: ","))
  }

  var body: some View {
    let _ = refresh
    List(recipients, id: \.email) { recipient in
      let keys = OpenPGP.shared.keys(for: recipient.email)
      HStack {
        Image(systemName: keys.isEmpty ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
          .foregroundStyle(keys.isEmpty ? .orange : .green)
        VStack(alignment: .leading) {
          Text(recipient.formatted)
          Text(status[recipient.email] ?? (keys.isEmpty ? "No usable key" : "Key \(keys[0].keyID)"))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if keys.isEmpty {
          Button("Discover") {
            Task {
              status[recipient.email] = "Looking on keys.openpgp.org…"
              let found = (try? await OpenPGP.shared.discoverKey(for: recipient.email)) ?? 0
              status[recipient.email] = found > 0 ? "Imported \(found) key" : "No key was found online"
              refresh += 1
            }
          }
          .buttonStyle(.glass)
          Button("Import…") {
            let panel = NSOpenPanel()
            if panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) {
              _ = try? OpenPGP.shared.importKeys(data)
              refresh += 1
            }
          }
          .buttonStyle(.glass)
        }
      }
    }
    .frame(height: 260)
  }
}
