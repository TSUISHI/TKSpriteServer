# test_definitions.gd — TKSpriteDefinitions の自己完結テスト
#
# 実行方法:
#   Godot --headless --path <プロジェクト> --script res://tests/test_definitions.gd
# 任意で、実在する v1 定義ファイルの読み込み互換もまとめて確認できます:
#   ... --script res://tests/test_definitions.gd -- <v1定義ファイルのパス>
#
# 画像アセットには依存しません（JSON文字列を組み立てて検証します）。

extends SceneTree

var failure_count: int = 0


# [_initialize]
# 処理内容: 全テストを順に実行し、失敗が1件でもあれば終了コード1で終了します。
# 戻り値: なし
func _initialize() -> void:
	test_v1_load()
	test_frames_and_counts()
	test_roundtrip_v2()
	test_keep_v1()
	test_v2_validation()
	test_external_v1_file()

	if failure_count == 0:
		print("test_definitions: ALL PASS")
	else:
		print("test_definitions: FAILED %d" % failure_count)
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


# [make_v1_json]
# 処理内容: テスト用の v1 定義JSON文字列を組み立てます。
# 戻り値: JSON文字列です。
func make_v1_json() -> String:
	return """
{
  "version": 1,
  "atlases": { "main": "res://demo/assets/main.png" },
  "sprites": [
    { "id": 0, "name": "SINGLE", "atlas": "main", "layout": "single",
      "rect": [0, 0, 16, 16], "draw_size": [16, 16] },
    { "id": 1, "name": "ROW", "atlas": "main", "layout": "row",
      "rect": [0, 16, 16, 16], "frame_count": 5,
      "native_bullet": { "use_multimesh": false, "frame_count": 5,
                         "direction_count": 0, "anim_every_frames": 4 },
      "comment": "メモ" },
    { "id": 2, "name": "EXPLICIT", "atlas": "main", "layout": "frames",
      "frames": [[0, 32, 8, 8], [8, 32, 8, 8], [16, 32, 8, 8]] },
    { "id": 3, "name": "ROT", "atlas": "main", "layout": "rotated",
      "rect": [0, 48, 16, 16], "original_orientation": 64, "roughness": 4 },
    { "id": 4, "name": "SPIN", "atlas": "main", "layout": "spin",
      "rect": [0, 64, 16, 16], "frame_count": 8, "visual_period_dirs": 64 },
    { "id": 5, "atlas": "main" }
  ]
}
"""
# [make_v1_json]END


# [test_v1_load]
# 処理内容: v1 のJSONが読め、読み込み結果が v2 形式へ補完されることを確認します。
# 戻り値: なし
func test_v1_load() -> void:
	var defs: Dictionary = TKSpriteDefinitions.parse_text(make_v1_json(), "test_v1")
	check(not defs.is_empty(), "v1 のパースに失敗した")
	check(int(defs.get("version", 0)) == TKSpriteDefinitions.FORMAT_VERSION, "読み込み後の version が v2 でない")
	check(int(defs.get("source_version", 0)) == 1, "source_version が 1 でない")

	var sprites: Array = defs.get("sprites", [])
	# layout が欠けた id:5 はスキップされるため 5 件になります。
	check(sprites.size() == 5, "スプライト件数が 5 でない: %d" % sprites.size())

	var row: Dictionary = sprites[1]
	check(String(row.get("name", "")) == "ROW", "name の正規化に失敗")
	check((row.get("extras", {}) as Dictionary).has("native_bullet"), "v1 の native_bullet が extras へ移っていない")
	check(int((row["extras"]["native_bullet"] as Dictionary).get("anim_every_frames", -1)) == 4, "native_bullet の中身が保持されていない")
	check((row.get("durations", [null]) as Array).is_empty(), "durations の既定値が空でない")
	check((row.get("pivot", []) as Array) == [0, 0], "pivot の既定値が [0,0] でない")
	check((row.get("tags", {}) as Dictionary).is_empty(), "tags の既定値が空でない")
	check(not bool(row.get("generated", true)), "generated の既定値が false でない")
	check(String(row.get("comment", "")) == "メモ", "comment が保持されていない")

	var messages: PackedStringArray = TKSpriteDefinitions.validate(defs)
	for message in messages:
		check(not message.begins_with("ERROR:"), "v1 の検証で ERROR が出た: " + message)
# [test_v1_load]END


# [test_frames_and_counts]
# 処理内容: フレーム矩形の展開とフレーム枚数の算出を確認します。
# 戻り値: なし
func test_frames_and_counts() -> void:
	var defs: Dictionary = TKSpriteDefinitions.parse_text(make_v1_json(), "test_frames")
	var sprites: Array = defs.get("sprites", [])

	var single_frames: Array[Rect2] = TKSpriteDefinitions.build_frames(sprites[0])
	check(single_frames.size() == 1 and single_frames[0] == Rect2(0, 0, 16, 16), "single の矩形が不正")

	var row_frames: Array[Rect2] = TKSpriteDefinitions.build_frames(sprites[1])
	check(row_frames.size() == 5, "row のフレーム数が 5 でない")
	check(row_frames[4] == Rect2(64, 16, 16, 16), "row の最終フレーム位置が不正: " + str(row_frames[4]))

	check(TKSpriteDefinitions.build_frames(sprites[2]).size() == 3, "frames の展開数が 3 でない")
	# rotated は実行時生成のため build_frames では 0 件、枚数は計算で求まります。
	check(TKSpriteDefinitions.build_frames(sprites[3]).is_empty(), "rotated が build_frames で展開された")

	check(TKSpriteDefinitions.get_frame_count(sprites[0]) == 1, "single の枚数が 1 でない")
	check(TKSpriteDefinitions.get_frame_count(sprites[1]) == 5, "row の枚数が 5 でない")
	check(TKSpriteDefinitions.get_frame_count(sprites[2]) == 3, "frames の枚数が 3 でない")
	check(TKSpriteDefinitions.get_frame_count(sprites[3]) == 16, "roughness=4 の枚数が 16 でない: %d" % TKSpriteDefinitions.get_frame_count(sprites[3]))
	check(TKSpriteDefinitions.get_frame_count(sprites[4]) == 8, "spin の枚数が 8 でない")

	# roughness=0 は 256枚、6 は 4枚になります。
	var rot: Dictionary = sprites[3].duplicate(true)
	rot["roughness"] = 0
	check(TKSpriteDefinitions.get_frame_count(rot) == 256, "roughness=0 の枚数が 256 でない")
	rot["roughness"] = 6
	check(TKSpriteDefinitions.get_frame_count(rot) == 4, "roughness=6 の枚数が 4 でない")
# [test_frames_and_counts]END


# [test_roundtrip_v2]
# 処理内容: v2 で保存し読み直しても内容が一致すること、および v1 由来の定義が
#           保存で膨らまないことを確認します。
# 戻り値: なし
func test_roundtrip_v2() -> void:
	var defs: Dictionary = TKSpriteDefinitions.parse_text(make_v1_json(), "test_roundtrip")
	var path: String = "user://tk_test_defs_v2.json"
	check(TKSpriteDefinitions.save_file(path, defs), "v2 の保存に失敗")

	var reloaded: Dictionary = TKSpriteDefinitions.load_file(path)
	check(int(reloaded.get("version", 0)) == 2, "保存したファイルの version が 2 でない")
	check(int(reloaded.get("source_version", 0)) == 2, "再読み込み時の source_version が 2 でない")

	var original_sprites: Array = defs.get("sprites", [])
	var reloaded_sprites: Array = reloaded.get("sprites", [])
	check(original_sprites.size() == reloaded_sprites.size(), "往復でスプライト件数が変わった")
	for index in range(mini(original_sprites.size(), reloaded_sprites.size())):
		var a: Dictionary = TKSpriteDefinitions.sprite_to_canonical(original_sprites[index])
		var b: Dictionary = TKSpriteDefinitions.sprite_to_canonical(reloaded_sprites[index])
		check(JSON.stringify(a) == JSON.stringify(b), "往復で内容が変わった: index %d\n  %s\n  %s" % [index, JSON.stringify(a), JSON.stringify(b)])

	# キー順は組み立てた順のまま出力されます（JSON.stringify の sort_keys 既定 true を
	# 使うとアルファベット順になり、保存のたびに差分が暴れます）。
	var saved_file := FileAccess.open(path, FileAccess.READ)
	check(saved_file != null, "保存した v2 ファイルを開けない")
	if saved_file != null:
		var saved_text: String = saved_file.get_as_text()
		saved_file.close()
		check(saved_text.find("\"version\"") < saved_text.find("\"atlases\""), "version が atlases より後ろに出力された")
		check(saved_text.find("\"atlases\"") < saved_text.find("\"sprites\""), "atlases が sprites より後ろに出力された")
		check(saved_text.find("\"id\"") < saved_text.find("\"name\""), "スプライト内のキー順が固定されていない")

	# 既定値のままのキーは出力されないため、v1 由来の定義に余計なキーが増えません。
	var single_out: Dictionary = TKSpriteDefinitions.sprite_to_canonical(original_sprites[0])
	check(not single_out.has("pivot"), "既定値の pivot が出力された")
	check(not single_out.has("durations"), "空の durations が出力された")
	check(not single_out.has("generated"), "false の generated が出力された")
	check(not single_out.has("extras"), "空の extras が出力された")
# [test_roundtrip_v2]END


# [test_keep_v1]
# 処理内容: keep_v1 指定で v1 形式へ書き戻せること（native_bullet の復元を含む）を
#           確認します。
# 戻り値: なし
func test_keep_v1() -> void:
	var defs: Dictionary = TKSpriteDefinitions.parse_text(make_v1_json(), "test_keep_v1")
	var path: String = "user://tk_test_defs_v1.json"
	check(TKSpriteDefinitions.save_file(path, defs, true), "v1 の保存に失敗")

	var file := FileAccess.open(path, FileAccess.READ)
	check(file != null, "保存した v1 ファイルを開けない")
	if file == null:
		return
	var text: String = file.get_as_text()
	file.close()

	var raw = JSON.parse_string(text)
	check(typeof(raw) == TYPE_DICTIONARY, "v1 出力のパースに失敗")
	check(int((raw as Dictionary).get("version", 0)) == 1, "keep_v1 の version が 1 でない")
	var raw_sprites: Array = (raw as Dictionary).get("sprites", [])
	var raw_row: Dictionary = raw_sprites[1]
	check(raw_row.has("native_bullet"), "keep_v1 で native_bullet が復元されていない")
	check(not raw_row.has("extras"), "keep_v1 で extras が出力された")
	check(not raw_row.has("tags"), "keep_v1 で tags が出力された")
# [test_keep_v1]END


# [test_v2_validation]
# 処理内容: v2 固有フィールドの検証（durations/offsets の要素数、タグ範囲）を確認します。
# 戻り値: なし
func test_v2_validation() -> void:
	var json_text: String = """
{
  "version": 2,
  "atlases": { "main": "res://demo/assets/main.png" },
  "sprites": [
    { "id": 0, "name": "OK", "atlas": "main", "layout": "row",
      "rect": [0, 0, 16, 16], "frame_count": 3,
      "durations": [100, 100, 200], "offsets": [[0,0],[1,0],[2,0]],
      "source_size": [16, 16], "pivot": [8, 8],
      "tags": { "walk": [0, 2] }, "generated": true,
      "source": { "type": "aseprite", "file": "res://a.aseprite" },
      "extras": { "anything": 1 } },
    { "id": 1, "name": "BADLEN", "atlas": "main", "layout": "row",
      "rect": [0, 16, 16, 16], "frame_count": 3, "durations": [100, 100] },
    { "id": 2, "name": "BADTAG", "atlas": "main", "layout": "row",
      "rect": [0, 32, 16, 16], "frame_count": 3, "tags": { "run": [1, 9] } }
  ]
}
"""
	var defs: Dictionary = TKSpriteDefinitions.parse_text(json_text, "test_v2")
	check(int(defs.get("source_version", 0)) == 2, "v2 の source_version が 2 でない")

	var ok_sprite: Dictionary = (defs["sprites"] as Array)[0]
	check((ok_sprite.get("durations", []) as Array) == [100, 100, 200], "durations の正規化に失敗")
	check((ok_sprite.get("offsets", []) as Array)[2] == [2, 0], "offsets の正規化に失敗")
	check((ok_sprite.get("pivot", []) as Array) == [8, 8], "pivot の正規化に失敗")
	check(bool(ok_sprite.get("generated", false)), "generated の読み取りに失敗")
	check(TKSpriteDefinitions.get_tag_range(ok_sprite, "walk") == Vector2i(0, 2), "get_tag_range が不正")
	check(TKSpriteDefinitions.get_tag_range(ok_sprite, "none") == Vector2i(-1, -1), "未定義タグの戻り値が不正")
	check(String((ok_sprite.get("source", {}) as Dictionary).get("type", "")) == "aseprite", "source が保持されていない")
	check((ok_sprite.get("extras", {}) as Dictionary).has("anything"), "extras が保持されていない")

	var messages: PackedStringArray = TKSpriteDefinitions.validate(defs)
	var joined: String = "\n".join(messages)
	check(joined.contains("durations の要素数"), "durations の要素数不一致を検出できていない")
	check(joined.contains("タグ 'run'"), "タグ範囲の超過を検出できていない")
	check(not joined.contains("[0:OK]"), "正しい定義に対して指摘が出た:\n" + joined)
# [test_v2_validation]END


# [test_external_v1_file]
# 処理内容: コマンドライン引数で実在の v1 定義ファイルが渡された場合に、読み込みと
#           検証が通ることを確認します。引数が無ければ何もしません。
# 戻り値: なし
func test_external_v1_file() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.is_empty():
		return
	var path: String = args[0]
	if not FileAccess.file_exists(path):
		print("  SKIP: 指定されたファイルがありません: " + path)
		return

	var defs: Dictionary = TKSpriteDefinitions.load_file(path)
	check(not defs.is_empty(), "外部 v1 ファイルの読み込みに失敗: " + path)
	var sprite_count: int = (defs.get("sprites", []) as Array).size()
	check(sprite_count > 0, "外部 v1 ファイルからスプライトが1件も読めなかった")
	var messages: PackedStringArray = TKSpriteDefinitions.validate(defs)
	var error_count: int = 0
	for message in messages:
		if message.begins_with("ERROR:"):
			error_count += 1
			print("  外部ファイルの ERROR: " + message)
	check(error_count == 0, "外部 v1 ファイルの検証で ERROR が出た")
	print("  外部 v1 ファイル: %d スプライト、指摘 %d 件" % [sprite_count, messages.size()])
# [test_external_v1_file]END
