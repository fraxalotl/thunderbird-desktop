/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import AppKit
import SwiftUI
import WebKit

/// The composer's HTML editing surface.
struct HTMLEditorView: NSViewRepresentable {
  let controller: ComposerController

  func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    let content = WKUserContentController()
    content.add(context.coordinator, name: "tb")
    content.addUserScript(WKUserScript(source: EditorScript.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    configuration.userContentController = content
    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = context.coordinator
    webView.allowsMagnification = true
    webView.appearance = NSAppearance(named: .aqua)
    controller.webView = webView
    webView.loadHTMLString(EditorScript.page, baseURL: nil)
    return webView
  }

  func updateNSView(_ webView: WKWebView, context: Context) {}

  static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
    webView.configuration.userContentController.removeScriptMessageHandler(forName: "tb")
  }

  final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let controller: ComposerController

    init(controller: ComposerController) {
      self.controller = controller
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
      guard let body = message.body as? [String: Any] else { return }
      MainActor.assumeIsolated {
        if body["type"] as? String == "ready" {
          controller.editorDidLoad()
        } else {
          controller.receive(body)
        }
      }
    }

    func webView(
      _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
      decisionHandler(navigationAction.navigationType == .linkActivated ? .cancel : .allow)
    }
  }
}
