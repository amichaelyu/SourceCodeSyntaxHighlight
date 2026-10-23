//
//  TeXRenderer.swift
//  TeXRender
//

import Foundation

enum TeXRenderer {
    /// Folders searched for the TeX binaries (MacTeX, Homebrew).
    static let binFolders = ["/Library/TeX/texbin", "/opt/homebrew/bin", "/usr/local/bin"]

    static let passTimeout: TimeInterval = 30
    static let maxPasses = 3

    enum Failure: LocalizedError {
        case engineNotFound(String)
        case timeout
        case compile(log: String)

        var errorDescription: String? {
            switch self {
            case .engineNotFound(let engine):
                return "\(engine) not found. Install MacTeX or BasicTeX to preview TeX files."
            case .timeout:
                return "The TeX compiler did not finish within \(Int(TeXRenderer.passTimeout)) seconds."
            case .compile:
                return "The document failed to compile."
            }
        }
    }

    /// Returns the PDF for the TeX file: the sibling PDF when up to date, otherwise a compiled (and cached) copy.
    static func pdf(for url: URL) throws -> Data {
        let texDate = modificationDate(url) ?? .distantFuture

        let sibling = url.deletingPathExtension().appendingPathExtension("pdf")
        if let date = modificationDate(sibling), date >= texDate, let data = try? Data(contentsOf: sibling) {
            return data
        }

        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tex-preview", isDirectory: true)
            .appendingPathComponent(String(format: "%016llx", stableHash(url.path)), isDirectory: true)
        let output = cacheDir.appendingPathComponent(url.deletingPathExtension().lastPathComponent).appendingPathExtension("pdf")
        if let date = modificationDate(output), date >= texDate, let data = try? Data(contentsOf: output) {
            return data
        }

        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: output)

        let engine = self.engine(for: url)
        guard let executable = binFolders.map({ URL(fileURLWithPath: $0).appendingPathComponent(engine) }).first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw Failure.engineNotFound(engine)
        }

        let logUrl = output.deletingPathExtension().appendingPathExtension("log")
        for _ in 0 ..< maxPasses {
            try runPass(executable: executable, file: url, outputDir: cacheDir)
            let log = (try? String(contentsOf: logUrl, encoding: .isoLatin1)) ?? ""
            if !log.contains("Rerun to get") && !log.contains("Rerun LaTeX") && !log.contains("may have changed. Rerun") {
                break
            }
        }

        guard let data = try? Data(contentsOf: output) else {
            let log = (try? String(contentsOf: logUrl, encoding: .isoLatin1)) ?? (try? String(contentsOf: cacheDir.appendingPathComponent("console.txt"), encoding: .isoLatin1)) ?? ""
            throw Failure.compile(log: log)
        }
        return data
    }

    /// Honors the `% !TEX program = xelatex` magic comment, otherwise picks the engine required by the packages.
    static func engine(for url: URL) -> String {
        let head = (try? String(contentsOf: url, encoding: .utf8))?.prefix(4000) ?? ""
        for line in head.split(separator: "\n") where line.hasPrefix("%") {
            let lower = line.lowercased().replacingOccurrences(of: " ", with: "")
            for engine in ["xelatex", "lualatex", "pdflatex"] where lower.hasPrefix("%!tex") && lower.contains("program=\(engine)") {
                return engine
            }
        }
        return head.contains("{fontspec}") ? "xelatex" : "pdflatex"
    }

    static func runPass(executable: URL, file: URL, outputDir: URL) throws {
        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = file.deletingLastPathComponent()
        process.arguments = ["-interaction=nonstopmode", "-halt-on-error", "-file-line-error", "-output-directory=\(outputDir.path)", file.lastPathComponent]

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (binFolders + ["/usr/bin", "/bin"]).joined(separator: ":")
        // Generated fonts and caches must go to a writable folder inside the sandbox.
        env["TEXMFVAR"] = outputDir.appendingPathComponent("texmf-var").path
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        // Keep the console output: early failures (e.g. kpathsea) happen before the .log exists.
        let consoleUrl = outputDir.appendingPathComponent("console.txt")
        FileManager.default.createFile(atPath: consoleUrl.path, contents: nil)
        let console = try FileHandle(forWritingTo: consoleUrl)
        defer { try? console.close() }
        process.standardOutput = console
        process.standardError = console

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        if done.wait(timeout: .now() + passTimeout) == .timedOut {
            process.terminate()
            throw Failure.timeout
        }
    }

    /// FNV-1a; `hashValue` is seeded per process and can't key a cache.
    static func stableHash(_ s: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return hash
    }

    static func modificationDate(_ url: URL) -> Date? {
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
