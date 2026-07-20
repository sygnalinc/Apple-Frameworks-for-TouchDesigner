# Gameplay Agents CHOP

GameplayKit の `GKAgent2D` 群を `GKGoal`(seek/flee/separate/align/cohere/avoid/wander/reach-speed)で
駆動する**群集シミュレーション**。各エージェントの位置/速度/角度を出力する。障害物は任意の入力CHOP
(1サンプル=1障害物、ch `x`,`y`,`radius`)から取得。

## 実測(M2)

- 30体・目標(5,0)・Seek重み2で、agent1 が速度(2.92,0.70)で目標方向へ移動。群集挙動を確認

## 出力(CHOP)

`agent{i}/x`,`/y`,`/vx`,`/vy`,`/angle`(1始まり・1sample)。Info CHOP: `executes / agents`

## パラメータ(主要)

| パラメータ | 説明 |
|---|---|
| Agent Count / Seed / Spawn Radius | 数 / 乱数種 / 初期散布半径 |
| Target X/Y | seek 目標点 |
| Sim Speed / Max Speed / Max Acceleration / Agent Radius | 挙動 |
| Bound to Region / Bounds X/Y | 領域内に収める |
| Weights: Seek/Separate/Align/Cohere/Avoid Obstacles/Wander/Reach Speed | 各 GKGoal の重み |
| Separation Distance / Neighbor Distance / Reach Speed Value | 距離・目標速度 |

## 注意

- 障害物は入力CHOP(`x`,`y`,`radius`)。無ければ障害物なし
- Reset で初期位置を再散布。Sim Speed が dt(1/60×Speed)。タイムライン停止中はcookされない

## ビルド
```
cd GameplayAgents && ./build.sh
```
