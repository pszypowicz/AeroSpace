import AppKit

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

    /// Right-deep fold of any non-BSP `tiles` container into binary BSP shape.
    ///
    /// For a `tiles` container with more than two children, keep `child[0]` in place,
    /// move `children[1...]` into a new opposite-orientation `tiles` wrapper at
    /// `index: 1`, then recurse into the wrapper (which itself may need folding).
    ///
    /// `accordion` containers and their descendants are skipped — accordion is an
    /// explicit user choice and remains an escape island inside BSP workspaces.
    /// An already-BSP tree is a fixed point of this transform.
    ///
    /// Weight preservation is best-effort: the new wrapper inherits the sum of the
    /// folded children's weights along the parent's orientation, and the folded
    /// children keep their `adaptiveWeight` verbatim.
    @MainActor func normalizeBspShape() {
        if layout == .tiles && children.count > 2 {
            let tailWithWeights: [(child: TreeNode, weight: CGFloat)] = children
                .dropFirst()
                .map { ($0, $0.getWeight(orientation)) }
            let tailWeightSum = tailWithWeights.reduce(0.0) { $0 + $1.weight }
            for (child, _) in tailWithWeights {
                child.unbindFromParent()
            }
            let wrapper = TilingContainer(
                parent: self,
                adaptiveWeight: tailWeightSum,
                orientation.opposite,
                .tiles,
                index: 1,
            )
            for (i, item) in tailWithWeights.enumerated() {
                item.child.bind(to: wrapper, adaptiveWeight: item.weight, index: i)
            }
        }
        for child in children {
            (child as? TilingContainer)?.normalizeBspShape()
        }
    }
}
