import AppKit
import Markdown
import WebKit

// swift-markdown 0.8's HTMLFormatter emits unescaped text/attributes. Render its
// parsed tree with a closed set of tags instead; no source value becomes markup.
private struct PreviewHTML: MarkupVisitor {
    typealias Result = String

    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    mutating func defaultVisit(_ markup: Markup) -> String {
        markup.children.map { visit($0) }.joined()
    }

    mutating func tag(_ name: String, _ markup: Markup) -> String {
        "<\(name)>\(defaultVisit(markup))</\(name)>"
    }

    mutating func visitText(_ text: Markdown.Text) -> String { Self.escape(text.string) }
    mutating func visitParagraph(_ paragraph: Paragraph) -> String { tag("p", paragraph) }
    mutating func visitHeading(_ heading: Heading) -> String { tag("h\(heading.level)", heading) }
    mutating func visitStrong(_ strong: Strong) -> String { tag("strong", strong) }
    mutating func visitEmphasis(_ emphasis: Emphasis) -> String { tag("em", emphasis) }
    mutating func visitStrikethrough(_ text: Strikethrough) -> String { tag("del", text) }
    mutating func visitBlockQuote(_ quote: BlockQuote) -> String { tag("blockquote", quote) }
    mutating func visitUnorderedList(_ list: UnorderedList) -> String { tag("ul", list) }
    mutating func visitOrderedList(_ list: OrderedList) -> String {
        "<ol start=\"\(list.startIndex)\">\(defaultVisit(list))</ol>"
    }
    mutating func visitListItem(_ item: ListItem) -> String {
        let check = item.checkbox.map { $0 == .checked ? "☑ " : "☐ " } ?? ""
        return "<li>\(check)\(defaultVisit(item))</li>"
    }
    mutating func visitInlineCode(_ code: InlineCode) -> String { "<code>\(Self.escape(code.code))</code>" }
    mutating func visitCodeBlock(_ code: CodeBlock) -> String { "<pre><code>\(Self.escape(code.code))</code></pre>" }
    mutating func visitHTMLBlock(_ html: HTMLBlock) -> String { "<pre>\(Self.escape(html.rawHTML))</pre>" }
    mutating func visitInlineHTML(_ html: InlineHTML) -> String { Self.escape(html.rawHTML) }
    mutating func visitLineBreak(_ line: LineBreak) -> String { "<br>" }
    mutating func visitSoftBreak(_ line: SoftBreak) -> String { "\n" }
    mutating func visitThematicBreak(_ line: ThematicBreak) -> String { "<hr>" }
    mutating func visitLink(_ link: Markdown.Link) -> String { tag("span", link) }
    mutating func visitImage(_ image: Markdown.Image) -> String {
        "<span class=\"image\">[Image: \(defaultVisit(image))]</span>"
    }
    mutating func visitTable(_ table: Markdown.Table) -> String { tag("table", table) }
    mutating func visitTableHead(_ head: Markdown.Table.Head) -> String { "<thead>\(tag("tr", head))</thead>" }
    mutating func visitTableBody(_ body: Markdown.Table.Body) -> String { tag("tbody", body) }
    mutating func visitTableRow(_ row: Markdown.Table.Row) -> String { tag("tr", row) }
    mutating func visitTableCell(_ cell: Markdown.Table.Cell) -> String { tag("td", cell) }

    static func page(_ markdown: String) -> String {
        var renderer = PreviewHTML()
        let body = renderer.visit(Document(parsing: markdown))
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src 'none'; media-src 'none'; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
        <meta name="color-scheme" content="light dark">
        <style>
        :root { color-scheme: light dark; }
        body { font: 14px -apple-system, sans-serif; line-height: 1.55; margin: 24px; overflow-wrap: anywhere; color: CanvasText; background: Canvas; }
        pre, code { font-family: ui-monospace, monospace; font-size: 12px; }
        pre { overflow: auto; padding: 12px; background: light-dark(#f4f4f5, #242426); border-radius: 6px; }
        blockquote { margin-left: 0; padding-left: 16px; border-left: 3px solid GrayText; }
        table { border-collapse: collapse; display: block; overflow: auto; }
        td { border: 1px solid GrayText; padding: 6px 10px; } thead { font-weight: bold; }
        .image { color: GrayText; } hr { border: 0; border-top: 1px solid GrayText; }
        </style></head><body>\(body)</body></html>
        """
    }
}

@MainActor
final class MarkdownPreviewController: NSWindowController, NSWindowDelegate, WKNavigationDelegate {
    private var rendering: Task<Void, Never>?
    private var webViews: [WKWebView] = []
    private var indicators: [NSProgressIndicator] = []
    private var statuses: [NSTextField] = []

    init(path: String, old: String, new: String) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "\(path) — Markdown Preview"
        window.minSize = NSSize(width: 700, height: 400)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        let columns = Style.stack([pane("Original"), pane("Changed")], spacing: 1)
        columns.distribution = .fillEqually
        columns.alignment = .top
        Style.pin(columns, in: window.contentView!)
        for column in columns.arrangedSubviews {
            column.heightAnchor.constraint(equalTo: columns.heightAnchor).isActive = true
        }
        rendering = Task { [weak self] in
            let pages = await Task.detached(priority: .userInitiated) {
                [PreviewHTML.page(old), PreviewHTML.page(new)]
            }.value
            guard !Task.isCancelled, let self else { return }
            for (webView, page) in zip(self.webViews, pages) {
                webView.loadHTMLString(page, baseURL: nil)
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func pane(_ title: String) -> NSView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.allowsLinkPreview = false
        webViews.append(webView)
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        indicators.append(spinner)
        let status = Style.label("Rendering…", size: 11, color: .secondaryLabelColor)
        statuses.append(status)
        let header = Style.stack([Style.label(title, weight: .semibold), Style.spacer(), status, spinner])
        let pane = NSView()
        for view in [header, webView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            pane.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -16),
            header.topAnchor.constraint(equalTo: pane.topAnchor, constant: 12),
            webView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            webView.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: pane.bottomAnchor)
        ])
        return pane
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Only the internally supplied document may navigate; even file: and data: links are blocked.
        decisionHandler(navigationAction.navigationType == .other &&
                        navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(webView, error: nil) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(webView, error: error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(webView, error: error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(webView, error: NSError(domain: "MarkdownPreview", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: "Preview stopped. Close and reopen this preview."]))
    }
    private func finish(_ webView: WKWebView, error: Error?) {
        guard let index = webViews.firstIndex(of: webView) else { return }
        indicators[index].stopAnimation(nil)
        indicators[index].isHidden = true
        statuses[index].stringValue = error?.localizedDescription ?? ""
        statuses[index].toolTip = error?.localizedDescription
    }
    func windowWillClose(_ notification: Notification) {
        rendering?.cancel()
        webViews.forEach { $0.stopLoading() }
    }
}
