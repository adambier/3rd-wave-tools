import AppKit
import SwiftUI

/// Classic scroll bars for a SwiftUI List, Table or ScrollView: shown whenever the content is larger
/// than the area, instead of the overlay bars macOS shows only while scrolling (its default with a
/// trackpad). So it is always visible which areas scroll and how much more there is.
///
/// SwiftUI has no setting for this, so a zero-size helper view placed behind the list finds the
/// AppKit scroll view under it and sets its scroller style. Applied again when the system scroll-bar
/// preference changes, which would otherwise reset it.
struct VisibleScrollers: NSViewRepresentable {
    func makeNSView(context: Context) -> Finder { Finder() }
    func updateNSView(_ view: Finder, context: Context) { view.scheduleApply() }

    final class Finder: NSView {
        private var observer: NSObjectProtocol?
        private var pending = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }   // never takes clicks

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil, observer == nil {
                observer = NotificationCenter.default.addObserver(
                    forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil, queue: .main
                ) { [weak self] _ in self?.scheduleApply() }
            }
            scheduleApply()
        }

        override func layout() {
            super.layout()
            scheduleApply()
        }

        /// Runs after SwiftUI has finished building the views for this pass.
        func scheduleApply() {
            guard !pending else { return }
            pending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pending = false
                self.apply()
            }
        }

        private func apply() {
            guard let root = window?.contentView, let scroll = scrollView(in: root) else { return }
            if scroll.scrollerStyle != .legacy { scroll.scrollerStyle = .legacy }
            if !scroll.autohidesScrollers { scroll.autohidesScrollers = true }   // shown only when needed
        }

        /// The innermost scroll view under this view's centre: the one behind the list it decorates.
        private func scrollView(in root: NSView) -> NSScrollView? {
            guard bounds.width > 0, bounds.height > 0 else { return nil }
            let centre = convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil)
            var found: NSScrollView?
            func visit(_ v: NSView) {
                if v.isHidden { return }
                if let s = v as? NSScrollView, s.convert(s.bounds, to: nil).contains(centre) { found = s }
                for sub in v.subviews { visit(sub) }   // deeper matches replace outer ones
            }
            visit(root)
            return found
        }
    }
}

extension View {
    /// Classic scroll bars, shown whenever the content does not fit. See `VisibleScrollers`.
    func visibleScrollers() -> some View { background(VisibleScrollers()) }
}
