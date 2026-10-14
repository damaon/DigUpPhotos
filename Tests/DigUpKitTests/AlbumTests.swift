import Foundation
import Testing
@testable import DigUpKit

@Suite struct AlbumTests {
    private let homeLat = 52.23
    private let homeLon = 21.01

    @Test func weekLongTripStaysOneAlbum() {
        var photos: [AlbumPhoto] = []
        for day in 0..<8 {
            let quality = day == 3 ? 90 : 60
            photos.append(shot(Int64(day + 1), Double(day), quality: quality))
        }
        let albums = AlbumClusterer.albums(from: photos)
        #expect(albums.count == 1)
        #expect(albums[0].photos.map(\.id) == [1, 2, 3, 4, 5, 6, 7, 8])
        #expect(albums[0].featured == [4])
        #expect(albums[0].cover == 4)
    }

    @Test func twoDayGapSplitsAPlace() {
        let photos = [
            shot(1, 0), shot(2, 1),
            shot(3, 4), shot(4, 5),
        ]
        let albums = AlbumClusterer.albums(from: photos)
        #expect(albums.count == 2)
        let groups = Set(albums.map { Set($0.photos.map(\.id)) })
        #expect(groups == [Set([1, 2]), Set([3, 4])])
    }

    @Test func exactlyTwoDaysStillJoins() {
        #expect(AlbumClusterer.albums(from: [shot(1, 0), shot(2, 2)]).count == 1)
        let later = AlbumClusterer.albums(from: [shot(1, 0), shot(2, 2 + 1.0 / 24), shot(3, 2 + 2.0 / 24)])
        #expect(later.count == 1)
        #expect(later[0].photos.map(\.id) == [2, 3])
    }

    @Test func homeDoesNotBecomeOneAlbum() {
        var photos: [AlbumPhoto] = []
        for day in 0..<40 {
            photos.append(shot(Int64(day + 1), Double(day)))
        }
        let albums = AlbumClusterer.albums(from: photos)
        #expect(albums.count == 2)
        var total = 0
        for album in albums {
            total += album.photos.count
            #expect(album.end.timeIntervalSince(album.start) <= AlbumClusterer.maxSpan)
            #expect(album.photos.count < 40)
        }
        #expect(total == 40)
    }

    @Test func farPlacesStayApart() {
        let photos = [
            shot(1, 0), shot(2, 1),
            shot(3, 0, lat: 50.06, lon: 19.94),
            shot(4, 1, lat: 50.06, lon: 19.94),
        ]
        let albums = AlbumClusterer.albums(from: photos)
        #expect(albums.count == 2)
    }

    @Test func nearbyPhotosShareAPlace() {
        let photos = [shot(1, 0), shot(2, 1, lat: homeLat + 0.04, lon: homeLon)]
        #expect(AlbumClusterer.albums(from: photos).count == 1)
    }

    @Test func aSinglePhotoIsNotATrip() {
        #expect(AlbumClusterer.albums(from: [shot(1, 0)]).isEmpty)
    }

    @Test func photosStayInDateOrderAndNiceOnesAreFeatured() {
        let photos = [
            shot(1, 2, quality: 40),
            shot(2, 0, quality: 88),
            shot(3, 1, quality: 80),
            shot(4, 1.5, quality: 70),
        ]
        let album = AlbumClusterer.albums(from: photos)[0]
        #expect(album.photos.map(\.id) == [2, 3, 4, 1])
        #expect(album.featured == [2, 3])
        #expect(album.cover == 2)
    }

    @Test func unscoredTripUsesTheMiddlePhotoAsCover() {
        let photos = [shot(1, 0, quality: 0), shot(2, 1, quality: 0), shot(3, 2, quality: 0)]
        let album = AlbumClusterer.albums(from: photos)[0]
        #expect(album.featured.isEmpty)
        #expect(album.cover == 2)
    }

    @Test func missingLocationIsSkipped() {
        let missing = AlbumSourcePhoto(id: 1, path: "a.jpg", takenText: "2024:08:12 10:00:00",
                                       modified: Date(timeIntervalSince1970: 0),
                                       latitude: nil, longitude: nil, quality: 80)
        let located = AlbumSourcePhoto(id: 2, path: "b.jpg", takenText: nil,
                                       modified: Date(timeIntervalSince1970: 10_000),
                                       latitude: homeLat, longitude: homeLon, quality: 10)
        let build = AlbumClusterer.build([missing, located])
        #expect(build.skipped == 1)
        #expect(build.located == 1)
        #expect(build.albums.isEmpty)
    }

    @Test func tripOverlapsItsYearAndMonth() {
        let album = span(from: (2024, 8, 10), to: (2024, 8, 16))
        #expect(album.overlaps(year: 2024, month: 8))
        #expect(!album.overlaps(year: 2024, month: 7))
        #expect(album.overlaps(year: 2024))
        #expect(!album.overlaps(year: 2023))
    }

    @Test func tripAcrossNewYearOverlapsBothMonths() {
        let album = span(from: (2024, 12, 30), to: (2025, 1, 2))
        #expect(album.overlaps(year: 2024, month: 12))
        #expect(album.overlaps(year: 2025, month: 1))
        #expect(!album.overlaps(year: 2024, month: 11))
        #expect(album.overlaps(year: 2024))
        #expect(album.overlaps(year: 2025))
        #expect(!album.overlaps(year: 2026))
    }

    @Test func exifAndISODatesParse() {
        let exif = CaptureInfo.date(from: "2024:08:12 15:04:05")
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: exif!)
        #expect(parts.year == 2024)
        #expect(parts.month == 8)
        #expect(parts.day == 12)
        #expect(parts.hour == 15)
        #expect(parts.minute == 4)
        #expect(CaptureInfo.date(from: "2024-08-12T15:04:05Z") != nil)
        #expect(CaptureInfo.date(from: nil) == nil)
        #expect(CaptureInfo.date(from: "") == nil)
    }

    private func span(from start: (Int, Int, Int), to end: (Int, Int, Int)) -> Album {
        let calendar = Calendar.current
        func date(_ parts: (Int, Int, Int)) -> Date {
            calendar.date(from: DateComponents(year: parts.0, month: parts.1, day: parts.2, hour: 12))!
        }
        let first = date(start)
        let last = date(end)
        let photos = [
            AlbumPhoto(id: 1, path: "a.jpg", taken: first, latitude: 1, longitude: 1, quality: 1),
            AlbumPhoto(id: 2, path: "b.jpg", taken: last, latitude: 1, longitude: 1, quality: 1),
        ]
        return Album(id: "span", photos: photos, latitude: 1, longitude: 1,
                     start: first, end: last, featured: [], cover: 1)
    }

    private func shot(_ id: Int64, _ day: Double, lat: Double? = nil, lon: Double? = nil,
                      quality: Int = 50) -> AlbumPhoto {
        AlbumPhoto(id: id, path: "\(id).jpg",
                   taken: Date(timeIntervalSince1970: day * 86400),
                   latitude: lat ?? homeLat, longitude: lon ?? homeLon, quality: quality)
    }
}
