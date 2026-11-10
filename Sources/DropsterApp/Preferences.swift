import Foundation
import AppKit
import Observation
import DropsterCore

/// User settings, persisted in UserDefaults.
@MainActor @Observable
final class Preferences {
    private let defaults = UserDefaults.standard

    var mode: CompressionMode { didSet { defaults.set(mode.rawValue, forKey: "mode") } }
    var metadata: MetadataPolicy { didSet { defaults.set(metadata.rawValue, forKey: "metadata") } }
    /// 0 = keep original dimensions.
    var maxPixelSize: Int { didSet { defaults.set(maxPixelSize, forKey: "maxPixelSize") } }
    var outputFolder: URL? { didSet { defaults.set(outputFolder?.path, forKey: "outputFolder") } }
    var startAutomatically: Bool { didSet { defaults.set(startAutomatically, forKey: "startAutomatically") } }
    var discardLargerConversions: Bool { didSet { defaults.set(discardLargerConversions, forKey: "discardLarger") } }
    var includeSubfolders: Bool { didSet { defaults.set(includeSubfolders, forKey: "includeSubfolders") } }
    var keepFileDates: Bool { didSet { defaults.set(keepFileDates, forKey: "keepFileDates") } }
    var nameTemplate: String { didSet { defaults.set(nameTemplate, forKey: "nameTemplate") } }

    // Clover
    var cloverOnDrag: Bool { didSet { defaults.set(cloverOnDrag, forKey: "cloverOnDrag"); onCloverChange?() } }
    var cloverModifier: CloverModifier { didSet { defaults.set(cloverModifier.rawValue, forKey: "cloverModifier"); onCloverChange?() } }
    var cloverShortcut: Bool { didSet { defaults.set(cloverShortcut, forKey: "cloverShortcut"); onCloverChange?() } }
    @ObservationIgnored var onCloverChange: (() -> Void)?

    init() {
        mode = CompressionMode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .balanced
        metadata = MetadataPolicy(rawValue: defaults.string(forKey: "metadata") ?? "") ?? .removePrivate
        maxPixelSize = defaults.integer(forKey: "maxPixelSize")
        outputFolder = defaults.string(forKey: "outputFolder").map { URL(fileURLWithPath: $0, isDirectory: true) }
        startAutomatically = defaults.object(forKey: "startAutomatically") as? Bool ?? true
        discardLargerConversions = defaults.bool(forKey: "discardLarger")
        includeSubfolders = defaults.object(forKey: "includeSubfolders") as? Bool ?? true
        keepFileDates = defaults.object(forKey: "keepFileDates") as? Bool ?? true
        nameTemplate = defaults.string(forKey: "nameTemplate") ?? ""
        cloverOnDrag = defaults.object(forKey: "cloverOnDrag") as? Bool ?? true
        cloverModifier = CloverModifier(rawValue: defaults.string(forKey: "cloverModifier") ?? "") ?? .option
        cloverShortcut = defaults.object(forKey: "cloverShortcut") as? Bool ?? true
    }

    var options: ProcessingOptions {
        ProcessingOptions(mode: mode, metadata: metadata, maxPixelSize: maxPixelSize > 0 ? maxPixelSize : nil,
                          output: outputFolder.map { .folder($0) } ?? .nextToOriginal,
                          discardLargerConversions: discardLargerConversions,
                          nameTemplate: nameTemplate.isEmpty ? nil : nameTemplate, keepFileDates: keepFileDates)
    }
}

/// The key held while dragging to summon the clover.
enum CloverModifier: String, CaseIterable {
    case option, control, shift

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .option: .option
        case .control: .control
        case .shift: .shift
        }
    }

    var symbol: String {
        switch self {
        case .option: "⌥ Option"
        case .control: "⌃ Control"
        case .shift: "⇧ Shift"
        }
    }
}
