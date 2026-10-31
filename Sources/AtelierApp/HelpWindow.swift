import AppKit
import WebKit

/// Lightfast Help: the HTML pages in Sources/AtelierApp/Help, shown in their own window
/// (Help > Lightfast Help, ⌘?). The same files open in any browser; they're written by hand and
/// indexed by Scripts/help/build_help_index.py.
@MainActor
final class HelpWindow: NSObject, WKNavigationDelegate {
    static let shared = HelpWindow()

    private var window: NSWindow?
    private var webView: WKWebView?

    /// The Help folder in the app's resources.
    static var folder: URL? {
        let hostApp = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let candidates = [
            AtelierResources.bundle.url(forResource: "Help", withExtension: nil),
            AtelierResources.bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("Atelier_AtelierApp.bundle/Help"),
            hostApp.appendingPathComponent("Contents/Resources/Atelier_AtelierApp.bundle/Help")
        ].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The help page and section for a Develop panel or tool, by the title its header shows.
    static func topic(forPanel title: String) -> (page: String, section: String?)? {
        switch title {
        case "Tone Mapping", "Artifacts": return ("hdr", "controls")
        case "Histogram": return ("develop", "histogram")
        case "Basic": return ("basic", nil)
        case "Tone Curve": return ("tone-curve", nil)
        case "HSL / Color": return ("hsl", nil)
        case "Color Grading": return ("color-grading", nil)
        case "Detail": return ("detail", nil)
        case "Lens Corrections": return ("lens-corrections", nil)
        case "Transform": return ("transform", nil)
        case "Effects": return ("effects", nil)
        case "Crop & Straighten": return ("crop", nil)
        case "Masking": return ("masking", nil)
        case "AI": return ("ai", nil)
        default: return nil
        }
    }

    /// Opens Help on a page ("basic") and section ("exposure"), or on the welcome page.
    func show(page: String = "index", section: String? = nil) {
        guard let folder = Self.folder else {
            NSSound.beep()
            return
        }
        var url = folder.appendingPathComponent(page + ".html")
        if let section, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.fragment = section
            url = components.url ?? url
        }
        let webView = self.webView ?? makeWindow()
        webView.loadFileURL(url, allowingReadAccessTo: folder)
        window?.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> WKWebView {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1100, height: 760))
        webView.navigationDelegate = self
        webView.allowsMagnification = true
        let window = NSWindow(contentRect: webView.frame,
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Lightfast Help"
        window.isReleasedWhenClosed = false
        window.minSize = CGSize(width: 560, height: 400)
        window.contentView = webView
        window.center()
        window.setFrameAutosaveName("AtelierHelp")
        self.window = window
        self.webView = webView
        return webView
    }

    /// Help pages open inside the window; links to the web open in the browser.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url, !url.isFileURL else { return .allow }
        if navigationAction.navigationType == .linkActivated {
            NSWorkspace.shared.open(url)
            return .cancel
        }
        return .allow
    }
}
