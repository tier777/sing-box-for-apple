#if os(macOS)
import Library
import SwiftUI

struct OverviewHeadline {
    enum Action { case setupEngine, start, stop, disableProtection, ruleMode, open(String), login(String) }

    let tier: ConnectionTier
    let title: String
    let subtitle: String
    var actionTitle: String?
    var action: Action?
}

@MainActor
extension RouteHealthViewModel {
    var leakBlocking: Bool { leakProtection?.armed == true && leakProtection?.blocking == true }

    var headline: OverviewHeadline {
        if needsEngineSetup {
            return OverviewHeadline(tier: .off, title: "Нужен локальный движок", subtitle: "Устанавливается один раз с паролем администратора. Сама установка VPN не включает.", actionTitle: installingEngine ? "Настраиваем…" : "Настроить…", action: .setupEngine)
        }
        if leakBlocking {
            return OverviewHeadline(tier: .fail, title: "Интернет заблокирован", subtitle: "Kill switch включён. Запустите VPN или отдельно отключите блокировку.", actionTitle: "Отключить kill switch", action: .disableProtection)
        }
        if !enabled {
            let subtitle = leakProtection?.enabled == true
                ? "Kill switch включится при первом запуске VPN. Сейчас правила VPN не действуют."
                : "Kill switch выключен. Приложения используют обычные сетевые маршруты."
            return OverviewHeadline(tier: .off, title: "VPN выключен", subtitle: subtitle, actionTitle: "Включить VPN", action: .start)
        }
        if currentClashMode.lowercased() == "direct" {
            return OverviewHeadline(tier: .action, title: "Сайты идут мимо VPN", subtitle: "Включён режим «Напрямую».", actionTitle: "Вернуть правила", action: .ruleMode)
        }
        let list = connections
        guard !list.isEmpty else {
            return OverviewHeadline(tier: .progress, title: "Подключаемся…", subtitle: "Ждём список подключений от движка.")
        }
        let worst = worstTier
        switch worst {
        case .fail:
            let broken = list.filter { tier(for: $0) == .fail }
            let affected = sites.filter { site in broken.contains { $0.tag == site.viaTag } }.map(\.name)
            let directOK = list.contains { $0.isDirect && tier(for: $0) == .ok }
            let title = affected.isEmpty ? "\(names(broken)) не работает" : "\(names(affected)) недоступны"
            let subtitle = "\(names(broken)) не работает." + (directOK ? " Wi-Fi и остальные подключения в порядке." : "")
            return OverviewHeadline(tier: .fail, title: title, subtitle: subtitle, actionTitle: "Подробнее", action: .open(broken[0].tag))
        case .action:
            let route = list.first { tier(for: $0) == .action }!
            return OverviewHeadline(tier: .action, title: "\(route.displayName): нужен вход", subtitle: "Сайты этого подключения недоступны, остальное работает.", actionTitle: "Войти…", action: .login(route.tag))
        case .progress:
            return OverviewHeadline(tier: .progress, title: "Проверка подключений…", subtitle: "Прежние результаты сброшены, обычно это несколько секунд.")
        case .ok, .off:
            let idle = list.filter { tier(for: $0) == .off }
            let rest = idle.isEmpty ? "" : " \(names(idle)) не подключён."
            return OverviewHeadline(tier: .ok, title: "Всё работает", subtitle: "Подключения проверены за последние 30 секунд." + rest)
        }
    }

    private func names(_ routes: [RouteDescriptor]) -> String { names(routes.map(\.displayName)) }

    private func names(_ values: [String]) -> String {
        guard values.count > 1 else { return values.first ?? "" }
        return values.dropLast().joined(separator: ", ") + " и " + values.last!
    }

    func secondLine(for route: RouteDescriptor) -> String {
        let state = state(for: route)
        if state == .verified, let snapshot = snapshots[route.tag] {
            let age = max(0, Int(now.timeIntervalSince(snapshot.checkedAt)))
            return "\(snapshot.latencyMs) мс · " + (age == 0 ? "только что" : "\(age) с назад")
        }
        return state.note
    }

    func exitLine(for route: RouteDescriptor) -> String {
        guard let snapshot = snapshots[route.tag], snapshot.reachable else { return route.kindTitle }
        if route.isWork { return route.kindTitle }
        let exit = [snapshot.country, snapshot.exitIP].filter { !$0.isEmpty }.joined(separator: " · ")
        return exit.isEmpty ? route.kindTitle : "\(route.kindTitle) · выход \(exit)"
    }
}

struct RoutesOverviewView: View {
    @EnvironmentObject private var model: RouteHealthViewModel
    @EnvironmentObject private var environments: ExtensionEnvironments
    @Binding var page: RoutesPage?
    let perform: (OverviewHeadline.Action) -> Void

    var body: some View {
        Form {
            headlineSection
            if !model.connections.isEmpty {
                connectionsSection
                sitesSection
            }
            routingSection
        }
        .formStyle(.grouped)
    }

    private var headlineSection: some View {
        let headline = model.headline
        return Section {
            HStack(alignment: .center, spacing: 14) {
                StatusSymbol(tier: headline.tier, size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(headline.title).font(.title2.weight(.bold))
                    Text(headline.subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                if let title = headline.actionTitle, let action = headline.action {
                    Button(title) { perform(action) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(model.installingEngine || model.leakProtectionUpdating || model.workVPNUpdating || model.changingTailscaleExit)
                }
            }
            .padding(.vertical, 6)
            .accessibilityElement(children: .combine)
            if let error = model.catalogError, !model.enabled || model.needsEngineSetup {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var connectionsSection: some View {
        Section {
            ForEach(model.connections) { route in
                Button { page = .connection(route.tag) } label: {
                    ConnectionRow(route: route)
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("Подключения")
        } footer: {
            Text("«Работает» означает, что HTTPS-запрос через это подключение прошёл за последние 45 секунд.")
        }
    }

    private var sitesSection: some View {
        Section("Сайты") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text("Сайт"); Text("Подключение"); Text("Состояние")
                }
                .font(.caption).foregroundStyle(.secondary)
                ForEach(model.sites) { site in
                    Divider().gridCellUnsizedAxes(.horizontal)
                    let route = model.route(tag: site.viaTag)
                    let tier = route.map { model.tier(for: $0) } ?? .off
                    GridRow {
                        Text(site.name)
                        Text(route?.displayName ?? site.viaTag).foregroundStyle(.secondary)
                        HStack(spacing: 5) {
                            StatusSymbol(tier: tier)
                            Text(siteStatus(tier, route: route))
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func siteStatus(_ tier: ConnectionTier, route: RouteDescriptor?) -> String {
        switch tier {
        case .ok: "Доступен"
        case .progress: "Проверяется"
        case .action: "Ждёт входа"
        case .fail: "Недоступен"
        case .off: model.enabled ? "\(route?.displayName ?? "") не подключён" : "VPN выключен"
        }
    }

    private var routingSection: some View {
        Section {
            if model.workVPNAvailable {
                Toggle(isOn: Binding(get: { model.workVPNEnabled }, set: { model.setWorkVPN($0) })) {
                    Text("Рабочий VPN · Fortinet")
                    Text(model.workVPNEnabled ? "Для доступа завершите вход в подключении Fortinet. При отказе рабочие адреса останутся заблокированы." : "Выключен. Рабочие адреса и их DNS заблокированы; личные маршруты сохраняются.")
                }
                .disabled(model.workVPNUpdating || model.installingEngine || model.changingTailscaleExit)
                Text("Переключение перезапускает общий туннель. Включённый kill switch сохраняет блокировку на время перезапуска.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.engineOutdated {
                LabeledContent {
                    Button(model.installingEngine ? "Обновляем…" : "Обновить движок…") { model.installEngine() }
                        .disabled(model.installingEngine)
                } label: {
                    Text("Kill switch")
                    Text("Нужна новая версия движка. Работающий VPN выключится, затем включите его снова.")
                }
            }
            if model.leakProtection?.supported == true {
                Toggle(isOn: Binding(get: { model.leakProtection?.enabled ?? true }, set: { model.setLeakProtection($0) })) {
                    Text("Kill switch")
                    Text("Блокирует интернет при сбое, перезапуске и ручном выключении VPN. Снимается отдельно этим переключателем.")
                }
                .disabled(model.leakProtectionUpdating || model.changingTailscaleExit)
            }
            if model.leakProtectionError != nil || !LocalEngine.isAvailable {
                Button("Аварийно отключить kill switch…") { model.emergencyDisableProtection() }
                    .disabled(model.leakProtectionUpdating)
            }
            let modes = environments.commandClient.clashModeList
            if model.enabled, modes.count > 1 {
                Picker("Режим", selection: Binding(get: { environments.commandClient.clashMode }, set: { setMode($0) })) {
                    ForEach(modes, id: \.self) { Text(modeTitle($0)).tag($0) }
                }
            }
        } header: {
            Text("Маршрутизация")
        } footer: {
            if let error = model.workVPNError { Text(error).foregroundStyle(.red) }
            if let error = model.leakProtectionError ?? model.leakProtection?.error, !error.isEmpty {
                Text(error).foregroundStyle(.red)
            }
        }
    }

    private func modeTitle(_ mode: String) -> String {
        switch mode.lowercased() {
        case "rule": "По правилам"
        case "global": "Всё через VPN"
        case "direct": "Напрямую"
        default: mode
        }
    }

    private func setMode(_ mode: String) {
        Task.detached { try? CommandTarget.standaloneClient().setClashMode(mode) }
    }
}

struct ConnectionRow: View {
    @EnvironmentObject private var model: RouteHealthViewModel
    let route: RouteDescriptor

    var body: some View {
        let state = model.state(for: route)
        HStack(spacing: 10) {
            Image(systemName: route.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 1) {
                Text(route.displayName).fontWeight(.medium)
                Text(model.exitLine(for: route)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 1) {
                HStack(spacing: 5) {
                    StatusSymbol(tier: state.tier(for: route))
                    Text(state.title(for: route))
                }
                Text(model.secondLine(for: route)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Открыть подробности")
    }
}
#endif
