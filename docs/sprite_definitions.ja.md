# スプライト定義ファイル

English: see [sprite_definitions.md](sprite_definitions.md).

定義ファイルは、全スプライトを 1 つの JSON にまとめたものです。スプライトごとにコードを
書く代わりに、`TKSpriteRegistry.register_all()` の 1 回で登録できます。手書きしても、
エディタ下部の **Sprite Definitions** パネルで編集しても、
[Aseprite インポータ](aseprite.ja.md)で生成しても構いません。

## ファイル全体の形

```json
{
  "version": 2,
  "atlases": {
    "main": "res://art/atlas.png"
  },
  "sprites": [
    { "id": 0, "name": "PLAYER", "atlas": "main", "layout": "row",
      "rect": [0, 0, 16, 16], "frame_count": 4, "draw_size": [16, 16] }
  ]
}
```

| キー | 意味 |
|---|---|
| `version` | `1` または `2`。どちらも読め、戻り値は常に v2 形式 |
| `atlases` | 別名 → 画像パス。スプライトは別名で参照するので、パス変更は 1 か所 |
| `sprites` | スプライトの配列。慣例として `id` 順に並べます |

## スプライト項目

`id` / `atlas` / `layout` は必須です。欠けた項目は警告付きでスキップされ、ファイルの
残りは読み込まれます。

| キー | 型 | 既定 | 意味 |
|---|---|---|---|
| `id` | int | — | 実行時に使う sprite_id |
| `name` | String | `SPRITE_<id>` | 名前。再インポート時の照合キーでもあります |
| `atlas` | String | — | `atlases` の別名 |
| `layout` | String | — | `single` / `row` / `frames` / `rotated` / `spin` |
| `rect` | `[x, y, w, h]` | — | 元矩形。`frames` 以外のレイアウトで必須 |
| `frames` | `[[x, y, w, h], ...]` | — | 矩形の明示列挙。`frames` 専用 |
| `frame_count` | int | — | `row` と `spin` のフレーム数 |
| `draw_size` | `[w, h]` | フレームサイズ | 画面上の描画サイズ |
| `original_orientation` | int | `64` | 元絵が向いている方向（`rotated` / `spin`） |
| `roughness` | int | `4` | `rotated` の生成方向数。`0`〜`6` |
| `visual_period_dirs` | int | `256` | `spin` で見た目が 1 周する方向数 |
| `durations` | `[ms, ...]` | `[]` | フレームごとの表示時間。保持のみで、再生は利用側 |
| `offsets` | `[[x, y], ...]` | `[]` | フレーム原点の補正。トリム付き Aseprite 書き出しで入ります |
| `source_size` | `[w, h]` | `[]` | トリム前のサイズ |
| `pivot` | `[x, y]` | `[0, 0]` | 描画基準点。既定は左上（v1 互換） |
| `tags` | `{ 名前: [from, to] }` | `{}` | 名前付きフレーム区間。両端を含む 0 基準 |
| `source` | Dictionary | `{}` | 生成元の記録。保持のみで解釈しません |
| `generated` | bool | `false` | インポータ生成かどうか。手編集との衝突検出用 |
| `extras` | Dictionary | `{}` | 利用側の自由領域。解釈しません |
| `comment` | String | — | 自由記述メモ |

## レイアウト

**`single`** — `rect` そのもの 1 枚。

**`row`** — `rect` を先頭に横並びで `frame_count` 枚。帯全体が収まる必要があり、
`x + w * frame_count` がアトラス内に入っていなければなりません。

**`frames`** — 矩形をすべて明示列挙します。等間隔でない、あるいは 1 行に並んでいない
場合に使います。

**`rotated`** — `rect` の 1 枚絵から全方向のフレームを、登録時に
`TKSpriteAtlasBuilder.build_rotated()` で生成します。

**`spin`** — 1 枚絵からその場で回る等間隔アニメ `frame_count` 枚を生成します。コインや
アイテム向けです。

方向番号は時計回りに 0〜255 で、`0` が右、`64` が下、`128` が左、`192` が上です。
`roughness` は生成枚数で、`0` = 256 枚、`3` = 32 枚、`4` = 16 枚、`6` = 4 枚です。

## v1 との互換

v1 ファイルはそのまま読めます。読み込み後は次のようになります。

- 戻り値は常に v2 形式で、省略値は既定値で補完されるため、利用側はバージョンを意識
  しません。
- 元のバージョンは `source_version` に残ります。
- v1 固有の `native_bullet` は `extras` へ移り、`save_file(path, defs, true)` で
  `native_bullet` として書き戻せます。

`save_file()` は既定値のままのキーを出力しないため、v1 ファイルを読んで保存し直しても
差分が増えません。キー順もアルファベット順にせず保持します（`version`・`atlases`・
`sprites` の順、各項目内は `id` が `name` より先）。差分を読みやすく保つためです。

## 検証

```gdscript
var defs: Dictionary = TKSpriteDefinitions.load_file(path)
var sizes: Dictionary = TKSpriteRegistry.get_atlas_sizes(
	TKSpriteRegistry.resolve_atlas_textures(defs["atlases"]))
for finding in TKSpriteDefinitions.validate(defs, sizes):
	print(finding)
```

`validate()` は、アトラスからはみ出す矩形、フレーム数と長さが合わない `durations` /
`offsets`、範囲外のタグ、未知のレイアウトを報告します。`register_all()` が自動で実行して
警告を出すため、これを直接使うのはツールを書くときだけです。
