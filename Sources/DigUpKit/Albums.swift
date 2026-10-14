import Foundation

/// A photo that can join a trip: it has a capture time and a place.
public struct AlbumPhoto: Sendable, Equatable, Identifiable {
    public let id: Int64
    public var path: String
    public var taken: Date
    public var latitude: Double
    public var longitude: Double
    /// Overall look score, 0…100. Zero means it has not been scored.
    public var quality: Int
    /// People recognized in this photo. Empty when faces were not looked up.
    public var people: Set<Int64>

    public init(id: Int64, path: String, taken: Date, latitude: Double, longitude: Double, quality: Int,
                people: Set<Int64> = []) {
        self.id = id
        self.path = path
        self.taken = taken
        self.latitude = latitude
        self.longitude = longitude
        self.quality = quality
        self.people = people
    }
}

/// One row from the index, before dates and missing places are resolved.
public struct AlbumSourcePhoto: Sendable, Equatable {
    public var id: Int64
    public var path: String
    /// EXIF or ISO-8601 capture time, when the file has one.
    public var takenText: String?
    public var modified: Date
    public var latitude: Double?
    public var longitude: Double?
    public var quality: Int

    public init(id: Int64, path: String, takenText: String?, modified: Date,
                latitude: Double?, longitude: Double?, quality: Int) {
        self.id = id
        self.path = path
        self.takenText = takenText
        self.modified = modified
        self.latitude = latitude
        self.longitude = longitude
        self.quality = quality
    }
}

/// A trip or outing: photos of the selected people, in one place, in date order.
public struct Album: Sendable, Equatable, Identifiable {
    public var id: String
    /// Date order, earliest first.
    public var photos: [AlbumPhoto]
    public var latitude: Double
    public var longitude: Double
    public var start: Date
    public var end: Date
    /// Highest-scoring photos, best first. Empty when nothing has a score.
    public var featured: [Int64]
    /// The photo to show as the cover: the best one, or the middle of the trip.
    public var cover: Int64

    public init(id: String, photos: [AlbumPhoto], latitude: Double, longitude: Double,
                start: Date, end: Date, featured: [Int64], cover: Int64) {
        self.id = id
        self.photos = photos
        self.latitude = latitude
        self.longitude = longitude
        self.start = start
        self.end = end
        self.featured = featured
        self.cover = cover
    }

    public var placeLabel: String { CaptureInfo.format(latitude: latitude, longitude: longitude) }

    public func photo(_ id: Int64) -> AlbumPhoto? { photos.first { $0.id == id } }

    /// Whether this trip touches `year`, or that month of `year` when `month` is set (1…12).
    /// A trip that runs across a boundary counts in both months.
    public func overlaps(year: Int, month: Int? = nil, calendar: Calendar = .current) -> Bool {
        let startParts = calendar.dateComponents([.year, .month], from: start)
        let endParts = calendar.dateComponents([.year, .month], from: end)
        guard let startYear = startParts.year, let startMonth = startParts.month,
              let endYear = endParts.year, let endMonth = endParts.month else { return false }
        let startIndex = startYear * 12 + (startMonth - 1)
        let endIndex = endYear * 12 + (endMonth - 1)
        if let month {
            let index = year * 12 + (month - 1)
            return index >= startIndex && index <= endIndex
        }
        return year * 12 + 11 >= startIndex && year * 12 <= endIndex
    }
}

public struct AlbumBuild: Sendable, Equatable {
    public var albums: [Album]
    /// Photos of the selected people that have no GPS, so they cannot join a place.
    public var skipped: Int
    public var located: Int

    public init(albums: [Album], skipped: Int, located: Int) {
        self.albums = albums
        self.skipped = skipped
        self.located = located
    }
}

/// Groups photos into trips.
///
/// A trip is one place (within `placeRadiusKm` of the first photo that seeded it). Photos join while each is at most
/// two days after the previous one, and the whole run stays within a month. A place you photograph every day — home —
/// therefore splits instead of becoming one album. Runs of a single photo are not trips.
public enum AlbumClusterer {
    public static let placeRadiusKm = 18.0
    public static let maxGap: TimeInterval = 2 * 24 * 60 * 60
    public static let maxSpan: TimeInterval = 31 * 24 * 60 * 60
    public static let minimumPhotos = 2
    /// Same threshold as the "Nice" label in the app.
    public static let niceScore = 75
    public static let maxFeatured = 8

    public static func build(_ sources: [AlbumSourcePhoto]) -> AlbumBuild {
        var ready: [AlbumPhoto] = []
        var skipped = 0
        for source in sources {
            guard let latitude = source.latitude, let longitude = source.longitude else {
                skipped += 1
                continue
            }
            let taken = CaptureInfo.date(from: source.takenText) ?? source.modified
            ready.append(AlbumPhoto(id: source.id, path: source.path, taken: taken,
                                    latitude: latitude, longitude: longitude, quality: source.quality))
        }
        return AlbumBuild(albums: albums(from: ready), skipped: skipped, located: ready.count)
    }

    /// Every photo from `candidates` that belongs to this trip: already in it, or taken on its days and within
    /// `placeRadiusKm` of its place. Date order.
    public static func photos(in album: Album, from candidates: [AlbumPhoto]) -> [AlbumPhoto] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: album.start)
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: album.end)) ?? album.end
        let members = Set(album.photos.map(\.id))
        var seen = Set<Int64>()
        var kept: [AlbumPhoto] = []
        for photo in candidates {
            guard seen.insert(photo.id).inserted else { continue }
            let during = photo.taken >= start && photo.taken < end
            let near = kilometers(album.latitude, album.longitude, photo.latitude, photo.longitude) <= placeRadiusKm
            guard members.contains(photo.id) || (during && near) else { continue }
            kept.append(photo)
        }
        for photo in album.photos where seen.insert(photo.id).inserted {
            kept.append(photo)
        }
        return kept.sorted { $0.taken == $1.taken ? $0.id < $1.id : $0.taken < $1.taken }
    }

    /// Newest trip first.
    public static func albums(from photos: [AlbumPhoto]) -> [Album] {
        places(of: photos)
            .flatMap(split)
            .map(makeAlbum)
            .sorted { $0.start == $1.start ? $0.id < $1.id : $0.start > $1.start }
    }

    /// Each photo joins the nearest existing place within `placeRadiusKm`, or seeds a new one. The seed stays put,
    /// so a drive across the country does not drag "home" along with it.
    private static func places(of photos: [AlbumPhoto]) -> [[AlbumPhoto]] {
        let ordered = photos.sorted { $0.taken == $1.taken ? $0.id < $1.id : $0.taken < $1.taken }
        var seeds: [(latitude: Double, longitude: Double)] = []
        var groups: [[AlbumPhoto]] = []
        for photo in ordered {
            var best: Int?
            var bestKm = placeRadiusKm
            for index in seeds.indices {
                let km = kilometers(seeds[index].latitude, seeds[index].longitude, photo.latitude, photo.longitude)
                if km <= placeRadiusKm, best == nil || km < bestKm {
                    bestKm = km
                    best = index
                }
            }
            if let best {
                groups[best].append(photo)
            } else {
                seeds.append((photo.latitude, photo.longitude))
                groups.append([photo])
            }
        }
        return groups
    }

    private static func split(_ photos: [AlbumPhoto]) -> [[AlbumPhoto]] {
        var runs: [[AlbumPhoto]] = []
        var run: [AlbumPhoto] = []
        for photo in photos {
            if let first = run.first, let last = run.last {
                let gap = photo.taken.timeIntervalSince(last.taken)
                let span = photo.taken.timeIntervalSince(first.taken)
                if gap > maxGap || span > maxSpan {
                    runs.append(run)
                    run = []
                }
            }
            run.append(photo)
        }
        if !run.isEmpty { runs.append(run) }
        return runs.filter { $0.count >= minimumPhotos }
    }

    private static func makeAlbum(_ photos: [AlbumPhoto]) -> Album {
        let latitude = photos.map(\.latitude).reduce(0, +) / Double(photos.count)
        let longitude = photos.map(\.longitude).reduce(0, +) / Double(photos.count)
        let nice = photos.filter { $0.quality >= niceScore }
            .sorted { $0.quality == $1.quality ? $0.taken < $1.taken : $0.quality > $1.quality }
        let featured: [Int64]
        if !nice.isEmpty {
            featured = nice.prefix(maxFeatured).map(\.id)
        } else if let best = photos.filter({ $0.quality > 0 }).max(by: { $0.quality < $1.quality }) {
            featured = [best.id]
        } else {
            featured = []
        }
        let cover = featured.first ?? photos[photos.count / 2].id
        let start = photos[0].taken
        return Album(id: "\(photos[0].id)-\(Int(start.timeIntervalSince1970))",
                     photos: photos, latitude: latitude, longitude: longitude,
                     start: start, end: photos[photos.count - 1].taken,
                     featured: featured, cover: cover)
    }

    private static func kilometers(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let radius = 6371.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * radius * asin(min(1, sqrt(a)))
    }
}

extension IndexStore {
    /// Photos that show any of `people`, with capture time, place, and look score when the index has them.
    public func albumPhotos(ofPeople people: Set<Int64>) throws -> [AlbumSourcePhoto] {
        guard !people.isEmpty else { return [] }
        let list = people.map(String.init).joined(separator: ",")
        var seen = Set<Int64>()
        var photos: [AlbumSourcePhoto] = []
        try db.query("""
            SELECT files.id, files.path, files.mtime,
                   json_extract(files.info, '$.taken'),
                   json_extract(files.info, '$.lat'),
                   json_extract(files.info, '$.lon'),
                   json_extract(files.info, '$.quality')
            FROM files
            JOIN faces ON faces.file = files.id
            WHERE files.kind = 'image' AND faces.person IN (\(list))
            """) { row in
            let id = row.int(0)
            guard seen.insert(id).inserted, let path = row.text(1) else { return }
            photos.append(AlbumSourcePhoto(
                id: id, path: path, takenText: row.text(3),
                modified: Date(timeIntervalSince1970: row.double(2)),
                latitude: row.text(4).flatMap(Double.init),
                longitude: row.text(5).flatMap(Double.init),
                quality: row.text(6).flatMap(Int.init) ?? 0))
        }
        return photos
    }

    /// Every indexed photo that has a location.
    public func locatedPhotos() throws -> [AlbumSourcePhoto] {
        var photos: [AlbumSourcePhoto] = []
        try db.query("""
            SELECT id, path, mtime,
                   json_extract(info, '$.taken'),
                   json_extract(info, '$.lat'),
                   json_extract(info, '$.lon'),
                   json_extract(info, '$.quality')
            FROM files
            WHERE kind = 'image'
              AND json_extract(info, '$.lat') IS NOT NULL
              AND json_extract(info, '$.lon') IS NOT NULL
            """) { row in
            guard let path = row.text(1),
                  let latitude = row.text(4).flatMap(Double.init),
                  let longitude = row.text(5).flatMap(Double.init) else { return }
            photos.append(AlbumSourcePhoto(
                id: row.int(0), path: path, takenText: row.text(3),
                modified: Date(timeIntervalSince1970: row.double(2)),
                latitude: latitude, longitude: longitude,
                quality: row.text(6).flatMap(Int.init) ?? 0))
        }
        return photos
    }

    /// People recognized in each of `files`.
    public func peopleByFile(_ files: Set<Int64>) throws -> [Int64: Set<Int64>] {
        guard !files.isEmpty else { return [:] }
        let list = files.map(String.init).joined(separator: ",")
        var map: [Int64: Set<Int64>] = [:]
        try db.query("""
            SELECT file, person FROM faces
            WHERE person IS NOT NULL AND file IN (\(list))
            """) { row in
            map[row.int(0), default: []].insert(row.int(1))
        }
        return map
    }
}
