import DigUpCore
import Foundation
import ImageIO

extension CaptureInfo {
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
