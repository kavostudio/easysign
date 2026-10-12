import AppKit
import SwiftUI
import WebKit

@main @MainActor
struct PreviewCheck {
    static func main() async {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let html = "<html><head><style>@media(max-width:400px){body{color:red}}</style></head><body><b id='test'>Žofia ✓</b><script>document.body.innerHTML='BAD';</script><iframe src='https://example.invalid'></iframe><a href='https://example.com'>link</a></body></html>"
        let host = NSHostingView(rootView: HTMLPreview(html: html, remoteContent: false, dark: false))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        func findWeb(_ view: NSView) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            return view.subviews.lazy.compactMap { findWeb($0) }.first
        }
        do {
            try await Task.sleep(for: .seconds(3))
            guard let web = findWeb(host) else { fatalError("No preview web view") }
            let text = try await web.evaluateJavaScript("document.getElementById('test')?.textContent")
            guard let string = text as? String, string == "Žofia ✓" else { fatalError("Preview missing or script executed") }
            guard !web.configuration.websiteDataStore.isPersistent else { fatalError("Persistent web storage") }
            guard !web.configuration.defaultWebpagePreferences.allowsContentJavaScript else { fatalError("JavaScript enabled") }
            let policy = try await web.evaluateJavaScript("document.querySelector('meta[http-equiv]').content")
            guard let policy = policy as? String, policy.contains("img-src data:"), policy.contains("font-src data:"), policy.contains("frame-src 'none'") else { fatalError("Missing preview restrictions") }
            print("PREVIEW_PASS unicode=visible javascript=disabled storage=nonpersistent remoteContent=blocked frames=blocked")
        } catch { fatalError("Preview check failed: \(error.localizedDescription)") }
        window.orderOut(nil)
    }
}
