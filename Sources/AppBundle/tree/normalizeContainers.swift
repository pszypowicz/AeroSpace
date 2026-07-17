extension Workspace {
    @MainActor func normalizeContainers() {
        // Always called: the function also removes effectively-empty containers
        // regardless of the flatten flag.
        // Beware! rootTilingContainer may change after this line of code
        rootTilingContainer.unbindEmptyAndAutoFlatten(allowFlatten: config.enableNormalizationFlattenContainers)
        if config.enableNormalizationOppositeOrientationForNestedContainers {
            rootTilingContainer.normalizeOppositeOrientationForNestedContainers()
        }
    }
}

extension TilingContainer {
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
