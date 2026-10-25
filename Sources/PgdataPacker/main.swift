import AppKit
import SwiftUI
// Sparkle (in-app updates) is linked by make-app.sh. Package.swift does not declare it, so a build
// through Xcode or a plain `swift build` compiles without it and has no "Check for Updates…" item.
#if canImport(Sparkle)
import Sparkle
#endif

// Built as a plain swiftc target (see make-app.sh), so the app is assembled here by hand
// rather than through the `App` protocol. Same structure as ThirdWaveWT.

let appName = "pgdata Packer"

final class AppDelegate: NSObject, NSApplicationDelegate {
    #if canImport(Sparkle)
    // Starts the updater (scheduled checks follow the user's choice, which Sparkle asks for on the
    // second launch) and validates the "Check for Updates…" menu item.
    let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    #endif

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @objc func showAbout(_ sender: Any?) {
        // Centred paragraphs with a blank line's space between them.
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.paragraphSpacing = NSFont.smallSystemFontSize
        let source = "github.com/adambier/3rd-wave-tools"
        let credits = NSMutableAttributedString(
            string: "Packs and unpacks unified program data (.pgdata) files for the Groove Synthesis 3rd Wave, and converts wavetables to and from its formats.\n"
                + "Not affiliated with or endorsed by Groove Synthesis.\n"
                + "Source: \(source)",   // the licence is the panel's copyright line (NSHumanReadableCopyright)
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

    /// Opens the README as it was at the running version's tag, since it describes the app; falls
    /// back to the current README on main, as Release Notes does.
    @objc func showReadMe(_ sender: Any?) {
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

private func buildMainMenu(appDelegate: AppDelegate) -> NSMenu {
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
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appMenuItem.submenu = appMenu
    mainMenu.addItem(appMenuItem)

    let editMenuItem = NSMenuItem()
    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
    editMenu.addItem(.separator())
    editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editMenuItem.submenu = editMenu
    mainMenu.addItem(editMenuItem)

    let windowMenuItem = NSMenuItem()
    let windowMenu = NSMenu(title: "Window")
    windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
    windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
    windowMenu.addItem(.separator())
    windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    windowMenuItem.submenu = windowMenu
    mainMenu.addItem(windowMenuItem)
    NSApplication.shared.windowsMenu = windowMenu

    let helpMenuItem = NSMenuItem()
    let helpMenu = NSMenu(title: "Help")
    helpMenu.addItem(withTitle: "Read Me", action: #selector(AppDelegate.showReadMe(_:)), keyEquivalent: "")
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
application.mainMenu = buildMainMenu(appDelegate: appDelegate)

let appState = AppState()

// Wide enough for the sidebar, the program list and every column of the Pack tables, but never
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
