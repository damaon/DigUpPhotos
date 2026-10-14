import AppKit
import DigUpKit
import Observation
import SwiftUI

/// Trips built from the people you pick: one place, at most two days between photos, never longer than a month.
final class AlbumsWindowController: NSObject, NSWindowDelegate {
    let albums: AlbumsModel
    private unowned let app: AppController
    private var window: NSWindow?

    init(app: AppController) {
        self.app = app
        albums = AlbumsModel(engine: app.engine)
        super.init()
    }

    var isVisible: Bool { window?.isVisible == true }

    func show() {
        let window = self.window ?? makeWindow()
        albums.refreshPeople()
        app.present(window)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 740),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Albums"
        window.minSize = NSSize(width: 880, height: 560)
        window.isReleasedWhenClosed = false
        window.delegate = self
        if UserDefaults.standard.string(forKey: "defaultsSuite") == nil {
            window.setFrameAutosaveName("DigUpPhotosAlbums")
        }
        window.contentView = NSHostingView(rootView: AlbumsView(albums: albums, app: app))
        if window.frame.origin == .zero { window.center() }
        self.window = window
        return window
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentView = nil
        window = nil
        app.windowClosed()
    }
}

@Observable
final class AlbumsModel {
    private(set) var people: [Person] = []
    private(set) var selected: Set<Int64> = []
    private(set) var albums: [Album] = []
    private(set) var skipped = 0
    private(set) var located = 0
    private(set) var loading = false
    /// Trips list, or the map of those same trips.
    var screen: AlbumScreen = .trips
    /// Year shown on the map. Nil until trips have loaded.
    var mapYear: Int?
    /// Month within `mapYear` (1…12). Nil is the whole year.
    var mapMonth: Int?
    var open: Album?
    var selectedPhoto: Int64?
    /// Coordinate key (`PlaceNames.key`) → "City, Country".
    private(set) var placeNames: [String: String] = [:]

    @ObservationIgnored private let engine: Engine
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var placeTask: Task<Void, Never>?

    init(engine: Engine) {
        self.engine = engine
    }

    func refreshPeople() {
        Task {
            let people = await engine.people()
            self.people = people
            selected.formIntersection(Set(people.map(\.id)))
            await reload()
        }
    }

    func toggle(_ id: Int64) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        open = nil
        selectedPhoto = nil
        albums = []
        skipped = 0
        located = 0
        loading = !selected.isEmpty
        Task { await reload() }
    }

    func clear() {
        selected.removeAll()
        open = nil
        selectedPhoto = nil
        albums = []
        skipped = 0
        located = 0
        loading = false
        generation += 1
    }

    func show(_ album: Album) {
        open = album
        selectedPhoto = album.cover
    }

    func closeAlbum() {
        open = nil
        selectedPhoto = nil
    }

    func placeLabel(for album: Album) -> String {
        placeNames[PlaceNames.key(album.latitude, album.longitude)] ?? album.placeLabel
    }

    private func reload() async {
        generation += 1
        let token = generation
        let people = selected
        guard !people.isEmpty else {
            albums = []
            skipped = 0
            located = 0
            loading = false
            return
        }
        loading = true
        let build = await engine.albums(ofPeople: people)
        guard token == generation else { return }
        albums = build.albums
        skipped = build.skipped
        located = build.located
        loading = false
        if let open {
            if let fresh = build.albums.first(where: { $0.id == open.id }) {
                self.open = fresh
                if let selectedPhoto, fresh.photo(selectedPhoto) == nil { self.selectedPhoto = fresh.cover }
            } else {
                self.open = nil
                selectedPhoto = nil
            }
        }
        syncMapPeriod()
        warmPlaces()
        log("albums: \(people.count) people, \(build.located) located, \(build.skipped) without a place, "
            + "\(build.albums.count) trips")
    }

    private func warmPlaces() {
        for album in albums {
            let key = PlaceNames.key(album.latitude, album.longitude)
            if let name = PlaceNames.shared.cached(album.latitude, album.longitude) {
                placeNames[key] = name
            }
        }
        placeTask?.cancel()
        let albums = self.albums
        placeTask = Task {
            await PlaceNames.shared.resolve(albums) { key, name in
                self.placeNames[key] = name
            }
        }
    }

    /// Years that contain a trip, oldest first.
    var tripYears: [Int] {
        let calendar = Calendar.current
        var years = Set<Int>()
        for album in albums {
            years.insert(calendar.component(.year, from: album.start))
            years.insert(calendar.component(.year, from: album.end))
        }
        return years.sorted()
    }

    /// Trips for the map's year, narrowed to `mapMonth` when one is chosen.
    var mapAlbums: [Album] {
        guard let mapYear else { return [] }
        return albums.filter { $0.overlaps(year: mapYear, month: mapMonth) }
    }

    func monthHasTrips(_ month: Int) -> Bool {
        guard let mapYear else { return false }
        return albums.contains { $0.overlaps(year: mapYear, month: month) }
    }

    func stepMapYear(by delta: Int) {
        let years = tripYears
        guard let mapYear, let index = years.firstIndex(of: mapYear) else { return }
        let next = index + delta
        guard years.indices.contains(next) else { return }
        let year = years[next]
        self.mapYear = year
        if let mapMonth, !albums.contains(where: { $0.overlaps(year: year, month: mapMonth) }) {
            self.mapMonth = nil
        }
    }

    func selectMapMonth(_ month: Int?) {
        mapMonth = month
    }

    private func syncMapPeriod() {
        let years = tripYears
        guard let latest = years.last else {
            mapYear = nil
            mapMonth = nil
            return
        }
        if let mapYear, years.contains(mapYear) { return }
        mapYear = latest
        mapMonth = nil
    }
}

enum AlbumScreen: String, CaseIterable {
    case trips, map

    var title: String {
        switch self {
        case .trips: "Trips"
        case .map: "Map"
        }
    }
}

struct AlbumsView: View {
    @Bindable var albums: AlbumsModel
    let app: AppController

    var body: some View {
        VStack(spacing: 0) {
            peopleBar
            Divider()
            Group {
                if let album = albums.open {
                    AlbumDetail(album: album, albums: albums)
                } else if albums.screen == .map {
                    mapContent
                } else {
                    tripList
                }
            }
        }
        .onExitCommand {
            if albums.open != nil { albums.closeAlbum() }
        }
        .onChange(of: albums.screen) { _, _ in
            albums.closeAlbum()
        }
    }

    private var peopleBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("People")
                    .font(.headline)
                Text("Photos of anyone you select.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Picker("View", selection: $albums.screen) {
                    ForEach(AlbumScreen.allCases, id: \.self) { screen in
                        Text(screen.title).tag(screen)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
                .labelsHidden()
                if !albums.selected.isEmpty {
                    Button("Clear", action: albums.clear)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            if albums.people.isEmpty {
                Text("No faces yet. Index photos, then name people in Settings.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(albums.people) { person in
                            FaceChip(person: person, selected: albums.selected.contains(person.id),
                                     engine: app.engine) {
                                albums.toggle(person.id)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    private var showsTrips: Bool {
        !albums.people.isEmpty && !albums.selected.isEmpty && !albums.albums.isEmpty
    }

    @ViewBuilder private var mapContent: some View {
        if showsTrips {
            AlbumMap(albums: albums)
        } else {
            waitingState
        }
    }

    @ViewBuilder private var tripList: some View {
        if showsTrips {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(albums.albums.count) \(albums.albums.count == 1 ? "trip" : "trips")")
                            .font(.title3.weight(.semibold))
                        Spacer()
                        Text("Same place · two days apart at most · a month at most")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if albums.skipped > 0 {
                        Text("\(albums.skipped) \(albums.skipped == 1 ? "photo has" : "photos have") no location, so \(albums.skipped == 1 ? "it isn’t" : "they aren’t") in a trip.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 360, maximum: 560), spacing: 16)], spacing: 16) {
                        ForEach(albums.albums) { album in
                            TripCard(album: album, place: albums.placeLabel(for: album)) { albums.show(album) }
                        }
                    }
                }
                .padding(22)
            }
        } else {
            waitingState
        }
    }

    @ViewBuilder private var waitingState: some View {
        if albums.people.isEmpty {
            AlbumEmpty(title: "No people yet", symbol: "person.crop.circle",
                       detail: "DigUpPhotos groups faces while it indexes. Name them in Settings, then pick them here.",
                       actionTitle: "People Settings") { app.showSettings(.people) }
        } else if albums.selected.isEmpty {
            AlbumEmpty(title: "Select people", symbol: "person.2",
                       detail: "Choose one or more faces. Their photos become a trip for each place: at most two days between photos, and never longer than a month, so home does not turn into one album.")
        } else if albums.loading {
            ProgressView("Finding trips…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            AlbumEmpty(title: "No trips", symbol: "map",
                       detail: albums.located == 0
                           ? "These photos have no location, so they can’t be grouped by place."
                           : "A trip needs at least two photos in the same place, at most two days apart.")
        }
    }
}

private struct FaceChip: View {
    let person: Person
    let selected: Bool
    let engine: Engine
    let action: () -> Void
    @State private var image: NSImage?

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    avatar
                        .frame(width: 64, height: 64)
                        .clipShape(Circle())
                        .overlay(Circle().strokeBorder(selected ? Brand.amber : Color.primary.opacity(0.12),
                                                       lineWidth: selected ? 3 : 1))
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Brand.amber)
                            .background(Circle().fill(.white).padding(1))
                            .offset(x: 22, y: 22)
                    }
                }
                .frame(width: 72, height: 72)
                Text(person.displayName)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                    .frame(width: 76)
                Text("\(person.photoCount)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .help(person.displayName)
        .accessibilityLabel(person.displayName)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .task(id: person.id) { await loadFace() }
    }

    @ViewBuilder private var avatar: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        } else {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.primary.opacity(0.06))
        }
    }

    private func loadFace() async {
        guard let face = await engine.exemplarFace(ofPerson: person.id),
              let image = NSImage(contentsOf: URL(fileURLWithPath: face.path)) else { return }
        self.image = FaceCrop.crop(image, box: face.box)
    }
}

private enum FaceCrop {
    /// Vision box (origin bottom-left) → a head-and-shoulders crop.
    static func crop(_ image: NSImage, box: CGRect) -> NSImage {
        guard box.width > 0.01, box.height > 0.01,
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        let width = CGFloat(cg.width), height = CGFloat(cg.height)
        var rect = CGRect(x: box.minX * width, y: (1 - box.maxY) * height,
                          width: box.width * width, height: box.height * height)
        rect = rect.insetBy(dx: -rect.width * 0.45, dy: -rect.height * 0.5)
        rect.origin.y -= rect.height * 0.06
        rect = rect.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard rect.width > 8, rect.height > 8, let cropped = cg.cropping(to: rect.integral) else { return image }
        return NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
    }
}

private struct TripCard: View {
    let album: Album
    let place: String
    let open: () -> Void

    private var cover: AlbumPhoto? { album.photo(album.cover) }

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 14) {
                coverPhoto
                VStack(alignment: .leading, spacing: 8) {
                    Text(AlbumText.title(album))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(place)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .help(album.placeLabel)
                    Text(AlbumText.meta(album))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    filmstrip
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 6)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 168, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.primary.opacity(0.04)))
        }
        .buttonStyle(.plain)
    }

    private var coverPhoto: some View {
        ZStack(alignment: .bottomLeading) {
            if let cover {
                ThumbnailView(url: URL(fileURLWithPath: cover.path), side: 148)
            }
            if album.featured.contains(album.cover) {
                Text("Best")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Brand.ember))
                    .padding(8)
            }
        }
    }

    private var filmstrip: some View {
        HStack(spacing: 4) {
            ForEach(album.photos.prefix(6)) { photo in
                ThumbnailView(url: URL(fileURLWithPath: photo.path), side: 36)
                    .overlay {
                        if album.featured.contains(photo.id) {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Brand.amber, lineWidth: 2)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if album.featured.contains(photo.id) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(Brand.ember)
                                .padding(2)
                        }
                    }
            }
            if album.photos.count > 6 {
                Text("+\(album.photos.count - 6)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
            }
        }
    }
}

private struct AlbumDetail: View {
    let album: Album
    @Bindable var albums: AlbumsModel

    private var photo: AlbumPhoto {
        album.photo(albums.selectedPhoto ?? album.cover) ?? album.photos[0]
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 128, maximum: 180), spacing: 12)]
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                header
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(album.photos) { item in
                            photoCell(item)
                        }
                    }
                    .padding(18)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            preview
                .frame(width: 300)
                .background(Color.primary.opacity(0.025))
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: albums.closeAlbum) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                Text(albums.screen == .map ? "Map" : "Trips")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(AlbumText.title(album))
                    .font(.title3.weight(.semibold))
                Text("\(albums.placeLabel(for: album)) · \(AlbumText.meta(album))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(album.placeLabel)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func photoCell(_ item: AlbumPhoto) -> some View {
        let url = URL(fileURLWithPath: item.path)
        let featured = album.featured.contains(item.id)
        let chosen = item.id == photo.id
        return VStack(spacing: 5) {
            ThumbnailView(url: url, side: 132)
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(featured ? Brand.amber : Color.clear, lineWidth: 2.5)
                }
                .overlay(alignment: .topLeading) {
                    if featured {
                        Image(systemName: "star.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(Circle().fill(Brand.ember))
                            .padding(6)
                    }
                }
            Text(AlbumText.day(item.taken))
                .font(.caption)
                .foregroundStyle(featured ? AnyShapeStyle(Brand.ember) : AnyShapeStyle(.secondary))
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(chosen ? Color.accentColor.opacity(0.12) : Color.clear))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .gesture(TapGesture(count: 2).onEnded { NSWorkspace.shared.open(url) })
        .simultaneousGesture(TapGesture().onEnded { albums.selectedPhoto = item.id })
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        .help(featured ? "Best · \(AlbumText.day(item.taken))" : AlbumText.day(item.taken))
    }

    private var preview: some View {
        let url = URL(fileURLWithPath: photo.path)
        let featured = album.featured.contains(photo.id)
        return VStack(alignment: .leading, spacing: 14) {
            ThumbnailView(url: url, side: 260)
                .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 4) {
                if featured {
                    Text("Best")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Brand.ember))
                }
                Text(photo.taken.formatted(date: .abbreviated, time: .shortened))
                    .font(.headline)
                Text(AlbumText.look(photo.quality))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text((url.path as NSString).lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                Button("Open") { NSWorkspace.shared.open(url) }
                    .keyboardShortcut(.defaultAction)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            .controlSize(.regular)
            Text("In date order. Starred photos scored highest.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(16)
    }
}

private struct AlbumEmpty: View {
    let title: String
    var symbol: String
    let detail: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Brand.gradient)
            Text(title)
                .font(.title3.weight(.semibold))
            Text(detail)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .padding(.top, 4)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum AlbumText {
    static func title(_ album: Album) -> String {
        let calendar = Calendar.current
        if calendar.isDate(album.start, inSameDayAs: album.end) {
            return album.start.formatted(date: .abbreviated, time: .omitted)
        }
        let sameMonth = calendar.component(.month, from: album.start) == calendar.component(.month, from: album.end)
            && calendar.component(.year, from: album.start) == calendar.component(.year, from: album.end)
        if sameMonth {
            let startDay = calendar.component(.day, from: album.start)
            let endDay = calendar.component(.day, from: album.end)
            let rest = album.end.formatted(.dateTime.month(.wide).year())
            return "\(startDay)–\(endDay) \(rest)"
        }
        let start = album.start.formatted(date: .abbreviated, time: .omitted)
        let end = album.end.formatted(date: .abbreviated, time: .omitted)
        return "\(start) – \(end)"
    }

    static func meta(_ album: Album) -> String {
        let days = daySpan(album)
        var text = "\(album.photos.count) photos · \(days) \(days == 1 ? "day" : "days")"
        if !album.featured.isEmpty {
            text += album.featured.count == 1 ? " · 1 best" : " · \(album.featured.count) best"
        }
        return text
    }

    static func look(_ score: Int) -> String {
        guard score > 0 else { return "Not scored" }
        let word: String
        switch score {
        case 75...: word = "Nice"
        case 50..<75: word = "OK"
        default: word = "Soft"
        }
        return "\(word) · \(score)"
    }

    static func day(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day())
    }

    private static func daySpan(_ album: Album) -> Int {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: album.start),
                                           to: calendar.startOfDay(for: album.end)).day ?? 0
        return max(1, days + 1)
    }
}
