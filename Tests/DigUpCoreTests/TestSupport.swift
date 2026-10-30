import DigUpCore

// What reads files in the tests that index real ones: Apple's frameworks on macOS, DigUpPortable elsewhere.
#if canImport(DigUpApple)
import DigUpApple
let testReader: any MediaReading = AppleMedia()
#else
import DigUpPortable
let testReader: any MediaReading = PortableMedia()
#endif
