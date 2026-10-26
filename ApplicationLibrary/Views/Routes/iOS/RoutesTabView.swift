#if os(iOS)
import Library
import SwiftUI

public enum RoutesTab: String, Hashable {
    case overview, profiles, settings
}

struct ConnectionLink: Hashable { let tag: String }

/// iPhone layout of the Routes app: three top-level sections in a tab bar,
/// details pushed inside each section's own navigation stack.
@available(iOS 16.0, *)
public struct RoutesTabView: View {
    @ObservedObject private var board: RoutesBoard
    @State private var tab: RoutesTab

    public init(board: RoutesBoard, tab: RoutesTab = .overview) {
        self.board = board
        _tab = State(initialValue: tab)
    }

    public var body: some View {
        TabView(selection: $tab) {
            NavigationStack { RoutesOverviewMobileView() }
                .tabItem { Label("Обзор", systemImage: "square.grid.2x2.fill") }
                .tag(RoutesTab.overview)
            NavigationStack { RoutesProfilesMobileView() }
                .tabItem { Label("Профили", systemImage: "doc.text.fill") }
                .tag(RoutesTab.profiles)
            NavigationStack { RoutesSettingsMobileView() }
                .tabItem { Label("Настройки", systemImage: "gearshape.fill") }
                .tag(RoutesTab.settings)
        }
        .environmentObject(board)
    }
}

@available(iOS 16.0, *)
struct RoutesOverviewMobileView: View {
    @EnvironmentObject private var board: RoutesBoard

    var body: some View {
        List {
            summarySection
            Section {
                Toggle("VPN", isOn: $board.enabled)
                Picker("Профиль", selection: $board.activeProfileID) {
                    ForEach(board.profiles) { Text($0.name).tag($0.id) }
                }
            } footer: {
                Text("Демо-данные: туннель в этой сборке не запускается.")
            }
            Section("Подключения") {
                ForEach(board.connections) { route in
                    NavigationLink(value: ConnectionLink(tag: route.tag)) {
                        ConnectionMobileRow(route: route)
                    }
                }
            }
            if board.enabled {
                Section("Сайты") {
                    ForEach(Array(board.sites.enumerated()), id: \.offset) { _, site in
                        SiteMobileRow(site: site)
                    }
                }
            }
        }
        .navigationTitle("Обзор")
        .navigationDestination(for: ConnectionLink.self) { RouteDetailMobileView(tag: $0.tag) }
        .refreshable { await board.refresh() }
    }

    private var summarySection: some View {
        let summary = board.summary
        return Section {
            HStack(spacing: 12) {
                StatusSymbol(tier: summary.tier, size: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(summary.title).font(.title3.weight(.semibold))
                    if let detail = summary.detail {
                        Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            if let title = summary.actionTitle, let action = summary.action {
                Button(title) { board.perform(action) }
            }
        }
    }
}

@available(iOS 16.0, *)
struct ConnectionMobileRow: View {
    @EnvironmentObject private var board: RoutesBoard
    let route: RouteDescriptor

    var body: some View {
        let state = board.state(for: route)
        HStack(spacing: 12) {
            Image(systemName: route.systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.accentColor))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(route.displayName)
                Text(subtitle(state)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            // With the VPN off every row would repeat "Выключено"; the summary says it once.
            if board.enabled {
                HStack(spacing: 5) {
                    StatusSymbol(tier: state.tier(for: route), size: 15)
                    Text(state.title(for: route)).foregroundStyle(.secondary).lineLimit(1)
                }
                .fixedSize()
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func subtitle(_ state: RouteHealthState) -> String {
        switch state {
        case .verified:
            guard let snapshot = board.snapshot(for: route) else { return route.kindTitle }
            return ([snapshot.country] + ["\(snapshot.latencyMs) мс"]).filter { !$0.isEmpty }.joined(separator: " · ")
        case .failed: return "нет ответа"
        default: return route.isWork ? "Рабочий VPN" : route.kindTitle
        }
    }
}

@available(iOS 16.0, *)
struct SiteMobileRow: View {
    @EnvironmentObject private var board: RoutesBoard
    let site: SiteRoute

    var body: some View {
        let route = board.route(tag: site.viaTag)
        let tier = route.map { board.tier(for: $0) } ?? .off
        HStack(spacing: 8) {
            Text(site.name).lineLimit(1)
            Spacer(minLength: 8)
            Text(route?.displayName ?? site.viaTag).foregroundStyle(.secondary)
            StatusSymbol(tier: tier, size: 15)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(site.name), через \(route?.displayName ?? site.viaTag), \(siteStatus(tier))")
    }

    private func siteStatus(_ tier: ConnectionTier) -> String {
        switch tier {
        case .ok: "доступен"
        case .progress: "проверяется"
        case .action: "ждёт входа"
        case .fail: "недоступен"
        case .off: "подключение не активно"
        }
    }
}
#endif
