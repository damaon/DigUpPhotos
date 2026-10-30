#if canImport(DigUpApple)
import DigUpApple
import DigUpCore

/// What reads files in the tests that index real ones: Apple's frameworks on macOS. Elsewhere those tests wait for a
/// MediaReading of that platform (docs/ARCHITECTURE.md).
let testReader: any MediaReading = AppleMedia()
#endif
