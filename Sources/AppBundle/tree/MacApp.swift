import AppKit
import Common

// Potential alternative implementation
// https://github.com/swiftlang/swift-evolution/blob/main/proposals/0392-custom-actor-executors.md
// (only available since macOS 14)
final class MacApp: AbstractApp {
    /*conforms*/ let pid: Int32
    /*conforms*/ let rawAppBundleId: String?
    let appId: KnownBundleId?
    let nsApp: NSRunningApplication
    private let axApp: ThreadGuardedValue<AXUIElement>
    private let appAxSubscriptions: ThreadGuardedValue<[AxSubscription]> // keep subscriptions in memory
    private let windows: ThreadGuardedValue<[UInt32: AxWindow]> = .init([:])
    private var windowsCount = 0
    var lastNativeFocusedWindowId: UInt32? = nil
    private var thread: Thread?
    private var setFrameJobs: [UInt32: RunLoopJob] = [:]
    // Last known size of windows that silently refused an AX resize even after an unstick attempt.
    // See verifyOrUnstickAxSize
    private let refusedAxSizes: ThreadGuardedValue<[UInt32: CGSize]> = .init([:])
    @MainActor private static var focusJob: RunLoopJob? = nil

    /*conforms*/ var name: String? { nsApp.localizedName }
    /*conforms*/ var execPath: String? { nsApp.executableURL?.path }
    /*conforms*/ var bundlePath: String? { nsApp.bundleURL?.path }

    // todo think if it's possible to integrate this global mutable state to https://github.com/nikitabobko/AeroSpace/issues/1215
    //      and make deinitialization automatic in deinit
    @MainActor static var allAppsMap: [pid_t: MacApp] = [:]
    @MainActor private static var wipPids: [pid_t: AwaitableOneTimeBroadcastLatch] = [:]
    @MainActor private static var failedRegistrationRetryAfter: [pid_t: Date] = [:]
    private static let failedRegistrationRetryDelay: TimeInterval = 5

    private init(_ nsApp: NSRunningApplication, _ axApp: AXUIElement, _ axSubscriptions: [AxSubscription], _ thread: Thread) {
        self.nsApp = nsApp
        self.axApp = .init(axApp)
        self.pid = nsApp.processIdentifier
        self.rawAppBundleId = nsApp.bundleIdentifier
        self.appId = nsApp.bundleIdentifier.flatMap { KnownBundleId.init(rawValue: $0) }
        assert(!axSubscriptions.isEmpty)
        self.appAxSubscriptions = .init(axSubscriptions)
        self.thread = thread
    }

    @MainActor
    @discardableResult
    static func getOrRegister(_ nsApp: NSRunningApplication) async throws -> MacApp? {
        // Don't perceive any of the lock screen windows as real windows
        // Otherwise, false positive ax notifications might trigger that lead to gcWindows
        if nsApp.bundleIdentifier == lockScreenAppBundleId { return nil }
        let pid = nsApp.processIdentifier
        // AX requests crash if you send them to yourself
        if pid == myPid { return nil }

        while true {
            if let existing = allAppsMap[pid] { return existing }
            if let retryAfter = failedRegistrationRetryAfter[pid] {
                if retryAfter > Date() { return nil }
                failedRegistrationRetryAfter[pid] = nil
            }
            try checkCancellation()
            if let wip = wipPids[pid] {
                try await wip.await()
                continue
            }
            let wip = AwaitableOneTimeBroadcastLatch()
            wipPids[pid] = wip

            let thread = Thread {
                $axTaskLocalAppThreadToken.withValue(AxAppThreadToken(pid: pid, idForDebug: nsApp.idForDebug)) {
                    let axApp = AXUIElementCreateApplication(nsApp.processIdentifier)
                    let handlers: HandlerToNotifKeyMapping = unsafe [
                        (refreshObs, [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification]),
                    ]
                    let job = RunLoopJob()
                    let subscriptions = (try? unsafe AxSubscription.bulkSubscribe(nsApp, axApp, job, handlers)) ?? []
                    let isGood = !subscriptions.isEmpty
                    let app = isGood ? MacApp(nsApp, axApp, subscriptions, Thread.current) : nil
                    Task { @MainActor in
                        if let app {
                            allAppsMap[pid] = app
                            failedRegistrationRetryAfter[pid] = nil
                        } else {
                            failedRegistrationRetryAfter[pid] = Date().addingTimeInterval(failedRegistrationRetryDelay)
                        }
                        await wip.signalToAll()
                        wipPids[pid] = nil
                    }
                    if isGood {
                        CFRunLoopRun()
                    }
                }
            }
            thread.name = "AxAppThread \(nsApp.idForDebug)"
            thread.start()
        }
    }

    func closeAndUnregisterAxWindow(_ windowId: UInt32) {
        if serverArgs.isReadOnly { return }
        setFrameJobs.removeValue(forKey: windowId)?.cancel()
        _ = withWindowAsync(windowId) { [windows, refusedAxSizes] window, job in
            guard let closeButton = window.get(Ax.closeButtonAttr) else { return }
            if AXUIElementPerformAction(closeButton.cast, kAXPressAction as CFString) == .success {
                windows.threadGuarded.removeValue(forKey: windowId)
                refusedAxSizes.threadGuarded.removeValue(forKey: windowId)
            }
        }
    }

    func getAxSize(_ windowId: UInt32) async throws -> CGSize? {
        try await withWindow(windowId) { window, job in
            window.get(Ax.sizeAttr)
        }
    }

    // todo merge together with detectNewWindows
    func getFocusedWindow() async throws -> Window? {
        let windowId = try await thread?.runInLoop { [nsApp, axApp, windows] job in
            try axApp.threadGuarded.get(Ax.focusedWindowAttr)
                .flatMap { try windows.threadGuarded.getOrRegisterAxWindow(windowId: $0.windowId, $0.ax.cast, nsApp, job) }?
                .windowId
        }
        guard let windowId else { return nil }
        return try await MacWindow.getOrRegister(windowId: windowId, macApp: self)
    }

    @MainActor func nativeFocus(_ windowId: UInt32) {
        if serverArgs.isReadOnly { return }
        MacApp.focusJob?.cancel()
        // Performance optimization. If possible avoid doing AX requests
        // (important for apps which are slow at responding even such basic AX requests. E.g. Godot)
        // Beware of the macOS bug: https://github.com/nikitabobko/AeroSpace/issues/101
        if (!NSScreen.screensHaveSeparateSpaces || monitors.count == 1) &&
            (lastNativeFocusedWindowId == windowId || windowsCount == 1)
        {
            nsApp.activate(options: .activateIgnoringOtherApps)
        } else {
            MacApp.focusJob = withWindowAsync(windowId) { [nsApp] window, job in
                // Raise firstly to make sure that by the time we activate the app, the window would be already on top
                window.set(Ax.isMainAttr, true)
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                nsApp.activate(options: .activateIgnoringOtherApps)
            }
        }
    }

    func setAxFrame(_ windowId: UInt32, _ topLeft: CGPoint?, _ size: CGSize?) {
        setFrameJobs.removeValue(forKey: windowId)?.cancel()
        setFrameJobs[windowId] = withWindowAsync(windowId) { [axApp, refusedAxSizes] window, job in
            try disableAnimations(app: axApp.threadGuarded, job) {
                try setFrame(window, topLeft, size, job, windowId: windowId, refusedAxSizes: refusedAxSizes)
            }
        }
    }

    func setAxFrameBlocking(_ windowId: UInt32, _ topLeft: CGPoint?, _ size: CGSize?) async throws {
        setFrameJobs.removeValue(forKey: windowId)?.cancel()
        try await withWindow(windowId) { [axApp, refusedAxSizes] window, job in
            try disableAnimations(app: axApp.threadGuarded, job) {
                try setFrame(window, topLeft, size, job, windowId: windowId, refusedAxSizes: refusedAxSizes)
            }
        }
    }

    func getAxWindowsCount() async throws -> Int? {
        try await thread?.runInLoop { [axApp] job in
            axApp.threadGuarded.get(Ax.windowsAttr)?.count
        }
    }

    func getAxRect(_ windowId: UInt32) async throws -> Rect? {
        try await withWindow(windowId) { window, job in
            guard let topLeftCorner = window.get(Ax.topLeftCornerAttr) else { return nil }
            guard let size = window.get(Ax.sizeAttr) else { return nil }
            return Rect(topLeftX: topLeftCorner.x, topLeftY: topLeftCorner.y, width: size.width, height: size.height)
        }
    }

    func isWindowHeuristic(_ windowId: UInt32, _ windowLevel: MacOsWindowLevel?) async throws -> Bool {
        return try await withWindow(windowId) { [nsApp, axApp, appId] window, job in
            window.isWindowHeuristic(axApp: axApp.threadGuarded, appId, nsApp.activationPolicy, windowLevel)
        } == true
    }

    func getAxUiElementWindowType(_ windowId: UInt32, _ windowLevel: MacOsWindowLevel?) async throws -> AxUiElementWindowType {
        return try await withWindow(windowId) { [nsApp, axApp, appId] window, job in
            window.getWindowType(axApp: axApp.threadGuarded, appId, nsApp.activationPolicy, windowLevel)
        } ?? .window
    }

    func isDialogHeuristic(_ windowId: UInt32, _ windowLevel: MacOsWindowLevel?) async throws -> Bool {
        try await withWindow(windowId) { [appId] window, job in
            window.isDialogHeuristic(appId, windowLevel)
        } == true
    }

    func setNativeFullscreen(_ windowId: UInt32, _ value: Bool) {
        setFrameJobs.removeValue(forKey: windowId)?.cancel()
        setFrameJobs[windowId] = withWindowAsync(windowId) { window, job in
            window.set(Ax.isFullscreenAttr, value)
        }
    }

    func setNativeMinimized(_ windowId: UInt32, _ value: Bool) {
        setFrameJobs.removeValue(forKey: windowId)?.cancel()
        setFrameJobs[windowId] = withWindowAsync(windowId) { window, job in
            window.set(Ax.minimizedAttr, value)
        }
    }

    func dumpWindowAxInfo(windowId: UInt32) async throws -> [String: Json] {
        try await withWindow(windowId) { window, job in
            dumpAxRecursive(window, .window)
        } ?? [:]
    }

    func dumpAppAxInfo() async throws -> [String: Json] {
        try await thread?.runInLoop { [axApp] job in
            dumpAxRecursive(axApp.threadGuarded, .app)
        } ?? [:]
    }

    func getAxTitle(_ windowId: UInt32) async throws -> String? {
        try await withWindow(windowId) { window, job in
            window.get(Ax.titleAttr)
        }
    }

    func isMacosNativeFullscreen(_ windowId: UInt32) async throws -> Bool? {
        try await withWindow(windowId) { window, job in
            window.get(Ax.isFullscreenAttr)
        }
    }

    func isMacosNativeMinimized(_ windowId: UInt32) async throws -> Bool? {
        try await withWindow(windowId) { window, job in
            window.get(Ax.minimizedAttr)
        }
    }

    @MainActor
    static func refreshAllAndGetAliveWindowIds(frontmostAppBundleId: String?) async throws -> [MacApp: [UInt32]] {
        for (_, app) in MacApp.allAppsMap { // gc dead apps
            try checkCancellation()
            if app.nsApp.isTerminated {
                await app.destroy()
            }
        }
        return try await withThrowingTaskGroup(of: (pid_t, [UInt32]).self, returning: [MacApp: [UInt32]].self) { group in
            func refreshTheApp(_ nsApp: NSRunningApplication) {
                group.addTask { @Sendable @MainActor in
                    guard let app = try await MacApp.getOrRegister(nsApp) else { return (nsApp.processIdentifier, []) }
                    return (nsApp.processIdentifier, try await app.refreshAndGetAliveWindowIds(frontmostAppBundleId: frontmostAppBundleId))
                }
            }
            // Register new apps
            for nsApp in NSWorkspace.shared.runningApplications {
                try checkCancellation()
                if nsApp.activationPolicy == .regular {
                    refreshTheApp(nsApp)
                }
            }
            for (_, app) in MacApp.allAppsMap {
                try checkCancellation()
                // "About this Mac" window, TouchID, and a lot of other utility windows
                // We don't monitor them actively as we do for regular apps, but if a window of one of those utility
                // apps got focused it will end up in allAppsMap
                if app.nsApp.activationPolicy != .regular {
                    refreshTheApp(app.nsApp)
                }
            }
            var result: [MacApp: [UInt32]] = [:]
            for try await (pid, windowIds) in group {
                if let app = MacApp.allAppsMap[pid] {
                    result[app] = windowIds
                }
            }
            return result
        }
    }

    private func refreshAndGetAliveWindowIds(frontmostAppBundleId: String?) async throws -> [UInt32] {
        if nsApp.isTerminated {
            await destroy()
            return []
        }
        guard let thread else { return [] }
        let (alive, dead) = try await thread.runInLoop { [nsApp, windows, axApp, refusedAxSizes] (job) -> ([UInt32], [UInt32]) in
            var alive: [UInt32: AxWindow] = windows.threadGuarded
            var dead = [UInt32: AxWindow]()
            // Second line of defence against lock screen. See the first line of defence: closedWindowsCache
            // Second and third lines of defence are technically needed only to avoid potential flickering
            if frontmostAppBundleId != lockScreenAppBundleId {
                (alive, dead) = try alive.partition {
                    try job.checkCancellation()
                    return $0.value.ax.containingWindowId() != nil
                }
                for windowId in dead.keys {
                    refusedAxSizes.threadGuarded.removeValue(forKey: windowId)
                }
            }

            for (id, window) in axApp.threadGuarded.get(Ax.windowsAttr) ?? [] {
                try job.checkCancellation()
                try alive.getOrRegisterAxWindow(windowId: id, window, nsApp, job)
            }

            windows.threadGuarded = alive
            return (Array(alive.keys), Array(dead.keys))
        }
        windowsCount = alive.count
        for windowId in dead {
            setFrameJobs.removeValue(forKey: windowId)?.cancel()
        }
        return alive
    }

    private func destroy() async {
        _ = await Task { @MainActor [pid] in
            _ = MacApp.allAppsMap.removeValue(forKey: pid)
            MacApp.failedRegistrationRetryAfter[pid] = nil
        }.result
        for (_, job) in setFrameJobs {
            job.cancel()
        }
        setFrameJobs = [:]
        thread?.runInLoopAsync { [windows, appAxSubscriptions, axApp, refusedAxSizes] job in
            appAxSubscriptions.destroy() // Destroy AX objects in reverse order of their creation
            refusedAxSizes.destroy()
            windows.destroy()
            axApp.destroy()
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        thread = nil // Disallow all future job submissions
    }

    private func withWindow<T>(_ windowId: UInt32, _ body: @Sendable @escaping (AXUIElement, RunLoopJob) throws -> T?) async throws -> T? {
        try await thread?.runInLoop { [windows] job in
            guard let window = windows.threadGuarded[windowId] else { return nil }
            return try body(window.ax, job)
        }
    }

    private func withWindowAsync(_ windowId: UInt32, _ body: @Sendable @escaping (AXUIElement, RunLoopJob) throws -> ()) -> RunLoopJob {
        thread?.runInLoopAsync { [windows] job in
            guard let window = windows.threadGuarded[windowId] else { return }
            try? body(window.ax, job)
        } ?? .cancelled
    }
}

private final class AxWindow {
    let windowId: UInt32
    let ax: AXUIElement
    // periphery:ignore
    private let axSubscriptions: [AxSubscription] // keep subscriptions in memory

    private init(windowId: UInt32, _ ax: AXUIElement, _ axSubscriptions: [AxSubscription]) {
        self.windowId = windowId
        self.ax = ax
        assert(!axSubscriptions.isEmpty)
        self.axSubscriptions = axSubscriptions
    }

    static func new(windowId: UInt32, _ ax: AXUIElement, _ nsApp: NSRunningApplication, _ job: RunLoopJob) throws -> AxWindow? {
        let handlers: HandlerToNotifKeyMapping = unsafe [
            (refreshObs, [kAXUIElementDestroyedNotification, kAXWindowDeminiaturizedNotification, kAXWindowMiniaturizedNotification]),
            (movedObs, [kAXMovedNotification]),
            (resizedObs, [kAXResizedNotification]),
        ]
        let subscriptions = try unsafe AxSubscription.bulkSubscribe(nsApp, ax, job, handlers)
        return !subscriptions.isEmpty ? AxWindow(windowId: windowId, ax, subscriptions) : nil
    }
}

extension [UInt32: AxWindow] {
    @discardableResult
    fileprivate mutating func getOrRegisterAxWindow(windowId id: UInt32, _ axWindow: AXUIElement, _ nsApp: NSRunningApplication, _ job: RunLoopJob) throws -> AxWindow? {
        if let existing = self[id] { return existing }
        // Delay new window detection if mouse is down
        // It helps with apps that allow dragging their tabs out to create new windows
        // https://github.com/nikitabobko/AeroSpace/issues/1001
        if isLeftMouseButtonDown { return nil }

        if let window = try AxWindow.new(windowId: id, axWindow, nsApp, job) {
            self[id] = window
            return window
        } else {
            return nil
        }
    }
}

private func setFrame(
    _ window: AXUIElement,
    _ topLeft: CGPoint?,
    _ size: CGSize?,
    _ job: RunLoopJob,
    windowId: UInt32,
    refusedAxSizes: ThreadGuardedValue<[UInt32: CGSize]>,
) throws {
    // Intentionally no cancellation checks inside the sequence. It may be canceled by jobs that don't re-apply
    // the frame afterwards (minimize, fullscreen, close). An interrupted sequence would leave the window moved
    // to the target position but not resized
    let sizeApplied = applyAxFrame(window, topLeft, size)
    // The set is a deliberate no-op in read-only mode and fails on AX errors (e.g. a closing window).
    // Verification would misread both as a refusal
    guard let size, sizeApplied else { return }
    try verifyOrUnstickAxSize(window, requested: size, topLeft: topLeft, job, windowId: windowId, refusedAxSizes: refusedAxSizes)
}

// Set size and then the position. The order is important https://github.com/nikitabobko/AeroSpace/issues/143
//                                                        https://github.com/nikitabobko/AeroSpace/issues/335
@discardableResult
private func applyAxFrame(_ window: AXUIElement, _ topLeft: CGPoint?, _ size: CGSize?) -> Bool {
    var sizeApplied = false
    if let size { sizeApplied = window.set(Ax.sizeAttr, size) }
    if let topLeft {
        window.set(Ax.topLeftCornerAttr, topLeft)
        if let size { sizeApplied = window.set(Ax.sizeAttr, size) }
    }
    return sizeApplied
}

// Terminals snap their size to the character grid, which legitimately deviates from the requested size.
// Don't treat such deviations as a refusal
private let axSizeApplyTolerance: CGFloat = 20
private let axSizeUnstickNudge: CGFloat = 50
// Some apps need a moment to apply AX frame requests. Delays are in microseconds (usleep)
private let axSizeReadBackDelay: UInt32 = 50000
private let axSizeUnstickDelay: UInt32 = 150_000

// Some apps accept AX resize requests (AXUIElementSetAttributeValue returns .success) and silently ignore them.
// E.g. Microsoft Teams pins the width of its windows while a meeting is active. Such a window can be unstuck:
// a size request that keeps the refused dimension at its current value and changes only the other dimension is
// processed, and the very next frame request is applied normally.
//
// Other windows refuse sizes legitimately and permanently (e.g. a window with a min width tiled into a narrower
// slot). refusedAxSizes remembers the windows that didn't react to the unstick attempt, so that the attempt
// (a visible resize) is not repeated on every layout pass while the window keeps refusing
private func verifyOrUnstickAxSize(
    _ window: AXUIElement,
    requested: CGSize,
    topLeft: CGPoint?,
    _ job: RunLoopJob,
    windowId: UInt32,
    refusedAxSizes: ThreadGuardedValue<[UInt32: CGSize]>,
) throws {
    let lastRefusedSize = refusedAxSizes.threadGuarded[windowId]
    guard var actual = window.get(Ax.sizeAttr) else { return }
    var verdict = axSizeVerdict(requested: requested, actual: actual, lastRefusedSize: lastRefusedSize)
    if case .stuck = verdict {
        // Some apps apply AX frame requests asynchronously. Re-read before concluding that the request was refused
        try job.checkCancellation()
        usleep(axSizeReadBackDelay)
        guard let reread = window.get(Ax.sizeAttr) else { return }
        actual = reread
        verdict = axSizeVerdict(requested: requested, actual: actual, lastRefusedSize: lastRefusedSize)
    }
    switch verdict {
        case .applied:
            refusedAxSizes.threadGuarded.removeValue(forKey: windowId)
        case .knownRefusal:
            break
        case .stuck(let perturbation):
            try job.checkCancellation()
            // No cancellation checks from here on, for the same reason as in setFrame: an interrupted sequence
            // would leave the window at the artificial perturbation size, and the jobs that cancel this one
            // never re-apply the frame. Floating windows would keep the perturbed size forever
            window.set(Ax.sizeAttr, perturbation)
            usleep(axSizeUnstickDelay)
            applyAxFrame(window, topLeft, requested)
            usleep(axSizeReadBackDelay)
            let final = window.get(Ax.sizeAttr) ?? actual
            if axSizeVerdict(requested: requested, actual: final, lastRefusedSize: nil) == .applied {
                refusedAxSizes.threadGuarded.removeValue(forKey: windowId)
            } else {
                refusedAxSizes.threadGuarded[windowId] = final
            }
    }
}

enum AxSizeVerdict: Equatable {
    case applied
    case knownRefusal
    case stuck(perturbation: CGSize)
}

func axSizeVerdict(requested: CGSize, actual: CGSize, lastRefusedSize: CGSize?) -> AxSizeVerdict {
    let widthStuck = abs(actual.width - requested.width) > axSizeApplyTolerance
    let heightStuck = abs(actual.height - requested.height) > axSizeApplyTolerance
    if !widthStuck && !heightStuck { return .applied }
    // Compare only the stuck dimensions: the accepted dimension legitimately tracks every new layout target,
    // and the final read-back may have captured it mid-flight. Exact comparison would re-trigger the unstick
    // attempt on sub-pixel jitter. 2 covers rounding
    if let lastRefusedSize,
       !widthStuck || abs(lastRefusedSize.width - actual.width) <= 2,
       !heightStuck || abs(lastRefusedSize.height - actual.height) <= 2
    {
        return .knownRefusal
    }
    let perturbation = heightStuck && !widthStuck
        ? CGSize(width: nudged(actual.width), height: actual.height)
        : CGSize(width: actual.width, height: nudged(actual.height))
    return .stuck(perturbation: perturbation)
}

// Shrinking is preferred because it always stays within the screen, but grow instead of degenerating
// to a no-op when the dimension is too small to shrink
private func nudged(_ dimension: CGFloat) -> CGFloat {
    dimension - axSizeUnstickNudge >= 100 ? dimension - axSizeUnstickNudge : dimension + axSizeUnstickNudge
}

// Some undocumented magic
// References: https://github.com/koekeishiya/yabai/commit/3fe4c77b001e1a4f613c26f01ea68c0f09327f3a
//             https://github.com/rxhanson/Rectangle/pull/285
private func disableAnimations<T>(app: AXUIElement, _ job: RunLoopJob, _ body: () throws -> T) throws -> T {
    let wasEnabled = app.get(Ax.enhancedUserInterfaceAttr) == true
    if wasEnabled {
        app.set(Ax.enhancedUserInterfaceAttr, false)
    }
    defer {
        if wasEnabled {
            app.set(Ax.enhancedUserInterfaceAttr, true)
        }
    }
    try job.checkCancellation()
    return try body()
}
