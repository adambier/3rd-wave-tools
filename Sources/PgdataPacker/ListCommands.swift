import SwiftUI
import AppKit

/// What each page's list does on Edit › Delete (the Delete key) and on Return: the list's own
/// closures, kept by the `NSTableView` behind the SwiftUI `List` or `Table`, so that a command
/// reaches the list that has the keyboard focus (the window's first responder) whatever
/// SwiftUI's own command routing does. (`.onCommand` on a `List` or `Table` did not answer
/// `NSApp.target(forAction:)` on macOS 13: Edit › Delete stayed disabled and the key beeped in
/// the table, and Return reached only the tables whose double-click action SwiftUI itself
/// runs on Return.)
///
/// A list registers through `.listCommands(delete:rename:)`, which puts a `ListCommandBridge`
/// behind it; the bridge's view finds the table view that shares its place in the window and
/// records the closures for it, replacing them on every update so they see the current
/// selection. `MenuActions` asks `handlers(forFirstResponderOf:)` to validate and run Edit ›
/// Delete and to act on Return.
final class ListCommands {
    static let shared = ListCommands()

    /// A list's commands; nil for one it cannot do just now (nothing selected, or several rows
    /// selected for a rename), which disables the menu item or lets the key pass.
    struct Handlers {
        /// Removes the selected rows.
        var delete: (() -> Void)?
        /// Edits the selected row's name (or, on the Pack page, puts the cursor in the name field).
        var rename: (() -> Void)?

        init(delete: (() -> Void)? = nil, rename: (() -> Void)? = nil) {
            self.delete = delete
            self.rename = rename
        }
    }

    private final class Entry {
        var handlers: Handlers
        init(_ handlers: Handlers) { self.handlers = handlers }
    }

    /// Weak keys: a table view that goes (a page switched away) takes its entry with it.
    private let entries = NSMapTable<NSTableView, Entry>(keyOptions: .weakMemory, valueOptions: .strongMemory)

    func set(_ handlers: Handlers, for tableView: NSTableView) {
        entries.setObject(Entry(handlers), forKey: tableView)
    }

    func remove(_ tableView: NSTableView) {
        entries.removeObject(forKey: tableView)
    }

    /// The handlers of the list whose table view is the window's first responder; nil when the
    /// first responder is something else (a text field, a button, nothing).
    func handlers(forFirstResponderOf window: NSWindow?) -> Handlers? {
        guard let table = window?.firstResponder as? NSTableView else { return nil }
        return entries.object(forKey: table)?.handlers
    }
}

extension View {
    /// Registers what this list does on Edit › Delete and on Return (see `ListCommands`). Pass
    /// nil for a command the list cannot do just now; the menu item is then disabled, and the
    /// key goes on to the table.
    func listCommands(delete: (() -> Void)?, rename: (() -> Void)? = nil) -> some View {
        background(ListCommandBridge(handlers: ListCommands.Handlers(delete: delete, rename: rename)))
    }
}

/// The view behind a list that finds the list's `NSTableView` and registers the handlers for it.
struct ListCommandBridge: NSViewRepresentable {
    let handlers: ListCommands.Handlers

    func makeNSView(context: Context) -> ListCommandBridgeView { ListCommandBridgeView() }

    func updateNSView(_ view: ListCommandBridgeView, context: Context) {
        view.handlers = handlers
        view.attach()
    }
}

final class ListCommandBridgeView: NSView {
    var handlers = ListCommands.Handlers() {
        didSet { if let table = tableView { ListCommands.shared.set(handlers, for: table) } }
    }
    private(set) weak var tableView: NSTableView?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attach()
    }

    override func layout() {
        super.layout()
        if tableView == nil { attach() }
    }

    /// Finds the table view that occupies this view's place in the window (a `.background` is
    /// laid out to the list's own frame): among the window's table views, the one whose scroll
    /// view overlaps this view the most. Registers the handlers for it; a change of table view
    /// moves them.
    func attach() {
        guard let window, let content = window.contentView else { return }
        let mine = convert(bounds, to: nil)
        guard mine.width > 0, mine.height > 0 else { return }
        var best: (table: NSTableView, area: CGFloat)?
        for table in Self.tableViews(in: content) {
            // The scroll view is where the list sits; the table view inside it scrolls and can
            // be taller than the room.
            let container: NSView = table.enclosingScrollView ?? table
            let theirs = container.convert(container.bounds, to: nil)
            let overlap = mine.intersection(theirs)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > 0, area > (best?.area ?? 0) { best = (table, area) }
        }
        guard let found = best?.table else { return }
        if let old = tableView, old !== found { ListCommands.shared.remove(old) }
        tableView = found
        ListCommands.shared.set(handlers, for: found)
    }

    private static func tableViews(in view: NSView) -> [NSTableView] {
        var out: [NSTableView] = []
        if let table = view as? NSTableView { out.append(table) }
        for sub in view.subviews { out += tableViews(in: sub) }
        return out
    }
}
