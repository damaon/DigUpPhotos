import Foundation
import ImageIO

/// When and where a photo or video was captured, for albums, places and timelines later.
public struct CaptureInfo: Sendable, Equatable {
    /// Camera or file creation time, as written (EXIF `YYYY:MM:DD HH:MM:SS`, or ISO-8601 from video).
    public var taken: String?
    public var latitude: Double?
    public var longitude: Double?

    public init(taken: String? = nil, latitude: Double? = nil, longitude: Double? = nil) {
        self.taken = taken
        self.latitude = latitude
        self.longitude = longitude
    }

    public var hasLocation: Bool { latitude != nil && longitude != nil }

    /// Compact coordinates for result details: "37.77°N 122.42°W".
    public var placeLabel: String? {
        guard let latitude, let longitude else { return nil }
        return Self.format(latitude: latitude, longitude: longitude)
    }

    /// Keys written into a file's `info` JSON.
    public func infoFields() -> [String: String] {
        var info: [String: String] = [:]
        if let taken { info["taken"] = taken }
        if let latitude { info["lat"] = String(format: "%.6f", latitude) }
        if let longitude { info["lon"] = String(format: "%.6f", longitude) }
        return info
    }

    public static func format(latitude: Double, longitude: Double) -> String {
        let ns = latitude >= 0 ? "N" : "S"
        let ew = longitude >= 0 ? "E" : "W"
        return String(format: "%.2f°%@ %.2f°%@", abs(latitude), ns, abs(longitude), ew)
    }

    /// GPS from ImageIO properties (`kCGImagePropertyGPSDictionary`).
    public static func gps(from properties: [CFString: Any]) -> (latitude: Double, longitude: Double)? {
        guard let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] else { return nil }
        let latValue = double(gps[kCGImagePropertyGPSLatitude])
        let lonValue = double(gps[kCGImagePropertyGPSLongitude])
        guard let latValue, let lonValue else { return nil }
        let latRef = (gps[kCGImagePropertyGPSLatitudeRef] as? String)?.uppercased() ?? "N"
        let lonRef = (gps[kCGImagePropertyGPSLongitudeRef] as? String)?.uppercased() ?? "E"
        let latitude = latRef == "S" ? -latValue : latValue
        let longitude = lonRef == "W" ? -lonValue : lonValue
        guard abs(latitude) <= 90, abs(longitude) <= 180 else { return nil }
        return (latitude, longitude)
    }

    /// ISO 6709 from QuickTime / iPhone video metadata, e.g. `+37.7749-122.4194/` or with altitude.
    public static func parseISO6709(_ text: String) -> (latitude: Double, longitude: Double)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = trimmed.range(of: #"^([+-]\d+(?:\.\d+)?)([+-]\d+(?:\.\d+)?)"#,
                                        options: .regularExpression) else { return nil }
        let body = String(trimmed[match])
        guard let split = body.dropFirst().firstIndex(where: { $0 == "+" || $0 == "-" }) else { return nil }
        guard let latitude = Double(body[..<split]), let longitude = Double(body[split...]) else { return nil }
        guard abs(latitude) <= 90, abs(longitude) <= 180 else { return nil }
        return (latitude, longitude)
    }

    private static func double(_ value: Any?) -> Double? {
        switch value {
        case let number as Double: number
        case let number as Float: Double(number)
        case let number as Int: Double(number)
        case let number as NSNumber: number.doubleValue
        default: nil
        }
    }
}
