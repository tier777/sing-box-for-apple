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

final class WorkVPNConfigurationTests: XCTestCase {
    private let profile = """
    {"outbounds":[{"type":"direct","tag":"DIRECT"},{"type":"hysteria2","tag":"CLAUDE","password":"preserve"},
      {"type":"selector","tag":"WORK","outbounds":["FORTINET","DIRECT"]},
      {"type":"selector","tag":"NESTED","outbounds":["WORK","TAILSCALE"]}],
     "endpoints":[{"type":"tailscale","tag":"TAILSCALE"},{"type":"openconnect","tag":"FORTINET"}],
     "dns":{"servers":[{"type":"dhcp","tag":"LAN"},{"type":"openconnect","tag":"WORK-DNS","endpoint":"FORTINET"}],
       "rules":[{"domain_suffix":["corp.ru"],"action":"route","server":"WORK-DNS"},{"domain_suffix":["ru"],"server":"LAN"}],"final":"LAN"},
     "route":{"rules":[{"action":"sniff"},{"domain_suffix":["corp.ru"],"action":"route","outbound":"WORK"},
       {"type":"logical","mode":"or","rules":[{"ip_cidr":["172.16.20.149/32"]}],"action":"route","outbound":"NESTED"},
       {"rule_set":"ANTHROPIC","action":"route","outbound":"CLAUDE"},
       {"domain_suffix":["ru"],"action":"route","outbound":"DIRECT"}],"final":"TAILSCALE"}}
    """

    func testDisabledWorkRejectsBeforeGeneralRulesAndRemovesClient() throws {
        XCTAssertTrue(try WorkVPNConfiguration.containsWorkVPN(profile))
        let output = try WorkVPNConfiguration.runtime(profile, enabled: false)
        let root = try JSONSerialization.jsonObject(with: Data(output.utf8)) as! [String: Any]
        let rules = (root["route"] as! [String: Any])["rules"] as! [[String: Any]]
        XCTAssertEqual(rules[1]["domain_suffix"] as? [String], ["corp.ru"])
        XCTAssertEqual(rules[1]["action"] as? String, "reject")
        XCTAssertNil(rules[1]["outbound"])
        XCTAssertEqual(rules[2]["action"] as? String, "reject")
        XCTAssertNotNil(rules[2]["rules"], "logical match must survive")
        XCTAssertEqual(rules[3]["outbound"] as? String, "CLAUDE")
        XCTAssertEqual(rules[4]["outbound"] as? String, "DIRECT")
        XCTAssertEqual(((root["route"] as! [String: Any])["final"] as? String), "TAILSCALE")
        XCTAssertEqual((root["outbounds"] as! [[String: Any]]).compactMap { $0["tag"] as? String }, ["DIRECT", "CLAUDE"])
        XCTAssertEqual((root["endpoints"] as! [[String: Any]]).compactMap { $0["tag"] as? String }, ["TAILSCALE"])
        let dns = root["dns"] as! [String: Any]
        let dnsRules = dns["rules"] as! [[String: Any]]
        XCTAssertEqual(dnsRules[0]["action"] as? String, "reject")
        XCTAssertNil(dnsRules[0]["server"])
        XCTAssertEqual(dnsRules[1]["server"] as? String, "LAN")
        XCTAssertEqual((dns["servers"] as! [[String: Any]]).count, 1)
        XCTAssertTrue(output.contains("preserve"), "unrelated credentials must survive")
        XCTAssertFalse(try WorkVPNConfiguration.containsWorkVPN(output))
    }

    func testEnabledConfigurationRemainsExactAndNoWorkIsUnchanged() throws {
        XCTAssertEqual(try WorkVPNConfiguration.runtime(profile, enabled: true), profile)
        XCTAssertEqual(try WorkVPNConfiguration.runtime("{\"outbounds\":[]}", enabled: false), "{\"outbounds\":[]}")
    }

    func testRefusesToRemoveDefaultWorkRouteOrDNS() throws {
        XCTAssertThrowsError(try WorkVPNConfiguration.runtime(profile.replacingOccurrences(of: "\"final\":\"TAILSCALE\"", with: "\"final\":\"WORK\""), enabled: false))
        XCTAssertThrowsError(try WorkVPNConfiguration.runtime(profile.replacingOccurrences(of: "\"final\":\"LAN\"", with: "\"final\":\"WORK-DNS\""), enabled: false))
    }
}

final class TailscaleExitConfigurationTests: XCTestCase {
    private let profile = """
    {"endpoints":[{"type":"tailscale","tag":"YOUTUBE","exit_node":"100.80.1.1","system_interface":false},{"type":"openconnect","tag":"FORTINET"}],"outbounds":[{"type":"hysteria2","tag":"CLAUDE","password":"preserve"}],"route":{"final":"YOUTUBE"}}
    """

    func testSavesStableIdentityAndPreservesOtherConnections() throws {
        let output = try TailscaleExitConfiguration.selecting("chosen", endpointTag: "YOUTUBE", in: profile)
        let original = try JSONSerialization.jsonObject(with: Data(profile.utf8)) as! [String: Any]
        let result = try JSONSerialization.jsonObject(with: Data(output.utf8)) as! [String: Any]
        let endpoints = result["endpoints"] as! [[String: Any]]
        XCTAssertEqual(endpoints[0]["exit_node"] as? String, "id:chosen")
        XCTAssertEqual(endpoints[1]["tag"] as? String, "FORTINET")
        XCTAssertEqual(result["outbounds"] as? NSArray, original["outbounds"] as? NSArray)
        XCTAssertEqual(result["route"] as? NSDictionary, original["route"] as? NSDictionary)
    }

    func testCannotDisableOrChangeAnUnrelatedEndpoint() throws {
        XCTAssertThrowsError(try TailscaleExitConfiguration.selecting("", endpointTag: "YOUTUBE", in: profile))
        XCTAssertThrowsError(try TailscaleExitConfiguration.selecting("chosen", endpointTag: "FORTINET", in: profile))
        XCTAssertThrowsError(try TailscaleExitConfiguration.selecting("chosen", endpointTag: "YOUTUBE", in: profile.replacingOccurrences(of: "\"system_interface\":false", with: "\"system_interface\":true")))
    }
}
