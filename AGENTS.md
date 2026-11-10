# AGENTS

This repository is for DROPSTER, a privacy-first universal file conversion and compression application.

## Mission

Build a polished, native-feeling macOS application that can convert, optimize, and compress files locally with strong performance, safe file handling, and quality-first processing.

## Primary guidance

Read and follow `CLAUDE.md` as the canonical project specification.

Key requirements:

- local-only processing by default
- no mandatory cloud dependency
- native macOS-first UX
- modular architecture with UI separated from processing logic
- strong benchmarking and quality verification
- no fake or placeholder features

## Product focus

Prioritize:

- image, video, and audio conversion
- adaptive compression intelligence
- batch processing and workflows
- safe file analysis and metadata handling
- premium UX polish and accessibility

## Delivery standards

- implement features in phases
- do not block the UI with heavy work
- validate conversion and compression behavior with tests
- document limitations and feasible alternatives when required
- keep the project privacy-first and production-minded

## When in doubt

Prefer the most thoughtful production-grade implementation over a quick prototype. The workspace should stay aligned with the architecture goals in `CLAUDE.md`. See `docs/ARCHITECTURE.md` for the current module map.
