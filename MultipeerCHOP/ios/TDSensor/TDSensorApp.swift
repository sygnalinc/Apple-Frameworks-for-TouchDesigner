// TDSensorApp.swift — TDAppleML Multipeer CHOP 用 iPhone センサー送信アプリ
//
// iPhone/iPad のモーション(ジャイロ・加速度・姿勢)・画面タッチ・向きを
// MultipeerConnectivity で Mac の Multipeer CHOP へ低遅延送信する。
// 同じローカルネットワークで、CHOP の Service Type を "td-sensor" にすれば自動接続する。
//
// Xcode で新規 iOS App(SwiftUI・言語 Swift)を作り、本フォルダの3ファイルを追加、
// Info.plist に下記キーを足してビルド(実機推奨。詳細は ../README.md)。

import SwiftUI

@main
struct TDSensorApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
