import AppKit
import Observation
import SwiftUI

/// Size of the notch and the island drawn around it, in points.
struct NotchGeometry: Equatable {
    /// Width of each side wing that holds one number.
    static let wingWidth: CGFloat = 64
    /// Width of the island while the details panel is open.
    static let expandedWidth: CGFloat = 620
    /// Upper bound for the details panel's height below the menu bar, used until its real height is measured.
    static let expandedHeight: CGFloat = 400

    var notchWidth: CGFloat
    var menuBarHeight: CGFloat

    /// Total width of the collapsed island: left wing + notch + right wing.
    var islandWidth: CGFloat { notchWidth + 2 * Self.wingWidth }

    /// Reads the notch geometry of `screen`; screens without a notch get a zero-width gap.
    init(screen: NSScreen) {
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            notchWidth = screen.frame.width - left.width - right.width
            menuBarHeight = screen.safeAreaInsets.top
        } else {
            notchWidth = 0
            menuBarHeight = NSStatusBar.system.thickness
        }
    }
}

/// Shared UI state between the window controller and the SwiftUI view.
@Observable
final class IslandState {
    var geometry: NotchGeometry
    var isExpanded = false
    /// Current laid-out height of the black island, reported by the view; the window is sized to it.
    @ObservationIgnored var islandHeight: CGFloat = 0 {
        didSet { if islandHeight != oldValue { onIslandHeightChange?() } }
    }
    /// Called after `islandHeight` changes.
    @ObservationIgnored var onIslandHeightChange: (() -> Void)?

    /// Creates state for the given initial geometry.
    init(geometry: NotchGeometry) {
        self.geometry = geometry
    }
}

/// Borderless panel allowed to sit over the menu bar.
private final class IslandPanel: NSPanel {
    // AppKit would otherwise push the window below the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Content view that reports the mouse entering and leaving the window.
private final class HoverView: NSView {
    /// Called with `true` on mouse enter and `false` on mouse exit.
    var onHoverChange: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // .inVisibleRect keeps the area matched to the view as the window resizes.
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }
}

/// Owns the overlay panel around the notch, keeps it positioned and drives hover expansion.
///
/// The panel is always sized to the visible black island, so it only takes mouse events there
/// (those pixels are covered anyway) and hover comes from a tracking area: the app is not woken
/// by mouse movement anywhere else on screen.
final class IslandController {
    private let panel: IslandPanel
    private let state: IslandState
    private let monitor: SystemMonitor

    /// Creates the panel showing data from `monitor` and puts it on screen.
    init(monitor: SystemMonitor) {
        self.monitor = monitor
        let screen = Self.targetScreen()
        state = IslandState(geometry: screen.map(NotchGeometry.init) ?? NotchGeometry(screen: NSScreen.screens[0]))

        panel = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        // No .fullScreenAuxiliary, so the island stays out of full-screen spaces.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let hostingView = NSHostingView(rootView: IslandView(monitor: monitor, state: state))
        // The controller sizes the window; SwiftUI must not resize or constrain it.
        hostingView.sizingOptions = []
        hostingView.autoresizingMask = [.width, .height]
        let hoverView = HoverView()
        hoverView.addSubview(hostingView)
        hoverView.onHoverChange = { [weak self] inside in self?.setExpanded(inside) }
        panel.contentView = hoverView

        state.onIslandHeightChange = { [weak self] in
            // Reported from inside a SwiftUI update; resize the window after it finishes.
            DispatchQueue.main.async {
                // While collapsing, the window keeps its size until the animation ends.
                guard let self, self.state.isExpanded else { return }
                self.layout()
            }
        }

        layout()
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.layout() }
    }

    /// Prefers the built-in notched display, falling back to the primary screen.
    private static func targetScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.screens.first
    }

    /// Sizes the panel to the island (collapsed, or expanded at its measured height) centred at the top of the screen.
    private func layout() {
        guard let screen = Self.targetScreen() else { return }
        let geometry = NotchGeometry(screen: screen)
        if geometry != state.geometry { state.geometry = geometry }

        let size: NSSize
        if state.isExpanded {
            // Until the expanded view reports its height, reserve the upper bound so nothing is clipped.
            let measured = state.islandHeight > geometry.menuBarHeight
            let height = measured ? state.islandHeight : geometry.menuBarHeight + NotchGeometry.expandedHeight
            size = NSSize(width: NotchGeometry.expandedWidth, height: height)
        } else {
            size = NSSize(width: geometry.islandWidth, height: geometry.menuBarHeight)
        }
        let origin = NSPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)

        // Resizing under a still cursor does not always send enter/exit events.
        var hitRect = panel.frame
        // +1 so the very top pixel row (y == maxY) still counts as inside.
        hitRect.size.height += 1
        setExpanded(hitRect.contains(NSEvent.mouseLocation))
    }

    private func setExpanded(_ expanded: Bool) {
        guard expanded != state.isExpanded else { return }
        monitor.samplesProcesses = expanded
        if expanded {
            withAnimation(IslandView.animation) { state.isExpanded = true }
            // Grow the window before the first expanded frame is drawn.
            layout()
        } else {
            withAnimation(IslandView.animation, completionCriteria: .removed) {
                state.isExpanded = false
            } completion: { [weak self] in
                // Shrink only once the island has finished animating, unless it re-expanded meanwhile.
                guard let self, !self.state.isExpanded else { return }
                self.layout()
            }
        }
    }
}
