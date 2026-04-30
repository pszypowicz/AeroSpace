@testable import AppBundle
import Common
import XCTest

@MainActor
final class EnableNormalizationCommandTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testOverride_on_takesPrecedenceOverGlobalOff() {
        config.enableNormalizationBspShape = false
        let workspace = Workspace.get(byName: name)
        workspace.normalizationOverride[.bspShape] = true

        XCTAssertTrue(workspace.isNormalizationEnabled(.bspShape))
    }

    func testOverride_off_takesPrecedenceOverGlobalOn() {
        config.enableNormalizationBspShape = true
        let workspace = Workspace.get(byName: name)
        workspace.normalizationOverride[.bspShape] = false

        XCTAssertFalse(workspace.isNormalizationEnabled(.bspShape))
    }

    func testOverride_isPerWorkspace() {
        config.enableNormalizationBspShape = false
        let a = Workspace.get(byName: "ws-A-\(name)")
        let b = Workspace.get(byName: "ws-B-\(name)")
        a.normalizationOverride[.bspShape] = true

        XCTAssertTrue(a.isNormalizationEnabled(.bspShape))
        XCTAssertFalse(b.isNormalizationEnabled(.bspShape))
    }

    func testOverride_appliedAtRefreshTime() {
        config.enableNormalizationBspShape = false
        let workspace = Workspace.get(byName: name)
        workspace.normalizationOverride[.bspShape] = true
        for id: UInt32 in 1 ... 3 {
            TestWindow.new(id: id, parent: workspace.rootTilingContainer)
        }

        workspace.normalizeContainers()

        // bsp-shape ran on this workspace despite the global flag being off.
        assertEquals(
            workspace.rootTilingContainer.layoutDescription,
            .h_tiles([
                .window(1),
                .v_tiles([.window(2), .window(3)]),
            ]),
        )
    }

    func testCommand_on_setsOverride() async {
        let workspace = focusedTestWorkspace()
        let args = EnableNormalizationCmdArgs(rawArgs: [], kind: .bspShape, targetState: .on)
        _ = await EnableNormalizationCommand(args: args)
            .run(.defaultEnv.withWorkspaceName(workspace.name), .emptyStdin)

        XCTAssertEqual(workspace.normalizationOverride[.bspShape], true)
    }

    func testCommand_off_setsOverride() async {
        let workspace = focusedTestWorkspace()
        let args = EnableNormalizationCmdArgs(rawArgs: [], kind: .bspShape, targetState: .off)
        _ = await EnableNormalizationCommand(args: args)
            .run(.defaultEnv.withWorkspaceName(workspace.name), .emptyStdin)

        XCTAssertEqual(workspace.normalizationOverride[.bspShape], false)
    }

    func testCommand_toggle_flipsEffectiveValue() async {
        config.enableNormalizationBspShape = false
        let workspace = focusedTestWorkspace()
        let args = EnableNormalizationCmdArgs(rawArgs: [], kind: .bspShape, targetState: .toggle)

        _ = await EnableNormalizationCommand(args: args)
            .run(.defaultEnv.withWorkspaceName(workspace.name), .emptyStdin)
        XCTAssertEqual(workspace.normalizationOverride[.bspShape], true)

        _ = await EnableNormalizationCommand(args: args)
            .run(.defaultEnv.withWorkspaceName(workspace.name), .emptyStdin)
        XCTAssertEqual(workspace.normalizationOverride[.bspShape], false)
    }

    func testCommand_reset_clearsOverride() async {
        let workspace = focusedTestWorkspace()
        workspace.normalizationOverride[.bspShape] = true
        let args = EnableNormalizationCmdArgs(rawArgs: [], kind: .bspShape, targetState: .reset)

        _ = await EnableNormalizationCommand(args: args)
            .run(.defaultEnv.withWorkspaceName(workspace.name), .emptyStdin)

        XCTAssertNil(workspace.normalizationOverride[.bspShape])
    }

    /// '--workspace <name>' targets a non-focused workspace without leaking the
    /// override onto the focused one. Without the flag the command would fall
    /// through to `focus.workspace`.
    func testCommand_withWorkspaceFlag_targetsNonFocusedWorkspace() async {
        // Hardcoded simple name so WorkspaceName.parse accepts it; XCTest's
        // 'name' property contains brackets that are not legal in workspace
        // names.
        let otherName = "ws-flag-target"
        let focused = focusedTestWorkspace()
        let other = Workspace.get(byName: otherName)
        XCTAssertNotEqual(focused.name, other.name, "test setup error: --workspace target must not be focused")
        // setUpWorkspacesForTests doesn't clear normalizationOverride; prior
        // tests in the suite may have left state on the focused workspace.
        focused.normalizationOverride.removeAll()
        other.normalizationOverride.removeAll()

        guard case .success(let parsedName) = WorkspaceName.parse(otherName) else {
            return XCTFail("WorkspaceName.parse rejected '\(otherName)'")
        }
        let args = EnableNormalizationCmdArgs(rawArgs: [], kind: .bspShape, targetState: .off)
            .copy(\.workspaceName, parsedName)
        _ = await EnableNormalizationCommand(args: args).run(.defaultEnv, .emptyStdin)

        XCTAssertEqual(other.normalizationOverride[.bspShape], false)
        XCTAssertNil(focused.normalizationOverride[.bspShape], "override must not leak to the focused workspace")
    }

    /// Returns the workspace already focused by `setUpWorkspacesForTests()` so it
    /// is not removed by `garbageCollectUnusedWorkspaces()` between command runs.
    @MainActor
    private func focusedTestWorkspace() -> Workspace {
        focus.workspace
    }
}
