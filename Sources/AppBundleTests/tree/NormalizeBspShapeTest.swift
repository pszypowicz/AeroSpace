@testable import AppBundle
import Common
import XCTest

@MainActor
final class NormalizeBspShapeTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    override func tearDown() async throws {
        config.enableNormalizationBspShape = false
        config.enableNormalizationFlattenContainers = true
        config.enableNormalizationOppositeOrientationForNestedContainers = true
    }

    func testBspShape_threeFlatWindows_foldsToTwoDeepBsp() {
        config.enableNormalizationBspShape = true
        let workspace = Workspace.get(byName: name)
        TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        TestWindow.new(id: 3, parent: workspace.rootTilingContainer)

        workspace.normalizeContainers()

        assertEquals(
            workspace.rootTilingContainer.layoutDescription,
            .h_tiles([
                .window(1),
                .v_tiles([.window(2), .window(3)]),
            ]),
        )
    }

    func testBspShape_fourFlatWindows_foldsToFibonacci() {
        config.enableNormalizationBspShape = true
        let workspace = Workspace.get(byName: name)
        for id: UInt32 in 1 ... 4 {
            TestWindow.new(id: id, parent: workspace.rootTilingContainer)
        }

        workspace.normalizeContainers()

        assertEquals(
            workspace.rootTilingContainer.layoutDescription,
            .h_tiles([
                .window(1),
                .v_tiles([
                    .window(2),
                    .h_tiles([.window(3), .window(4)]),
                ]),
            ]),
        )
    }

    func testBspShape_alreadyBspTree_isFixedPoint() {
        config.enableNormalizationBspShape = true
        let workspace = Workspace.get(byName: name)
        for id: UInt32 in 1 ... 4 {
            TestWindow.new(id: id, parent: workspace.rootTilingContainer)
        }
        workspace.normalizeContainers()
        let firstPass = workspace.rootTilingContainer.layoutDescription

        workspace.normalizeContainers()
        let secondPass = workspace.rootTilingContainer.layoutDescription

        assertEquals(firstPass, secondPass)
    }

    func testBspShape_twoChildren_unchanged() {
        config.enableNormalizationBspShape = true
        let workspace = Workspace.get(byName: name)
        TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer)

        workspace.normalizeContainers()

        assertEquals(
            workspace.rootTilingContainer.layoutDescription,
            .h_tiles([.window(1), .window(2)]),
        )
    }

    func testBspShape_disabled_noChange() {
        config.enableNormalizationBspShape = false
        // Disable flatten too so the 3-flat-children shape survives the refresh
        // and we can assert the bsp-shape pass did nothing.
        config.enableNormalizationFlattenContainers = false
        let workspace = Workspace.get(byName: name)
        TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        TestWindow.new(id: 3, parent: workspace.rootTilingContainer)

        workspace.normalizeContainers()

        assertEquals(
            workspace.rootTilingContainer.layoutDescription,
            .h_tiles([.window(1), .window(2), .window(3)]),
        )
    }

    func testBspShape_accordionParent_skipped() {
        config.enableNormalizationBspShape = true
        let workspace = Workspace.get(byName: name)
        let accordion = TilingContainer(
            parent: workspace.rootTilingContainer,
            adaptiveWeight: 1,
            .h,
            .accordion,
            index: INDEX_BIND_LAST,
        )
        TestWindow.new(id: 1, parent: accordion)
        TestWindow.new(id: 2, parent: accordion)
        TestWindow.new(id: 3, parent: accordion)

        workspace.normalizeContainers()

        // The accordion subtree must remain flat: bsp-shape only folds 'tiles'
        // containers, accordion is an explicit user choice and stays as is.
        assertEquals(
            accordion.layoutDescription,
            .h_accordion([.window(1), .window(2), .window(3)]),
        )
    }

    func testBspShape_withFlattenEnabled_doesNotCollapseFreshWrapper() {
        config.enableNormalizationBspShape = true
        config.enableNormalizationFlattenContainers = true
        let workspace = Workspace.get(byName: name)
        for id: UInt32 in 1 ... 3 {
            TestWindow.new(id: id, parent: workspace.rootTilingContainer)
        }

        workspace.normalizeContainers()

        // Wrapper has two children, so flatten leaves it alone. Result must be a
        // proper BSP shape, not collapsed back to a flat triple.
        assertEquals(
            workspace.rootTilingContainer.layoutDescription,
            .h_tiles([
                .window(1),
                .v_tiles([.window(2), .window(3)]),
            ]),
        )
    }

    /// The fold only ever creates two-child wrappers, so flatten-off should
    /// not produce degenerate single-child containers. This pins the invariant
    /// against future flatten-touching changes.
    func testBspShape_withFlattenDisabled_stillProducesValidBspShape() {
        config.enableNormalizationBspShape = true
        config.enableNormalizationFlattenContainers = false
        let workspace = Workspace.get(byName: name)
        for id: UInt32 in 1 ... 4 {
            TestWindow.new(id: id, parent: workspace.rootTilingContainer)
        }

        workspace.normalizeContainers()

        assertEquals(
            workspace.rootTilingContainer.layoutDescription,
            .h_tiles([
                .window(1),
                .v_tiles([
                    .window(2),
                    .h_tiles([.window(3), .window(4)]),
                ]),
            ]),
        )
    }

    func testBspShape_withOppositeOrientationEnabled_orientationsAlternate() {
        config.enableNormalizationBspShape = true
        config.enableNormalizationOppositeOrientationForNestedContainers = true
        let workspace = Workspace.get(byName: name)
        for id: UInt32 in 1 ... 4 {
            TestWindow.new(id: id, parent: workspace.rootTilingContainer)
        }

        workspace.normalizeContainers()

        // Each nested wrapper alternates orientation relative to its parent.
        let root = workspace.rootTilingContainer
        XCTAssertEqual(root.orientation, .h)
        let firstWrapper = root.children[1] as? TilingContainer
        XCTAssertEqual(firstWrapper?.orientation, .v)
        let secondWrapper = firstWrapper?.children[1] as? TilingContainer
        XCTAssertEqual(secondWrapper?.orientation, .h)
    }

    /// The MRU-pivot fold's central claim: the new window splits the focused
    /// window's slot, not whichever-pair-happens-to-be-at-the-end-of-children.
    /// Without this test, the MRU pivot is interchangeable with a position-only
    /// fold for any sequentially-built test setup (which is every other test in
    /// this file).
    func testBspShape_focusedWindowDeterminesFoldPivot() {
        config.enableNormalizationBspShape = true
        let workspace = Workspace.get(byName: name)
        let w1 = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        // Re-focus w1 so it is most-recent in the root's MRU stack. After w3
        // is bound, MRU = [w3, w1, w2] - w1 is the previously-focused child
        // that w3 should split with, not w2 (the last sequentially bound).
        w1.markAsMostRecentChild()
        TestWindow.new(id: 3, parent: workspace.rootTilingContainer)

        workspace.normalizeContainers()

        // Focus-aware fold wraps [w1, w3] together at w1's index (0); w2 stays
        // alone at index 1. A position-only fold would have produced
        // `[.window(1), .v_tiles([.window(2), .window(3)])]` instead - a
        // visibly different arrangement that would shuffle w2 out from under
        // the user.
        assertEquals(
            workspace.rootTilingContainer.layoutDescription,
            .h_tiles([
                .v_tiles([.window(1), .window(3)]),
                .window(2),
            ]),
        )

        // The fold rebinds the wrapper, so it is now the most-recent child of
        // root. Inside the wrapper, w3 (pre-fold MRU[0]) remains most-recent.
        // Asserting MRU positions catches a future regression where the fold
        // accidentally reorders the MRU stack.
        let wrapper = workspace.rootTilingContainer.children[0] as? TilingContainer
        XCTAssertNotNil(wrapper, "fold must produce a wrapper at index 0")
        XCTAssertTrue(workspace.rootTilingContainer.mostRecentChild === wrapper)
        XCTAssertEqual((wrapper?.mostRecentChild as? TestWindow)?.windowId, 3)
    }

    /// The wrapper inherits the previously-focused child's weight so the user's
    /// custom proportions for non-focused siblings survive a new-window event.
    /// Without this, opening a new window when the focused window is narrow
    /// would collapse all top-level slots to 50/50.
    func testBspShape_preservesUserCustomisedSiblingWeight() {
        config.enableNormalizationBspShape = true
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        let w1 = TestWindow.new(id: 1, parent: root)
        let w2 = TestWindow.new(id: 2, parent: root)
        // Custom 30/70 weights along the root's horizontal orientation.
        w1.setWeight(.h, 580)
        w2.setWeight(.h, 1340)
        // Focus w1 so the new window splits its slot.
        w1.markAsMostRecentChild()
        TestWindow.new(id: 3, parent: root)

        workspace.normalizeContainers()

        // After fold, root.children = [wrapper, w2]. w2 keeps its 1340 weight
        // (the wrapper covers w1's slot, not w2's). Without the fix, the fold
        // would have set every sibling's weight to 1, destroying the 30/70
        // proportion.
        XCTAssertEqual(w2.getWeight(.h), 1340, "w2 weight must be preserved")
        let wrapper = root.children[0] as? TilingContainer
        XCTAssertNotNil(wrapper, "fold must produce a wrapper at index 0")
        XCTAssertEqual(wrapper?.getWeight(.h), 580, "wrapper must inherit w1's pre-fold weight")
    }

    /// Recursion uses the *subtree's* MRU, not the root's. Focus a leaf inside
    /// a deep wrapper, bind a new window inside that wrapper, and confirm the
    /// fold happens at that level with the right pair.
    func testBspShape_focusInDeepSubtree() {
        config.enableNormalizationBspShape = true
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        TestWindow.new(id: 1, parent: root)
        TestWindow.new(id: 2, parent: root)
        TestWindow.new(id: 3, parent: root)
        workspace.normalizeContainers()
        // Tree is now [w1, wrapper[w2, w3]]; wrapper.MRU = [w3, w2].
        let wrapper = root.children[1] as? TilingContainer
        XCTAssertNotNil(wrapper, "expected initial fold to produce a wrapper")
        // Focus w2 inside the wrapper so wrapper.MRU = [w2, w3].
        let w2 = wrapper!.children[0] as! TestWindow
        w2.markAsMostRecentChild()
        // Bind w4 next to w2 inside wrapper (mimics 'siblingOfMru' placement).
        TestWindow.new(id: 4, parent: wrapper!)

        workspace.normalizeContainers()

        // Fold happens *inside the wrapper*, pivoting on [w4, w2] (top-2 MRU
        // of wrapper). Result: wrapper has [wrapper2[w2, w4], w3]. A
        // position-fold would have produced [w2, wrapper2[w4, w3]] - shuffling
        // w3 out from where the user left it.
        assertEquals(
            workspace.rootTilingContainer.layoutDescription,
            .h_tiles([
                .window(1),
                .v_tiles([
                    .h_tiles([.window(2), .window(4)]),
                    .window(3),
                ]),
            ]),
        )
    }

    /// Five flat windows force the fold loop to nest a wrapper inside another
    /// wrapper of the same orientation. The fold must repair alternation in
    /// the moved subtree itself so the result is a valid BSP tree even when
    /// the global opposite-orientation normaliser is disabled.
    func testBspShape_foldRepairsDeepAlternationLocally() {
        config.enableNormalizationBspShape = true
        // Note: opposite-orientation is OFF (the test setUp default). The
        // alternation must come from the recursive repair inside the fold.
        let workspace = Workspace.get(byName: name)
        for id: UInt32 in 1 ... 5 {
            TestWindow.new(id: id, parent: workspace.rootTilingContainer)
        }

        workspace.normalizeContainers()

        // Walk the resulting tree and verify every nested TilingContainer
        // alternates orientation with its parent. Without the recursive repair,
        // a deep grandchild would share its grandparent's orientation after the
        // fold moves a subtree into a same-orientation wrapper.
        func assertAlternates(_ container: TilingContainer, expected: Orientation) {
            XCTAssertEqual(container.orientation, expected)
            for child in container.children {
                if let inner = child as? TilingContainer {
                    assertAlternates(inner, expected: expected.opposite)
                }
            }
        }
        assertAlternates(workspace.rootTilingContainer, expected: .h)
    }

    /// The central claim of the per-workspace override feature: two workspaces
    /// with different overrides normalize independently. The shape on each is
    /// determined by that workspace's effective setting, not the global config
    /// alone.
    func testBspShape_perWorkspaceOverride_doesNotLeakAcrossWorkspaces() {
        config.enableNormalizationBspShape = true
        let off = Workspace.get(byName: "ws-off-\(name)")
        let on = Workspace.get(byName: "ws-on-\(name)")
        off.normalizationOverride[.bspShape] = false
        // 'on' inherits the global config (true).

        for workspace in [off, on] {
            for id: UInt32 in 1 ... 3 {
                TestWindow.new(id: id, parent: workspace.rootTilingContainer)
            }
            workspace.normalizeContainers()
        }

        // bsp-shape OFF on this workspace: tree stays flat.
        assertEquals(
            off.rootTilingContainer.layoutDescription,
            .h_tiles([.window(1), .window(2), .window(3)]),
        )
        // bsp-shape ON on this workspace: standard fold.
        assertEquals(
            on.rootTilingContainer.layoutDescription,
            .h_tiles([
                .window(1),
                .v_tiles([.window(2), .window(3)]),
            ]),
        )
    }
}
