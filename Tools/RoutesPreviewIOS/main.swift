import SwiftUI

// Entitlement-free iOS Simulator host for the SAME Routes screens the iOS
// app uses. All values are synthetic: it cannot create tunnels or log in.
// Launch arguments: -RoutesScenario working|workIdle|meshDown|stopped
//                   -RoutesTab overview|profiles|settings
@main
struct RoutesPreviewApp: App {
    @StateObject private var board = RoutesBoard(
        scenario: UserDefaults.standard.string(forKey: "RoutesScenario").flatMap(RoutesBoard.Scenario.init(rawValue:)) ?? .workIdle
    )

    var body: some Scene {
        WindowGroup {
            RoutesTabView(
                board: board,
                tab: UserDefaults.standard.string(forKey: "RoutesTab").flatMap(RoutesTab.init(rawValue:)) ?? .overview
            )
        }
    }
}
