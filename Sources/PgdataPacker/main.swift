import AppKit
import SwiftUI

// Built as a plain swiftc target (see make-app.sh), so the app is assembled here by hand
// rather than through the `App` protocol. Same structure as ThirdWaveWT.

let appName = "pgdata Packer"

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @objc func showAbout(_ sender: Any?) {
        let credits = NSAttributedString(
            string: "Packs and unpacks unified program data (.pgdata) files for the Groove Synthesis 3rd Wave.\n"
                + "Not affiliated with or endorsed by Groove Synthesis.",
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                         .foregroundColor: NSColor.secondaryLabelColor])
        NSApplication.shared.orderFrontStandardAboutPanel(options: [.applicationName: appName, .credits: credits])
    }
}

private func buildMainMenu() -> NSMenu {
    let mainMenu = NSMenu()

    let appMenuItem = NSMenuItem()
    let appMenu = NSMenu()
    let name = appName
    appMenu.addItem(withTitle: "About \(name)", action: #selector(AppDelegate.showAbout(_:)), keyEquivalent: "")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Hide \(name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appMenuItem.submenu = appMenu
    mainMenu.addItem(appMenuItem)

    let editMenuItem = NSMenuItem()
    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editMenuItem.submenu = editMenu
    mainMenu.addItem(editMenuItem)

    return mainMenu
}

let application = NSApplication.shared
application.setActivationPolicy(.regular)
application.mainMenu = buildMainMenu()

let appDelegate = AppDelegate()
application.delegate = appDelegate

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
