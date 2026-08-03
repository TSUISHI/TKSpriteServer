# Aseprite 連携

English: see [aseprite.md](aseprite.md).

TKSpriteServer は、Aseprite がスプライトシートと一緒に書き出す JSON を読めます。フレーム
矩形・表示時間・タグを手で打ち直す必要はありません。

書き出し工程を挟まず、`.aseprite` を直接読むこともできます（Aseprite 本体は不要です）。
下の「[`.aseprite` を直接読む](#aseprite-を直接読む)」を参照してください。

## Aseprite からの書き出し

*File → Export Sprite Sheet* で **Output → JSON Data** を有効にするか、CLI を使います。

```bash
aseprite -b player.aseprite --sheet player.png --data player.json --format json-array --list-tags
```

`--format json-array` と `--format json-hash` の両方に対応します。タグを取り込みたい場合は
`--list-tags` を、トリムしたい場合は `--trim` を付けてください。トリムは扱えて、フレーム
ごとの原点補正は `offsets` に入ります。

## 取り込み

定義ファイルの読み込み・マージ・保存を 1 回で行えます。

```gdscript
TKAsepriteImporter.import_sheet_into_file(
	"res://art/player.json",           # Aseprite のデータJSON
	"res://devdata/sprite_definitions.json",
	false,                             # split_by_tag
	"PLAYER",                          # スプライト名（既定はファイル名）
	"main"                             # アトラス別名
)
```

定義ファイルが無ければ新規作成します。

`split_by_tag = true` にすると、Aseprite のタグごとに別スプライトへ分割されます
（`PLAYER_WALK`、`PLAYER_JUMP` など。各々 0 基準のフレーム範囲を持ちます）。`false` なら
1 つのスプライトになり、範囲は `tags` に入ります。

## 対応関係

| Aseprite | 定義ファイル |
|---|---|
| `frame` | `frames` |
| `duration` | `durations` |
| `spriteSourceSize` | `offsets` — すべて 0 のときは出力しません |
| `sourceSize` | `source_size` |
| `frameTags` | `tags` |
| 最初のスライスの pivot | `pivot` |
| — | `source: { "type": "aseprite", "file": ... }` |

## 再インポート

ここがこのワークフローの要点です。

**スプライトは名前で照合されます。** 既存の名前は sprite_id を維持するため、絵を更新
しても、ゲームコードは何も変える必要がありません。新しい名前には `max_id + 1` が
割り当てられます。

**手編集は残ります。** `draw_size` / `comment` / `extras` は前の項目から引き継がれるため、
エディタパネルや手作業で調整した内容が、作業者の再書き出しで消えることはありません。

フレームデータ自体は置き換わります。それが再インポートの目的だからです。

## フレーム順序についての注意

`--format json-hash` ではフレームがファイル名をキーとする辞書で届きますが、そのキーは
**名前の末尾の数値**で並べ替えています。文字列として並べ替えると `player 10` が
`player 2` より前に来て、アニメーションが静かに壊れるためです。この形式を扱うツールを
自作する場合も同じ処理が必要です。

## `.aseprite` を直接読む

書き出し工程を挟まない経路もあります。`.aseprite` ファイルそのものを指定してください。
Aseprite 本体は不要です。ファイルは GDScript で解析します。

```gdscript
TKAsepriteImporter.import_aseprite_into_file(
	"res://art/player.aseprite",       # 元ファイル
	"res://art/player.png",            # 書き出すシートPNG
	"res://devdata/sprite_definitions.json",
	false,                             # split_by_tag
	"PLAYER",                          # スプライト名（既定はファイル名）
	"main"                             # アトラス別名
)
```

レイヤーは下から順に合成されてフレーム1枚の画像になり、それらが横一列に並べられて、
指定したパスへPNGとして書き出されます。そこから先はJSON経路とまったく同じ処理へ合流する
ため、**名前による照合・IDの維持・手編集のマージはすべて同じ挙動**です。上の「再インポート」
の内容がそのまま当てはまります。

画素だけが欲しい場合は、パーサ単体でも使えます。

```gdscript
var doc: Dictionary = TKAsepriteFile.load_file("res://art/player.aseprite")
var images: Array = TKAsepriteFile.build_frame_images(doc)   # RGBA8 の Image 配列
var durations: Array = TKAsepriteFile.get_frame_durations(doc)
```

`doc` には `layers` / `tags` / `palette` / `pivot` も入っているため、独自の処理を組むこと
もできます。

### 対応範囲

| 項目 | 対応 |
|---|---|
| カラーモード | RGBA / グレースケール / インデックス（透明色番号を反映） |
| セル種別 | 生画素 / リンク / zlib圧縮 |
| レイヤー | 可視性と不透明度、グループは飛ばす、入れ子の深さは任意 |
| メタ情報 | タグ、パレット、最初のスライスの pivot |

Normal 以外のブレンドモードは Normal として扱い、レイヤーごとに1回だけ警告します。
タイルマップレイヤーとタイルセットは読みません。どちらも意図的な割り切りです。完全な
再現は費用が大きく、スプライト用途での見返りが小さいためです。

### どちらの経路を使うか

すでにビルド工程で Aseprite を走らせている場合や、パッキングを細かく制御したい場合
（`--sheet-type packed`、`--trim`）は書き出し経路が向いています。直読み経路が作るシートは
キャンバス原寸のフレームを順に並べただけで、単純で予測しやすい代わりに詰まっていません。

リポジトリに置く素材を `.aseprite` だけにしたい、書き出し忘れを無くしたい場合は直読み
経路が向いています。
