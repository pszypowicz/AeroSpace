extension Workspace {
    @MainActor func normalizeContainers() {
        rootTilingContainer.unbindEmptyAndAutoFlatten() // Beware! rootTilingContainer may change after this line of code
        if config.enableNormalizationOppositeOrientationForNestedContainers {
            rootTilingContainer.normalizeOppositeOrientationForNestedContainers()
        }
        if config.enableNormalizationBspShape {
            rootTilingContainer.normalizeBspShape()
        }
    }
}

extension TilingContainer {
    /// Right-deep fold of any non-BSP `tiles` container into binary BSP shape.
    ///
    /// For a `tiles` container with more than two children, keep `children[0]` in
    /// place and move `children[1...]` into a new opposite-orientation `tiles`
    /// wrapper at index 1, then recurse into the wrapper (which itself may need
    /// folding). An already-BSP tree is a fixed point of this transform.
    ///
    /// `accordion` containers and their descendants are skipped: accordion is an
    /// explicit user choice and remains an escape island inside BSP workspaces.
    ///
    /// Weight handling is best-effort: the wrapper inherits the sum of the folded
    /// children's weights along the parent's orientation, and the folded children
    /// keep their `adaptiveWeight` verbatim. `layoutTiles` renormalises weights to
    /// the parent's pixel dimension on every layout pass, so the post-fold sizes
    /// reflect each child's relative share among its new siblings.
    @MainActor func normalizeBspShape() {
        if layout == .tiles && children.count > 2 {
            let tail = children.dropFirst().map { (child: $0, weight: $0.getWeight(orientation)) }
            let tailWeightSum = tail.reduce(0.0) { $0 + $1.weight }
            for item in tail {
                item.child.unbindFromParent()
            }
            let wrapper = TilingContainer(
                parent: self,
                adaptiveWeight: tailWeightSum,
                orientation.opposite,
                .tiles,
                index: 1,
            )
            for (i, item) in tail.enumerated() {
                item.child.bind(to: wrapper, adaptiveWeight: item.weight, index: i)
            }
        }
        for child in children {
            (child as? TilingContainer)?.normalizeBspShape()
        }
    }

    @MainActor fileprivate func unbindEmptyAndAutoFlatten() {
        if let child = children.singleOrNil(), config.enableNormalizationFlattenContainers && (child is TilingContainer || !isRootContainer) {
            child.unbindFromParent()
            let mru = parent?.mostRecentChild
            let previousBinding = unbindFromParent()
            child.bind(to: previousBinding.parent, adaptiveWeight: previousBinding.adaptiveWeight, index: previousBinding.index)
            (child as? TilingContainer)?.unbindEmptyAndAutoFlatten()
            if mru != self {
                mru?.markAsMostRecentChild()
            } else {
                child.markAsMostRecentChild()
            }
        } else {
            for child in children {
                (child as? TilingContainer)?.unbindEmptyAndAutoFlatten()
            }
            if children.isEmpty && !isRootContainer {
                unbindFromParent()
            }
        }
    }
}
