import DigUpKit
import MapKit
import SwiftUI

/// The same trips as the list, on a map. Chevrons move by year; the month row narrows to one month.
struct AlbumMap: View {
    @Bindable var albums: AlbumsModel
    @State private var position: MapCameraPosition = .automatic
    @State private var selectedID: String?

    var body: some View {
        let pins = MapPins.make(from: albums.mapAlbums)
        let fitKey = pins.map(\.id).joined(separator: "|")
        ZStack {
            Map(position: $position, selection: $selectedID) {
                ForEach(pins) { pin in
                    Annotation(pin.label, coordinate: pin.coordinate, anchor: .bottom) {
                        MapPinMark(title: pin.badge, selected: selectedID == pin.id)
                            .help(pin.label)
                    }
                    .tag(pin.id)
                }
            }
            .mapStyle(.standard(elevation: .flat))
            .mapControls {
                MapCompass()
                MapZoomStepper()
            }

            VStack(spacing: 10) {
                periodBar
                Spacer(minLength: 0)
                    .allowsHitTesting(false)
                if pins.isEmpty {
                    Text("No trips in \(periodTitle)")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .allowsHitTesting(false)
                    Spacer(minLength: 0)
                        .allowsHitTesting(false)
                }
                if let pin = pins.first(where: { $0.id == selectedID }) {
                    MapPinCard(pin: pin, albums: albums) { selectedID = nil }
                }
            }
            .padding(16)
        }
        .onChange(of: fitKey, initial: true) { _, _ in
            selectedID = nil
            guard !pins.isEmpty else { return }
            withAnimation(.easeInOut(duration: 0.45)) {
                position = MapPins.camera(for: pins)
            }
        }
    }

    private var periodTitle: String {
        guard let year = albums.mapYear else { return "this period" }
        guard let month = albums.mapMonth,
              let date = Calendar.current.date(from: DateComponents(year: year, month: month, day: 1)) else {
            return String(year)
        }
        return date.formatted(.dateTime.month(.wide).year())
    }

    private var periodBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    albums.stepMapYear(by: -1)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .disabled(albums.mapYear == albums.tripYears.first)
                .help("Previous year")

                Text(periodTitle)
                    .font(.headline)
                    .monospacedDigit()
                    .frame(minWidth: 120)

                Button {
                    albums.stepMapYear(by: 1)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .disabled(albums.mapYear == albums.tripYears.last)
                .help("Next year")

                Spacer(minLength: 8)
                Text(tripCount)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                periodChip("All", on: albums.mapMonth == nil, enabled: true) {
                    albums.selectMapMonth(nil)
                }
                ForEach(1...12, id: \.self) { month in
                    periodChip(monthSymbol(month), on: albums.mapMonth == month,
                               enabled: albums.monthHasTrips(month)) {
                        albums.selectMapMonth(month)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: 760)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .frame(maxWidth: .infinity)
    }

    private var tripCount: String {
        let count = albums.mapAlbums.count
        return count == 1 ? "1 trip" : "\(count) trips"
    }

    private func monthSymbol(_ month: Int) -> String {
        let symbols = Calendar.current.shortMonthSymbols
        guard symbols.indices.contains(month - 1) else { return "\(month)" }
        return symbols[month - 1]
    }

    private func periodChip(_ title: String, on: Bool, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .foregroundStyle(on ? Color.white : Color.primary)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(on ? AnyShapeStyle(Brand.ember) : AnyShapeStyle(Color.primary.opacity(0.06)))
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(title == "All" ? "Whole year" : title)
    }
}

private struct MapPin: Identifiable {
    var id: String
    var albums: [Album]
    var latitude: Double
    var longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// One trip shows its month; several at the same place show how many.
    var badge: String {
        if albums.count > 1 { return "\(albums.count)" }
        return albums.first?.start.formatted(.dateTime.month(.abbreviated)) ?? ""
    }

    var label: String {
        if albums.count == 1, let album = albums.first { return AlbumText.title(album) }
        return "\(albums.count) trips"
    }
}

private enum MapPins {
    /// Home months land on nearly the same coordinates; stack them into one pin.
    static let radiusKm = 1.2

    static func make(from albums: [Album]) -> [MapPin] {
        var pins: [MapPin] = []
        for album in albums {
            if let index = pins.firstIndex(where: {
                kilometers($0.latitude, $0.longitude, album.latitude, album.longitude) <= radiusKm
            }) {
                pins[index].albums.append(album)
                pins[index].id = pins[index].albums.map(\.id).sorted().joined(separator: "+")
            } else {
                pins.append(MapPin(id: album.id, albums: [album],
                                   latitude: album.latitude, longitude: album.longitude))
            }
        }
        return pins
    }

    static func camera(for pins: [MapPin]) -> MapCameraPosition {
        guard let first = pins.first else { return .automatic }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for pin in pins {
            minLat = min(minLat, pin.latitude)
            maxLat = max(maxLat, pin.latitude)
            minLon = min(minLon, pin.longitude)
            maxLon = max(maxLon, pin.longitude)
        }
        let latPad = max((maxLat - minLat) * 0.45, 0.35)
        let lonPad = max((maxLon - minLon) * 0.45, 0.35)
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(latitudeDelta: (maxLat - minLat) + latPad,
                                    longitudeDelta: (maxLon - minLon) + lonPad)
        return .region(MKCoordinateRegion(center: center, span: span))
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

private struct MapPinMark: View {
    let title: String
    let selected: Bool

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Capsule().fill(selected ? Brand.ember : Brand.moss))
            PinStem()
                .fill(selected ? Brand.ember : Brand.moss)
                .frame(width: 12, height: 7)
        }
        .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
    }
}

private struct PinStem: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

private struct MapPinCard: View {
    let pin: MapPin
    @Bindable var albums: AlbumsModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(pin.albums.count == 1 ? AlbumText.title(pin.albums[0]) : "\(pin.albums.count) trips here")
                    .font(.headline)
                Spacer(minLength: 8)
                Button(action: close) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            Text(pin.albums[0].placeLabel)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if pin.albums.count == 1, let album = pin.albums.first {
                single(album)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(pin.albums) { album in
                            tripRow(album)
                        }
                    }
                }
                .frame(maxHeight: 240)
            }
        }
        .padding(14)
        .frame(maxWidth: 480)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 16, y: 6)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func single(_ album: Album) -> some View {
        let path = album.photo(album.cover)?.path ?? album.photos[0].path
        return HStack(spacing: 12) {
            ThumbnailView(url: URL(fileURLWithPath: path), side: 72)
            VStack(alignment: .leading, spacing: 6) {
                Text(AlbumText.meta(album))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Open trip") { albums.show(album) }
            }
            Spacer(minLength: 0)
        }
    }

    private func tripRow(_ album: Album) -> some View {
        let path = album.photo(album.cover)?.path ?? album.photos[0].path
        return Button {
            albums.show(album)
        } label: {
            HStack(spacing: 10) {
                ThumbnailView(url: URL(fileURLWithPath: path), side: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(AlbumText.title(album))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(AlbumText.meta(album))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}
