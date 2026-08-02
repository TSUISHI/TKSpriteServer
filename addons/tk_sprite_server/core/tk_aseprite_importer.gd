# tk_aseprite_importer.gd — Aseprite の書き出し結果を定義JSONへ取り込む（経路A）
#
# Aseprite CLI が出力する「シートPNG + データJSON」を、このライブラリの定義JSON
# （スキーマ v2）へ変換します。Aseprite 本体を持たない利用者でも、配布された
# シートとJSONさえあれば動くため、3つの取り込み経路のうち最も汎用性が高い経路です。
#
# 想定コマンド:
#   aseprite --batch player.aseprite --sheet player.png --sheet-type packed \
#            --data player.json --format json-array --list-tags --trim
#
# 対応する形式:
#   --format json-array … frames が配列
#   --format json-hash  … frames が Dictionary（キー順が保証されないため、
#                          ファイル名末尾の連番で並べ直します）
#
# 再インポートの約束:
#   スプライトIDはゲーム側コードから参照されるため、既存定義に同じ名前があれば
#   そのIDを維持します。無い場合だけ「既存の最大ID + 1」を割り当てます。
#   手編集フィールド（draw_size / extras / comment）は上書きせず引き継ぎます。
#
# 設計書: CLAUDE_SPEC_TKSpriteServerKit.md §8.1
#
# 【メモリ規則】ツール実行時・起動時にのみ使用します。毎フレーム呼んではいけません。

class_name TKAsepriteImporter extends RefCounted


# [import_sheet]
# 処理内容: Aseprite のデータJSONを読み、定義JSON（v2）へ変換して既存定義へマージします。
# 引数 json_path:      Aseprite が出力したデータJSONのパスです。
# 引数 existing_defs:  既存の定義です（空なら新規作成）。IDと手編集値の引き継ぎに使います。
# 引数 split_by_tag:   true ならタグごとに別スプライトへ分割します。
# 引数 sprite_name:    生成するスプライト名です。空ならJSONのファイル名を使います。
#                      split_by_tag が true のときはタグ名が優先されます。
# 引数 atlas_alias:    アトラス別名です。空ならシート画像のファイル名（拡張子なし）を使います。
# 戻り値: マージ済みの正規化された定義 Dictionary。失敗時は空 Dictionary です。
static func import_sheet(
	json_path: String,
	existing_defs: Dictionary = {},
	split_by_tag: bool = false,
	sprite_name: String = "",
	atlas_alias: String = ""
) -> Dictionary:
	if not FileAccess.file_exists(json_path):
		push_error("TKAsepriteImporter: データJSONが見つかりません: " + json_path)
		return {}
	var file := FileAccess.open(json_path, FileAccess.READ)
	if file == null:
		push_error("TKAsepriteImporter: データJSONを開けません: " + json_path)
		return {}
	var text: String = file.get_as_text()
	file.close()
	return import_sheet_text(text, json_path, existing_defs, split_by_tag, sprite_name, atlas_alias)
# [import_sheet]END


# [import_sheet_text]
# 処理内容: Aseprite のデータJSON文字列を定義JSONへ変換し、既存定義へマージします。
# 引数 json_text:      Aseprite のデータJSON文字列です。
# 引数 json_path:      シート画像のパス解決に使う元JSONのパスです。
# 引数 existing_defs:  既存の定義です。
# 引数 split_by_tag:   true ならタグごとに別スプライトへ分割します。
# 引数 sprite_name:    生成するスプライト名です。
# 引数 atlas_alias:    アトラス別名です。
# 戻り値: マージ済みの正規化された定義 Dictionary。失敗時は空 Dictionary です。
static func import_sheet_text(
	json_text: String,
	json_path: String,
	existing_defs: Dictionary = {},
	split_by_tag: bool = false,
	sprite_name: String = "",
	atlas_alias: String = ""
) -> Dictionary:
	var parsed = JSON.parse_string(json_text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("TKAsepriteImporter: データJSONのパースに失敗しました: " + json_path)
		return {}
	var sheet: Dictionary = parsed

	var frames: Array = collect_frames(sheet)
	if frames.is_empty():
		push_error("TKAsepriteImporter: frames が空です: " + json_path)
		return {}

	var meta: Dictionary = sheet.get("meta", {}) if typeof(sheet.get("meta", null)) == TYPE_DICTIONARY else {}
	var image_path: String = resolve_image_path(meta, json_path)
	var alias: String = atlas_alias
	if alias.is_empty():
		alias = image_path.get_file().get_basename()
	if alias.is_empty():
		alias = json_path.get_file().get_basename()

	var base_name: String = sprite_name
	if base_name.is_empty():
		base_name = json_path.get_file().get_basename().to_upper()

	# 既存定義を土台にして、アトラスとスプライトを差し替えます。
	var defs: Dictionary = normalize_existing(existing_defs)
	(defs["atlases"] as Dictionary)[alias] = image_path

	var tags: Dictionary = collect_tags(meta)
	var new_sprites: Array = []
	if split_by_tag and not tags.is_empty():
		for tag_name in tags:
			var tag_range: Array = tags[tag_name]
			new_sprites.append(make_sprite(
				frames, alias, image_path, String(tag_name),
				int(tag_range[0]), int(tag_range[1]), {}, meta
			))
	else:
		new_sprites.append(make_sprite(
			frames, alias, image_path, base_name,
			0, frames.size() - 1, tags, meta
		))

	for sprite in new_sprites:
		merge_sprite(defs, sprite)

	return TKSpriteDefinitions.normalize_defs(defs)
# [import_sheet_text]END


# [collect_frames]
# 処理内容: json-array / json-hash のどちらの形式からもフレーム配列を取り出します。
#           hash 形式はキー順が保証されないため、ファイル名末尾の連番で並べ直します。
# 引数 sheet: Aseprite のデータJSON全体です。
# 戻り値: フレーム Dictionary の配列（表示順）です。
static func collect_frames(sheet: Dictionary) -> Array:
	var frames_in = sheet.get("frames", null)
	var frames: Array = []

	if typeof(frames_in) == TYPE_ARRAY:
		for entry in frames_in:
			if typeof(entry) == TYPE_DICTIONARY:
				frames.append(entry)
		return frames

	if typeof(frames_in) == TYPE_DICTIONARY:
		var keys: Array = (frames_in as Dictionary).keys()
		# ファイル名末尾の連番で並べ替えます。連番が無い場合は名前順です。
		keys.sort_custom(func(a, b) -> bool:
			var index_a: int = extract_trailing_number(String(a))
			var index_b: int = extract_trailing_number(String(b))
			if index_a != index_b:
				return index_a < index_b
			return String(a) < String(b)
		)
		for key in keys:
			var entry = frames_in[key]
			if typeof(entry) != TYPE_DICTIONARY:
				continue
			var frame: Dictionary = (entry as Dictionary).duplicate()
			# 配列形式と同じく filename を持たせ、以降の処理を共通化します。
			if not frame.has("filename"):
				frame["filename"] = String(key)
			frames.append(frame)
		return frames

	return frames
# [collect_frames]END


# [extract_trailing_number]
# 処理内容: "player 3.aseprite" のような文字列の末尾にある連番を取り出します。
# 引数 text: 対象の文字列です。
# 戻り値: 見つかった数値。無ければ -1 です。
static func extract_trailing_number(text: String) -> int:
	var digits: String = ""
	# 拡張子を落としてから末尾の数字を拾います。
	var body: String = text.get_basename()
	for index in range(body.length() - 1, -1, -1):
		var character: String = body[index]
		if character >= "0" and character <= "9":
			digits = character + digits
		else:
			break
	if digits.is_empty():
		return -1
	return digits.to_int()
# [extract_trailing_number]END


# [collect_tags]
# 処理内容: meta.frameTags を { タグ名 : [from, to] } へ変換します。
# 引数 meta: データJSONの meta です。
# 戻り値: タグ表です。タグが無ければ空 Dictionary です。
static func collect_tags(meta: Dictionary) -> Dictionary:
	var tags: Dictionary = {}
	var frame_tags = meta.get("frameTags", null)
	if typeof(frame_tags) != TYPE_ARRAY:
		return tags
	for entry in frame_tags:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var tag: Dictionary = entry
		if not tag.has("name"):
			continue
		tags[String(tag["name"])] = [int(tag.get("from", 0)), int(tag.get("to", 0))]
	return tags
# [collect_tags]END


# [collect_pivot]
# 処理内容: meta.slices の最初の pivot を描画基準点として取り出します。
# 引数 meta: データJSONの meta です。
# 戻り値: [x, y]。pivot が無ければ空配列です。
static func collect_pivot(meta: Dictionary) -> Array:
	var slices = meta.get("slices", null)
	if typeof(slices) != TYPE_ARRAY:
		return []
	for slice_entry in slices:
		if typeof(slice_entry) != TYPE_DICTIONARY:
			continue
		var keys = (slice_entry as Dictionary).get("keys", null)
		if typeof(keys) != TYPE_ARRAY:
			continue
		for key_entry in keys:
			if typeof(key_entry) != TYPE_DICTIONARY:
				continue
			var pivot = (key_entry as Dictionary).get("pivot", null)
			if typeof(pivot) == TYPE_DICTIONARY:
				return [int((pivot as Dictionary).get("x", 0)), int((pivot as Dictionary).get("y", 0))]
	return []
# [collect_pivot]END


# [resolve_image_path]
# 処理内容: シート画像のパスを求めます。meta.image はファイル名だけのことが多いため、
#           データJSONと同じディレクトリを基準に解決します。
# 引数 meta:      データJSONの meta です。
# 引数 json_path: データJSONのパスです。
# 戻り値: シート画像のパスです。
static func resolve_image_path(meta: Dictionary, json_path: String) -> String:
	var image_name: String = String(meta.get("image", ""))
	if image_name.is_empty():
		# 画像名が無い場合はデータJSONと同名の .png を仮定します。
		image_name = json_path.get_file().get_basename() + ".png"
	if image_name.begins_with("res://") or image_name.begins_with("user://") or image_name.is_absolute_path():
		return image_name
	return json_path.get_base_dir().path_join(image_name)
# [resolve_image_path]END


# [make_sprite]
# 処理内容: フレーム範囲から定義JSONのスプライト1件を組み立てます。
#           ID は 0 を仮置きし、マージ時に確定させます。
# 引数 frames:      フレーム配列（表示順）です。
# 引数 alias:       アトラス別名です。
# 引数 image_path:  シート画像のパスです（source の記録に使います）。
# 引数 sprite_name: スプライト名です。
# 引数 from_index:  開始フレーム番号です。
# 引数 to_index:    終了フレーム番号です。
# 引数 tags:        付与するタグ表です（分割時は空）。
# 引数 meta:        データJSONの meta です。
# 戻り値: スプライト定義 Dictionary です。
static func make_sprite(
	frames: Array,
	alias: String,
	image_path: String,
	sprite_name: String,
	from_index: int,
	to_index: int,
	tags: Dictionary,
	meta: Dictionary
) -> Dictionary:
	from_index = clampi(from_index, 0, frames.size() - 1)
	to_index = clampi(to_index, from_index, frames.size() - 1)

	var rects: Array = []
	var durations: Array = []
	var offsets: Array = []
	var source_size: Array = []
	var has_offset: bool = false

	for index in range(from_index, to_index + 1):
		var frame: Dictionary = frames[index]
		var rect = frame.get("frame", null)
		if typeof(rect) != TYPE_DICTIONARY:
			continue
		rects.append([
			int((rect as Dictionary).get("x", 0)), int((rect as Dictionary).get("y", 0)),
			int((rect as Dictionary).get("w", 0)), int((rect as Dictionary).get("h", 0))
		])
		durations.append(int(frame.get("duration", 100)))

		var sprite_source = frame.get("spriteSourceSize", null)
		if typeof(sprite_source) == TYPE_DICTIONARY:
			var offset_x: int = int((sprite_source as Dictionary).get("x", 0))
			var offset_y: int = int((sprite_source as Dictionary).get("y", 0))
			offsets.append([offset_x, offset_y])
			if offset_x != 0 or offset_y != 0:
				has_offset = true
		else:
			offsets.append([0, 0])

		if source_size.is_empty():
			var original = frame.get("sourceSize", null)
			if typeof(original) == TYPE_DICTIONARY:
				source_size = [int((original as Dictionary).get("w", 0)), int((original as Dictionary).get("h", 0))]

	var sprite: Dictionary = {
		"id": 0,
		"name": sprite_name,
		"atlas": alias,
		"layout": TKSpriteDefinitions.LAYOUT_FRAMES,
		"frames": rects,
		"durations": durations,
		"generated": true,
		"source": { "type": "aseprite", "file": image_path }
	}
	# トリムが無い場合は全て [0,0] になるため、出力しません。
	if has_offset:
		sprite["offsets"] = offsets
	if not source_size.is_empty():
		sprite["source_size"] = source_size

	var pivot: Array = collect_pivot(meta)
	if not pivot.is_empty():
		sprite["pivot"] = pivot

	if not tags.is_empty():
		sprite["tags"] = tags.duplicate(true)
	else:
		# タグ分割時は、そのタグ名を自分の全範囲を指すタグとして残します。
		sprite["source"]["tag"] = sprite_name
		sprite["tags"] = { sprite_name: [0, rects.size() - 1] }
	return sprite
# [make_sprite]END


# [normalize_existing]
# 処理内容: 既存定義を、マージ先として使える形（atlases と sprites を持つ）へ整えます。
#           元の Dictionary は変更しません。
# 引数 existing_defs: 既存の定義です。
# 戻り値: マージ先の定義 Dictionary です。
static func normalize_existing(existing_defs: Dictionary) -> Dictionary:
	var defs: Dictionary = existing_defs.duplicate(true)
	if typeof(defs.get("atlases", null)) != TYPE_DICTIONARY:
		defs["atlases"] = {}
	if typeof(defs.get("sprites", null)) != TYPE_ARRAY:
		defs["sprites"] = []
	defs["version"] = TKSpriteDefinitions.FORMAT_VERSION
	return defs
# [normalize_existing]END


# [merge_sprite]
# 処理内容: 生成したスプライトを定義へ差し込みます。同名の既存スプライトがあれば
#           そのIDと手編集フィールドを引き継いで置き換え、無ければ最大ID+1で追加します。
# 引数 defs:   マージ先の定義です（この関数が書き換えます）。
# 引数 sprite: 差し込むスプライト定義です。
# 戻り値: 確定したスプライトIDです。
static func merge_sprite(defs: Dictionary, sprite: Dictionary) -> int:
	var sprites: Array = defs["sprites"]
	var sprite_name: String = String(sprite.get("name", ""))

	var max_id: int = -1
	var found_index: int = -1
	for index in range(sprites.size()):
		var existing: Dictionary = sprites[index]
		max_id = maxi(max_id, int(existing.get("id", -1)))
		if String(existing.get("name", "")) == sprite_name:
			found_index = index

	if found_index < 0:
		sprite["id"] = max_id + 1
		sprites.append(sprite)
		return int(sprite["id"])

	# 再インポートでIDが変わらないことを保証します。
	var previous: Dictionary = sprites[found_index]
	sprite["id"] = int(previous.get("id", max_id + 1))

	# 手編集フィールドは上書きせず引き継ぎます。
	for key in ["draw_size", "comment", "extras"]:
		if previous.has(key) and not sprite.has(key):
			sprite[key] = previous[key]
	sprites[found_index] = sprite
	return int(sprite["id"])
# [merge_sprite]END


# [import_sheet_into_file]
# 処理内容: 既存の定義ファイルへ取り込み結果をマージし、同じパスへ保存します。
#           定義ファイルが無い場合は新規作成します。
# 引数 json_path:    Aseprite のデータJSONのパスです。
# 引数 defs_path:    定義JSONのパスです（読み込み先かつ保存先）。
# 引数 split_by_tag: true ならタグごとに別スプライトへ分割します。
# 引数 sprite_name:  生成するスプライト名です。
# 引数 atlas_alias:  アトラス別名です。
# 戻り値: 成功時 true です。
static func import_sheet_into_file(
	json_path: String,
	defs_path: String,
	split_by_tag: bool = false,
	sprite_name: String = "",
	atlas_alias: String = ""
) -> bool:
	var existing_defs: Dictionary = {}
	if FileAccess.file_exists(defs_path):
		existing_defs = TKSpriteDefinitions.load_file(defs_path)
	var merged: Dictionary = import_sheet(json_path, existing_defs, split_by_tag, sprite_name, atlas_alias)
	if merged.is_empty():
		return false
	return TKSpriteDefinitions.save_file(defs_path, merged)
# [import_sheet_into_file]END
