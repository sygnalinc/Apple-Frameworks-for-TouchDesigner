// ContentView.swift — 接続状態の表示、送信 On/Off、画面タッチを touch/touch_x/touch_y に

import SwiftUI

struct ContentView: View {
    @StateObject private var sender = SensorSender(
        displayName: UIDevice.current.name,
        serviceType: "td-sensor")
    @State private var started = false

    var body: some View {
        VStack(spacing: 24) {
            Text("TDAppleML Sensor")
                .font(.title2).bold()

            VStack(spacing: 8) {
                Label(sender.peerCount > 0 ? "Connected (\(sender.peerCount))"
                                           : "Searching…",
                      systemImage: sender.peerCount > 0 ? "wifi" : "wifi.slash")
                    .foregroundColor(sender.peerCount > 0 ? .green : .secondary)
                Text(String(format: "%.0f pkt/s", sender.lastRate))
                    .font(.caption).foregroundColor(.secondary)
            }

            Button(started ? "Stop" : "Start Sending") {
                started ? sender.stop() : sender.start()
                started.toggle()
            }
            .font(.headline)
            .padding(.horizontal, 32).padding(.vertical, 14)
            .background(started ? Color.red : Color.blue)
            .foregroundColor(.white)
            .clipShape(Capsule())

            // タッチパッド: ドラッグ位置を 0〜1 で送る
            GeometryReader { geo in
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.secondary.opacity(0.15))
                    Text("Touch Pad\n(touch / touch_x / touch_y)")
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            sender.touch = true
                            sender.touchX = Float(max(0, min(1, g.location.x / geo.size.width)))
                            sender.touchY = Float(max(0, min(1, 1 - g.location.y / geo.size.height)))
                        }
                        .onEnded { _ in sender.touch = false }
                )
            }
            .frame(height: 260)

            Text("Service Type: td-sensor")
                .font(.caption2).foregroundColor(.secondary)
            Spacer()
        }
        .padding()
    }
}
