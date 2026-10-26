#if os(macOS)
import Library
import SwiftUI

struct LeakProtectionSettingsSection: View {
    @EnvironmentObject private var model: RouteHealthViewModel

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { model.leakProtection?.enabled ?? true }, set: { model.setLeakProtection($0) })) {
                Text("Защита от утечек")
                Text("Пока VPN включён, приложения выходят в интернет только через него. Если он упал, перезапускается или меняется профиль, интернет ненадолго пропадает, но трафик не уходит напрямую и через другой VPN.")
            }
            .disabled(model.leakProtection?.supported != true)
            if model.engineOutdated {
                LabeledContent {
                    Button(model.installingEngine ? "Обновляем…" : "Обновить движок…") { model.installEngine() }
                        .disabled(model.installingEngine)
                } label: {
                    Text("Движок устарел")
                    Text("Защита появится после обновления. Работающий VPN выключится, затем включите его снова.")
                }
            }
            if let protection = model.leakProtection, protection.armed {
                LabeledContent("Сейчас") {
                    Text(protection.blocking ? "Трафик заблокирован до восстановления VPN" : "Трафик идёт только через \(protection.tunnel)")
                }
            }
        } header: {
            Text("VPN")
        } footer: {
            if let error = model.leakProtectionError ?? model.leakProtection?.error, !error.isEmpty {
                Text(error).foregroundStyle(.red)
            } else if model.leakProtection?.supported != true, !model.engineOutdated {
                Text("Доступна после настройки локального движка.")
            } else {
                Text("Защита снимается только когда вы сами выключаете VPN. Локальная сеть (принтеры, роутер) доступна всегда.")
            }
        }
    }
}
#endif
