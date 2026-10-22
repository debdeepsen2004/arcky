import AppKit
import SwiftUI

/// Two-finger horizontal swipes over the sidebar switch spaces, like Arc. The sidebar follows
/// the fingers during the swipe and slides to the next space once it passes a threshold.
/// Horizontal mouse wheels (which send no gesture phases) step one space per flick.
@MainActor
final class SpaceSwipeTracker {
    static let shared = SpaceSwipeTracker()

    /// The sidebar's frame in window coordinates, kept current by `SidebarFrameReporter`.
    var sidebarFrame: CGRect = .zero

    private static let threshold: CGFloat = 70
    private var accumulatedX: CGFloat = 0
    private var accumulatedY: CGFloat = 0
    private enum Axis { case horizontal, vertical }
    private var axis: Axis?
    /// True from a horizontal swipe's start until its momentum events stop.
    private var swallowingMomentum = false
    private var wheelAccumulated: CGFloat = 0
    private var lastWheelEvent = Date.distantPast
    private var lastWheelSwitch = Date.distantPast

    private var store: BrowserStore { .shared }

    /// Returns true when the event was used for swiping and shouldn't scroll anything.
    func handle(_ event: NSEvent) -> Bool {
        // Inertial scrolling after a swipe is ignored.
        if event.momentumPhase != [] { return swallowingMomentum }
        swallowingMomentum = false

        guard event.window === store.mainWindow, store.sidebarVisible else { return false }

        if event.phase == [] {
            return handleWheel(event)
        }
        if event.phase.contains(.began) {
            guard sidebarFrame.contains(event.locationInWindow) else { return false }
            accumulatedX = 0
            accumulatedY = 0
            axis = nil
        }
        if event.phase.contains(.began) || event.phase.contains(.changed) {
            accumulatedX += event.scrollingDeltaX
            accumulatedY += event.scrollingDeltaY
            // Decide once per gesture whether it's a sideways swipe or a normal scroll.
            if axis == nil, abs(accumulatedX) + abs(accumulatedY) > 8 {
                axis = abs(accumulatedX) > abs(accumulatedY) * 1.5 ? .horizontal : .vertical
            }
            guard axis == .horizontal else { return false }
            store.swipeOffset = rubberBanded(accumulatedX)
            return true
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            defer { axis = nil }
            guard axis == .horizontal else { return false }
            swallowingMomentum = true
            finish(cancelled: event.phase.contains(.cancelled))
            return true
        }
        return axis == .horizontal
    }

    private func finish(cancelled: Bool) {
        // Natural scrolling: fingers moving left give negative deltas and mean "next space".
        if !cancelled, abs(accumulatedX) >= Self.threshold {
            store.stepSpace(by: accumulatedX < 0 ? 1 : -1)
        }
        withAnimation(.spring(duration: 0.3)) { store.swipeOffset = 0 }
    }

    /// Follows the fingers, with resistance, and much more resistance past the first or last space.
    private func rubberBanded(_ x: CGFloat) -> CGFloat {
        let atEnd = (x < 0 && store.activeSpaceIndex == store.spaces.count - 1) || (x > 0 && store.activeSpaceIndex == 0)
        let factor: CGFloat = atEnd ? 0.15 : 0.5
        return max(-140, min(140, x * factor))
    }

    private func handleWheel(_ event: NSEvent) -> Bool {
        guard sidebarFrame.contains(event.locationInWindow),
              abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return false }
        let now = Date()
        if now.timeIntervalSince(lastWheelEvent) > 0.3 { wheelAccumulated = 0 }
        lastWheelEvent = now
        wheelAccumulated += event.hasPreciseScrollingDeltas ? event.scrollingDeltaX / 30 : event.scrollingDeltaX
        if abs(wheelAccumulated) >= 1, now.timeIntervalSince(lastWheelSwitch) > 0.4 {
            store.stepSpace(by: wheelAccumulated < 0 ? 1 : -1)
            wheelAccumulated = 0
            lastWheelSwitch = now
        }
        return true
    }
}

/// Reports the sidebar's frame in window coordinates to the swipe tracker.
struct SidebarFrameReporter: NSViewRepresentable {
    final class ReportingView: NSView {
        override func layout() {
            super.layout()
            report()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            report()
        }

        func report() {
            guard window != nil else { return }
            let frame = convert(bounds, to: nil)
            MainActor.assumeIsolated { SpaceSwipeTracker.shared.sidebarFrame = frame }
        }
    }

    func makeNSView(context: Context) -> ReportingView { ReportingView() }

    func updateNSView(_ view: ReportingView, context: Context) {
        DispatchQueue.main.async { view.report() }
    }
}
