#if os(macOS)
import Library
import SwiftUI

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
        case .off: Color(nsColor: .tertiaryLabelColor)
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

@MainActor
extension RouteHealthViewModel {
    /// Real tunnels and DIRECT. Selectors only pick between them.
    var connections: [RouteDescriptor] {
        routes.filter { !$0.isGroup }.sorted { ($0.sortRank, $0.displayName) < ($1.sortRank, $1.displayName) }
    }

    func resolved(_ route: RouteDescriptor) -> RouteDescriptor {
        guard route.isGroup, let selected = routes.first(where: { $0.tag == selectedOutbound(for: route) }) else { return route }
        return selected.isGroup && selected.tag != route.tag ? resolved(selected) : selected
    }

    func tier(for route: RouteDescriptor) -> ConnectionTier {
        let route = resolved(route)
        return state(for: route).tier(for: route)
    }

    var sites: [SiteRoute] {
        var result: [String: SiteRoute] = [:]
        var order: [String] = []
        for route in routes {
            let via = resolved(route)
            for label in route.destinations {
                guard let name = SiteNames.pretty(label) else { continue }
                if let existing = result[name] {
                    // SSID rules duplicate work sites under DIRECT; the tunnel wins.
                    let current = routes.first { $0.tag == existing.viaTag }
                    if current?.isDirect == true, !via.isDirect { result[name] = SiteRoute(name: name, viaTag: via.tag) }
                    continue
                }
                result[name] = SiteRoute(name: name, viaTag: via.tag)
                order.append(name)
            }
        }
        let rank = Dictionary(uniqueKeysWithValues: connections.enumerated().map { ($1.tag, $0) })
        return order.compactMap { result[$0] }.sorted { (rank[$0.viaTag] ?? 99, $0.name) < (rank[$1.viaTag] ?? 99, $1.name) }
    }

    func route(tag: String) -> RouteDescriptor? { routes.first { $0.tag == tag } }

    var worstTier: ConnectionTier {
        connections.map { tier(for: $0) }.max() ?? .off
    }
}
#endif

#if os(macOS)
import AppKit

public struct RouteMenuEntry {
    public let name: String
    public let status: String
    public let image: NSImage?
}

@MainActor
public extension RouteHealthViewModel {
    /// Connections for the menu bar extra, in the same order as the window.
    var menuEntries: [RouteMenuEntry] {
        connections.map { route in
            let state = state(for: route)
            let tier = state.tier(for: route)
            var status = state.title(for: route)
            if state == .verified, let snapshot = snapshots[route.tag], !snapshot.country.isEmpty, !route.isWork {
                status += " · \(snapshot.country)"
            }
            let configuration = NSImage.SymbolConfiguration(paletteColors: [.white, tier.nsColor])
            let image = NSImage(systemSymbolName: tier.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
            return RouteMenuEntry(name: route.displayName, status: status, image: image)
        }
    }

    var isLeakBlocking: Bool { leakBlocking }
}

extension ConnectionTier {
    var nsColor: NSColor {
        switch self {
        case .ok: .systemGreen
        case .progress: .secondaryLabelColor
        case .action: .systemOrange
        case .fail: .systemRed
        case .off: .tertiaryLabelColor
        }
    }
}
#endif
