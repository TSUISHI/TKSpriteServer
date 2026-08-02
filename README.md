# TKSpriteServer

Godot 4 用の高スループット 2D スプライトサーバーです。
GDExtension (C++) 実装と、API 互換の純 GDScript 実装を同梱し、
実行時に自動で切り替えます（DLL が無い環境でも動作します）。

- リンクID方式のスプライトプール（数万枚規模）
- MultiMesh バッチ描画 / dirty フラグによる差分更新
- 5 レイヤーのプレーン管理
- スプライト文字 HUD（`sprlocate` / `sprprint` / `sprcls`）
- JSON スプライト定義システム + 視覚的定義エディタ
- Aseprite 連携（エクスポート JSON 取り込み、.aseprite 直読み）

## 性能

`demo/demo_stress.tscn` での実測（`_update_sprites` + `commit_frame` の 60 フレーム平均、
Windows / Godot 4.6.3。GPU 負荷や vsync 待ちは含みません）。

| スプライト数 | GDExtension | GDScript フォールバック |
|---|---|---|
| 10,000 | **7.2 – 8.5 ms/frame** | 82 – 87 ms/frame |
| 20,000 | **15.0 – 16.6 ms/frame** | 61 – 167 ms/frame |

ネイティブ実装は体数に対してほぼ線形で、フレーム時間も安定しています。

**現在の状態: Phase 2 完了（コア実装 + Windows ビルド）。定義システムと Aseprite 連携は実装中。**

## フォルダ構成

| パス | 内容 |
|---|---|
| `addons/tk_sprite_server/` | 配布するアドオン本体 |
| `native/` | GDExtension の C++ ソース（`.gdignore` 済み・エクスポート対象外） |
| `demo/` | デモシーンとプレースホルダアセット |
| `docs/` | 利用者向けドキュメント |
