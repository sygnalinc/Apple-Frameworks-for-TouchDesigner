# GameplayKit Path SOP

GameplayKit の `GKObstacleGraph` で、始点→終点の**障害物回避最短経路**を計算し、1本の Line primitive
として出力する。障害物は**入力SOPの各点(中心)**を半径 Obstacle Radius の多角形(既定8角形)として扱う。

## 実測(M2)

- 始点(-4,0)→終点(4,0)、原点に障害物(半径1.2)→ 経路 `(-4,0)→(0,1.42)→(4,0)` で障害物を迂回。
  障害物が無ければ直線

## 出力(SOP)

経路の点列 + 1本の Line primitive。点属性 `pathindex`。Info CHOP: `executes / found / length`

## パラメータ

| パラメータ | 説明 |
|---|---|
| Start X/Y / End X/Y | 始点・終点 |
| Obstacle Radius | 入力点1つあたりの障害物半径 |
| Buffer Radius | エージェント半径(障害物を膨張) |
| Obstacle Polygon Sides | 円の多角形近似の辺数 |

## 注意

- **GKPolygonObstacle は反時計回り(CCW)巻き順**が正しい(CWだと全遮蔽で経路0)。半径が小さく頂点が
  始点終点の線分上に乗ると迂回しないことがある(半径を上げる)
- 経路が見つからないと直線でフォールバック(Info `found`=0・Warning)

## ビルド
```
cd GameplayPath && ./build.sh
```
