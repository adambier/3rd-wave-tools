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
/// A list keeps a `ListCommandSource` in its `@State`, sets the source's handlers on every pass
/// of its body (so they always see the current selection), and puts a `ListCommandBridge` for the
/// source behind each row's content. The bridge's view walks up from the row to the table view
/// and registers the source for it; a row that scrolls away leaves the registration standing,
/// and the source keeps it current. (An earlier bridge behind the whole list matched table
/// views by their frames in the window and matched the wrong ones on the Pack page.)
/// `MenuActions` asks `handlers(forFirstResponderOf:)` to validate and run Edit › Delete and to
/// act on Return.
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

    /// Weak keys: a table view that goes (a page switched away) takes its entry with it.
    private let entries = NSMapTable<NSTableView, ListCommandSource>(keyOptions: .weakMemory, valueOptions: .strongMemory)

    func set(_ source: ListCommandSource, for tableView: NSTableView) {
        entries.setObject(source, forKey: tableView)
    }

    /// The handlers of the list whose table view is the window's first responder; nil when the
    /// first responder is something else (a text field, a button, nothing).
    func handlers(forFirstResponderOf window: NSWindow?) -> Handlers? {
        guard let table = window?.firstResponder as? NSTableView else { return nil }
        return entries.object(forKey: table)?.handlers
    }

    /// How many lists are registered (for the log's diagnostics).
    var count: Int { entries.count }
}

/// A list's current commands, held by reference so the registration behind its table view sees
/// each pass's closures. Kept in the list's view as `@State`, and set at the top of its body.
final class ListCommandSource {
    var handlers = ListCommands.Handlers()

    /// Sets this pass's handlers (nil for a command the list cannot do just now) and returns
    /// the source, for one expression in a view's body.
    @discardableResult
    func set(delete: (() -> Void)?, rename: (() -> Void)? = nil) -> ListCommandSource {
        handlers = ListCommands.Handlers(delete: delete, rename: rename)
        return self
    }
}

extension View {
    /// Behind a row's content: registers the list's `ListCommandSource` for the table view the
    /// row is in (see `ListCommands`).
    func listCommands(_ source: ListCommandSource) -> some View {
        background(ListCommandBridge(source: source))
    }
}

/// The view behind a row that finds the row's `NSTableView` up the view hierarchy and registers
/// the list's source for it.
struct ListCommandBridge: NSViewRepresentable {
    let source: ListCommandSource

    func makeNSView(context: Context) -> ListCommandBridgeView { ListCommandBridgeView() }

    func updateNSView(_ view: ListCommandBridgeView, context: Context) {
        view.source = source
        view.attach()
    }
}

final class ListCommandBridgeView: NSView {
    var source: ListCommandSource?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attach()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        attach()
    }

    /// Registers the source for the table view this row is in: the first `NSTableView` up the
    /// superview chain (the row's cell view and SwiftUI's own views sit between).
    func attach() {
        guard let source, window != nil else { return }
        var view: NSView? = superview
        while let v = view {
            if let table = v as? NSTableView {
                ListCommands.shared.set(source, for: table)
                return
            }
            view = v.superview
        }
    }
}
