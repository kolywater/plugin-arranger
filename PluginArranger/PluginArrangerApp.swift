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

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        PluginManager.shared.restoreAllHiddenWindowsSync()
    }
}
