import Foundation
import DropsterCore
import DropsterEngines

/// `dropster-cli bench <files or folder> [--out report.md]`
///
/// Runs every applicable operation in every mode on each file and records size, time,
/// peak memory and (for lossy images) SSIM. Outputs go to a scratch folder and are deleted.
enum Bench {
    struct Row {
        var file: String
        var operation: String
        var mode: CompressionMode
        var inBytes: Int64
        var outBytes: Int64
        var seconds: Double
        var ssim: Double?
        var kept: Bool
    }

    static func run(_ inputs: [URL], report: URL?) async throws {
        let registry = Engines.makeRegistry()
        let processor = try Processor(registry: registry, workspace: Workspace(), verifier: DefaultVerifier())
        let analyzer = FileAnalyzer()
        let meter = QualityMeter()
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("dropster-bench-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        var files: [URL] = []
        for u in inputs {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir)
            if isDir.boolValue {
                files += (try FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: nil))
                    .filter { !$0.lastPathComponent.hasPrefix(".") }.sorted { $0.path < $1.path }
            } else { files.append(u) }
        }

        var rows: [Row] = []
        for f in files {
            let r = await analyzer.analyze(f)
            guard let format = r.format else { continue }
            var ops: [FileOperation] = []
            if registry.optimizableFormats.contains(format) { ops.append(.optimize) }
            switch format.category {
            case .image: ops += [FormatID.webp, .avif, .heic].filter { $0 != format && registry.route(from: format, to: $0) != nil }.map { .convert($0) }
            case .audio: ops += [FormatID.flac, .opus].filter { $0 != format && registry.route(from: format, to: $0) != nil }.map { .convert($0) }
            default: break
            }
            for op in ops {
                for mode in CompressionMode.allCases {
                    let target: FormatID = if case .convert(let t) = op { t } else { format }
                    let dest = scratch.appendingPathComponent(UUID().uuidString + "." + target.preferredExtension)
                    let options = ProcessingOptions(mode: mode, metadata: .keep, output: .folder(scratch))
                    do {
                        let res = try await processor.process(r, operation: op, options: options, destination: dest) { _ in }
                        var ssim: Double?
                        if target.category == .image, target.isLossy, res.outcome == .written, let meter {
                            ssim = try? await meter.ssim(original: f, candidate: dest)
                        }
                        rows.append(Row(file: f.lastPathComponent, operation: op.label, mode: mode, inBytes: res.inputBytes,
                                        outBytes: res.producedBytes, seconds: res.duration, ssim: ssim, kept: res.outcome == .keptOriginal))
                        try? FileManager.default.removeItem(at: dest)
                    } catch {
                        FileHandle.standardError.write(Data("\(f.lastPathComponent) \(op.label) \(mode): \(error.localizedDescription)\n".utf8))
                    }
                }
            }
        }

        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        var childUsage = rusage()
        getrusage(RUSAGE_CHILDREN, &childUsage)
        let peakMB = Double(max(usage.ru_maxrss, childUsage.ru_maxrss)) / 1_048_576 // bytes on macOS

        var md = "| File | Operation | Mode | Input | Output | Change | Time | SSIM |\n|---|---|---|---:|---:|---:|---:|---:|\n"
        for r in rows {
            let change = r.inBytes > 0 ? (Double(r.outBytes) / Double(r.inBytes) - 1) * 100 : 0
            md += "| \(r.file) | \(r.operation) | \(r.mode.displayName) | \(fmt(r.inBytes)) | \(fmt(r.outBytes)) | "
            md += String(format: "%+.1f%%", change) + (r.kept ? " (kept original)" : "") + " | "
            md += String(format: "%.2f s", r.seconds) + " | " + (r.ssim.map { String(format: "%.4f", $0) } ?? "–") + " |\n"
        }
        md += "\nPeak resident memory (largest of Dropster process and any single child tool): \(String(format: "%.0f", peakMB)) MB\n"
        md += "Machine: \(machine()) · \(ProcessInfo.processInfo.activeProcessorCount) cores · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        if let report { try md.write(to: report, atomically: true, encoding: .utf8) }
        print(md)
    }

    static func fmt(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    static func machine() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        return String(cString: buf)
    }
}
