# test_registry.gd — TKSpriteRegistry の自己完結テスト
#
# 実行方法:
#   Godot --headless --path <プロジェクト> --script res://tests/test_registry.gd
#
# 画像アセットには依存しません（テスト内で PNG と定義JSONを user:// へ生成します）。

extends SceneTree

var failure_count: int = 0

const ATLAS_PATH: String = "user://tk_test_registry_atlas.png"
const DEFS_PATH: String = "user://tk_test_registry_defs.json"


# [_initialize]
# 処理内容: テスト用アセットを用意し、全テストを実行します。
# 戻り値: なし
func _initialize() -> void:
	make_test_atlas()
	make_test_defs()

	test_register_all()
	test_draw_size_scale()
	test_missing_atlas()
	test_lookup_by_name()

	if failure_count == 0:
		print("test_registry: ALL PASS")
	else:
		print("test_registry: FAILED %d" % failure_count)
		quit(1)
		return
	quit(0)
# [_initialize]END


# [check]
# 処理内容: 1件の判定を記録します。失敗時はラベルを出力します。
# 引数 condition: 判定結果です。
# 引数 label: 失敗時に表示する内容です。
# 戻り値: なし
func check(condition: bool, label: String) -> void:
	if not condition:
		failure_count += 1
		print("  FAIL: " + label)
# [check]END


# [make_test_atlas]
# 処理内容: 16x16 のセルを縦に並べたテスト用アトラスPNGを作ります。
# 戻り値: なし
func make_test_atlas() -> void:
	var image := Image.create_empty(80, 64, false, Image.FORMAT_RGBA8)
	# 各セルの中央付近にだけ点を置きます（回転してもキャンバス拡張が起きない大きさ）。
	for cell_y in range(4):
		for cell_x in range(5):
			image.set_pixel(cell_x * 16 + 8, cell_y * 16 + 8, Color(1, 1, 1, 1))
			image.set_pixel(cell_x * 16 + 9, cell_y * 16 + 8, Color(1, 0, 0, 1))
	check(image.save_png(ATLAS_PATH) == OK, "テスト用アトラスPNGの保存に失敗")
# [make_test_atlas]END


# [make_test_defs]
# 処理内容: テスト用の定義JSONを書き出します。5種の layout をすべて含みます。
# 戻り値: なし
func make_test_defs() -> void:
	var defs: Dictionary = {
		"version": 2,
		"atlases": { "main": ATLAS_PATH },
		"sprites": [
			{ "id": 10, "name": "ONE", "atlas": "main", "layout": "single",
			  "rect": [0, 0, 16, 16], "draw_size": [16, 16] },
			{ "id": 11, "name": "ROW", "atlas": "main", "layout": "row",
			  "rect": [0, 16, 16, 16], "frame_count": 5 },
			{ "id": 12, "name": "EXPLICIT", "atlas": "main", "layout": "frames",
			  "frames": [[0, 32, 16, 16], [16, 32, 16, 16]] },
			{ "id": 13, "name": "ROT", "atlas": "main", "layout": "rotated",
			  "rect": [0, 48, 16, 16], "original_orientation": 64, "roughness": 4 },
			{ "id": 14, "name": "SPIN", "atlas": "main", "layout": "spin",
			  "rect": [16, 48, 16, 16], "original_orientation": 64,
			  "frame_count": 8, "visual_period_dirs": 256 }
		]
	}
	var file := FileAccess.open(DEFS_PATH, FileAccess.WRITE)
	check(file != null, "テスト用定義JSONを開けない")
	if file == null:
		return
	file.store_string(JSON.stringify(defs, "  "))
	file.close()
# [make_test_defs]END


# [make_server]
# 処理内容: テスト用の GDScript バックエンドを作ります。
# 戻り値: サーバーインスタンスです。
func make_server() -> Object:
	var server = TKSpriteServerGD.new()
	server.setup(256, true)
	return server
# [make_server]END


# [test_register_all]
# 処理内容: 5種の layout がそれぞれ正しい形式で登録されることを確認します。
# 戻り値: なし
func test_register_all() -> void:
	TKSpriteAtlasBuilder.clear_cache()
	var server = make_server()
	var registered_count: int = TKSpriteRegistry.register_all(server, DEFS_PATH)
	check(registered_count == 5, "登録数が 5 でない: %d" % registered_count)

	var textures: Dictionary = server.sprite_textures
	check(textures.has(10) and textures.has(11) and textures.has(12) and textures.has(13) and textures.has(14), "登録されていないIDがある")

	# single は rect 形式です。
	var single_entry: Dictionary = textures[10]
	check(single_entry.has("rect"), "single が rect 形式で登録されていない")
	check((single_entry["rect"] as Rect2) == Rect2(0, 0, 16, 16), "single の rect が不正")
	check(single_entry["texture"] is Texture2D, "single の texture が Texture2D でない")

	# row / frames は frames 形式です。
	check((textures[11]["frames"] as Array).size() == 5, "row のフレーム数が 5 でない")
	check((textures[11]["frames"] as Array)[4] == Rect2(64, 16, 16, 16), "row の最終フレーム矩形が不正")
	check((textures[12]["frames"] as Array).size() == 2, "frames のフレーム数が 2 でない")
	# row / frames は元のアトラス画像をそのまま参照します。
	check(textures[11]["texture"] == textures[12]["texture"], "row と frames が同じアトラスを共有していない")

	# rotated / spin は生成されたアトラスを参照します。
	check((textures[13]["frames"] as Array).size() == 16, "rotated のフレーム数が 16 でない")
	check((textures[14]["frames"] as Array).size() == 8, "spin のフレーム数が 8 でない")
	check(textures[13]["texture"] != textures[11]["texture"], "rotated が元アトラスを参照している")
	check((textures[13]["frames"] as Array)[0] == Rect2(0, 0, 16, 16), "rotated の先頭フレーム矩形が不正")

	# 生成物はキャッシュされます（rotated と spin で 2 件）。
	check(TKSpriteAtlasBuilder.get_cache_count() == 2, "生成アトラスがキャッシュされていない: %d" % TKSpriteAtlasBuilder.get_cache_count())

	server.free()
# [test_register_all]END


# [test_draw_size_scale]
# 処理内容: draw_size が倍率つきでサーバーへ登録されることを確認します。
# 戻り値: なし
func test_draw_size_scale() -> void:
	var server = make_server()
	TKSpriteRegistry.register_all(server, DEFS_PATH, Vector2(2.0, 3.0))
	check(server.get_sprite_draw_size(10) == Vector2(32.0, 48.0), "draw_size に倍率が反映されていない: %s" % str(server.get_sprite_draw_size(10)))
	# draw_size を持たない定義には設定されないため、サーバー側でフレームサイズへ
	# フォールバックします（倍率は掛かりません）。
	check(server.get_sprite_draw_size(11) == Vector2(16.0, 16.0), "draw_size 未指定時にフレームサイズへフォールバックしていない: %s" % str(server.get_sprite_draw_size(11)))
	server.free()

	var plain_server = make_server()
	TKSpriteRegistry.register_all(plain_server, DEFS_PATH)
	check(plain_server.get_sprite_draw_size(10) == Vector2(16.0, 16.0), "既定倍率で draw_size が等倍にならない")
	plain_server.free()
# [test_draw_size_scale]END


# [test_missing_atlas]
# 処理内容: 解決できないアトラスを参照する定義がスキップされ、他の登録は続くことを
#           確認します。
# 戻り値: なし
func test_missing_atlas() -> void:
	var defs: Dictionary = {
		"version": 2,
		"atlases": { "main": ATLAS_PATH, "missing": "user://tk_test_no_such_atlas.png" },
		"sprites": [
			{ "id": 20, "name": "OK", "atlas": "main", "layout": "single", "rect": [0, 0, 16, 16] },
			{ "id": 21, "name": "NG", "atlas": "missing", "layout": "single", "rect": [0, 0, 16, 16] }
		]
	}
	var server = make_server()
	var registered_count: int = TKSpriteRegistry.register_defs(server, TKSpriteDefinitions.normalize_defs(defs))
	check(registered_count == 1, "解決できないアトラスの分まで登録された: %d" % registered_count)
	check((server.sprite_textures as Dictionary).has(20), "正常な定義が登録されていない")
	check(not (server.sprite_textures as Dictionary).has(21), "解決できない定義が登録された")

	# 存在しない定義ファイルは 0 件です。
	check(TKSpriteRegistry.register_all(server, "user://tk_test_no_such_defs.json") == 0, "存在しない定義ファイルが 0 件でない")
	server.free()
# [test_missing_atlas]END


# [test_lookup_by_name]
# 処理内容: 名前からスプライトIDを引けることを確認します。
# 戻り値: なし
func test_lookup_by_name() -> void:
	var defs: Dictionary = TKSpriteDefinitions.load_file(DEFS_PATH)
	check(TKSpriteRegistry.get_sprite_id_by_name(defs, "SPIN") == 14, "名前からIDを引けない")
	check(TKSpriteRegistry.get_sprite_id_by_name(defs, "NOPE") == -1, "未定義の名前で -1 が返らない")
# [test_lookup_by_name]END
