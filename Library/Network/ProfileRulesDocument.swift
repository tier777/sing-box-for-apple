import Foundation

public enum TailscaleExitConfiguration {
    public static func selecting(_ stableID: String, endpointTag: String, in json: String) throws -> String {
        guard !stableID.isEmpty, !stableID.contains(where: { $0.isWhitespace }),
              var root = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              var endpoints = root["endpoints"] as? [[String: Any]],
              let index = endpoints.firstIndex(where: { $0["tag"] as? String == endpointTag && $0["type"] as? String == "tailscale" }),
              endpoints[index]["system_interface"] as? Bool != true else {
            throw NSError(domain: "TailscaleExit", code: 1, userInfo: [NSLocalizedDescriptionKey: "Для защищённого переключения нужен конкретный узел и встроенный Tailscale без системного интерфейса."])
        }
        endpoints[index]["exit_node"] = "id:\(stableID)"
        root["endpoints"] = endpoints
        return String(decoding: try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }
}

/// Build the local engine's runtime configuration without changing the saved
/// profile. Disabled work destinations are rejected in place, never removed
/// from the rule list (which would expose them to .ru or the default route).
public enum WorkVPNConfiguration {
    public static func containsWorkVPN(_ json: String) throws -> Bool {
        let root = try object(json)
        return (root["endpoints"] as? [[String: Any]] ?? []).contains { $0["type"] as? String == "openconnect" }
    }

    public static func runtime(_ json: String, enabled: Bool) throws -> String {
        if enabled { return json }
        var root = try object(json)
        let endpoints = root["endpoints"] as? [[String: Any]] ?? []
        var blocked = Set(endpoints.filter { $0["type"] as? String == "openconnect" }.compactMap { $0["tag"] as? String })
        if blocked.isEmpty { return json }
        let outbounds = root["outbounds"] as? [[String: Any]] ?? []
        // A selector containing a disabled endpoint must not select DIRECT.
        var previousCount = -1
        while blocked.count != previousCount {
            previousCount = blocked.count
            for entry in endpoints + outbounds {
                let dependencies = (entry["outbounds"] as? [String] ?? []) + [entry["detour"] as? String].compactMap { $0 }
                if dependencies.contains(where: blocked.contains), let tag = entry["tag"] as? String { blocked.insert(tag) }
            }
        }
        var route = root["route"] as? [String: Any] ?? [:]
        var dns = root["dns"] as? [String: Any] ?? [:]
        let servers = dns["servers"] as? [[String: Any]] ?? []
        let blockedDNS = Set(servers.filter {
            blocked.contains($0["endpoint"] as? String ?? "") || blocked.contains($0["detour"] as? String ?? "")
        }.compactMap { $0["tag"] as? String })
        guard !blocked.contains(route["final"] as? String ?? ""), !blockedDNS.contains(dns["final"] as? String ?? "") else {
            throw NSError(domain: "WorkVPN", code: 1, userInfo: [NSLocalizedDescriptionKey: "Рабочий VPN нельзя отключить: он выбран общим выходом или основным DNS."])
        }
        func reject(_ value: Any, key: String, tags: Set<String>) -> Any {
            if let list = value as? [Any] { return list.map { reject($0, key: key, tags: tags) } }
            guard var rule = value as? [String: Any] else { return value }
            if let tag = rule[key] as? String, tags.contains(tag) {
                rule.removeValue(forKey: key)
                rule["action"] = "reject"
            }
            if let children = rule["rules"] { rule["rules"] = reject(children, key: key, tags: tags) }
            return rule
        }
        route["rules"] = reject(route["rules"] ?? [], key: "outbound", tags: blocked)
        dns["rules"] = reject(dns["rules"] ?? [], key: "server", tags: blockedDNS)
        dns["servers"] = servers.filter { !blockedDNS.contains($0["tag"] as? String ?? "") }
        root["endpoints"] = endpoints.filter { !blocked.contains($0["tag"] as? String ?? "") }
        root["outbounds"] = outbounds.filter { !blocked.contains($0["tag"] as? String ?? "") }
        root["route"] = route
        root["dns"] = dns
        return String(decoding: try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }

    private static func object(_ json: String) throws -> [String: Any] {
        guard let root = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw NSError(domain: "WorkVPN", code: 1, userInfo: [NSLocalizedDescriptionKey: "Профиль должен быть JSON-объектом."])
        }
        return root
    }
}

/// Structured view of a profile's route rules for the rules editor. Only
/// rules that send matching traffic to one outbound are editable here;
/// everything else (sniffing, DNS hijack, nested logic) is kept untouched.
public struct ProfileRulesDocument {
    public struct Choice: Hashable {
        public let tag: String
        public let kind: String
        public let name: String
    }

    public struct Rule {
        public let title: String
        public let detail: String
        public let outbound: String
        /// Plain domain/subnet lists the editor can rewrite.
        public let isSimple: Bool
        public let siteLines: [String]
    }

    private var root: [String: Any]
    private var rules: [[String: Any]]

    public init(json: String) throws {
        guard let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw NSError(domain: "ProfileRules", code: 1, userInfo: [NSLocalizedDescriptionKey: "Профиль не является JSON-объектом"])
        }
        root = object
        rules = (object["route"] as? [String: Any])?["rules"] as? [[String: Any]] ?? []
    }

    public var outboundChoices: [Choice] {
        var result: [Choice] = []
        for section in ["outbounds", "endpoints"] {
            for entry in root[section] as? [[String: Any]] ?? [] {
                guard let tag = entry["tag"] as? String, let kind = entry["type"] as? String, kind != "block", kind != "dns" else { continue }
                result.append(Choice(tag: tag, kind: kind, name: Self.choiceName(tag: tag, kind: kind)))
            }
        }
        return result
    }

    static func choiceName(tag: String, kind: String) -> String {
        switch kind {
        case "direct": return "Напрямую"
        case "selector", "urltest": return "\(tag) (выбор)"
        default: return tag
        }
    }

    public var final: String {
        get { (root["route"] as? [String: Any])?["final"] as? String ?? outboundChoices.first?.tag ?? "" }
        set {
            var route = root["route"] as? [String: Any] ?? [:]
            route["final"] = newValue
            root["route"] = route
        }
    }

    public var editableIndices: [Int] {
        rules.indices.filter { index in
            let rule = rules[index]
            let action = rule["action"] as? String ?? "route"
            return action == "route" && rule["outbound"] is String
        }
    }

    public func rule(at index: Int) -> Rule {
        let rule = rules[index]
        let sets = Self.strings(rule["rule_set"])
        let domains = Self.strings(rule["domain_suffix"]) + Self.strings(rule["domain"])
        let cidrs = Self.strings(rule["ip_cidr"])
        let ssids = Self.strings(rule["wifi_ssid"])
        var titleParts = sets.map(Self.prettySet)
        if titleParts.isEmpty, !domains.isEmpty {
            titleParts = Array(domains.prefix(2)) + (domains.count > 2 ? ["ещё \(domains.count - 2)"] : [])
        }
        if titleParts.isEmpty, !cidrs.isEmpty { titleParts = [cidrs.count == 1 ? cidrs[0] : "\(cidrs.count) подсетей"] }
        if titleParts.isEmpty, rule["ip_is_private"] as? Bool == true { titleParts = ["Локальная сеть"] }
        if titleParts.isEmpty { titleParts = ["Составное правило"] }
        var title = titleParts.joined(separator: ", ")
        if !ssids.isEmpty { title += " · в Wi-Fi \(ssids.joined(separator: ", "))" }
        var detail = (sets.map { "набор \($0)" } + domains + cidrs)
        if detail.isEmpty { detail = rule.keys.filter { !["action", "outbound"].contains($0) }.sorted() }
        let simpleKeys: Set<String> = ["domain_suffix", "ip_cidr", "action", "outbound"]
        let isSimple = Set(rule.keys).isSubset(of: simpleKeys) && !(domains.isEmpty && cidrs.isEmpty)
        return Rule(title: title, detail: detail.joined(separator: ", "), outbound: rule["outbound"] as? String ?? "", isSimple: isSimple, siteLines: domains + cidrs)
    }

    public mutating func setOutbound(_ tag: String, at index: Int) {
        rules[index]["outbound"] = tag
    }

    public mutating func setSites(_ entries: [String], at index: Int) {
        let split = Self.split(entries)
        rules[index]["domain_suffix"] = split.domains.isEmpty ? nil : split.domains
        rules[index]["ip_cidr"] = split.cidrs.isEmpty ? nil : split.cidrs
    }

    public mutating func move(_ index: Int, by offset: Int) {
        let editable = editableIndices
        guard let position = editable.firstIndex(of: index) else { return }
        let target = position + offset
        guard editable.indices.contains(target) else { return }
        rules.swapAt(index, editable[target])
    }

    public mutating func remove(at index: Int) {
        rules.remove(at: index)
    }

    /// New rules go above the existing route rules, so specific sites win.
    public mutating func insertRule(sites entries: [String], outbound: String, dns: Bool) {
        let split = Self.split(entries)
        var rule: [String: Any] = ["action": "route", "outbound": outbound]
        if !split.domains.isEmpty { rule["domain_suffix"] = split.domains }
        if !split.cidrs.isEmpty { rule["ip_cidr"] = split.cidrs }
        rules.insert(rule, at: editableIndices.first ?? rules.count)
        if dns, !split.domains.isEmpty, let server = dnsServer(for: outbound) {
            var dnsSection = root["dns"] as? [String: Any] ?? [:]
            var dnsRules = dnsSection["rules"] as? [[String: Any]] ?? []
            let position = dnsRules.firstIndex { $0["server"] is String } ?? dnsRules.count
            dnsRules.insert(["domain_suffix": split.domains, "action": "route", "server": server], at: position)
            dnsSection["rules"] = dnsRules
            root["dns"] = dnsSection
        }
    }

    /// A DNS server that already sends its queries through this outbound.
    public func dnsServer(for outbound: String) -> String? {
        let servers = (root["dns"] as? [String: Any])?["servers"] as? [[String: Any]] ?? []
        return servers.first { ($0["detour"] as? String) == outbound || ($0["endpoint"] as? String) == outbound }?["tag"] as? String
    }

    public func serialized() throws -> String {
        var output = root
        var route = output["route"] as? [String: Any] ?? [:]
        route["rules"] = rules
        output["route"] = route
        let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    private static func strings(_ value: Any?) -> [String] {
        if let text = value as? String { return [text] }
        return value as? [String] ?? []
    }

    private static func split(_ entries: [String]) -> (domains: [String], cidrs: [String]) {
        var domains: [String] = []
        var cidrs: [String] = []
        for entry in entries {
            let value = entry.trimmingCharacters(in: .whitespaces).lowercased()
                .replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
            let host = value.split(separator: "/").first.map(String.init) ?? value
            if value.contains("/"), host.allSatisfy({ $0.isNumber || $0 == "." || $0 == ":" || $0.isHexDigit }) {
                cidrs.append(value)
            } else if host.allSatisfy({ $0.isNumber || $0 == "." }) {
                cidrs.append(host + "/32")
            } else if !host.isEmpty {
                domains.append(host.hasPrefix(".") ? String(host.dropFirst()) : host)
            }
        }
        return (domains, cidrs)
    }

    private static func prettySet(_ name: String) -> String {
        let known = ["ANTHROPIC": "Claude", "OPENAI": "OpenAI", "YOUTUBE": "YouTube", "TELEGRAM": "Telegram", "TELEGRAM-DOMAINS": "Telegram", "OZON": "Ozon"]
        return known[name] ?? name
    }
}
