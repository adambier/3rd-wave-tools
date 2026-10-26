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
    /// responder and on to the window) undo removals from the pages' lists.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { appState?.undoManager }

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
            state.addToConvert(urls: wavetables)
            if rest.isEmpty { state.section = .convert }
        }
        if !rest.isEmpty { state.add(urls: rest) }
    }

    @objc func showAbout(_ sender: Any?) {
        // Centred paragraphs with a blank line's space between them.
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.paragraphSpacing = NSFont.smallSystemFontSize
        let source = "github.com/adambier/3rd-wave-tools"
        let credits = NSMutableAttributedString(
            string: "Packs and unpacks unified program data (.pgdata) files for the Groove Synthesis 3rd Wave, and converts wavetables to and from its formats.\n"
                + "Not affiliated with or endorsed by Groove Synthesis.\n"
                + "Source: \(source)",   // the licence is the panel’s copyright line (NSHumanReadableCopyright)
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
    /// What Edit › Delete sends down the responder chain; the pages' lists answer it with
    /// `.onCommand(MenuActions.removeSelected)` by removing their selected rows (undoable).
    static let removeSelected = NSSelectorFromString("removeSelected:")

    /// Edit › Delete (the Delete key, as the HIG has it). The item is this object's, not the
    /// first responder's, so that it can stay out of the way of text: while a text field is
    /// being edited the item is disabled and the key deletes a character, as it should; with a
    /// list focused the item is enabled when the list answers `removeSelected:`.
    @objc func deleteSelection(_ sender: Any?) {
        _ = NSApp.sendAction(Self.removeSelected, to: nil, from: self)
    }

    private var textIsBeingEdited: Bool {
        NSApp.keyWindow?.firstResponder is NSText
    }
    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
        super.init()
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

    /// The current page's main action: Pack All…, Unpack All…, or Convert….
    @objc func mainAction(_ sender: Any?) {
        switch appState.section {
        case .pack: appState.writeUnified(appState.programs.map(\.id))
        case .unpack: appState.unpack(appState.unpacks.map(\.id))
        case .convert: appState.convertTables()
        }
    }

    /// The Wavetables page's "Send to Pack…".
    @objc func sendToPack(_ sender: Any?) {
        appState.convertTables(sendToPack: true)
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

    private var mainActionTitle: String {
        switch appState.section {
        case .pack: return "Pack All…"
        case .unpack: return "Unpack All…"
        case .convert: return "Convert…"
        }
    }

    /// Mirrors the `.disabled` condition of the page's own button.
    private var mainActionEnabled: Bool {
        guard !appState.isWorking else { return false }
        switch appState.section {
        case .pack: return !appState.programs.isEmpty
        case .unpack: return !appState.unpacks.isEmpty
        case .convert: return !appState.convertPlan.selectedItems.isEmpty
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
        case #selector(sendToPack(_:)):
            // Enabled as the Wavetables page's button is: tables marked, and a 3rd Wave destination.
            let plan = appState.convertPlan
            return appState.section == .convert && !appState.isWorking
                && !plan.selectedItems.isEmpty && plan.preset.isThirdWave
        case #selector(showPage(_:)):
            let current = AppState.Section.allCases.firstIndex(of: appState.section) ?? -1
            menuItem.state = menuItem.tag == current ? .on : .off
            return true
        case #selector(toggleLog(_:)):
            menuItem.title = appState.showLog ? "Hide Log" : "Show Log"
            return true
        case #selector(deleteSelection(_:)):
            return !textIsBeingEdited && NSApp.target(forAction: Self.removeSelected, to: nil, from: self) != nil
        default:
            return true
        }
    }
}

/// The window's toolbar: one control, the page switcher, centred. It follows `AppState.section`
/// (which the View menu also sets) and sets it.
final class ToolbarController: NSObject, NSToolbarDelegate {
    private static let pageItem = NSToolbarItem.Identifier("page")
    private static let outputItem = NSToolbarItem.Identifier("audioOutput")
    private let appState: AppState
    private weak var control: NSSegmentedControl?
    private weak var outputItem: NSMenuToolbarItem?
    private var cancellable: AnyCancellable?
    private var outputCancellable: AnyCancellable?

    init(appState: AppState) {
        self.appState = appState
        super.init()
        cancellable = appState.$section.sink { [weak self] (section: AppState.Section) in
            self?.control?.selectedSegment = AppState.Section.allCases.firstIndex(of: section) ?? 0
        }
    }

    func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.displayMode = .iconOnly
        toolbar.centeredItemIdentifier = Self.pageItem
        return toolbar
    }

    // The page switcher in the centre; at the trailing end, the audio output for the Wavetables
    // page's Listen control. The output pop-up is there on every page: a toolbar whose items
    // come and go with the page is what the HIG advises against, and the device is one setting
    // for the app.
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.pageItem, .flexibleSpace, Self.outputItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.pageItem, Self.outputItem]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if itemIdentifier == Self.outputItem { return makeOutputItem() }
        guard itemIdentifier == Self.pageItem else { return nil }
        let sections = AppState.Section.allCases
        let control = NSSegmentedControl(labels: sections.map(\.rawValue), trackingMode: .selectOne,
                                         target: self, action: #selector(pageChosen(_:)))
        control.segmentStyle = .automatic
        for (i, s) in sections.enumerated() {
            control.setImage(NSImage(systemSymbolName: s.icon, accessibilityDescription: s.rawValue), forSegment: i)
            control.setImageScaling(.scaleProportionallyDown, forSegment: i)
        }
        control.selectedSegment = sections.firstIndex(of: appState.section) ?? 0
        control.setAccessibilityLabel("Page")
        self.control = control
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.view = control
        item.label = "Page"
        item.paletteLabel = "Page"
        item.isNavigational = false
        return item
    }

    @objc private func pageChosen(_ sender: NSSegmentedControl) {
        let sections = AppState.Section.allCases
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

    private func fillOutputMenu() {
        guard let item = outputItem else { return }
        let preview = AudioPreview.shared
        let chosen = preview.effectiveOutputDevice
        let menu = NSMenu()
        let header = NSMenuItem(title: "Audio Output for Listen", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
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
    let sendItem = fileMenu.addItem(withTitle: "Send to Pack…", action: #selector(MenuActions.sendToPack(_:)), keyEquivalent: "")
    sendItem.target = menuActions
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
    // validates it and passes it to the focused list; removals are undoable). An earlier ⌘⌫ was
    // Finder's Move to Trash shortcut, not the Edit menu's.
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
let toolbarController = ToolbarController(appState: appState)
application.mainMenu = buildMainMenu(appDelegate: appDelegate, menuActions: menuActions)

// Wide enough for the program list and every column of the Pack and Wavetables tables, but never
// larger than the screen.
let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1512, height: 900)
let defaultSize = NSSize(width: min(1560, visible.width - 24), height: min(900, visible.height - 40))
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
