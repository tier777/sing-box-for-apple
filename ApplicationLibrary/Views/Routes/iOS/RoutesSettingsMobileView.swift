#if os(iOS)
import SwiftUI

@available(iOS 16.0, *)
struct RoutesSettingsMobileView: View {
    @EnvironmentObject private var board: RoutesBoard

    var body: some View {
        List {
            Section {
                Picker("Состояние", selection: $board.scenario) {
                    ForEach(RoutesBoard.Scenario.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Демо")
            } footer: {
                Text("Туннеля в этой сборке нет: на iPhone для него нужен Network Extension. Экраны показывают условные данные.")
            }
            Section {
                LabeledContent("Версия", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                LabeledContent("Движок", value: "sing-box 1.14.3")
            }
        }
        .navigationTitle("Настройки")
    }
}
#endif
