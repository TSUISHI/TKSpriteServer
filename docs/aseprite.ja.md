# Aseprite 連携

English: see [aseprite.md](aseprite.md).

TKSpriteServer は、Aseprite がスプライトシートと一緒に書き出す JSON を読めます。フレーム
矩形・表示時間・タグを手で打ち直す必要はありません。

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

## 今後の予定

書き出し工程を挟まずに `.aseprite` を直接読む機能は計画中で、まだ実装されていません。
それまでは上記の書き出し経由が正式な手順です。
