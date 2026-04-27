@testable import AppBundle
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
}
