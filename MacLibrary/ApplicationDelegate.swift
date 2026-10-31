import AppKit
import ApplicationLibrary
import Foundation
import Libbox
import Library
import ServiceManagement
import UserNotifications

@MainActor
open class ApplicationDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    public let applicationState = MacApplicationState()

    public func applicationDidFinishLaunching(_: Notification) {
        LibboxPrepareCrashSignalHandlers()
        NativeCrashReporter.installForCurrentProcess()
        LibboxReinstallCrashSignalHandlers()
        HangWatchdog.installForCurrentProcess()
        NSLog("Here I stand")
        do {
            try ServiceSetup.apply(crashReportSource: "Application")
        } catch {
            NSLog("setup service error: \(error.localizedDescription)")
        }
        do {
            try ApplicationLocale.apply()
        } catch {
            NSLog("failed to set locale: \(error)")
        }
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.setNotificationCategories([
            UNNotificationCategory(
                identifier: "OPEN_URL",
                actions: [
                    UNNotificationAction(identifier: "COPY_URL", title: "Copy URL", options: .foreground, icon: UNNotificationActionIcon(systemImageName: "clipboard.fill")),
                    UNNotificationAction(identifier: "OPEN_URL", title: "Open", options: .foreground, icon: UNNotificationActionIcon(systemImageName: "safari.fill")),
                ],
                intentIdentifiers: []
            ),
        ])
        notificationCenter.delegate = self
        let event = NSAppleEventManager.shared().currentAppleEvent
        let launchedAsLogInItem =
            event?.eventID == kAEOpenApplication &&
            event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        Task {
            if Variant.useLocalEngine, !(await SharedPreferences.localLoginItemConfigured.get()) {
                do {
                    try SMAppService.mainApp.register()
                    await SharedPreferences.localLoginItemConfigured.set(true)
                } catch {
                    NSLog("SFM+ login item registration needs attention: \(error.localizedDescription)")
                }
            }
            let showMenuBarExtra = await SharedPreferences.showMenuBarExtra.get()
            let menuBarExtraInBackground = await SharedPreferences.menuBarExtraInBackground.get()
            let shouldShowWindow = Variant.screenshotMode ||
                Variant.inDebug ||
                !launchedAsLogInItem ||
                !showMenuBarExtra ||
                !menuBarExtraInBackground
            if shouldShowWindow {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
            } else {
                NSApp.windows.first?.close()
            }
            await applicationState.initialize()
            do {
                try await ProfileUpdateTask.configure()
                if launchedAsLogInItem {
                    let wasStartedByUser = await SharedPreferences.startedByUser.get()
                    let shouldConnect = Variant.useLocalEngine || wasStartedByUser
                    if shouldConnect {
                        if let profile = try await ExtensionProfile.load() {
                            var alreadyRunning = false
                            if Variant.useLocalEngine {
                                alreadyRunning = await Task.detached { (try? LocalEngine.state().state) == 2 }.value
                            }
                            if !alreadyRunning { try await profile.start() }
                        }
                    }
                }
            } catch {
                NSLog("application setup error: \(error.localizedDescription)")
            }
        }
    }

    public func userNotificationCenter(_: UNUserNotificationCenter, willPresent _: UNNotification) async -> UNNotificationPresentationOptions {
        .banner
    }

    public func userNotificationCenter(_: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if let url = response.notification.request.content.userInfo["OPEN_URL"] as? String {
            switch response.actionIdentifier {
            case "COPY_URL":
                NSPasteboard.general.setString(url, forType: .URL)
            default:
                NSWorkspace.shared.open(URL(string: url)!)
            }
        }
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ application: NSApplication) -> Bool {
        if Variant.inDebug {
            return true
        }
        Task {
            let keepRunning = await SharedPreferences.menuBarExtraInBackground.get()
            if !keepRunning, !application.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
                application.terminate(nil)
            }
        }
        return false
    }

    public func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, NSApp.activationPolicy() == .accessory {
            NSApp.setActivationPolicy(.regular)
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.activate()
        }
        return true
    }
}
