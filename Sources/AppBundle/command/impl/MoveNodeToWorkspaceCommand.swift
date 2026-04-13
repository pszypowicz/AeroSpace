import Common

struct MoveNodeToWorkspaceCommand: Command {
    let args: MoveNodeToWorkspaceCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache: Bool = true

    func run(_ env: CmdEnv, _ io: CmdIo) -> Bool {
        guard let target = args.resolveTargetOrReportError(env, io) else { return false }
        guard let window = target.windowOrNil else { return io.err(noWindowIsFocused) }
        let subjectWs = window.nodeWorkspace
        let targetWorkspace: Workspace
        switch args.target.val {
            case .relative(let nextPrev):
                guard let subjectWs else { return io.err("Window \(window.windowId) doesn't belong to any workspace") }
                let ws = getNextPrevWorkspace(
                    current: subjectWs,
                    isNext: nextPrev == .next,
                    wrapAround: args.wrapAround,
                    stdin: args.useStdin ? io.readStdin() : nil,
                    target: target,
                )
                guard let ws else { return io.err("Can't resolve next or prev workspace") }
                targetWorkspace = ws
            case .direct(let name):
                targetWorkspace = Workspace.get(byName: name.raw)
        }
        return moveWindowToWorkspace(window, targetWorkspace, io, focusFollowsWindow: args.focusFollowsWindow, failIfNoop: args.failIfNoop)
    }
}

@MainActor
func moveWindowToWorkspace(_ window: Window, _ targetWorkspace: Workspace, _ io: CmdIo, focusFollowsWindow: Bool, failIfNoop: Bool, index: Int = INDEX_BIND_LAST) -> Bool {
    if window.nodeWorkspace == targetWorkspace {
        if !failIfNoop {
            io.err("Window '\(window.windowId)' already belongs to workspace '\(targetWorkspace.name)'. Tip: use --fail-if-noop to exit with non-zero code")
        }
        return !failIfNoop
    }
    if window.isFloating {
        // Floating windows are direct children of workspace, not in the tiling tree.
        // Preserve the caller's index hint (used by move-node-to-monitor for
        // directional placement).
        window.bind(to: targetWorkspace, adaptiveWeight: WEIGHT_AUTO, index: index)
    } else if config.tilingInsertionStrategy == .splitMru {
        // BSP mode: route through the same dispatch that newly-detected windows use
        // so the window lands BSP-wrapped on the destination workspace rather than
        // as a flat sibling of root. The index hint (e.g. from move-node-to-monitor's
        // directional placement) is intentionally ignored in BSP mode — BSP
        // determines placement from the destination's MRU window, not from a
        // cardinal-direction hint.
        let data = unbindAndGetBindingDataForNewTilingWindow(targetWorkspace, window: window)
        window.bind(to: data.parent, adaptiveWeight: data.adaptiveWeight, index: data.index)
    } else {
        // Existing sibling-of-mru behavior: bind directly to root at the requested
        // index. This preserves upstream behavior exactly for non-BSP users.
        window.bind(to: targetWorkspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: index)
    }
    return focusFollowsWindow ? window.focusWindow() : true
}
