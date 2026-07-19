// SensorSender.swift — CoreMotion のセンサー値を TDMP バイナリで Multipeer 送信する
//
// TDMP パケット(Multipeer CHOP と対):
//   "TDMP"(4B) | uint16 count(LE) | count×{ uint8 nameLen, name(UTF8), float32 value(LE) }

import Foundation
import CoreMotion
import MultipeerConnectivity
import Combine

final class SensorSender: NSObject, ObservableObject,
    MCSessionDelegate, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate
{
    @Published var peerCount = 0
    @Published var sending = false
    @Published var lastRate = 0.0

    private let motion = CMMotionManager()
    private var peerID: MCPeerID!
    private var session: MCSession!
    private var advertiser: MCNearbyServiceAdvertiser!
    private var browser: MCNearbyServiceBrowser!
    private let serviceType: String

    // タッチ状態(ContentView から更新)
    var touch = false
    var touchX: Float = 0
    var touchY: Float = 0

    private var frames = 0
    private var lastStamp = Date()

    init(displayName: String, serviceType: String) {
        self.serviceType = serviceType
        super.init()
        peerID = MCPeerID(displayName: displayName)
        session = MCSession(peer: peerID, securityIdentity: nil,
                            encryptionPreference: .none)
        session.delegate = self
        advertiser = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: nil,
                                               serviceType: serviceType)
        advertiser.delegate = self
        browser = MCNearbyServiceBrowser(peer: peerID, serviceType: serviceType)
        browser.delegate = self
    }

    func start() {
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
        motion.deviceMotionUpdateInterval = 1.0 / 60.0
        motion.startDeviceMotionUpdates(to: .main) { [weak self] dm, _ in
            guard let self, let dm else { return }
            self.send(dm)
        }
        sending = true
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        session.disconnect()
        sending = false
    }

    private func send(_ dm: CMDeviceMotion) {
        guard !session.connectedPeers.isEmpty else { return }
        var data = Data("TDMP".utf8)
        var fields: [(String, Float)] = [
            ("gyro_x", Float(dm.rotationRate.x)),
            ("gyro_y", Float(dm.rotationRate.y)),
            ("gyro_z", Float(dm.rotationRate.z)),
            ("accel_x", Float(dm.userAcceleration.x)),
            ("accel_y", Float(dm.userAcceleration.y)),
            ("accel_z", Float(dm.userAcceleration.z)),
            ("gravity_x", Float(dm.gravity.x)),
            ("gravity_y", Float(dm.gravity.y)),
            ("gravity_z", Float(dm.gravity.z)),
            ("roll", Float(dm.attitude.roll)),
            ("pitch", Float(dm.attitude.pitch)),
            ("yaw", Float(dm.attitude.yaw)),
            ("heading", Float(dm.heading)),
            ("touch", touch ? 1 : 0),
            ("touch_x", touchX),
            ("touch_y", touchY),
        ]
        var count = UInt16(fields.count).littleEndian
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
        for (name, value) in fields {
            let n = Array(name.utf8)
            data.append(UInt8(n.count))
            data.append(contentsOf: n)
            var v = value.bitPattern.littleEndian   // float32 LE
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }
        try? session.send(data, toPeers: session.connectedPeers, with: .unreliable)

        frames += 1
        let dt = Date().timeIntervalSince(lastStamp)
        if dt >= 1.0 {
            let rate = Double(frames) / dt
            frames = 0
            lastStamp = Date()
            DispatchQueue.main.async { self.lastRate = rate }
        }
        _ = fields   // silence unused in release
    }

    // MARK: - MCSessionDelegate
    func session(_ s: MCSession, peer: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async { self.peerCount = s.connectedPeers.count }
    }
    func session(_ s: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {}
    func session(_ s: MCSession, didReceive stream: InputStream, withName streamName: String,
                 fromPeer peerID: MCPeerID) {}
    func session(_ s: MCSession, didStartReceivingResourceWithName name: String,
                 fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ s: MCSession, didFinishReceivingResourceWithName name: String,
                 fromPeer peerID: MCPeerID, at url: URL?, withError error: Error?) {}

    // MARK: - Advertiser / Browser(表示名の辞書順で片方向招待=二重接続防止)
    func advertiser(_ a: MCNearbyServiceAdvertiser,
                    didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?,
                    invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(true, session)
    }
    func browser(_ b: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
                 withDiscoveryInfo info: [String: String]?) {
        if self.peerID.displayName < peerID.displayName {
            b.invitePeer(peerID, to: session, withContext: nil, timeout: 15)
        }
    }
    func browser(_ b: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}
}
