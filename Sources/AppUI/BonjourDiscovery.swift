import Foundation
import Observation
import TransportCore

/// Main-actor view model over `BonjourBrowser` for the Viewer's "Nearby Macs" list.
///
/// Discovery is a convenience only (PRD §4): a result carries just the Host's advertised name and is never trusted
/// by itself. Selecting one resolves it to an address and then goes through exactly the same fingerprint
/// verification and Host approval as a typed address. Browsing runs only while the Viewer screen is visible.
@MainActor
@Observable
public final class BonjourDiscovery {
    public private(set) var results: [BonjourBrowser.Result] = []
    public private(set) var isBrowsing = false
    /// The result currently being resolved (disables its row).
    public private(set) var resolving: BonjourBrowser.Result?

    @ObservationIgnored private var browser: BonjourBrowser?

    public init() {}

    public func start() {
        guard browser == nil else { return }
        let browser = BonjourBrowser()
        browser.onResults = { [weak self] list in
            // Result changes are rare (a Mac appearing/disappearing); one main-actor hop each is fine.
            Task { @MainActor [weak self] in self?.results = list }
        }
        self.browser = browser
        isBrowsing = true
        browser.start()
    }

    public func stop() {
        browser?.onResults = nil
        browser?.stop()
        browser = nil
        isBrowsing = false
        results = []
        resolving = nil
    }

    /// Resolves a discovered Host to a dialable address (nil if it vanished or did not resolve within ~5 s).
    public func resolve(_ result: BonjourBrowser.Result) async -> ConnectTarget? {
        guard let browser, resolving == nil else { return nil }
        resolving = result
        defer { resolving = nil }
        guard let resolved = await browser.resolve(result) else { return nil }
        return ConnectTarget(host: resolved.host, port: resolved.port)
    }
}
