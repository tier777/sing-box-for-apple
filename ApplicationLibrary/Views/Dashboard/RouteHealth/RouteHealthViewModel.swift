import Combine
import Foundation
import Libbox
import Library
import Network
import SwiftUI
#if os(macOS)
import AppKit
#endif

@MainActor
public final class RouteHealthViewModel: ObservableObject {
    @Published public var routes: [RouteDescriptor] = []
    @Published public var snapshots: [String: RouteProbeSnapshot] = [:]
    @Published public var checking: Set<String> = []
    @Published public var networkAvailable: Bool?
    @Published public var networkInterfaces = "Проверяем сеть…"
    @Published public var sleeping = false
    @Published public var now = Date()
    @Published public var catalogError: String?
    @Published public var targets: [String: String] = [:]
    @Published public var installingEngine = false
    public let openConnect = OpenConnectStatusViewModel()
    private weak var environments: ExtensionEnvironments?
    private weak var tailscale: TailscaleStatusViewModel?
    private let pathMonitor = NWPathMonitor()
    private var subscriptions: Set<AnyCancellable> = []
    private var loop: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var lastProbeAt = Date.distantPast
    private var lastRetryAt = Date.distantPast
    private var serviceStartedAt: Int64?
    private var catalogLoading = false
    private var wasEnabled = false
    private var observedNetworkEpoch: Int64 = 0
    private var endpointSignatures: [String: String] = [:]
    private var probeTasks: [Task<Void, Never>] = []

    public init() {}

    public func start(environments: ExtensionEnvironments, tailscale: TailscaleStatusViewModel) {
        guard self.environments == nil else { return }
        self.environments = environments
        self.tailscale = tailscale
        targets = UserDefaults.standard.dictionary(forKey: "route-health-targets") as? [String: String] ?? [:]
        openConnect.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        tailscale.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        tailscale.$endpoints.dropFirst().sink { [weak self] endpoints in
            let signatures = Dictionary(uniqueKeysWithValues: endpoints.map { endpoint in
                (endpoint.endpointTag, "\(endpoint.backendState)|\(endpoint.selfPeer?.stableID ?? "")|\(endpoint.selfPeer?.expired ?? true)|\(endpoint.selfPeer?.tailscaleIPs.joined(separator: ",") ?? "")|\(endpoint.exitNode?.stableID ?? "")|\(endpoint.exitNode?.online ?? false)|\(endpoint.exitNode?.expired ?? false)")
            })
            self?.updateEndpointSignatures(signatures, type: "tailscale")
        }.store(in: &subscriptions)
        openConnect.$endpoints.dropFirst().sink { [weak self] endpoints in
            let signatures = Dictionary(uniqueKeysWithValues: endpoints.map {
                ($0.endpointTag, "\($0.state)|\($0.authChallenge?.id ?? "")|\($0.tunnelInfo?.connectedSince ?? 0)")
            })
            self?.updateEndpointSignatures(signatures, type: "openconnect")
        }.store(in: &subscriptions)
        environments.commandClient.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        environments.selectedProfileUpdate.sink { [weak self] _ in self?.invalidate("Профиль изменён — перепроверяем маршруты") }.store(in: &subscriptions)
        environments.commandClient.$isConnected.dropFirst().sink { [weak self] _ in self?.invalidate(nil) }.store(in: &subscriptions)
        environments.commandClient.$groups.dropFirst().sink { [weak self] groups in
            self?.updateEndpointSignatures(Dictionary(uniqueKeysWithValues: (groups ?? []).map { ($0.tag, $0.selected) }), type: "selection")
        }.store(in: &subscriptions)
        environments.commandClient.$clashMode.dropFirst().sink { [weak self] _ in self?.invalidate(nil) }.store(in: &subscriptions)
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            let interfaces = path.availableInterfaces.map(\.name).joined(separator: ", ")
            Task { @MainActor in
                guard let self else { return }
                self.networkAvailable = available
                self.networkInterfaces = available ? "Сеть доступна · \(interfaces)" : "Система не видит доступной сети"
                self.invalidate(nil)
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "sfm.route-health.path"))
        #if os(macOS)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification).sink { [weak self] _ in
            Task { @MainActor in self?.sleeping = true; self?.invalidate("Mac спит") }
        }.store(in: &subscriptions)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification).sink { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.sleeping = false
                self.invalidate("После сна — проверяем подключения")
                self.environments?.commandClient.reconnect()
                self.openConnect.cancel()
                self.tailscale?.cancel()
                if Variant.useLocalEngine {
                    Task {
                        _ = await Task.detached { try? LocalEngine.wake() }.value
                        self.invalidate("Движок восстановил сеть после сна — проверяем заново")
                    }
                }
            }
        }.store(in: &subscriptions)
        #endif
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(nanoseconds: NSEC_PER_SEC)
            }
        }
    }

    public var enabled: Bool { environments?.extensionProfile?.status.isStarted == true }
    #if os(macOS)
    public var needsEngineSetup: Bool { Variant.useLocalEngine && !LocalEngine.isAvailable }
    public func installEngine() {
        guard !installingEngine else { return }
        installingEngine = true
        Task {
            defer { installingEngine = false }
            do {
                try await Task.detached { try LocalEngine.install() }.value
                for _ in 0..<15 {
                    if await Task.detached(operation: { (try? LocalEngine.state()) != nil }).value {
                        catalogError = "Движок готов. Запусти выбранный профиль кнопкой Start."; return
                    }
                    try await Task.sleep(nanoseconds: NSEC_PER_SEC)
                }
                catalogError = "Движок не ответил после установки. VPN не запускался."
            } catch { catalogError = error.localizedDescription }
        }
    }
    #endif
    public var telemetryFresh: Bool {
        if environments?.extensionProfile?.localEngineStateUnknown == true { return false }
        guard let client = environments?.commandClient, client.isConnected, let at = client.lastStatusAt else { return false }
        return now.timeIntervalSince(at) < 5
    }

    public func tailscaleModel() -> TailscaleStatusViewModel? { tailscale }

    public func target(for route: RouteDescriptor) -> String {
        if let custom = targets[route.tag] { return custom }
        let selected = routes.first { $0.tag == selectedOutbound(for: route) }
        return route.isWork || selected?.isWork == true ? "" : "https://www.cloudflare.com/cdn-cgi/trace"
    }

    public func selectedOutbound(for route: RouteDescriptor) -> String {
        environments?.commandClient.groups?.first { $0.tag == route.tag }?.selected ?? ""
    }

    public func setTarget(_ value: String, for route: RouteDescriptor) -> Bool {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return false }
        targets[route.tag] = value
        UserDefaults.standard.set(targets, forKey: "route-health-targets")
        invalidate(nil)
        checkNow()
        return true
    }

    public func endpointState(for route: RouteDescriptor) -> String? {
        if route.isGroup {
            guard let selected = routes.first(where: { $0.tag == selectedOutbound(for: route) }) else { return "unknown" }
            // Nested groups are diagnosed through their probe; never recurse
            // indefinitely on a malformed configuration.
            return selected.isGroup ? nil : endpointState(for: selected)
        }
        if route.type == "tailscale" {
            guard let endpoint = tailscale?.endpoint(tag: route.tag) else { return "unknown" }
            if endpoint.backendState != "Running" { return endpoint.backendState }
            if endpoint.selfPeer?.expired == true || endpoint.selfPeer?.tailscaleIPs.isEmpty != false { return "reconnecting" }
            if let exit = endpoint.exitNode, !exit.online || exit.expired { return "exit-offline" }
            return endpoint.backendState
        }
        if route.type == "openconnect" { return openConnect.endpoint(tag: route.tag)?.state ?? "unknown" }
        return nil
    }

    public func state(for route: RouteDescriptor) -> RouteHealthState {
        RouteHealthState.evaluate(enabled: enabled, sleeping: sleeping, networkAvailable: networkAvailable, telemetryFresh: telemetryFresh, endpointState: endpointState(for: route), targetConfigured: !target(for: route).isEmpty, checking: checking.contains(route.tag), snapshot: snapshots[route.tag], now: now)
    }

    public func endpointError(for route: RouteDescriptor) -> String {
        if route.type == "openconnect" { return openConnect.endpoint(tag: route.tag)?.error ?? "" }
        return ""
    }

    private func updateEndpointSignatures(_ values: [String: String], type: String) {
        let prefix = type + ":"
        let old = endpointSignatures.filter { $0.key.hasPrefix(prefix) }
        let new = Dictionary(uniqueKeysWithValues: values.map { (prefix + $0.key, $0.value) })
        guard old != new else { return }
        endpointSignatures = endpointSignatures.filter { !$0.key.hasPrefix(prefix) }.merging(new) { _, new in new }
        invalidate(nil)
    }

    public var diagnosis: String {
        if environments?.extensionProfile?.localEngineStateUnknown == true { return "Состояние движка неизвестно. Нельзя подтвердить, что VPN работает или выключен. " + (environments?.extensionProfile?.localEngineError ?? "") }
        if !enabled { return "Туннель выключен. Защита маршрутов VPN сейчас не действует." }
        if sleeping { return "Подключения приостановлены на время сна." }
        if environments?.commandClient.clashMode.lowercased() == "direct" {
            return "Включён режим DIRECT. Правила сайтов могут обходиться: успешная проверка отдельного VPN не означает, что Claude использует его. Верни режим rule перед открытием защищённых сайтов."
        }
        if networkAvailable == false { return "Нет доступной сети. Сначала проверь Wi-Fi или Ethernet." }
        if !telemetryFresh { return "Нет свежего ответа движка. Предыдущие успешные проверки больше не подтверждают связь." }
        let direct = routes.filter(\.isDirect).contains { state(for: $0) == .verified }
        let failedVPN = routes.filter { !$0.isDirect }.contains { state(for: $0) == .failed }
        if direct && failedVPN { return "Прямой интернет отвечает, но один из VPN не проходит проверку. Переключать Wi-Fi пока нет оснований." }
        if routes.contains(where: { $0.isDirect && state(for: $0) == .failed }) { return "Прямая HTTPS-проверка не прошла. Возможна проблема сети, DNS или адреса проверки — это ещё не доказывает неисправность Wi-Fi." }
        return "Нулевой трафик бывает при простое. Работоспособность определяем по свежим HTTPS-проверкам каждого маршрута." }

    public func checkNow() {
        guard enabled, !sleeping, telemetryFresh, checking.isEmpty else { return }
        lastProbeAt = now
        let token = generation
        for route in routes where !target(for: route).isEmpty {
            if let endpoint = endpointState(for: route), !["Running", "connected"].contains(endpoint) { continue }
            checking.insert(route.tag)
            let tag = route.tag, url = target(for: route)
            let task = Task { [weak self] in
                let result: RouteProbeSnapshot
                do {
                    result = try await Task.detached {
                        let client = try CommandTarget.ownedStandaloneClient()
                        defer { try? client.disconnect() }
                        let value = try client.probeRoute(tag, targetURL: url)
                        return RouteProbeSnapshot(reachable: value.reachable, checkedAt: Date(timeIntervalSince1970: Double(value.checkedAt) / 1000), latencyMs: value.latencyMs, httpStatus: value.httpStatus, stage: value.stage, error: value.error, exitIP: value.exitIP, country: value.country)
                    }.value
                } catch {
                    result = RouteProbeSnapshot(reachable: false, checkedAt: Date(), stage: "service", error: error.localizedDescription)
                }
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.snapshots[tag] = result
                self.checking.remove(tag)
            }
            probeTasks.append(task)
        }
    }

    public func invalidate(_ reason: String?) {
        generation &+= 1
        probeTasks.forEach { $0.cancel() }
        probeTasks.removeAll()
        checking.removeAll()
        snapshots.removeAll()
        lastProbeAt = .distantPast
        if let reason { catalogError = reason }
    }

    private func tick() {
        now = Date()
        let epoch = environments?.extensionProfile?.localEngineNetworkEpoch ?? 0
        if epoch != observedNetworkEpoch { observedNetworkEpoch = epoch; invalidate("Сеть движка перезапущена — нужны свежие проверки") }
        if enabled != wasEnabled {
            wasEnabled = enabled
            invalidate(nil)
            if !enabled { openConnect.cancel(); tailscale?.cancel() }
        }
        guard enabled, !sleeping else { return }
        if !telemetryFresh {
            if now.timeIntervalSince(lastRetryAt) > 10 {
                lastRetryAt = now
                environments?.commandClient.reconnect()
            }
            return
        }
        if !openConnect.isSubscribed { openConnect.subscribe() }
        if tailscale?.isSubscribed == false { tailscale?.subscribe() }
        if !catalogLoading, now.timeIntervalSince(lastProbeAt) > 30, checking.isEmpty {
            refreshCatalogAndCheck()
        }
    }

    private func refreshCatalogAndCheck() {
        catalogLoading = true
        let token = generation
        Task { [weak self] in
            defer { self?.catalogLoading = false }
            do {
                let catalog = try await Task.detached {
                    let client = try CommandTarget.ownedStandaloneClient()
                    defer { try? client.disconnect() }
                    var error: NSError?
                    let json = client.getRouteCatalog(&error)
                    if let error { throw error }
                    return try JSONDecoder().decode(RouteCatalog.self, from: Data(json.utf8))
                }.value
                guard let self, generation == token else { return }
                if serviceStartedAt != catalog.startedAt { invalidate(nil); serviceStartedAt = catalog.startedAt }
                routes = catalog.routes ?? []
                catalogError = nil
                checkNow()
            } catch {
                guard let self, generation == token else { return }
                catalogError = "Не удалось получить активные маршруты: \(error.localizedDescription)"
                lastProbeAt = now
            }
        }
    }
}
