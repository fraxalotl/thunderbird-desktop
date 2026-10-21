/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import AppKit
import SwiftUI

/// The composer's formatting toolbar (mail/components/compose/content/editFormatButtons.inc.xhtml).
struct FormatBar: View {
  let controller: ComposerController
  @State private var textColor = Color.black
  @State private var backgroundColor = Color.white

  static let paragraphStyles: [(String, String)] = [
    ("Body Text", "div"), ("Paragraph", "p"), ("Heading 1", "h1"), ("Heading 2", "h2"), ("Heading 3", "h3"),
    ("Heading 4", "h4"), ("Heading 5", "h5"), ("Heading 6", "h6"), ("Address", "address"), ("Preformat", "pre"),
  ]

  static let fonts: [(String, String)] = [
    ("Variable Width", "-apple-system, Helvetica, Arial, sans-serif"), ("Fixed Width", "Menlo, Courier, monospace"),
    ("Helvetica, Arial", "Helvetica, Arial, sans-serif"), ("Times", "Times, 'Times New Roman', serif"),
    ("Courier", "Courier, 'Courier New', monospace"),
  ]

  static let sizes: [(String, String)] = [
    ("Tiny", "1"), ("Small", "2"), ("Medium", "3"), ("Large", "4"), ("Extra Large", "5"), ("Huge", "6"),
  ]

  var body: some View {
    ScrollView(.horizontal) {
      GlassEffectContainer(spacing: 6) {
        HStack(spacing: 6) {
          Picker("Paragraph", selection: Binding(get: { controller.paragraph }, set: { controller.exec("formatBlock", $0) })) {
            ForEach(Self.paragraphStyles, id: \.1) { Text($0.0).tag($0.1) }
          }
          .labelsHidden()
          .frame(width: 120)
          .help("Paragraph format")
          Menu {
            ForEach(Self.fonts, id: \.1) { name, family in
              Button(name) { controller.exec("fontName", family) }
            }
            Divider()
            Button("Show Fonts…") { NSFontManager.shared.orderFrontFontPanel(nil) }
          } label: {
            Text(controller.fontName.isEmpty ? "Variable Width" : controller.fontName.components(separatedBy: ",").first ?? "")
              .lineLimit(1)
              .frame(width: 96, alignment: .leading)
          }
          .fixedSize()
          .help("Font")

          ColorPicker("Text colour", selection: $textColor, supportsOpacity: false)
            .labelsHidden()
            .onChange(of: textColor) { _, value in controller.exec("foreColor", value.hexString) }
            .help("Text colour")
          ColorPicker("Background colour", selection: $backgroundColor, supportsOpacity: false)
            .labelsHidden()
            .onChange(of: backgroundColor) { _, value in controller.exec("hiliteColor", value.hexString) }
            .help("Background colour")

          Menu {
            ForEach(Self.sizes, id: \.1) { name, size in Button(name) { controller.exec("fontSize", size) } }
          } label: {
            Image(systemName: "textformat.size")
          }
          .menuIndicator(.hidden)
          .fixedSize()
          .help("Font size")
          button("Smaller Size", "textformat.size.smaller", active: false) { controller.exec("decreaseFontSize") }
          button("Larger Size", "textformat.size.larger", active: false) { controller.exec("increaseFontSize") }

          Divider().frame(height: 18)

          button("Bold", "bold", active: controller.isBold) { controller.exec("bold") }
          button("Italic", "italic", active: controller.isItalic) { controller.exec("italic") }
          button("Underline", "underline", active: controller.isUnderlined) { controller.exec("underline") }
          button("Remove Text Styling", "eraser", active: false) { controller.exec("removeFormat") }

          Divider().frame(height: 18)

          button("Bulleted List", "list.bullet", active: controller.isBulleted) { controller.exec("insertUnorderedList") }
          button("Numbered List", "list.number", active: controller.isNumbered) { controller.exec("insertOrderedList") }
          button("Decrease Indent", "decrease.indent", active: false) { controller.exec("outdent") }
          button("Increase Indent", "increase.indent", active: false) { controller.exec("indent") }

          Menu {
            Button("Align Left") { controller.exec("justifyLeft") }
            Button("Center") { controller.exec("justifyCenter") }
            Button("Align Right") { controller.exec("justifyRight") }
            Button("Justify") { controller.exec("justifyFull") }
          } label: {
            Image(systemName: controller.alignment == "center" ? "text.aligncenter"
              : controller.alignment == "right" ? "text.alignright"
              : controller.alignment == "justify" ? "text.justify" : "text.alignleft")
          }
          .menuIndicator(.hidden)
          .fixedSize()
          .help("Choose alignment")

          Menu {
            Button("Link…") { controller.dialog = .link }
            Button("Anchor…") { controller.dialog = .anchor }
            Button("Image…") { controller.insertImage() }
            Button("Horizontal Line") { controller.exec("insertHorizontalRule") }
            Button("Table…") { controller.dialog = .table }
          } label: {
            Image(systemName: "plus.rectangle.on.rectangle")
          }
          .menuIndicator(.hidden)
          .fixedSize()
          .help("Insert a link, anchor, image, horizontal line or table")

          button("Emoji & Symbols", "face.smiling", active: false) { controller.insertCharacters() }
        }
        .buttonStyle(.glass)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
      }
    }
    .scrollIndicators(.never)
  }

  private func button(_ title: String, _ symbol: String, active: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .frame(width: 16, height: 16)
    }
    .glassEffect(active ? .regular.tint(.accentColor.opacity(0.5)) : .regular, in: .capsule)
    .help(title)
    .accessibilityLabel(title)
    .accessibilityAddTraits(active ? .isSelected : [])
  }
}
