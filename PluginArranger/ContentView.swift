//
//  ContentView.swift
//  PluginArranger
//
//  Created by Aiden Elliott on 12/22/25.
//

import SwiftUI
import ApplicationServices
import Combine

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
        Array(Set(pluginWindows.map { $0.track })).sorted()
    }

    var plugins: [String] {
        Array(Set(pluginWindows.map { $0.plugin })).sorted()
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
        AXUIElementSetAttributeValue(window, kAXPositionAttribute a s CFString, positionValue)
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
}

// MARK: - ContentView

struct ContentView: View {
    @ObservedObject private var pluginManager = PluginManager.shared
    @State private var hasAccessibilityPermission = false

    var body: some View {
        VStack(spacing: 16) {
            if !hasAccessibilityPermission {
                Text("Accessibility permission required")
                    .foregroundStyle(.secondary)
                Button("Open Accessibility Settings") {
                    openAccessibilitySettings()
                }
                Button("Check Permission") {
                    hasAccessibilityPermission = AXIsProcessTrusted()
                }
            } else {
                Button("Scan Live Plugins") {
                    performScan()
                }

                if !pluginManager.scanResult.tracks.isEmpty {
                    Text("Focus on track:")
                        .font(.headline)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(pluginManager.scanResult.tracks, id: \.self) { track in
                                Button(track) {
                                    focusOnTrack(track)
                                }
                                .buttonStyle(.bordered)
                            }
                            Button("Show All") {
                                showAllPlugins()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }

                    Text("Focus on plugin:")
                        .font(.headline)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(pluginManager.scanResult.plugins, id: \.self) { plugin in
                                Button(plugin) {
                                    focusOnPlugin(plugin)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }

                    Button("Fit to Screen") {
                        fitToScreen()
                    }
                    .buttonStyle(.borderedProminent)
                }

                if !pluginManager.outputLines.isEmpty {
                    List(pluginManager.outputLines, id: \.self) { line in
                        Text(line)
                            .font(.system(.body, design: .monospaced))
                    }
                }
            }
        }
        .padding()
        .frame(minWidth: 500, minHeight: 400)
        .onAppear {
            hasAccessibilityPermission = AXIsProcessTrusted()
            if hasAccessibilityPermission {
                performScan()
            }
        }
    }

    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    func activateLive(then action: @escaping (NSRunningApplication) -> Void) {
        let runningApps = NSWorkspace.shared.runningApplications
        guard let liveApp = runningApps.first(where: {
            $0.localizedName?.contains("Live") == true
        }) else {
            pluginManager.outputLines = ["App 'Live' not found"]
            return
        }

        liveApp.activate()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            action(liveApp)
        }
    }

    func activatePluginArranger() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    func activateLiveAndRun(action: @escaping () -> [String]) {
        activateLive { _ in
            let results = action()
            pluginManager.outputLines = results
            activatePluginArranger()
        }
    }

    func performScan() {
        activateLiveAndRun {
            let (output, result) = scanPlugins(named: "Live")
            pluginManager.scanResult = result
            return output
        }
    }

    func scanPlugins(named appName: String) -> (output: [String], result: PluginScanResult) {
        let runningApps = NSWorkspace.shared.runningApplications
        guard let app = runningApps.first(where: {
            $0.localizedName?.contains(appName) == true
        }) else {
            return (["App '\(appName)' not found"], .empty)
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        // Get all windows
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            return (["Could not get windows"], .empty)
        }

        // Collect all plugin windows
        var pluginWindows: [PluginWindow] = []
        var debugInfo: [String] = []

        debugInfo.append("Found \(windows.count) windows")

        for (windowIndex, window) in windows.enumerated() {
            // Get window title
            var windowTitleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &windowTitleRef)
            let windowTitle = (windowTitleRef as? String) ?? "(no title)"

            debugInfo.append("Window \(windowIndex + 1): '\(windowTitle)'")

            // Check if window title matches plugin/track format
            if windowTitle.contains("/") {
                let parts = windowTitle.split(separator: "/", maxSplits: 1)
                if parts.count == 2 {
                    let plugin = String(parts[0])
                    let track = String(parts[1])
                    let position = pluginManager.getWindowPosition(window)
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

        let result = PluginScanResult(pluginWindows: pluginWindows)

        if pluginWindows.isEmpty {
            return (debugInfo + ["", "No plugins found (no titles matching 'plugin/track' format)"], result)
        }

        // Format output using the result's computed properties
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
        activateLive { _ in
            var hiddenCount = 0
            var shownCount = 0

            for index in pluginManager.scanResult.pluginWindows.indices {
                if pluginManager.scanResult.pluginWindows[index].track == keepTrack {
                    if pluginManager.scanResult.pluginWindows[index].isHidden {
                        pluginManager.showWindow(at: index)
                        shownCount += 1
                    }
                } else {
                    if !pluginManager.scanResult.pluginWindows[index].isHidden {
                        pluginManager.hideWindow(at: index)
                        hiddenCount += 1
                    }
                }
            }

            pluginManager.outputLines = ["Showing '\(keepTrack)': hid \(hiddenCount), restored \(shownCount)"]
        }
    }

    func showAllPlugins() {
        activateLive { _ in
            var shownCount = 0

            for index in pluginManager.scanResult.pluginWindows.indices {
                if pluginManager.scanResult.pluginWindows[index].isHidden {
                    pluginManager.showWindow(at: index)
                    shownCount += 1
                }
            }

            pluginManager.outputLines = ["Restored \(shownCount) plugin window(s)"]
        }
    }

    func focusOnPlugin(_ keepPlugin: String) {
        activateLive { _ in
            var hiddenCount = 0
            var shownCount = 0

            for index in pluginManager.scanResult.pluginWindows.indices {
                if pluginManager.scanResult.pluginWindows[index].plugin == keepPlugin {
                    if pluginManager.scanResult.pluginWindows[index].isHidden {
                        pluginManager.showWindow(at: index)
                        shownCount += 1
                    }
                } else {
                    if !pluginManager.scanResult.pluginWindows[index].isHidden {
                        pluginManager.hideWindow(at: index)
                        hiddenCount += 1
                    }
                }
            }

            // Fit visible windows to screen
            arrangeVisibleWindows()

            pluginManager.outputLines = ["Showing '\(keepPlugin)': hid \(hiddenCount), restored \(shownCount)"]
        }
    }

    func arrangeVisibleWindows() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame

        let topY = screen.frame.height - frame.maxY
        let bottomY = screen.frame.height - frame.minY

        let visibleIndices = pluginManager.scanResult.pluginWindows.indices.filter {
            !pluginManager.scanResult.pluginWindows[$0].isHidden
        }

        var windowSizes: [(index: Int, size: CGSize)] = []
        for windowIndex in visibleIndices {
            let window = pluginManager.scanResult.pluginWindows[windowIndex].windowElement
            let size = pluginManager.getWindowSize(window) ?? CGSize(width: 400, height: 300)
            windowSizes.append((windowIndex, size))
        }

        var currentX: CGFloat = frame.minX
        var currentY: CGFloat = topY
        var columnWidth: CGFloat = 0

        for (windowIndex, size) in windowSizes {
            // Check if window fits vertically
            if currentY + size.height > bottomY && currentY > topY {
                // Move to next column
                currentX += columnWidth
                currentY = topY
                columnWidth = 0

                // If new column would exceed screen width, wrap to top-left
                if currentX + size.width > frame.maxX {
                    currentX = frame.minX
                    currentY = topY
                }
            }

            let window = pluginManager.scanResult.pluginWindows[windowIndex].windowElement
            pluginManager.setWindowPosition(window, CGPoint(x: currentX, y: currentY))

            currentY += size.height
            columnWidth = max(columnWidth, size.width)
        }
    }

    func fitToScreen() {
        activateLive { _ in
            let visibleCount = pluginManager.scanResult.pluginWindows.filter { !$0.isHidden }.count
            guard visibleCount > 0 else {
                pluginManager.outputLines = ["No visible windows to arrange"]
                return
            }
            arrangeVisibleWindows()
            pluginManager.outputLines = ["Arranged \(visibleCount) window(s)"]
        }
    }
}

#Preview {
    ContentView()
}
