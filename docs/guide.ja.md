# 使い方ガイド

English: see [guide.md](guide.md).

空のプロジェクトから、数千体のスプライトが動く画面までを順に説明します。
関数の正確なシグネチャは [api.md](api.md)（英語）にあります。

## 目次

1. [このアドオンが向いている場面](#1-このアドオンが向いている場面)
2. [導入](#2-導入)
3. [最初の1体](#3-最初の1体)
4. [大量のスプライトを動かす](#4-大量のスプライトを動かす)
5. [レイヤー](#5-レイヤー)
6. [反転と拡縮](#6-反転と拡縮)
7. [コードではなく定義ファイルで登録する](#7-コードではなく定義ファイルで登録する)
8. [向きを持つスプライト](#8-向きを持つスプライト)
9. [スプライト文字HUD](#9-スプライト文字hud)
10. [終了処理](#10-終了処理)
11. [うまく使うために](#11-うまく使うために)
12. [困ったときは](#12-困ったときは)

---

## 1. このアドオンが向いている場面

TKSpriteServer は `RenderingServer` へ直接描画します。`Sprite2D` ノードを作らないため、
ノード1個あたりのオーバーヘッドもシーンツリーの増減もありません。

向いているのは、**単純なスプライトが大量にあり、毎フレーム自分で位置を更新する**種類の
ゲームです。弾が数百飛ぶシューティング、エフェクトの多いアクション、タイル単位の
シミュレーション、固定解像度のドット絵ゲームなどです。

逆に、1体ごとにシグナルや物理ボディやアニメーションプレイヤーを持たせ、エディタ上に
配置したい場合は向きません。それは `Sprite2D` や `AnimatedSprite2D` の役目で、数十体
程度ならそちらの方が確実に楽です。

考え方はシーンツリーよりも 2D グラフィックスライブラリに近く、ゲームの状態は利用側が
持ち、毎フレーム「今どこに何があるか」をサーバーへ伝えます。

## 2. 導入

1. `addons/tk_sprite_server/` をプロジェクトの `addons/` へコピーします。
2. プロジェクト設定 → プラグイン で **TKSpriteServer** を有効化します。
3. GDExtension を読み込ませるため、エディタを一度再起動します。

Windows x86_64 のバイナリは同梱しています。それ以外のプラットフォームでも動かなくなる
ことはなく、API も見た目も同じ純 GDScript 実装へ自動的に切り替わります（速度だけが
違います）。どちらが選ばれたかは `TKSpriteServer.get_backend_name()` で確認できます。

## 3. 最初の1体

表示までに必要なものは 3 つです。

1. **プレーン** — 描画先の canvas_item。
2. **スプライト表の登録** — どのテクスチャの、どの矩形か。
3. **`commit_frame()`** — 毎フレーム1回。これを呼ばないと何も描かれません。

```gdscript
extends Node2D

var _server: Object
var _link_id: int

func _ready() -> void:
	# 1. プレーン。canvas_item を3枚作り、このノードの canvas にぶら下げます。
	var back: RID = RenderingServer.canvas_item_create()
	var medium: RID = RenderingServer.canvas_item_create()
	var front: RID = RenderingServer.canvas_item_create()
	for plane_rid in [back, medium, front]:
		RenderingServer.canvas_item_set_parent(plane_rid, get_canvas())

	# サーバーは Node なので、必ずシーンツリーへ入れます。
	_server = TKSpriteServer.create(4096, true)
	add_child(_server)
	_server.set_plane_rids(back, medium, front)

	# 2. スプライト表。sprite_id 0 をテクスチャの 16x16 の領域として登録します。
	var texture: Texture2D = preload("res://art/player.png")
	_server.sprite_textures[0] = {
		"texture": texture,
		"frames": [Rect2(0, 0, 16, 16)],
	}
	_server.set_sprite_draw_size(0, Vector2(16, 16))

	# 1体分の枠を確保します。返る link_id がその個体のハンドルです。
	_link_id = _server.allocate_link_id(0)

func _process(_delta: float) -> void:
	_server.update_sprite(_link_id, Vector2(100.0, 80.0))
	# 3. すべての更新のあと、1フレームに1回だけ呼びます。
	_server.commit_frame()
```

**link_id** は画面上の1体を指すハンドルです。最初に1回確保し、毎フレーム使い回し、
消滅時に破棄します。毎フレーム確保し直してはいけません。

**sprite_id** はスプライト表の項目、つまりテクスチャとフレーム矩形の組です。
1つの sprite_id を多数の link_id が共有できます。

## 4. 大量のスプライトを動かす

書き方は体数が増えても変わりません。状態は利用側の配列で持ち、毎フレーム流し込みます。

```gdscript
const COUNT: int = 5000

var _links: PackedInt32Array = PackedInt32Array()
var _positions: PackedVector2Array = PackedVector2Array()
var _velocities: PackedVector2Array = PackedVector2Array()

func _spawn_all() -> void:
	_links.resize(COUNT)
	_positions.resize(COUNT)
	_velocities.resize(COUNT)
	for i in range(COUNT):
		_links[i] = _server.allocate_link_id(0)
		_positions[i] = Vector2(randf() * 640.0, randf() * 360.0)
		_velocities[i] = Vector2(randf_range(-60.0, 60.0), randf_range(-60.0, 60.0))

func _process(delta: float) -> void:
	for i in range(COUNT):
		_positions[i] += _velocities[i] * delta
		_server.update_sprite(_links[i], _positions[i])
	_server.commit_frame()
```

値が変わらなかったスプライトは再描画されません（スロットごとに dirty フラグを持って
います）。同じ値で毎フレーム `update_sprite()` を呼んでも安く済みます。

`create(max_sprites, ...)` で決めたプールが満杯になると `allocate_link_id()` は `-1` を
返します。動的に生成する場合は必ず確認してください。

```gdscript
var link_id: int = _server.allocate_link_id(BULLET_SPRITE_ID)
if link_id < 0:
	return  # プール満杯。この弾は諦めます
```

消滅時は `destroy_sprite(link_id)` で返却します。忘れるとプールが枯れます。

## 5. レイヤー

スプライトは `plane_type` で 5 枚のプレーンのいずれかへ描かれます。

| `plane_type` | プレーン | 用途の例 |
|---|---|---|
| `0` | 背景 | 背景、地形 |
| `1` | 中景（既定） | 敵、自機、弾 |
| `2` | 前景 | 手前の障害物 |
| `3` | エフェクト | 何よりも手前に出す爆発 |
| `4` | テキスト | スプライト文字HUD |

3 と 4 は `set_effect_plane_rid()` / `set_text_plane_rid()` を呼んだ場合だけ有効で、
未設定なら中景として扱われます。

同じプレーン内の前後関係は `priority` で決まります。値が大きいほど後に描かれ、手前に
出ます。

```gdscript
_link_id = _server.allocate_link_id(sprite_id, false, false, 2, 10)   # 前景へ
_server.update_sprite(_link_id, pos, 0, Color.WHITE, 0, 5)            # 背景へ移す
```

`plane_type` と `priority` に `-1` を渡すと現在値を維持します。

## 6. 反転と拡縮

反転は確保時に指定でき、いつでも変更できます。

```gdscript
_server.set_sprite_flip(_link_id, true, false)   # 左向き
```

反転は transform で行い、原点のずれを補正するため、反転しても位置は変わりません。
座標は中心基準ではなく**左上基準**です。

サイズ変更は 2 通りあります。

```gdscript
_server.update_sprite_scaled(_link_id, pos, Vector2(2.0, 2.0))      # 2倍
_server.update_sprite_stretched(_link_id, pos, Vector2(64.0, 32.0)) # 64x32 ピクセル
```

注意点が 1 つあります。**素の `update_sprite()` は描画サイズを既定へ戻します。**
拡縮を維持したいスプライトには、毎フレーム拡縮版の方を呼び続けてください。同じ
スプライトに両方を混ぜないのがコツです。

`color` は乗算です。暗くしたり色を付けたりはできますが、色の付いたスプライトを白へ
することはできません。被弾フラッシュには `Color(1.8, 1.8, 1.8)` のような
オーバーブライトな色を使います。ただし RGB が真っ黒なピクセルは、いくら値を上げても
黒のままです。

## 7. コードではなく定義ファイルで登録する

`sprite_textures[id] = {...}` を手書きするのは 10 個目あたりで限界が来ます。定義
ファイルにすると JSON 側にまとまります。

```json
{
  "version": 2,
  "atlases": { "main": "res://art/atlas.png" },
  "sprites": [
    {
      "id": 0, "name": "PLAYER", "atlas": "main",
      "layout": "row", "rect": [0, 0, 16, 16], "frame_count": 4,
      "draw_size": [16, 16]
    }
  ]
}
```

登録は 1 行です。

```gdscript
TKSpriteRegistry.register_all(_server, "res://devdata/sprite_definitions.json")
```

コードから id を消したい場合は名前で引けます。

```gdscript
var defs: Dictionary = TKSpriteDefinitions.load_file(DEFS_PATH)
var player_id: int = TKSpriteRegistry.get_sprite_id_by_name(defs, "PLAYER")
```

JSON を手書きする必要もありません。プラグインを有効にすると、エディタ下部に
**Sprite Definitions** パネルが出て、アトラス上でフレーム矩形を指定して保存できます。
スキーマの全項目は [sprite_definitions.md](sprite_definitions.md)、Aseprite を使う場合は
[aseprite.md](aseprite.md) を参照してください（書き出したシートを 1 行で取り込め、
再インポートしても id は変わりません）。

## 8. 向きを持つスプライト

進行方向を向く自機・追尾ミサイル・回転する岩などは、全角度の絵を用意する必要は
ありません。`rotated` を指定すれば、1 枚の元絵から読み込み時にアトラスが生成されます。

```json
{
  "id": 5, "name": "MISSILE", "atlas": "main",
  "layout": "rotated", "rect": [0, 64, 16, 16],
  "original_orientation": 64, "roughness": 3,
  "draw_size": [16, 16]
}
```

方向番号は**時計回りに 0〜255**で、`0` が右、`64` が下、`128` が左、`192` が上です。
`original_orientation` は元絵がどちらを向いているかを表します。`roughness` は生成
枚数で、`3` なら 32 方向、`4` なら 16 方向、`0` なら 256 方向すべてです。

実行時は角度をフレーム番号へ変換します。

```gdscript
var direction: int = int(velocity.angle() / TAU * 256.0) & 255
var frame: int = TKSpriteAtlasBuilder.direction_to_frame_index(direction, 3)
_server.update_sprite(_link_id, pos, frame)
```

その場で回るだけのコインやアイテムには、`layout: "spin"` と `frame_count` を指定し、
通常のアニメーションとして再生します。

回転は最近傍補間なのでドット絵が滲みません。生成結果はプロセス内でキャッシュされ
ますが、多数のスプライトで多方向を生成すると読み込み時間はそれなりに掛かります。
`register_all()` の `progress_callback` 引数はそのためのものです。

## 9. スプライト文字HUD

フォントがスプライトシート（1 文字 1 フレーム）になっていれば、そのまま文字表示に
使えます。

```gdscript
_server.set_text_plane_rid(text_plane)
# 8x8 ピクセルのセルを 40x30、グリフ0 が sprite_id 200、プレーン4 へ
_server.init_sprite_text(40, 30, 8, 8, 200, 4, 0)

func _update_hud() -> void:
	_server.sprcls()
	_server.sprlocate(2, 1)
	_server.sprprint("SCORE")
	_server.sprlocate(8, 1)
	_server.sprprintint(score, 7)   # 7桁ゼロ埋め
```

グリフ *n* は `glyph_base_id + n` の sprite_id で描かれるので、フォントはその順に
並べてください。

## 10. 終了処理

サーバーは `RenderingServer` の RID を保持しています。ノードが消えても自動では解放
されません。

```gdscript
func _exit_tree() -> void:
	if _server != null:
		_server.free_all_rids()
```

実行中にサーバーを作り直す場合（バックエンド切り替えなど）も、破棄する前に同じ処理が
必要です。忘れるとセッション中ずっと RID が残ります。

## 11. うまく使うために

- **`commit_frame()` は毎フレーム最後に1回だけ。** 何度も呼べば無駄が増え、呼び忘れ
  れば何も描かれません。
- **link_id は使い回す。** 毎フレーム確保しないでください。使い捨て描画が本当に必要な
  ときだけ `request_draw()` を使います（呼ぶたびに一時スロットを消費します）。
- **プールは最悪ケースに合わせる。** `create(max_sprites, ...)` は先に確保する方式で、
  上限に達すると自動で増えずに `allocate_link_id()` が失敗します。
- **dirty フラグと戦わない。** 同じ値を渡す分にはほぼ無料なので、「動いたかどうか」を
  自前で管理する必要はありません。
- **スプライト登録は読み込み時に。** `TKSpriteRegistry` と `TKSpriteDefinitions` は
  起動時とツール用です。フレームループへ持ち込まないでください。
- **バックエンド名はキャッシュする。** HUD に出す場合、毎フレーム取得しないこと。

## 12. 困ったときは

**何も表示されない。**
順に確認してください。`commit_frame()` を呼んでいますか。`set_plane_rids()` は
呼びましたか。プレーンの canvas_item を canvas にぶら下げましたか
（`RenderingServer.canvas_item_set_parent(rid, get_canvas())`）。サーバーを
`add_child()` しましたか。その sprite_id は `sprite_textures` に入っていますか。

**`get_backend_name()` が `gdscript` を返す。**
そのプラットフォーム向けのバイナリが無いか、エディタが拡張を再スキャンしていません。
エディタを一度再起動してください。不足メソッド名を挙げる警告が出ている場合は、
バイナリが GDScript 側より古いので、ビルドし直すか更新してください。

**`allocate_link_id()` が `-1` を返す。**
プールが満杯です。`create()` の `max_sprites` を増やすか、消滅時に
`destroy_sprite()` を呼べているか確認してください。

**拡縮したスプライトが元のサイズに戻る。**
どこかで素の `update_sprite()` を呼んでいます。そのスプライトには
`update_sprite_scaled()` か `update_sprite_stretched()` を一貫して使ってください。

**反転したスプライトが幅の分ずれる。**
原点補正を通っていないことになります。反転は `set_sprite_flip()` か
`allocate_link_id()` の引数で設定してください。

**矩形がアトラス範囲を食み出すと警告が出る。**
フレーム矩形が画像からはみ出しています。`row` レイアウトでは帯全体が収まる必要が
あり、`x + 幅 * frame_count` がアトラス内に入っていなければなりません。
`TKSpriteDefinitions.validate()` を通すと、この種の問題を一度に列挙できます。
