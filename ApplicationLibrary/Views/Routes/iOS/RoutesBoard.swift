#if os(iOS)
import Foundation
import Library
import SwiftUI

/// State the iOS screens read. iOS has no local engine, and a real tunnel
/// needs the Packet Tunnel entitlement, so for now it is fed by demo data
/// built from real profile JSON: connections and sites come from the rules.
@MainActor
public final class RoutesBoard: ObservableObject {
    public enum Scenario: String, CaseIterable, Identifiable {
        case working, workIdle, meshDown, stopped

        public var id: String { rawValue }

        var title: String {
            switch self {
            case .working: "Всё работает"
            case .workIdle: "Fortinet не подключён"
            case .meshDown: "Tailscale не работает"
            case .stopped: "VPN выключен"
            }
        }
    }

    public struct Profile: Identifiable {
        public let id: String
        public var name: String
        public var rules: ProfileRulesDocument
    }

    struct Summary {
        enum Action { case ruleMode, login(String) }

        let tier: ConnectionTier
        let title: String
        var detail: String?
        var actionTitle: String?
        var action: Action?
    }

    @Published public var scenario: Scenario { didSet { apply(scenario) } }
    @Published public var enabled = true
    @Published public var profiles: [Profile]
    @Published public var activeProfileID: String
    @Published var mode = "rule"
    @Published private(set) var now = Date()
    @Published private var workLoggedIn = true
    @Published private var failedTag: String?
    @Published private var connecting: Set<String> = []
    @Published private var checking: Set<String> = []
    @Published private var checkedAt: [String: Date] = [:]
    private var ticker: Task<Void, Never>?

    public init(scenario: Scenario = .workIdle, profiles: [Profile] = RoutesBoard.demoProfiles) {
        self.scenario = scenario
        self.profiles = profiles
        activeProfileID = profiles.last?.id ?? ""
        apply(scenario)
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: NSEC_PER_SEC)
                self?.tick()
            }
        }
    }

    deinit { ticker?.cancel() }

    // MARK: Reading

    var activeProfile: Profile? { profiles.first { $0.id == activeProfileID } }

    /// Real tunnels and DIRECT in the fixed order: Напрямую, Tailscale, proxies, Fortinet.
    var connections: [RouteDescriptor] {
        guard let rules = activeProfile?.rules else { return [] }
        return Self.connections(in: rules)
    }

    static func connections(in rules: ProfileRulesDocument) -> [RouteDescriptor] {
        rules.outboundChoices.compactMap { descriptor(tag: $0.tag, type: $0.kind) }
            .filter { !$0.isGroup }
            .sorted { ($0.sortRank, $0.displayName) < ($1.sortRank, $1.displayName) }
    }

    func route(tag: String) -> RouteDescriptor? { connections.first { $0.tag == tag } }

    func name(of tag: String, in rules: ProfileRulesDocument) -> String {
        Self.connections(in: rules).first { $0.tag == tag }?.displayName
            ?? rules.outboundChoices.first { $0.tag == tag }?.name ?? tag
    }

    /// Each editable rule of the active profile is one site line; the final
    /// outbound covers everything else.
    var sites: [SiteRoute] {
        guard let rules = activeProfile?.rules else { return [] }
        let routed = rules.editableIndices.map { index in
            let rule = rules.rule(at: index)
            return SiteRoute(name: Self.siteTitle(rule.title), viaTag: rule.outbound)
        }
        return routed + [SiteRoute(name: "Всё остальное", viaTag: rules.final)]
    }

    static func siteTitle(_ title: String) -> String { SiteNames.pretty(title) ?? title }

    func state(for route: RouteDescriptor) -> RouteHealthState {
        if !enabled { return .stopped }
        if route.tag == failedTag { return .failed }
        if connecting.contains(route.tag) { return .reconnecting }
        if route.isWork, !workLoggedIn { return .authentication }
        if checking.contains(route.tag) { return .checking }
        return .verified
    }

    func tier(for route: RouteDescriptor) -> ConnectionTier { state(for: route).tier(for: route) }

    func snapshot(for route: RouteDescriptor) -> RouteProbeSnapshot? {
        let exit = Self.demoExits[route.tag] ?? Self.DemoExit(country: "", ip: "", latency: 50, age: 5)
        switch state(for: route) {
        case .verified:
            return RouteProbeSnapshot(reachable: true, checkedAt: checkedAt[route.tag] ?? now, latencyMs: exit.latency, httpStatus: 200, stage: "http", exitIP: exit.ip, country: exit.country)
        case .failed:
            return RouteProbeSnapshot(reachable: false, checkedAt: checkedAt[route.tag] ?? now, stage: "connect", error: "exit node offline · 6 мин")
        default:
            return nil
        }
    }

    func target(for route: RouteDescriptor) -> String {
        route.isWork ? "https://gitlab.corp.example" : "https://www.cloudflare.com/cdn-cgi/trace"
    }

    var summary: Summary {
        if !enabled {
            return Summary(tier: .off, title: "VPN выключен", detail: "Сайты открываются напрямую, правила не действуют.")
        }
        if mode == "direct" {
            return Summary(tier: .action, title: "Сайты идут мимо VPN", detail: "Включён режим «Напрямую».", actionTitle: "Вернуть правила", action: .ruleMode)
        }
        let list = connections
        let broken = list.filter { tier(for: $0) == .fail }
        if !broken.isEmpty {
            let affected = sites.filter { site in broken.contains { $0.tag == site.viaTag } }.map(\.name)
            let title = affected.isEmpty ? "\(names(broken.map(\.displayName))) не работает" : "\(names(affected)) недоступны"
            return Summary(tier: .fail, title: title, detail: "\(names(broken.map(\.displayName))) не работает, остальное в порядке.")
        }
        if let route = list.first(where: { tier(for: $0) == .action }) {
            return Summary(tier: .action, title: "\(route.displayName): нужен вход", detail: "Сайты этого подключения недоступны.", actionTitle: "Войти", action: .login(route.tag))
        }
        if list.contains(where: { tier(for: $0) == .progress }) {
            return Summary(tier: .progress, title: "Проверка подключений…")
        }
        return Summary(tier: .ok, title: "Всё работает")
    }

    private func names(_ values: [String]) -> String {
        guard values.count > 1 else { return values.first ?? "" }
        return values.dropLast().joined(separator: ", ") + " и " + values.last!
    }

    // MARK: Acting

    func refresh() async {
        guard enabled else { return }
        checking = Set(connections.filter { tier(for: $0) == .ok }.map(\.tag))
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        checking = []
        for route in connections { checkedAt[route.tag] = Date() }
    }

    func logIn(_ tag: String) {
        connecting.insert(tag)
        Task {
            try? await Task.sleep(nanoseconds: 2 * NSEC_PER_SEC)
            connecting.remove(tag)
            workLoggedIn = true
            checkedAt[tag] = Date()
        }
    }

    func logOut(_: String) { workLoggedIn = false }

    func perform(_ action: Summary.Action) {
        switch action {
        case .ruleMode: mode = "rule"
        case let .login(tag): logIn(tag)
        }
    }

    func updateRules(of profileID: String, _ change: (inout ProfileRulesDocument) -> Void) {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        change(&profiles[index].rules)
    }

    private func apply(_ scenario: Scenario) {
        enabled = scenario != .stopped
        workLoggedIn = scenario != .workIdle
        failedTag = scenario == .meshDown ? "tailscale" : nil
        mode = "rule"
        connecting = []
        checking = []
        checkedAt = Dictionary(uniqueKeysWithValues: Self.demoExits.map { ($0.key, Date().addingTimeInterval(-$0.value.age)) })
    }

    private func tick() {
        now = Date()
        // Demo re-check every 30 seconds, like the macOS engine probes.
        for (tag, date) in checkedAt where now.timeIntervalSince(date) >= 30 { checkedAt[tag] = now }
    }

    private static func descriptor(tag: String, type: String) -> RouteDescriptor? {
        guard let data = try? JSONSerialization.data(withJSONObject: ["tag": tag, "type": type]) else { return nil }
        return try? JSONDecoder().decode(RouteDescriptor.self, from: data)
    }
}

// MARK: Demo data

extension RoutesBoard {
    struct DemoExit {
        let country: String
        let ip: String
        let latency: Int64
        let age: TimeInterval
    }

    // Documentation addresses only (RFC 5737).
    static let demoExits: [String: DemoExit] = [
        "direct": DemoExit(country: "RU", ip: "192.0.2.44", latency: 18, age: 3),
        "tailscale": DemoExit(country: "NL", ip: "198.51.100.7", latency: 64, age: 8),
        "happ": DemoExit(country: "DE", ip: "203.0.113.20", latency: 116, age: 3),
        "fortinet": DemoExit(country: "", ip: "", latency: 38, age: 14),
    ]

    public nonisolated static var demoProfiles: [Profile] {
        [
            Profile(id: "personal", name: "Личный", rules: try! ProfileRulesDocument(json: demoConfig(work: false))),
            Profile(id: "work", name: "Работа", rules: try! ProfileRulesDocument(json: demoConfig(work: true))),
        ]
    }

    nonisolated static func demoConfig(work: Bool) -> String {
        var endpoints: [[String: Any]] = [["type": "tailscale", "tag": "tailscale"]]
        var rules: [[String: Any]] = [
            ["action": "sniff"],
            ["rule_set": ["ANTHROPIC"], "action": "route", "outbound": "happ"],
            ["rule_set": ["YOUTUBE"], "action": "route", "outbound": "tailscale"],
            ["rule_set": ["TELEGRAM"], "action": "route", "outbound": "tailscale"],
            ["rule_set": ["OPENAI"], "action": "route", "outbound": "tailscale"],
        ]
        if work {
            endpoints.append(["type": "openconnect", "tag": "fortinet"])
            rules.append(["domain_suffix": ["corp.example"], "action": "route", "outbound": "fortinet"])
        }
        rules += [
            ["rule_set": ["OZON"], "action": "route", "outbound": "direct"],
            ["domain_suffix": ["ru"], "action": "route", "outbound": "direct"],
        ]
        let config: [String: Any] = [
            "outbounds": [["type": "direct", "tag": "direct"], ["type": "hysteria2", "tag": "happ", "server": "203.0.113.20", "server_port": 443]],
            "endpoints": endpoints,
            "dns": ["servers": [
                ["type": "https", "tag": "dns-happ", "server": "1.1.1.1", "detour": "happ"],
                ["type": "tailscale", "tag": "dns-tailscale", "endpoint": "tailscale"],
            ]],
            "route": ["rules": rules, "final": "direct"],
        ]
        let data = try! JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
#endif
