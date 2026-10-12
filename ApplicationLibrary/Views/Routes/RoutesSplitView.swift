#if os(macOS)
import Library
import SwiftUI

public enum RoutesPage: Hashable {
    case overview
    case connection(String)
    case profiles
    case page(NavigationPage)
}

/// Main window of the local-engine build: connections in the sidebar, the way
/// System Settings lists network services, and their details on the right.
@MainActor
public struct RoutesSplitView: View {
    @EnvironmentObject private var environments: ExtensionEnvironments
    @EnvironmentObject private var model: RouteHealthViewModel
    @Binding private var upstreamSelection: NavigationPage
    @Binding private var settingsPath: NavigationPath
    @StateObject private var profiles = RoutesProfileStore()
    @State private var page: RoutesPage? = .overview
    @State private var alert: AlertState?
    @State private var loginTag: String?

    public init(upstreamSelection: Binding<NavigationPage>, settingsPath: Binding<NavigationPath>) {
        _upstreamSelection = upstreamSelection
        _settingsPath = settingsPath
    }

    public var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 280)
        } detail: {
            NavigationStack(path: $settingsPath) {
                detail
            }
        }
        .toolbar { toolbar }
        .alert($alert)
        .task { await profiles.reload() }
        .onReceive(environments.profileUpdate) { _ in Task { await profiles.reload() } }
        .onReceive(environments.selectedProfileUpdate) { _ in Task { await profiles.reload() } }
        .onChangeCompat(of: upstreamSelection) { value in
            // Upstream code (menu bar, deep links) still navigates by NavigationPage.
            if value != .dashboard, page != .page(value) { page = .page(value) }
        }
        .onChangeCompat(of: page) { value in
            let current = value ?? .overview
            if case let .page(upstream) = current { upstreamSelection = upstream } else { upstreamSelection = .dashboard }
            if current != .page(.settings) { settingsPath = NavigationPath() }
        }
        .sheet(item: Binding(get: { loginTag.map(LoginTag.init) }, set: { loginTag = $0?.id })) { login in
            NavigationStackCompat {
                OpenConnectEndpointView(viewModel: model.openConnect, endpointTag: login.id)
                    .toolbar { ToolbarItem { Button("Готово") { loginTag = nil } } }
            }.frame(minWidth: 440, minHeight: 340)
        }
    }

    private var sidebar: some View {
        List(selection: $page) {
            Label("Обзор", systemImage: "square.grid.2x2").tag(RoutesPage.overview)
            Section("Подключения") {
                if model.connections.isEmpty {
                    Text("Появятся после включения VPN").foregroundStyle(.secondary).font(.callout)
                }
                ForEach(model.connections) { route in
                    HStack {
                        Label(route.displayName, systemImage: route.systemImage)
                        Spacer()
                        StatusSymbol(tier: model.tier(for: route))
                    }
                    .tag(RoutesPage.connection(route.tag))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(route.displayName), \(model.state(for: route).title(for: route))")
                }
            }
            Section("Ещё") {
                Label("Профили", systemImage: "doc.text").badge(profiles.list.count).tag(RoutesPage.profiles)
                if environments.extensionProfile?.status.isConnectedStrict == true {
                    Label("Соединения", systemImage: "list.bullet.rectangle.portrait").tag(RoutesPage.page(.connections))
                }
                Label("Журнал", systemImage: "list.bullet.rectangle").tag(RoutesPage.page(.logs))
                Label("Инструменты", systemImage: "wrench.and.screwdriver").tag(RoutesPage.page(.tools))
                Label("Настройки", systemImage: "gearshape").tag(RoutesPage.page(.settings))
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var detail: some View {
        switch page ?? .overview {
        case .overview:
            RoutesOverviewView(page: $page, perform: perform).navigationTitle("Обзор")
        case let .connection(tag):
            RouteConnectionView(tag: tag).id(tag)
        case .profiles:
            RoutesProfilesView(store: profiles).navigationTitle("Профили")
        case let .page(upstream):
            upstream.contentView.navigationTitle(upstream.title)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker("Профиль", selection: Binding(get: { profiles.selectedID }, set: { switchProfile($0) })) {
                    ForEach(profiles.list, id: \.mustID) { Text($0.name).tag($0.mustID) }
                }
                .pickerStyle(.inline)
                Divider()
                Button("Изменить профили…") { page = .profiles }
            } label: {
                // Profile names can be long; the toolbar must keep the switch visible.
                Text(profiles.selectedName).lineLimit(1).frame(maxWidth: 180)
            }
            .help("Профиль")
            .disabled(profiles.list.isEmpty)
        }
        ToolbarItem(placement: .primaryAction) {
            Button { model.checkNow() } label: {
                Label("Проверить", systemImage: "arrow.clockwise")
            }
            .labelStyle(.titleAndIcon)
            .help("Заново проверить все подключения (⌘R)")
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!model.enabled || !model.checking.isEmpty)
        }
        ToolbarItem(placement: .primaryAction) {
            if let profile = environments.extensionProfile {
                VPNSwitch(onError: { alert = $0 }).environmentObject(profile)
            }
        }
    }

    private func perform(_ action: OverviewHeadline.Action) {
        switch action {
        case .setupEngine: model.installEngine()
        case .start: Task { await setVPN(true) }
        case .stop: Task { await setVPN(false) }
        case .ruleMode: Task.detached { try? CommandTarget.standaloneClient().setClashMode("rule") }
        case let .open(tag): page = .connection(tag)
        case let .login(tag): loginTag = tag
        }
    }

    private func setVPN(_ on: Bool) async {
        guard let profile = environments.extensionProfile else { return }
        do {
            if on { try await profile.start(); environments.commandClient.connect() } else { try await profile.stop() }
        } catch {
            alert = AlertState(action: on ? "start service" : "stop service", error: error)
        }
    }

    private func switchProfile(_ id: Int64) {
        guard id != profiles.selectedID else { return }
        Task {
            await SharedPreferences.selectedProfileID.set(id)
            profiles.selectedID = id
            environments.selectedProfileUpdate.send()
            // Reload in place: the engine keeps leak protection armed across it.
            if let profile = environments.extensionProfile, profile.status.isConnected {
                do { try await profile.reloadService() } catch { alert = AlertState(action: "reload service", error: error) }
            }
        }
    }
}

private struct LoginTag: Identifiable { let id: String }

/// The VPN on/off switch. It stays on while leak protection is armed, even
/// if the engine is recovering: off is only ever the person's own choice.
private struct VPNSwitch: View {
    @EnvironmentObject private var environments: ExtensionEnvironments
    @EnvironmentObject private var profile: ExtensionProfile
    @EnvironmentObject private var model: RouteHealthViewModel
    let onError: (AlertState) -> Void
    @State private var busy = false

    var body: some View {
        Toggle(isOn: Binding(get: { profile.status.isConnected || model.leakProtection?.armed == true }, set: set)) {
            Text("VPN")
        }
        .toggleStyle(.switch)
        .disabled(busy || model.needsEngineSetup || environments.emptyProfiles)
        .help("Включить или выключить VPN")
    }

    private func set(_ on: Bool) {
        busy = true
        Task {
            defer { busy = false }
            do {
                if on { try await profile.start(); environments.commandClient.connect() } else { try await profile.stop() }
            } catch {
                onError(AlertState(action: on ? "start service" : "stop service", error: error))
            }
        }
    }
}

@MainActor
final class RoutesProfileStore: ObservableObject {
    @Published var list: [Profile] = []
    @Published var selectedID: Int64 = 0

    var selectedName: String { list.first { $0.mustID == selectedID }?.name ?? "Нет профиля" }

    func reload() async {
        list = (try? await ProfileManager.list()) ?? []
        selectedID = await SharedPreferences.selectedProfileID.get()
        if !list.isEmpty, !list.contains(where: { $0.mustID == selectedID }) {
            selectedID = list[0].mustID
            await SharedPreferences.selectedProfileID.set(selectedID)
        }
    }
}
#endif
