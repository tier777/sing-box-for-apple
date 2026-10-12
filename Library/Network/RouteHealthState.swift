import Foundation

public struct RouteDescriptor: Decodable, Identifiable, Equatable, Sendable {
    public var id: String { tag }
    public let tag: String
    public let type: String
    public let bindInterface: String
    public let detour: String
    public let destinations: [String]
    public let directFallback: Bool

    enum CodingKeys: String, CodingKey { case tag, type, bindInterface, detour, destinations, directFallback }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        tag = try values.decode(String.self, forKey: .tag)
        type = try values.decode(String.self, forKey: .type)
        bindInterface = try values.decodeIfPresent(String.self, forKey: .bindInterface) ?? ""
        detour = try values.decodeIfPresent(String.self, forKey: .detour) ?? ""
        destinations = try values.decodeIfPresent([String].self, forKey: .destinations) ?? []
        directFallback = try values.decodeIfPresent(Bool.self, forKey: .directFallback) ?? false
    }

    public var isGroup: Bool { type == "selector" || type == "urltest" }
    public var isDirect: Bool { type == "direct" }
    public var isWork: Bool { type == "openconnect" || type == "openvpn" }
}

public struct RouteCatalog: Decodable, Sendable {
    public let routes: [RouteDescriptor]?
    public let startedAt: Int64?
}

public struct RouteProbeSnapshot: Equatable, Sendable {
    public let reachable: Bool
    public let checkedAt: Date
    public let latencyMs: Int64
    public let httpStatus: Int32
    public let stage: String
    public let error: String
    public let exitIP: String
    public let country: String
    public init(reachable: Bool, checkedAt: Date, latencyMs: Int64 = 0, httpStatus: Int32 = 0, stage: String = "", error: String = "", exitIP: String = "", country: String = "") {
        self.reachable = reachable; self.checkedAt = checkedAt; self.latencyMs = latencyMs
        self.httpStatus = httpStatus; self.stage = stage; self.error = error
        self.exitIP = exitIP; self.country = country
    }
}

public enum RouteHealthState: String, Sendable {
    case stopped, sleeping, noNetwork, telemetryLost, authentication, reconnecting, unconfigured, checking, verified, failed, stale

    // Lifecycle / authentication always beats a previous successful probe.
    // No traffic is deliberately absent: a healthy connection may be idle.
    public static func evaluate(enabled: Bool, sleeping: Bool, networkAvailable: Bool?, telemetryFresh: Bool, endpointState: String?, targetConfigured: Bool, checking: Bool, snapshot: RouteProbeSnapshot?, now: Date) -> Self {
        if !enabled { return .stopped }
        if sleeping { return .sleeping }
        if networkAvailable == false { return .noNetwork }
        if !telemetryFresh { return .telemetryLost }
        if ["auth-pending", "NeedsLogin", "NeedsMachineAuth"].contains(endpointState ?? "") { return .authentication }
        if endpointState == "error" { return .failed }
        if endpointState == "Stopped" { return .stopped }
        if let endpointState, !["connected", "Running"].contains(endpointState) { return .reconnecting }
        if !targetConfigured { return .unconfigured }
        if checking { return .checking }
        guard let snapshot else { return .stale }
        if now.timeIntervalSince(snapshot.checkedAt) > 45 || snapshot.checkedAt > now.addingTimeInterval(2) { return .stale }
        return snapshot.reachable ? .verified : .failed
    }
}
