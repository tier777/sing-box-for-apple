#if os(macOS)
import Library
import SwiftUI

struct LeakProtectionSettingsSection: View {
    @EnvironmentObject private var model: RouteHealthViewModel

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { model.leakProtection?.enabled ?? true }, set: { model.setLeakProtection($0) })) {
                Text("Kill switch")
                Text("Блокирует интернет при сбое, перезапуске и ручном выключении VPN. Чтобы вернуть обычные сетевые маршруты, отключите kill switch отдельно.")
            }
            .disabled(model.leakProtection?.supported != true || model.leakProtectionUpdating || model.changingTailscaleExit)
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
            Button("Аварийно отключить kill switch…") { model.emergencyDisableProtection() }
                .disabled(model.leakProtectionUpdating)
            Text("Если фоновая служба не отвечает. Потребуется пароль администратора macOS; снимаются только правила SFM+.")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            Text("VPN")
        } footer: {
            if let error = model.leakProtectionError ?? model.leakProtection?.error, !error.isEmpty {
                Text(error).foregroundStyle(.red)
            } else if model.leakProtection?.supported != true, !model.engineOutdated {
                Text("Доступна после настройки локального движка.")
            } else {
                Text("Выключение VPN сохраняет блокировку. Переключатель kill switch снимает её. Локальная сеть (принтеры, роутер) остаётся доступна.")
            }
        }
    }
}
#endif
