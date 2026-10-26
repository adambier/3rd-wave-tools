import AppKit
import Combine
import SwiftUI
// Sparkle (in-app updates) is linked by make-app.sh. Package.swift does not declare it, so a build
// through Xcode or a plain `swift build` compiles without it and has no "Check for Updates…" item.
#if canImport(Sparkle)
import Sparkle
#endif

// Built as a plain swiftc target (see make-app.sh), so the app is assembled here by hand
// rather than through the `App` protocol. Same structure as ThirdWaveWT.

let appName = "pgdata Packer"

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    #if canImport(Sparkle)
    // Starts the updater (scheduled checks follow the user's choice, which Sparkle asks for on the
    // second launch) and validates the "Check for Updates…" menu item.
    let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    #endif

    /// The app's state, set once it exists (it is made after the delegate; see the end of this file).
    var appState: AppState? { didSet { openPendingFiles() } }
    /// Files to open that arrived before the state existed (a launch by dropping files on the
    /// app's icon, should macOS deliver them that early).
    private var pendingOpenURLs: [URL] = []

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// The window's undo manager is the app state's, so Edit › Undo and Redo (sent to the first
    /// responder and on to the window) undo removals and renames in the pages' lists. While a
    /// text field is being edited, the field editor asks the window too, and gets a manager of
    /// its own: typing is undone within the field, and a committed name is undone as a rename,
    /// not as keystrokes in a field that is gone. The text manager is emptied when editing
    /// begins, so one field's typing is never undone in another.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        window.firstResponder is NSText ? textUndoManager : appState?.undoManager
    }
    private let textUndoManager = UndoManager()
    private var editingObserver: NSObjectProtocol?

    override init() {
        super.init()
        editingObserver = NotificationCenter.default.addObserver(forName: NSControl.textDidBeginEditingNotification, object: nil, queue: .main) { [weak self] _ in
            self?.textUndoManager.removeAllActions()
        }
    }

    /// Files dropped on the app's icon (in the Dock or the Finder). The app claims no file type
    /// (see the Info.plist in make-app.sh), so this is the one way the Finder hands it files.
    func application(_ application: NSApplication, open urls: [URL]) {
        pendingOpenURLs += urls
        openPendingFiles()
    }

    /// Sends the files waiting to be opened to the page that reads them: WAV and FLAC files to
    /// the Wavetables page; everything else, folders included, through `add(urls:)`, which puts
    /// 3rd Wave files on the Pack or Unpack page and shows it, as a drop on either page does.
    private func openPendingFiles() {
        guard let state = appState, !pendingOpenURLs.isEmpty else { return }
        let urls = pendingOpenURLs
        pendingOpenURLs = []
        let wavetables = urls.filter { ["wav", "wave", "flac"].contains($0.pathExtension.lowercased()) }
        let rest = urls.filter { !wavetables.contains($0) }
        if !wavetables.isEmpty {
            if state.showsWavetablesPage {
                state.addToConvert(urls: wavetables)
                if rest.isEmpty { state.section = .convert }
            } else {
                let n = wavetables.count
                state.note("\(n) WAV or FLAC file\(n == 1 ? "" : "s") not opened: the Wavetables page is under development and hidden (View › Show Under-Development Features).")
            }
        }
        if !rest.isEmpty { state.add(urls: rest) }
    }

    @objc func showAbout(_ sender: Any?) {
        // Centered paragraphs with a blank line's space between them.
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.paragraphSpacing = NSFont.smallSystemFontSize
        let source = "github.com/adambier/3rd-wave-tools"
        let credits = NSMutableAttributedString(
            string: "Packs and unpacks unified program data (.pgdata) files for the Groove Synthesis 3rd Wave, and converts wavetables to and from its formats.\n"
                + "Not affiliated with or endorsed by Groove Synthesis.\n"
                + "Source: \(source)",   // the license is the panel’s copyright line (NSHumanReadableCopyright)
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                         .foregroundColor: NSColor.secondaryLabelColor,
                         .paragraphStyle: para])
        // The address is a link; the About panel's credits view opens it when clicked.
        if let url = URL(string: "https://\(source)") {
            credits.addAttribute(.link, value: url, range: (credits.string as NSString).range(of: source))
        }
        NSApplication.shared.orderFrontStandardAboutPanel(options: [.applicationName: appName, .credits: credits])
    }

    private static let repository = "https://github.com/adambier/3rd-wave-tools"

    /// The running version, from the Info.plist that make-app.sh writes; nil in a build without it.
    private var runningVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// Opens `url` if GitHub answers for it, and `fallback` if it does not or cannot be reached.
    /// Pages for the running version do not exist yet in a build of a version not yet released.
    private func openIfAvailable(_ url: URL, orElse fallback: URL) {
        Task { @MainActor in
            var request = URLRequest(url: url, timeoutInterval: 5)
            request.httpMethod = "HEAD"
            let exists = ((try? await URLSession.shared.data(for: request))?.1 as? HTTPURLResponse)?.statusCode == 200
            NSWorkspace.shared.open(exists ? url : fallback)
        }
    }

    /// Opens the GitHub release page for the running version. Falls back to the list of all
    /// releases when that page does not exist (a build of a version not yet released), when the
    /// version is unknown (a build without make-app.sh's Info.plist), or when GitHub cannot be
    /// reached to check.
    @objc func showReleaseNotes(_ sender: Any?) {
        guard let allReleases = URL(string: "\(Self.repository)/releases") else { return }
        guard let version = runningVersion else {
            NSWorkspace.shared.open(allReleases)
            return
        }
        openIfAvailable(allReleases.appendingPathComponent("tag").appendingPathComponent("v\(version)"), orElse: allReleases)
    }

    /// Opens the README as it was at the running version's tag, since it describes the app (the
    /// Help menu's first item); falls back to the current README on main, as Release Notes does.
    @objc func showHelp(_ sender: Any?) {
        guard let current = URL(string: "\(Self.repository)/blob/main/README.md") else { return }
        guard let version = runningVersion,
              let tagged = URL(string: "\(Self.repository)/blob/v\(version)/README.md") else {
            NSWorkspace.shared.open(current)
            return
        }
        openIfAvailable(tagged, orElse: current)
    }

    /// Opens the current file format reference on main. It describes the 3rd Wave's files, not
    /// this version of the app, so the latest corrections apply whatever version is running.
    @objc func showFormats(_ sender: Any?) {
        guard let url = URL(string: "\(Self.repository)/blob/main/docs/FORMATS.md") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// The target of the menu items whose action, title, or state depends on the page: the File
/// menu's commands and the View menu's pages and log. Validation gives the dynamic items their
/// titles and check marks, and disables a command when the page's own button for it is disabled
/// (see the `controls` of PackView, UnpackView, and ConvertView) or while a pack, unpack, or
/// conversion is running.
final class MenuActions: NSObject, NSMenuItemValidation {
    /// Edit › Delete (the Delete key, as the HIG has it). The item is this object's, not the
    /// first responder's, so that it can stay out of the way of text: while a text field is
    /// being edited the item is disabled and the key deletes a character, as it should; with a
    /// list focused, the item is enabled when that list has rows selected (`ListCommands`,
    /// keyed by the table view that is the first responder), and removes them (undoable).
    @objc func deleteSelection(_ sender: Any?) {
        ListCommands.shared.handlers(forFirstResponderOf: NSApp.keyWindow)?.delete?()
    }

    private var textIsBeingEdited: Bool {
        NSApp.keyWindow?.firstResponder is NSText
    }
    private let appState: AppState
    /// The Return key's event monitor (`installReturnKey`), kept for the app's life.
    private var returnKeyMonitor: Any?

    init(appState: AppState) {
        self.appState = appState
        super.init()
    }

    /// A plain Return (or keypad Enter) pressed while a list has the focus edits the selected
    /// row's name, as in the Finder (`ListCommands`; there is no menu item for it, since Return is
    /// the Finder's way, not a menu shortcut). The event is swallowed only when the list has a
    /// rename to do (one row selected); otherwise it goes on as before. Text being edited keeps
    /// its Return (the first responder is then the field editor, not the table), as do a
    /// focused button or pop-up, which Return presses (`ListCommands` would otherwise answer
    /// for the list showing a selection, which is right for Delete but not here).
    func installReturnKey() {
        returnKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { (event: NSEvent) -> NSEvent? in
            let returnKey: UInt16 = 36, keypadEnter: UInt16 = 76
            guard event.keyCode == returnKey || event.keyCode == keypadEnter,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  event.window === NSApp.keyWindow,
                  !(NSApp.keyWindow?.firstResponder is NSButton),
                  let rename = ListCommands.shared.handlers(forFirstResponderOf: NSApp.keyWindow)?.rename else { return event }
            rename()
            return nil
        }
    }

    /// The current page's "Add Files or Folders…": the same panel as its button, with files of
    /// other kinds dimmed.
    @objc func addFiles(_ sender: Any?) {
        switch appState.section {
        case .pack:
            appState.add(urls: Panels.chooseFiles(message: "Choose .pro programs and the .wt and .bin files they use",
                                                  allowedExtensions: ["pro", "wt", "bin", "pgdata"]))
        case .unpack:
            appState.add(urls: Panels.chooseFiles(message: "Choose .pgdata files to unpack",
                                                  allowedExtensions: ["pgdata"]))
        case .convert:
            appState.addToConvert(urls: Panels.chooseFiles(message: "Choose wavetable files (.wav, .flac, .wt, .pgdata) or folders to search",
                                                           allowedExtensions: ["wav", "flac", "wt", "pgdata"]))
        }
    }

    /// The current page's main action: Pack All…, Unpack All…, or Convert All….
    @objc func mainAction(_ sender: Any?) {
        switch appState.section {
        case .pack: appState.writeUnified(appState.programs.map(\.id))
        case .unpack: appState.unpack(appState.unpacks.map(\.id))
        case .convert: appState.convertTables()
        }
    }

    /// Shows the page the item's tag names (its index in `AppState.Section.allCases`).
    @objc func showPage(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        let sections = AppState.Section.allCases
        guard sections.indices.contains(item.tag) else { return }
        appState.section = sections[item.tag]
    }

    @objc func toggleLog(_ sender: Any?) {
        appState.showLog.toggle()
    }

    /// View › Show Under-Development Features: shows or hides the Wavetables page (and the audio
    /// output in the toolbar) while wavetable conversion is being tested.
    @objc func toggleUnderDevelopmentFeatures(_ sender: Any?) {
        appState.showsUnderDevelopmentFeatures.toggle()
    }

    private var mainActionTitle: String {
        switch appState.section {
        case .pack: return "Pack All…"
        case .unpack: return "Unpack All…"
        case .convert: return "Convert All…"
        }
    }

    /// Mirrors the `.disabled` condition of the page's own button.
    private var mainActionEnabled: Bool {
        guard !appState.isWorking else { return false }
        switch appState.section {
        case .pack: return !appState.programs.isEmpty
        case .unpack: return !appState.unpacks.isEmpty
        case .convert: return !appState.convertPlan.includedItems.isEmpty
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let action = menuItem.action else { return true }
        switch action {
        case #selector(addFiles(_:)):
            return !appState.isWorking
        case #selector(mainAction(_:)):
            menuItem.title = mainActionTitle
            return mainActionEnabled
        case #selector(showPage(_:)):
            let sections = AppState.Section.allCases
            let current = sections.firstIndex(of: appState.section) ?? -1
            menuItem.state = menuItem.tag == current ? .on : .off
            // A page under development is out of the menu while hidden (its ⌘3 with it).
            let shown = sections.indices.contains(menuItem.tag) && appState.availableSections.contains(sections[menuItem.tag])
            menuItem.isHidden = !shown
            return shown
        case #selector(toggleUnderDevelopmentFeatures(_:)):
            // Out of the menu, with the separator above it, once no page is under development.
            let gated = AppState.hasUnderDevelopmentSections
            menuItem.isHidden = !gated
            menuItem.menu?.items.last(where: { $0.isSeparatorItem })?.isHidden = !gated
            menuItem.state = appState.showsUnderDevelopmentFeatures ? .on : .off
            return gated
        case #selector(toggleLog(_:)):
            menuItem.title = appState.showLog ? "Hide Log" : "Show Log"
            return true
        case #selector(deleteSelection(_:)):
            return !textIsBeingEdited && ListCommands.shared.handlers(forFirstResponderOf: NSApp.keyWindow)?.delete != nil
        default:
            return true
        }
    }
}

/// The window's toolbar: one control, the page switcher, centered. It follows `AppState.section`
/// (which the View menu also sets) and sets it.
final class ToolbarController: NSObject, NSToolbarDelegate, NSMenuDelegate {
    private static let pageItem = NSToolbarItem.Identifier("page")
    private static let outputItem = NSToolbarItem.Identifier("audioOutput")
    private let appState: AppState
    private weak var toolbar: NSToolbar?
    private weak var control: NSSegmentedControl?
    private weak var outputItem: NSMenuToolbarItem?
    private var cancellables: Set<AnyCancellable> = []
    private var outputCancellable: AnyCancellable?

    init(appState: AppState) {
        self.appState = appState
        super.init()
        appState.$section.sink { [weak self] (section: AppState.Section) in
            guard let self, let control = self.control else { return }
            control.selectedSegment = self.appState.availableSections.firstIndex(of: section) ?? 0
        }.store(in: &cancellables)
        // The pages offered, and the audio output beside them, follow View › Show
        // Under-Development Features (the one time this toolbar's items change).
        appState.$showsUnderDevelopmentFeatures.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self else { return }
            self.fillSegments()
            self.showOutputItem(self.appState.showsWavetablesPage)   // not the toggle: the page shows by default once nothing gates it
        }.store(in: &cancellables)
    }

    func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.displayMode = .iconOnly
        toolbar.centeredItemIdentifier = Self.pageItem
        self.toolbar = toolbar
        return toolbar
    }

    // The page switcher in the center; at the trailing end, while the Wavetables page is shown,
    // the audio output for its Listen control. The output item is there on every page then: a
    // toolbar whose items come and go with the page is what the HIG advises against, and the
    // device is one setting for the app.
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.pageItem, .flexibleSpace] + (appState.showsWavetablesPage ? [Self.outputItem] : [])
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.pageItem, Self.outputItem]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if itemIdentifier == Self.outputItem { return makeOutputItem() }
        guard itemIdentifier == Self.pageItem else { return nil }
        let control = NSSegmentedControl(labels: [], trackingMode: .selectOne, target: self, action: #selector(pageChosen(_:)))
        control.segmentStyle = .automatic
        control.setAccessibilityLabel("Page")
        self.control = control
        fillSegments()
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.view = control
        item.label = "Page"
        item.paletteLabel = "Page"
        item.isNavigational = false
        return item
    }

    /// One segment per page offered (`AppState.availableSections`), the current one selected.
    private func fillSegments() {
        guard let control else { return }
        let sections = appState.availableSections
        control.segmentCount = sections.count
        for (i, s) in sections.enumerated() {
            control.setLabel(s.rawValue, forSegment: i)
            control.setImage(NSImage(systemSymbolName: s.icon, accessibilityDescription: s.rawValue), forSegment: i)
            control.setImageScaling(.scaleProportionallyDown, forSegment: i)
        }
        control.selectedSegment = sections.firstIndex(of: appState.section) ?? 0
        control.sizeToFit()
    }

    /// Adds or removes the audio output item at the toolbar's trailing end.
    private func showOutputItem(_ shows: Bool) {
        guard let toolbar else { return }
        let index = toolbar.items.firstIndex { $0.itemIdentifier == Self.outputItem }
        if shows, index == nil {
            toolbar.insertItem(withItemIdentifier: Self.outputItem, at: toolbar.items.count)
        } else if !shows, let index {
            toolbar.removeItem(at: index)
        }
    }

    @objc private func pageChosen(_ sender: NSSegmentedControl) {
        let sections = appState.availableSections
        guard sections.indices.contains(sender.selectedSegment) else { return }
        appState.section = sections[sender.selectedSegment]
    }

    // MARK: Audio output

    /// A speaker icon with a menu of the output devices, "System Default" first, the one in use
    /// checked (the HIG's toolbar menu with a selected state, as Finder's grouping menu); the
    /// list follows `AudioPreview`'s as devices come and go. The tip names the device in use.
    private func makeOutputItem() -> NSToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: Self.outputItem)
        item.image = NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: "Audio Output")
        item.label = "Audio Output"
        item.paletteLabel = "Audio Output"
        item.showsIndicator = true
        outputItem = item
        fillOutputMenu()
        outputCancellable = AudioPreview.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.fillOutputMenu() }
        return item
    }

    /// Whether the menu is open: it is not filled again meanwhile (dragging the volume slider
    /// changes the audio state on every tick), only once it closes. The volume row is a new
    /// view each time the menu is filled: a view that has been shown in a menu and is then
    /// given to a new item came back as a sliver of slider (Adam, 2026-10-26: the slider went
    /// after the first Listen, which changes the device list and so refills the menu).
    private var outputMenuIsOpen = false
    private var outputMenuNeedsFilling = false

    func menuWillOpen(_ menu: NSMenu) { outputMenuIsOpen = true }

    func menuDidClose(_ menu: NSMenu) {
        outputMenuIsOpen = false
        if outputMenuNeedsFilling { DispatchQueue.main.async { [weak self] in self?.fillOutputMenu() } }
    }

    private func fillOutputMenu() {
        guard let item = outputItem else { return }
        guard !outputMenuIsOpen else { outputMenuNeedsFilling = true; return }
        outputMenuNeedsFilling = false
        let preview = AudioPreview.shared
        let chosen = preview.effectiveOutputDevice
        let menu = NSMenu()
        menu.delegate = self
        let header = NSMenuItem(title: "Audio Output for Listen", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        // The level, as the system's Sound menu has it: a slider between two speaker icons.
        let volumeItem = NSMenuItem()
        volumeItem.view = VolumeMenuView(volume: preview.volume) { AudioPreview.shared.volume = $0 }
        menu.addItem(volumeItem)
        menu.addItem(.separator())
        let defaultItem = NSMenuItem(title: "System Default", action: #selector(outputChosen(_:)), keyEquivalent: "")
        defaultItem.target = self
        defaultItem.state = chosen == nil ? .on : .off
        menu.addItem(defaultItem)
        if !preview.outputDevices.isEmpty { menu.addItem(.separator()) }
        for device in preview.outputDevices {
            let deviceItem = NSMenuItem(title: device.name, action: #selector(outputChosen(_:)), keyEquivalent: "")
            deviceItem.target = self
            deviceItem.representedObject = device.uid
            deviceItem.state = chosen?.uid == device.uid ? .on : .off
            menu.addItem(deviceItem)
        }
        item.menu = menu
        item.toolTip = "Audio output for the Wavetables page’s Listen control: " + (chosen?.name ?? "System Default")
    }

    @objc private func outputChosen(_ sender: NSMenuItem) {
        AudioPreview.shared.outputDeviceUID = sender.representedObject as? String
    }
}

/// A menu item's view: "Volume", then a slider between a quiet and a loud speaker icon, for the
/// level Listen plays at (`AudioPreview.volume`). The system's Sound menu has the same shape.
/// The label starts where the menu's item titles do (after the check-mark column), and the
/// slider runs to the menu's right margin, whatever width the menu takes.
final class VolumeMenuView: NSView {
    private let slider = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let label = NSTextField(labelWithString: "Volume")
    private let quiet = NSImageView(image: NSImage(systemSymbolName: "speaker.fill", accessibilityDescription: nil) ?? NSImage())
    private let loud = NSImageView(image: NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: nil) ?? NSImage())
    private let changed: (Float) -> Void

    /// Where a menu item's title begins, so "Volume" lines up with the titles under it: 32
    /// points on macOS 14 and later (14 of menu padding and an 18-point check-mark column,
    /// measured on Adam's display, 2026-10-26), 21 on macOS 13's menus. The right margin is
    /// the menu's padding.
    private static var titleInset: CGFloat { if #available(macOS 14, *) { return 32 } else { return 21 } }
    private static var rightMargin: CGFloat { if #available(macOS 14, *) { return 14 } else { return 12 } }
    private static let height: CGFloat = 28

    // Laid out by Auto Layout, not by frames: a menu sizes a custom item view from its
    // constraints and intrinsic size, and lays it out when the menu opens, by which time a
    // frame-based layout done at init (or in `layout()` with a zero-height bounds) had put the
    // label and icons outside the view, leaving a sliver of slider (Adam, 2026-10-26: the
    // slider "disappeared" on 75d1724).
    init(volume: Float, changed: @escaping (Float) -> Void) {
        self.changed = changed
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: Self.height))
        autoresizingMask = [.width]   // the menu gives the view its width
        label.font = NSFont.menuFont(ofSize: 0)
        label.textColor = .labelColor
        quiet.contentTintColor = .secondaryLabelColor
        loud.contentTintColor = .secondaryLabelColor
        slider.controlSize = .small
        slider.isContinuous = true
        slider.doubleValue = Double(volume)
        slider.target = self
        slider.action = #selector(slid(_:))
        slider.setAccessibilityLabel("Volume")
        for view in [label, quiet, slider, loud] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.titleInset),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            quiet.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 10),
            quiet.centerYAnchor.constraint(equalTo: centerYAnchor),
            quiet.widthAnchor.constraint(equalToConstant: 14),
            quiet.heightAnchor.constraint(equalToConstant: 14),
            slider.leadingAnchor.constraint(equalTo: quiet.trailingAnchor, constant: 6),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor),
            slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 60),
            loud.leadingAnchor.constraint(equalTo: slider.trailingAnchor, constant: 6),
            loud.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.rightMargin),
            loud.centerYAnchor.constraint(equalTo: centerYAnchor),
            loud.widthAnchor.constraint(equalToConstant: 18),
            loud.heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    required init?(coder: NSCoder) { nil }

    /// The size the menu starts from; the menu widens the view to its own width.
    override var intrinsicContentSize: NSSize { NSSize(width: 280, height: Self.height) }

    @objc private func slid(_ sender: NSSlider) {
        changed(Float(sender.doubleValue))
    }
}

/// The menu bar. Items that depend on the page have `menuActions` as their target; the rest go to
/// the first responder or to `appDelegate`.
private func buildMainMenu(appDelegate: AppDelegate, menuActions: MenuActions) -> NSMenu {
    let mainMenu = NSMenu()

    let appMenuItem = NSMenuItem()
    let appMenu = NSMenu()
    let name = appName
    appMenu.addItem(withTitle: "About \(name)", action: #selector(AppDelegate.showAbout(_:)), keyEquivalent: "")
    #if canImport(Sparkle)
    let updateItem = appMenu.addItem(withTitle: "Check for Updates…",
                                     action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                                     keyEquivalent: "")
    updateItem.target = appDelegate.updaterController
    #endif
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Hide \(name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
    hideOthers.keyEquivalentModifierMask = [.command, .option]
    appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appMenuItem.submenu = appMenu
    mainMenu.addItem(appMenuItem)

    // File: the current page's commands (validation gives the main one its title) and Close.
    let fileMenuItem = NSMenuItem()
    let fileMenu = NSMenu(title: "File")
    let addItem = fileMenu.addItem(withTitle: "Add Files or Folders…", action: #selector(MenuActions.addFiles(_:)), keyEquivalent: "o")
    addItem.target = menuActions
    let mainItem = fileMenu.addItem(withTitle: "Pack All…", action: #selector(MenuActions.mainAction(_:)), keyEquivalent: "e")
    mainItem.keyEquivalentModifierMask = [.command, .shift]
    mainItem.target = menuActions
    fileMenu.addItem(.separator())
    fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    fileMenuItem.submenu = fileMenu
    mainMenu.addItem(fileMenuItem)

    let editMenuItem = NSMenuItem()
    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
    editMenu.addItem(.separator())
    editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editMenu.addItem(.separator())
    // Delete, on the Delete key, as the HIG's Edit menu has it (`MenuActions.deleteSelection`
    // validates it and passes it to the focused list through `ListCommands`, which has a
    // handler only while rows are selected; removals are undoable). An earlier ⌘⌫ was Finder's
    // Move to Trash shortcut, not the Edit menu's.
    let deleteItem = editMenu.addItem(withTitle: "Delete", action: #selector(MenuActions.deleteSelection(_:)), keyEquivalent: "\u{8}")
    deleteItem.keyEquivalentModifierMask = []
    deleteItem.target = menuActions
    editMenuItem.submenu = editMenu
    mainMenu.addItem(editMenuItem)

    // View: the pages (⌘1–⌘3; validation checks the current one) and the log.
    let viewMenuItem = NSMenuItem()
    let viewMenu = NSMenu(title: "View")
    for (i, section) in AppState.Section.allCases.enumerated() {
        let item = viewMenu.addItem(withTitle: section.rawValue, action: #selector(MenuActions.showPage(_:)), keyEquivalent: "\(i + 1)")
        item.tag = i
        item.target = menuActions
    }
    viewMenu.addItem(.separator())
    let logItem = viewMenu.addItem(withTitle: "Show Log", action: #selector(MenuActions.toggleLog(_:)), keyEquivalent: "l")
    logItem.keyEquivalentModifierMask = [.command, .option]
    logItem.target = menuActions
    viewMenu.addItem(.separator())
    // A checkmark item, as the HIG has for a setting toggled from a menu; validation sets its state.
    let devItem = viewMenu.addItem(withTitle: "Show Under-Development Features", action: #selector(MenuActions.toggleUnderDevelopmentFeatures(_:)), keyEquivalent: "")
    devItem.target = menuActions
    devItem.toolTip = "Show the Wavetables page, which converts wavetables between synths and is still being tested"
    viewMenuItem.submenu = viewMenu
    mainMenu.addItem(viewMenuItem)

    let windowMenuItem = NSMenuItem()
    let windowMenu = NSMenu(title: "Window")
    windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
    windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
    windowMenu.addItem(.separator())
    windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
    windowMenuItem.submenu = windowMenu
    mainMenu.addItem(windowMenuItem)
    NSApplication.shared.windowsMenu = windowMenu

    let helpMenuItem = NSMenuItem()
    let helpMenu = NSMenu(title: "Help")
    helpMenu.addItem(withTitle: "\(name) Help", action: #selector(AppDelegate.showHelp(_:)), keyEquivalent: "")
    helpMenu.addItem(withTitle: "File Format Reference", action: #selector(AppDelegate.showFormats(_:)), keyEquivalent: "")
    helpMenu.addItem(.separator())
    helpMenu.addItem(withTitle: "Release Notes", action: #selector(AppDelegate.showReleaseNotes(_:)), keyEquivalent: "")
    helpMenuItem.submenu = helpMenu
    mainMenu.addItem(helpMenuItem)
    NSApplication.shared.helpMenu = helpMenu

    return mainMenu
}

let application = NSApplication.shared
application.setActivationPolicy(.regular)

let appDelegate = AppDelegate()
application.delegate = appDelegate

let appState = AppState()
appDelegate.appState = appState
let menuActions = MenuActions(appState: appState)
menuActions.installReturnKey()
let toolbarController = ToolbarController(appState: appState)
application.mainMenu = buildMainMenu(appDelegate: appDelegate, menuActions: menuActions)

// The default size is the one that fits the smallest display the app is expected on, a 13-inch
// MacBook with the Dock showing (about 1,470 × 860 points of visible frame), and the pages are
// laid out to give their best at that size, the Wavetables table giving way to its right pane
// (Adam, 2026-10-26). On a larger display the window opens at the same size and can be
// enlarged; on a smaller one it is capped to the screen. The minimum is set in ContentView
// (1,000 × 700).
let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1470, height: 860)
let defaultSize = NSSize(width: min(1440, visible.width - 24), height: min(860, visible.height - 40))
let window = NSWindow(
    contentRect: NSRect(origin: .zero, size: defaultSize),
    styleMask: [.titled, .closable, .miniaturizable, .resizable],
    backing: .buffered,
    defer: false
)
window.title = appName
window.isReleasedWhenClosed = false
window.delegate = appDelegate
// The page switcher sits in the toolbar beside the title, as a view switcher does on the Mac.
window.titleVisibility = .visible
window.toolbarStyle = .unified
window.toolbar = toolbarController.makeToolbar()
let hosting = NSHostingView(rootView: ContentView().environmentObject(appState))
// By default (macOS 13+) the hosting view also sizes the window to the content's ideal size,
// which overrode the default size above. Let it set only the minimum.
hosting.sizingOptions = [.minSize]
window.contentView = hosting
window.setContentSize(defaultSize)
// New autosave name: frames saved under the earlier names were saved too narrow.
if !window.setFrameUsingName("MainWindow3") { window.center() }
window.setFrameAutosaveName("MainWindow3")
window.makeKeyAndOrderFront(nil)

application.activate(ignoringOtherApps: true)
application.run()
