// wifiscan-helper — 独立した .app として動く CoreWLAN スキャナ。
// 独自 Info.plist(NSLocation 用途文字列)を持つので**位置情報の許可ダイアログ**を出せる。
// 許可(authorizedAlways/authorizedWhenInUse)されると CoreWLAN の scanForNetworks が
// SSID/BSSID を返す(macOS 14.4+ の privacy ゲートは Location 許可で解ける・実測)。
//
// 使い方: open -g -j <helper.app> --args <出力JSONパス>
// 結果を JSON でファイルに書いて exit。TouchDesigner の CoreWLAN Scan CHOP が読む。
import CoreWLAN
import CoreLocation
import Foundation

let outPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : (NSHomeDirectory() + "/Library/Caches/TDAppleML/wifiscan.json")

func writeJSON(_ s: String) {
    let dir = (outPath as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try? s.write(toFile: outPath, atomically: true, encoding: .utf8)
}

func esc(_ s: String) -> String {
    return s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "'")
}

func doScanAndExit() {
    guard let itf = CWWiFiClient.shared().interface() else {
        writeJSON("{\"status\":\"no_interface\"}"); exit(0)
    }
    var arr: [String] = []
    if let nets = try? itf.scanForNetworks(withName: nil) {
        for n in nets {
            let ssid = esc(n.ssid ?? "")
            let bssid = esc(n.bssid ?? "")
            let ch = n.wlanChannel?.channelNumber ?? -1
            var band = "?"
            if let b = n.wlanChannel?.channelBand { band = (b == .band5GHz) ? "5" : ((b == .band2GHz) ? "2.4" : "?") }
            var w = 20
            switch n.wlanChannel?.channelWidth {
                case .some(.width40MHz): w = 40
                case .some(.width80MHz): w = 80
                case .some(.width160MHz): w = 160
                default: w = 20
            }
            arr.append("{\"ssid\":\"\(ssid)\",\"bssid\":\"\(bssid)\",\"rssi\":\(n.rssiValue),\"channel\":\(ch),\"band\":\"\(band)\",\"width\":\(w)}")
        }
    }
    let connected = esc(itf.ssid() ?? "")
    writeJSON("{\"status\":\"ok\",\"connected\":\"\(connected)\",\"networks\":[\(arr.joined(separator: ","))]}")
    exit(0)
}

final class D: NSObject, CLLocationManagerDelegate {
    let m = CLLocationManager()
    override init() {
        super.init()
        m.delegate = self
        m.requestAlwaysAuthorization()
        m.startUpdatingLocation()
    }
    func locationManagerDidChangeAuthorization(_ mgr: CLLocationManager) {
        let s = mgr.authorizationStatus.rawValue
        if s == 3 || s == 4 { doScanAndExit() }
        else if s == 1 || s == 2 { writeJSON("{\"status\":\"denied\"}"); exit(0) }
        // notDetermined(0): プロンプト待ち
    }
    func locationManager(_ m: CLLocationManager, didUpdateLocations l: [CLLocation]) {}
}

let d = D()
let cur = d.m.authorizationStatus.rawValue
if cur == 3 || cur == 4 { doScanAndExit() }
// 初回プロンプト待ちのタイムアウト(最大40秒)
Timer.scheduledTimer(withTimeInterval: 40, repeats: false) { _ in
    writeJSON("{\"status\":\"timeout\"}"); exit(0)
}
CFRunLoopRun()
