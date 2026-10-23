//
//  main.swift
//  TeXRender
//
//  Unsandboxed XPC service: the Quick Look extension sandbox forbids running the TeX binaries.
//

import Foundation

class TeXRenderService: NSObject, TeXRenderProtocol {
    func compile(path: String, withReply reply: @escaping (Data?, String?, String?) -> Void) {
        do {
            reply(try TeXRenderer.pdf(for: URL(fileURLWithPath: path)), nil, nil)
        } catch TeXRenderer.Failure.compile(let log) {
            reply(nil, TeXRenderer.Failure.compile(log: log).localizedDescription, log)
        } catch {
            reply(nil, error.localizedDescription, nil)
        }
    }
}

class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: TeXRenderProtocol.self)
        newConnection.exportedObject = TeXRenderService()
        newConnection.resume()
        return true
    }
}

let delegate = ServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
