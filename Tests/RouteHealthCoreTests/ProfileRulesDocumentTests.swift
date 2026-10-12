@testable import RouteHealthCore
import XCTest

final class ProfileRulesDocumentTests: XCTestCase {
    private let profile = """
    {"inbounds":[{"type":"tun","tag":"TUN","address":["172.19.0.1/30"]}],
     "outbounds":[{"type":"direct","tag":"DIRECT"},{"type":"hysteria2","tag":"HAPP","server":"x"},{"type":"selector","tag":"WORK","outbounds":["FORTINET","DIRECT"]}],
     "endpoints":[{"type":"tailscale","tag":"TAILSCALE","detour":"HAPP"},{"type":"openconnect","tag":"FORTINET"}],
     "dns":{"servers":[{"type":"dhcp","tag":"LAN"},{"type":"https","tag":"HAPP-DNS","server":"1.1.1.1","detour":"HAPP"}],"rules":[{"rule_set":"ANTHROPIC","action":"route","server":"HAPP-DNS"}]},
     "route":{"rules":[{"action":"sniff"},{"protocol":"dns","action":"hijack-dns"},
       {"wifi_ssid":["office"],"domain_suffix":["corp.example"],"action":"route","outbound":"DIRECT"},
       {"rule_set":"ANTHROPIC","action":"route","outbound":"HAPP"},
       {"domain_suffix":["ru"],"action":"route","outbound":"DIRECT"}],"final":"DIRECT"}}
    """

    func testOnlyRouteRulesAreEditableAndOthersSurvive() throws {
        var document = try ProfileRulesDocument(json: profile)
        XCTAssertEqual(document.editableIndices, [2, 3, 4])
        XCTAssertEqual(document.rule(at: 3).title, "Claude")
        XCTAssertFalse(document.rule(at: 3).isSimple)
        XCTAssertTrue(document.rule(at: 4).isSimple)
        XCTAssertTrue(document.rule(at: 2).title.contains("в Wi-Fi office"))
        XCTAssertEqual(document.outboundChoices.map(\.tag), ["DIRECT", "HAPP", "WORK", "TAILSCALE", "FORTINET"])

        document.setOutbound("TAILSCALE", at: 3)
        document.move(4, by: -1)
        let output = try ProfileRulesDocument(json: try document.serialized())
        XCTAssertEqual(output.rule(at: 3).title, "ru")
        XCTAssertEqual(output.rule(at: 4).outbound, "TAILSCALE")
        let json = try document.serialized()
        XCTAssertTrue(json.contains("hijack-dns"), "non-editable rules must be preserved")
        XCTAssertTrue(json.contains("\"server\" : \"x\""), "outbound settings must be preserved")
    }

    func testNewRuleGoesFirstWithMatchingDNS() throws {
        var document = try ProfileRulesDocument(json: profile)
        XCTAssertEqual(document.dnsServer(for: "HAPP"), "HAPP-DNS")
        XCTAssertNil(document.dnsServer(for: "FORTINET"))
        document.insertRule(sites: ["https://GitHub.com/login", ".githubusercontent.com", "140.82.112.0/20", "1.2.3.4"], outbound: "HAPP", dns: true)
        let rule = document.rule(at: 2)
        XCTAssertEqual(rule.outbound, "HAPP")
        XCTAssertEqual(rule.siteLines, ["github.com", "githubusercontent.com", "140.82.112.0/20", "1.2.3.4/32"])
        let json = try document.serialized()
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let dnsRules = (object["dns"] as! [String: Any])["rules"] as! [[String: Any]]
        XCTAssertEqual(dnsRules.first?["server"] as? String, "HAPP-DNS")
        XCTAssertEqual(dnsRules.first?["domain_suffix"] as? [String], ["github.com", "githubusercontent.com"])
    }

    func testFinalOutbound() throws {
        var document = try ProfileRulesDocument(json: profile)
        XCTAssertEqual(document.final, "DIRECT")
        document.final = "HAPP"
        XCTAssertTrue(try document.serialized().contains("\"final\" : \"HAPP\""))
    }
}
