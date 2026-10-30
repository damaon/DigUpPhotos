import CoreLocation
import DigUpCore
import Foundation

/// Reverse-geocoded names for trip coordinates. One lookup per neighborhood, remembered on disk.
@MainActor
final class PlaceNames {
    static let shared = PlaceNames()

    private var names: [String: String] = [:]
    private var generation = 0
    private let geocoder = CLGeocoder()
    private let file = AppSettings.supportDirectory.appendingPathComponent("places.json")

    private init() { load() }

    static func key(_ latitude: Double, _ longitude: Double) -> String {
        String(format: "%.2f,%.2f", latitude, longitude)
    }

    func cached(_ latitude: Double, _ longitude: Double) -> String? {
        names[Self.key(latitude, longitude)]
    }

    /// Fills `store` as each place is known. A newer call cancels the one still running.
    func resolve(_ albums: [Album], store: @MainActor (String, String) -> Void) async {
        generation += 1
        let token = generation
        geocoder.cancelGeocode()
        var seen = Set<String>()
        for album in albums {
            guard token == generation, !Task.isCancelled else { return }
            let key = Self.key(album.latitude, album.longitude)
            guard seen.insert(key).inserted else { continue }
            if let name = names[key] {
                store(key, name)
                continue
            }
            guard let name = await fetch(album.latitude, album.longitude), token == generation else { continue }
            names[key] = name
            persist()
            store(key, name)
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private func fetch(_ latitude: Double, _ longitude: Double) async -> String? {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        do {
            let marks = try await geocoder.reverseGeocodeLocation(location)
            guard let mark = marks.first else { return nil }
            return CaptureInfo.placeLine(locality: mark.locality, area: mark.administrativeArea, country: mark.country)
        } catch {
            return nil
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: file),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        names = decoded
    }

    private func persist() {
        try? FileManager.default.createDirectory(at: AppSettings.supportDirectory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(names) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
