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

class PluginWindow {
    let plugin: String
    let track: String
    let windowElement: AXUIElement
    var originalPosition: CGPoint?
    var isHidden: Bool = false

    init(plugin: String, track: String, windowElement: AXUIElement, originalPosition: CGPoint? = nil, isHidden: Bool = false) {
        self.plugin = plugin
        self.track = track
        self.windowElement = windowElement
        self.originalPosition = originalPosition
        self.isHidden = isHidden
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
            guard var pos = newValue else { return }
            let positionValue = AXValueCreate(.cgPoint, &pos)!
            AXUIElementSetAttributeValue(windowElement, kAXPositionAttribute as CFString, positionValue)
        }
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

    func close() {
        var closeButtonRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(windowElement, kAXCloseButtonAttribute as CFString, &closeButtonRef) == .success,
              let closeButton = closeButtonRef else { return }
        AXUIElementPerformAction(closeButton as! AXUIElement, kAXPressAction as CFString)
    }
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

    private init() {}

    func restoreAllHiddenWindows() {
        scanResult.pluginWindows
            .filter { $0.isHidden }
            .forEach { showWindow($0) }
    }

    func restoreAllHiddenWindowsSync() {
        scanResult.pluginWindows
            .filter { $0.isHidden && $0.originalPosition != nil }
            .forEach { $0.position = $0.originalPosition }
    }

    func showWindow(_ pluginWindow: PluginWindow) {
        pluginWindow.position = pluginWindow.originalPosition
        pluginWindow.isHidden = false
    }

    func hideWindow(_ pluginWindow: PluginWindow) {
        pluginWindow.originalPosition = pluginWindow.position
        pluginWindow.isHidden = true

        guard let screen = NSScreen.main else { return }
        pluginWindow.position = CGPoint(x: screen.frame.maxX, y: screen.frame.maxY)
    }

    // MARK: - Actions

    func activateLive(then action: @escaping (NSRunningApplication) -> Void) {
        let runningApps = NSWorkspace.shared.runningApplications
        guard let liveApp = runningApps.first(where: {
            $0.localizedName == "Live"
        }) else {
            return
        }

        liveApp.activate()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            action(liveApp)
        }
    }

    func performScan() {
        activateLive { [self] _ in
            let result = scanPlugins()
            guard !result.pluginWindows.isEmpty else { return }
            scanResult = result

            // Resize window to fit new content (delay to let SwiftUI update)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NotificationCenter.default.post(name: .resizeWindow, object: nil)
            }
        }
    }

    func scanPlugins() -> PluginScanResult {
        let runningApps = NSWorkspace.shared.runningApplications
        guard let app = runningApps.first(where: { $0.localizedName == "Live" }) else {
            return .empty
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            return .empty
        }

        let pluginWindows: [PluginWindow] = windows.compactMap { window in
            var windowTitleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &windowTitleRef)
            guard let windowTitle = windowTitleRef as? String,
                  windowTitle.contains("/") else { return nil }

            let parts = windowTitle.split(separator: "/", maxSplits: 1)
            guard parts.count == 2 else { return nil }

            let plugin = String(parts[0])
            let track = String(parts[1])

            let existing = scanResult.pluginWindows.first { $0.plugin == plugin && $0.track == track }
            let pluginWindow = PluginWindow(
                plugin: plugin,
                track: track,
                windowElement: window,
                originalPosition: existing?.originalPosition,
                isHidden: existing?.isHidden ?? false
            )
            if pluginWindow.originalPosition == nil {
                pluginWindow.originalPosition = pluginWindow.position
            }
            return pluginWindow
        }

        return PluginScanResult(pluginWindows: pluginWindows)
    }

    func focusOnTrack(_ keepTrack: String) {
        activateLive { [self] _ in
            scanResult.pluginWindows
                .filter { $0.track == keepTrack && $0.isHidden }
                .forEach { showWindow($0) }
            scanResult.pluginWindows
                .filter { $0.track != keepTrack && !$0.isHidden }
                .forEach { hideWindow($0) }
            arrangeVisibleWindows()
        }
    }

    func showAllPlugins() {
        activateLive { [self] _ in
            scanResult.pluginWindows
                .filter { $0.isHidden }
                .forEach { showWindow($0) }
        }
    }

    func hideAllPlugins() {
        activateLive { [self] _ in
            scanResult.pluginWindows
                .filter { !$0.isHidden }
                .forEach { hideWindow($0) }
        }
    }

    func hideWindowsOnTrack(_ track: String) {
        activateLive { [self] _ in
            scanResult.pluginWindows
                .filter { $0.track == track && !$0.isHidden }
                .forEach { hideWindow($0) }
        }
    }

    func hidePluginsMatchingName(_ plugin: String) {
        activateLive { [self] _ in
            scanResult.pluginWindows
                .filter { $0.plugin == plugin && !$0.isHidden }
                .forEach { hideWindow($0) }
        }
    }

    func closePluginsMatchingName(_ plugin: String) {
        activateLive { [self] _ in
            scanResult.pluginWindows
                .filter { $0.plugin == plugin }
                .forEach { $0.close() }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.performScan()
            }
        }
    }

    func closeWindowsOnTrack(_ track: String) {
        activateLive { [self] _ in
            scanResult.pluginWindows
                .filter { $0.track == track }
                .forEach { $0.close() }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.performScan()
            }
        }
    }

    func focusOnPlugin(_ keepPlugin: String) {
        activateLive { [self] _ in
            scanResult.pluginWindows
                .filter { $0.plugin == keepPlugin && $0.isHidden }
                .forEach { showWindow($0) }
            scanResult.pluginWindows
                .filter { $0.plugin != keepPlugin && !$0.isHidden }
                .forEach { hideWindow($0) }
            arrangeVisibleWindows()
        }
    }

    func arrangeVisibleWindows() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame

        let topY = screen.frame.height - frame.maxY
        let bottomY = screen.frame.height - frame.minY

        let visibleWindows = scanResult.pluginWindows
            .filter { !$0.isHidden }
            .sorted { $0.plugin < $1.plugin }
            .map { ($0, $0.size ?? CGSize(width: 400, height: 300)) }

        var currentX: CGFloat = frame.minX
        var currentY: CGFloat = topY
        var columnWidth: CGFloat = 0

        for (pluginWindow, size) in visibleWindows {
            if currentY + size.height > bottomY && currentY > topY {
                currentX += columnWidth
                currentY = topY
                columnWidth = 0

                if currentX + size.width > frame.maxX {
                    currentX = frame.minX
                    currentY = topY
                }
            }

            pluginWindow.position = CGPoint(x: currentX, y: currentY)

            currentY += size.height
            columnWidth = max(columnWidth, size.width)
        }
    }

    func fitToScreen() {
        activateLive { [self] _ in
            arrangeVisibleWindows()
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
                        onHide: { pluginManager.hideWindowsOnTrack(track) },
                        onClose: { pluginManager.closeWindowsOnTrack(track) }
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
                        onHide: { pluginManager.hidePluginsMatchingName(plugin) },
                        onClose: { pluginManager.closePluginsMatchingName(plugin) }
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
