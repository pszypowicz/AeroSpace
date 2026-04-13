@testable import AppBundle
import Common
import XCTest

@MainActor
final class MoveNodeToWorkspaceCommandTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testParse() {
        testParseCommandSucc("move-node-to-workspace next", MoveNodeToWorkspaceCmdArgs(target: .relative(.next)))
        assertEquals(parseCommand("move-node-to-workspace --fail-if-noop next").errorOrNil, "--fail-if-noop is incompatible with (next|prev)")
        assertEquals(parseCommand("move-node-to-workspace --stdin foo").errorOrNil, "--stdin and --no-stdin require using (next|prev) argument")
        testParseCommandSucc("move-node-to-workspace --stdin next", MoveNodeToWorkspaceCmdArgs(target: .relative(.next)).copy(\.explicitStdinFlag, true))
        testParseCommandSucc("move-node-to-workspace --no-stdin next", MoveNodeToWorkspaceCmdArgs(target: .relative(.next)).copy(\.explicitStdinFlag, false))
    }

    func testSimple() async throws {
        let workspaceA = Workspace.get(byName: "a")
        workspaceA.rootTilingContainer.apply {
            _ = TestWindow.new(id: 1, parent: $0).focusWindow()
        }

        try await MoveNodeToWorkspaceCommand(args: MoveNodeToWorkspaceCmdArgs(workspace: "b")).run(.defaultEnv, .emptyStdin)
        XCTAssertTrue(workspaceA.isEffectivelyEmpty)
        assertEquals((Workspace.get(byName: "b").rootTilingContainer.children.singleOrNil() as? Window)?.windowId, 1)
    }

    func testEmptyWorkspaceSubject() async throws {
        let workspaceA = Workspace.get(byName: "a")
        workspaceA.rootTilingContainer.apply {
            _ = TestWindow.new(id: 1, parent: $0).focusWindow()
        }

        try await MoveNodeToWorkspaceCommand(args: MoveNodeToWorkspaceCmdArgs(workspace: "b")).run(.defaultEnv, .emptyStdin)
        assertEquals(focus.workspace.name, "a")
    }

    func testAnotherWindowSubject() async throws {
        Workspace.get(byName: "a").rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            _ = TestWindow.new(id: 2, parent: $0).focusWindow()
        }

        try await MoveNodeToWorkspaceCommand(args: MoveNodeToWorkspaceCmdArgs(workspace: "b")).run(.defaultEnv, .emptyStdin)
        assertEquals(focus.windowOrNil?.windowId, 1)
    }

    func testPreserveFloatingLayout() async throws {
        let workspaceA = Workspace.get(byName: "a").apply {
            _ = TestWindow.new(id: 1, parent: $0).focusWindow()
        }

        try await MoveNodeToWorkspaceCommand(args: MoveNodeToWorkspaceCmdArgs(workspace: "b")).run(.defaultEnv, .emptyStdin)
        XCTAssertTrue(workspaceA.isEffectivelyEmpty)
        assertEquals(Workspace.get(byName: "b").children.filterIsInstance(of: Window.self).singleOrNil()?.windowId, 1)
    }

    func testSummonWindow() async throws {
        let workspaceA = Workspace.get(byName: "a").apply {
            $0.rootTilingContainer.apply {
                _ = TestWindow.new(id: 1, parent: $0).focusWindow()
            }
        }
        Workspace.get(byName: "b").rootTilingContainer.apply {
            TestWindow.new(id: 2, parent: $0)
        }

        assertEquals(focus.workspace, workspaceA)

        try await MoveNodeToWorkspaceCommand(args: MoveNodeToWorkspaceCmdArgs(workspace: "a").copy(\.windowId, 2))
            .run(.defaultEnv, .emptyStdin)

        assertEquals(focus.workspace, workspaceA)
        assertEquals(focus.windowOrNil?.windowId, 1)
        assertEquals(Workspace.get(byName: "b").rootTilingContainer.children.count, 0)
        assertEquals(workspaceA.rootTilingContainer.children.count, 2)
    }

    // MARK: - BSP interaction (split-mru insertion strategy)

    /// Simulates the user's on-window-detected routing workflow: every new window is
    /// detected on some transient workspace and immediately routed to a target via
    /// `move-node-to-workspace`. The test asserts that the destination workspace
    /// ends up with a BSP-shaped tree rather than the flat-sibling tree the
    /// pre-fix `moveWindowToWorkspace` produced.
    func testBsp_moveFourWindowsToTargetWorkspace_producesFibonacci() async throws {
        config.tilingInsertionStrategy = .splitMru
        let targetWs = Workspace.get(byName: "bsp-target")

        for id: UInt32 in 1 ... 4 {
            // Each window appears on workspace "a" first (simulating on-window-detected
            // firing from wherever the app spawned the window), then immediately gets
            // routed to the target.
            let sourceWs = Workspace.get(byName: "a")
            let w = TestWindow.new(id: id, parent: sourceWs.rootTilingContainer)
            _ = w.focusWindow()
            try await MoveNodeToWorkspaceCommand(args: MoveNodeToWorkspaceCmdArgs(workspace: "bsp-target"))
                .run(.defaultEnv, .emptyStdin)
        }

        assertEquals(
            targetWs.rootTilingContainer.layoutDescription,
            .h_tiles([
                .window(1),
                .v_tiles([
                    .window(2),
                    .h_tiles([.window(3), .window(4)]),
                ]),
            ]),
        )
    }

    func testBsp_moveIntoNonEmptyWorkspace_wrapsMru() async throws {
        config.tilingInsertionStrategy = .splitMru
        // Seed the target workspace with two windows directly (bypassing insertion),
        // as if they were already there from a previous session.
        let targetWs = Workspace.get(byName: "bsp-target").apply {
            $0.rootTilingContainer.apply {
                TestWindow.new(id: 1, parent: $0)
                _ = TestWindow.new(id: 2, parent: $0).focusWindow() // MRU
            }
        }
        // The moved window goes through split-mru on the target, wrapping w2.
        let sourceWs = Workspace.get(byName: "a")
        let w3 = TestWindow.new(id: 3, parent: sourceWs.rootTilingContainer)
        _ = w3.focusWindow()
        try await MoveNodeToWorkspaceCommand(args: MoveNodeToWorkspaceCmdArgs(workspace: "bsp-target"))
            .run(.defaultEnv, .emptyStdin)

        assertEquals(
            targetWs.rootTilingContainer.layoutDescription,
            .h_tiles([
                .window(1),
                .v_tiles([.window(2), .window(3)]),
            ]),
        )
    }

    func testBsp_moveToEmptyWorkspace_landsAtRoot() async throws {
        config.tilingInsertionStrategy = .splitMru
        let sourceWs = Workspace.get(byName: "a")
        let w1 = TestWindow.new(id: 1, parent: sourceWs.rootTilingContainer)
        _ = w1.focusWindow()

        try await MoveNodeToWorkspaceCommand(args: MoveNodeToWorkspaceCmdArgs(workspace: "bsp-target"))
            .run(.defaultEnv, .emptyStdin)

        assertEquals(
            Workspace.get(byName: "bsp-target").rootTilingContainer.layoutDescription,
            .h_tiles([.window(1)]),
        )
        XCTAssertTrue(sourceWs.isEffectivelyEmpty)
    }

    func testSiblingOfMru_isDefault_moveCommandUnchangedBehavior() async throws {
        // Default strategy: move-node-to-workspace lands at root as INDEX_BIND_LAST,
        // matching pre-BSP upstream behavior exactly. Four windows routed one by one
        // into an empty target produce a flat h_tiles with four siblings, NOT a BSP
        // shape.
        XCTAssertEqual(config.tilingInsertionStrategy, .siblingOfMru)
        let targetWs = Workspace.get(byName: "flat-target")

        for id: UInt32 in 1 ... 4 {
            let sourceWs = Workspace.get(byName: "a")
            let w = TestWindow.new(id: id, parent: sourceWs.rootTilingContainer)
            _ = w.focusWindow()
            try await MoveNodeToWorkspaceCommand(args: MoveNodeToWorkspaceCmdArgs(workspace: "flat-target"))
                .run(.defaultEnv, .emptyStdin)
        }

        assertEquals(
            targetWs.rootTilingContainer.layoutDescription,
            .h_tiles([.window(1), .window(2), .window(3), .window(4)]),
        )
    }
}
