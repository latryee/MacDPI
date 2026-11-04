import AppKit
import Combine
import Network
import SwiftUI
import WebKit

/// Optional HTTPS window using Apple's per-data-store proxy API. Other applications are unaffected.
@available(macOS 14, *)
@MainActor
final class ProxiedWebModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published var address = "https://discord.com/app"
    @Published var message = "Choose a site. This window routes HTTPS through MacDPI; native games and voice UDP are not covered."
    let webView: WKWebView
    init(port: UInt16) {
        let configuration = WKWebViewConfiguration()
        let store = WKWebsiteDataStore.nonPersistent()
        var proxy = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!))
        proxy.allowFailover = false
        store.proxyConfigurations = [proxy]
        configuration.websiteDataStore = store
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self; webView.uiDelegate = self
    }
    func load(_ value: String? = nil) {
        let text = (value ?? address).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text.contains("://") ? text : "https://" + text), permitted(url) else {
            message = "Enter an HTTPS URL on port 443. Other protocols and native app links require separate integration."; return
        }
        address = url.absoluteString; message = "Connecting through MacDPI…"
        webView.load(URLRequest(url: url))
    }
    private func permitted(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host != nil && (url.port == nil || url.port == 443)
            && url.user == nil && url.password == nil
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, permitted(url) || url.absoluteString == "about:blank" else {
            if navigationAction.targetFrame?.isMainFrame != false {
                message = "This window supports HTTPS. Native game launchers require separate integration."
            }
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, permitted(url) { webView.load(navigationAction.request) }
        return nil
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let url = webView.url { address = url.absoluteString }
        message = "Page loaded in the proxied window. This does not verify native apps, games or voice."
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        message = "Connection failed. Check that the proxy is enabled and try Cloudflare DNS over HTTPS in Settings."
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        message = "Page connection failed. The site may need a different strategy or unsupported traffic."
    }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }
}

@available(macOS 14, *)
private struct ProxiedWebView: NSViewRepresentable {
    let model: ProxiedWebModel
    func makeNSView(context: Context) -> WKWebView { model.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
    static func dismantleNSView(_ nsView: WKWebView, coordinator: ()) { nsView.stopLoading(); nsView.loadHTMLString("", baseURL: nil) }
}

@available(macOS 14, *)
struct ProxiedBrowser: View {
    @StateObject private var model: ProxiedWebModel
    init(port: UInt16) { _model = StateObject(wrappedValue: ProxiedWebModel(port: port)) }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("HTTPS address", text: $model.address).onSubmit { model.load() }.accessibilityIdentifier("web-address")
                Button("Go") { model.load() }.accessibilityIdentifier("web-go")
                Button("Discord") { model.load("https://discord.com/app") }
                Button("Roblox") { model.load("https://www.roblox.com/") }
            }.padding(12)
            Text("Session-only website data · HTTPS proxy · Microphone/camera disabled · Other Mac apps are unaffected")
                .font(.caption).foregroundStyle(.secondary).padding(.bottom, 8)
            Divider()
            ProxiedWebView(model: model)
            Divider()
            Text(model.message).font(.caption).padding(10).frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("web-status")
        }.frame(minWidth: 760, minHeight: 480)
    }
}
