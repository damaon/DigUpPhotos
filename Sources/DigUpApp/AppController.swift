import AppKit
import DigUpKit
import ServiceManagement
import UniformTypeIdentifiers

/// Owns the app's parts (engine, model download, hotkey, panel, windows, menu) and carries out what they ask for:
/// new folders, a new hotkey, the login item, which window to show.
final class AppController {
    /// `-debugOffscreen YES`: windows and the panel are built and drawn but never shown, and the app never activates,
    /// so snapshot tests don't take the keyboard from whoever is using the Mac.
    static let offscreen = UserDefaults.standard.bool(forKey: "debugOffscreen")

    let model: AppModel
    let engine: Engine
    let download: ModelDownload
    let hotkeys = HotkeyCenter()
    let updates: Updates
    private let power: PowerPolicy
    private(set) var panel: SearchPanelController!
    private(set) var searchWindow: SearchWindowController!
    private(set) var albumsWindow: AlbumsWindowController!
    private(set) var settingsWindow: SettingsWindowController!
    private(set) var statusMenu: StatusMenuController!
    private(set) var onboarding: OnboardingController?
    private var observers: [NSObjectProtocol] = []
    /// Set while onboarding's shortcut step waits for you to try the hotkey: a press goes there, not to the panel.
    var hotkeyTester: (() -> Void)?

    init(settings: AppSettings) {
        let download = ModelDownload(folder: settings.modelsDirectory)
        let model = AppModel(settings: settings, download: download)
        var engineRef: Engine?
        let power = PowerPolicy(indexOnBattery: settings.indexOnBattery) { blocker in
            engineRef?.setBackfillBlocker(blocker)
        }
        log("power: \(PowerPolicy.onACPower() ? "AC" : "battery"), backfill \(power.blocker.map { "waits (\($0))" } ?? "may run")")
        let engine = Engine(settings: settings, backfillBlocker: power.blocker) { status in
            let before = model.statusLine
            model.status = status
            if model.statusLine != before { log("status: \(model.statusLine)") }
        }
        engineRef = engine
        self.download = download
        self.model = model
        self.power = power
        self.engine = engine
        updates = Updates(model: model)
        let key = OpenRouterKey.load()
        engine.setOpenRouterKey(key)
        model.hasOpenRouterKey = OpenRouterKey.usable(key)
    }

    /// Saves the OpenRouter key in the Keychain and uses it on the next search. Empty turns rewriting off.
    func setOpenRouterKey(_ key: String) {
        OpenRouterKey.save(key)
        engine.setOpenRouterKey(key)
        model.hasOpenRouterKey = OpenRouterKey.usable(key)
    }

    /// The Settings switch and the sparkle in the search field. Off searches the words as typed.
    func setQueryUnderstanding(_ on: Bool) {
        guard model.settings.queryUnderstanding != on else { return }
        AppSettings.save(queryUnderstanding: on)
        model.settings.queryUnderstanding = on
        engine.setQueryUnderstanding(on)
        panel?.research()
        searchWindow?.search.research()
    }

    /// Yellow sparkle means a question is rewritten. A click turns that off, or back on. With no key, turning it on
    /// opens Settings.
    func toggleQueryUnderstanding() {
        if model.settings.queryUnderstanding, model.hasOpenRouterKey {
            setQueryUnderstanding(false)
        } else {
            setQueryUnderstanding(true)
            if !model.hasOpenRouterKey { showSettings() }
        }
    }

    /// `showWindow`: opened by hand (not at login), so the search window comes up once the app is set up.
    func start(showWindow: Bool = false) {
        panel = SearchPanelController(app: self)
        searchWindow = SearchWindowController(app: self)
        albumsWindow = AlbumsWindowController(app: self)
        settingsWindow = SettingsWindowController(app: self)
        statusMenu = StatusMenuController(model: model)
        statusMenu.onSearch = { [weak self] in self?.panel.show() }
        statusMenu.onOpenWindow = { [weak self] in self?.showSearchWindow() }
        statusMenu.onAlbums = { [weak self] in self?.showAlbums() }
        statusMenu.onSettings = { [weak self] in self?.showSettings() }
        statusMenu.onChooseFolders = { [weak self] in self?.chooseFolders() }
        statusMenu.onPauseChanged = { [weak self] paused in self?.engine.setPaused(paused) }
        statusMenu.onCheckForUpdates = { [weak self] in self?.updates.checkNow() }
        updates.onSessionEnded = { [weak self] in self?.windowClosed() }
        updates.start()

        hotkeys.onPress = { [weak self] in
            guard let self else { return }
            if let hotkeyTester { hotkeyTester() } else { panel.toggle() }
        }
        if let combo = KeyCombo(model.settings.hotkey) {
            model.hotkey = hotkeys.register(combo) ? combo : nil
            log(model.hotkey == nil ? "hotkey \(combo.display) is taken by another app" : "hotkey \(combo.display)")
        } else {
            log("hotkey: can't read \"\(model.settings.hotkey)\" (try cmd+shift+space)")
        }

        Previews.shared.passage = { [engine] id in await engine.text(ofSegment: id) }
        download.onReady = { [weak self] in self?.engine.modelArrived() }
        engine.start()
        let settings = model.settings
        if !settings.onboarded, settings.roots.isEmpty {
            showOnboarding()
        } else {
            // Set up already (the go-ahead came with onboarding), so a missing model just downloads.
            if !download.isReady { download.start() }
            if showWindow { showSearchWindow() }
        }
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil,
                                                                               queue: .main) { [weak self] note in
                let volume = (note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path
                MainActor.assumeIsolated { self?.volumeChanged(volume) }
            })
        }
    }

    /// A drive was connected or ejected: only a chosen folder on it (or one that's missing) is of interest.
    private func volumeChanged(_ volume: String?) {
        guard let volume else { return }
        let prefix = volume.hasSuffix("/") ? volume : volume + "/"
        let affected = model.settings.roots.contains { $0.path == volume || $0.path.hasPrefix(prefix) }
            || !model.status.missingRoots.isEmpty
        guard affected else { return }
        log("volume: \(volume) came or went")
        engine.volumesChanged()
    }

    // MARK: Folders

    /// The folders to index from now on, and those to skip in them (and the file types, when given); the engine
    /// follows without a relaunch. A folder another chosen one already searches is dropped (its files would be found
    /// twice), and so is a skip with nothing around it to skip from (`FolderSelection`).
    func applyFolders(_ roots: [URL], excluded: [URL]? = nil, types: [String]? = nil) {
        let selection = FolderSelection(chosen: roots.map { AppSettings.folderURL($0.path).path },
                                        skipped: (excluded ?? model.settings.excludedFolders).map(\.path))
        let roots = selection.folders.map(AppSettings.folderURL)
        let excluded = selection.effectiveSkips.map(AppSettings.folderURL)
        let types = types ?? model.settings.excludedTypes
        if roots.count < selection.chosen.count {
            log("folders: \(selection.chosen.count - roots.count) inside another chosen folder, already covered")
        }
        let settings = model.settings
        guard roots != settings.roots || excluded != settings.excludedFolders || types != settings.excludedTypes
        else { return }
        AppSettings.save(roots: roots)
        AppSettings.save(excludedFolders: excluded)
        AppSettings.save(excludedTypes: types)
        model.settings.roots = roots
        model.settings.excludedFolders = excluded
        model.settings.excludedTypes = types
        engine.setFolders(roots: roots, excluded: excluded, excludedTypes: types)
    }

    func removeFolder(_ root: URL) {
        applyFolders(model.settings.roots.filter { $0.path != root.path })
    }

    func setExcluded(_ folders: [URL]) {
        AppSettings.save(excludedFolders: folders)
        model.settings.excludedFolders = folders
        engine.setFolders(roots: model.settings.roots, excluded: folders, excludedTypes: model.settings.excludedTypes)
    }

    /// File extensions never to index ("heic, .txt"); files of those types already indexed leave the index.
    func setExcludedTypes(_ text: String) {
        let types = IndexOptions.extensions(text).sorted()
        guard types != model.settings.excludedTypes else { return }
        AppSettings.save(excludedTypes: types)
        model.settings.excludedTypes = types
        engine.setFolders(roots: model.settings.roots, excluded: model.settings.excludedFolders, excludedTypes: types)
    }

    func setIndexOnBattery(_ on: Bool) {
        AppSettings.save(indexOnBattery: on)
        model.settings.indexOnBattery = on
        power.setIndexOnBattery(on)
    }

    /// Photos and videos only (default), or every kind DigUp can read. Screenshots, PDFs, documents and audio leave
    /// the index when this turns on.
    func setPhotosAndVideoOnly(_ on: Bool) {
        guard on != model.settings.photosAndVideoOnly else { return }
        AppSettings.save(photosAndVideoOnly: on)
        model.settings.photosAndVideoOnly = on
        engine.setPhotosAndVideoOnly(on)
    }

    /// Asks for folders with the standard open panel (as a sheet when there's a window).
    func pickFolders(for window: NSWindow?, prompt: String = "Add", then done: @escaping ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.prompt = prompt
        panel.message = "Choose folders for DigUpPhotos to search."
        let finish = { (response: NSApplication.ModalResponse) in
            done(response == .OK ? panel.urls.map { AppSettings.folderURL($0.path) } : [])
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    /// No folders yet: onboarding if it never ran, else Settings' folder list with Add Folders open.
    func chooseFolders() {
        guard model.settings.onboarded else { return showOnboarding() }
        showSettings(.folders)
        settingsWindow.addFolders()
    }

    // MARK: Hotkey

    /// Nil when `combo` is now the hotkey, else why it can't be.
    func setHotkey(_ combo: KeyCombo) -> String? {
        if let conflict = combo.systemConflict { return conflict }
        guard hotkeys.register(combo) else { return "Another app is using \(combo.display)" }
        AppSettings.save(hotkey: combo.spec)
        model.settings.hotkey = combo.spec
        model.hotkey = combo
        log("hotkey: \(combo.display)")
        return nil
    }

    /// The shortcut recorder is listening (the hotkey steps aside so pressing it reaches the recorder).
    func hotkeyRecording(_ on: Bool) {
        if on { hotkeys.suspend() } else { hotkeys.resume() }
    }

    // MARK: Login item

    var launchesAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    /// Dev builds (anywhere but /Applications) don't suggest it, so trying a build never adds a login item.
    var suggestsLaunchAtLogin: Bool { Bundle.main.bundlePath.hasPrefix("/Applications/") }

    /// Nil when done, else why it failed.
    func setLaunchAtLogin(_ on: Bool) -> String? {
        guard on != launchesAtLogin else { return nil }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            log("login item: \(on ? "on" : "off")")
            return nil
        } catch {
            log("login item: \(error)")
            return error.localizedDescription
        }
    }

    // MARK: Windows

    func showSearchWindow(query: String? = nil, kind: ResultGroupKind? = nil) {
        searchWindow.show(query: query, kind: kind)
    }

    /// Copies the results on screen as absolute paths, one per line.
    func copySearchFileList() {
        guard let source = fileListSource() else { NSSound.beep(); return }
        let count = FileList.copy(source.rows, to: source.pasteboard)
        guard count > 0 else { NSSound.beep(); return }
        source.note(count)
    }

    /// Saves that same list as a text file.
    func exportSearchFileList() {
        guard let source = fileListSource() else { NSSound.beep(); return }
        let text = FileList.text(source.rows)
        guard !text.isEmpty else { NSSound.beep(); return }
        let save = NSSavePanel()
        save.allowedContentTypes = [.plainText]
        save.canCreateDirectories = true
        save.nameFieldStringValue = FileList.suggestedName(for: source.query)
        save.prompt = "Save"
        save.message = "One path per line, in the order of these results."
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = save.url else { return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                log("file list: \(error.localizedDescription)")
                NSAlert(error: error).runModal()
            }
        }
        if let window = NSApp.keyWindow {
            save.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(save.runModal())
        }
    }

    /// The search that's in front: the panel when it's key, otherwise the search window.
    private func fileListSource() -> (rows: [ResultRow], query: String, pasteboard: NSPasteboard, note: (Int) -> Void)? {
        let windowRows = searchWindow?.search.rows ?? []
        let panelRows = panel?.rows ?? []
        let panelKey = panel?.isVisible == true && NSApp.keyWindow?.windowNumber == panel?.windowNumber
        if panelKey, !panelRows.isEmpty, let panel {
            return (panelRows, panel.query, panel.pasteboard, { [weak panel] count in
                panel?.flashCopied(count)
            })
        }
        if searchWindow?.isVisible == true, !windowRows.isEmpty, let search = searchWindow?.search {
            return (windowRows, search.query, .general, { [weak search] count in search?.noteCopied(count) })
        }
        if panel?.isVisible == true, !panelRows.isEmpty, let panel {
            return (panelRows, panel.query, panel.pasteboard, { [weak panel] count in panel?.flashCopied(count) })
        }
        return nil
    }

    func showAlbums() {
        albumsWindow.show()
    }

    func showSettings(_ tab: SettingsTab = .general) {
        settingsWindow.show(tab)
    }

    func showOnboarding() {
        let onboarding = self.onboarding ?? OnboardingController(app: self)
        self.onboarding = onboarding
        onboarding.show()
    }

    /// Onboarding closed: by Done, or by its close button. Folders chosen by then count as set up.
    func onboardingClosed() {
        hotkeyTester = nil
        if model.hasFolders {
            AppSettings.saveOnboarded()
            model.settings.onboarded = true
        }
        onboarding = nil
        windowClosed()
    }

    /// Brings a window forward, with the Dock icon showing while any window is open. Offscreen test runs only build it.
    func present(_ window: NSWindow) {
        guard !Self.offscreen else { return }
        NSApp.setActivationPolicy(.regular)
        bringAppToFront()
        window.makeKeyAndOrderFront(nil)
    }

    /// A window closed: the Dock icon goes once none is left.
    func windowClosed() {
        DispatchQueue.main.async { [self] in
            let open = [searchWindow?.isVisible, albumsWindow?.isVisible, settingsWindow?.isVisible,
                        onboarding?.isVisible]
                .contains { $0 == true }
            if !open {
                NSApp.setActivationPolicy(.accessory)
                Thumbnails.shared.clear()
                Previews.shared.clear()
            }
        }
    }
}
