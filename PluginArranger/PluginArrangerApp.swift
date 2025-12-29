//
//  PluginArrangerApp.swift
//  PluginArranger
//
//  Created by Aiden Elliott on 12/22/25.
//

import SwiftUI
import AppKit

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

    func resizeWindowToFit() {
        guard let hostingView = hostingView, let panel = panel, let screen = NSScreen.main else {
            print("DEBUG resize: guard failed")
            return
        }

        // Force layout update before getting size
        hostingView.layoutSubtreeIfNeeded()
        let contentSize = hostingView.fittingSize
        print("DEBUG resize: contentSize = \(contentSize)")

        // Calculate frame size (content + title bar)
        let titleBarHeight = panel.frame.height - panel.contentLayoutRect.height
        let frameSize = NSSize(width: contentSize.width, height: contentSize.height + titleBarHeight)
        print("DEBUG resize: frameSize = \(frameSize)")

        // Calculate origin to keep at lower left
        let screenFrame = screen.visibleFrame
        let newOrigin = NSPoint(x: screenFrame.minX, y: screenFrame.minY)
        print("DEBUG resize: newOrigin = \(newOrigin)")

        // Set frame with correct size and position
        panel.setFrame(NSRect(origin: newOrigin, size: frameSize), display: true, animate: false)
        print("DEBUG resize: frame set to \(panel.frame)")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        print("DEBUG: resize notification received")
        resizeWindowToFit()
    }

    func setupClickMonitor() {
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self = self, let panel = self.panel else { return event }

            // Check if click is in our panel
            if event.window == panel {
                print("DEBUG: Click in panel detected")
                PluginManager.shared.performScan()
            }
            return event
        }
    }

    func setupPanel() {
        let panel = NonActivatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 150),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        let hostingView = NSHostingView(rootView: ContentView())
        self.hostingView = hostingView
        let size = hostingView.fittingSize
        panel.setContentSize(size)
        panel.contentView = hostingView

        // Position at lower left corner (with small margin)
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: screenFrame.minX, y: screenFrame.minY))
        }

        panel.orderFront(nil)

        self.panel = panel
    }

    func applicationWillTerminate(_ notification: Notification) {
        PluginManager.shared.restoreAllHiddenWindowsSync()
    }

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "PluginArranger")
        }

        statusMenu = NSMenu()
        statusMenu?.delegate = self
        statusItem?.menu = statusMenu
    }

    func menuWillOpen(_ menu: NSMenu) {
        // Run scan before menu opens
        let (_, result) = PluginManager.shared.scanPlugins(named: "Live")
        PluginManager.shared.scanResult = result

        // Rebuild menu
        menu.removeAllItems()

        menu.addItem(NSMenuItem(title: "Scan Plugins", action: #selector(scanPlugins), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Show All", action: #selector(showAllPlugins), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())

        // Plugins
        for plugin in PluginManager.shared.scanResult.plugins {
            let item = NSMenuItem(title: plugin, action: #selector(focusOnPlugin(_:)), keyEquivalent: "")
            item.representedObject = plugin
            menu.addItem(item)
        }

        if !PluginManager.shared.scanResult.plugins.isEmpty {
            menu.addItem(NSMenuItem.separator())
        }

        // Tracks
        for track in PluginManager.shared.scanResult.tracks {
            let item = NSMenuItem(title: track, action: #selector(focusOnTrack(_:)), keyEquivalent: "")
            item.representedObject = track
            menu.addItem(item)
        }

        if !PluginManager.shared.scanResult.tracks.isEmpty {
            menu.addItem(NSMenuItem.separator())
        }

        menu.addItem(NSMenuItem(title: "Fit to Screen", action: #selector(fitToScreen), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
    }

    @objc func scanPlugins() {
        PluginManager.shared.performScan()
    }

    @objc func showAllPlugins() {
        PluginManager.shared.showAllPlugins()
    }

    @objc func focusOnPlugin(_ sender: NSMenuItem) {
        if let plugin = sender.representedObject as? String {
            PluginManager.shared.focusOnPlugin(plugin)
        }
    }

    @objc func focusOnTrack(_ sender: NSMenuItem) {
        if let track = sender.representedObject as? String {
            PluginManager.shared.focusOnTrack(track)
        }
    }

    @objc func fitToScreen() {
        PluginManager.shared.fitToScreen()
    }

    @objc func quit() {
        NSApplication.shared.terminate(nil)
    }
}
