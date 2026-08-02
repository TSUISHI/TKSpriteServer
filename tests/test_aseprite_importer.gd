# test_aseprite_importer.gd — TKAsepriteImporter（経路A）の自己完結テスト
#
# 実行方法:
#   Godot --headless --path <プロジェクト> --script res://tests/test_aseprite_importer.gd
#
# Aseprite 本体には依存しません（CLI が出力する形のJSONをテスト内で組み立てます）。

extends SceneTree

var failure_count: int = 0

const WORK_DIR: String = "user://tk_test_ase"
const ARRAY_JSON_PATH: String = "user://tk_test_ase/player.json"
const HASH_JSON_PATH: String = "user://tk_test_ase/player_hash.json"
const DEFS_PATH: String = "user://tk_test_ase/defs.json"


# [_initialize]
# 処理内容: テスト用データを用意し、全テストを実行します。
# 戻り値: なし
func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(WORK_DIR)
	write_text(ARRAY_JSON_PATH, make_array_json())
	write_text(HASH_JSON_PATH, make_hash_json())

	test_import_array()
	test_import_hash_order()
	test_split_by_tag()
	test_id_stability_and_merge()
	test_import_into_file()

	if failure_count == 0:
		print("test_aseprite_importer: ALL PASS")
	else:
		print("test_aseprite_importer: FAILED %d" % failure_count)
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


# [write_text]
# 処理内容: 文字列をファイルへ書き出します。
# 引数 path: 保存先パスです。
# 引数 text: 内容です。
# 戻り値: なし
func write_text(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	check(file != null, "テストファイルを書けない: " + path)
	if file == null:
		return
	file.store_string(text)
	file.close()
# [write_text]END


# [make_array_json]
# 処理内容: --format json-array 相当のデータJSONを組み立てます。
#           トリム（spriteSourceSize）とタグ、slice の pivot を含みます。
# 戻り値: JSON文字列です。
func make_array_json() -> String:
	return """
{
  "frames": [
    { "filename": "player 0.aseprite", "frame": { "x": 0, "y": 0, "w": 16, "h": 16 },
      "spriteSourceSize": { "x": 2, "y": 1, "w": 16, "h": 16 },
      "sourceSize": { "w": 20, "h": 18 }, "duration": 100 },
    { "filename": "player 1.aseprite", "frame": { "x": 16, "y": 0, "w": 16, "h": 16 },
      "spriteSourceSize": { "x": 2, "y": 1, "w": 16, "h": 16 },
      "sourceSize": { "w": 20, "h": 18 }, "duration": 150 },
    { "filename": "player 2.aseprite", "frame": { "x": 32, "y": 0, "w": 16, "h": 16 },
      "spriteSourceSize": { "x": 0, "y": 0, "w": 16, "h": 16 },
      "sourceSize": { "w": 20, "h": 18 }, "duration": 200 },
    { "filename": "player 3.aseprite", "frame": { "x": 48, "y": 0, "w": 16, "h": 16 },
      "spriteSourceSize": { "x": 0, "y": 0, "w": 16, "h": 16 },
      "sourceSize": { "w": 20, "h": 18 }, "duration": 200 }
  ],
  "meta": {
    "app": "https://www.aseprite.org/", "version": "1.3", "image": "player.png",
    "format": "RGBA8888", "size": { "w": 64, "h": 16 }, "scale": "1",
    "frameTags": [
      { "name": "walk", "from": 0, "to": 1, "direction": "forward" },
      { "name": "jump", "from": 2, "to": 3, "direction": "forward" }
    ],
    "slices": [
      { "name": "center", "color": "#0000ffff",
        "keys": [ { "frame": 0, "bounds": { "x": 0, "y": 0, "w": 16, "h": 16 },
                    "pivot": { "x": 8, "y": 16 } } ] }
    ]
  }
}
"""
# [make_array_json]END


# [make_hash_json]
# 処理内容: --format json-hash 相当のデータJSONを、意図的にキー順を崩して組み立てます。
# 戻り値: JSON文字列です。
func make_hash_json() -> String:
	return """
{
  "frames": {
    "player 2.aseprite": { "frame": { "x": 32, "y": 0, "w": 16, "h": 16 },
      "sourceSize": { "w": 16, "h": 16 }, "duration": 200 },
    "player 0.aseprite": { "frame": { "x": 0, "y": 0, "w": 16, "h": 16 },
      "sourceSize": { "w": 16, "h": 16 }, "duration": 100 },
    "player 10.aseprite": { "frame": { "x": 64, "y": 0, "w": 16, "h": 16 },
      "sourceSize": { "w": 16, "h": 16 }, "duration": 100 },
    "player 1.aseprite": { "frame": { "x": 16, "y": 0, "w": 16, "h": 16 },
      "sourceSize": { "w": 16, "h": 16 }, "duration": 150 }
  },
  "meta": { "image": "player.png", "size": { "w": 80, "h": 16 } }
}
"""
# [make_hash_json]END


# [test_import_array]
# 処理内容: json-array の取り込み結果を確認します。
# 戻り値: なし
func test_import_array() -> void:
	var defs: Dictionary = TKAsepriteImporter.import_sheet(ARRAY_JSON_PATH)
	check(not defs.is_empty(), "json-array の取り込みに失敗した")
	if defs.is_empty():
		return

	# シート画像はデータJSONと同じディレクトリを基準に解決します。
	var atlases: Dictionary = defs["atlases"]
	check(atlases.has("player"), "アトラス別名がシート画像名から決まっていない")
	check(String(atlases.get("player", "")) == WORK_DIR + "/player.png", "シート画像のパス解決が不正: " + String(atlases.get("player", "")))

	var sprites: Array = defs["sprites"]
	check(sprites.size() == 1, "スプライト件数が 1 でない: %d" % sprites.size())
	var sprite: Dictionary = sprites[0]
	check(String(sprite["name"]) == "PLAYER", "スプライト名がJSONファイル名から決まっていない: " + String(sprite["name"]))
	check(int(sprite["id"]) == 0, "新規定義のIDが 0 でない")
	check(String(sprite["layout"]) == "frames", "layout が frames でない")

	var frames: Array = sprite["frames"]
	check(frames.size() == 4, "フレーム数が 4 でない")
	check(frames[0] == [0, 0, 16, 16] and frames[3] == [48, 0, 16, 16], "フレーム矩形が不正")
	check((sprite["durations"] as Array) == [100, 150, 200, 200], "durations が不正: " + str(sprite["durations"]))
	check((sprite["offsets"] as Array)[0] == [2, 1], "spriteSourceSize が offsets へ入っていない")
	check((sprite["source_size"] as Array) == [20, 18], "sourceSize が source_size へ入っていない")
	check((sprite["pivot"] as Array) == [8, 16], "slice の pivot が取り込まれていない")

	var tags: Dictionary = sprite["tags"]
	check(tags.size() == 2, "タグ数が 2 でない")
	check(TKSpriteDefinitions.get_tag_range(sprite, "walk") == Vector2i(0, 1), "walk タグの範囲が不正")
	check(TKSpriteDefinitions.get_tag_range(sprite, "jump") == Vector2i(2, 3), "jump タグの範囲が不正")

	check(bool(sprite["generated"]), "generated が true でない")
	check(String((sprite["source"] as Dictionary).get("type", "")) == "aseprite", "source.type が aseprite でない")

	# 取り込み結果はそのまま検証を通ります。
	for message in TKSpriteDefinitions.validate(defs):
		check(not message.begins_with("ERROR:"), "取り込み結果の検証で ERROR が出た: " + message)
# [test_import_array]END


# [test_import_hash_order]
# 処理内容: json-hash がファイル名末尾の連番で正しく並ぶことを確認します。
#           文字列順なら "player 10" が "player 2" より前に来てしまいます。
# 戻り値: なし
func test_import_hash_order() -> void:
	var defs: Dictionary = TKAsepriteImporter.import_sheet(HASH_JSON_PATH)
	check(not defs.is_empty(), "json-hash の取り込みに失敗した")
	if defs.is_empty():
		return
	var sprite: Dictionary = (defs["sprites"] as Array)[0]
	var frames: Array = sprite["frames"]
	check(frames.size() == 4, "hash 形式のフレーム数が 4 でない")
	check(frames[0] == [0, 0, 16, 16], "連番 0 が先頭でない")
	check(frames[1] == [16, 0, 16, 16], "連番 1 が2番目でない")
	check(frames[2] == [32, 0, 16, 16], "連番 2 が3番目でない")
	check(frames[3] == [64, 0, 16, 16], "連番 10 が最後でない（文字列順で並んでいる）")
	# トリム情報が無い場合、offsets は出力されません。
	check((sprite["offsets"] as Array).is_empty(), "トリム無しで offsets が作られた")
	# タグが無い場合は、自分の全範囲を指すタグが1件だけ付きます。
	check((sprite["tags"] as Dictionary).size() == 1, "タグ無しの既定タグが1件でない")
# [test_import_hash_order]END


# [test_split_by_tag]
# 処理内容: split_by_tag でタグごとに別スプライトへ分割されることを確認します。
# 戻り値: なし
func test_split_by_tag() -> void:
	var defs: Dictionary = TKAsepriteImporter.import_sheet(ARRAY_JSON_PATH, {}, true)
	var sprites: Array = defs["sprites"]
	check(sprites.size() == 2, "タグ分割後のスプライト件数が 2 でない: %d" % sprites.size())
	if sprites.size() < 2:
		return

	var walk: Dictionary = sprites[0]
	var jump: Dictionary = sprites[1]
	check(String(walk["name"]) == "walk" and String(jump["name"]) == "jump", "分割後の名前がタグ名になっていない")
	check(int(walk["id"]) == 0 and int(jump["id"]) == 1, "分割後のIDが 0,1 でない")
	check((walk["frames"] as Array).size() == 2 and (jump["frames"] as Array).size() == 2, "分割後のフレーム数が 2 でない")
	check((jump["frames"] as Array)[0] == [32, 0, 16, 16], "jump の先頭フレームが3枚目でない")
	check((walk["durations"] as Array) == [100, 150], "分割後の durations が切り出されていない")
	# 分割後のタグは自分の範囲（0起点）を指します。
	check(TKSpriteDefinitions.get_tag_range(jump, "jump") == Vector2i(0, 1), "分割後のタグ範囲が0起点になっていない")
	check(String((jump["source"] as Dictionary).get("tag", "")) == "jump", "source.tag が記録されていない")

	for message in TKSpriteDefinitions.validate(defs):
		check(not message.begins_with("ERROR:"), "分割結果の検証で ERROR が出た: " + message)
# [test_split_by_tag]END


# [test_id_stability_and_merge]
# 処理内容: 再インポートでIDが変わらないこと、手編集フィールドが残ることを確認します。
# 戻り値: なし
func test_id_stability_and_merge() -> void:
	# 手編集済みの既存定義を用意します（PLAYER は id 7、他に id 30 の手書き定義あり）。
	var existing: Dictionary = TKSpriteDefinitions.normalize_defs({
		"version": 2,
		"atlases": { "other": "user://tk_test_ase/other.png" },
		"sprites": [
			{ "id": 7, "name": "PLAYER", "atlas": "player", "layout": "frames",
			  "frames": [[0, 0, 8, 8]], "draw_size": [24, 24], "comment": "手編集メモ",
			  "extras": { "native_bullet": { "use_multimesh": false } } },
			{ "id": 30, "name": "HANDMADE", "atlas": "other", "layout": "single", "rect": [0, 0, 8, 8] }
		]
	})

	var defs: Dictionary = TKAsepriteImporter.import_sheet(ARRAY_JSON_PATH, existing)
	var sprites: Array = defs["sprites"]
	check(sprites.size() == 2, "マージ後の件数が 2 でない: %d" % sprites.size())

	var player: Dictionary = {}
	for sprite in sprites:
		if String(sprite["name"]) == "PLAYER":
			player = sprite
	check(not player.is_empty(), "PLAYER が見つからない")
	if player.is_empty():
		return

	check(int(player["id"]) == 7, "再インポートでIDが変わった: %d" % int(player["id"]))
	check((player["frames"] as Array).size() == 4, "再インポートでフレームが更新されていない")
	check((player["draw_size"] as Array) == [24, 24], "手編集の draw_size が失われた")
	check(String(player["comment"]) == "手編集メモ", "手編集の comment が失われた")
	check((player["extras"] as Dictionary).has("native_bullet"), "手編集の extras が失われた")

	# 既存アトラスは残り、新しいアトラスが追加されます。
	var atlases: Dictionary = defs["atlases"]
	check(atlases.has("other") and atlases.has("player"), "アトラスのマージが不正")

	# 新しい名前で取り込むと最大ID+1（=31）が割り当てられます。
	var added: Dictionary = TKAsepriteImporter.import_sheet(ARRAY_JSON_PATH, existing, false, "NEWONE")
	var new_id: int = -1
	for sprite in added["sprites"]:
		if String(sprite["name"]) == "NEWONE":
			new_id = int(sprite["id"])
	check(new_id == 31, "新規スプライトのIDが最大ID+1 でない: %d" % new_id)
# [test_id_stability_and_merge]END


# [test_import_into_file]
# 処理内容: 定義ファイルへの取り込み・保存・再取り込みが一巡することを確認します。
# 戻り値: なし
func test_import_into_file() -> void:
	if FileAccess.file_exists(DEFS_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(DEFS_PATH))

	check(TKAsepriteImporter.import_sheet_into_file(ARRAY_JSON_PATH, DEFS_PATH), "定義ファイルへの取り込みに失敗")
	check(FileAccess.file_exists(DEFS_PATH), "定義ファイルが作られていない")

	var loaded: Dictionary = TKSpriteDefinitions.load_file(DEFS_PATH)
	check(int(loaded.get("source_version", 0)) == 2, "保存された定義が v2 でない")
	check((loaded["sprites"] as Array).size() == 1, "保存後のスプライト件数が 1 でない")

	# 2回目の取り込みでも件数は増えず、IDも変わりません。
	check(TKAsepriteImporter.import_sheet_into_file(ARRAY_JSON_PATH, DEFS_PATH), "再取り込みに失敗")
	var reloaded: Dictionary = TKSpriteDefinitions.load_file(DEFS_PATH)
	check((reloaded["sprites"] as Array).size() == 1, "再取り込みでスプライトが増えた")
	check(int((reloaded["sprites"] as Array)[0]["id"]) == 0, "再取り込みでIDが変わった")
# [test_import_into_file]END
