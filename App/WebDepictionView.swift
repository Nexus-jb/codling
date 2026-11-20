// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import WebKit

enum WebLoadState: Equatable {
    case loading
    case loaded
    case failed(String)
}

/// A web depiction, as tall as its content so that it scrolls with the rest
/// of the package page. It keeps no cookies or storage between pages, and a
/// tapped link opens outside it.
struct WebDepictionView: UIViewRepresentable {
    let url: URL
    @Binding var height: CGFloat
    @Binding var state: WebLoadState
    /// Changing it loads the page again.
    let reload: Int
    let onLink: (URL) -> Void

    /// The tallest a page is shown, against pages that keep growing.
    static let heightLimit: CGFloat = 40_000

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: Self.configuration())
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsLinkPreview = false
        context.coordinator.observe(webView)
        context.coordinator.load(webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.loadedReload != reload {
            context.coordinator.load(webView)
        }
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        coordinator.observation = nil
    }

    static func configuration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.applicationNameForUserAgent = "Codling"
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        return configuration
    }

    static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        return request
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: WebDepictionView
        var observation: NSKeyValueObservation?
        var loadedReload: Int

        init(_ parent: WebDepictionView) {
            self.parent = parent
            loadedReload = parent.reload
        }

        func load(_ webView: WKWebView) {
            loadedReload = parent.reload
            setState(.loading)
            webView.load(WebDepictionView.request(parent.url))
        }

        func observe(_ webView: WKWebView) {
            observation = webView.scrollView.observe(\.contentSize, options: [.new]) { [weak self] scrollView, _ in
                let height = min(scrollView.contentSize.height, WebDepictionView.heightLimit)
                DispatchQueue.main.async {
                    guard let self, abs(self.parent.height - height) > 1 else { return }
                    self.parent.height = height
                }
            }
        }

        private func setState(_ state: WebLoadState) {
            DispatchQueue.main.async {
                if self.parent.state != state {
                    self.parent.state = state
                }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else {
                decisionHandler(.cancel)
                return
            }
            let mainFrame = action.targetFrame?.isMainFrame ?? true
            if action.navigationType == .linkActivated && mainFrame {
                decisionHandler(.cancel)
                parent.onLink(url)
                return
            }
            let scheme = url.scheme?.lowercased() ?? ""
            guard ["http", "https", "about", "data", "blob"].contains(scheme) else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if response.isForMainFrame, let http = response.response as? HTTPURLResponse, http.statusCode >= 400 {
                decisionHandler(.cancel)
                setState(.failed("The description page could not be loaded: the server answered \(http.statusCode) (\(HTTPURLResponse.localizedString(forStatusCode: http.statusCode)))."))
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            setState(.loaded)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            failed(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            failed(error)
        }

        private func failed(_ error: Error) {
            let nsError = error as NSError
            // Cancelled loads, and loads Codling stopped itself.
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
                || nsError.domain == "WebKitErrorDomain" && nsError.code == 102 {
                return
            }
            setState(.failed("The description page could not be loaded. \(RefreshError.describe(error))"))
        }

        /// Links that open a new window open outside the page.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url {
                parent.onLink(url)
            }
            return nil
        }
    }
}

/// An embedded YouTube or Vimeo player from a native depiction.
struct EmbedWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WebDepictionView.configuration())
        webView.scrollView.isScrollEnabled = false
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.navigationDelegate = context.coordinator
        webView.load(WebDepictionView.request(url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let url: URL

        init(url: URL) {
            self.url = url
        }

        /// The player stays on its own page.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let allowed = action.navigationType != .linkActivated
                && (action.request.url.map(DepictionMedia.isEmbeddable) ?? false || action.targetFrame?.isMainFrame == false)
            decisionHandler(allowed ? .allow : .cancel)
        }
    }
}
