import Foundation

private var failures = 0
private var checks = 0

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() {
        failures += 1
        fputs("FAIL: \(message)\n", stderr)
    }
}

@MainActor
private func runTests() {
    // 1. Registry aliases
    check(GenUIBlockRegistry.kind(for: "stats") == .stats, "stats kind")
    check(GenUIBlockRegistry.kind(for: "node-diagram") == .tree, "node-diagram alias")
    check(GenUIBlockRegistry.kind(for: "clarification") == .form, "clarification alias")
    check(GenUIBlockRegistry.kind(for: "follow-ups") == .proposals, "follow-ups alias")
    check(GenUIBlockRegistry.kind(for: "widget") == .widget, "widget kind")
    check(GenUIBlockRegistry.kind(for: "swift") == nil, "unknown language returns nil")

    // 2. Valid built-in block parsing
    let stats = GenUIBlockParser.parse(
        info: "stats",
        source: #"{"title":"Metrics","items":[{"label":"Users","value":"42","change":"+5%","trend":"up"}]}"#
    )
    if case .stats(let s) = stats {
        check(s.title == "Metrics" && s.items.count == 1 && s.items[0].value == "42", "stats payload decoded")
    } else {
        check(false, "expected .stats")
    }

    let callout = GenUIBlockParser.parse(
        info: "callout",
        source: #"{"type":"warning","title":"Check","message":"Careful"}"#
    )
    if case .callout(let c) = callout {
        check(c.effectiveSeverity == "warning" && c.effectiveBody == "Careful", "callout payload decoded")
    } else {
        check(false, "expected .callout")
    }

    // 3. Invalid JSON graceful fallback
    let invalid = GenUIBlockParser.parse(info: "stats", source: "{not json")
    check(invalid == nil, "invalid JSON falls back to nil")

    // 4. Custom widget parsing + trust manager
    let widget = GenUIBlockParser.parse(
        info: "widget",
        source: #"{"title":"3D Chart","height":320,"html":"<canvas></canvas>","script":"console.log(1)"}"#
    )
    if case .widget(let w) = widget {
        check(w.title == "3D Chart" && w.height == 320, "widget payload decoded")
    } else {
        check(false, "expected .widget")
    }

    let suiteName = "com.pixerate.swash.genui.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let trust = WidgetTrustManager(userDefaults: defaults)
    check(!trust.isTrusted(documentKey: "/tmp/doc.md"), "untrusted by default")
    trust.grantTrust(for: "/tmp/doc.md")
    check(trust.isTrusted(documentKey: "/tmp/doc.md"), "trusted after grant")
    trust.revokeTrust(for: "/tmp/doc.md")
    check(!trust.isTrusted(documentKey: "/tmp/doc.md"), "untrusted after revoke")
    defaults.removePersistentDomain(forName: suiteName)
}

MainActor.assumeIsolated {
    runTests()
}

if failures > 0 {
    fputs("\(failures)/\(checks) checks failed\n", stderr)
    exit(1)
}
print("\(checks)/\(checks) GenUI checks passed")
