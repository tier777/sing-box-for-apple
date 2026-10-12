import SwiftUI
#if !HEALTH_PREVIEW
import Library
#endif

// Native system typography and list rows. Text names every state; color only
// reinforces it. The last successful test is never a permanent connected badge.
public struct RouteHealthRow: View {
    @Environment(\.colorScheme) private var colorScheme
    public let route: RouteDescriptor
    public let state: RouteHealthState
    public let snapshot: RouteProbeSnapshot?
    public let target: String
    public let endpointState: String?
    public let endpointError: String
    public let selectedOutbound: String
    public let now: Date
    public let configure: () -> Void
    public let authenticate: () -> Void

    public init(route: RouteDescriptor, state: RouteHealthState, snapshot: RouteProbeSnapshot?, target: String, endpointState: String?, endpointError: String = "", selectedOutbound: String = "", now: Date, configure: @escaping () -> Void, authenticate: @escaping () -> Void) {
        self.route = route; self.state = state; self.snapshot = snapshot; self.target = target
        self.endpointState = endpointState; self.now = now; self.configure = configure; self.authenticate = authenticate
        self.endpointError = endpointError; self.selectedOutbound = selectedOutbound
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: route.isDirect ? "network" : "shield.lefthalf.filled")
                    .font(.title3).foregroundStyle(.secondary).frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text(route.tag).font(.headline).textSelection(.enabled)
                    Text(route.isDirect ? "Прямой интернет" : route.type == "tailscale" ? "Tailscale · проверяем выход в интернет" : route.type == "openconnect" ? "Рабочий VPN · Fortinet / OpenConnect" : route.type)
                        .font(.subheadline).foregroundStyle(.secondary)
                    if !route.destinations.isEmpty {
                        Text(route.destinations.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    if !selectedOutbound.isEmpty { Text("Текущий выход: \(selectedOutbound)").font(.subheadline.weight(.medium)) }
                    if !route.isDirect && route.directFallback { Text("В пути разрешён прямой выход").font(.caption).foregroundStyle(.orange) }
                }
                Spacer(minLength: 12)
                Label(stateTitle, systemImage: stateIcon).font(.subheadline.weight(.medium)).foregroundStyle(stateColor)
                    .multilineTextAlignment(.trailing)
                    .accessibilityLabel("\(route.tag): \(stateTitle)")
            }
            if state == .verified, let snapshot {
                HStack(spacing: 16) {
                    Text("\(snapshot.latencyMs) мс").monospacedDigit()
                    if !snapshot.country.isEmpty { Text("Выход: \(snapshot.country)") }
                    if !snapshot.exitIP.isEmpty { Text(snapshot.exitIP).textSelection(.enabled) }
                    Spacer(minLength: 0)
                    Text("Проверка \(max(0, Int(now.timeIntervalSince(snapshot.checkedAt)))) с назад").monospacedDigit()
                }.font(.caption).foregroundStyle(.secondary)
                if snapshot.httpStatus >= 300 {
                    Text("Маршрут отвечает. Сайт вернул HTTP \(snapshot.httpStatus) — доступ к самому сайту требует отдельной проверки.").font(.caption)
                }
            } else {
                Text(stateExplanation).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if state == .authentication && route.type == "openconnect" {
                Button("Ввести пароль / код из SMS", action: authenticate).buttonStyle(.borderedProminent)
            }
            DisclosureGroup("Маршрут и диагностика") {
                VStack(alignment: .leading, spacing: 8) {
                    if let endpointState { Text("Состояние VPN: \(endpointState)") }
                    if !endpointError.isEmpty { Text(endpointError).textSelection(.enabled).foregroundStyle(.red) }
                    if !route.bindInterface.isEmpty { Text("Сетевой интерфейс: \(route.bindInterface)") }
                    if !route.detour.isEmpty { Text("Соединения VPN идут через: \(route.detour)") }
                    if !route.isDirect {
                        Text(route.directFallback ? "В этом пути есть вариант прямого выхода. Проверь выбор маршрута." : "Варианта прямого выхода в этом VPN нет. Это не заменяет проверку правил сайтов.")
                    }
                    if !target.isEmpty { Text("HTTPS-проверка: \(target)").textSelection(.enabled) }
                    if let snapshot, !snapshot.error.isEmpty {
                        Text("Этап: \(snapshot.stage)").font(.caption)
                        Text(snapshot.error).font(.caption).textSelection(.enabled)
                    }
                    Button(target.isEmpty ? "Указать адрес проверки" : "Изменить адрес проверки", action: configure)
                }.font(.subheadline).padding(.top, 6)
            }.font(.caption)
            if state == .unconfigured { Button("Указать внутренний HTTPS-адрес", action: configure) }
        }.padding(.vertical, 16)
    }

    private var stateTitle: String {
        switch state {
        case .stopped: "Выключено"
        case .sleeping: "Сон"
        case .noNetwork: "Нет сети"
        case .telemetryLost: "Нет ответа движка"
        case .authentication: "Нужен вход"
        case .reconnecting: "Восстанавливается"
        case .unconfigured: "Не проверено"
        case .checking: "Проверяем…"
        case .verified: "Проверено"
        case .failed: "Не отвечает"
        case .stale: "Нужна проверка"
        }
    }
    private var stateIcon: String {
        switch state {
        case .verified: "checkmark.circle.fill"
        case .failed, .noNetwork: "exclamationmark.circle.fill"
        case .authentication: "key.fill"
        case .checking, .reconnecting: "arrow.triangle.2.circlepath"
        case .sleeping: "moon.fill"
        default: "circle.dashed"
        }
    }
    private var stateColor: Color {
        switch state {
        case .verified: colorScheme == .dark ? .green : Color(red: 0.10, green: 0.40, blue: 0.19)
        case .failed, .noNetwork: colorScheme == .dark ? .red : Color(red: 0.70, green: 0.12, blue: 0.08)
        case .authentication, .reconnecting, .telemetryLost: colorScheme == .dark ? .orange : Color(red: 0.55, green: 0.28, blue: 0)
        default: .secondary
        }
    }
    private var stateExplanation: String {
        switch state {
        case .stopped: "Туннель не запущен. Проверки VPN не выполняются."
        case .sleeping: "После пробуждения повторим проверку; старый результат не подтверждает связь."
        case .noNetwork: "Система не видит доступной сети."
        case .telemetryLost: "Нет свежей телеметрии. Канал наблюдения восстанавливается, VPN не переключаем."
        case .authentication: "VPN ожидает авторизацию. Доступ через него пока не подтверждён."
        case .reconnecting: "VPN ещё не готов или выходной узел недоступен."
        case .unconfigured: "Для рабочего VPN нужен внутренний адрес проверки: публичный интернет может быть запрещён политикой компании."
        case .checking: "Отправляем HTTPS-запрос именно через этот маршрут."
        case .verified: "HTTPS-запрос прошёл через этот маршрут."
        case .failed: "Последняя HTTPS-проверка не прошла. Причина указана в диагностике ниже."
        case .stale: "Свежего результата нет. Предыдущую проверку нельзя считать подтверждением связи сейчас."
        }
    }
}
