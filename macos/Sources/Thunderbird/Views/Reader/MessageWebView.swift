/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import AppKit
import SwiftUI
import WebKit

struct MessageWebView: NSViewRepresentable {
  let rendered: MessageHTML.Rendered
  var onMailto: (URL) -> Void
  @Environment(ReaderController.self) private var reader

  func makeCoordinator() -> Coordinator {
    Coordinator(onMailto: onMailto)
  }

  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = false
    configuration.websiteDataStore = .nonPersistent()
    configuration.suppressesIncrementalRendering = true
    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = context.coordinator
    webView.allowsMagnification = true
    webView.setValue(false, forKey: "drawsBackground")
    reader.webView = webView
    return webView
  }

  func updateNSView(_ webView: WKWebView, context: Context) {
    context.coordinator.onMailto = onMailto
    guard context.coordinator.loaded != rendered else { return }
    context.coordinator.loaded = rendered
    webView.underPageBackgroundColor = rendered.isPlainText ? .clear : .white
    webView.loadHTMLString(rendered.html, baseURL: nil)
  }

  final class Coordinator: NSObject, WKNavigationDelegate {
    var loaded: MessageHTML.Rendered?
    var onMailto: (URL) -> Void

    init(onMailto: @escaping (URL) -> Void) {
      self.onMailto = onMailto
    }

    func webView(
      _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
      guard let url = navigationAction.request.url else {
        decisionHandler(.cancel)
        return
      }
      if url.scheme == "about" || url.scheme == "data" {
        decisionHandler(navigationAction.navigationType == .linkActivated ? .cancel : .allow)
        return
      }
      decisionHandler(.cancel)
      guard navigationAction.navigationType == .linkActivated else { return }
      if url.scheme?.lowercased() == "mailto" {
        onMailto(url)
      } else if ["http", "https"].contains(url.scheme?.lowercased()) {
        NSWorkspace.shared.open(url)
      }
    }
  }
}
