import Foundation
import XCTest
@testable import RouteHealthCore

final class RouteHealthStateTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1000)
    func state(enabled: Bool = true, sleeping: Bool = false, network: Bool? = true, telemetry: Bool = true, endpoint: String? = nil, configured: Bool = true, checking: Bool = false, reachable: Bool = true, age: Double = 1) -> RouteHealthState {
        .evaluate(enabled: enabled, sleeping: sleeping, networkAvailable: network, telemetryFresh: telemetry, endpointState: endpoint, targetConfigured: configured, checking: checking, snapshot: .init(reachable: reachable, checkedAt: now.addingTimeInterval(-age)), now: now)
    }
    func testFreshProbeIsRequired() {
        XCTAssertEqual(state(), .verified)
        XCTAssertEqual(state(age: 46), .stale)
        XCTAssertEqual(state(age: -10), .stale)
        XCTAssertEqual(state(reachable: false), .failed)
        XCTAssertEqual(state(checking: true), .checking)
    }
    func testLifecycleOverridesOldSuccess() {
        XCTAssertEqual(state(enabled: false), .stopped)
        XCTAssertEqual(state(sleeping: true), .sleeping)
        XCTAssertEqual(state(network: false), .noNetwork)
        XCTAssertEqual(state(telemetry: false), .telemetryLost)
        XCTAssertEqual(state(endpoint: "Starting"), .reconnecting)
        XCTAssertEqual(state(endpoint: "exit-offline"), .reconnecting)
        XCTAssertEqual(state(endpoint: "NeedsLogin"), .authentication)
        XCTAssertEqual(state(endpoint: "auth-pending"), .authentication)
        XCTAssertEqual(state(endpoint: "Running"), .verified)
        XCTAssertEqual(state(endpoint: "error"), .failed)
        XCTAssertEqual(state(endpoint: "Stopped"), .stopped)
    }
    func testWorkDoesNotPretendPublicProbeProvesInternalReachability() {
        XCTAssertEqual(state(configured: false), .unconfigured)
        XCTAssertEqual(state(endpoint: "auth-pending", configured: false), .authentication)
    }
    func testEmptyProtoFieldsDecode() throws {
        let catalog = try JSONDecoder().decode(RouteCatalog.self, from: Data(#"{"routes":[{"tag":"VPN","type":"hysteria2"}]}"#.utf8))
        XCTAssertEqual(catalog.routes?.first?.directFallback, false)
        XCTAssertEqual(catalog.routes?.first?.destinations, [])
    }
}
