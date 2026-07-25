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

    static func == (lhs: PluginWindow, rhs: PluginWindow) -> Bool {
        lhs.pluginName == rhs.pluginName && lhs.trackName == rhs.trackName
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

    func show() {
        position = originalPosition
        isHidden = false
    }

    func hide() {
        originalPosition = position
        isHidden = true
        guard let screen = NSScreen.main else { return }
        position = CGPoint(x: screen.frame.maxX, y: screen.frame.maxY)
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
            scanResult.pluginWindows.filter(\.isHidden).forEach { $0.show() }
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

            let existing = scanResult.pluginWindows.first { $0.pluginName == pluginName && $0.trackName == trackName }
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
        var currentY = topY
        var columnWidth: CGFloat = 0

        for (window, size) in visibleWindows {
            if currentY + size.height > bottomY && currentY > topY {
                currentX += columnWidth
                currentY = topY
                columnWidth = 0
                if currentX + size.width > frame.maxX {
                    currentX = frame.minX
                    currentY = topY
                }
            }
            window.position = CGPoint(x: currentX, y: currentY)
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
                onToggleVisibility()
            } label: {
                Image(systemName: isHidden ? "eye" : "eye.slash")
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
                Image(systemName: "xmark")
                    .foregroundColor(.primary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(Color.gray.opacity(0.3))
        .cornerRadius(6)
        .focusEffectDisabled()
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
