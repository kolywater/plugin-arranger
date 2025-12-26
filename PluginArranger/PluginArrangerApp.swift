//
//  PluginArrangerApp.swift
//  PluginArranger
//
//  Created by Aiden Elliott on 12/22/25.
//

import SwiftUI

@main
struct PluginArrangerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @ObservedObject private var pluginManager = PluginManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
        }

        MenuBarExtra("PluginArranger", systemImage: "slider.horizontal.3") {
            Button("Scan Plugins") {
                pluginManager.performScan()
            }

            Divider()

            Button("Show All") {
                pluginManager.showAllPlugins()
            }

            Divider()

            ForEach(pluginManager.scanResult.plugins, id: \.self) { plugin in
                Button(plugin) {
                    pluginManager.focusOnPlugin(plugin)
                }
            }

            if !pluginManager.scanResult.plugins.isEmpty {
                Divider()
            }

            ForEach(pluginManager.scanResult.tracks, id: \.self) { track in
                Button(track) {
                    pluginManager.focusOnTrack(track)
                }
            }

            if !pluginManager.scanResult.tracks.isEmpty {
                Divider()
            }

            Button("Fit to Screen") {
                pluginManager.fitToScreen()
            }

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        PluginManager.shared.restoreAllHiddenWindowsSync()
    }
}
