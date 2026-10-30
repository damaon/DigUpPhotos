import AppKit
import DigUpKit
import Observation
import Quartz
import SwiftUI

/// The search window, for the searches the panel is too small for: a big field, kind filters with counts, the results
/// as a grid of pictures, and the selected one in a preview pane with why it matched. The Dock icon shows while it's
/// open, and closing it frees its views (the app goes back to its idle size).
final class SearchWindowController: NSObject, NSWindowDelegate {
    let search: SearchModel
    private unowned let app: AppController
    private var window: QuickLookWindow?
    private var keyMonitor: Any?
    private var mouseMonitor: Any?

    init(app: AppController) {
        self.app = app
        search = SearchModel(engine: app.engine)
    }

    var isVisible: Bool { window?.isVisible == true }

    func show(query: String? = nil, kind: ResultGroupKind? = nil) {
        let window = self.window ?? makeWindow()
        if let query {
            search.filter = kind
            search.query = query
        }
        search.refreshPeople()
        search.refreshMonths()
        app.present(window)
        if !AppController.offscreen { window.makeFirstResponder(search.field) }
        installKeyMonitor()
    }

    func close() {
        window?.close()
    }

    private func makeWindow() -> QuickLookWindow {
        let window = QuickLookWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700),
                                     styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                     backing: .buffered, defer: false)
        // An empty unified toolbar makes the title bar tall enough for the search field to sit beside the window
        // buttons.
        window.toolbar = NSToolbar(identifier: "DigUpPhotosSearch")
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "DigUpPhotos"
        window.minSize = NSSize(width: 820, height: 520)
        window.isReleasedWhenClosed = false
        window.delegate = self
        // The frame is remembered in the app's real defaults, so dev runs (their own -defaultsSuite) don't keep it.
        if UserDefaults.standard.string(forKey: "defaultsSuite") == nil {
            window.setFrameAutosaveName("DigUpPhotosSearchWindow")
        }
        window.contentView = NSHostingView(rootView: SearchWindowView(search: search, model: app.model, app: app))
        if window.frame.origin == .zero { window.center() }
        self.window = window
        return window
    }

    func windowWillClose(_ notification: Notification) {
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().orderOut(nil)
        }
        removeKeyMonitor()
        PreviewPlayback.shared.stop()
        window?.contentView = nil
        window = nil
        app.windowClosed()
    }

    func snapshot(to url: URL) throws {
        try Snapshot.write(window, to: url)
    }

    // MARK: Keys

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window else { return event }
            // Keys typed here, or in Quick Look while this window is the one showing it (not the panel's).
            let previewing = QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
                && event.window === QLPreviewPanel.shared() && QLPreviewPanel.shared().dataSource === window
            guard event.window === window || previewing else { return event }
            return handle(event) ? nil : event
        }
        // A click back in the search field: Space and ← → type again (after a click on a result, they were its).
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, let window, event.window === window, let field = search.field else { return event }
            if field.bounds.contains(field.convert(event.locationInWindow, from: nil)) { search.editing() }
            return event
        }
    }

    private func removeKeyMonitor() {
        for monitor in [keyMonitor, mouseMonitor].compactMap({ $0 }) { NSEvent.removeMonitor(monitor) }
        keyMonitor = nil
        mouseMonitor = nil
    }

    /// Arrows move through the grid (← → only once you've arrowed, so they still move the cursor while you type),
    /// ↩ opens, ⌘↩ reveals, Space previews, ⌘C copies, Esc closes the preview or clears the search.
    private func handle(_ event: NSEvent) -> Bool {
        // An input method is composing (Japanese, Chinese…): ↩, the arrows and Esc are its keys until it's done.
        if (search.field?.currentEditor() as? NSTextView)?.hasMarkedText() == true { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        let previewing = QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
        switch event.keyCode {
        case 125, 126:   // ↓ ↑
            guard modifiers.isEmpty else { return false }
            search.move(by: event.keyCode == 125 ? search.columns : -search.columns)
        case 123, 124:   // ← →
            guard modifiers.isEmpty, search.navigated || previewing else { return false }
            search.move(by: event.keyCode == 124 ? 1 : -1)
        case 36, 76:   // ↩
            guard let row = search.selectedRow else { return false }
            if modifiers == .command {
                NSWorkspace.shared.activateFileViewerSelecting([row.url])
            } else if modifiers.isEmpty {
                search.open(row)
            } else {
                return false
            }
        case 49 where modifiers.isEmpty && (search.navigated || previewing) && search.selectedRow != nil:   // Space
            toggleQuickLook()
        case 16 where modifiers == .command:   // ⌘Y
            toggleQuickLook()
        case 18...23 where modifiers == .command:   // ⌘1 all, ⌘2… kinds (photos/video by default)
            let chips = ResultGroupKind.files(photosAndVideoOnly: app.model.settings.photosAndVideoOnly)
            let kinds: [ResultGroupKind?] = [nil] + chips
            let index = [18, 19, 20, 21, 23, 22].firstIndex(of: Int(event.keyCode)) ?? 0   // key codes of 1…6
            guard index < kinds.count else { return false }
            search.filter = kinds[index]
        case 8 where modifiers == .command && search.navigated:   // ⌘C
            guard let row = search.selectedRow else { return false }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([row.url as NSURL])
        case 53:   // Esc
            if previewing {
                QLPreviewPanel.shared().orderOut(nil)
            } else if !search.query.isEmpty {
                search.query = ""
            } else if !search.peopleFilter.isEmpty || search.dateFilter != nil {
                search.peopleFilter = []   // then back to the start
                search.dateFilter = nil
            } else {
                return false
            }
        default:
            return false
        }
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { updateQuickLook() }
        return true
    }

    func toggleQuickLook() {
        let panel = QLPreviewPanel.shared()!
        if QLPreviewPanel.sharedPreviewPanelExists(), panel.isVisible {
            panel.orderOut(nil)
        } else if search.selectedRow != nil {
            updateQuickLook()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Quick Look shows the selected result at its page or moment.
    private func updateQuickLook() {
        window?.previewURL = search.selectedRow?.url
        QLPreviewPanel.shared().reloadData()
        QuickLookMoment.show(search.selectedRow, in: QLPreviewPanel.shared())
    }
}

/// A window that hands Quick Look the selected file (Space / ⌘Y).
final class QuickLookWindow: NSWindow, QLPreviewPanelDataSource {
    var previewURL: URL?

    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = self }
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = nil }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURL == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        previewURL as NSURL?
    }
}

/// The window's query: keyword and meaning results together after a short pause in typing, optionally of one kind.
@Observable
final class SearchModel {
    var query = "" {
        didSet { if query != oldValue { run() } }
    }
    var filter: ResultGroupKind? {
        didSet { if filter != oldValue { run() } }
    }
    /// People to require on each photo (AND when more than one). Empty means no people filter. With nothing typed,
    /// all their photos are shown (`browsingPeople`); typed words search among them.
    var peopleFilter: Set<Int64> = [] {
        didSet { if peopleFilter != oldValue { run() } }
    }
    /// The time picked in the date menu. Nil: any time, or the time the query names ("beach 2023", `typedDates`).
    var dateFilter: DateSpan? {
        didSet { if dateFilter != oldValue { run() } }
    }
    /// The time the typed words name, when no date is picked: it filters, and the rest of the words are searched for.
    var typedDates: (span: DateSpan, rest: String)? {
        dateFilter == nil ? DateSpan.parse(query.trimmingCharacters(in: .whitespacesAndNewlines)) : nil
    }
    /// What results are limited to: the picked time, else the typed one.
    var dates: DateSpan? { dateFilter ?? typedDates?.span }
    /// The words searched for: the query without the time it names.
    private var words: String {
        (typedDates?.rest ?? query).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// People or a time picked and nothing else typed: their photos, newest first, rather than search results.
    var browsing: Bool { words.isEmpty && (!peopleFilter.isEmpty || dates != nil) }
    var browsingPeople: Bool { browsing && !peopleFilter.isEmpty }
    /// Photos and videos per year and month, for the date menu.
    private(set) var months: [Int: [Int: Int]] = [:]
    private(set) var people: [Person] = []
    private(set) var results = ResultSet.empty
    /// Results per kind for the query, whatever the filter (the counts on the kind buttons).
    private(set) var counts: [ResultGroupKind: Int] = [:]
    private(set) var hasResults = false
    /// Luna's formal line, when it differs from `query`.
    private(set) var interpreted: String?
    /// Why that line was not searched, or why OpenRouter refused.
    private(set) var rewriteNote: String?
    private(set) var interpreting = false
    var selection: String?
    var showWeaker = false
    var showsPreview = true
    /// "Copied N paths", for a moment after the file list goes to the clipboard.
    private(set) var listNote: String?
    @ObservationIgnored private var listNoteTask: Task<Void, Never>?
    /// You moved the selection with the arrow keys since the last edit: Space and ← → act on results then.
    private(set) var navigated = false
    /// The grid's columns right now (↑ ↓ move by a row).
    var columns = 4
    @ObservationIgnored weak var field: NSTextField?
    @ObservationIgnored let engine: Engine
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var task: Task<Void, Never>?

    init(engine: Engine) {
        self.engine = engine
    }

    /// Runs the current query again after query understanding is switched.
    func research() {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        run()
    }

    func refreshMonths() {
        Task { months = await engine.photoMonths() }
    }

    func refreshPeople() {
        Task {
            let list = await engine.people()
            people = list
            // Drop filter ids that no longer exist (merged/removed).
            let known = Set(list.map(\.id))
            peopleFilter = peopleFilter.intersection(known)
        }
    }

    func togglePerson(_ id: Int64) {
        if peopleFilter.contains(id) { peopleFilter.remove(id) } else { peopleFilter.insert(id) }
    }

    /// Every result shown, in order (strong ones, then the weaker ones once they're unfolded).
    var rows: [ResultRow] { results.ranked + (showWeaker ? results.weaker : []) }

    var selectedRow: ResultRow? { rows.first { $0.id == selection } ?? rows.first }

    /// A click on a result: like the arrow keys, it makes Space and ← → act on the results.
    func select(_ row: ResultRow) {
        selection = row.id
        navigated = true
    }

    /// A click in the search field: keys are the text's again.
    func editing() {
        navigated = false
    }

    /// Puts the cursor in the search field (a click on the empty window lands there).
    func focusField() {
        guard let field, field.currentEditor() == nil else { return }
        field.window?.makeFirstResponder(field)
    }

    /// The file in its app, at the page or moment that matched when the app can be told where.
    func open(_ row: ResultRow) {
        engine.open(row)
    }

    func noteCopied(_ count: Int) {
        listNote = count == 1 ? "Copied 1 path" : "Copied \(count) paths"
        listNoteTask?.cancel()
        listNoteTask = Task {
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            listNote = nil
        }
    }

    func move(by step: Int) {
        let ids = rows.map(\.id)
        guard !ids.isEmpty else { return }
        let index = selection.flatMap { ids.firstIndex(of: $0) } ?? -1
        selection = ids[max(0, min(ids.count - 1, index + step))]
        navigated = true
    }

    /// All photos of the picked people taken in `dates` (`Engine.photos(of:)`), in the kind picked; no query to read
    /// or embed.
    private func browse(people: Set<Int64>, dates: DateSpan?, generation current: Int) {
        interpreted = nil
        rewriteNote = nil
        interpreting = false
        let filter = self.filter
        task = Task {
            let all = await engine.photos(of: people, in: dates)
            let shown = filter == nil ? all : await engine.photos(of: people, in: dates, kinds: filter!.kinds)
            guard !Task.isCancelled, current == generation else { return }
            var counts: [ResultGroupKind: Int] = [:]
            for hit in all { counts[ResultGroupKind(hit.kind), default: 0] += 1 }
            self.counts = counts
            results = ResultSet(shown, browsed: people.isEmpty ? .time : .people)
            showWeaker = false
            if !rows.contains(where: { $0.id == selection }) { selection = rows.first?.id }
            hasResults = true
            log("window: \(people.count) people (AND), \(dates?.title ?? "any time"), nothing typed: "
                + "\(results.ranked.count) photos")
        }
    }

    private func run() {
        generation += 1
        let current = generation
        task?.cancel()
        navigated = false
        let text = words
        let dates = self.dates
        if browsing {
            browse(people: peopleFilter, dates: dates, generation: current)
            return
        }
        guard !text.isEmpty else {
            results = .empty
            counts = [:]
            hasResults = false
            interpreted = nil
            rewriteNote = nil
            interpreting = false
            return
        }
        interpreted = nil
        rewriteNote = nil
        interpreting = engine.rewritesQueries
        engine.noteTyped(text)
        engine.prewarm()
        if !engine.rewritesQueries { engine.embedAhead(text) }
        let filter = self.filter
        let people = peopleFilter
        let showAt = ContinuousClock.now + SearchPanelController.typingPause
        let rewrite = engine.rewritesQueries
        task = Task {
            if rewrite {
                try? await Task.sleep(until: showAt, tolerance: .milliseconds(1), clock: .continuous)
                guard !Task.isCancelled, current == generation else { return }
            }
            let reading = await engine.formalQuery(text)
            guard !Task.isCancelled, current == generation else { return }
            interpreting = false
            interpreted = reading.interpreted
            rewriteNote = reading.note
            let asked = reading.search
            let vector = await engine.embedQuery(asked, typed: text)
            guard !Task.isCancelled, current == generation else { return }
            let peopleArg: Set<Int64>? = people.isEmpty ? nil : people
            let all = await engine.search(asked, vector: vector, prefixLast: false, people: peopleArg, dates: dates,
                                          limit: 120)
            let shown = filter == nil ? all : await engine.search(asked, vector: vector, prefixLast: false,
                                                                    kinds: filter!.kinds, people: peopleArg,
                                                                    dates: dates, limit: 120)
            if !rewrite {
                try? await Task.sleep(until: showAt, tolerance: .milliseconds(1), clock: .continuous)
            }
            guard !Task.isCancelled, current == generation else { return }
            var counts: [ResultGroupKind: Int] = [:]
            for hit in all.prefix(Searcher.strongCount(all)) { counts[ResultGroupKind(hit.kind), default: 0] += 1 }
            self.counts = counts
            results = ResultSet(shown, query: asked)
            showWeaker = false
            if !rows.contains(where: { $0.id == selection }) { selection = rows.first?.id }
            hasResults = true
            let who = (people.isEmpty ? "" : " · \(people.count) people (AND)") + (dates.map { " · \($0.title)" } ?? "")
            log("window: \"\(text)\"\(filter.map { " in \($0.title)" } ?? "")\(who): \(results.ranked.count) results "
                + "+ \(results.weaker.count) weaker")
        }
    }
}

// MARK: Views

struct SearchWindowView: View {
    @Bindable var search: SearchModel
    let model: AppModel
    let app: AppController
    @State private var fieldFocused = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if search.showsPreview, let row = search.selectedRow, search.hasResults {
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            PreviewPane(row: row, imageSize: CGSize(width: 292, height: 230),
                                        open: { search.open(row) })
                            PreviewActions(row: row, open: { search.open(row) },
                                           reveal: { NSWorkspace.shared.activateFileViewerSelecting([row.url]) })
                        }
                        .padding(16)
                    }
                    .frame(width: 324)
                    .background(Color.primary.opacity(0.025))
                }
            }
            Divider()
            statusBar
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 820, minHeight: 520)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Brand.gradient)
                        .frame(width: 22)
                    SearchField(text: $search.query, fontSize: 18, placeholder: placeholder,
                                onMake: { search.field = $0 }, onFocus: { fieldFocused = $0 })
                    QueryUnderstandingToggle(
                        active: model.settings.queryUnderstanding && model.hasOpenRouterKey,
                        toggle: { app.toggleQueryUnderstanding() })
                    if !search.query.isEmpty {
                        Button {
                            search.query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear")
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
                // Where typing goes, as a Mac text field shows it: a ring in the accent color while it has the cursor.
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(fieldFocused ? 0.6 : 0), lineWidth: 2))
                .animation(.easeOut(duration: 0.15), value: fieldFocused)
                Button {
                    app.showAlbums()
                } label: {
                    Image(systemName: "rectangle.stack")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Albums")
                Button {
                    search.showsPreview.toggle()
                } label: {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 15))
                        .foregroundStyle(search.showsPreview ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.plain)
                .help(search.showsPreview ? "Hide Preview" : "Show Preview")
                Button {
                    app.showSettings()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Settings (⌘,)")
            }
            .padding(.leading, 78)   // beside the window buttons
            .frame(height: 52)
            if search.interpreting || search.interpreted != nil || search.rewriteNote != nil {
                QueryInterpretation(interpreting: search.interpreting, line: search.interpreted,
                                    note: search.rewriteNote,
                                    apply: { if let line = search.interpreted { search.query = line } },
                                    openSettings: { app.showSettings() })
                    .padding(.leading, 90)
            }
            HStack(spacing: 6) {
                KindFilters(search: search,
                            photosAndVideoOnly: model.settings.photosAndVideoOnly)
                DateFilter(search: search)
            }
            if !search.people.isEmpty {
                PersonFilters(search: search)
            }
        }
        // Indexing groups people again as faces come in.
        .onChange(of: model.status) {
            search.refreshPeople()
            search.refreshMonths()
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    @ViewBuilder private var content: some View {
        if !model.hasFolders {
            VStack(spacing: 0) {
                BrandMark()
                Text("Choose folders to search").font(.system(size: 20, weight: .bold)).padding(.top, 18)
                Text("DigUpPhotos only looks where you tell it to.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
                Button("Choose Folders…") { app.chooseFolders() }
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .padding(.top, 18)
            }
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if search.query.trimmingCharacters(in: .whitespaces).isEmpty, !search.browsing {
            SearchHome(search: search, model: model, engine: app.engine)
        } else if !search.hasResults {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if search.results.isEmpty, search.browsing, search.peopleFilter.isEmpty {
            EmptyState(symbol: "calendar",
                       title: "No photos from \(search.dates?.title ?? "then")",
                       message: search.filter == nil ? "Try another time." : "Try All instead of \(search.filter!.title).")
        } else if search.results.isEmpty, search.browsing {
            EmptyState(symbol: "person.2",
                       title: (search.peopleFilter.count > 1 ? "No photos of them together" : "No photos of them here")
                           + (search.dates.map { " in \($0.title)" } ?? ""),
                       message: search.filter == nil
                           ? (search.dates == nil ? "They may be in folders that aren't searched any more."
                                                  : "Try another time.")
                           : "Try All instead of \(search.filter!.title).")
        } else if search.results.isEmpty {
            EmptyState(symbol: "magnifyingglass",
                       title: "No good matches for “\(search.query.trimmingCharacters(in: .whitespaces))”",
                       message: search.dates != nil || !search.peopleFilter.isEmpty
                           ? "Try without the time or people picked, or describe it another way."
                           : "Try describing what's in it: what you'd see or hear, or words you remember.")
        } else {
            ResultsGrid(search: search)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            if let progress = model.progress {
                ProgressView(value: progress).progressViewStyle(.circular).controlSize(.mini)
            }
            // What's indexed: a click shows the folders and their progress.
            Button(model.statusLine) { app.showSettings(.folders) }
                .buttonStyle(.plain)
                .lineLimit(1)
                .help("Folders and indexing")
            Spacer()
            if !search.rows.isEmpty {
                Menu {
                    Button("Copy Paths") { app.copySearchFileList() }
                    Button("Save File List…") { app.exportSearchFileList() }
                } label: {
                    Text(search.listNote ?? "File List")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Paths of these results, one per line, to paste or save for another program")
            }
            if search.hasResults, !search.query.isEmpty || search.browsing {
                Text(model.resultsCaveat ?? resultCount).lineLimit(1)
            }
            if let version = model.updateAvailable {
                Button {
                    app.updates.checkNow()
                } label: {
                    Label("DigUpPhotos \(version) is available", systemImage: "arrow.down.circle.fill")
                        .foregroundStyle(Brand.ember)
                }
                .buttonStyle(.plain)
                .help("See what's new and update")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 28)
    }

    private var placeholder: String {
        "Describe it: “receipt from the hardware store”, “zebra in a video”…"
    }

    private var resultCount: String {
        let count = search.results.ranked.count
        if search.browsing { return count == 1 ? "1 photo" : "\(count) photos" }
        return (count == 1 ? "1 result" : "\(count) results")
            + (search.results.weaker.isEmpty ? "" : " · \(search.results.weaker.count) weaker")
    }
}

/// People chips: select one or more. Several selected → only photos with all of them together (AND).
private struct PersonFilters: View {
    @Bindable var search: SearchModel

    /// Named people, people on 5 or more photos, and whoever is selected, up to 16; the rest are in a menu. Faces
    /// grouped into people include passers-by (2026-10-29: 13 of 58 on fewer than 5 photos).
    private var shown: [Person] {
        let chips = Set(search.people.filter(Self.worthAChip).prefix(16).map(\.id)).union(search.peopleFilter)
        return search.people.filter { chips.contains($0.id) }
    }

    private var more: [Person] {
        let visible = Set(shown.map(\.id))
        return search.people.filter { !visible.contains($0.id) }
    }

    private static func worthAChip(_ person: Person) -> Bool {
        person.name?.isEmpty == false || person.photoCount >= 5
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Text(search.peopleFilter.count > 1 ? "All of:" : "People")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 2)
                ForEach(shown) { person in
                    let on = search.peopleFilter.contains(person.id)
                    Button {
                        search.togglePerson(person.id)
                    } label: {
                        HStack(spacing: 5) {
                            PersonThumb(personID: person.id, engine: search.engine, side: 20)
                            Text(person.displayName)
                                .lineLimit(1)
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                        .padding(.leading, 3)
                        .padding(.trailing, 10)
                        .padding(.vertical, 3)
                        .background(on ? Color.accentColor : Color.primary.opacity(0.06), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(person.photoCount == 1 ? "1 photo" : "\(person.photoCount) photos")
                }
                if !more.isEmpty {
                    Menu("\(more.count) more") {
                        ForEach(more) { person in
                            Button("\(person.displayName) · \(person.photoCount)") { search.togglePerson(person.id) }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                }
                if !search.peopleFilter.isEmpty {
                    Button("Clear") { search.peopleFilter = [] }
                        .font(.system(size: 11, weight: .medium))
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.top, 4)
    }
}

/// Any Time ▾: a year, a month of it, or the last days. A time typed in the query ("beach 2023") shows here too, and
/// picking one here searches the words as typed.
private struct DateFilter: View {
    @Bindable var search: SearchModel

    private var years: [Int] { search.months.keys.sorted(by: >) }

    var body: some View {
        let on = search.dates != nil
        HStack(spacing: 0) {
            Menu {
                Button("Any Time") { search.dateFilter = nil }
                Divider()
                if let span = DateSpan.last(days: 30) { Button(span.title) { search.dateFilter = span } }
                if let span = DateSpan.last(days: 365) { Button("Last 12 Months") { search.dateFilter = span } }
                Divider()
                ForEach(years, id: \.self) { year in
                    let months = search.months[year] ?? [:]
                    Menu("\(String(year)) · \(months.values.reduce(0, +))") {
                        if let span = DateSpan.year(year) { Button("All of \(String(year))") { search.dateFilter = span } }
                        Divider()
                        ForEach(months.keys.sorted(by: >), id: \.self) { month in
                            if let span = DateSpan.month(month, of: year) {
                                Button("\(Calendar.current.standaloneMonthSymbols[month - 1]) · \(months[month]!)") {
                                    search.dateFilter = span
                                }
                            }
                        }
                    } primaryAction: {
                        search.dateFilter = DateSpan.year(year)
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "calendar").font(.system(size: 10.5))
                    Text(search.dates?.title ?? "Any Time")
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            if search.dateFilter != nil {
                Button {
                    search.dateFilter = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .padding(.leading, 5)
                .help("Any time")
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(on ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(0.06))))
        .help(search.typedDates != nil ? "From your words; pick a time to search them all as typed" : "When it was taken")
    }
}

/// All · Photos 4 · Video 9 · …: what the query found of each kind; click to see only that kind.
private struct KindFilters: View {
    @Bindable var search: SearchModel
    var photosAndVideoOnly = true

    private var chips: [ResultGroupKind] { ResultGroupKind.files(photosAndVideoOnly: photosAndVideoOnly) }

    var body: some View {
        HStack(spacing: 6) {
            chip(title: "All", symbol: nil, count: nil, selected: search.filter == nil) {
                search.filter = nil
            }
            ForEach(chips, id: \.self) { kind in
                chip(title: kind.title, symbol: kind.symbol, count: search.counts[kind],
                     selected: search.filter == kind) {
                    search.filter = search.filter == kind ? nil : kind
                }
            }
        }
    }

    private func chip(title: String, symbol: String?, count: Int?, selected: Bool, shortcut: Int? = nil,
                      action: @escaping () -> Void) -> some View {
        let number = shortcut ?? (chips.firstIndex { $0.title == title }).map { $0 + 2 } ?? 1
        return Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 10.5)) }
                Text(title)
                if let count, !search.query.isEmpty || search.browsing {
                    Text("\(count)").monospacedDigit().opacity(0.6)
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(selected ? AnyShapeStyle(Color.accentColor)
                                                : AnyShapeStyle(Color.primary.opacity(0.06))))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("\(title) (⌘\(number))")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct ResultsGrid: View {
    @Bindable var search: SearchModel
    private static let cell = CGSize(width: 176, height: 132)

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.cell.width, maximum: 230), spacing: 14)],
                              alignment: .leading, spacing: 18) {
                        ForEach(search.results.ranked) { row in cell(row) }
                    }
                    .padding(16)
                    if !search.results.weaker.isEmpty {
                        WeakerToggle(count: search.results.weaker.count, expanded: search.showWeaker) {
                            search.showWeaker.toggle()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                        if search.showWeaker {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.cell.width, maximum: 230),
                                                         spacing: 14)], alignment: .leading, spacing: 18) {
                                ForEach(search.results.weaker) { row in cell(row).opacity(0.85) }
                            }
                            .padding(16)
                        }
                    }
                }
                .onChange(of: search.selection) { _, id in
                    if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
                }
            }
            .onAppear { updateColumns(geometry.size.width) }
            .onChange(of: geometry.size.width) { _, width in updateColumns(width) }
        }
    }

    private func updateColumns(_ width: CGFloat) {
        search.columns = max(1, Int((width - 32 + 14) / (Self.cell.width + 14)))
    }

    private func cell(_ row: ResultRow) -> some View {
        GridCell(row: row, selected: row.id == search.selectedRow?.id)
            .id(row.id)
            .overlay(FileDragArea(url: row.url, openTitle: row.openTitle, onClick: { search.select(row) },
                                  onOpen: { search.open(row) }))
    }
}

private struct GridCell: View {
    let row: ResultRow
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // A fixed box the picture fills and is clipped to: a picture's own shape must never size the cell.
            Color.primary.opacity(0.05)
                .frame(height: 132)
                .frame(maxWidth: .infinity)
                .overlay {
                    if row.kind == .audio {
                        Image(systemName: "waveform")
                            .font(.system(size: 34, weight: .light))
                            .foregroundStyle(Brand.gradient)
                    } else {
                        MomentThumbnail(row: row)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .topLeading) {
                if row.kind != .image && row.kind != .screenshot {
                    Image(systemName: row.kind.symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(Circle().fill(.black.opacity(0.5)))
                        .padding(6)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let place = row.place { PlaceBadge(text: place, onImage: true).padding(6) }
            }
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 3 : 0.5)
                .padding(selected ? -3 : 0))
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(row.folder)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.kind.title), \(row.name), \(row.reason)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct MomentThumbnail: View {
    let row: ResultRow
    @State private var image: NSImage?
    @Environment(\.displayScale) private var scale

    var body: some View {
        Group {
            if let image {
                // A page shows its top (its title), anything else its middle.
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: row.page == nil ? .center : .top)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: row.url.path))
                    .resizable()
                    .frame(width: 56, height: 56)
            }
        }
        .task(id: row.previewKey) {
            let side: CGFloat = 230
            image = Previews.shared.cached(row, side: side)
            if image == nil { image = await Previews.shared.load(row, side: side, scale: scale) }
        }
    }
}

struct WeakerToggle: View {
    let count: Int
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                Text(expanded ? "Weaker matches" : "\(count) weaker \(count == 1 ? "match" : "matches")")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// After a search: a big quiet symbol, what happened, what to try.
private struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Nothing typed yet: the app's mark (not a magnifier, which reads as a second search field), a pointer to the field
/// above, examples to click (each with the kind it finds), what's in the index, and the shortcut. A click anywhere else
/// puts the cursor in the field.
private struct SearchHome: View {
    let search: SearchModel
    let model: AppModel
    let engine: Engine
    @State private var kinds: [FileKind: Int] = [:]

    private static let examples: [(text: String, kind: ResultGroupKind)] = [
        ("kids on the beach", .images), ("best photos of dinner", .images), ("the part with the drums", .video),
        ("someone laughing", .audio), ("a dog on the beach", .video), ("slides about the budget", .documents),
    ]

    var body: some View {
        VStack(spacing: 0) {
            BrandMark()
            Text("Describe it. Dig it up.")
                .font(.system(size: 24, weight: .bold))
                .padding(.top, 18)
            Text("Type what you remember in the search field above: what's in it, what it looks or sounds like, or "
                 + "words from it.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440)
                .padding(.top, 6)
            Text("TRY")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.tertiary)
                .padding(.top, 26)
            FlowRow(spacing: 8) {
                ForEach(examples, id: \.text) { example in
                    ExampleChip(text: example.text, kind: example.kind) { search.query = example.text }
                }
            }
            .frame(maxWidth: 560)
            .padding(.top, 8)
            VStack(spacing: 8) {
                if !kinds.isEmpty {
                    HStack(spacing: 8) {
                        KindCounts(counts: kinds)
                        Text("in \(folders)")
                    }
                } else if model.status.searchable > 0 {
                    Text("\(model.status.searchable.formatted()) files to search in \(folders)")
                }
                if let hotkey = model.hotkey {
                    HStack(spacing: 6) {
                        Keycaps(caps: hotkey.caps, size: 10)
                        Text("opens DigUpPhotos from any app")
                    }
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .padding(.top, 30)
        }
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { search.focusField() }
        .task(id: model.status.files) {
            var counts: [FileKind: Int] = [:]
            for summary in await engine.rootSummaries() { counts.merge(summary.kinds, uniquingKeysWith: +) }
            kinds = counts
        }
    }

    private var examples: [(text: String, kind: ResultGroupKind)] {
        Self.examples
    }

    private var folders: String {
        let names = model.settings.roots.map(\.lastPathComponent)
        return names.count <= 3 ? names.formatted(.list(type: .and)) : "\(names.count) folders"
    }
}

/// The app's icon with its own glow (the find in the D) spread soft around it: the window's empty states.
private struct BrandMark: View {
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .frame(width: 84, height: 84)
            .shadow(color: Brand.moss.opacity(0.3), radius: 14, y: 6)
            .background {
                Circle()
                    .fill(RadialGradient(colors: [Brand.amber.opacity(0.22), Brand.leaf.opacity(0.08), .clear],
                                         center: .center, startRadius: 0, endRadius: 150))
                    .frame(width: 300, height: 300)
                    .allowsHitTesting(false)
            }
            .accessibilityHidden(true)
    }
}

/// An example query: the kind it finds, the words; a click searches for it.
private struct ExampleChip: View {
    let text: String
    let kind: ResultGroupKind
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: kind.symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Brand.leaf)
                Text(text)
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(Capsule().fill(Brand.leaf.opacity(hovering ? 0.2 : 0.1)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Search for “\(text)”")
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .onDisappear { if hovering { NSCursor.pop() } }
    }
}

/// Lays children out in rows, wrapping like text.
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews) {
            var x = bounds.minX + (bounds.width - row.width) / 2
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> [(items: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], width: CGFloat, height: CGFloat)] = []
        var current: (items: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.items.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.items.isEmpty {
                rows.append(current)
                current = ([index], size.width, size.height)
            } else {
                current = (current.items + [index], needed, max(current.height, size.height))
            }
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}
