# Contributing

## Setup

```sh
brew install ffmpeg webp zstd xz brotli
swift build
swift test
./scripts/build-app.sh && ./scripts/e2e.sh   # every operation + the clover in the real app
```

Integration tests that need an optional tool are skipped when it isn't installed.

## Rules

Read [CLAUDE.md](CLAUDE.md) first. In particular:

- **No placeholder UI.** A control appears only if it works on this machine.
- **No unmeasured claims.** Changing a quality default needs before/after numbers from
  `dropster-cli bench` / `dropster-cli ssim`, recorded in `docs/BENCHMARKS.md`.
- **Never touch originals.** Write into the job workspace; let `Processor` commit.
- **Keep processing out of the UI target.** Engines and core must not import SwiftUI.
- **Tests with every change**: unit tests in `Tests/DropsterCoreTests` (fake engines),
  real-codec tests in `Tests/DropsterEnginesTests`. Lossless paths must be proven lossless.

## Adding an engine

1. Implement `Engine` in `Sources/DropsterEngines`. Build tool arguments as arrays.
2. Register it in `Engines.available()`.
3. Add argument tests (pure) and at least one end-to-end test.
4. Document settings and measurements.

## Pull requests

Describe what changed, how you verified it, and any measured effect on size, quality or speed.
