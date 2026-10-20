/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import AppKit
import Observation
import SwiftUI

/// Owns the compose text view so the format bar and send logic can reach it.
@MainActor
@Observable
final class RichTextController {
  @ObservationIgnored weak var textView: NSTextView?
  private(set) var isBold = false
  private(set) var isItalic = false
  private(set) var isUnderlined = false

  static let defaultFont = NSFont(name: "Helvetica", size: 14) ?? .systemFont(ofSize: 14)

  func load(html: String) {
    guard let textView else { return }
    let wrapped = "<meta charset=\"utf-8\"><div style=\"font-family: Helvetica; font-size: 14px\">\(html)</div>"
    let attributed =
      (try? NSAttributedString(
        data: Data(wrapped.utf8),
        options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
        documentAttributes: nil)) ?? NSAttributedString(string: "")
    textView.textStorage?.setAttributedString(attributed)
    textView.setSelectedRange(NSRange(location: 0, length: 0))
  }

  func load(plain: String) {
    textView?.textStorage?.setAttributedString(
      NSAttributedString(string: plain, attributes: [.font: Self.defaultFont, .foregroundColor: NSColor.black]))
  }

  var plainText: String { textView?.string ?? "" }

  var html: String {
    guard let storage = textView?.textStorage, storage.length > 0 else { return "" }
    let data = try? storage.data(
      from: NSRange(location: 0, length: storage.length),
      documentAttributes: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue])
    return data.map { String(decoding: $0, as: UTF8.self) } ?? ""
  }

  var hasInlineImages: Bool {
    guard let storage = textView?.textStorage else { return false }
    var found = false
    storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, stop in
      if value != nil {
        found = true
        stop.pointee = true
      }
    }
    return found
  }

  func updateState() {
    guard let textView else { return }
    let attributes =
      textView.selectedRange().length > 0 && textView.textStorage!.length > 0
      ? textView.textStorage!.attributes(at: textView.selectedRange().location, effectiveRange: nil)
      : textView.typingAttributes
    let font = attributes[.font] as? NSFont ?? Self.defaultFont
    let traits = NSFontManager.shared.traits(of: font)
    isBold = traits.contains(.boldFontMask)
    isItalic = traits.contains(.italicFontMask)
    isUnderlined = (attributes[.underlineStyle] as? Int ?? 0) != 0
  }

  private func apply(_ transform: (inout [NSAttributedString.Key: Any]) -> Void) {
    guard let textView, let storage = textView.textStorage else { return }
    let range = textView.selectedRange()
    if range.length == 0 {
      var attributes = textView.typingAttributes
      transform(&attributes)
      textView.typingAttributes = attributes
    } else {
      guard textView.shouldChangeText(in: range, replacementString: nil) else { return }
      storage.beginEditing()
      storage.enumerateAttributes(in: range) { existing, subrange, _ in
        var attributes = existing
        transform(&attributes)
        storage.setAttributes(attributes, range: subrange)
      }
      storage.endEditing()
      textView.didChangeText()
    }
    updateState()
  }

  func toggle(_ trait: NSFontTraitMask) {
    updateState()
    let enable = trait == .boldFontMask ? !isBold : !isItalic
    apply { attributes in
      let font = attributes[.font] as? NSFont ?? Self.defaultFont
      attributes[.font] =
        enable
        ? NSFontManager.shared.convert(font, toHaveTrait: trait) : NSFontManager.shared.convert(font, toNotHaveTrait: trait)
    }
  }

  func toggleUnderline() {
    updateState()
    let enable = !isUnderlined
    apply { $0[.underlineStyle] = enable ? NSUnderlineStyle.single.rawValue : nil }
  }

  func setSize(_ size: CGFloat) {
    apply { attributes in
      let font = attributes[.font] as? NSFont ?? Self.defaultFont
      attributes[.font] = NSFontManager.shared.convert(font, toSize: size)
    }
  }

  func setColor(_ color: NSColor) {
    apply { $0[.foregroundColor] = color }
  }

  func setLink(_ url: URL?) {
    apply { $0[.link] = url }
  }

  func clearFormatting() {
    apply { attributes in
      attributes = [.font: Self.defaultFont, .foregroundColor: NSColor.black]
    }
  }

  func showFontPanel() {
    textView?.window?.makeFirstResponder(textView)
    NSFontManager.shared.orderFrontFontPanel(nil)
  }

  func showListPanel() {
    textView?.window?.makeFirstResponder(textView)
    textView?.orderFrontListPanel(nil)
  }
}

struct RichTextEditor: NSViewRepresentable {
  let controller: RichTextController
  let initialHTML: String
  var onChange: () -> Void

  func makeCoordinator() -> Coordinator { Coordinator(controller: controller, onChange: onChange) }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSTextView.scrollableTextView()
    let textView = scrollView.documentView as! NSTextView
    textView.isRichText = true
    textView.importsGraphics = true
    textView.allowsUndo = true
    textView.usesFontPanel = true
    textView.usesRuler = true
    textView.isAutomaticLinkDetectionEnabled = true
    textView.isContinuousSpellCheckingEnabled = true
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.appearance = NSAppearance(named: .aqua)
    textView.drawsBackground = true
    textView.backgroundColor = .white
    textView.insertionPointColor = .black
    textView.textContainerInset = NSSize(width: 16, height: 14)
    textView.typingAttributes = [.font: RichTextController.defaultFont, .foregroundColor: NSColor.black]
    textView.delegate = context.coordinator
    scrollView.drawsBackground = true
    scrollView.backgroundColor = .white
    controller.textView = textView
    controller.load(html: initialHTML)
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    context.coordinator.onChange = onChange
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    let controller: RichTextController
    var onChange: () -> Void

    init(controller: RichTextController, onChange: @escaping () -> Void) {
      self.controller = controller
      self.onChange = onChange
    }

    func textDidChange(_ notification: Notification) {
      onChange()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
      MainActor.assumeIsolated { controller.updateState() }
    }
  }
}

struct FormatBar: View {
  let controller: RichTextController
  @State private var color = Color.black
  @State private var showingLink = false
  @State private var link = "https://"

  var body: some View {
    GlassEffectContainer(spacing: 6) {
      HStack(spacing: 6) {
        Menu {
          Button("Small") { controller.setSize(11) }
          Button("Normal") { controller.setSize(14) }
          Button("Large") { controller.setSize(18) }
          Button("Huge") { controller.setSize(24) }
        } label: {
          Image(systemName: "textformat.size")
        }
        .menuIndicator(.hidden)
        .help("Text size")
        formatButton("Bold", "bold", active: controller.isBold) { controller.toggle(.boldFontMask) }
        formatButton("Italic", "italic", active: controller.isItalic) { controller.toggle(.italicFontMask) }
        formatButton("Underline", "underline", active: controller.isUnderlined) { controller.toggleUnderline() }
        ColorPicker("Text colour", selection: $color, supportsOpacity: false)
          .labelsHidden()
          .onChange(of: color) { _, value in controller.setColor(NSColor(value)) }
          .help("Text colour")
        formatButton("Lists", "list.bullet", active: false) { controller.showListPanel() }
        formatButton("Insert Link", "link", active: false) { showingLink = true }
        formatButton("Fonts", "textformat", active: false) { controller.showFontPanel() }
        formatButton("Remove Formatting", "eraser", active: false) { controller.clearFormatting() }
      }
      .buttonStyle(.glass)
      .controlSize(.small)
    }
    .alert("Insert Link", isPresented: $showingLink) {
      TextField("URL", text: $link)
      Button("Insert") { controller.setLink(URL(string: link)) }
      Button("Remove Link") { controller.setLink(nil) }
      Button("Cancel", role: .cancel) {}
    }
  }

  private func formatButton(_ title: String, _ symbol: String, active: Bool, action: @escaping () -> Void) -> some View {
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
