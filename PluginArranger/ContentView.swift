//
//  ContentView.swift
//  PluginArranger
//
//  Created by Aiden Elliott on 12/22/25.
//

import SwiftUI
import ApplicationServices
import Combine

extension Notification.Name {
    static let resizeWindow = Notification.Name("resizeWindow")
}

// MARK: - Data Structures

class PluginWindow: Equatable {
    let pluginName: String
    let trackName: String
    let windowElement: AXUIElement
    var originalPosition: CGPoint?
    var isHidden: Bool = false

    init(pluginName: String, trackName: String, windowElement: AXUIElement, originalPosition: CGPoint? = nil, isHidden: Bool = false) {
        self.pluginName = pluginName
        self.trackName = trackName
        self.windowElement = windowElement
        self.originalPosition = originalPosition
        self.isHidden = isHidden
    }

    // Identity is the AX element, not the title: two instances of the same
    // plugin on the same track produce identical "Plugin/Track" titles, and
    // keying on that made them indistinguishable. Names are still compared so
    // a rename still counts as a change for the background scan's refresh.
    static func == (lhs: PluginWindow, rhs: PluginWindow) -> Bool {
        CFEqual(lhs.windowElement, rhs.windowElement)
            && lhs.pluginName == rhs.pluginName
            && lhs.trackName == rhs.trackName
    }
}

// MARK: - PluginWindow Window Operations

extension PluginWindow {
    var position: CGPoint? {
        get {
            var positionRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(windowElement, kAXPositionAttribute as CFString, &positionRef) == .success,
                  let positionValue = positionRef else { return nil }
            var position = CGPoint.zero
            AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
            return position
        }
        set {
            guard let newValue else { return }
            setPosition(newValue)
        }
    }

    /// Move the window, reporting whether AX actually accepted it. `show`/`hide`
    /// need this: a silently dropped write used to leave a window parked
    /// offscreen but flagged visible, which excluded it from every later
    /// "Show All".
    @discardableResult
    func setPosition(_ point: CGPoint) -> Bool {
        var pos = point
        guard let positionValue = AXValueCreate(.cgPoint, &pos) else { return false }
        return AXUIElementSetAttributeValue(
            windowElement, kAXPositionAttribute as CFString, positionValue
        ) == .success
    }

    var size: CGSize? {
        get {
            var sizeRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(windowElement, kAXSizeAttribute as CFString, &sizeRef) == .success,
                  let sizeValue = sizeRef else { return nil }
            var size = CGSize.zero
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
            return size
        }
        set {
            guard var s = newValue else { return }
            let sizeValue = AXValueCreate(.cgSize, &s)!
            AXUIElementSetAttributeValue(windowElement, kAXSizeAttribute as CFString, sizeValue)
        }
    }

    /// Only clear `isHidden` once the window has actually moved back, so a
    /// failed restore stays queued for the next "Show All" instead of being
    /// silently dropped from it.
    func show() {
        guard let original = originalPosition else {
            debugLog("show: no original position for \(pluginName)/\(trackName)")
            return
        }
        guard setPosition(original) else {
            debugLog("show: AX rejected move for \(pluginName)/\(trackName)")
            return
        }
        // Raise too, or a window restored on top of one that's already visible
        // comes back underneath it — shown, but invisible. Arranging raises as
        // it places, which is why the track buttons never hit this and
        // "Show All" did.
        raise()
        isHidden = false
        debugLog("show: \(pluginName)/\(trackName) -> \(Int(original.x)),\(Int(original.y))")
    }

    /// Refuses to park a window whose position can't be read — without an
    /// original to return to, it could never be shown again.
    func hide() {
        guard let current = position else {
            debugLog("hide: can't read position for \(pluginName)/\(trackName)")
            return
        }
        guard let screen = NSScreen.main else { return }
        originalPosition = current
        if setPosition(CGPoint(x: screen.frame.maxX, y: screen.frame.maxY)) {
            isHidden = true
        }
    }

    /// Bring this window to the front within Live's window stack. Arranging
    /// raises each window as it's placed, so later windows sit above earlier
    /// ones instead of disappearing behind them.
    func raise() {
        AXUIElementPerformAction(windowElement, kAXRaiseAction as CFString)
    }

    func close() {
        var closeButtonRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(windowElement, kAXCloseButtonAttribute as CFString, &closeButtonRef) == .success,
              let closeButton = closeButtonRef else { return }
        AXUIElementPerformAction(closeButton as! AXUIElement, kAXPressAction as CFString)
    }
}

struct PluginScanResult {
    var pluginWindows: [PluginWindow]

    var tracks: [String] {
        Set(pluginWindows.map(\.trackName)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var plugins: [String] {
        Set(pluginWindows.map(\.pluginName)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static let empty = PluginScanResult(pluginWindows: [])
}

// MARK: - PluginManager (Shared State)

class PluginManager: ObservableObject {
    @MainActor static let shared = PluginManager()

    @Published var scanResult: PluginScanResult = .empty

    private var backgroundTimer: Timer?
    private let scanInterval: TimeInterval = 1.0

    /// Vertical step applied when `arrangeVisibleWindows` runs out of columns
    /// and wraps back to the left edge, so the new pass doesn't land exactly
    /// on top of the previous one.
    private let wrapStep: CGFloat = 100
    /// How many distinct offsets before the step cycles. Without this the
    /// offset would accumulate and later passes would march off the bottom.
    private let wrapCycle = 3

    private init() {}

    func startBackgroundScanning() {
        guard backgroundTimer == nil else { return }
        backgroundTimer = Timer.scheduledTimer(withTimeInterval: scanInterval, repeats: true) { [weak self] _ in
            self?.backgroundScan()
        }
    }

    func stopBackgroundScanning() {
        backgroundTimer?.invalidate()
        backgroundTimer = nil
    }

    private func backgroundScan() {
        let result = scanPlugins()
        if result.pluginWindows != scanResult.pluginWindows {
            scanResult = result
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NotificationCenter.default.post(name: .resizeWindow, object: nil)
            }
        }
    }

    // MARK: - Window Operations

    func restoreAllHiddenWindows() {
        scanResult.pluginWindows
            .filter(\.isHidden)
            .forEach { $0.position = $0.originalPosition }
    }

    func showAllPlugins() {
        activateLive { [self] in
            let hidden = scanResult.pluginWindows.filter(\.isHidden)
            debugLog("showAll: \(hidden.count) hidden of \(scanResult.pluginWindows.count) total")
            hidden.forEach { $0.show() }
            let stillHidden = scanResult.pluginWindows.filter(\.isHidden)
            if !stillHidden.isEmpty {
                debugLog("showAll: STILL HIDDEN \(stillHidden.map { "\($0.pluginName)/\($0.trackName)" })")
            }
            objectWillChange.send()
        }
    }

    func hideAllPlugins() {
        activateLive { [self] in
            scanResult.pluginWindows.filter { !$0.isHidden }.forEach { $0.hide() }
            objectWillChange.send()
        }
    }

    func hideWindows(matching keyPath: KeyPath<PluginWindow, String>, value: String) {
        activateLive { [self] in
            scanResult.pluginWindows
                .filter { $0[keyPath: keyPath] == value && !$0.isHidden }
                .forEach { $0.hide() }
            objectWillChange.send()
        }
    }

    func showWindows(matching keyPath: KeyPath<PluginWindow, String>, value: String) {
        activateLive { [self] in
            scanResult.pluginWindows
                .filter { $0[keyPath: keyPath] == value && $0.isHidden }
                .forEach { $0.show() }
            objectWillChange.send()
        }
    }

    func allHidden(matching keyPath: KeyPath<PluginWindow, String>, value: String) -> Bool {
        let matching = scanResult.pluginWindows.filter { $0[keyPath: keyPath] == value }
        return !matching.isEmpty && matching.allSatisfy(\.isHidden)
    }

    func closeWindows(matching keyPath: KeyPath<PluginWindow, String>, value: String) {
        activateLive { [self] in
            scanResult.pluginWindows
                .filter { $0[keyPath: keyPath] == value }
                .forEach { $0.close() }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.performScan()
            }
        }
    }

    func focus(on keyPath: KeyPath<PluginWindow, String>, value: String) {
        activateLive { [self] in
            scanResult.pluginWindows.forEach { window in
                if window[keyPath: keyPath] == value {
                    if window.isHidden { window.show() }
                } else {
                    if !window.isHidden { window.hide() }
                }
            }
            arrangeVisibleWindows()
            objectWillChange.send()
        }
    }

    func fitToScreen() {
        activateLive { [self] in
            arrangeVisibleWindows()
        }
    }

    // MARK: - Scanning

    func performScan() {
        scanResult = scanPlugins()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NotificationCenter.default.post(name: .resizeWindow, object: nil)
        }
    }

    func scanPlugins() -> PluginScanResult {
        debugLog("Scanning... AXIsProcessTrusted: \(AXIsProcessTrusted())")

        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == "Live" }) else {
            debugLog("Live not found")
            return .empty
        }
        debugLog("Found Live with PID: \(app.processIdentifier)")

        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        guard result == .success,
              let windows = windowsRef as? [AXUIElement] else {
            debugLog("Failed to get windows: \(result.rawValue)")
            return .empty
        }
        debugLog("Found \(windows.count) windows")

        let pluginWindows: [PluginWindow] = windows.compactMap { window in
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
            guard let title = titleRef as? String,
                  let slashIndex = title.firstIndex(of: "/") else { return nil }

            let pluginName = String(title[..<slashIndex])
            let trackName = String(title[title.index(after: slashIndex)...])

            // Match on the AX element so duplicate "Plugin/Track" titles keep
            // their own hidden state and original position, and so state
            // survives a track or device rename.
            let existing = scanResult.pluginWindows.first { CFEqual($0.windowElement, window) }
            let pluginWindow = PluginWindow(
                pluginName: pluginName,
                trackName: trackName,
                windowElement: window,
                originalPosition: existing?.originalPosition ?? nil,
                isHidden: existing?.isHidden ?? false
            )
            pluginWindow.originalPosition = pluginWindow.originalPosition ?? pluginWindow.position
            return pluginWindow
        }

        return PluginScanResult(pluginWindows: pluginWindows)
    }

    // MARK: - Helpers

    private func activateLive(then action: @escaping () -> Void) {
        guard let liveApp = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == "Live" }) else {
            return
        }
        liveApp.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { action() }
    }

    private func arrangeVisibleWindows() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let topY = screen.frame.height - frame.maxY
        let bottomY = screen.frame.height - frame.minY

        let visibleWindows = scanResult.pluginWindows
            .filter { !$0.isHidden }
            .sorted { $0.pluginName < $1.pluginName }
            .map { ($0, $0.size ?? CGSize(width: 400, height: 300)) }

        var currentX = frame.minX
        var passTop = topY          // top edge of the current left-to-right pass
        var currentY = passTop
        var columnWidth: CGFloat = 0
        var wrapCount = 0

        for (window, size) in visibleWindows {
            if currentY + size.height > bottomY && currentY > passTop {
                let nextX = currentX + columnWidth

                if nextX + size.width <= frame.maxX {
                    // Fits cleanly in a fresh column.
                    currentX = nextX
                } else if frame.maxX - size.width > currentX {
                    // Doesn't fit cleanly, but there's still unused width to
                    // the right. Slide it flush against the right edge so it
                    // sits fully on screen, overlapping the previous column a
                    // little, rather than wrapping on top of the first one.
                    currentX = frame.maxX - size.width
                } else {
                    // Genuinely out of room. Start a new pass at the left
                    // edge, stepped down so it doesn't land exactly on the
                    // previous pass and hide it completely.
                    wrapCount += 1
                    passTop = topY + wrapStep * CGFloat((wrapCount - 1) % wrapCycle + 1)
                    currentX = frame.minX
                }

                currentY = passTop
                columnWidth = 0
            }
            window.position = CGPoint(x: currentX, y: currentY)
            // Raise as we go, so z-order follows placement order.
            window.raise()
            currentY += size.height
            columnWidth = max(columnWidth, size.width)
        }
    }
}

// MARK: - FlowLayout

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? 780
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxRowWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if currentX + size.width > maxWidth && currentX > 0 {
                maxRowWidth = max(maxRowWidth, currentX - spacing)
                currentX = 0
                currentY += rowHeight + spacing
                rowHeight = 0
            }

            positions.append(CGPoint(x: currentX, y: currentY))
            currentX += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        maxRowWidth = max(maxRowWidth, currentX - spacing)
        let totalHeight = currentY + rowHeight
        let finalWidth = proposal.width ?? max(maxRowWidth, 0)
        return (CGSize(width: finalWidth, height: totalHeight), positions)
    }
}

// MARK: - ItemButton

struct ItemButton: View {
    let label: String
    let onSelect: () -> Void
    let isHidden: Bool
    let onToggleVisibility: () -> Void
    let onClose: () -> Void

    private let height: CGFloat = 24
    private let iconWidth: CGFloat = 24

    // `.buttonStyle(.plain)` makes the hit area the rendered content, so a bare
    // Text/Image is only clickable on the glyph itself. Padding each label out
    // to full height and stamping a `contentShape` gives every segment a hit
    // area covering its whole slice of the pill.
    var body: some View {
        HStack(spacing: 0) {
            Button(action: onSelect) {
                Text(label)
                    .font(.caption)
                    .padding(.leading, 8)
                    .padding(.trailing, 5)
                    .frame(height: height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            separator

            Button(action: onToggleVisibility) {
                Image(systemName: isHidden ? "eye" : "eye.slash")
                    .foregroundColor(.primary)
                    .frame(width: iconWidth, height: height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            separator

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .foregroundColor(.primary)
                    .frame(width: iconWidth, height: height)
                    .padding(.trailing, 3)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(height: height)
        .background(Color.gray.opacity(0.3))
        .cornerRadius(6)
        .focusEffectDisabled()
    }

    private var separator: some View {
        Text("|")
            .foregroundColor(.secondary)
            .font(.caption)
    }
}

// MARK: - ContentView

struct ContentView: View {
    @ObservedObject private var pluginManager = PluginManager.shared

    private var hasPlugins: Bool {
        !pluginManager.scanResult.pluginWindows.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if hasPlugins {
                // Track buttons
                FlowLayout(spacing: 6) {
                    ForEach(pluginManager.scanResult.tracks, id: \.self) { track in
                        ItemButton(
                            label: track,
                            onSelect: { pluginManager.focus(on: \.trackName, value: track) },
                            isHidden: pluginManager.allHidden(matching: \.trackName, value: track),
                            onToggleVisibility: {
                                if pluginManager.allHidden(matching: \.trackName, value: track) {
                                    pluginManager.showWindows(matching: \.trackName, value: track)
                                } else {
                                    pluginManager.hideWindows(matching: \.trackName, value: track)
                                }
                            },
                            onClose: { pluginManager.closeWindows(matching: \.trackName, value: track) }
                        )
                    }
                }

                Divider()

                // Plugin buttons
                FlowLayout(spacing: 6) {
                    ForEach(pluginManager.scanResult.plugins, id: \.self) { plugin in
                        ItemButton(
                            label: plugin,
                            onSelect: {
                                pluginManager.performScan()
                                pluginManager.focus(on: \.pluginName, value: plugin)
                            },
                            isHidden: pluginManager.allHidden(matching: \.pluginName, value: plugin),
                            onToggleVisibility: {
                                if pluginManager.allHidden(matching: \.pluginName, value: plugin) {
                                    pluginManager.showWindows(matching: \.pluginName, value: plugin)
                                } else {
                                    pluginManager.hideWindows(matching: \.pluginName, value: plugin)
                                }
                            },
                            onClose: { pluginManager.closeWindows(matching: \.pluginName, value: plugin) }
                        )
                    }
                }

                // Bottom links
                HStack(spacing: 16) {
                    Button("Show all") {
                        pluginManager.showAllPlugins()
                    }
                    .buttonStyle(.link)
                    .controlSize(.small)

                    Button("Hide all") {
                        pluginManager.hideAllPlugins()
                    }
                    .buttonStyle(.link)
                    .controlSize(.small)

                    Button("Arrange") {
                        pluginManager.fitToScreen()
                    }
                    .buttonStyle(.link)
                    .controlSize(.small)
                }
            }
        }
        .padding()
        .frame(minWidth: 400)
        .onAppear {
            pluginManager.performScan()
            pluginManager.startBackgroundScanning()
        }
    }
}

#Preview {
    ContentView()
}
