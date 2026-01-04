//
//  PluginArrangerApp.swift
//  PluginArranger
//
//  Created by Aiden Elliott on 12/22/25.
//

import SwiftUI
import AppKit

// MARK: - Debug Logging

final class DebugLog {
    static let shared = DebugLog()
    private let path = "/tmp/pluginarranger.log"
    private var handle: FileHandle?
    private let formatter = ISO8601DateFormatter()

    private init() {}

    func start() {
        try? FileManager.default.removeItem(atPath: path)
        FileManager.default.createFile(atPath: path, contents: nil)
        handle = FileHandle(forWritingAtPath: path)
    }

    func log(_ message: String) {
        guard let handle = handle,
              let data = "[\(formatter.string(from: Date()))] \(message)\n".data(using: .utf8)
        else { return }
        handle.write(data)
    }
}

func debugLog(_ message: String) {
    DebugLog.shared.log(message)
}

@main
struct PluginArrangerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem?
    var statusMenu: NSMenu?
    var panel: NSPanel?
    var hostingView: NSHostingView<ContentView>?
    var clickMonitor: Any?

    private let defaultWidth: CGFloat = 780
    private let widthKey = "dockedWindowWidth"
    private var isResizing = false

    var storedWidth: CGFloat {
        get {
            let width = UserDefaults.standard.double(forKey: widthKey)
            return width > 0 ? width : defaultWidth
        }
        set {
            UserDefaults.standard.set(newValue, forKey: widthKey)
        }
    }

    func resizeWindowToFit() {
        guard let hostingView = hostingView, let panel = panel, let screen = NSScreen.main else {
            return
        }

        // Force layout update before getting size
        hostingView.layoutSubtreeIfNeeded()
        let fittingSize = hostingView.fittingSize

        // Calculate frame anchored to bottom-left of screen
        let newFrame = NSRect(
            x: screen.visibleFrame.minX,
            y: 0,
            width: storedWidth,
            height: fittingSize.height
        )
        panel.setFrame(newFrame, display: true)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DebugLog.shared.start()
        debugLog("App launched")

        setupMenuBar()
        setupPanel()
        setupClickMonitor()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleResizeNotification),
            name: .resizeWindow,
            object: nil
        )
    }

    @objc func handleResizeNotification() {
        resizeWindowToFit()
    }

    func setupClickMonitor() {
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self = self, let panel = self.panel else { return event }

            if event.window == panel {
                PluginManager.shared.performScan()
            }
            return event
        }
    }

    func setupPanel() {
        let panel = NonActivatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: storedWidth, height: 150),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.isMovable = false
        panel.minSize = NSSize(width: 400, height: 50)

        let hostingView = NSHostingView(rootView: ContentView())
        self.hostingView = hostingView
        panel.contentView = hostingView

        // Set initial size and position at lower left of screen
        if let screen = NSScreen.main {
            let newFrame = NSRect(
                x: screen.visibleFrame.minX,
                y: 0,
                width: storedWidth,
                height: hostingView.fittingSize.height
            )
            panel.setFrame(newFrame, display: false)
        }

        panel.orderFront(nil)
        self.panel = panel

        // Observe resize to store width
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResize),
            name: NSWindow.didResizeNotification,
            object: panel
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidEndLiveResize),
            name: NSWindow.didEndLiveResizeNotification,
            object: panel
        )
    }

    @objc func windowDidResize(_ notification: Notification) {
        guard let panel = panel, !isResizing else { return }
        storedWidth = panel.frame.width

        // Keep window anchored to bottom of screen
        if panel.frame.origin.y != 0 {
            isResizing = true
            var frame = panel.frame
            frame.origin.y = 0
            panel.setFrame(frame, display: true)
            isResizing = false
        }
    }

    @objc func windowDidEndLiveResize(_ notification: Notification) {
        guard !isResizing else { return }
        isResizing = true
        DispatchQueue.main.async { [weak self] in
            self?.resizeWindowToFit()
            self?.isResizing = false
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        PluginManager.shared.restoreAllHiddenWindows()
    }

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: "PluginArranger")
        }

        statusMenu = NSMenu()
        statusMenu?.delegate = self
        statusItem?.menu = statusMenu
    }

    func menuWillOpen(_ menu: NSMenu) {
        // Run scan before menu opens
        let result = PluginManager.shared.scanPlugins()
        if !result.pluginWindows.isEmpty {
            PluginManager.shared.scanResult = result
        }

        // Rebuild menu
        menu.removeAllItems()

        menu.addItem(NSMenuItem(title: "Refresh", action: #selector(scanPlugins), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Show All", action: #selector(showAllPlugins), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Hide All", action: #selector(hideAllPlugins), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Arrange", action: #selector(fitToScreen), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())

        // Tracks
        for track in PluginManager.shared.scanResult.tracks {
            let item = NSMenuItem(title: track, action: #selector(focusOnTrack(_:)), keyEquivalent: "")
            item.representedObject = track
            menu.addItem(item)
        }

        if !PluginManager.shared.scanResult.tracks.isEmpty {
            menu.addItem(NSMenuItem.separator())
        }

        // Plugins
        for plugin in PluginManager.shared.scanResult.plugins {
            let item = NSMenuItem(title: plugin, action: #selector(focusOnPlugin(_:)), keyEquivalent: "")
            item.representedObject = plugin
            menu.addItem(item)
        }

        if !PluginManager.shared.scanResult.plugins.isEmpty {
            menu.addItem(NSMenuItem.separator())
        }

        let windowTitle = panel?.isVisible == true ? "Hide docked window" : "Show docked window"
        menu.addItem(NSMenuItem(title: windowTitle, action: #selector(toggleDockedWindow), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
    }

    @objc func scanPlugins() {
        PluginManager.shared.performScan()
    }

    @objc func showAllPlugins() {
        PluginManager.shared.showAllPlugins()
    }

    @objc func hideAllPlugins() {
        PluginManager.shared.hideAllPlugins()
    }

    @objc func focusOnPlugin(_ sender: NSMenuItem) {
        if let plugin = sender.representedObject as? String {
            PluginManager.shared.focus(on: \.pluginName, value: plugin)
        }
    }

    @objc func focusOnTrack(_ sender: NSMenuItem) {
        if let track = sender.representedObject as? String {
            PluginManager.shared.focus(on: \.trackName, value: track)
        }
    }

    @objc func fitToScreen() {
        PluginManager.shared.fitToScreen()
    }

    @objc func toggleDockedWindow() {
        guard let panel = panel else { return }

        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.orderFront(nil)
            PluginManager.shared.performScan()
        }
    }

    @objc func quit() {
        NSApplication.shared.terminate(nil)
    }
}
