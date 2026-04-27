import AppKit
import Common

@MainActor
private var resizeWithMouseTask: Task<(), any Error>? = nil

func resizedObs(_: AXObserver, ax: AXUIElement, notif: CFString, _: UnsafeMutableRawPointer?) {
    let notif = notif as String
    let windowId = ax.containingWindowId()
    Task { @MainActor in
        guard let token: RunSessionGuard = .isServerEnabled else { return }
        guard let windowId, let window = Window.get(byId: windowId), try await isManipulatedWithMouse(window) else {
            scheduleCancellableCompleteRefreshSession(.ax(notif))
            return
        }
        resizeWithMouseTask?.cancel()
        resizeWithMouseTask = Task {
            try checkCancellation()
            try await runLightSession(.ax(notif), token) {
                try await resizeWithMouse(window)
            }
        }
    }
}

@MainActor
func resetManipulatedWithMouseIfPossible() async throws {
    guard let manipulatedId = currentlyManipulatedWithMouseWindowId else { return }
    currentlyManipulatedWithMouseWindowId = nil
    for workspace in Workspace.all {
        workspace.resetResizeWeightBeforeResizeRecursive()
    }

    // Reconcile weights from actual AX rects before the heavy refresh.
    // Each mouse-resize tick reshapes weights from a diff against the
    // dragged window's 'lastAppliedLayoutPhysicalRect'. macOS doesn't
    // always honour our 'setAxFrame' calls (apps refuse to shrink below
    // their content minimum, sub-pixel rounding, etc.), so over multiple
    // drags the weight state drifts away from what's actually on screen.
    // Reading every tile's real AX rect on mouseUp and writing those
    // dimensions back into 'adaptiveWeight' makes reality the source of
    // truth at the moment of release. The subsequent layoutWorkspaces
    // pass then snaps any stale rect-from-AX-quirks to a clean tiled
    // state. Without this, alternating-direction drags compound their
    // errors and 'click another window to fix it' was the only recovery.
    if let window = Window.get(byId: manipulatedId), let workspace = window.nodeWorkspace {
        try await reconcileWeightsFromAxRects(workspace)
    }

    scheduleCancellableCompleteRefreshSession(
        .resetManipulatedWithMouse,
        optimisticallyPreLayoutWorkspaces: true,
    )
}

/// Walk the tiling tree of `workspace` and overwrite each tile's
/// `adaptiveWeight` with the actual on-screen dimension along its parent's
/// orientation. Reads `getAxRect()` for every leaf window; containers
/// borrow the dimension from any descendant leaf (all descendants of a
/// container share its extent in the parent's orientation by construction).
@MainActor
private func reconcileWeightsFromAxRects(_ workspace: Workspace) async throws {
    func leafRectDimension(_ node: TreeNode, _ orientation: Orientation) async throws -> CGFloat? {
        if let window = node as? Window {
            return try await window.getAxRect()?.getDimension(orientation)
        }
        for leaf in node.allLeafWindowsRecursive {
            if let dim = try await leaf.getAxRect()?.getDimension(orientation) {
                return dim
            }
        }
        return nil
    }
    func recurse(_ container: TilingContainer) async throws {
        let orientation = container.orientation
        for child in container.children {
            if let dim = try await leafRectDimension(child, orientation) {
                child.setWeight(orientation, dim)
            }
            if let inner = child as? TilingContainer {
                try await recurse(inner)
            }
        }
    }
    try await recurse(workspace.rootTilingContainer)
}

private let adaptiveWeightBeforeResizeWithMouseKey = TreeNodeUserDataKey<CGFloat>(key: "adaptiveWeightBeforeResizeWithMouseKey")

@MainActor
private func resizeWithMouse(_ window: Window) async throws { // todo cover with tests
    resetClosedWindowsCache()
    guard let parent = window.parent else { return }
    switch parent.cases {
        case .workspace, .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer,
             .macosPopupWindowsContainer, .macosHiddenAppsWindowsContainer:
            return // Nothing to do for floating, or unconventional windows
        case .tilingContainer:
            guard let rect = try await window.getAxRect() else { return }
            guard let lastAppliedLayoutRect = window.lastAppliedLayoutPhysicalRect else { return }
            let (lParent, lOwnIndex) = window.closestParent(hasChildrenInDirection: .left, withLayout: .tiles) ?? (nil, nil)
            let (dParent, dOwnIndex) = window.closestParent(hasChildrenInDirection: .down, withLayout: .tiles) ?? (nil, nil)
            let (uParent, uOwnIndex) = window.closestParent(hasChildrenInDirection: .up, withLayout: .tiles) ?? (nil, nil)
            let (rParent, rOwnIndex) = window.closestParent(hasChildrenInDirection: .right, withLayout: .tiles) ?? (nil, nil)
            let table: [(CGFloat, TilingContainer?, Int?, Int?)] = [
                (lastAppliedLayoutRect.minX - rect.minX, lParent, 0,                        lOwnIndex),               // Horizontal, to the left of the window
                (rect.maxY - lastAppliedLayoutRect.maxY, dParent, dOwnIndex.map { $0 + 1 }, dParent?.children.count), // Vertical, to the down of the window
                (lastAppliedLayoutRect.minY - rect.minY, uParent, 0,                        uOwnIndex),               // Vertical, to the up of the window
                (rect.maxX - lastAppliedLayoutRect.maxX, rParent, rOwnIndex.map { $0 + 1 }, rParent?.children.count), // Horizontal, to the right of the window
            ]
            for (diff, parent, startIndex, pastTheEndIndex) in table {
                if let parent, let startIndex, let pastTheEndIndex, pastTheEndIndex - startIndex > 0 && abs(diff) > 5 { // 5 pixels should be enough to fight with accumulated floating precision error
                    let orientation = parent.orientation
                    let siblingCount = pastTheEndIndex - startIndex

                    // Same clamp as ResizeCommand: keep every weight >= MIN_TILING_WEIGHT
                    // after the change. Without it, dragging a border past the sibling's
                    // share drives the sibling to <= 0 and macOS apps refuse to shrink
                    // below their content minimum, leaving them visibly overlapping the
                    // dragged window. The bug is most visible when alternating drags
                    // (left, then right) because each drag accumulates on top of an
                    // already-skewed weight.
                    let ancestors = window.parentsWithSelf.lazy
                        .prefix(while: { $0 != parent })
                        .filter {
                            let p = $0.parent as? TilingContainer
                            return p?.orientation == orientation && p?.layout == .tiles
                        }
                    let minAncestorWeight = ancestors.map { $0.getWeightBeforeResize(orientation) }.min() ?? CGFloat.greatestFiniteMagnitude
                    let minSiblingWeight = parent.children[startIndex ..< pastTheEndIndex]
                        .map { $0.getWeightBeforeResize(orientation) }.min() ?? CGFloat.greatestFiniteMagnitude
                    // diff >= MIN - minAncestor (lower bound from ancestors getting +diff)
                    // diff <= (minSibling - MIN) * siblingCount (upper bound from siblings getting -diff/n)
                    let lowerBound = MIN_TILING_WEIGHT - minAncestorWeight
                    let upperBound = (minSiblingWeight - MIN_TILING_WEIGHT) * CGFloat(siblingCount)
                    if lowerBound > upperBound { continue } // impossible clamp; happens only when weights are already < MIN
                    let clampedDiff = max(lowerBound, min(upperBound, diff))
                    if abs(clampedDiff) < .ulpOfOne { continue }

                    let siblingDiff = clampedDiff.div(siblingCount).orDie()

                    ancestors.forEach { $0.setWeight(orientation, $0.getWeightBeforeResize(orientation) + clampedDiff) }
                    for sibling in parent.children[startIndex ..< pastTheEndIndex] {
                        sibling.setWeight(orientation, sibling.getWeightBeforeResize(orientation) - siblingDiff)
                    }
                }
            }
            currentlyManipulatedWithMouseWindowId = window.windowId
    }
}

extension TreeNode {
    @MainActor
    fileprivate func getWeightBeforeResize(_ orientation: Orientation) -> CGFloat {
        let currentWeight = getWeight(orientation) // Check assertions
        return getUserData(key: adaptiveWeightBeforeResizeWithMouseKey)
            ?? (lastAppliedLayoutVirtualRect?.getDimension(orientation) ?? currentWeight)
            .also { putUserData(key: adaptiveWeightBeforeResizeWithMouseKey, data: $0) }
    }

    fileprivate func resetResizeWeightBeforeResizeRecursive() {
        cleanUserData(key: adaptiveWeightBeforeResizeWithMouseKey)
        for child in children {
            child.resetResizeWeightBeforeResizeRecursive()
        }
    }
}
