#if os(macOS) || os(iOS)
import Library
import SwiftUI

// Words, symbols and order shared by the macOS window and the iOS app.

/// Five groups a person reads at a glance. The precise engine state stays in
/// the detail line; the group only chooses symbol shape and color.
public enum ConnectionTier: Int, Comparable {
    case off, ok, progress, action, fail

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var symbol: String {
        switch self {
        case .ok: "checkmark.circle.fill"
        case .progress: "ellipsis.circle.fill"
        case .action: "exclamationmark.triangle.fill"
        case .fail: "xmark.circle.fill"
        case .off: "minus.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .ok: .green
        case .progress: .secondary
        case .action: .orange
        case .fail: .red
        #if os(macOS)
        case .off: Color(nsColor: .tertiaryLabelColor)
        #else
        case .off: Color(uiColor: .systemGray2)
        #endif
        }
    }
}

struct StatusSymbol: View {
    let tier: ConnectionTier
    var size: CGFloat = 13

    var body: some View {
        Image(systemName: tier.symbol)
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, tier.color)
            .font(.system(size: size))
            .accessibilityHidden(true)
    }
}

extension RouteHealthState {
    func tier(for route: RouteDescriptor) -> ConnectionTier {
        switch self {
        case .verified: .ok
        case .checking, .reconnecting, .stale, .telemetryLost: .progress
        // A work VPN that nobody logged into is simply not in use.
        case .authentication: route.isWork ? .off : .action
        case .unconfigured: .off
        case .failed, .noNetwork: .fail
        case .stopped, .sleeping: .off
        }
    }

    func title(for route: RouteDescriptor) -> String {
        switch self {
        case .verified: "Работает"
        case .checking: "Проверяется"
        case .reconnecting: "Подключается"
        case .stale: "Проверяется"
        case .telemetryLost: "Нет связи с движком"
        case .authentication: route.isWork ? "Не подключён" : "Нужен вход"
        case .unconfigured: "Не проверяется"
        case .failed: "Не работает"
        case .noNetwork: "Нет сети"
        case .stopped: "Выключено"
        case .sleeping: "Сон"
        }
    }

    var note: String {
        switch self {
        case .verified: ""
        case .checking, .stale: "HTTPS-запрос через это подключение"
        case .reconnecting: "выходной узел ещё не готов"
        case .telemetryLost: "ждём ответа движка"
        case .authentication: "вход не выполнен"
        case .unconfigured: "нет адреса проверки"
        case .failed: "последняя проверка не прошла"
        case .noNetwork: "система не видит сети"
        case .stopped: "VPN выключен"
        case .sleeping: "Mac спит"
        }
    }
}

extension RouteDescriptor {
    private static let namesKey = "route-display-names"

    var displayName: String {
        if let custom = (UserDefaults.standard.dictionary(forKey: Self.namesKey) as? [String: String])?[tag], !custom.isEmpty { return custom }
        switch type {
        case "direct": return "Напрямую"
        case "tailscale": return "Tailscale"
        case "openconnect": return "Fortinet"
        case "wireguard": return "WireGuard"
        default: return tag.prefix(1).uppercased() + tag.dropFirst().lowercased()
        }
    }

    static func rename(_ tag: String, to name: String) {
        var names = UserDefaults.standard.dictionary(forKey: namesKey) as? [String: String] ?? [:]
        names[tag] = name.trimmingCharacters(in: .whitespaces).isEmpty ? nil : name
        UserDefaults.standard.set(names, forKey: namesKey)
    }

    var kindTitle: String {
        switch type {
        case "direct": "Без VPN" + (bindInterface.isEmpty ? "" : " · \(bindInterface)")
        case "tailscale": "Tailscale"
        case "openconnect": "Рабочий VPN · OpenConnect"
        case "hysteria2": "Hysteria2"
        case "hysteria": "Hysteria"
        case "shadowsocks": "Shadowsocks"
        case "wireguard": "WireGuard"
        default: type.capitalized
        }
    }

    var systemImage: String {
        switch type {
        case "direct": "wifi"
        case "tailscale": "circle.grid.3x3.fill"
        case "openconnect", "openvpn": "briefcase.fill"
        default: "bolt.fill"
        }
    }

    // Direct first, then mesh, then proxies, then work: the order people asked for.
    var sortRank: Int {
        switch type {
        case "direct": 0
        case "tailscale": 1
        case "openconnect", "openvpn": 3
        default: 2
        }
    }
}

struct SiteRoute: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let viaTag: String
}

enum SiteNames {
    private static let known: [String: String] = [
        "ANTHROPIC": "Claude", "OPENAI": "OpenAI", "YOUTUBE": "YouTube", "TELEGRAM": "Telegram",
        "TELEGRAM-DOMAINS": "Telegram", "OZON": "Ozon", "ru": "Сайты .ru",
    ]

    static func pretty(_ label: String) -> String? {
        if let name = known[label] { return name }
        // Bare subnets are an implementation detail of a site, not a site.
        if label.contains("/") || label.contains(":") || label.first?.isNumber == true { return nil }
        if label == label.uppercased() { return label.prefix(1) + label.dropFirst().lowercased() }
        return label
    }
}
#endif
