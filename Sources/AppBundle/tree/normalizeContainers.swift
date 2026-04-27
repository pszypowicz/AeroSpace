import Common

extension Workspace {
    /// Defaults to the global config flag. A future per-workspace override layer
    /// will inspect a per-workspace map first; for now this is a thin wrapper so
    /// every normalizer dispatch goes through a single point.
    @MainActor func isNormalizationEnabled(_ kind: NormalizationKind) -> Bool {
        config.isNormalizationEnabled(kind)
    }

    @MainActor func normalizeContainers() {
        // Always called: the function also removes effectively-empty containers
        // regardless of the flatten flag.
        rootTilingContainer.unbindEmptyAndAutoFlatten(allowFlatten: isNormalizationEnabled(.flattenContainers))
        if isNormalizationEnabled(.oppositeOrientationForNestedContainers) {
            rootTilingContainer.normalizeOppositeOrientationForNestedContainers()
        }
        if isNormalizationEnabled(.bspShape) {
            rootTilingContainer.normalizeBspShape()
        }
    }
}

extension TilingContainer {
    /// Fold a non-BSP `tiles` container into binary BSP shape using the focus
    /// signal already tracked in `_mruChildren`.
    ///
    /// Each iteration finds the two most-recently-bound children (top of the
    /// MRU stack) and wraps them together in a new opposite-orientation `tiles`
    /// container at the lower-index member's position. Other children stay put.
    /// Repeat until `children.count <= 2`. Then recurse into each child.
    ///
    /// Why MRU? Every `bind()` call ends with `markAsMostRecentChild()`, so
    /// after a new window is bound, `_mruChildren[0]` is that window and
    /// `_mruChildren[1]` is whichever child was previously focused.
    /// Wrapping those two together reproduces traditional BSP behaviour: the
    /// new window splits the focused window's slot, and existing windows the
    /// user wasn't interacting with don't move. This is the focus-context
    /// that a position-only fold (`children[0]` + `children[1...]`) loses.
    ///
    /// `accordion` containers and their descendants are skipped: accordion is
    /// an explicit user choice and remains an escape island inside BSP
    /// workspaces. Already-BSP trees (every `tiles` node has at most two
    /// children) are a fixed point.
    ///
    /// Weights inside the new wrapper are uniform (1 each) so `layoutTiles`
    /// splits them 50/50 - the new window takes half of the focused window's
    /// slot, which is what BSP / Fibonacci tiling expects. The wrapper itself
    /// inherits the previously-focused child's pre-fold weight so it claims
    /// exactly the share that child had before the new window arrived; the
    /// other siblings keep their weights and the user's custom proportions
    /// survive across new-window events.
    @MainActor func normalizeBspShape() {
        while layout == .tiles && children.count > 2 {
            // Top-2 MRU children, falling back to children[0]/children[1] if
            // the MRU stack is incomplete (defensive; in practice every bind
            // calls markAsMostRecentChild so the stack mirrors children).
            let mru = mruChildrenOrdered
            guard let mostRecent = mru.first ?? children.first,
                  let secondMostRecent = mru.dropFirst().first ?? children.dropFirst().first,
                  mostRecent !== secondMostRecent else { break }
            // 'mostRecent !== secondMostRecent' guards against an MRU stack so
            // degenerate that the same child appears twice (would only happen
            // if markAsMostRecentChild had a bug and double-pushed). Bailing
            // with 'break' leaves the tree as it was rather than crashing the
            // whole normaliser pass; a partially-folded tree is still safe to
            // render and the next normalize call will retry.
            guard let mruIdx = mostRecent.ownIndex,
                  let secondIdx = secondMostRecent.ownIndex else { break }

            // Place the wrapper at the lower-index pivot. Bind the lower-index
            // member first so the in-tree visual order matches the array order
            // the user perceived before the fold.
            let pivotIdx = min(mruIdx, secondIdx)
            let firstChild = mruIdx < secondIdx ? mostRecent : secondMostRecent
            let secondChild = mruIdx < secondIdx ? secondMostRecent : mostRecent
            // The wrapper takes the previously-focused child's slot. Its weight
            // matches that child's current weight in the parent's orientation.
            // 'layoutTiles' will redistribute via the standard delta and the
            // wrapper ends up occupying the share the focused window had,
            // splitting the new + previously-focused windows 50/50 inside it
            // (their uniform weights below make the inner split equal). Other
            // siblings keep their weights, so user customisations to those
            // windows' sizes are preserved across new-window events.
            // Read this before the unbinds: getWeight requires the node to
            // still be bound to a parent and dies otherwise.
            let wrapperWeight = secondMostRecent.getWeight(orientation)
            firstChild.unbindFromParent()
            secondChild.unbindFromParent()
            let wrapper = TilingContainer(
                parent: self,
                adaptiveWeight: wrapperWeight,
                orientation.opposite,
                .tiles,
                index: pivotIdx,
            )
            firstChild.bind(to: wrapper, adaptiveWeight: 1, index: 0)
            secondChild.bind(to: wrapper, adaptiveWeight: 1, index: 1)
            // Repair the alternation invariant inside the moved subtree:
            // recursively flip any descendant that now shares its parent's
            // orientation. The wrapper itself is correct by construction
            // (its orientation is `self.opposite`), so iterate its children
            // directly rather than calling the helper on the wrapper.
            for child in wrapper.children {
                (child as? TilingContainer)?.normalizeOppositeOrientationForNestedContainers()
            }
        }
        for child in children {
            (child as? TilingContainer)?.normalizeBspShape()
        }
    }

    @MainActor fileprivate func unbindEmptyAndAutoFlatten(allowFlatten: Bool) {
        if let child = children.singleOrNil(), allowFlatten && (child is TilingContainer || !isRootContainer) {
            child.unbindFromParent()
            let mru = parent?.mostRecentChild
            let previousBinding = unbindFromParent()
            child.bind(to: previousBinding.parent, adaptiveWeight: previousBinding.adaptiveWeight, index: previousBinding.index)
            (child as? TilingContainer)?.unbindEmptyAndAutoFlatten(allowFlatten: allowFlatten)
            if mru != self {
                mru?.markAsMostRecentChild()
            } else {
                child.markAsMostRecentChild()
            }
        } else {
            for child in children {
                (child as? TilingContainer)?.unbindEmptyAndAutoFlatten(allowFlatten: allowFlatten)
            }
            if children.isEmpty && !isRootContainer {
                unbindFromParent()
            }
        }
    }
}
