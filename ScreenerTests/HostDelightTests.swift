import CoreVideo
import SwiftData
import UIKit
import XCTest
@testable import Screener

final class ConnectionStageTests: XCTestCase {
    func testTheHappyPathWalksTheThreeSteps() {
        var s = ConnectionStage.idle
        var seen: [ConnectionStage] = []
        for m: ConnectionMilestone in [.started, .authenticated, .recordLayerActive, .mediaAnswered, .streamStarted,
                                        .firstFrame] {
            s = s.advanced(by: m)
            seen.append(s)
        }
        XCTAssertEqual(seen, [.signingIn, .securing, .startingVideo, .startingVideo, .startingVideo, .live])
        XCTAssertEqual(ConnectionStage.derive([.started, .authenticated, .recordLayerActive]), .startingVideo)
    }

    func testTheStageNeverStepsBack() {
        // Late hops and a starved-burst retry (the ControlSession milestones repeat).
        XCTAssertEqual(ConnectionStage.derive([.started, .authenticated, .recordLayerActive, .authenticated]),
                       .startingVideo)
        XCTAssertEqual(ConnectionStage.derive([.started, .mediaAnswered, .authenticated]), .startingVideo)
        XCTAssertEqual(ConnectionStage.derive([.started, .firstFrame, .recordLayerActive]), .live)
    }

    func testMilestonesWhileIdleAreStale() {
        XCTAssertEqual(ConnectionStage.derive([.authenticated, .recordLayerActive, .firstFrame]), .idle)
        XCTAssertEqual(ConnectionStage.derive([.started, .authenticated, .ended, .recordLayerActive]), .idle)
    }

    func testAReconnectStartsOver() {
        XCTAssertEqual(ConnectionStage.derive([.started, .authenticated, .recordLayerActive, .firstFrame, .ended,
                                               .started]), .signingIn)
        XCTAssertEqual(ConnectionStage.live.advanced(by: .started), .signingIn)
    }

    func testStepsAndTitles() {
        XCTAssertEqual(ConnectionStage.steps.count, 3)
        XCTAssertEqual(ConnectionStage.signingIn.stepIndex, 0)
        XCTAssertEqual(ConnectionStage.startingVideo.stepIndex, 2)
        XCTAssertNil(ConnectionStage.live.stepIndex)
        XCTAssertEqual(ConnectionStage.signingIn.title, "Signing in…")
        XCTAssertEqual(ConnectionStage.securing.title, "Securing…")
        XCTAssertEqual(ConnectionStage.startingVideo.title, "Starting video…")
    }
}

/// SessionCoordinator publishes the stage from the real handshake (the fake
/// server of SessionCoordinatorConnectedTests), captures the last picture at
/// teardown, and resets the stage.
@MainActor
final class SessionCoordinatorStageTests: XCTestCase {
    private func waitUntil(_ what: String, timeout: Duration = .seconds(5), _ cond: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !cond(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertTrue(cond(), "timed out waiting for \(what)")
        if !cond() { throw CancellationError() }
    }

    func testStagesFollowTheHandshakeAndTheLastPictureIsCaptured() async throws {
        let h = try SessionCoordinatorConnectedTests.Harness()
        var policy = SessionCoordinator.Policy()
        policy.firstFrameKeyframeAfter = .seconds(60)
        policy.firstFrameDeadline = .seconds(120)
        let c = SessionCoordinator(policy: policy, seams: h.seams(ip: "192.0.2.150"))
        XCTAssertEqual(c.stage, .idle)
        let t = Task { await c.connect(host: "mac", port: 5900, username: "u", password: "p") }
        var seen: [ConnectionStage] = []
        try await waitUntil("handshake") {
            if c.stage != .idle, seen.last != c.stage { seen.append(c.stage) }
            return c.mediaParams != nil && c.stage == .startingVideo
        }
        XCTAssertEqual(seen, seen.sorted(), "never steps back: \(seen)")
        XCTAssertEqual(seen.first, .signingIn)
        try h.deliverBurst(try XCTUnwrap(c.mediaParams?.keys))
        try await waitUntil("connected") { if case .connected = c.state { true } else { false } }
        await t.value
        XCTAssertEqual(c.stage, .startingVideo, "connected, no picture yet")

        // A picture: the stage goes live; the disconnect captures it.
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 40, kCVPixelFormatType_32BGRA, nil, &pb)
        let buffer = try XCTUnwrap(pb)
        c.frames.configure(tileCount: 1, canvas: CGSize(width: 64, height: 40))
        c.frames.publish(DecodedFrame(tile: 0, pixelBuffer: buffer, decodeTime: .zero, don: 0, seq: 1_000_000),
                         epoch: c.frames.currentEpoch)
        c.frames.onFirstFrame?(buffer)
        try await waitUntil("live") { c.stage == .live }
        XCTAssertNil(c.lastPicture)
        await c.disconnect()
        XCTAssertEqual(c.stage, .idle)
        try await waitUntil("last picture") { c.lastPicture != nil }
        XCTAssertEqual(c.lastPicture?.image.size, CGSize(width: 64, height: 40))
    }
}

final class MacModelSymbolTests: XCTestCase {
    func testFamiliesByPrefix() {
        XCTAssertEqual(MacModelSymbol.symbol(for: "Macmini9,1"), "macmini")
        XCTAssertEqual(MacModelSymbol.symbol(for: "MacBookPro18,3"), "macbook")
        XCTAssertEqual(MacModelSymbol.symbol(for: "MacBookAir10,1"), "macbook")
        XCTAssertEqual(MacModelSymbol.symbol(for: "iMac21,1"), "desktopcomputer")
        XCTAssertEqual(MacModelSymbol.symbol(for: "iMacPro1,1"), "desktopcomputer")
        XCTAssertEqual(MacModelSymbol.symbol(for: "MacPro7,1"), "macpro.gen3")
        XCTAssertEqual(MacModelSymbol.symbol(for: "MacPro6,1"), "macpro.gen2")
    }

    func testAppleSiliconIdentifiers() {
        XCTAssertEqual(MacModelSymbol.symbol(for: "Mac13,1"), "macstudio")
        XCTAssertEqual(MacModelSymbol.symbol(for: "Mac16,9"), "macstudio")
        XCTAssertEqual(MacModelSymbol.symbol(for: "Mac14,3"), "macmini")
        XCTAssertEqual(MacModelSymbol.symbol(for: "Mac16,10"), "macmini")
        XCTAssertEqual(MacModelSymbol.symbol(for: "Mac14,8"), "macpro.gen3")
        XCTAssertEqual(MacModelSymbol.symbol(for: "Mac15,4"), "desktopcomputer")
        XCTAssertEqual(MacModelSymbol.symbol(for: "Mac14,2"), "macbook")
        XCTAssertEqual(MacModelSymbol.symbol(for: "Mac16,1"), "macbook")
    }

    func testUnknownAndMissing() {
        XCTAssertEqual(MacModelSymbol.symbol(for: nil), MacModelSymbol.generic)
        XCTAssertEqual(MacModelSymbol.symbol(for: ""), MacModelSymbol.generic)
        XCTAssertEqual(MacModelSymbol.symbol(for: "Mac99,1"), MacModelSymbol.generic)
        XCTAssertEqual(MacModelSymbol.symbol(for: "VirtualMac2,1"), MacModelSymbol.generic)
        XCTAssertEqual(MacModelSymbol.symbol(for: " Macmini9,1\n"), "macmini")
        XCTAssertEqual(MacModelSymbol.family(for: "Macmini9,1"), "Mac mini")
        XCTAssertEqual(MacModelSymbol.family(for: "Mac15,4"), "iMac")
        XCTAssertNil(MacModelSymbol.family(for: nil))
    }

    /// Every symbol the mapping can return exists on this OS.
    func testEverySymbolExists() {
        let all = Set(MacModelSymbol.appleSilicon.values).union([
            MacModelSymbol.generic, MacModelSymbol.laptop, MacModelSymbol.mini, MacModelSymbol.studio,
            MacModelSymbol.pro, MacModelSymbol.proCylinder, MacModelSymbol.iMac])
        for name in all { XCTAssertNotNil(UIImage(systemName: name), name) }
    }
}

@MainActor
final class HostReachabilityTests: XCTestCase {
    private func service(_ name: String) -> DiscoveredHost {
        DiscoveredHost(name: name, endpoint: .service(name: name, type: "_rfb._tcp", domain: "local.", interface: nil))
    }

    func testOnlineWhileAdvertised() {
        let h = SavedHost(name: "Studio", host: "192.168.1.20", username: "u", bonjourName: "Studio")
        XCTAssertEqual(HostReachability.of(h, discovered: [service("Studio")], resolved: [:], isBrowsing: true), .online)
        XCTAssertTrue(HostReachability.online.isOnline)
    }

    func testMatchedByResolvedAddressOrHostName() {
        let byIP = SavedHost(name: "x", host: "10.0.0.5", username: "u")
        XCTAssertEqual(HostReachability.of(byIP, discovered: [service("Desk")], resolved: ["Desk": "10.0.0.5"],
                                           isBrowsing: true), .online)
        let byName = SavedHost(name: "x", host: "Alexs-MacBook-Pro.local", username: "u")
        XCTAssertEqual(HostReachability.of(byName, discovered: [service("Alex’s MacBook Pro")], resolved: [:],
                                           isBrowsing: true), .online)
    }

    func testOfflineWhileBrowsingUnknownOtherwise() {
        let h = SavedHost(name: "Studio", host: "192.168.1.20", username: "u")
        XCTAssertEqual(HostReachability.of(h, discovered: [service("Other")], resolved: [:], isBrowsing: true), .offline)
        XCTAssertEqual(HostReachability.of(h, discovered: [], resolved: [:], isBrowsing: false), .unknown)
        XCTAssertFalse(HostReachability.offline.isOnline)
        XCTAssertFalse(HostReachability.unknown.isOnline)
    }
}

final class ThumbnailStoreTests: XCTestCase {
    private var dir: URL!
    private var store: ThumbnailStore!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("thumbs-\(UUID().uuidString)")
        store = ThumbnailStore(directory: dir)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    static func image(width: Int, height: Int, color: UIColor = .systemTeal) -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { ctx in
            color.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }.cgImage!
    }

    func testSaveLoadDelete() throws {
        let id = UUID(), other = UUID()
        XCTAssertNil(store.load(id))
        let url = try store.save(Self.image(width: 1920, height: 1200), for: id)
        try store.save(Self.image(width: 100, height: 100), for: other)
        XCTAssertTrue(["heic", "jpg"].contains(url.pathExtension))
        XCTAssertEqual(store.existingURL(for: id), url)
        let loaded = try XCTUnwrap(store.load(id))
        XCTAssertEqual(max(loaded.size.width * loaded.scale, loaded.size.height * loaded.scale), 640,
                       "downscaled to 640 px on the long side")
        XCTAssertEqual(loaded.size.width / loaded.size.height, 1.6, accuracy: 0.01)
        let values = try dir.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true, "thumbnails stay on this device")

        try store.save(Self.image(width: 300, height: 200), for: id)       // replaced
        XCTAssertEqual(try XCTUnwrap(store.load(id)).size.width, 300)

        store.delete(id)
        XCTAssertNil(store.load(id))
        XCTAssertNil(store.existingURL(for: id))
        XCTAssertNotNil(store.load(other), "only that host's")
        store.deleteAll()
        XCTAssertNil(store.load(other))
    }

    @MainActor
    func testDeletingAHostDeletesItsThumbnail() throws {
        let container = try HostStore.makeContainer(inMemory: true)
        let h = SavedHost(name: "Studio", host: "1.2.3.4", username: "u")
        container.mainContext.insert(h)
        try container.mainContext.save()
        try store.save(Self.image(width: 64, height: 40), for: h.id)
        try HostStore.delete(h, in: container.mainContext, passwords: MemoryPasswordStore(), thumbnails: store)
        XCTAssertNil(store.load(h.id))
    }

    @MainActor
    func testObservableThumbnails() async throws {
        let t = HostThumbnails(store: store)
        let id = UUID()
        await t.save(UIImage(cgImage: Self.image(width: 800, height: 500)), for: id)
        XCTAssertNotNil(t.image(for: id))
        let fresh = HostThumbnails(store: store)
        await fresh.load([id, UUID()])
        XCTAssertNotNil(fresh.image(for: id))
        fresh.remove(id)
        XCTAssertNil(fresh.image(for: id))
        XCTAssertNil(store.load(id))
    }
}

final class FrameSnapshotTests: XCTestCase {
    /// 4:4:4 bi-planar full-range buffer (the decoder's output format) of one luma value.
    private func yuv444(width: Int, height: Int, luma: UInt8) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_444YpCbCr8BiPlanarFullRange,
                                           attrs, &pb), kCVReturnSuccess)
        let b = try XCTUnwrap(pb)
        CVPixelBufferLockBaseAddress(b, [])
        defer { CVPixelBufferUnlockBaseAddress(b, []) }
        for plane in 0..<2 {
            let base = CVPixelBufferGetBaseAddressOfPlane(b, plane)!
            let bytes = CVPixelBufferGetBytesPerRowOfPlane(b, plane) * CVPixelBufferGetHeightOfPlane(b, plane)
            memset(base, Int32(plane == 0 ? luma : 128), bytes)
        }
        return b
    }

    private func luma(_ image: CGImage, x: Int, y: Int) -> Int {
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Int(px[0]) + Int(px[1]) + Int(px[2])) / 3
    }

    /// Two strips (bright over dark) composite in tile order onto the canvas,
    /// the padded bottom rows cut, then downscale.
    func testStripsCompositeTopToBottom() throws {
        let bright = try yuv444(width: 64, height: 24, luma: 230)
        let dark = try yuv444(width: 64, height: 24, luma: 20)
        let snap = FrameSnapshot(frames: [0: bright, 1: dark], tileCount: 2, canvas: CGSize(width: 64, height: 40))
        let full = try XCTUnwrap(snap.renderCGImage(maxPixels: 1000))
        XCTAssertEqual(full.width, 64)
        XCTAssertEqual(full.height, 40)
        XCTAssertGreaterThan(luma(full, x: 32, y: 4), 180, "top strip")
        XCTAssertLessThan(luma(full, x: 32, y: 36), 60, "bottom strip")
        let small = try XCTUnwrap(snap.renderCGImage(maxPixels: 32))
        XCTAssertEqual(small.width, 32)
        XCTAssertEqual(small.height, 20)
    }

    func testNoPictureNoSnapshot() {
        XCTAssertNil(FrameSnapshot(nil))
        XCTAssertNil(FrameSnapshot.capture(VideoFrameStore()))
    }
}

@MainActor
final class HostsSchemaMigrationTests: XCTestCase {
    /// A v1 store (as shipped) opens with the v2 schema: hosts kept, the new
    /// `macModel` column empty, then writable.
    func testV1StoreMigratesToV2() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hosts-\(UUID().uuidString).store")
        defer {
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
            }
        }
        let id = UUID()
        do {
            let v1 = Schema(versionedSchema: HostsSchemaV1.self)
            let c = try ModelContainer(for: v1, migrationPlan: HostsMigrationPlan.self,
                                       configurations: ModelConfiguration(schema: v1, url: url))
            let old = HostsSchemaV1.SavedHost(id: id, name: "Kept", host: "1.2.3.4", username: "u",
                                              bonjourName: "Studio")
            old.macAddress = "aa:bb"
            c.mainContext.insert(old)
            try c.mainContext.save()
        }
        do {
            let c = try HostStore.makeContainer(url: url)
            let hosts = try c.mainContext.fetch(FetchDescriptor<SavedHost>())
            XCTAssertEqual(hosts.map(\.name), ["Kept"])
            let h = try XCTUnwrap(hosts.first)
            XCTAssertEqual(h.id, id)
            XCTAssertEqual(h.bonjourName, "Studio")
            XCTAssertEqual(h.macAddress, "aa:bb")
            XCTAssertNil(h.macModel)
            h.macModel = "Macmini9,1"
            try c.mainContext.save()
        }
        let reopened = try HostStore.makeContainer(url: url)
        XCTAssertEqual(try reopened.mainContext.fetch(FetchDescriptor<SavedHost>()).first?.macModel, "Macmini9,1")
    }

    func testDuplicateCopiesTheModel() throws {
        let c = try HostStore.makeContainer(inMemory: true)
        let h = SavedHost(name: "Studio", host: "1.2.3.4", username: "u")
        h.macModel = "Mac13,1"
        c.mainContext.insert(h)
        let copy = try HostStore.duplicate(h, in: c.mainContext, passwords: MemoryPasswordStore())
        XCTAssertEqual(copy.macModel, "Mac13,1")
    }
}

@MainActor
final class HostConnectorModelTests: XCTestCase {
    func testMarkConnectedMakesTheHostActiveAndANewConnectClearsIt() async throws {
        let c = try HostStore.makeContainer(inMemory: true)
        let h = SavedHost(name: "Studio", host: "1.2.3.4", username: "u")
        c.mainContext.insert(h)
        let connector = HostConnector(model: SessionCoordinator(), passwords: MemoryPasswordStore())
        connector.markConnected(h, resolvedAddress: nil, rememberPassword: nil, context: c.mainContext)
        XCTAssertEqual(connector.activeHostID, h.id)
        connector.recordDeviceModel("Macmini9,1", in: c.mainContext)
        XCTAssertEqual(h.macModel, "Macmini9,1")
        connector.recordDeviceModel(nil, in: c.mainContext)
        XCTAssertEqual(h.macModel, "Macmini9,1")
        // A connect to an unsaved address must not credit the previous host.
        _ = await connector.connect(host: "", port: 5900, username: "u", password: "p")
        XCTAssertNil(connector.activeHostID)
    }
}
