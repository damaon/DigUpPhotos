# Architecture

DigUpPhotos is one search engine with several ways in: the macOS app, a command-line tool, and an MCP server
that AI agents can use. It's meant to run on macOS, Linux and Windows. This page is the target layout and the
order of getting there.

## One repository, one Swift package

```
Package.swift
Sources/
  DigUpCore/      the engine: crawler, index store (SQLite), search, people, albums, dates. Foundation only.
  DigUpApple/     what only Apple's frameworks do: Vision faces, Core ML (SFace), ImageIO, PDFKit, AVFoundation
  DigUpPortable/  the same jobs on Linux and Windows: ONNX Runtime (YuNet + SFace), libheif/stb, FFmpeg, Poppler
  CLlama/         llama.cpp, built by scripts/build-llama.sh (macOS, Linux and Windows alike)
  LlamaRuntime/   EmbeddingGemma 2 on llama.cpp: text, image and audio vectors
  digup/          the CLI: index, search, people, status, eval, and `digup mcp`
  DigUpApp/       the macOS menubar app (SwiftUI)
Tests/
```

Why Swift and one package rather than a rewrite: the engine is about 6,000 lines of tested Swift, and Swift 6
builds for Linux and Windows. What ties it to macOS is a short list of system frameworks in a few files, not the
language. One `Package.swift` keeps every part building against the same core in one `swift build`; a future
non-Swift UI (a web page the CLI serves, say) would sit next to it in `apps/`.

### The rule for the core

`DigUpCore` imports Foundation and nothing that only Apple ships. What needs a platform is a protocol in the core,
implemented in `DigUpApple` and `DigUpPortable`:

| Job | Protocol (core) | Apple | Linux / Windows |
| --- | --- | --- | --- |
| Decode and shrink a picture, read EXIF | `ImageReading` | ImageIO | libheif + stb_image |
| Find faces and their landmarks | `FaceFinding` | Vision | YuNet (ONNX Runtime) |
| Face vectors | `FaceRecognizing` | SFace on Core ML | SFace on ONNX Runtime |
| PDF pages: text and pictures | `DocumentReading` | PDFKit | Poppler |
| Video frames, sound, capture date | `MediaReading` | AVFoundation | FFmpeg |
| Text in pictures (OCR) | `TextRecognizing` | Vision | Tesseract, or none |
| Fast vector math | `#if canImport(Accelerate)` | Accelerate | plain loops (BLAS later) |

The CLI and the app pick the platform once (`Platform.apple`, `Platform.portable`) and hand it to the indexer.
Search, people grouping, albums and dates never need one.

### The MCP server

`digup mcp` speaks MCP over stdio, so an agent can be pointed at it like any other command. Tools: `search`
(text, kinds, people, dates), `photos` (of people or a time), `people`, `status`. It opens the same index the app
writes, read-only, and uses the same query encoder as `digup search`.

## Order

Each step lands as small commits that build and pass the tests on their own.

Done: 1 to 4 (2026-10-30). The core and its tests build on Linux (`scripts/linux-test.sh`, CI); the tests that
index real files wait for a Linux `MediaReading`.

1. Vector math behind `#if canImport(Accelerate)`, with portable loops.
2. `digup mcp`: the MCP server on macOS, over the current core.
3. Platform protocols in the core; today's Apple code moves behind them into `DigUpApple`. `DigUpKit` becomes
   `DigUpCore`.
4. SQLite through a system-library target, so the core and the CLI build in a Linux container (CI).
5. `DigUpPortable`: ONNX Runtime faces, image decoding, FFmpeg. Indexing works on Linux.
6. Windows: the same targets with the Windows toolchain; paths and file watching.
7. A UI beyond macOS: likely a local web page served by `digup serve`, so one UI covers Linux and Windows.
