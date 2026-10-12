import SwiftUI
import WebKit

struct HTMLPreview: NSViewRepresentable {
    let html: String
    let remoteContent: Bool
    let dark: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.underPageBackgroundColor = .clear
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        let sources = remoteContent ? "https: http: data:" : "data:"
        // This policy is added only to the preview. The user's installed source is never rewritten.
        // A second CSP supplied by imported HTML can restrict this policy, but cannot relax it.
        let prefix = """
        <!doctype html><head><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; img-src \(sources); font-src \(sources); style-src 'unsafe-inline' \(remoteContent ? "https: http:" : ""); connect-src 'none'; frame-src 'none'; object-src 'none'; media-src 'none'; base-uri 'none'; form-action 'none'"><meta name="viewport" content="width=device-width, initial-scale=1"><style>:root { color-scheme: light; } html { background: \(dark ? "#202124" : "#ffffff"); } body { color: \(dark ? "#eeeeee" : "#202124"); }</style></head>
        """
        let rendered = prefix + html
        guard context.coordinator.lastHTML != rendered else { return }
        context.coordinator.lastHTML = rendered
        context.coordinator.pending?.cancel()
        let coordinator = context.coordinator
        context.coordinator.pending = Task { @MainActor [weak view, weak coordinator] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            view?.stopLoading()
            coordinator?.allowInitialLoad = true
            view?.loadHTMLString(rendered, baseURL: nil)
        }
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.pending?.cancel()
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var lastHTML = ""
        var allowInitialLoad = false
        var pending: Task<Void, Never>?
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url,
               ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
            }
            // Only the initial in-memory document is allowed. Redirects, forms, frames and all links are cancelled.
            let initial = allowInitialLoad && action.navigationType == .other && action.request.url?.absoluteString == "about:blank" && action.targetFrame?.isMainFrame == true
            if initial { allowInitialLoad = false }
            decisionHandler(initial ? .allow : .cancel)
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    }
}
