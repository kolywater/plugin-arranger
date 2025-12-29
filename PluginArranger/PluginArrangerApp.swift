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

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        setupPanel()
    }

    func setupPanel() {
        let panel = NonActivatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 150),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.title = "PluginArranger"
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: ContentView())
        panel.center()
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
