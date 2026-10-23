//
//  MarkdownRenderer.swift
//  SyntaxHighlightRenderXPC
//
//  Renders Markdown files as formatted (GitHub-like) HTML instead of highlighted source.
//  The cmark-gfm pipeline is ported from QLMarkdown (sbarex) `Settings+render.swift`;
//  fenced code blocks are colorized by SH's own `highlight` engine with the current SH themes.
//
//  This file is compiled only in the targets that define the `SCSH_MARKDOWN` Swift
//  compilation condition (the "Syntax Highlight XPC Render" service and `syntax_highlight_cli`),
//  because they are the ones that also compile the vendored cmark-gfm / cmark-extra C sources.
//
//  Fixed defaults (there is no settings UI for Markdown yet):
//  - Output is always HTML, whatever output format (RTF/HTML) the user chose for source code.
//  - cmark-gfm options: footnotes ON, UTF-8 validation ON, smart quotes OFF,
//    unsafe raw HTML OFF (raw HTML is omitted), hard line breaks OFF.
//  - GFM extensions: table, autolink, tagfilter, tasklist, strikethrough (single and double tilde).
//  - Extra extensions (from QLMarkdown's cmark-extra):
//      heads (GitHub style anchors on headings), emoji (`:smile:` as Unicode glyphs, no network),
//      inlineimage (local images embedded as base64 `data:` URIs, confined to the document folder;
//      remote images are left as links), alert (GitHub `> [!NOTE]` blocks).
//  - YAML front matter (a leading `---` block) is shown as a `yaml` code block.
//  - Fenced code blocks: highlighted with SH's `highlight` using the SH light theme and SH dark
//    theme (switched with `prefers-color-scheme`, or forced when the appearance is forced),
//    honouring the user's font family / size and tab-to-spaces settings. Line numbers and word
//    wrap are not applied to code blocks (they scroll horizontally like on GitHub).
//  - Not enabled: math, mermaid (both need JavaScript from a CDN), mention, wikilink, hashtag,
//    sub/sup, ==highlight==, admonition, definition lists, table of contents. No JavaScript at all.
//  - Page style: QLMarkdown's GitHub-like `markdown.css` (light/dark via prefers-color-scheme).

#if SCSH_MARKDOWN

import Foundation
import OSLog
import UniformTypeIdentifiers

enum MarkdownError: Error, LocalizedError {
    case failure(String)
    var errorDescription: String? {
        switch self {
        case .failure(let message): return "Syntax Highlight: \(message)."
        }
    }
}

enum MarkdownRenderer {
    /// File extensions handled as Markdown.
    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "mdwn", "mdtxt", "mdtext", "rmd", "qmd"]
    /// UTIs handled as Markdown (the file UTI must conform to one of them).
    static let markdownUTIs: [String] = [
        "net.daringfireball.markdown", "public.markdown", "com.unknown.md", "io.typora.markdown",
        "net.ia.markdown", "com.rstudio.rmarkdown", "org.quarto.qmarkdown", "com.nutstore.down",
    ]
    /// Fence languages rendered as plain text, without invoking highlight.
    static let plainLanguages: Set<String> = ["", "text", "txt", "plain", "plaintext", "nohighlight", "none"]

    /// cmark-gfm extensions are global objects and inlineimage changes the process current directory: serialize the renderings.
    private static let lock = NSLock()

    static func isMarkdown(url: URL) -> Bool {
        if markdownExtensions.contains(url.pathExtension.lowercased()) {
            return true
        }
        if let uti = (try? url.resourceValues(forKeys: [.typeIdentifierKey]))?.typeIdentifier, let type = UTType(uti) {
            for m in markdownUTIs {
                if let t = UTType(m), type.conforms(to: t) {
                    return true
                }
            }
        }
        return false
    }

    /// Render a Markdown file.
    /// - parameters:
    ///   - url: Markdown file.
    ///   - settings: Global settings.
    ///   - highlightBin: Path of the highlight executable.
    ///   - dataDir: highlight data dir.
    ///   - rsrcEsc: Resources folder that contains `highlight/markdown.css`.
    ///   - overridingSettings: Settings overridden by the caller (eg. the CLI).
    ///   - logFile: Log file.
    static func render(url: URL, settings: Settings, highlightBin: String, dataDir: String?, rsrcEsc: String, overridingSettings: [String: AnyHashable]?, logFile: URL?, logOs: OSLog?) throws -> (data: Data, settings: SettingsRendering) {
        try? "Rendering \(url.path) as Markdown…".appendLine(to: logFile)

        let uti = settings.searchUTI(for: url)
        let utiSettings = uti != nil ? settings.utiSettings[uti!] : nil
        let custom_settings = SettingsRendering(globalSettings: settings, format: utiSettings)
        custom_settings.logFile = logFile
        if let overridingSettings = overridingSettings, !overridingSettings.isEmpty {
            custom_settings.override(fromDictionary: overridingSettings)
        }
        // Markdown is always rendered as HTML so the Quick Look extension shows it in the web view.
        custom_settings.format = .html
        custom_settings.isRenderingSupported = true

        let text = try readText(url: url)
        lock.lock()
        defer {
            lock.unlock()
        }
        let body = try autoreleasepool {
            try renderBody(text: text, baseDir: url.deletingLastPathComponent().path, settings: custom_settings, highlightBin: highlightBin, dataDir: dataDir, logFile: logFile)
        }
        let css = pageCSS(settings: custom_settings, highlightBin: highlightBin, dataDir: dataDir, rsrcEsc: rsrcEsc, logFile: logFile)
        let html = completeHTML(title: url.lastPathComponent, body: body, css: css)

        if custom_settings.isDebug {
            let u = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Desktop/colorize.html")
            try? html.data(using: .utf8)?.write(to: u)
        }
        try? "Markdown rendered (\(html.utf8.count) bytes).".appendLine(to: logFile)

        return (data: html.data(using: .utf8) ?? Data(), settings: custom_settings)
    }

    // MARK: - Private

    private static func readText(url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if let s = String(data: data, encoding: .utf8) {
            return s
        }
        var enc: String.Encoding = .utf8
        if let s = try? String(contentsOf: url, usedEncoding: &enc) {
            return s
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Show a leading YAML front matter as a code block instead of a thematic break + setext heading.
    private static func preprocessFrontMatter(_ text: String) -> String {
        guard text.hasPrefix("---\n") || text.hasPrefix("---\r\n") else {
            return text
        }
        let pattern = "(?s)\\A---\\r?\\n(.*?)\\r?\\n(?:---|\\.\\.\\.)[ \\t]*(?:\\r?\\n|\\z)"
        guard let regex = try? NSRegularExpression(pattern: pattern), let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let all = Range(m.range, in: text), let yamlRange = Range(m.range(at: 1), in: text) else {
            return text
        }
        let yaml = String(text[yamlRange])
        let fence = yaml.contains("```") ? "~~~~" : "```"
        return "\(fence)yaml\n\(yaml)\n\(fence)\n\n" + text[all.upperBound...]
    }

    private static func renderBody(text: String, baseDir: String, settings: SettingsRendering, highlightBin: String, dataDir: String?, logFile: URL?) throws -> String {
        scsh_markdown_extensions_ensure_registered()

        let options = CMARK_OPT_DEFAULT | CMARK_OPT_FOOTNOTES | CMARK_OPT_VALIDATE_UTF8

        guard let parser = cmark_parser_new(options) else {
            throw MarkdownError.failure( "unable to create the Markdown parser")
        }
        defer {
            cmark_parser_free(parser)
        }

        for name in ["table", "autolink", "tagfilter", "tasklist", "strikethrough", "alert"] {
            if let ext = cmark_find_syntax_extension(name) {
                cmark_parser_attach_syntax_extension(parser, ext)
            } else {
                try? "WARNING: markdown extension `\(name)` not available.".appendLine(to: logFile)
            }
        }
        if let ext = cmark_find_syntax_extension("heads") {
            heads_reset_slut_counter(ext)
            cmark_parser_attach_syntax_extension(parser, ext)
        }
        if let ext = cmark_find_syntax_extension("emoji") {
            cmark_syntax_extension_emoji_set_use_characters(ext, true)
            cmark_parser_attach_syntax_extension(parser, ext)
        }
        if let ext = cmark_find_syntax_extension("inlineimage") {
            cmark_syntax_extension_inlineimage_set_wd(ext, baseDir)
            cmark_syntax_extension_inlineimage_set_mime_callback(ext, nil, nil)
            cmark_syntax_extension_inlineimage_set_remote_data_callback(ext, nil, nil)
            cmark_syntax_extension_inlineimage_set_unsafe_html_processor_callback(ext, nil, nil)
            cmark_parser_attach_syntax_extension(parser, ext)
        }

        let md = preprocessFrontMatter(text)
        md.withCString { p in
            cmark_parser_feed(parser, p, strlen(p))
        }
        guard let doc = cmark_parser_finish(parser) else {
            throw MarkdownError.failure( "unable to parse the Markdown file")
        }
        defer {
            cmark_node_free(doc)
        }

        highlightCodeBlocks(doc: doc, settings: settings, highlightBin: highlightBin, dataDir: dataDir, logFile: logFile)

        guard let html = cmark_render_html(doc, options, cmark_parser_get_syntax_extensions(parser)) else {
            throw MarkdownError.failure( "unable to render the Markdown file")
        }
        defer {
            free(html)
        }
        var body = String(cString: html)
        if body.contains("type=\"checkbox\"") {
            // GitHub CSS classes that cmark-gfm does not emit (drop the bullet next to the checkbox).
            body = body.replacingOccurrences(of: #"<li>(\s*<input type=\"checkbox\"[^>]*>)"#, with: #"<li class="task-list-item">$1"#, options: .regularExpression)
        }
        return body
    }

    /// Highlight all code blocks with SH's highlight and attach the result to the nodes.
    private static func highlightCodeBlocks(doc: OpaquePointer, settings: SettingsRendering, highlightBin: String, dataDir: String?, logFile: URL?) {
        guard let ext = cmark_find_syntax_extension("scsh_codeblock") else {
            try? "WARNING: markdown code block extension not available.".appendLine(to: logFile)
            return
        }
        var blocks: [(node: OpaquePointer, code: String, lang: String)] = []
        let iter = cmark_iter_new(doc)
        while true {
            let ev = cmark_iter_next(iter)
            if ev == CMARK_EVENT_DONE {
                break
            }
            guard ev == CMARK_EVENT_ENTER, let node = cmark_iter_get_node(iter), cmark_node_get_type(node) == CMARK_NODE_CODE_BLOCK else {
                continue
            }
            let code = cmark_node_get_literal(node).map { String(cString: $0) } ?? ""
            let info = cmark_node_get_fence_info(node).map { String(cString: $0) } ?? ""
            let words = info.components(separatedBy: CharacterSet.whitespaces)
            let lang: String = words.first ?? ""
            blocks.append((node: node, code: code, lang: lang))
        }
        cmark_iter_free(iter)

        guard !blocks.isEmpty else {
            return
        }

        var extraArgs: [String] = []
        if let dataDir = dataDir {
            extraArgs.append("--data-dir=\(dataDir)")
        }
        extraArgs.append("--replace-tabs=\(settings.isTabSpacesDefined && settings.tabSpaces > 0 ? settings.tabSpaces : 4)")

        var results = [String?](repeating: nil, count: blocks.count)
        let resultsLock = NSLock()
        DispatchQueue.concurrentPerform(iterations: blocks.count) { i in
            let block = blocks[i]
            let lang = block.lang.lowercased()
            var html: String? = nil
            if !plainLanguages.contains(lang) && !highlightBin.isEmpty {
                html = highlightFragment(code: block.code, language: lang, highlightBin: highlightBin, extraArgs: extraArgs)
            }
            let value = html ?? escapeHTML(block.code)
            resultsLock.lock()
            results[i] = value
            resultsLock.unlock()
        }

        for (i, block) in blocks.enumerated() {
            if let html = results[i] {
                scsh_codeblock_set_html(block.node, ext, html)
            }
        }
        try? "Highlighted \(blocks.count) code block(s).".appendLine(to: logFile)
    }

    /// Run highlight on a code fragment.
    /// - returns: The HTML fragment or nil on error.
    private static func highlightFragment(code: String, language: String, highlightBin: String, extraArgs: [String]) -> String? {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("scsh-md-" + UUID().uuidString)
        do {
            try code.write(to: tmp, atomically: false, encoding: .utf8)
        } catch {
            return nil
        }
        defer {
            try? FileManager.default.removeItem(at: tmp)
        }
        let args = ["--out-format=html", "--fragment", "--syntax=\(language)", "--encoding=UTF-8", "--quiet"] + extraArgs + [tmp.path]
        guard let r = run(highlightBin, args), r.status == 0 else {
            return nil
        }
        return String(data: r.output, encoding: .utf8)
    }

    private static func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: Data)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (status: process.terminationStatus, output: data)
    }

    private static func escapeHTML(_ s: String) -> String {
        var r = ""
        r.reserveCapacity(s.utf8.count)
        for c in s {
            switch c {
            case "&": r += "&amp;"
            case "<": r += "&lt;"
            case ">": r += "&gt;"
            case "\"": r += "&quot;"
            default: r.append(c)
            }
        }
        return r
    }

    // MARK: - Style

    /// CSS of an SH theme (as generated by `highlight --print-style`) for the requested appearance.
    private static func themeCSS(settings: SettingsRendering, light: Bool, highlightBin: String, dataDir: String?, logFile: URL?) -> String? {
        let s = SettingsRendering(settings: settings.toDictionary())
        s.isLight = light
        s.themeName = "" // Use the light/dark theme of the settings.
        guard let hl = try? s.getHighlightArguments() else {
            return nil
        }
        var args = ["--print-style", "--out-format=html", "--style-outfile=stdout", "--quiet"]
        if let dataDir = dataDir {
            args.append("--data-dir=\(dataDir)")
        }
        var temporaryTheme: URL? = nil
        defer {
            if let u = temporaryTheme {
                try? FileManager.default.removeItem(at: u)
            }
        }
        if !settings.themeLua.isEmpty {
            // Inline theme (used by the app preview).
            let u = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString).appendingPathExtension("theme")
            if (try? settings.themeLua.write(to: u, atomically: true, encoding: .utf8)) != nil {
                temporaryTheme = u
                args.append("--style=\(u.path)")
            }
        } else if hl.theme.hasPrefix("!") {
            let name = String(hl.theme.dropFirst())
            if let u = SCSHBaseXPCService.getCustomThemesUrl(createIfMissing: false)?.appendingPathComponent(name).appendingPathExtension("theme") {
                args.append("--style=\(u.path)")
            }
        } else if let dataDir = dataDir {
            args.append("--style=\(dataDir)/themes/\(hl.theme).theme")
        } else {
            args.append("--style=\(hl.theme)")
        }
        // Keep only the user font settings.
        args += hl.arguments.filter({ $0.hasPrefix("--font=") || $0.hasPrefix("--font-size=") })

        guard let r = run(highlightBin, args), r.status == 0, let css = String(data: r.output, encoding: .utf8) else {
            try? "WARNING: unable to get the style of the theme `\(hl.theme)`.".appendLine(to: logFile)
            return nil
        }
        try? "Markdown code theme (\(light ? "light" : "dark")): \(hl.theme)".appendLine(to: logFile)
        return css
    }

    private static func pageCSS(settings: SettingsRendering, highlightBin: String, dataDir: String?, rsrcEsc: String, logFile: URL?) -> String {
        let cssUrl = URL(fileURLWithPath: rsrcEsc).appendingPathComponent("highlight/markdown.css")
        var base = (try? String(contentsOf: cssUrl, encoding: .utf8)) ?? fallbackCSS

        // Appearance forced by the caller (eg. `syntax_highlight_cli --appearance`): ignore the system scheme.
        let forced = settings.isLight

        var themes = ""
        if forced == nil || forced == true, let light = themeCSS(settings: settings, light: true, highlightBin: highlightBin, dataDir: dataDir, logFile: logFile) {
            themes += light + "\n"
        }
        if forced == nil || forced == false, let dark = themeCSS(settings: settings, light: false, highlightBin: highlightBin, dataDir: dataDir, logFile: logFile) {
            themes += forced == nil ? "@media (prefers-color-scheme: dark) {\n\(dark)\n}\n" : dark + "\n"
        }

        if let forced = forced {
            base = base.replacingOccurrences(of: "@media (prefers-color-scheme: dark)", with: forced ? "@media not all" : "@media all")
        }

        // Code blocks: theme colors/background/font, no wrap (scroll like GitHub).
        let overrides = """
        .markdown-body pre.hl { white-space: pre; overflow: auto; }
        .markdown-body pre.hl > code { font-family: inherit; color: inherit; white-space: pre; }
        .markdown-body img { max-width: 100%; }
        """
        return base + "\n" + themes + overrides
    }

    private static func completeHTML(title: String, body: String, css: String) -> String {
        // The body comes from an untrusted file: raw HTML is already omitted by cmark, the CSP
        // additionally blocks any script and limits the loaded resources.
        let csp = [
            "default-src 'none'",
            "style-src 'unsafe-inline'",
            "img-src data: https: http:",
            "font-src data:",
            "base-uri 'none'",
            "form-action 'none'",
        ].joined(separator: "; ")
        return """
        <!doctype html>
        <html>
        <head>
        <meta http-equiv="Content-Security-Policy" content="\(csp)">
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>\(escapeHTML(title))</title>
        <style type="text/css">
        \(css)
        </style>
        </head>
        <body>
        <article class="markdown-body">
        \(body)
        </article>
        </body>
        </html>
        """
    }

    private static let fallbackCSS = """
    body { font-family: -apple-system, sans-serif; line-height: 1.5; margin: 0; color: #24292e; background: #fff; }
    article { max-width: 902px; margin: auto; padding: 32px; }
    pre { padding: 16px; border-radius: 6px; }
    table { border-collapse: collapse; } td, th { border: 1px solid #ccc; padding: 6px 13px; }
    @media (prefers-color-scheme: dark) { body { color: #c9d1d9; background: #0d1117; } }
    """
}

#endif
