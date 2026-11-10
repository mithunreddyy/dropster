import Foundation
import PDFKit
import AppKit
import DropsterCore

/// Operations that turn many files into one: merge into a PDF, pack into a ZIP.
public struct BatchProcessor: Sendable {
    let workspace: Workspace
    let verifier: any OutputVerifier

    public init(workspace: Workspace, verifier: any OutputVerifier = DefaultVerifier()) {
        self.workspace = workspace
        self.verifier = verifier
    }

    public static func defaultName(for op: BatchOperation, inputs: [URL]) -> String {
        let base = inputs.count == 1 ? inputs[0].deletingPathExtension().lastPathComponent : "Combined"
        return op == .mergePDF ? "\(base).pdf" : "\(base).zip"
    }

    /// Runs `op` and commits the result into `folder` (default: the first input's folder).
    public func run(_ op: BatchOperation, inputs: [URL], folder: URL? = nil,
                    progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        guard !inputs.isEmpty else { throw DropsterError.unsupported("nothing to combine") }
        let jobDir = try workspace.makeJobDirectory()
        defer { workspace.remove(jobDir) }
        let temp = jobDir.appendingPathComponent(op == .mergePDF ? "out.pdf" : "out.zip")
        switch op {
        case .mergePDF: try mergePDF(inputs, to: temp, progress: progress)
        case .zip: try await zip(inputs, to: temp, stage: jobDir.appendingPathComponent("stage", isDirectory: true))
        }
        try verifier.verify(temp, expected: op == .mergePDF ? .pdf : .zip)
        let dir = folder ?? inputs[0].deletingLastPathComponent()
        let dest = OutputPlanner.unique(Self.defaultName(for: op, inputs: inputs), in: dir)
        try OutputPlanner.commit(temp, to: dest, preservingDatesOf: nil)
        progress(1)
        return dest
    }

    /// PDFs contribute all their pages; images become pages fitted to A4/Letter.
    func mergePDF(_ inputs: [URL], to url: URL, progress: @Sendable (Double) -> Void) throws {
        let out = PDFDocument()
        let letter = ["US", "CA", "MX", "PH"].contains(Locale.current.region?.identifier ?? "")
        let media = letter ? CGRect(x: 0, y: 0, width: 612, height: 792) : CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
        for (i, u) in inputs.enumerated() {
            if FileSignature.detect(url: u) == .pdf, let doc = PDFDocument(url: u) {
                guard !doc.isLocked else { throw DropsterError.unsupported("\(u.lastPathComponent) is password-protected") }
                for p in 0..<doc.pageCount { if let page = doc.page(at: p)?.copy() as? PDFPage { out.insert(page, at: out.pageCount) } }
            } else if FileSignature.detect(url: u) == .pdf {
                throw DropsterError.decodeFailed("\(u.lastPathComponent) is a damaged PDF")
            } else if let image = NSImage(contentsOf: u), image.isValid {
                let landscape = image.size.width > image.size.height
                let box = landscape ? CGRect(x: 0, y: 0, width: media.height, height: media.width) : media
                guard let page = PDFPage(image: image, options: [.mediaBox: box, .compressionQuality: 0.85]) else {
                    throw DropsterError.encodeFailed(u.lastPathComponent)
                }
                out.insert(page, at: out.pageCount)
            } else {
                throw DropsterError.unsupported("\(u.lastPathComponent) is not a PDF or image")
            }
            progress(Double(i + 1) / Double(inputs.count) * 0.9)
        }
        guard out.pageCount > 0, out.write(to: url) else { throw DropsterError.encodeFailed("merged PDF") }
    }

    /// Stages uniquely named links to the inputs so the archive has a flat, clean layout,
    /// then zips with symlinks followed (the archive contains the files, never links).
    func zip(_ inputs: [URL], to url: URL, stage: URL) async throws {
        guard let zip = ToolLocator.find("zip") else { throw DropsterError.unsupported("zip is not installed") }
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        var used: Set<String> = []
        var names: [String] = []
        for u in inputs {
            var name = OutputPlanner.sanitize(u.lastPathComponent)
            var n = 2
            while used.contains(name.lowercased()) {
                name = "\(OutputPlanner.sanitize(u.deletingPathExtension().lastPathComponent)) \(n)" + (u.pathExtension.isEmpty ? "" : ".\(u.pathExtension)")
                n += 1
            }
            used.insert(name.lowercased())
            try FileManager.default.createSymbolicLink(at: stage.appendingPathComponent(name), withDestinationURL: u)
            names.append(name)
        }
        try await ProcessRunner.check(zip, ["-q", "-r", "-X", "-9", url.path] + names, currentDirectory: stage)
    }
}
