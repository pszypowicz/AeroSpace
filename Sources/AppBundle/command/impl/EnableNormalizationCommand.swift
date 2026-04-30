import Common

struct EnableNormalizationCommand: Command {
    let args: EnableNormalizationCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        let workspace = args.workspaceName.map { Workspace.get(byName: $0.raw) } ?? focus.workspace
        let kind = args.kind.val
        let prevEffective = workspace.isNormalizationEnabled(kind)

        switch args.targetState.val {
            case .on:
                if args.failIfNoop && prevEffective && workspace.normalizationOverride[kind] == true {
                    return .fail(io.err("Normalization '\(kind.rawValue)' is already enabled on workspace '\(workspace.name)'. Tip: use --fail-if-noop to exit with non-zero code"))
                }
                workspace.normalizationOverride[kind] = true
            case .off:
                if args.failIfNoop && !prevEffective && workspace.normalizationOverride[kind] == false {
                    return .fail(io.err("Normalization '\(kind.rawValue)' is already disabled on workspace '\(workspace.name)'. Tip: use --fail-if-noop to exit with non-zero code"))
                }
                workspace.normalizationOverride[kind] = false
            case .toggle:
                workspace.normalizationOverride[kind] = !prevEffective
            case .reset:
                workspace.normalizationOverride.removeValue(forKey: kind)
        }
        return .succ
    }
}
