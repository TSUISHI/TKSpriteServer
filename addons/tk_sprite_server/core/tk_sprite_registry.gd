# tk_sprite_registry.gd — 定義JSONを読み、スプライトをサーバーへ登録する
#
# 2Dレトロゲームの register_sprites_from_defs() を公開ライブラリ向けに移植したものです。
# 定義の読み込み（TKSpriteDefinitions）と回転アトラス生成（TKSpriteAtlasBuilder）を
# つなぎ、バックエンド（native / GDScript）に依存しない形でサーバーへ登録します。
#
# 移植元からの主な変更点:
#   1. 定義ファイルのパスとサーバーを引数で受け取り、グローバル参照をなくした。
#   2. ゲーム座標→表示座標の変換（移植元の game_size_to_display）を持ち込まず、
#      draw_size_scale 引数として利用者に委ねた（公開コアは表示座標だけを扱う方針）。
#   3. 移植元のゲーム固有な弾種登録を外した。その情報は定義の extras に残るので、
#      必要な利用者は定義を読んで自分で登録できる。
#   4. rotated / spin は TKSpriteAtlasBuilder が返した結果をここで登録する
#      （移植元は生成関数の中で登録していた）。
#
# 設計書 §6.3
#
# 【メモリ規則】起動時とツール実行時にのみ使用します。毎フレーム呼んではいけません。

class_name TKSpriteRegistry extends RefCounted

# 定義で省略されたときの既定値です。
const DEFAULT_ORIGINAL_ORIENTATION: int = 64
const DEFAULT_ROUGHNESS: int = 4
const DEFAULT_VISUAL_PERIOD_DIRS: int = 256


# [register_all]
# 処理内容: 定義JSONを読み込み、含まれるスプライトをすべてサーバーへ登録します。
# 引数 server:            TKSpriteServer.create() が返したサーバーです。
# 引数 defs_path:         スプライト定義JSONのパスです。
# 引数 draw_size_scale:   定義の draw_size に掛ける倍率です（座標系変換は利用者側の責任）。
# 引数 progress_callback: 回転アトラス生成の進捗を受け取る任意のコールバックです。
# 戻り値: 登録できたスプライト数です。読み込みに失敗した場合は 0 です。
static func register_all(
	server: Object,
	defs_path: String,
	draw_size_scale: Vector2 = Vector2.ONE,
	progress_callback: Callable = Callable()
) -> int:
	var defs: Dictionary = TKSpriteDefinitions.load_file(defs_path)
	if defs.is_empty():
		push_error("TKSpriteRegistry: スプライト定義を読み込めませんでした: " + defs_path)
		return 0
	return register_defs(server, defs, draw_size_scale, progress_callback)
# [register_all]END


# [register_defs]
# 処理内容: 読み込み済みの定義からスプライトをサーバーへ登録します。
#           アトラス画像は別名ごとに1回だけ解決し、同じパスを何度も load しません。
# 引数 server:            サーバーです。
# 引数 defs:              TKSpriteDefinitions 形式の正規化済み定義です。
# 引数 draw_size_scale:   draw_size に掛ける倍率です。
# 引数 progress_callback: 回転アトラス生成の進捗コールバックです。
# 戻り値: 登録できたスプライト数です。
static func register_defs(
	server: Object,
	defs: Dictionary,
	draw_size_scale: Vector2 = Vector2.ONE,
	progress_callback: Callable = Callable()
) -> int:
	if server == null:
		push_error("TKSpriteRegistry: server が null です。")
		return 0

	var atlas_paths: Dictionary = defs.get("atlases", {})
	var atlas_textures: Dictionary = resolve_atlas_textures(atlas_paths)

	# 検証結果はログへ出します。ERROR の定義は登録段階で自然にスキップされます。
	for message in TKSpriteDefinitions.validate(defs, get_atlas_sizes(atlas_textures)):
		push_warning("TKSpriteRegistry: " + String(message))

	# サーバーのスプライト表を一度取り出し、まとめて書き戻します。
	# ネイティブ実装ではプロパティ経由のやり取りになるため、1件ずつ書き戻しません。
	var sprite_textures: Dictionary = server.sprite_textures
	var registered_count: int = 0

	for sprite in defs.get("sprites", []):
		var entry: Dictionary = build_registration_entry(sprite, atlas_paths, atlas_textures, progress_callback)
		if entry.is_empty():
			continue
		sprite_textures[int(sprite["id"])] = entry
		registered_count += 1

	server.sprite_textures = sprite_textures

	# 表示サイズは登録が済んでから設定します。
	for sprite in defs.get("sprites", []):
		if not sprite.has("draw_size"):
			continue
		var draw_size: Array = sprite["draw_size"]
		server.set_sprite_draw_size(
			int(sprite["id"]),
			Vector2(float(draw_size[0]), float(draw_size[1])) * draw_size_scale
		)

	return registered_count
# [register_defs]END


# [build_registration_entry]
# 処理内容: スプライト定義1件から、サーバーへ登録する { "texture", ... } を組み立てます。
#           single は "rect" 形式、row/frames/rotated/spin は "frames" 形式です。
# 引数 sprite:            正規化済みスプライト定義です。
# 引数 atlas_paths:       別名 → 画像パスの表です。
# 引数 atlas_textures:    別名 → Texture2D の表です。
# 引数 progress_callback: 回転アトラス生成の進捗コールバックです。
# 戻り値: 登録用 Dictionary。組み立て不能なら空 Dictionary です。
static func build_registration_entry(
	sprite: Dictionary,
	atlas_paths: Dictionary,
	atlas_textures: Dictionary,
	progress_callback: Callable = Callable()
) -> Dictionary:
	var alias: String = String(sprite.get("atlas", ""))
	if not atlas_textures.has(alias):
		# アトラスの解決失敗は resolve_atlas_textures() が報告済みです。
		return {}
	var layout: String = String(sprite.get("layout", TKSpriteDefinitions.LAYOUT_SINGLE))

	if layout == TKSpriteDefinitions.LAYOUT_ROTATED or layout == TKSpriteDefinitions.LAYOUT_SPIN:
		if not sprite.has("rect"):
			return {}  # validate() が ERROR 報告済みです。
		var r: Array = sprite["rect"]
		var crop_rect := Rect2i(int(r[0]), int(r[1]), int(r[2]), int(r[3]))
		var image_path: String = String(atlas_paths.get(alias, ""))
		var built: Dictionary = {}
		if layout == TKSpriteDefinitions.LAYOUT_ROTATED:
			built = TKSpriteAtlasBuilder.build_rotated(
				image_path,
				crop_rect,
				int(sprite.get("original_orientation", DEFAULT_ORIGINAL_ORIENTATION)),
				int(sprite.get("roughness", DEFAULT_ROUGHNESS)),
				progress_callback
			)
		else:
			built = TKSpriteAtlasBuilder.build_spin(
				image_path,
				crop_rect,
				int(sprite.get("original_orientation", DEFAULT_ORIGINAL_ORIENTATION)),
				int(sprite.get("frame_count", 1)),
				int(sprite.get("visual_period_dirs", DEFAULT_VISUAL_PERIOD_DIRS))
			)
		if built.is_empty():
			return {}
		return { "texture": built["texture"], "frames": built["frames"] }

	if layout == TKSpriteDefinitions.LAYOUT_SINGLE:
		if not sprite.has("rect"):
			return {}
		var single_rect: Array = sprite["rect"]
		return {
			"texture": atlas_textures[alias],
			"rect": Rect2(float(single_rect[0]), float(single_rect[1]), float(single_rect[2]), float(single_rect[3]))
		}

	# row / frames はアトラス上の矩形をそのまま並べます。
	var frames: Array[Rect2] = TKSpriteDefinitions.build_frames(sprite)
	if frames.is_empty():
		return {}  # validate() が ERROR 報告済みです。
	return { "texture": atlas_textures[alias], "frames": frames }
# [build_registration_entry]END


# [resolve_atlas_textures]
# 処理内容: アトラス別名 → Texture2D の表を作ります。インポートされていない画像も
#           ImageTexture として読み込みます。
# 引数 atlas_paths: 別名 → 画像パスの表です。
# 戻り値: 別名 → Texture2D の表です。読み込めなかった別名は含みません。
static func resolve_atlas_textures(atlas_paths: Dictionary) -> Dictionary:
	var atlas_textures: Dictionary = {}
	for alias in atlas_paths:
		var path: String = String(atlas_paths[alias])
		if ResourceLoader.exists(path):
			var res = load(path)
			if res is Texture2D:
				atlas_textures[String(alias)] = res
				continue
		# インポート済みリソースでない場合は画像として直接読み込みます。
		var image: Image = TKSpriteAtlasBuilder.load_source_image(path)
		if image == null:
			push_error("TKSpriteRegistry: アトラス画像を読み込めません: %s (%s)" % [String(alias), path])
			continue
		atlas_textures[String(alias)] = ImageTexture.create_from_image(image)
	return atlas_textures
# [resolve_atlas_textures]END


# [get_atlas_sizes]
# 処理内容: 検証用に、別名 → 画像サイズの表を作ります。
# 引数 atlas_textures: 別名 → Texture2D の表です。
# 戻り値: 別名 → Vector2i(幅, 高さ) の表です。
static func get_atlas_sizes(atlas_textures: Dictionary) -> Dictionary:
	var atlas_sizes: Dictionary = {}
	for alias in atlas_textures:
		var texture: Texture2D = atlas_textures[alias]
		atlas_sizes[alias] = Vector2i(texture.get_width(), texture.get_height())
	return atlas_sizes
# [get_atlas_sizes]END


# [get_sprite_id_by_name]
# 処理内容: 定義から名前でスプライトIDを引きます。定義に名前で書いておき、実行時は
#           IDで扱う使い方のための補助です。
# 引数 defs:        正規化済み定義です。
# 引数 sprite_name: 探すスプライト名です。
# 戻り値: スプライトID。見つからない場合は -1 です。
static func get_sprite_id_by_name(defs: Dictionary, sprite_name: String) -> int:
	for sprite in defs.get("sprites", []):
		if String(sprite.get("name", "")) == sprite_name:
			return int(sprite.get("id", -1))
	return -1
# [get_sprite_id_by_name]END
