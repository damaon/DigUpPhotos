import Foundation

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

    /// "Kraków, Poland", or just the country when the city is missing. Nil when nothing was named.
    public static func placeLine(locality: String?, area: String?, country: String?) -> String? {
        func clean(_ text: String?) -> String? {
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return text
        }
        let locality = clean(locality)
        let area = clean(area)
        let country = clean(country)
        var parts: [String] = []
        if let locality {
            parts.append(locality)
        } else if let area, area != country {
            parts.append(area)
        }
        if let country, country != parts.last { parts.append(country) }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    public static func format(latitude: Double, longitude: Double) -> String {
        let ns = latitude >= 0 ? "N" : "S"
        let ew = longitude >= 0 ? "E" : "W"
        return String(format: "%.2f°%@ %.2f°%@", abs(latitude), ns, abs(longitude), ew)
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

    /// EXIF `YYYY:MM:DD HH:MM:SS`, or ISO-8601 from video metadata.
    public static func date(from text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        if let date = ISO8601DateFormatter().date(from: text) { return date }
        let parts = text.split(separator: " ")
        guard parts.count == 2 else { return nil }
        let day = parts[0].split(separator: ":")
        let time = parts[1].split(separator: ":")
        guard day.count == 3, time.count >= 2,
              let year = Int(day[0]), let month = Int(day[1]), let dayOfMonth = Int(day[2]),
              let hour = Int(time[0]), let minute = Int(time[1]) else { return nil }
        let second = time.count > 2 ? Int(time[2]) ?? 0 : 0
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = dayOfMonth
        components.hour = hour
        components.minute = minute
        components.second = second
        return Calendar.current.date(from: components)
    }
}
