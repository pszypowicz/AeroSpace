import AppKit
import Common

/// Minimum adaptive weight any tiling node is allowed to hold after a resize.
///
/// Resize distributes the requested delta zero-sum between the focused node and its
/// siblings (`sibling -= diff / (n - 1)`). Without a floor, a delta larger than a
/// sibling's share of the weight space drives the sibling to (or below) zero,
/// which produces two visible bugs:
///
///   1. Negative weights invert the layout rect — the sibling renders past its
///      assigned parent bounds (windows overlap or run off-monitor).
///   2. Near-zero weights request a rect smaller than the app's own content
///      minimum size. macOS apps refuse to shrink below that minimum, so the
///      window keeps its actual on-screen size and simply sticks out past its
///      assigned rect — which on a multi-monitor setup looks like a window
///      spilling from one monitor onto the next.
///
/// `adaptiveWeight` is stored in pixel units (`layoutTiles` in
/// `layoutRecursive.swift` renormalizes the weight sum to the parent's
/// dimension on every pass). A conservative floor of 100 pixels is well below
/// any reasonable app's content minimum and keeps the clamped side of a resize
/// visibly non-zero. Apps with larger content minimums will still overflow
/// at 100 px — that's a deeper AppKit limitation — but the common case looks
/// right.
let MIN_TILING_WEIGHT: CGFloat = 100

struct ResizeCommand: Command { // todo cover with tests
    let args: ResizeCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }

        let candidates = target.windowOrNil?.parentsWithSelf
            .filter { ($0.parent as? TilingContainer)?.layout == .tiles }
            ?? []

        let orientation: Orientation?
        let parent: TilingContainer?
        let node: TreeNode?
        switch args.dimension.val {
            case .width:
                orientation = .h
                node = candidates.first(where: { ($0.parent as? TilingContainer)?.orientation == orientation })
                parent = node?.parent as? TilingContainer
            case .height:
                orientation = .v
                node = candidates.first(where: { ($0.parent as? TilingContainer)?.orientation == orientation })
                parent = node?.parent as? TilingContainer
            case .smart:
                node = candidates.first
                parent = node?.parent as? TilingContainer
                orientation = parent?.orientation
            case .smartOpposite:
                orientation = (candidates.first?.parent as? TilingContainer)?.orientation.opposite
                node = candidates.first(where: { ($0.parent as? TilingContainer)?.orientation == orientation })
                parent = node?.parent as? TilingContainer
        }
        guard let parent else {
            return .fail(io.err("resize command doesn't support floating windows yet https://github.com/nikitabobko/AeroSpace/issues/9"))
        }
        guard let orientation else { return .fail }
        guard let node else { return .fail }
        let requestedDiff: CGFloat = switch args.units.val {
            case .set(let unit): CGFloat(unit) - node.getWeight(orientation)
            case .add(let unit): CGFloat(unit)
            case .subtract(let unit): -CGFloat(unit)
        }

        // Clamp so neither the focused node nor any sibling drops below MIN_TILING_WEIGHT.
        // Lower bound on diff (from the focused node): node.weight + diff >= MIN  ⇒  diff >= MIN - node.weight
        // Upper bound on diff (from each sibling):     sibling.weight - diff/(n-1) >= MIN
        //                                              ⇒  diff <= (sibling.weight - MIN) * (n - 1)
        let nodeMinDiff = MIN_TILING_WEIGHT - node.getWeight(orientation)
        let siblingMaxDiff: CGFloat = parent.children.lazy
            .filter { $0 != node }
            .map { ($0.getWeight(parent.orientation) - MIN_TILING_WEIGHT) * CGFloat(parent.children.count - 1) }
            .min() ?? CGFloat.greatestFiniteMagnitude

        // If the constraints are mutually unsatisfiable — i.e. at least one side is
        // already below MIN_TILING_WEIGHT so no diff keeps both sides ≥ MIN — bail
        // out cleanly rather than picking one constraint and violating the other.
        // In production this never happens (layoutTiles renormalizes weights to
        // the parent's pixel dimension on every pass, which is always >> MIN);
        // it only comes up in unit tests where weights are synthesized by hand.
        if nodeMinDiff > siblingMaxDiff { return .succ }

        let diff = max(nodeMinDiff, min(siblingMaxDiff, requestedDiff))

        // If the request was fully clamped away (e.g. all siblings already at MIN), bail out
        // quietly rather than pretending to do work. Preserves idempotency of resize loops.
        if abs(diff) < .ulpOfOne { return .succ }

        guard let childDiff = diff.div(parent.children.count - 1) else { return .fail }
        parent.children.lazy
            .filter { $0 != node }
            .forEach { $0.setWeight(parent.orientation, $0.getWeight(parent.orientation) - childDiff) }

        node.setWeight(orientation, node.getWeight(orientation) + diff)
        return .succ
    }
}
