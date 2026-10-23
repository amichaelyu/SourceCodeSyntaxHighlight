//
//  PreviewViewController.swift
//  SyntaxHighlightExtension
//
//  Created by sbarex on 15/10/2019.
//  Copyright © 2019 sbarex. All rights reserved.
//
//
//  This file is part of SyntaxHighlight.
//  SyntaxHighlight is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  SyntaxHighlight is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with SyntaxHighlight. If not, see <http://www.gnu.org/licenses/>.

import Cocoa
import Quartz
import PDFKit
import WebKit
import OSLog

import Syntax_Highlight_XPC_Render


class StaticTextView: NSTextView {
    override func mouseDown(with event: NSEvent) {
        if event.clickCount > 1, let u = (self.window?.contentViewController as? PreviewViewController)?.fileUrl {
            // Open the source file by a double click on the Quick Look preview window.
            NSWorkspace.shared.open(u)
        }
        /*
        if let parent = self.superview?.superview as? NSScrollView {
            if let _ = parent.verticalScroller?.hitTest(NSPoint(x: event.absoluteX, y: event.absoluteY)) {
                super.mouseDown(with: event)
                return
            } else if let _ = parent.horizontalScroller?.hitTest(NSPoint(x: event.absoluteX, y: event.absoluteY)) {
                super.mouseDown(with: event)
                return
            }
        }
        */
        self.window?.performDrag(with: event)
    }
}

class StaticWebView: WKWebView {
    var fileUrl: URL?
    static let scrollerSize = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay)
    
    override func mouseDown(with event: NSEvent) {
        if event.clickCount > 1, let u = fileUrl {
            // Open the source file by a double click on the Quick Look preview window.
            NSWorkspace.shared.open(u)
        } else {
            let pos = self.convert(event.locationInWindow, from: nil)
            var rect = bounds
            rect.size.width -= StaticWebView.scrollerSize
            rect.size.height -= StaticWebView.scrollerSize
            if rect.contains(pos) {
                self.window?.performDrag(with: event)
            } else {
                // Ignore the event to allow interaction with scrollbars.
                super.mouseDown(with: event)
            }
        }
    }
}

class PreviewViewController: NSViewController, QLPreviewingController, WKNavigationDelegate {
    /// Url of current file.
    var fileUrl: URL?
    
    var textScrollView: NSScrollView?
    var textView: NSTextView?
    var webView: WKWebView?
    var pdfView: PDFView?
    var appearanceObserver: NSKeyValueObservation?
    
    /// Check if the appearance is Dark
    lazy var isDarkMode: Bool = {
        // fixme: nell'estensione non sempre restituisce il valore aggiornato!
        if let appearance = self.view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) {
            return appearance == .darkAqua
        }
        return false
    }()
    
    lazy var connection: NSXPCConnection = {
        let connection = NSXPCConnection(serviceName: "com.michaelyu.SourceCodeSyntaxHighlight.XPCRender")
        connection.remoteObjectInterface = NSXPCInterface(with: XPCLightRenderServiceProtocol.self)
        connection.resume()
        return connection
    }()
    
    private let log = {
        return OSLog(subsystem: Bundle.main.bundleIdentifier!, category: "quicklook.scsh-extension")
    }()
    
    override var nibName: NSNib.Name? {
        return NSNib.Name("PreviewViewController")
    }

    override func loadView() {
        // This code will not be called on macOS 12 Monterey with QLIsDataBasedPreview set.
        
        super.loadView()
        // Do any additional setup after loading the view.
        if #available(macOS 11, *) {
            view.wantsLayer = true
            view.layer?.borderWidth = 0
        }
        
        self.appearanceObserver = NSApp.observe(\.effectiveAppearance, options: [.new, .old, .initial, .prior]) { app, change in
            self.isDarkMode = change.newValue?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
        
        self.textView?.linkTextAttributes = [:]
        
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(self.handleSettingsChanged(_:)), name: .SettingsUpdated, object: nil)
    }

    deinit {
        self.connection.invalidate()
        DistributedNotificationCenter.default().removeObserver(self, name: .SettingsUpdated, object: nil)
        self.appearanceObserver?.invalidate()
        self.appearanceObserver = nil
    }
    
    /// Reload settings after they have been changed in the main app.
    @objc internal func handleSettingsChanged(_ notification: Notification) {
        guard let service = connection.synchronousRemoteObjectProxyWithErrorHandler({ error in
            print("Received error:", error)
        }) as? XPCLightRenderServiceProtocol else {
            return
        }
        service.reloadSettings()
    }
    
    /*
     * Implement this method and set QLSupportsSearchableItems to YES in the Info.plist of the extension if you support CoreSpotlight.
     *
    func preparePreviewOfSearchableItem(identifier: String, queryString: String?, completionHandler handler: @escaping (Error?) -> Void) {
        // Perform any setup necessary in order to prepare the view.
        
        // Call the completion handler so Quick Look knows that the preview is fully loaded.
        // Quick Look will display a loading spinner while the completion handler is not called.
        handler(nil)
    }
     */
    
    var handler: ((Error?) -> Void)? = nil
    
    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        // This code will *not* be called on macOS 12 Monterey with QLIsDataBasedPreview set.
        
        // Add the supported content types to the QLSupportedContentTypes array in the Info.plist of the extension.
        
        // Perform any setup necessary in order to prepare the view.
        
        // Call the completion handler so Quick Look knows that the preview is fully loaded.
        // Quick Look will display a loading spinner while the completion handler is not called.
        
        self.fileUrl = url
        
        os_log(
            "Generating preview for file %{public}s…",
            log: self.log,
            type: .info,
            url.path
        )
        
        do {
            let result: RenderResult
            if TeXSupportedExtensions.contains(url.pathExtension.lowercased()) {
                // TeX documents are compiled to PDF by the TeXRender service, bypassing the highlight service.
                switch self.renderTeX(at: url) {
                case .pdf(let data, let size):
                    result = .pdf(data: data, size: size)
                case .failure(let html):
                    result = .html(code: html, settings: nil)
                }
            } else {
                result = try self.renderFile(at: url, refreshingSettings: true)
            }
            
            DispatchQueue.main.async {
                let previewRect: CGRect
                if #available(macOS 11, *) {
                    previewRect = self.view.bounds
                } else {
                    previewRect = self.view.bounds.insetBy(dx: 2, dy: 2)
                }
                switch result {
                case .html(let code, let settings):
                    os_log(OSLogType.info, log: self.log, "Preferred content size: %{public}f x %{public}f", settings?.qlWindowSize.width ?? 0, settings?.qlWindowSize.height ?? 0)
                    self.preferredContentSize = settings?.qlWindowSize ?? .zero
                    self.handler = handler
                    if self.webView == nil {
                        // Create a configuration for the preferences
                        let configuration = WKWebViewConfiguration()
                        
                        if #available(macOS 11.0, *) {
                            configuration.defaultWebpagePreferences.allowsContentJavaScript = settings?.allowInteractiveActions ?? false
                        } else {
                            configuration.preferences.javaScriptEnabled = settings?.allowInteractiveActions ?? false
                        }
                        configuration.allowsAirPlayForMediaPlayback = false
                        // configuration.userContentController.add(self, name: "jsHandler")
                    
                        /* MARK: FIXME
                        On Big Sur as far as I know, Quick Look extensions don't honor com.apple.security.network.client, so WebKit process immediately crash.
                        To temporary fix add this entitlements exception
                        com.apple.security.temporary-exception.mach-lookup.global-name:
                        <key>com.apple.security.temporary-exception.mach-lookup.global-name</key>
                        <array>
                            <string>com.apple.nsurlsessiond</string>
                        </array>
                        */

                        let webView: WKWebView
                        if settings?.allowInteractiveActions ?? false {
                            webView = WKWebView(frame: previewRect, configuration: configuration)
                        } else {
                            webView = StaticWebView(frame: previewRect, configuration: configuration)
                            (webView as! StaticWebView).fileUrl = self.fileUrl
                        }
                        webView.autoresizingMask = [.height, .width]
                        
                        webView.wantsLayer = true
                        if #available(macOS 11, *) {
                            webView.layer?.borderWidth = 0
                        } else {
                            // Draw a border around the web view
                            webView.layer?.borderColor = NSColor.tertiaryLabelColor.cgColor
                            webView.layer?.borderWidth = 1
                        }
                    
                        webView.navigationDelegate = self
                        webView.uiDelegate = self
                        self.view.addSubview(webView)
                        self.webView = webView
                    } else {
                        if #available(macOS 11.0, *) {
                            self.webView?.configuration.defaultWebpagePreferences.allowsContentJavaScript = settings?.allowInteractiveActions ?? false
                        } else {
                            self.webView?.configuration.preferences.javaScriptEnabled =  settings?.allowInteractiveActions ?? false
                        }
                    }
                    
                    self.textScrollView?.isHidden = true
                    self.pdfView?.isHidden = true
                    self.webView?.isHidden = false

                    self.webView?.loadHTMLString(code, baseURL: nil)
                    // handler(nil) // call the handler in the delegate method after complete rendering
                case .rtf(let data, let settings):
                    self.preferredContentSize = settings?.qlWindowSize ?? .zero
                    if self.textScrollView == nil {
                        let textScrollView = NSScrollView(frame: previewRect)
                        textScrollView.autoresizingMask = [.height, .width]
                        textScrollView.hasHorizontalScroller = true
                        textScrollView.hasVerticalScroller = true
                        if #available(macOS 11, *) {
                            textScrollView.borderType = .noBorder
                            textScrollView.backgroundColor = NSColor.clear
                        } else {
                            textScrollView.borderType = .lineBorder
                        }
                        self.view.addSubview(textScrollView)
                        
                        let textView: NSTextView
                        if #available(macOS 11, *) {
                            textView = NSTextView(frame: CGRect(origin: .zero, size: textScrollView.contentSize))
                        } else {
                            // Catalina do not automatically handle double click and drag on the ql preview window.
                            textView = StaticTextView(frame: CGRect(origin: .zero, size: textScrollView.contentSize))
                        }
                        
                        self.textScrollView = textScrollView
                        self.textView = textView
                        
                        self.textView?.isVerticallyResizable = true
                        self.textView?.isHorizontallyResizable = true
                        self.textView?.autoresizingMask = []
                        
                        self.textView?.textContainerInset = CGSize(width: 6, height: 12)
                        
                        self.textView?.textContainer?.heightTracksTextView = false
                        self.textView?.wantsLayer = true
                        self.textView?.layer?.borderWidth = 0
                        
                        self.textView?.isEditable = false
                        self.textView?.isSelectable = false
                        
                        self.textView?.isGrammarCheckingEnabled = false
                        
                        self.textView?.backgroundColor = .clear
                        
                        self.textView?.allowsDocumentBackgroundColorChange = true
                        self.textView?.usesFontPanel = false
                        self.textView?.usesRuler = false
                        self.textView?.usesInspectorBar = false
                        self.textView?.allowsImageEditing = false
                        
                        self.textScrollView?.documentView = self.textView
                    }
                    self.webView?.isHidden = true
                    self.pdfView?.isHidden = true
                    self.textScrollView?.isHidden = false
                    
                    if let settings = settings, settings.isWordWrapped, !settings.isWordWrappedSoft {
                        self.textView?.maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
                        self.textView?.textContainer?.widthTracksTextView = false
                        self.textView?.textContainer?.containerSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
                    } else {
                        // self.textView?.maxSize = CGSize(width: textScrollView!.bounds.width, height: CGFloat.greatestFiniteMagnitude)
                        self.textView?.textContainer?.widthTracksTextView = true
                    }
                    
                    // The rtf parser don't apply (why?) the page background color.
                    if let c = settings?.backgroundColor, let color = NSColor(fromHexString: c) {
                        self.textView?.backgroundColor = color
                        self.textView?.drawsBackground = true
                    } else {
                        self.textView?.backgroundColor = .clear
                        self.textView?.drawsBackground = false
                    }
                    
                    var text: NSAttributedString
                    if let t = NSAttributedString(rtf: data, documentAttributes: nil) {
                        text = t
                    } else {
                        let t: NSMutableAttributedString
                        os_log(OSLogType.error, log: self.log, "Syntax Highlight: unable to convert data to RTF!")
                        if let settings = settings, let a: NSAttributedString = "Syntax Highlight: unable to convert data to RTF.\n\n".toRTF(settings: settings) {
                            t = NSMutableAttributedString(attributedString: a)
                        } else {
                            t = NSMutableAttributedString(string: "Syntax Highlight: unable to convert data to RTF.\n\n", attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
                        }
                        if let s = String(data: data, encoding: .utf8) {
                            t.append(NSAttributedString(string: s, attributes: [.font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)]))
                        }
                        text = t
                    }
                    
                    self.textView?.textStorage?.setAttributedString(text)
                    
                    handler(nil)
                case .pdf(let data, let size):
                    self.preferredContentSize = size
                    if self.pdfView == nil {
                        let pdfView = PDFView(frame: previewRect)
                        pdfView.autoresizingMask = [.height, .width]
                        pdfView.autoScales = true
                        pdfView.displayMode = .singlePageContinuous
                        self.view.addSubview(pdfView)
                        self.pdfView = pdfView
                    }
                    self.webView?.isHidden = true
                    self.textScrollView?.isHidden = true
                    self.pdfView?.isHidden = false
                    
                    if let document = PDFDocument(data: data) {
                        self.pdfView?.document = document
                        handler(nil)
                    } else {
                        os_log(OSLogType.error, log: self.log, "Unable to load the PDF generated from the TeX file.")
                        handler(NSError(domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError, userInfo: [NSLocalizedDescriptionKey: "Unable to load the PDF generated from the TeX file."]))
                    }
                }
            }
        } catch {
            os_log(OSLogType.error, log: self.log, "Error processing the file: %{public}s", error.localizedDescription)
            handler(error)
        }
    }
    
    @available(macOSApplicationExtension 12.0, *)
    func providePreview(for request: QLFilePreviewRequest, completionHandler handler: @escaping (QLPreviewReply?, Error?) -> Void) {
        // This code will be called on macOS 12 Monterey with QLIsDataBasedPreview set.
        
        if TeXSupportedExtensions.contains(request.fileURL.pathExtension.lowercased()) {
            switch self.renderTeX(at: request.fileURL) {
            case .pdf(let data, let size):
                handler(QLPreviewReply(dataOfContentType: UTType.pdf, contentSize: size) { _ in data }, nil)
            case .failure(let html):
                handler(QLPreviewReply(dataOfContentType: UTType.html, contentSize: .zero) { (reply: QLPreviewReply) in
                    reply.stringEncoding = .utf8
                    return html.data(using: .utf8)!
                }, nil)
            }
            return
        }
        
        do {
            let result = try self.renderFile(at: request.fileURL, refreshingSettings: true)
            let r: QLPreviewReply
            switch result {
            case .html(let code, let settings):
                if settings?.isRenderingSupported ?? false {
                    if settings?.isImage ?? false {
                        os_log(OSLogType.info, log: self.log, "File rendered as image.")
                        r = QLPreviewReply(dataOfContentType: UTType.image, contentSize: .zero) { _ in
                            return (try? Data(contentsOf: request.fileURL)) ?? "Unable to load the image file!".data(using: .utf8)!
                        }
                    } else if settings?.isPDF ?? false {
                        os_log(OSLogType.info, log: self.log, "File rendered as PDF.")
                        r = QLPreviewReply(dataOfContentType: UTType.pdf, contentSize: .zero) { _ in
                            return (try? Data(contentsOf: request.fileURL)) ?? "Unable to load the PDF file!".data(using: .utf8)!
                        }
                    } else if settings?.isMovie ?? false {
                        os_log(OSLogType.info, log: self.log, "File rendered as movie.")
                        r = QLPreviewReply(dataOfContentType: UTType.movie, contentSize: .zero) { _ in
                            return (try? Data(contentsOf: request.fileURL)) ?? "Unable to load the movie file!".data(using: .utf8)!
                        }
                    } else if settings?.isAudio ?? false {
                        os_log(OSLogType.info, log: self.log, "File rendered as audio.")
                        r = QLPreviewReply(dataOfContentType: UTType.audio, contentSize: .zero) { _ in
                            return (try? Data(contentsOf: request.fileURL)) ?? "Unable to load the audio file!".data(using: .utf8)!
                        }
                    } else {
                        os_log(OSLogType.info, log: self.log, "Syntax highlighted in HTML format, content size: %{public}f x %{public}f.", settings?.qlWindowSize.width ?? 0, settings?.qlWindowSize.height ?? 0)
                        r = QLPreviewReply(dataOfContentType: UTType.html, contentSize: settings?.qlWindowSize ?? .zero) { _ in
                            return code.data(using: .utf8)!
                        }
                    }
                } else {
                    os_log(OSLogType.error, log: self.log, "Unable to process the file.")
                    r = QLPreviewReply(fileURL: request.fileURL)
                }
            case .rtf(let data, let settings):
                if settings?.isRenderingSupported ?? false {
                    if settings?.isImage ?? false {
                        os_log(OSLogType.info, log: self.log, "File rendered as image.")
                        r = QLPreviewReply(dataOfContentType: UTType.image, contentSize: .zero) { _ in
                            return (try? Data(contentsOf: request.fileURL)) ?? "Unable to load the image file!".data(using: .utf8)!
                        }
                    } else if settings?.isPDF ?? false {
                        os_log(OSLogType.info, log: self.log, "File rendered as PDF.")
                        r = QLPreviewReply(dataOfContentType: UTType.pdf, contentSize: .zero) { _ in
                            return (try? Data(contentsOf: request.fileURL)) ?? "Unable to load the PDF file!".data(using: .utf8)!
                        }
                    } else if settings?.isMovie ?? false {
                        os_log(OSLogType.info, log: self.log, "File rendered as moview.")
                        r = QLPreviewReply(dataOfContentType: UTType.movie, contentSize: .zero) { _ in
                            return (try? Data(contentsOf: request.fileURL)) ?? "Unable to load the movie file!".data(using: .utf8)!
                        }
                    } else if settings?.isAudio ?? false {
                        os_log(OSLogType.info, log: self.log, "File rendered as audio.")
                        r = QLPreviewReply(dataOfContentType: UTType.audio, contentSize: .zero) { _ in
                            return (try? Data(contentsOf: request.fileURL)) ?? "Unable to load the audio file!".data(using: .utf8)!
                        }
                    }  else {
                        os_log(OSLogType.info, log: self.log, "Syntax highlighted in RTF format, content size: %{public}f x %{public}f.", settings?.qlWindowSize.width ?? 0, settings?.qlWindowSize.height ?? 0)
                        r = QLPreviewReply(dataOfContentType: UTType.rtf, contentSize: settings?.qlWindowSize ?? .zero) { _ in
                            return data
                        }
                    }
                } else {
                    os_log(OSLogType.error, log: self.log, "Unable to process the file.")
                    r = QLPreviewReply(fileURL: request.fileURL)
                }
            case .pdf(let data, let size):
                r = QLPreviewReply(dataOfContentType: UTType.pdf, contentSize: size) { _ in data }
            }
            handler(r, nil)
        } catch {
            os_log(OSLogType.error, log: self.log, "Error processing the file: %{public}s", error.localizedDescription)
            handler(nil, error)
        }
    }
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let handler = self.handler {
            // Show the Quick Look preview only after the complete rendering (preventing a flickering glitch).
            /*
            let w = NSScroller.scrollerWidth(for: NSControl.ControlSize.regular, scrollerStyle: NSScroller.Style.overlay)
            webView.evaluateJavaScript("""
            document.body.onmousedown = function(event) {
                const height = document.body.scrollHeight;
                const width = document.body.scrollWidth;
                const hasHorizontalScrollbar = width >  window.innerWidth;
                const hasVerticalScrollbar = height > window.innerHeight;
                const scroller = \(w);
                if (hasVerticalScrollbar && event.clientX >= window.innerWidth - scroller) {
                    // Mouse over scrollbar.
                    return;
                } else if (hasHorizontalScrollbar && event.clientY >= window.innerHeight - scroller) {
                    // Mouse over scrollbar.
                    return;
                } else {
                    event.stopPropagation();
                    window.webkit.messageHandlers.jsHandler.postMessage({event: "mousedown"});
                }
            }
            body.ondblclick = function(event) {
                window.webkit.messageHandlers.jsHandler.postMessage({event: "dblclick"});
                event.stopPropagation();
            }
            true; // result returned to swift
            """){ (result, error) in
                if let e = error {
                    print(e)
                }
            }
            */
            handler(nil)
            self.handler = nil
        }
    }
    
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if let handler = self.handler {
            handler(error)
            self.handler = nil
        }
    }
    
    enum RenderResult {
        case html(code: String, settings: SettingsRendering?)
        case rtf(data: Data, settings: SettingsRendering?)
        case pdf(data: Data, size: CGSize)
    }
    
    enum TeXResult {
        case pdf(data: Data, size: CGSize)
        case failure(html: String)
    }
    
    /// Compiles a TeX file through the unsandboxed TeXRender XPC service (the extension sandbox cannot run the TeX binaries).
    func renderTeX(at url: URL) -> TeXResult {
        os_log("Generating TeX preview for file %{public}s", log: self.log, type: .info, url.path)
        
        var pdf: Data?
        var message = "The TeX render service is not available."
        var texLog = ""
        
        let connection = NSXPCConnection(serviceName: TeXRenderServiceName)
        connection.remoteObjectInterface = NSXPCInterface(with: TeXRenderProtocol.self)
        connection.resume()
        defer { connection.invalidate() }
        
        let service = connection.synchronousRemoteObjectProxyWithErrorHandler { error in
            message = error.localizedDescription
        } as? TeXRenderProtocol
        service?.compile(path: url.path) { data, error, errorLog in
            pdf = data
            message = error ?? message
            texLog = errorLog ?? ""
        }
        
        if let pdf = pdf {
            os_log("TeX preview generated (%{public}d bytes).", log: self.log, type: .info, pdf.count)
            return .pdf(data: pdf, size: Self.texPreviewSize(for: pdf))
        }
        os_log(OSLogType.error, log: self.log, "TeX preview failed: %{public}s", message)
        return .failure(html: Self.texErrorPage(for: url, message: message, log: texLog))
    }
    
    /// Window size fitting the width of the first page, limited to the screen.
    static func texPreviewSize(for pdf: Data) -> CGSize {
        let page = PDFDocument(data: pdf)?.page(at: 0)?.bounds(for: .mediaBox).size ?? CGSize(width: 612, height: 792)
        let available = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        return CGSize(width: min(page.width + 40, available.width * 0.9), height: min(page.height + 40, available.height * 0.9))
    }
    
    static func texErrorPage(for url: URL, message: String, log: String) -> String {
        var details = ""
        if !log.isEmpty {
            // Keep the error lines reported by -file-line-error and their context.
            let lines = log.components(separatedBy: "\n")
            if let first = lines.firstIndex(where: { $0.hasPrefix("!") || $0.range(of: #"^[^:]+:\d+: "#, options: .regularExpression) != nil }) {
                details = lines[first ..< min(lines.count, first + 20)].joined(separator: "\n")
            } else {
                details = lines.suffix(30).joined(separator: "\n")
            }
        }
        let source = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        func escape(_ s: String) -> String {
            return s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        
        return """
        <!doctype html>
        <html><head><meta charset="utf-8"><style>
        :root { color-scheme: light dark; }
        body { font: 13px -apple-system, sans-serif; margin: 20px; }
        pre { font: 12px ui-monospace, monospace; white-space: pre-wrap; padding: 12px; border-radius: 6px; background: rgba(127,127,127,.12); }
        .error { color: #d33; }
        </style></head><body>
        <h3 class="error">\(escape(message))</h3>
        \(details.isEmpty ? "" : "<pre>\(escape(details))</pre>")
        <h4>\(escape(url.lastPathComponent))</h4>
        <pre>\(escape(source))</pre>
        </body></html>
        """
    }
    
    func renderFile(at url: URL, refreshingSettings: Bool) throws -> RenderResult {
        os_log(
            "Generating preview for file %{public}s…",
            log: self.log,
            type: .info,
            url.path
        )
        
        var result: RenderResult?
        
        var connettion_error: Error?
        guard let service = connection.synchronousRemoteObjectProxyWithErrorHandler({ error in
            connettion_error = error
            /*
            print("Received error:", error)
             */
        }) as? XPCLightRenderServiceProtocol else {
            os_log(OSLogType.error, log: self.log, "Syntax Highlight: invalid XPC service!")
            return RenderResult.html(code: "Syntax Highlight: invalid XPC service.\n\(connettion_error?.localizedDescription ?? "")".toHTML(), settings: nil)
        }
        guard connettion_error == nil else {
            os_log(OSLogType.error, log: self.log, "Syntax Highlight: %{public}s", connettion_error!.localizedDescription)
            return RenderResult.html(code: "Syntax Highlight: \(connettion_error!.localizedDescription).".toHTML(), settings: nil)
        }
        
        service.colorize(url: url, refreshingSettings: refreshingSettings) { (response: Data, settings: NSDictionary, error: Error?) in
            let settings = SettingsRendering(settings: settings as! [String: AnyHashable])
            
            os_log(
                "Output mode: %{public}s",
                log: self.log,
                type: .info,
                settings.format.rawValue
            )
                
            if settings.format == .rtf {
                result = RenderResult.rtf(data: response, settings: settings)
            } else {
                var lossy = false
                let html = response.decodeToString(lossy: &lossy).trimmingCharacters(in: CharacterSet.newlines)
                
                if lossy {
                    os_log(OSLogType.error, log: self.log, "Some bytes cannot be decoded and have been replaced!")
                }
                
                result = RenderResult.html(code: html, settings: settings)
            }
        }
        
        if result == nil {
            os_log(OSLogType.error, log: self.log, "Syntax Highlight error!")
        }
        return result ?? RenderResult.html(code: "Syntax Highlight error.".toHTML(), settings: nil)
    }
}

/*
// MARK - WKScriptMessageHandler
extension PreviewViewController: WKScriptMessageHandler {
    /// Handle messages from the webkit.
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "jsHandler", let result = message.body as? [String: Any] else {
            return
        }
        
        if result["event"] as? String == "mousedown" {
        let event = NSEvent.mouseEvent(with: NSEvent.EventType.leftMouseDown, location: NSEvent.mouseLocation, modifierFlags: [], timestamp: TimeInterval(), windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        self.view.window?.performDrag(with: event)
        } else if result["event"] as? String == "dblclick" {
            NSWorkspace.shared.open(fileUrl!)
        } else {
            print(result)
        }
    }
}
*/

extension PreviewViewController: WKUIDelegate {
}
