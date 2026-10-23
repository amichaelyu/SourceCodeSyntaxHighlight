//
//  TeXRenderProtocol.swift
//  TeXRender
//

import Foundation

/// Mach service name of the TeX render XPC service embedded in the Quick Look extension.
let TeXRenderServiceName = "com.michaelyu.SourceCodeSyntaxHighlight.TeXRender"

/// Extensions of the files rendered as TeX documents.
let TeXSupportedExtensions: Set<String> = ["tex", "latex", "ltx"]

@objc protocol TeXRenderProtocol {
    /// Compiles the TeX file at `path`. Replies with the PDF data, or with an error message and the compiler log.
    func compile(path: String, withReply reply: @escaping (Data?, String?, String?) -> Void)
}
