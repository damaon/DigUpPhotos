import AppKit
import DigUpCore
import Observation
import SwiftUI

enum SettingsTab: String, CaseIterable {
    case general, folders, people, storage

    var title: String {
        switch self {
        case .general: "General"
        case .folders: "Folders"
        case .people: "People"
        case .storage: "Storage"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .folders: "folder"
        case .people: "person.2"
        case .storage: "internaldrive"
        }
    }
}

/// Settings, the way Mac apps lay them out: a toolbar of tabs, and the window sized to each one. Folders is also where
/// the index shows how far along it is, folder by folder.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    let state: SettingsState
    /// Folders → Add Folders…, a sheet on this window.
    let addSheet: AddFoldersController
    private unowned let app: AppController
    private var window: NSWindow?
    private var tabs: NSTabViewController?

    init(app: AppController) {
        self.app = app
        state = SettingsState(app: app)
        addSheet = AddFoldersController(app: app)
        super.init()
        state.addFolders = { [weak self] in self?.addFolders() }
        addSheet.onAdded = { [weak self] in
            guard let self else { return }
            Task { await self.state.refresh() }
        }
    }

    /// Opens Add Folders on the Folders tab.
    func addFolders() {
        addSheet.begin(on: window)
    }

    var isVisible: Bool { window?.isVisible == true }

    func show(_ tab: SettingsTab = .general) {
        let window = self.window ?? makeWindow()
        tabs?.selectedTabViewItemIndex = SettingsTab.allCases.firstIndex(of: tab) ?? 0
        state.tab = tab
        Task { await state.refresh() }
        app.present(window)
    }

    var selectedTab: SettingsTab { state.tab }

    private func makeWindow() -> NSWindow {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = [.allowUserInteraction]
        for tab in SettingsTab.allCases {
            let controller = NSHostingController(rootView: SettingsPane(tab: tab, state: state))
            controller.sizingOptions = .preferredContentSize
            controller.title = tab.title   // the window takes the selected tab's title
            let item = NSTabViewItem(viewController: controller)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            item.identifier = tab.rawValue
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.tabs = tabs
        self.window = window
        state.selectTab = { [weak self] tab in
            self?.tabs?.selectedTabViewItemIndex = SettingsTab.allCases.firstIndex(of: tab) ?? 0
        }
        return window
    }

    func windowWillClose(_ notification: Notification) {
        addSheet.end()
        window?.contentViewController = nil
        window = nil
        tabs = nil
        app.windowClosed()
    }

    func snapshot(to url: URL) throws {
        try Snapshot.write(window, to: url)
    }
}

@Observable
final class SettingsState {
    var tab = SettingsTab.general
    private(set) var summaries: [Engine.RootSummary]?
    private(set) var people: [Person] = []
    private(set) var indexSize: Int64 = 0
    var launchAtLogin = false
    var loginProblem: String?
    var checksForUpdates = false
    @ObservationIgnored let app: AppController
    @ObservationIgnored var selectTab: (SettingsTab) -> Void = { _ in }
    @ObservationIgnored var addFolders: () -> Void = {}

    init(app: AppController) {
        self.app = app
    }

    @ObservationIgnored private var lastRefresh = Date.distantPast
    @ObservationIgnored private var refreshPending = false

    var model: AppModel { app.model }

    func refresh() async {
        lastRefresh = Date()
        launchAtLogin = app.launchesAtLogin
        checksForUpdates = app.updates.automaticallyChecks
        indexSize = app.engine.indexSize
        people = await app.engine.people()
        summaries = await app.engine.rootSummaries()
    }

    func renamePerson(_ id: Int64, to name: String) async {
        await app.engine.renamePerson(id, to: name)
        people = await app.engine.people()
    }

    /// Changes to people that Undo takes back, the latest last: what was done ("Merged Person 12 into Anna") and how
    /// people were before it. Merges happen at once, without asking; Undo is how a wrong one is taken back.
    private(set) var undoable: [(title: String, before: PeopleSnapshot)] = []

    func mergePeople(_ other: Person, into keeper: Person) async {
        if let before = await app.engine.mergePeople(keeper: keeper.id, other: other.id) {
            undoable.append(("Merged \(other.displayName) into \(keeper.displayName)", before))
        }
        await peopleChanged()
    }

    func undoMerges() async {
        if let before = await app.engine.undoMerges() { undoable.append(("Undid all merges", before)) }
        await peopleChanged()
    }

    func undo() async {
        guard let last = undoable.popLast() else { return }
        await app.engine.restorePeople(last.before)
        await peopleChanged()
    }

    private func peopleChanged() async {
        people = await app.engine.people()
        app.albumsWindow?.albums.refreshPeople()
        app.searchWindow?.search.refreshPeople()
    }

    /// The index changed: refresh the folder counts, at most every 2 s while files are being indexed.
    func statusChanged() {
        guard !refreshPending else { return }
        refreshPending = true
        let wait = max(0, 2 - Date().timeIntervalSince(lastRefresh))
        Task {
            try? await Task.sleep(for: .seconds(wait))
            refreshPending = false
            await refresh()
        }
    }

    /// Ready to be drawn (debug snapshots wait for this).
    var isLoaded: Bool { summaries != nil }
}

/// One tab's content, at the width every tab shares.
private struct SettingsPane: View {
    let tab: SettingsTab
    let state: SettingsState

    var body: some View {
        Group {
            switch tab {
            case .general: GeneralSettings(state: state)
            case .folders: FolderSettings(state: state)
            case .people: PeopleSettings(state: state)
            case .storage: StorageSettings(state: state)
            }
        }
        .frame(width: 580)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralSettings: View {
    @Bindable var state: SettingsState
    @State private var openRouterKey = OpenRouterKey.load()
    @State private var keyNote = ""
    @State private var keyOK = false
    @State private var keyCheck: Task<Void, Never>?

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    ShortcutRecorder(combo: state.model.hotkey, apply: { state.app.setHotkey($0) },
                                     listening: { state.app.hotkeyRecording($0) }, capSize: 13)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Search shortcut")
                        Text("Opens the search panel from any app.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Toggle(isOn: Binding(get: { state.launchAtLogin }, set: { on in
                    state.loginProblem = state.app.setLaunchAtLogin(on)
                    state.launchAtLogin = state.app.launchesAtLogin
                })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Open DigUpPhotos when you log in")
                        Text(state.loginProblem ?? "So the shortcut always works.")
                            .font(.system(size: 11))
                            .foregroundStyle(state.loginProblem == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                    }
                }
            }
            Section {
                Toggle(isOn: Binding(get: { state.model.settings.queryUnderstanding }, set: { on in
                    state.app.setQueryUnderstanding(on)
                })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Query understanding")
                        Text("Rewrite a question into and, or, and − before searching.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("API key") {
                    SecureField("sk-or-…", text: $openRouterKey)
                        .onSubmit { commitKey() }
                        .onChange(of: openRouterKey) { _, _ in commitKey() }
                }
            } header: {
                Text("OpenRouter")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if !keyNote.isEmpty {
                        Text(keyNote)
                            .foregroundStyle(keyOK ? AnyShapeStyle(.green) : keyNote.hasPrefix("Off") || keyNote == "Checking the key…"
                                             ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                    }
                    Text("The question is sent to OpenRouter; your photos are not. The key stays in the Keychain. "
                         + "Turn query understanding off to search the words as you type them.")
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .onAppear { commitKey() }
            Section {
                Toggle(isOn: Binding(get: { state.checksForUpdates }, set: { on in
                    state.app.updates.automaticallyChecks = on
                    state.checksForUpdates = on
                })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Check for updates automatically")
                        Text("Once a day DigUp asks GitHub for its newest version; nothing about your files is sent. "
                             + "Updates install with one click.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                LabeledContent {
                    Button("Check Now") { state.app.updates.checkNow() }
                } label: {
                    Text(state.model.updateAvailable.map { "DigUpPhotos \($0) is available" }
                         ?? "DigUpPhotos \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }

    private func commitKey() {
        let cleaned = OpenRouterKey.normalize(openRouterKey)
        if cleaned != openRouterKey {
            openRouterKey = cleaned
            return
        }
        state.app.setOpenRouterKey(cleaned)
        keyCheck?.cancel()
        if cleaned.isEmpty {
            keyOK = false
            keyNote = "Off. Questions are searched as you type them."
            return
        }
        if let problem = OpenRouterKey.formatProblem(cleaned) {
            keyOK = false
            keyNote = problem
            return
        }
        keyOK = false
        keyNote = "Checking the key…"
        keyCheck = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            let result = await OpenRouterKey.verify(cleaned)
            guard !Task.isCancelled else { return }
            keyOK = result.ok
            keyNote = result.message
        }
    }
}

private struct FolderSettings: View {
    @Bindable var state: SettingsState
    @State private var removing: Engine.RootSummary?

    var body: some View {
        Form {
            Section {
                IndexProgress(model: state.model) { state.app.engine.setPaused(!state.model.status.paused) }
            }
            Section {
                if let summaries = state.summaries {
                    if summaries.isEmpty {
                        Text("No folders yet. Add the ones DigUp should search.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(summaries) { summary in
                        FolderStatusRow(summary: summary) { removing = summary }
                    }
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                }
            } header: {
                Text("Folders to search")
            } footer: {
                HStack {
                    Button(action: state.addFolders) {
                        Label("Add Folders…", systemImage: "plus")
                    }
                    Spacer()
                }
            }
            Section {
                ForEach(state.model.settings.excludedFolders, id: \.path) { folder in
                    HStack {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: folder.path))
                            .resizable()
                            .frame(width: 18, height: 18)
                        Text(tildePath(folder.path)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button {
                            state.app.setExcluded(state.model.settings.excludedFolders.filter { $0 != folder })
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Search this folder again")
                    }
                }
                if state.model.settings.excludedFolders.isEmpty {
                    Text("None. Code projects, app bundles and caches are skipped anyway (code has its own tab).")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Skip these folders")
            } footer: {
                HStack {
                    Button {
                        state.app.pickFolders(for: NSApp.keyWindow, prompt: "Skip") { folders in
                            guard !folders.isEmpty else { return }
                            state.app.setExcluded(state.model.settings.excludedFolders
                                + folders.filter { !state.model.settings.excludedFolders.contains($0) })
                        }
                    } label: {
                        Label("Skip a Folder…", systemImage: "plus")
                    }
                    Spacer()
                }
            }
            Section {
                Toggle(isOn: Binding(get: { state.model.settings.photosAndVideoOnly },
                                     set: { state.app.setPhotosAndVideoOnly($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Photos and videos only")
                        Text("Skip screenshots, PDFs, documents and standalone audio. DigUp keeps capture dates and "
                             + "GPS, and scores how good each photo looks (sharpness, light, faces).")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                TypeExclusions(types: state.model.settings.excludedTypes) { state.app.setExcludedTypes($0) }
            } header: {
                Text("What to index")
            } footer: {
                Text(state.model.settings.photosAndVideoOnly
                     ? "Only photos and videos in the folders above are indexed. Code is still optional under the "
                       + "Code tab. Keys, certificates and password files are never read."
                     : "DigUp reads pictures, PDFs, documents (txt, md, rtf, docx, odt, html), audio and video here; "
                       + "code is read only in the code folders (the Code tab). Keys, certificates and password files "
                       + "are never read, nor are hidden folders like ~/.ssh.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Toggle(isOn: Binding(get: { state.model.settings.indexOnBattery },
                                     set: { state.app.setIndexOnBattery($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AppSettings.batteryTitle)
                        Text(AppSettings.batteryDetail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .onChange(of: state.model.status) { state.statusChanged() }
        .confirmationDialog(removalTitle, isPresented: Binding(get: { removing != nil },
                                                               set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                guard let removing else { return }
                state.app.removeFolder(URL(fileURLWithPath: removing.path))
                Task { await state.refresh() }
            }
        } message: {
            Text("Its \(removing?.files.formatted() ?? "") files leave the index. Adding it back later indexes them "
                 + "again.")
        }
    }

    private var removalTitle: String {
        "Stop searching “\(removing.map { ($0.path as NSString).lastPathComponent } ?? "")”?"
    }
}

/// Name people, and merge a person who was clustered twice.
private struct PeopleSettings: View {
    @Bindable var state: SettingsState
    @State private var draftNames: [Int64: String] = [:]
    /// The person who stays. The next pick is merged into them.
    @State private var mergeKeeper: Int64?
    @State private var suggestions: [(first: Int64, second: Int64, score: Float)] = []
    /// Suggestions turned down with "Not the same", which the menu can bring back.
    @State private var dismissed = 0

    private struct Suggestion: Identifiable {
        var first: Int64
        var second: Int64
        var score: Float
        var id: String { "\(first)-\(second)" }
    }

    private var suggestionRows: [Suggestion] {
        suggestions.map { Suggestion(first: $0.first, second: $0.second, score: $0.score) }
    }

    var body: some View {
        Form {
            if let last = state.undoable.last {
                Section {
                    HStack {
                        Text(last.title).lineLimit(1)
                        Spacer(minLength: 8)
                        Button("Undo") { Task { await state.undo() } }
                    }
                }
            }
            if !suggestions.isEmpty, mergeKeeper == nil {
                Section {
                    ForEach(suggestionRows) { pair in
                        if let first = person(pair.first), let second = person(pair.second) {
                            let sides = kept(first, second)
                            suggestionRow(keeper: sides.keeper, other: sides.other, score: pair.score)
                        }
                    }
                } header: {
                    Text("Likely the same person")
                } footer: {
                    Text("Merging keeps both face embeddings. Filtering the person who stays finds photos of either one.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            if let faces = state.model.facesLine {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(faces).font(.system(size: 13, weight: .semibold))
                        if let progress = state.model.facesProgress {
                            ProgressView(value: progress).controlSize(.small)
                        }
                    }
                } footer: {
                    Text("People are grouped from the photos checked so far, so some may be missing until the rest are."
                         + (state.model.status.waitingFor == "on battery"
                            ? " Plug in a charger, or turn on “\(AppSettings.batteryTitle)” in General." : ""))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Section {
                if state.people.isEmpty {
                    Text("No people yet. Index photos that show faces, then name them here.")
                        .foregroundStyle(.secondary)
                } else if let keeper = mergeKeeper, let person = person(keeper) {
                    Text("Pick the duplicate to merge into \(person.displayName). \(person.displayName)’s name is kept.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                ForEach(listed) { person in
                    personRow(person)
                }
            } header: {
                HStack {
                    Text("People in your photos")
                    Spacer()
                    peopleMenu
                }
            } footer: {
                Text("A name is saved with Return. Merge when the same person was split into two. In search, several "
                     + "selected people keep only photos where all of them appear. Albums turns the people you pick into trips.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if mergeKeeper != nil {
                Section {
                    Button("Cancel") { mergeKeeper = nil }
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxHeight: 640)
        .onAppear { syncDrafts(state.people) }
        .onChange(of: state.people) { _, people in
            syncDrafts(people)
        }
        .task(id: state.people.map(\.id)) {
            await loadSuggestions()
        }
    }

    private func merge(_ other: Person, into keeper: Person) {
        mergeKeeper = nil
        draftNames[other.id] = nil
        Task { await state.mergePeople(other, into: keeper) }
    }

    /// Named people first, alphabetically, as everywhere else; while merging, the one who stays and then whoever is in
    /// the most photos, since the big groups are the ones worth merging.
    private var listed: [Person] {
        guard let keeper = mergeKeeper else { return state.people }
        return state.people.filter { $0.id == keeper } + Person.byPhotos(state.people.filter { $0.id != keeper })
    }

    private func suggestionRow(keeper: Person, other: Person, score: Float) -> some View {
        HStack(spacing: 10) {
            PersonThumb(personID: keeper.id, engine: state.app.engine)
            PersonThumb(personID: other.id, engine: state.app.engine)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(other.displayName) → \(keeper.displayName)")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(similarity(score))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Not the Same") {
                Task {
                    await state.app.engine.dismissSuggestion(keeper.id, other.id)
                    await loadSuggestions()
                }
            }
            .controlSize(.small)
            .help("Stop suggesting these two")
            Button("Merge") { merge(other, into: keeper) }
                .controlSize(.small)
        }
    }

    /// Rarely needed, so out of the way: bring back turned-down suggestions, or take back every merge.
    private var peopleMenu: some View {
        Menu {
            Button(dismissed == 1 ? "Show 1 Dismissed Suggestion" : "Show \(dismissed) Dismissed Suggestions") {
                Task {
                    await state.app.engine.restoreSuggestions()
                    await loadSuggestions()
                }
            }
            .disabled(dismissed == 0)
            Divider()
            Button("Undo All Merges") { Task { await state.undoMerges() } }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
    }

    private func loadSuggestions() async {
        suggestions = await state.app.engine.similarPeople()
        dismissed = await state.app.engine.dismissedSuggestionCount()
    }

    private func personRow(_ person: Person) -> some View {
        HStack(spacing: 12) {
            PersonThumb(personID: person.id, engine: state.app.engine, side: 44)
            VStack(alignment: .leading, spacing: 4) {
                TextField("Name", text: Binding(
                    get: { draftNames[person.id] ?? person.name ?? "" },
                    set: { draftNames[person.id] = $0 }
                ), prompt: Text(person.displayName))
                .onSubmit { Task { await save(person.id) } }
                Text("\(person.photoCount) photos · \(person.faceCount) faces")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            mergeControl(person)
        }
    }

    @ViewBuilder private func mergeControl(_ person: Person) -> some View {
        if mergeKeeper == person.id {
            Text("Stays")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        } else if let keeper = mergeKeeper, let kept = self.person(keeper) {
            Button("Merge") { merge(person, into: kept) }
            .controlSize(.small)
            .help("Merge into \(kept.displayName)")
        } else {
            Button("Merge…") { mergeKeeper = person.id }
                .controlSize(.small)
        }
    }

    /// The named person stays; otherwise the one in more photos.
    private func kept(_ a: Person, _ b: Person) -> (keeper: Person, other: Person) {
        let aNamed = !(a.name ?? "").isEmpty
        let bNamed = !(b.name ?? "").isEmpty
        if aNamed != bNamed { return aNamed ? (a, b) : (b, a) }
        if a.photoCount != b.photoCount { return a.photoCount >= b.photoCount ? (a, b) : (b, a) }
        return a.id <= b.id ? (a, b) : (b, a)
    }

    /// Suggested pairs are ones grouping didn't join (under 0.22): even the closest are a guess (of the 10 closest at
    /// 0.20–0.22, 2 were plainly one person, `FaceIdentity`, 2026-10-30).
    private func similarity(_ score: Float) -> String {
        score >= 0.18 ? "Very similar" : "Similar"
    }

    private func person(_ id: Int64) -> Person? { state.people.first { $0.id == id } }

    private func syncDrafts(_ people: [Person]) {
        for person in people where draftNames[person.id] == nil {
            draftNames[person.id] = person.name ?? ""
        }
    }

    private func save(_ id: Int64) async {
        await state.renamePerson(id, to: draftNames[id] ?? "")
    }
}

/// Face crop of a person's exemplar photo.
/// A person's face, cropped from the photo of their thumbnail face.
struct PersonThumb: View {
    let personID: Int64
    let engine: Engine
    var side: CGFloat = 36
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: side * 0.55))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: side, height: side)
        .clipShape(Circle())
        .task(id: personID) {
            guard let face = await engine.exemplarFace(ofPerson: personID),
                  let crop = await FaceCrop.load(face.path, box: face.box, side: Int(side * 2)) else { return }
            image = crop
        }
    }
}

/// Extensions typed as "heic, txt": applied on Return or when the field loses focus.
private struct TypeExclusions: View {
    let types: [String]
    let apply: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Extensions", text: $text, prompt: Text("e.g. heic, txt"))
            .labelsHidden()
            .focused($focused)
            .onSubmit { apply(text) }
            .onChange(of: focused) { _, now in if !now { apply(text) } }
            .onAppear { text = types.joined(separator: ", ") }
            .onChange(of: types) { _, now in text = now.joined(separator: ", ") }
    }
}

/// What the index is doing, with Pause/Resume.
private struct IndexProgress: View {
    let model: AppModel
    let togglePause: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.statusLine).font(.system(size: 13, weight: .semibold))
                if let progress = model.progress {
                    ProgressView(value: progress).controlSize(.small)
                }
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.hasFolders {
                Button(model.status.paused ? "Resume" : "Pause", action: togglePause)
            }
        }
    }

    /// "357 of 365 files searchable · 8 waiting · 2 long files to finish"
    private var detail: String {
        let status = model.status
        var text = "\(status.searchable.formatted()) of \(status.files.formatted()) files searchable"
        if status.pending > 0 { text += " · \(status.pending.formatted()) waiting" }
        if status.unfinished > 0 {
            text += " · \(status.unfinished.formatted()) long \(status.unfinished == 1 ? "file" : "files") to finish"
        }
        if model.download.isActive { text += " · model \(model.download.progressText)" }
        if let faces = model.facesLine { text += "\n" + faces }
        return text
    }
}

private struct FolderStatusRow: View {
    let summary: Engine.RootSummary
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: summary.missing ? "/Volumes" : summary.path))
                .resizable()
                .frame(width: 32, height: 32)
                .opacity(summary.missing ? 0.5 : 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text((summary.path as NSString).lastPathComponent).font(.system(size: 13, weight: .semibold))
                    if summary.missing || summary.unreadable {
                        Text(summary.missing ? "Not connected" : "No access")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.2)))
                    }
                    if summary.unreadable {
                        Button("Allow in Settings…", action: openFolderPrivacySettings)
                            .buttonStyle(.link)
                            .font(.system(size: 11))
                    }
                }
                Text(tildePath(summary.path))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !summary.kinds.isEmpty {
                    KindCounts(counts: summary.kinds).padding(.top, 1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(summary.missing || summary.unreadable ? "Kept for when it's back"
                     : "\(summary.indexed.formatted()) of \(summary.files.formatted()) indexed")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                if !states.isEmpty {
                    Text(states).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Button(action: remove) {
                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Stop searching this folder")
            .accessibilityLabel("Remove \((summary.path as NSString).lastPathComponent)")
        }
        .padding(.vertical, 2)
    }

    private var states: String {
        [summary.pending > 0 ? "\(summary.pending.formatted()) waiting" : nil,
         summary.unfinished > 0
            ? "\(summary.unfinished.formatted()) long \(summary.unfinished == 1 ? "file" : "files") to finish" : nil,
         summary.skipped > 0 ? "\(summary.skipped.formatted()) skipped" : nil,
         summary.failed > 0 ? "\(summary.failed.formatted()) couldn't be read" : nil].compactMap { $0 }
            .joined(separator: " · ")
    }
}

private struct StorageSettings: View {
    let state: SettingsState

    var body: some View {
        Form {
            Section("Model") {
                LabeledContent("EmbeddingGemma 2") {
                    Text("Google · Apache 2.0 · 865 MB")
                }
                LabeledContent("Status") {
                    HStack(spacing: 8) {
                        Text(state.model.download.isReady ? "Downloaded" : state.model.download.progressText)
                        switch state.model.download.phase {
                        case .needed, .failed:
                            Button("Download") { state.model.download.start() }.controlSize(.small)
                        default:
                            EmptyView()
                        }
                    }
                }
                LabeledContent("Location") {
                    PathButton(url: state.model.settings.modelsDirectory)
                }
            }
            Section("Index") {
                LabeledContent("Size on disk", value: bytes(state.indexSize))
                LabeledContent("Location") {
                    PathButton(url: state.model.settings.indexDirectory)
                }
            }
            Section("Privacy") {
                Text("DigUp reads the folders you choose and keeps what it learns in its index, on this Mac. "
                     + "It goes online only to download its model, once, and to check for updates (General), "
                     + "which sends nothing about your files.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Text("DigUpPhotos \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") · "
                     + "EmbeddingGemma 2 by Google (Apache 2.0), run by llama.cpp (MIT).")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}

/// "~/Library/…/Models" that shows the folder in Finder.
private struct PathButton: View {
    let url: URL

    var body: some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } label: {
            HStack(spacing: 4) {
                Text(tildePath(url.path)).lineLimit(1).truncationMode(.middle)
                Image(systemName: "arrow.right.circle.fill").foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .help("Show in Finder")
    }
}
