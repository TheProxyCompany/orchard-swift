import Foundation
import Testing
@testable import Orchard

@Test func testManifestFetch() async throws {
    let fetcher = EngineFetcher()

    // Just verify we can check for updates without crashing
    // This makes a real network call to the manifest endpoint
    let update = await fetcher.checkForUpdates()
    // update is nil if we're on latest, or a version string if update available
    #expect(update == nil || update?.hasPrefix("v") == true)
}

@Test func testIPCEndpoints() {
    // Verify endpoint URLs are well-formed
    #expect(IPCEndpoints.requestURL.hasPrefix("ipc://"))
    #expect(IPCEndpoints.responseURL.hasPrefix("ipc://"))
    #expect(IPCEndpoints.managementURL.hasPrefix("ipc://"))

    // Verify topic prefixes
    #expect(IPCEndpoints.responseTopicPrefix == Data("resp:".utf8))
    #expect(IPCEndpoints.eventTopicPrefix == Data("__PIE_EVENT__:".utf8))
}
