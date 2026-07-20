# CoreLocation Beacon CHOP

`CoreLocation` で **iBeacon を測距(ranging)**し、各ビーコンの major/minor/rssi/近接度/推定距離を出力する。
展示内の近接検出に。`CLBeaconIdentityConstraint`(UUID + 任意の major/minor)で対象を絞る。

## 出力(CHOP)

`beacon{i}/valid / major / minor / rssi / accuracy / proximity`(proximity: 0=unknown,1=immediate,
2=near,3=far)。Info CHOP: `executes / beacons / auth`

## パラメータ

| パラメータ | 説明 |
|---|---|
| Active | 測距の有効 |
| Beacon UUID | 対象ビーコンのProximity UUID |
| Major / Minor | 絞り込み(0=任意) |
| Max Beacons | 出力スロット数 |

## 注意

- **Location 権限が必要**。TouchDesigner の Info.plist に `NSLocationUsageDescription` が無いと権限取得に
  失敗しうる(その場合は測距できない)。**実 iBeacon が必要**
- ビーコン測距は macOS 10.15+。`@available` ガード済み

## ビルド
```
cd Beacon && ./build.sh
```
