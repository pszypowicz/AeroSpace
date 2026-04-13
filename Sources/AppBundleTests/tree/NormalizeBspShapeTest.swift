@testable import AppBundle
import Common
import XCTest

@MainActor
final class NormalizeBspShapeTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.enableNormalizationBspShape = true
    }

    // MARK: - Trivial cases

    func testNormalizeBspShape_emptyTree_noop() {
        let workspace = Workspace.get(byName: name)
        XCTAssertTrue(workspace.rootTilingContainer.children.isEmpty)
        workspace.normalizeContainers()
        XCTAssertTrue(workspace.rootTilingContainer.children.isEmpty)
    }

    func testNormalizeBspShape_disabledFlag_isNoop() {
        config.enableNormalizationBspShape = false
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TestWindow.new(id: 2, parent: $0)
            TestWindow.new(id: 3, parent: $0)
            TestWindow.new(id: 4, parent: $0)
        }
        workspace.normalizeContainers()
        // With the flag off, the flat 4-window tree must be unchanged.
        assertEquals(
            workspace.rootTilingContainer.layoutDescription,
            .h_tiles([.window(1), .window(2), .window(3), .window(4)]),
        )
    }

    func testNormalizeBspShape_alreadyBsp_isFixedPoint() {
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                TestWindow.new(id: 2, parent: $0)
                TilingContainer.newHTiles(parent: $0, adaptiveWeight: 1).apply {
                    TestWindow.new(id: 3, parent: $0)
                    TestWindow.new(id: 4, parent: $0)
                }
            }
        }
        let before = workspace.rootTilingContainer.layoutDescription
        workspace.normalizeContainers()
        assertEquals(workspace.rootTilingContainer.layoutDescription, before)
    }

    // MARK: - Right-deep fold

    func testNormalizeBspShape_flatThreeChildren_foldsTailIntoOpposite() {
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TestWindow.new(id: 2, parent: $0)
            TestWindow.new(id: 3, parent: $0)
        }
        workspace.normalizeContainers()
        assertEquals(
            workspace.rootTilingContainer.layoutDescription,
            .h_tiles([
                .window(1),
                .v_tiles([.window(2), .window(3)]),
            ]),
        )
    }

    func testNormalizeBspShape_flatFourChildren_producesRightDeepBsp() {
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TestWindow.new(id: 2, parent: $0)
            TestWindow.new(id: 3, parent: $0)
            TestWindow.new(id: 4, parent: $0)
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

    func testNormalizeBspShape_flatTenChildren_producesRightDeepBsp() {
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            for id: UInt32 in 1 ... 10 {
                TestWindow.new(id: id, parent: $0)
            }
        }
        workspace.normalizeContainers()
        // The right-deep fold makes every tiles container hold exactly two children.
        // Walk the tree and verify the property without writing the 9-level-deep literal.
        var current: TreeNode = workspace.rootTilingContainer
        var seenWindowIds: [UInt32] = []
        var alternationStack: [Orientation] = [.h] // root starts horizontal
        while let container = current as? TilingContainer {
            XCTAssertEqual(container.layout, .tiles)
            XCTAssertEqual(container.children.count, 2)
            XCTAssertEqual(container.orientation, alternationStack.last!)
            // Left child is a leaf window (or, at the very bottom, both children are windows).
            let leftWindow = container.children[0] as! Window
            seenWindowIds.append(leftWindow.windowId)
            current = container.children[1]
            alternationStack.append(alternationStack.last!.opposite)
        }
        // Bottom of the spine: the last `current` is the trailing leaf window.
        let lastWindow = current as! Window
        seenWindowIds.append(lastWindow.windowId)
        assertEquals(seenWindowIds, Array<UInt32>(1 ... 10))
    }

    // MARK: - Recursion & accordion handling

    func testNormalizeBspShape_recursesIntoExistingNestedContainers() {
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            // A nested tiles container that is itself non-BSP (3 children).
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                TestWindow.new(id: 2, parent: $0)
                TestWindow.new(id: 3, parent: $0)
                TestWindow.new(id: 4, parent: $0)
            }
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

    func testNormalizeBspShape_skipsAccordionSubtrees() {
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TilingContainer(parent: $0, adaptiveWeight: 1, .h, .accordion, index: INDEX_BIND_LAST).apply {
                TestWindow.new(id: 2, parent: $0)
                TestWindow.new(id: 3, parent: $0)
                TestWindow.new(id: 4, parent: $0)
            }
        }
        workspace.normalizeContainers()
        // The accordion's children must NOT have been folded.
        assertEquals(
            workspace.rootTilingContainer.layoutDescription,
            .h_tiles([
                .window(1),
                .h_accordion([.window(2), .window(3), .window(4)]),
            ]),
        )
    }

    // MARK: - Ordering with other normalizations

    func testNormalizeBspShape_runsAfterFlatten() {
        // Flatten collapses 1-child wrappers BEFORE bsp-shape sees the tree, so a
        // tree shaped like h([h([w1]), w2, w3]) — where the inner h([w1]) is a
        // collapse target — gets first flattened to h([w1, w2, w3]) and then folded
        // by bsp-shape into h([w1, v([w2, w3])]).
        config.enableNormalizationFlattenContainers = true
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            TilingContainer.newHTiles(parent: $0, adaptiveWeight: 1).apply {
                TestWindow.new(id: 1, parent: $0)
            }
            TestWindow.new(id: 2, parent: $0)
            TestWindow.new(id: 3, parent: $0)
        }
        workspace.normalizeContainers()
        assertEquals(
            workspace.rootTilingContainer.layoutDescription,
            .h_tiles([
                .window(1),
                .v_tiles([.window(2), .window(3)]),
            ]),
        )
    }

    func testNormalizeBspShape_runsAfterOppositeOrientation() {
        // The opposite-orientation normalizer flips a same-orientation child container
        // BEFORE bsp-shape sees it. Without that pass, two adjacent same-orientation
        // tiles containers would still get folded by bsp-shape, but the resulting
        // tree would not match upstream's idea of "BSP". With the pass enabled, the
        // child container is flipped to v_tiles first, and bsp-shape leaves it alone
        // (count == 2, already BSP).
        config.enableNormalizationOppositeOrientationForNestedContainers = true
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            // Same orientation as root (.h) — opposite-orientation pass will flip it to .v.
            TilingContainer.newHTiles(parent: $0, adaptiveWeight: 1).apply {
                TestWindow.new(id: 2, parent: $0)
                TestWindow.new(id: 3, parent: $0)
            }
        }
        workspace.normalizeContainers()
        assertEquals(
            workspace.rootTilingContainer.layoutDescription,
            .h_tiles([
                .window(1),
                .v_tiles([.window(2), .window(3)]),
            ]),
        )
    }

    // MARK: - Weight handling

    func testNormalizeBspShape_wrapperInheritsTailWeightSum() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0, adaptiveWeight: 1)
            TestWindow.new(id: 2, parent: $0, adaptiveWeight: 2)
            TestWindow.new(id: 3, parent: $0, adaptiveWeight: 3)
            TestWindow.new(id: 4, parent: $0, adaptiveWeight: 4)
        }
        workspace.normalizeContainers()
        // Root: [w1 (weight 1), wrapper (weight 2+3+4=9)]
        XCTAssertEqual(root.children.count, 2)
        let wrapper = root.children[1] as! TilingContainer
        XCTAssertEqual(wrapper.getWeight(.h), 9)
        // Inside the wrapper (vertical): w2 keeps its original weight (2), and the
        // inner wrapper (which now holds w3 + w4) inherits 3+4=7.
        XCTAssertEqual(wrapper.children.count, 2)
        let innerWindow2 = wrapper.children[0] as! Window
        XCTAssertEqual(innerWindow2.getWeight(.v), 2)
        let innerWrapper = wrapper.children[1] as! TilingContainer
        XCTAssertEqual(innerWrapper.getWeight(.v), 7)
    }
}
