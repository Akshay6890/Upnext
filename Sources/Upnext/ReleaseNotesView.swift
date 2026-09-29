import AppKit
import SwiftUI
import UpnextCore
import WebKit

struct ReleaseNotesView: View {
    let row: AppModel.Row
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                AppIcon(url: row.app.url).frame(width: 28, height: 28)
                VStack(alignment: .leading) {
                    Text("\(row.app.name) \(row.update?.newVersion ?? "")").font(.headline)
                    Text("You have \(row.app.displayVersion)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let url = row.update?.releaseNotesURL {
                    Button("Open in Browser") { NSWorkspace.shared.open(url) }
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            if let html = row.update?.releaseNotesHTML {
                WebView(content: .html(html))
            } else if let url = row.update?.releaseNotesURL {
                WebView(content: .url(url))
            } else {
                Text("No release notes were published for this version.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 420, idealHeight: 540)
    }
}

private struct WebView: NSViewRepresentable {
    enum Content {
        case html(String)
        case url(URL)
    }

    let content: Content

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Release notes are documents; they don't need scripts.
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        switch content {
        case let .html(html):
            view.loadHTMLString(Self.wrap(html), baseURL: nil)
        case let .url(url):
            view.load(URLRequest(url: url))
        }
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        // Links clicked inside the notes open in the user's browser.
        func webView(_ webView: WKWebView,
                     decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            if action.navigationType == .linkActivated, let url = action.request.url {
                NSWorkspace.shared.open(url)
                return .cancel
            }
            return .allow
        }
    }

    private static func wrap(_ body: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <style>
          :root { color-scheme: light dark; }
          body { font: 13px -apple-system, sans-serif; line-height: 1.5; margin: 16px 20px; }
          h1, h2, h3 { font-size: 1.1em; }
          a { color: -apple-system-control-accent; }
          img { max-width: 100%; }
        </style></head><body>\(body)</body></html>
        """
    }
}
