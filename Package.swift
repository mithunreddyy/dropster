// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Dropster",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Dropster", targets: ["DropsterApp"]),
        .executable(name: "dropster-cli", targets: ["dropster-cli"]),
        .library(name: "DropsterCore", targets: ["DropsterCore"]),
        .library(name: "DropsterEngines", targets: ["DropsterEngines"]),
    ],
    targets: [
        .target(name: "DropsterCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "DropsterEngines", dependencies: ["DropsterCore"]),
        .executableTarget(name: "DropsterApp", dependencies: ["DropsterCore", "DropsterEngines"]),
        .executableTarget(name: "dropster-cli", dependencies: ["DropsterCore", "DropsterEngines"]),
        .testTarget(name: "DropsterCoreTests", dependencies: ["DropsterCore"]),
        .testTarget(name: "DropsterEnginesTests", dependencies: ["DropsterCore", "DropsterEngines"]),
    ]
)
