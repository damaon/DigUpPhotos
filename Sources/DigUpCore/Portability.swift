import Foundation

// The few places where macOS and Linux (and later Windows) spell the same thing differently.

/// `autoreleasepool` where there is one (Objective-C's: what `body` autoreleased is freed when it returns), else just
/// `body`.
func drainingPool<T>(_ body: () throws -> T) rethrows -> T {
    #if canImport(ObjectiveC)
    try autoreleasepool(invoking: body)
    #else
    try body()
    #endif
}

/// When a file was last changed, in seconds since 1970, from `lstat`.
func modificationTime(_ info: stat) -> Double {
    #if os(macOS)
    Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
    #else
    Double(info.st_mtim.tv_sec) + Double(info.st_mtim.tv_nsec) / 1e9
    #endif
}

/// A placeholder whose bytes are in the cloud (iCloud's "Optimize Mac Storage", File Providers): reading it would
/// download it. Only macOS has them.
func isInTheCloud(_ info: stat, _ values: URLResourceValues?) -> Bool {
    #if os(macOS)
    let dataless = info.st_flags & 0x4000_0000 != 0  // SF_DATALESS
    return dataless || (values?.isUbiquitousItem == true && values?.ubiquitousItemDownloadingStatus != .current)
    #else
    false
    #endif
}

/// Where DigUp keeps its models and index: Application Support on macOS, the XDG data folder elsewhere
/// (`$XDG_DATA_HOME`, or ~/.local/share).
public let dataFolder: URL = {
    let home = FileManager.default.homeDirectoryForCurrentUser
    #if os(macOS)
    return home.appendingPathComponent("Library/Application Support/DigUpPhotos")
    #else
    let data = ProcessInfo.processInfo.environment["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : $0 }
    return (data.map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".local/share"))
        .appendingPathComponent("DigUpPhotos")
    #endif
}()
