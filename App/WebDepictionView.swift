// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import WebKit

enum WebLoadState: Equatable {
    case loading
    case loaded
    case failed(String)
}

/// A web depiction, shown in the package page's Full Description tab and as
/// tall as its content, so that it scrolls with the rest of the page. A
/// tapped link opens outside it, and it keeps no cookies or site data once
/// the page closes.
struct WebDepictionView: UIViewRepresentable {
    let url: URL
    @Binding var height: CGFloat
    @Binding var state: WebLoadState
    /// Changing it loads the page again.
    let reload: Int
    let onLink: (URL) -> Void

    /// The tallest a page is shown, against pages that keep growing.
    static let heightLimit: CGFloat = 40_000
    /// How long a page may take to start showing.
    static let timeout: TimeInterval = 20

    /// Pages load in a private session that keeps nothing. Where that
    /// session cannot run (its page process stops before drawing anything),
    /// they load in the app's own session instead, which Codling empties
    /// whenever a page closes. The choice holds until Codling quits.
    static var privateSessionFails = false

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    /// A plain view that holds the web view, so that the web view can be
    /// replaced when it has to load in the other session.
    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .clear
        container.clipsToBounds = true
        context.coordinator.container = container
        context.coordinator.load()
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.loadedReload != reload {
            context.coordinator.load()
        }
    }

    static func dismantleUIView(_ container: UIView, coordinator: Coordinator) {
        coordinator.tearDown()
        if privateSessionFails {
            WebDepictionView.emptyAppSession()
        }
    }

    static func configuration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = privateSessionFails ? .default() : .nonPersistent()
        configuration.applicationNameForUserAgent = "Codling"
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        return configuration
    }

    /// Removes every cookie and all site data of the app's own session.
    static func emptyAppSession() {
        let store = WKWebsiteDataStore.default()
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
    }

    static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        return request
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: WebDepictionView
        weak var container: UIView?
        private var webView: WKWebView?
        var observation: NSKeyValueObservation?
        var loadedReload: Int
        var deadline: DispatchWorkItem?
        /// The page has started to show: later failures of its parts leave
        /// it in place.
        private var committed = false
        /// How far the load got, to say where a page that never shows stopped.
        private var started = false
        private var answer: Int?

        init(_ parent: WebDepictionView) {
            self.parent = parent
            loadedReload = parent.reload
        }

        /// Loads the page in a new web view.
        func load() {
            tearDown()
            guard let container else { return }
            let webView = WKWebView(frame: container.bounds, configuration: WebDepictionView.configuration())
            webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            webView.scrollView.isScrollEnabled = false
            webView.scrollView.contentInsetAdjustmentBehavior = .never
            webView.navigationDelegate = self
            webView.uiDelegate = self
            webView.allowsLinkPreview = false
            container.addSubview(webView)
            self.webView = webView
            observe(webView)

            loadedReload = parent.reload
            committed = false
            started = false
            answer = nil
            setState(.loading)
            webView.load(WebDepictionView.request(parent.url))
            let deadline = DispatchWorkItem { [weak self, weak webView] in
                guard let self, !self.committed else { return }
                webView?.stopLoading()
                self.setState(.failed("The description page did not answer in time: \(self.stage)."))
            }
            self.deadline = deadline
            DispatchQueue.main.asyncAfter(deadline: .now() + WebDepictionView.timeout, execute: deadline)
        }

        func tearDown() {
            deadline?.cancel()
            deadline = nil
            observation = nil
            webView?.stopLoading()
            webView?.navigationDelegate = nil
            webView?.uiDelegate = nil
            webView?.removeFromSuperview()
            webView = nil
        }

        /// Where a load that never showed stopped.
        private var stage: String {
            if let answer {
                return "the server answered (\(answer)), but the page did not start to draw"
            }
            return started ? "the server did not answer" : "the web view did not start loading it"
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

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            started = true
        }

        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if response.isForMainFrame {
                answer = (response.response as? HTTPURLResponse)?.statusCode ?? 0
            }
            if response.isForMainFrame, let http = response.response as? HTTPURLResponse, http.statusCode >= 400 {
                decisionHandler(.cancel)
                deadline?.cancel()
                setState(.failed("The description page could not be loaded: the server answered \(http.statusCode) (\(HTTPURLResponse.localizedString(forStatusCode: http.statusCode)))."))
                return
            }
            decisionHandler(.allow)
        }

        /// The page shows as soon as it starts to draw, rather than once every
        /// image and script on it has loaded.
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            committed = true
            deadline?.cancel()
            setState(.loaded)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            committed = true
            deadline?.cancel()
            setState(.loaded)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            failed(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            failed(error)
        }

        private func failed(_ error: Error) {
            guard !committed else { return }
            let nsError = error as NSError
            // Cancelled loads, and loads Codling stopped itself.
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
                || nsError.domain == "WebKitErrorDomain" && nsError.code == 102 {
                return
            }
            deadline?.cancel()
            setState(.failed("The description page could not be loaded. \(RefreshError.describe(error))"))
        }

        /// The process that draws the page stopped. Before anything was
        /// drawn in the private session, the page loads again in the app's
        /// own session; otherwise the page has failed.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            deadline?.cancel()
            if !committed && !WebDepictionView.privateSessionFails {
                WebDepictionView.privateSessionFails = true
                DispatchQueue.main.async { self.load() }
                return
            }
            committed = false
            setState(.failed("The description page stopped unexpectedly."))
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

/// A web page inside Codling, as a page of its own: links tapped in a
/// depiction, such as a changelog, open here rather than in a browser.
/// Links on it open further pages.
struct WebPageView: View {
    let url: URL
    @State private var height: CGFloat = 1
    @State private var state: WebLoadState = .loading
    @State private var reload = 0
    @StateObject private var router = DepictionRouter()

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                switch state {
                case .failed(let message):
                    Card(padding: 14) {
                        ToolHeader(symbol: "exclamationmark.triangle", color: .orange, title: "The page did not load") {
                            ToolNote(text: message)
                        }
                        HStack(spacing: 8) {
                            Button("Try Again") {
                                state = .loading
                                reload += 1
                            }
                            .buttonStyle(TintedButtonStyle())
                            Button {
                                router.browser(url)
                            } label: {
                                Label("Open in Browser", systemImage: "safari")
                            }
                            .buttonStyle(TintedButtonStyle())
                        }
                        .padding(.top, 12)
                    }
                    .padding(16)
                default:
                    ZStack(alignment: .top) {
                        WebDepictionView(url: url, height: $height, state: $state, reload: reload) { link in
                            router.open(link, base: url)
                        }
                        .frame(height: max(height, 1))
                        .opacity(state == .loaded ? 1 : 0)
                        if state == .loading {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding(32)
                        }
                    }
                }
            }
        }
        .background(WallBackground())
        .navigationTitle(url.host ?? "Page")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    router.browser(url)
                } label: {
                    Label("Open in Browser", systemImage: "safari")
                }
            }
        }
        .depictionRouting(router, base: url)
    }
}
