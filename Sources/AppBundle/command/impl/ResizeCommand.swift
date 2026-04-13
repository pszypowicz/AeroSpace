import AppKit
import Common

/// Minimum adaptive weight any tiling node is allowed to hold after a resize.
///
/// Resize distributes the requested delta zero-sum between the focused node and its
/// siblings (`sibling -= diff / (n - 1)`). Without a floor, a delta larger than a
/// sibling's share of the weight space drives that sibling below zero, which the
/// layout math then renders as an inverted / overlapping rect. Clamping to a
/// strictly-positive minimum is the upstream-safe fix: the requested delta is
/// clamped to whatever is actually applicable, and the operation remains
/// zero-sum so no weight leaks out of the parent.
let MIN_TILING_WEIGHT: CGFloat = 0.1

struct ResizeCommand: Command { // todo cover with tests
    let args: ResizeCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) -> Bool {
        guard let target = args.resolveTargetOrReportError(env, io) else { return false }

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
        guard let parent else { return io.err("resize command doesn't support floating windows yet https://github.com/nikitabobko/AeroSpace/issues/9") }
        guard let orientation else { return false }
        guard let node else { return false }
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
        let diff = max(nodeMinDiff, min(siblingMaxDiff, requestedDiff))

        // If the request was fully clamped away (e.g. all siblings already at MIN), bail out
        // quietly rather than pretending to do work. Preserves idempotency of resize loops.
        if abs(diff) < .ulpOfOne { return true }

        guard let childDiff = diff.div(parent.children.count - 1) else { return false }
        parent.children.lazy
            .filter { $0 != node }
            .forEach { $0.setWeight(parent.orientation, $0.getWeight(parent.orientation) - childDiff) }

        node.setWeight(orientation, node.getWeight(orientation) + diff)
        return true
    }
}
