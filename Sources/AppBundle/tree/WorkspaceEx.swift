import Common

extension Workspace {
    @MainActor var rootTilingContainer: TilingContainer {
        let containers = children.filterIsInstance(of: TilingContainer.self)
        switch containers.count {
            case 0:
                let orientation: Orientation = switch config.defaultRootContainerOrientation {
                    case .horizontal: .h
                    case .vertical: .v
                    case .auto: workspaceMonitor.then { $0.width >= $0.height } ? .h : .v
                }
                return TilingContainer(parent: self, adaptiveWeight: 1, orientation, config.defaultRootContainerLayout, index: INDEX_BIND_LAST)
            case 1:
                return containers.singleOrNil().orDie()
            default:
                die("Workspace must contain zero or one tiling container as its child")
        }
    }

    @MainActor
    var floatingWindows: [Window] {
        floatingWindowsContainer.children.filterIsInstance(of: Window.self)
    }

    @MainActor
    var floatingWindowsContainer: FloatingWindowsContainer {
        let containers = children.filterIsInstance(of: FloatingWindowsContainer.self)
        return switch containers.count {
            case 0: FloatingWindowsContainer(parent: self)
            case 1: containers.singleOrNil().orDie()
            default: dieT("Workspace must contain zero or one FloatingWindowsContainer")
        }
    }

    @MainActor var macOsNativeFullscreenWindowsContainer: MacosFullscreenWindowsContainer {
        let containers = children.filterIsInstance(of: MacosFullscreenWindowsContainer.self)
        return switch containers.count {
            case 0: MacosFullscreenWindowsContainer(parent: self)
            case 1: containers.singleOrNil().orDie()
            default: dieT("Workspace must contain zero or one MacosFullscreenWindowsContainer")
        }
    }

    @MainActor var macOsNativeHiddenAppsWindowsContainer: MacosHiddenAppsWindowsContainer {
        let containers = children.filterIsInstance(of: MacosHiddenAppsWindowsContainer.self)
        return switch containers.count {
            case 0: MacosHiddenAppsWindowsContainer(parent: self)
            case 1: containers.singleOrNil().orDie()
            default: dieT("Workspace must contain zero or one MacosHiddenAppsWindowsContainer")
        }
    }

    /// A workspace is "hollow" when it holds macOS native fullscreen windows (each on its own macOS Space)
    /// but has nothing on its host desktop, so visiting it shows a bare desktop while its windows display on
    /// their own Spaces. Minimized and hidden-app windows don't count as host-desktop content.
    @MainActor var isHollow: Bool {
        var hasNativeFullscreen = false
        var hasHostDesktopWindow = false
        for window in allLeafWindowsRecursive {
            switch window.windowParentCases {
                case .macosFullscreenWindowsContainer: hasNativeFullscreen = true
                case .tilingContainer, .floatingWindowsContainer: hasHostDesktopWindow = true
                case .macosMinimizedWindowsContainer, .macosHiddenAppsWindowsContainer, .macosPopupWindowsContainer, .unbound: break
            }
        }
        return hasNativeFullscreen && !hasHostDesktopWindow
    }

    @MainActor var forceAssignedMonitor: Monitor? {
        guard let monitorDescriptions = config.workspaceToMonitorForceAssignment[name] else { return nil }
        let sortedMonitors = sortedMonitors
        return monitorDescriptions.lazy
            .compactMap { $0.resolveMonitor(sortedMonitors: sortedMonitors) }
            .first
    }
}
