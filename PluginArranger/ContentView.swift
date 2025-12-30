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

struct PluginWindow {
    let plugin: String
    let track: String
    let windowElement: AXUIElement
    var originalPosition: CGPoint?
    var isHidden: Bool = false
}

struct PluginScanResult {
    var pluginWindows: [PluginWindow]

    var trackToWindows: [String: [PluginWindow]] {
        Dictionary(grouping: pluginWindows, by: { $0.track })
    }

    var pluginToWindows: [String: [PluginWindow]] {
        Dictionary(grouping: pluginWindows, by: { $0.plugin })
    }

    var tracks: [String] {
        Array(Set(pluginWindows.map { $0.track })).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    var plugins: [String] {
        Array(Set(pluginWindows.map { $0.plugin })).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    static let empty = PluginScanResult(pluginWindows: [])
}

// MARK: - PluginManager (Shared State)

class PluginManager: ObservableObject {
    @MainActor static let shared = PluginManager()

    @Published var scanResult: PluginScanResult = .empty
    @Published var outputLines: [String] = []

    private init() {}

    func restoreAllHiddenWindows() {
        for index in scanResult.pluginWindows.indices {
            if scanResult.pluginWindows[index].isHidden {
                showWindow(at: index)
            }
        }
    }

    func restoreAllHiddenWindowsSync() {
        for index in scanResult.pluginWindows.indices {
            if scanResult.pluginWindows[index].isHidden,
               let position = scanResult.pluginWindows[index].originalPosition {
                let window = scanResult.pluginWindows[index].windowElement
                setWindowPosition(window, position)
            }
        }
    }

    func showWindow(at index: Int) {
        guard let position = scanResult.pluginWindows[index].originalPosition else { return }
        let window = scanResult.pluginWindows[index].windowElement
        setWindowPosition(window, position)
        scanResult.pluginWindows[index].isHidden = false
    }

    func hideWindow(at index: Int) {
        let window = scanResult.pluginWindows[index].windowElement
        scanResult.pluginWindows[index].originalPosition = getWindowPosition(window)
        scanResult.pluginWindows[index].isHidden = true

        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.frame
        setWindowPosition(window, CGPoint(x: screenFrame.maxX, y: screenFrame.maxY))
    }

    func getWindowPosition(_ window: AXUIElement) -> CGPoint? {
        var positionRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef) == .success,
              let positionValue = positionRef else {
            return nil
        }
        var position = CGPoint.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
        return position
    }

    func setWindowPosition(_ window: AXUIElement, _ position: CGPoint) {
        var pos = position
        let positionValue = AXValueCreate(.cgPoint, &pos)!
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
    }

    func setWindowSize(_ window: AXUIElement, _ size: CGSize) {
        var s = size
        let sizeValue = AXValueCreate(.cgSize, &s)!
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
    }

    func getWindowSize(_ window: AXUIElement) -> CGSize? {
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let sizeValue = sizeRef else {
            return nil
        }
        var size = CGSize.zero
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return size
    }

    // MARK: - Actions

    func activateLive(then action: @escaping (NSRunningApplication) -> Void) {
        let runningApps = NSWorkspace.shared.runningApplications
        guard let liveApp = runningApps.first(where: {
            $0.localizedName == "Live"
        }) else {
            outputLines = ["Ableton Live not found"]
            return
        }

        liveApp.activate()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            action(liveApp)
        }
    }

    func performScan() {
        activateLive { [self] _ in
            let (output, result) = scanPlugins(named: "Live")

            // Don't update if no plugins found
            guard !result.pluginWindows.isEmpty else {
                outputLines = ["No plugins found, keeping current list"]
                return
            }

            scanResult = result
            outputLines = output

            // Resize window to fit new content (delay to let SwiftUI update)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NotificationCenter.default.post(name: .resizeWindow, object: nil)
            }
        }
    }

    func scanPlugins(named appName: String) -> (output: [String], result: PluginScanResult) {
        let runningApps = NSWorkspace.shared.runningApplications
        guard let app = runningApps.first(where: {
            $0.localizedName == "Live"
        }) else {
            return (["Ableton Live not found"], .empty)
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            return (["Could not get windows"], .empty)
        }

        var pluginWindows: [PluginWindow] = []
        var debugInfo: [String] = []

        debugInfo.append("Found \(windows.count) windows")

        for (windowIndex, window) in windows.enumerated() {
            var windowTitleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &windowTitleRef)
            let windowTitle = (windowTitleRef as? String) ?? "(no title)"

            debugInfo.append("Window \(windowIndex + 1): '\(windowTitle)'")

            if windowTitle.contains("/") {
                let parts = windowTitle.split(separator: "/", maxSplits: 1)
                if parts.count == 2 {
                    let plugin = String(parts[0])
                    let track = String(parts[1])

                    // Check if this window is already being tracked
                    if let existing = scanResult.pluginWindows.first(where: { $0.plugin == plugin && $0.track == track }) {
                        // Preserve original position and hidden state
                        pluginWindows.append(PluginWindow(
                            plugin: plugin,
                            track: track,
                            windowElement: window,
                            originalPosition: existing.originalPosition,
                            isHidden: existing.isHidden
                        ))
                    } else {
                        // New window - capture current position
                        let position = getWindowPosition(window)
                        pluginWindows.append(PluginWindow(
                            plugin: plugin,
                            track: track,
                            windowElement: window,
                            originalPosition: position,
                            isHidden: false
                        ))
                    }
                }
            }
        }

        let result = PluginScanResult(pluginWindows: pluginWindows)

        if pluginWindows.isEmpty {
            return (debugInfo + ["", "No plugins found (no titles matching 'plugin/track' format)"], result)
        }

        var output: [String] = []
        output.append("=== Track → Plugins ===")
        for track in result.tracks {
            let plugins = result.trackToWindows[track]!.map { $0.plugin }.joined(separator: ", ")
            output.append("\(track): [\(plugins)]")
        }
        output.append("")
        output.append("=== Plugin → Tracks ===")
        for plugin in result.plugins {
            let tracks = result.pluginToWindows[plugin]!.map { $0.track }.joined(separator: ", ")
            output.append("\(plugin): [\(tracks)]")
        }

        return (output, result)
    }

    func focusOnTrack(_ keepTrack: String) {
        activateLive { [self] _ in
            var hiddenCount = 0
            var shownCount = 0

            for index in scanResult.pluginWindows.indices {
                if scanResult.pluginWindows[index].track == keepTrack {
                    if scanResult.pluginWindows[index].isHidden {
                        showWindow(at: index)
                        shownCount += 1
                    }
                } else {
                    if !scanResult.pluginWindows[index].isHidden {
                        hideWindow(at: index)
                        hiddenCount += 1
                    }
                }
            }

            arrangeVisibleWindows()
            outputLines = ["Showing '\(keepTrack)': hid \(hiddenCount), restored \(shownCount)"]
        }
    }

    func showAllPlugins() {
        activateLive { [self] _ in
            var shownCount = 0

            for index in scanResult.pluginWindows.indices {
                if scanResult.pluginWindows[index].isHidden {
                    showWindow(at: index)
                    shownCount += 1
                }
            }

            outputLines = ["Restored \(shownCount) plugin window(s)"]
        }
    }

    func hideAllPlugins() {
        activateLive { [self] _ in
            var hiddenCount = 0

            for index in scanResult.pluginWindows.indices {
                if !scanResult.pluginWindows[index].isHidden {
                    hideWindow(at: index)
                    hiddenCount += 1
                }
            }

            outputLines = ["Hid \(hiddenCount) plugin window(s)"]
        }
    }

    func hideTrack(_ track: String) {
        activateLive { [self] _ in
            var hiddenCount = 0

            for index in scanResult.pluginWindows.indices {
                if scanResult.pluginWindows[index].track == track && !scanResult.pluginWindows[index].isHidden {
                    hideWindow(at: index)
                    hiddenCount += 1
                }
            }

            outputLines = ["Hid \(hiddenCount) plugin(s) on '\(track)'"]
        }
    }

    func hidePlugin(_ plugin: String) {
        activateLive { [self] _ in
            var hiddenCount = 0

            for index in scanResult.pluginWindows.indices {
                if scanResult.pluginWindows[index].plugin == plugin && !scanResult.pluginWindows[index].isHidden {
                    hideWindow(at: index)
                    hiddenCount += 1
                }
            }

            outputLines = ["Hid \(hiddenCount) '\(plugin)' window(s)"]
        }
    }

    func closePlugin(_ plugin: String) {
        activateLive { [self] _ in
            var closedCount = 0

            for index in scanResult.pluginWindows.indices {
                if scanResult.pluginWindows[index].plugin == plugin {
                    let window = scanResult.pluginWindows[index].windowElement
                    if closeWindow(window) {
                        closedCount += 1
                    }
                }
            }

            outputLines = ["Closed \(closedCount) '\(plugin)' window(s)"]

            // Refresh and resize
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.performScan()
            }
        }
    }

    func closeTrack(_ track: String) {
        activateLive { [self] _ in
            var closedCount = 0

            for index in scanResult.pluginWindows.indices {
                if scanResult.pluginWindows[index].track == track {
                    let window = scanResult.pluginWindows[index].windowElement
                    if closeWindow(window) {
                        closedCount += 1
                    }
                }
            }

            outputLines = ["Closed \(closedCount) plugin(s) on '\(track)'"]

            // Refresh and resize
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.performScan()
            }
        }
    }

    func closeWindow(_ window: AXUIElement) -> Bool {
        // Get the close button and press it
        var closeButtonRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &closeButtonRef) == .success,
              let closeButton = closeButtonRef else {
            return false
        }
        let result = AXUIElementPerformAction(closeButton as! AXUIElement, kAXPressAction as CFString)
        return result == .success
    }

    func focusOnPlugin(_ keepPlugin: String) {
        activateLive { [self] _ in
            var hiddenCount = 0
            var shownCount = 0

            for index in scanResult.pluginWindows.indices {
                if scanResult.pluginWindows[index].plugin == keepPlugin {
                    if scanResult.pluginWindows[index].isHidden {
                        showWindow(at: index)
                        shownCount += 1
                    }
                } else {
                    if !scanResult.pluginWindows[index].isHidden {
                        hideWindow(at: index)
                        hiddenCount += 1
                    }
                }
            }

            arrangeVisibleWindows()
            outputLines = ["Showing '\(keepPlugin)': hid \(hiddenCount), restored \(shownCount)"]
        }
    }

    func arrangeVisibleWindows() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame

        let topY = screen.frame.height - frame.maxY
        let bottomY = screen.frame.height - frame.minY

        // Get visible windows sorted by plugin name
        let visibleIndices = scanResult.pluginWindows.indices
            .filter { !scanResult.pluginWindows[$0].isHidden }
            .sorted { scanResult.pluginWindows[$0].plugin < scanResult.pluginWindows[$1].plugin }

        var windowSizes: [(index: Int, size: CGSize)] = []
        for windowIndex in visibleIndices {
            let window = scanResult.pluginWindows[windowIndex].windowElement
            let size = getWindowSize(window) ?? CGSize(width: 400, height: 300)
            windowSizes.append((windowIndex, size))
        }

        var currentX: CGFloat = frame.minX
        var currentY: CGFloat = topY
        var columnWidth: CGFloat = 0

        for (windowIndex, size) in windowSizes {
            if currentY + size.height > bottomY && currentY > topY {
                currentX += columnWidth
                currentY = topY
                columnWidth = 0

                if currentX + size.width > frame.maxX {
                    currentX = frame.minX
                    currentY = topY
                }
            }

            let window = scanResult.pluginWindows[windowIndex].windowElement
            setWindowPosition(window, CGPoint(x: currentX, y: currentY))

            currentY += size.height
            columnWidth = max(columnWidth, size.width)
        }
    }

    func fitToScreen() {
        activateLive { [self] _ in
            let visibleCount = scanResult.pluginWindows.filter { !$0.isHidden }.count
            guard visibleCount > 0 else {
                outputLines = ["No visible windows to arrange"]
                return
            }
            arrangeVisibleWindows()
            outputLines = ["Arranged \(visibleCount) window(s)"]
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
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += rowHeight + spacing
                rowHeight = 0
            }

            positions.append(CGPoint(x: currentX, y: currentY))
            currentX += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        let totalHeight = currentY + rowHeight
        return (CGSize(width: maxWidth, height: totalHeight), positions)
    }
}

// MARK: - ItemButton

struct ItemButton: View {
    let label: String
    let onSelect: () -> Void
    let onHide: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(label) {
                onSelect()
            }
            .buttonStyle(.plain)
            .font(.caption)

            Text("|")
                .foregroundColor(.secondary)
                .font(.caption)
                .padding(.horizontal, 3)

            Button {
                onHide()
            } label: {
                Image(systemName: "eye.slash")
                    .foregroundColor(.primary)
            }
            .buttonStyle(.plain)

            Text("|")
                .foregroundColor(.secondary)
                .font(.caption)
                .padding(.horizontal, 3)

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.primary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.gray.opacity(0.3))
        .cornerRadius(6)
    }
}

// MARK: - ContentView

struct ContentView: View {
    @ObservedObject private var pluginManager = PluginManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Track buttons
            FlowLayout(spacing: 6) {
                ForEach(pluginManager.scanResult.tracks, id: \.self) { track in
                    ItemButton(
                        label: track,
                        onSelect: { pluginManager.focusOnTrack(track) },
                        onHide: { pluginManager.hideTrack(track) },
                        onClose: { pluginManager.closeTrack(track) }
                    )
                }
            }

            // Plugin buttons
            FlowLayout(spacing: 6) {
                ForEach(pluginManager.scanResult.plugins, id: \.self) { plugin in
                    ItemButton(
                        label: plugin,
                        onSelect: {
                            pluginManager.performScan()
                            pluginManager.focusOnPlugin(plugin)
                        },
                        onHide: { pluginManager.hidePlugin(plugin) },
                        onClose: { pluginManager.closePlugin(plugin) }
                    )
                }
            }

            // Bottom links
            HStack(spacing: 16) {
                Button("Refresh") {
                    pluginManager.performScan()
                }
                .buttonStyle(.link)
                .controlSize(.small)

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
        .padding()
        .frame(width: 400)
        .onAppear {
            if AXIsProcessTrusted() {
                pluginManager.performScan()
            }
        }
    }
}

#Preview {
    ContentView()
}
