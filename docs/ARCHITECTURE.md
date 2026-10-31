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
  DigUpPortable/  the same jobs on Linux and Windows: stb_image, libheif, YuNet + SFace on ONNX Runtime, ffmpeg, poppler
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

`DigUpCore` imports Foundation and nothing that only Apple ships. What needs a platform is one protocol in the core,
`MediaReading`, implemented in `DigUpApple` and `DigUpPortable`; the CLI picks one (`Sources/digup/Platform.swift`) and
hands it to the indexer.

| Job | Apple (`AppleMedia`) | Linux / Windows (`PortableMedia`) |
| --- | --- | --- |
| Decode and shrink a picture | ImageIO | stb_image, libheif |
| EXIF: capture date, place, orientation | ImageIO | `Exif` in the core |
| Faces and their vectors | Vision, SFace on Core ML | YuNet + SFace on ONNX Runtime |
| PDF pages: text and pictures | PDFKit | poppler-utils |
| Video frames, sound, capture date | AVFoundation | ffmpeg, ffprobe |
| Rich documents (docx, odt, rtf) | the Cocoa text system | `RichText` in the core (ZIP and DEFLATE included); .doc through antiword or catdoc |
| Text in pictures (OCR) | Vision | tesseract, when installed |
| Fast vector math (in the core) | Accelerate | plain loops (BLAS later) |

Search, people grouping, albums and dates never need one.

### The MCP server

`digup mcp` speaks MCP over stdio, so an agent can be pointed at it like any other command. Tools: `search`
(text, kinds, people, dates), `photos` (of people or a time), `people`, `status`. It searches the index the app
writes (it never indexes or edits it) and uses the same query encoder as `digup search`.

## Order

Each step lands as small commits that build and pass the tests on their own.

Done: 1 to 5 (2026-10-31). The CLI indexes and searches on Linux, and the tests run there (`scripts/linux-test.sh`,
CI). On the CPU, llama.cpp makes the reference vectors Metal makes. The same 29 files (JPEG, HEIC, video, sound, PDF,
text) indexed on both agree: every capture date; photos' vectors at cosine 0.986 to 0.998 (decoding and shrinking
differ a little); text and WAV at 1.000. Faces: on 160 photos of a real library, YuNet finds 213 faces where Vision
finds 216 (199 the same), SFace gives them vectors at cosine 0.94 (median) to what macOS gives, and the people agree
with macOS's at pair precision 0.98, recall 0.93. Against the library owner's own merges, Linux groups as well as macOS
(precision 0.844 vs 0.842, recall 0.377 vs 0.360). Word, OpenDocument and RTF files: on 383 of them
found on a Mac, `RichText` reads the same words as Cocoa in 371 (≥ 98%); the rest are old Apple RTFs in the Mac Roman code
page, where Cocoa guesses Central European letters by language. What `DigUpPortable` doesn't do yet: WebP and raw photos,
OCR without tesseract.

1. Vector math behind `#if canImport(Accelerate)`, with portable loops.
2. `digup mcp`: the MCP server on macOS, over the current core.
3. Platform protocols in the core; today's Apple code moves behind them into `DigUpApple`. `DigUpKit` becomes
   `DigUpCore`.
4. SQLite through a system-library target, so the core builds and is tested in a Linux container (CI). The CLI
   follows in step 5, with llama.cpp built for Linux.
5. `DigUpPortable`: image decoding (stb_image, libheif), EXIF in the core, faces (YuNet + SFace on ONNX Runtime), ffmpeg,
   poppler-utils, tesseract. Indexing works on Linux.
6. Windows: the same targets with the Windows toolchain; paths and file watching.
7. A UI beyond macOS: likely a local web page served by `digup serve`, so one UI covers Linux and Windows.
