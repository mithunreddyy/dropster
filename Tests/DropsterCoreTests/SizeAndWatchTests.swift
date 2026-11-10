import Testing
import Foundation
@testable import DropsterCore

@Suite struct SizeTargetTests {
    @Test func parsesAndLabelsSizes() {
        #expect(SizeTarget.parse("10MB") == 10_000_000)
        #expect(SizeTarget.parse("2.5 mb") == 2_500_000)
        #expect(SizeTarget.parse("800k") == 800_000)
        #expect(SizeTarget.parse("1g") == 1_000_000_000)
        #expect(SizeTarget.parse("12345") == 12345)
        #expect(SizeTarget.parse("") == nil)
        #expect(SizeTarget.parse("-5MB") == nil)
        #expect(SizeTarget.parse("lots") == nil)
        #expect(SizeTarget.label(10_000_000) == "10 MB")
        #expect(SizeTarget.label(1_500_000) == "1.5 MB")
        #expect(SizeTarget.label(750_000) == "750 KB")
    }

    @Test func picksAnOutputFormatPerKind() {
        #expect(SizeTarget.outputFormat(source: .jpeg) == .jpeg)
        #expect(SizeTarget.outputFormat(source: .heic) == .heic)
        #expect(SizeTarget.outputFormat(source: .png) == .jpeg)
        #expect(SizeTarget.outputFormat(source: .mov) == .mp4)
        #expect(SizeTarget.outputFormat(source: .wav) == .m4a)
        #expect(SizeTarget.outputFormat(source: .mp3) == .mp3)
        #expect(FileOperation.fitSize(5_000_000).outputFormat(source: .tiff) == .jpeg)
        #expect(FileOperation.unpack.producesFolder)
        #expect(!FileOperation.unpack.measuresSavings)
    }

    @Test func outputNames() throws {
        let src = URL(fileURLWithPath: "/tmp/dropster-names-\(UUID().uuidString)/photo.png")
        let fit = try OutputPlanner.destination(for: src, target: .jpeg, operation: .fitSize(5_000_000), location: .nextToOriginal)
        #expect(fit.lastPathComponent == "photo-5MB.jpg")
        let tgz = URL(fileURLWithPath: "/tmp/dropster-names-\(UUID().uuidString)/backup.tar.gz")
        let unpacked = try OutputPlanner.destination(for: tgz, target: .any, operation: .unpack, location: .nextToOriginal)
        #expect(unpacked.lastPathComponent == "backup")
    }

    @Test func operationsRoundTripThroughJSON() throws {
        for op in [FileOperation.fitSize(25_000_000), .unpack] {
            let data = try JSONEncoder().encode(op)
            #expect(try JSONDecoder().decode(FileOperation.self, from: data) == op)
        }
    }

    @Test func detectsTarBySignature() {
        var header = [UInt8](repeating: 0, count: 512)
        header.replaceSubrange(257..<262, with: Array("ustar".utf8))
        #expect(FileSignature.detect(header) == .tar)
    }
}

@Suite struct ArrivalTrackerTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func waitsUntilAFileStopsGrowing() {
        var t = ArrivalTracker(known: [], settleTime: 1)
        let d = Date(timeIntervalSince1970: 5)
        #expect(t.scan([ScannedFile(name: "a.jpg", size: 100, modified: d)], at: t0).isEmpty)
        #expect(t.hasPending)
        // Still growing: the clock restarts.
        #expect(t.scan([ScannedFile(name: "a.jpg", size: 200, modified: d)], at: t0 + 2).isEmpty)
        #expect(t.scan([ScannedFile(name: "a.jpg", size: 200, modified: d)], at: t0 + 2.5).isEmpty, "not settled long enough")
        #expect(t.scan([ScannedFile(name: "a.jpg", size: 200, modified: d)], at: t0 + 3.1) == ["a.jpg"])
        // Handed out once only.
        #expect(t.scan([ScannedFile(name: "a.jpg", size: 200, modified: d)], at: t0 + 9).isEmpty)
        #expect(!t.hasPending)
    }

    @Test func ignoresKnownHiddenAndPartialFiles() {
        var t = ArrivalTracker(known: ["old.png"], settleTime: 0)
        let d = Date()
        let files = ["old.png", ".DS_Store", "movie.mp4.crdownload", "clip.part", "~$doc.docx", "new.png"].map { ScannedFile(name: $0, size: 10, modified: d) }
        _ = t.scan(files, at: t0)
        #expect(t.scan(files, at: t0 + 1) == ["new.png"])
    }

    @Test func emptyFilesWaitAndRemovedFilesAreForgotten() {
        var t = ArrivalTracker(known: [], settleTime: 0)
        let d = Date()
        _ = t.scan([ScannedFile(name: "x.txt", size: 0, modified: d)], at: t0)
        #expect(t.scan([ScannedFile(name: "x.txt", size: 0, modified: d)], at: t0 + 1).isEmpty, "an empty file is still being created")
        _ = t.scan([ScannedFile(name: "x.txt", size: 5, modified: d)], at: t0 + 2)
        #expect(t.scan([ScannedFile(name: "x.txt", size: 5, modified: d)], at: t0 + 3) == ["x.txt"])
        // Deleted, then a new file with the same name arrives: it is processed again.
        _ = t.scan([], at: t0 + 4)
        #expect(!t.known.contains("x.txt"))
        _ = t.scan([ScannedFile(name: "x.txt", size: 9, modified: d)], at: t0 + 5)
        #expect(t.scan([ScannedFile(name: "x.txt", size: 9, modified: d)], at: t0 + 6) == ["x.txt"])
    }

    @Test func storePersistsRules() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("watch.json")
        let store = WatchStore(url: url)
        let rule = WatchRule(folder: dir, operation: .fitSize(1_000_000), known: ["a"])
        store.save(rule)
        let again = WatchStore(url: url)
        #expect(again.all == [rule])
        again.delete(rule.id)
        #expect(WatchStore(url: url).all.isEmpty)
        #expect(rule.outputFolder.lastPathComponent == "Dropster")
    }
}
