#if os(macOS)
import Library
import SwiftUI

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
