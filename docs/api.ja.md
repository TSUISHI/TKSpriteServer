# API リファレンス

English: see [api.md](api.md).

すべてのクラスはプラグインがグローバル登録するため、`preload()` なしで使えます。
サーバー本体以外はすべて静的ユーティリティクラスです。

- [`TKSpriteServer`](#tkspriteserver) — バックエンド選択のファサード
- [サーバーインスタンス](#サーバーインスタンス) — スプライトサーバー本体
- [`TKSpriteRegistry`](#tkspriteregistry) — 定義ファイルをサーバーへ登録
- [`TKSpriteDefinitions`](#tkspritedefinitions) — 定義ファイルの読み書き・検証
- [`TKSpriteAtlasBuilder`](#tkspriteatlasbuilder) — 回転・スピンアトラスの生成
- [`TKAsepriteImporter`](#tkaspriteimporter) — Aseprite 書き出しの取り込み

JSON スキーマは [sprite_definitions.ja.md](sprite_definitions.ja.md)、Aseprite の手順は
[aseprite.ja.md](aseprite.ja.md) を参照してください。

---

## TKSpriteServer

静的ファサードです。自身はインスタンス化されず、サーバーを生成します。

### `static create(max_sprites: int = 4096, pixel_snap: bool = true, prefer_native: bool = true) -> Object`

サーバーを生成し、`setup()` まで済ませて返します。

ネイティブ実装が `ClassDB` に登録済みで、**かつ**互換メソッドをすべて備えている場合に
ネイティブが選ばれます。そうでなければ GDScript 実装が使われ、不足メソッド名を挙げた
警告が出ます。`prefer_native = false` を渡すと強制的に GDScript 実装になります
（ストレスデモの比較機能がこれを使っています）。

`pixel_snap` は描画位置を整数へ丸めます。ドット絵では通常 true にします。

**戻り値は `Node` です。** 必ず自分でシーンツリーへ入れてください。

```gdscript
var server: Object = TKSpriteServer.create(4096, true)
add_child(server)
```

### `static is_native_available() -> bool`

GDExtension のクラスが存在し、インスタンス化できるかを返します。API 互換性までは見ません
（それは `create()` が行います）。

### `static get_backend_name(server: Object) -> String`

`"native"` / `"gdscript"` / `"unknown"` を返します。デバッグ HUD 向けです。

---

## サーバーインスタンス

両バックエンドの API は同一なので、以下は `create()` がどちらを返しても同じように使えます。

### 初期化

| メソッド | 内容 |
|---|---|
| `setup(max_sprites: int, pixel_snap: bool)` | プールを確保します。`create()` が呼ぶので通常は不要 |
| `set_plane_rids(back: RID, medium: RID, front: RID)` | 描画先の canvas_item 3 枚 |
| `set_effect_plane_rid(plane_rid: RID)` | 任意の 4 枚目 |
| `set_text_plane_rid(plane_rid: RID)` | スプライト文字HUD 用のプレーン |

canvas_item は `RenderingServer.canvas_item_create()` で作り、自ノードの canvas へ
ぶら下げます。

```gdscript
var back: RID = RenderingServer.canvas_item_create()
RenderingServer.canvas_item_set_parent(back, get_canvas())
```

### プレーンと優先度

`plane_type` で描画先を選びます。

| 値 | プレーン |
|---|---|
| `0` | 背景 |
| `1` | 中景（既定） |
| `2` | 前景 |
| `3` | エフェクト — `set_effect_plane_rid()` 未設定なら中景 |
| `4` | テキスト — `set_text_plane_rid()` 未設定なら中景 |

それ以外の値は中景として扱われます。

`priority` は**同一プレーン内**の順序です。canvas_item の draw index になるため、値が
大きいほど後に描かれ、手前に出ます。

### スプライト表

描画する前に `server.sprite_textures` へ登録が必要です。

```gdscript
server.sprite_textures[sprite_id] = {
	"texture": my_texture,                       # Texture2D
	"frames": [Rect2(0, 0, 16, 16), ...],        # フレームごとの Rect2
}
server.set_sprite_draw_size(sprite_id, Vector2(32, 32))
```

ネイティブ実装では `sprite_textures` は通常のメンバではなくバインドされたプロパティ
です。読み出すと複製が返るため、多数登録するときは辞書を組み立ててから**一度だけ**
代入してください。`TKSpriteRegistry` はそうしています。

| メソッド | 内容 |
|---|---|
| `set_sprite_draw_size(sprite_id: int, size: Vector2)` | その sprite_id の既定描画サイズ |
| `get_sprite_draw_size(sprite_id: int) -> Vector2` | 登録済みサイズ。未登録なら**先頭フレームのサイズ**を返します（ゼロではありません） |

### 永続スプライト

| メソッド | 内容 |
|---|---|
| `allocate_link_id(sprite_id, flip_h = false, flip_v = false, plane_type = 1, priority = 0) -> int` | スロットを確保して link_id を返します。満杯時は `-1` |
| `update_sprite(link_id, pos, frame = 0, color = Color.WHITE, plane_type = -1, priority = -1)` | 位置・フレーム・色。`-1` は現在値維持。**描画サイズは既定へ戻ります** |
| `update_sprite_scaled(link_id, pos, scale: Vector2, ...)` | 倍率指定 |
| `update_sprite_stretched(link_id, pos, draw_size: Vector2, ...)` | ピクセルサイズ指定 |
| `set_sprite_flip(link_id, flip_h: bool, flip_v: bool)` | 確保後の反転変更 |
| `get_sprite_flip(link_id) -> Vector2i` | 現在の反転を `(h, v)` で返します |
| `get_sprite_id_from_link(link_id) -> int` | link_id の sprite_id |
| `destroy_sprite(link_id)` | スロットをプールへ返却 |

`color` は**乗算**です。色付きスプライトを白くすることはできません。被弾フラッシュには
`Color(1.8, 1.8, 1.8)` のようなオーバーブライト色を使いますが、RGB が真っ黒なピクセルは
どれだけ上げても黒のままです。

`allocate_link_id()` の戻り値は必ず確認してください。`-1` はプール満杯で、サーバー側の
`sprite_buffer_over` フラグも立ちます。

### 使い捨て描画

`request_draw(sprite_id, pos, flip_h, flip_v, plane_type, priority)` は link_id を持たずに
1 フレームだけ描画します。内部では一時スロットを確保し、次の `commit_frame()` で解放
されるため、プール容量は通常のスプライトと同様に消費します。

### フレームの流れ

`commit_frame()` が有効スロットを `RenderingServer` へ反映し、一時スロットを解放します。
**毎フレーム、すべての更新のあとに 1 回だけ呼んでください。** 呼ばないと何も描画されません。

| メソッド | 内容 |
|---|---|
| `clear_all()` | 全スプライトを解放（プールは維持） |
| `free_all_rids()` | canvas_item の RID を解放。サーバー破棄前に必ず |
| `get_stats() -> Dictionary` | プール使用状況と `"backend"` |

### スプライト文字HUD

グリフをスプライトとして持つフォント用の文字レイヤーです。

| メソッド | 内容 |
|---|---|
| `init_sprite_text(cols, rows, cell_width, cell_height, glyph_base_id, plane_type, priority)` | 桁数・セルサイズ・グリフ0 の sprite_id |
| `sprlocate(col: int, row: int)` | カーソル移動 |
| `sprprint(text: String)` | カーソル位置へ出力 |
| `sprprintint(value: int, digits: int)` | ゼロ埋め整数の出力 |
| `sprcls()` | 文字レイヤーの消去 |

グリフ *n* は `glyph_base_id + n` の sprite_id で描かれます。

---

## TKSpriteRegistry

定義ファイルを登録済みスプライトへ変換します。起動時専用で、毎フレーム呼んではいけません。

### `static register_all(server, defs_path: String, draw_size_scale: Vector2 = Vector2.ONE, progress_callback: Callable = Callable()) -> int`

定義ファイルを読み込み、含まれるスプライトをすべて登録して件数を返します。読み込めなければ
`0` です。`rotated` と `spin` のアトラス生成はここで行われるため、進捗コールバックを
受け取れます。

`draw_size_scale` はファイル内の `draw_size` すべてに掛かります。ゲームの論理単位と画面
ピクセルが異なる場合に使います（座標変換自体は利用側の責任です）。

### `static register_defs(server, defs: Dictionary, draw_size_scale = Vector2.ONE, progress_callback = Callable()) -> int`

読み込み済みの定義から登録します。検証結果は警告として出力され、壊れた項目はスキップ
されます（読み込み全体は中断しません）。

### `static get_sprite_id_by_name(defs: Dictionary, sprite_name: String) -> int`

名前から id を引きます。ゲームコードから数値を追放するために使います。存在しなければ `-1`。

---

## TKSpriteDefinitions

定義ファイルの読み書きと検証のみを行い、テクスチャの load やサーバーへの登録はしません。
起動時とツール用です。

| メソッド | 内容 |
|---|---|
| `static load_file(path: String) -> Dictionary` | 読み込んで v2 形式へ正規化。失敗時は空 |
| `static parse_text(text: String, source_label := "(text)") -> Dictionary` | JSON 文字列から同様に |
| `static normalize_defs(parsed: Dictionary) -> Dictionary` | パース済み辞書の正規化 |
| `static save_file(path: String, defs: Dictionary, keep_v1: bool = false) -> bool` | 保存。`keep_v1` で v1 形式へ戻します |
| `static validate(defs: Dictionary, atlas_sizes: Dictionary) -> Array` | 矩形のはみ出しなどを列挙 |
| `static get_frame_count(sprite: Dictionary) -> int` | レイアウトによらないフレーム数 |
| `static get_tag_range(sprite: Dictionary, tag_name: String) -> Vector2i` | タグの開始・終了フレーム |

v1 ファイルはそのまま読め、戻り値は常に v2 形式なので、利用側がバージョンで分岐する必要は
ありません。元のバージョンは `source_version` に残ります。既定値のままのキーは保存時に
出力されないため、v1 由来のファイルを読んで保存し直しても差分が増えません。

---

## TKSpriteAtlasBuilder

1 枚の元絵から実行時にアトラスを生成します。生成パラメータをキーにプロセス内で
キャッシュされ、`clear_cache()` で解放できます。

各生成関数の戻り値は次の形です。

```gdscript
{
	"texture": ImageTexture,
	"frames": Array,        # Array[Rect2]。そのまま sprite_textures へ
	"image": Image,
	"frame_size": Vector2i,
	"total_frames": int,
}
```

空辞書は失敗を意味します。

### 方向番号

1 周を **256 方向**とし、時計回りに増えます。`0` が右、`64` が下、`128` が左、`192` が上です。
`original_orientation` は元絵がどちらを向いているかを表します。

### `static build_rotated(image_path, crop_rect: Rect2i, original_orientation := 64, roughness := 4, progress_callback := Callable()) -> Dictionary`

方向ごとに 1 フレームを生成します。`roughness` は枚数とメモリの兼ね合いです。

| roughness | フレーム数 | 刻み |
|---|---|---|
| 0 | 256 | 1.4° |
| 3 | 32 | 11.25° |
| 4（既定） | 16 | 22.5° |
| 6 | 4 | 90° |

実回転は第 1 象限のみで、残り 3 象限は反転で展開するため、生成コストは素朴な方法の 1/4 です。
回転は最近傍補間でドット絵が滲まず、45° 回転で角が欠ける場合はキャンバスを自動拡張します。

`build_rotated_from_image(source: Image, ...)` はファイル読み込みとキャッシュを伴わない版です。

### `static build_spin(image_path, crop_rect: Rect2i, original_orientation: int, frame_count: int, visual_period_dirs := 256) -> Dictionary`

コインなど、その場で回るものの等間隔アニメを生成します。`visual_period_dirs` は絵の見た目が
1 周する方向数で、全周なら `256`、4 回対称の絵なら `64` です。

`build_spin_from_image(source: Image, ...)` はキャッシュなしの版です。

### 補助関数

| メソッド | 内容 |
|---|---|
| `static direction_to_frame_index(direction: int, roughness: int) -> int` | 方向番号を回転アトラスのフレーム番号へ |
| `static rotate_image_nearest(source: Image, angle_rad: float, out_w: int, out_h: int) -> Image` | 内部で使う最近傍回転 |
| `static load_source_image(path: String) -> Image` | 未インポートのファイルも読める画像読み込み |
| `static save_atlas_png(result: Dictionary, path: String) -> bool` | 生成結果の書き出し（焼き込み用） |
| `static clear_cache()` | プロセス内キャッシュの解放 |

---

## TKAsepriteImporter

`aseprite --data` が出力する JSON を取り込みます。手順は
[aseprite.ja.md](aseprite.ja.md) を参照してください。

| メソッド | 内容 |
|---|---|
| `static import_sheet_into_file(json_path, defs_path, split_by_tag := false, sprite_name := "", atlas_alias := "") -> bool` | 読み込み・マージ・保存を 1 回で |
| `static import_sheet(json_path, existing_defs, split_by_tag := false, sprite_name := "", atlas_alias := "") -> Dictionary` | マージのみ |

`--format json-array` と `--format json-hash` の両方に対応します。

**再インポートの契約:** スプライトは**名前で照合**されます。既存の名前は id を維持し、
新しい名前には `max_id + 1` が割り当てられます。`draw_size` / `comment` / `extras` は
前の項目から引き継がれるため、手編集は再インポートで失われません。
