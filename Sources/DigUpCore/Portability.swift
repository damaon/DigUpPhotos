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

/// What the crawler needs to know about a file, from `lstat` (Foundation's attributes on Windows, which has no inodes:
/// there `inode` is 0, and a moved file is indexed again rather than recognized).
struct FileFacts {
    var isRegular: Bool
    var size: Int64
    /// When it was last changed, in seconds since 1970.
    var mtime: Double
    var inode: UInt64
    var device: UInt64
    /// A placeholder whose bytes are in the cloud (iCloud's "Optimize Mac Storage", File Providers): reading it would
    /// download it. Only macOS has them.
    var inTheCloud = false

    init?(_ url: URL, _ values: URLResourceValues?) {
        #if os(Windows)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        isRegular = attributes[.type] as? FileAttributeType == .typeRegular
        size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        mtime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        inode = 0
        device = 0
        #else
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        isRegular = (info.st_mode & S_IFMT) == S_IFREG
        size = Int64(info.st_size)
        inode = UInt64(info.st_ino)
        device = UInt64(bitPattern: Int64(info.st_dev))
        #if os(macOS)
        mtime = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
        let dataless = info.st_flags & 0x4000_0000 != 0  // SF_DATALESS
        inTheCloud = dataless
            || (values?.isUbiquitousItem == true && values?.ubiquitousItemDownloadingStatus != .current)
        #else
        mtime = Double(info.st_mtim.tv_sec) + Double(info.st_mtim.tv_nsec) / 1e9
        #endif
        #endif
    }
}

/// Where DigUp keeps its models and index: Application Support on macOS, %LOCALAPPDATA% on Windows, the XDG data
/// folder elsewhere (`$XDG_DATA_HOME`, or ~/.local/share).
public let dataFolder: URL = {
    let home = FileManager.default.homeDirectoryForCurrentUser
    #if os(macOS)
    return home.appendingPathComponent("Library/Application Support/DigUpPhotos")
    #elseif os(Windows)
    let local = ProcessInfo.processInfo.environment["LOCALAPPDATA"].flatMap { $0.isEmpty ? nil : $0 }
    return (local.map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent("AppData/Local"))
        .appendingPathComponent("DigUpPhotos")
    #else
    let data = ProcessInfo.processInfo.environment["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : $0 }
    return (data.map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".local/share"))
        .appendingPathComponent("DigUpPhotos")
    #endif
}()
