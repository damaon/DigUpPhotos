import DigUpCore

// What reads files for indexing: Apple's frameworks on macOS; stb_image, libheif, ffmpeg and poppler elsewhere.
#if canImport(DigUpApple)
import DigUpApple
let mediaReader: any MediaReading = AppleMedia()
#else
import DigUpPortable
let mediaReader: any MediaReading = PortableMedia()
#endif
