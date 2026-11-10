import Foundation
import DropsterCore
import DropsterEngines

// dropster — command-line front end to the same engine the app uses.
//
//   dropster analyze <files…>
//   dropster optimize [--mode smallest|balanced|fastest] [--keep-metadata|--strip-all] [--max-size N] [--out DIR] <files…>
//   dropster convert <format> [options] <files…>
//   dropster clean <files…>
//   dropster formats

func usage() -> Never {
    print("""
    usage: dropster analyze <files…>
           dropster optimize [options] <files…>
           dropster convert <format> [options] <files…>
           dropster clean <files…>
           dropster edit rotate-right|rotate-left|flip-h|flip-v|grayscale|cutout <images…>
           dropster pages <format> <pdf or video…>     one image per page / frame
           dropster long <format> <pdf…>               every page in one tall image
           dropster split <pdf…>   ·   dropster extract "1-3,5" <pdf…>
           dropster merge <files…> ·   dropster zip <files…>
           dropster fit <size, e.g. 10MB> <images, videos or audio…>   best quality under a size
           dropster unpack <archives…>                 safe extraction (zip, 7z, tar, gz, xz, zst, br)
           dropster list <archive>                     show an archive's contents without extracting
           dropster formats
           dropster bench <files or folders> [--out report.md]
           dropster ssim <original> <candidate>

    options: --mode smallest|balanced|fastest   --quality 0-100   --max-size PIXELS
             --keep-metadata | --strip-all       --out DIR         --only-smaller
             --dpi N   --height 720   --codec h264|hevc|av1   --hardware   --fps N
             --mp3-bitrate 192   --name "{name}-{action}"
    """)
    exit(64)
}

func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { usage() }
args.removeFirst()

if command == "ssim" {
    guard args.count == 2, let meter = QualityMeter() else { usage() }
    let v = try await meter.ssim(original: URL(fileURLWithPath: args[0]), candidate: URL(fileURLWithPath: args[1]))
    print(String(format: "%.4f  %@", v, QualityMeter.Verdict(ssim: v).rawValue))
    exit(0)
}

if command == "bench" {
    var report: URL?
    if let i = args.firstIndex(of: "--out"), i + 1 < args.count { report = URL(fileURLWithPath: args[i + 1]); args.removeSubrange(i...(i + 1)) }
    try await Bench.run(args.map { URL(fileURLWithPath: $0) }, report: report)
    exit(0)
}

var options = ProcessingOptions()
var files: [URL] = []
var target: FormatID?
var fileOperation: FileOperation?
func format(_ s: String) -> FormatID? { FormatID(rawValue: s.lowercased()) ?? FormatID.fromExtension(s) }
switch command {
case "convert":
    guard let f = args.first, let fmt = format(f) else { usage() }
    target = fmt
    fileOperation = .convert(fmt)
    args.removeFirst()
case "edit":
    guard let e = args.first else { usage() }
    let edits: [String: ImageEdit] = ["rotate-right": .rotateRight, "rotate-left": .rotateLeft, "flip-h": .flipH,
                                      "flip-v": .flipV, "grayscale": .toGrayscale, "cutout": .cutout]
    guard let edit = edits[e] else { usage() }
    fileOperation = .edit(edit)
    args.removeFirst()
case "pages", "long":
    guard let f = args.first, let fmt = format(f) else { usage() }
    fileOperation = command == "pages" ? .exportPages(fmt) : .longImage(fmt)
    args.removeFirst()
case "extract":
    guard let r = args.first else { usage() }
    fileOperation = .extractPages(r)
    args.removeFirst()
case "fit":
    guard let s = args.first, let limit = SizeTarget.parse(s) else { usage() }
    fileOperation = .fitSize(limit)
    args.removeFirst()
case "unpack": fileOperation = .unpack
case "split": fileOperation = .splitPDF
case "optimize": fileOperation = .optimize
case "clean": fileOperation = .stripMetadata
default: break
}
var i = 0
while i < args.count {
    let a = args[i]
    func value() -> String { i += 1; guard i < args.count else { usage() }; return args[i] }
    switch a {
    case "--mode": options.mode = CompressionMode(rawValue: value()) ?? { usage() }()
    case "--quality": options.qualityOverride = (Double(value()) ?? 80) / 100
    case "--max-size": options.maxPixelSize = Int(value())
    case "--keep-metadata": options.metadata = .keep
    case "--strip-all": options.metadata = .removeAll
    case "--only-smaller": options.discardLargerConversions = true
    case "--out": options.output = .folder(URL(fileURLWithPath: value(), isDirectory: true))
    case "--dpi": options.dpi = Int(value())
    case "--height": options.maxVideoHeight = Int(value())
    case "--codec": options.videoCodec = VideoCodecChoice(rawValue: value()) ?? .automatic
    case "--hardware": options.hardwareEncoding = true
    case "--fps": options.frameRate = Double(value())
    case "--mp3-bitrate": options.mp3Bitrate = Int(value())
    case "--name": options.nameTemplate = value()
    default: files.append(URL(fileURLWithPath: a))
    }
    i += 1
}

let registry = Engines.makeRegistry()
let analyzer = FileAnalyzer()

switch command {
case "formats":
    for e in registry.engines { print("\(e.id): optimizes \(e.optimizable.map(\.displayName).sorted().joined(separator: ", "))") }
    for f in FormatID.allCases where f != .any {
        let t = registry.targets(for: f)
        if !t.isEmpty { print("\(f.displayName) → \(t.map(\.preferredExtension).joined(separator: " "))") }
    }
    exit(0)
case "analyze":
    for f in files {
        let r = await analyzer.analyze(f)
        print("\(f.lastPathComponent): \(r.format?.displayName ?? "unknown") · \(bytes(r.byteSize))")
        if let img = r.image {
            print("  \(img.width)×\(img.height) · \(img.bitsPerComponent)-bit\(img.hasAlpha ? " · alpha" : "")\(img.estimatedJPEGQuality.map { " · quality ≈\($0)" } ?? "")\(img.hasGPS ? " · has location" : "")")
        }
        if let m = r.media {
            print("  \([m.videoCodec, m.audioCodec].compactMap { $0 }.joined(separator: " + ")) · \(m.duration.map { String(format: "%.1fs", $0) } ?? "")")
        }
        for rec in Advisor.recommendations(for: r, available: Set(registry.reachable(from: r.format ?? .any).keys)) { print("  • \(rec.message)") }
    }
    exit(0)
case "list":
    guard let f = files.first else { usage() }
    let r = await analyzer.analyze(f)
    let entries = try await UnpackEngine().list(f, format: r.format ?? .any)
    for e in entries { print("\(e.isDirectory ? "dir " : e.isLink ? "link" : "file")  \(e.size >= 0 ? bytes(e.size) : "?")\t\(e.path)") }
    let unsafe = entries.compactMap { UnpackEngine.problem(with: $0.path) }
    print("\(entries.count) entries · \(bytes(entries.reduce(0) { $0 + max(0, $1.size) })) unpacked" + (unsafe.isEmpty ? "" : " · UNSAFE: \(unsafe[0])"))
    exit(0)
case "optimize", "convert", "clean", "edit", "pages", "long", "extract", "split", "fit", "unpack": break
case "merge", "zip":
    guard !files.isEmpty else { usage() }
    let batch = BatchProcessor(workspace: try Workspace())
    var folder: URL?
    if case .folder(let f) = options.output { folder = f }
    let out = try await batch.run(command == "merge" ? .mergePDF : .zip, inputs: files, folder: folder)
    print("✓ \(files.count) files → \(out.lastPathComponent)  \(bytes(((try? FileManager.default.attributesOfItem(atPath: out.path))?[.size] as? NSNumber)?.int64Value ?? 0))")
    exit(0)
default: usage()
}

guard !files.isEmpty else { usage() }
let processor = try Processor(registry: registry, workspace: Workspace(), verifier: DefaultVerifier())
let queue = JobQueue(processor: processor)
let operation = fileOperation!
for f in files {
    let r = await analyzer.analyze(f)
    await queue.enqueue(Job(report: r, operation: operation, options: options))
}
await queue.waitUntilIdle()
var failed = 0
var saved: Int64 = 0
for job in await queue.allJobs {
    let name = job.report.url.lastPathComponent
    switch job.state {
    case .done(let r) where r.outcome == .written && !operation.measuresSavings:
        print("✓ \(name) → \(r.output!.lastPathComponent)  \(bytes(r.producedBytes)) unpacked (\(String(format: "%.2fs", r.duration)))")
    case .done(let r) where r.outcome == .written:
        saved += r.inputBytes - r.producedBytes
        print("✓ \(name) → \(r.output!.lastPathComponent)  \(bytes(r.inputBytes)) → \(bytes(r.producedBytes)) (\(String(format: "%+.1f%%", -r.savedFraction * 100)), \(String(format: "%.2fs", r.duration)))")
    case .done(let r) where operation.isFitSize:
        print("= \(name): already \(bytes(r.inputBytes)), under the limit; nothing to do")
    case .done(let r):
        print("= \(name): result was \(bytes(r.producedBytes)), not smaller than \(bytes(r.inputBytes)); original kept")
    case .failed(let e): failed += 1; print("✗ \(name): \(e)")
    default: failed += 1; print("✗ \(name): \(job.state)")
    }
}
if saved > 0 { print("Saved \(bytes(saved))") }
exit(failed == 0 ? 0 : 1)
