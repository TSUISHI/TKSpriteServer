# tk_sprite_definitions.gd — スプライト定義JSON(v1/v2)の読み書き・検証
#
# 2Dレトロゲームで使っていた定義ローダを公開ライブラリ向けに移植したものです。
# 定義データの入出力のみを担当し、テクスチャの load やサーバーへの登録は行いません
# （それは TKSpriteRegistry の役目です）。
#
# 移植元からの主な変更点:
#   1. スキーマ v2 を追加した。v1 のファイルはそのまま読め、読み込み後は常に v2 形式
#      （不足フィールドは既定値で補完）で返るため、利用側はバージョンを意識しない。
#   2. v1 の native_bullet はライブラリが解釈しない自由領域 extras へ移した。
#      保存時に keep_v1 を指定すれば元の native_bullet として書き戻す。
#   3. save_file() は既定で v2 を書き出す。値が既定のままのキーは出力しないため、
#      v1 由来のファイルを読んで保存し直しても差分が増えない。
#   4. フレーム枚数を返す get_frame_count() と、タグ範囲を返す get_tag_range() を追加した。
#
# 設計書 §7
#
# 【メモリ規則】起動時とツール実行時にのみ使用します。毎フレーム呼んではいけません。

class_name TKSpriteDefinitions extends RefCounted

# 書き出すファイルフォーマットのバージョンです。
const FORMAT_VERSION: int = 2
# そのまま読み込める旧バージョンです。
const LEGACY_FORMAT_VERSION: int = 1

# layout フィールドに書ける値の一覧です。
#   single  : 単一矩形。
#   row     : 先頭矩形 rect から横並びに frame_count 枚。
#   frames  : 矩形を明示列挙（不等間隔・非横並び用）。
#   rotated : 1枚絵から TKSpriteAtlasBuilder.build_rotated() で全方向アトラスを生成。
#   spin    : 1枚絵から TKSpriteAtlasBuilder.build_spin() で均等回転アニメを生成。
const LAYOUT_SINGLE: String = "single"
const LAYOUT_ROW: String = "row"
const LAYOUT_FRAMES: String = "frames"
const LAYOUT_ROTATED: String = "rotated"
const LAYOUT_SPIN: String = "spin"
const VALID_LAYOUTS: Array[String] = ["single", "row", "frames", "rotated", "spin"]

# roughness の許容範囲です（§6.5.2）。
const ROUGHNESS_MIN: int = 0
const ROUGHNESS_MAX: int = 6
# 方向の分割数です。1周 = 256方向（§6.5.1）。
const DIRECTION_RESOLUTION: int = 256


# [load_file]
# 処理内容: スプライト定義JSONを読み込み、v2形式へ正規化した Dictionary を返します。
# 引数 path: 読み込む res:// または user:// のパスです。
# 戻り値: 正規化済み定義 Dictionary。失敗時は空 Dictionary です。
static func load_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_error("TKSpriteDefinitions: 定義ファイルが見つかりません: " + path)
		return {}

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("TKSpriteDefinitions: 定義ファイルを開けません: " + path)
		return {}
	var text: String = file.get_as_text()
	file.close()
	return parse_text(text, path)
# [load_file]END


# [parse_text]
# 処理内容: JSON文字列を読み込み、v2形式へ正規化した Dictionary を返します。
#           ファイルを介さずに定義を組み立てるツール（Asepriteインポータ等）から使います。
# 引数 text: JSON文字列です。
# 引数 source_label: エラーメッセージに出す出所の名前です。
# 戻り値: 正規化済み定義 Dictionary。失敗時は空 Dictionary です。
static func parse_text(text: String, source_label: String = "(text)") -> Dictionary:
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("TKSpriteDefinitions: JSONのパースに失敗しました: " + source_label)
		return {}
	return normalize_defs(parsed)
# [parse_text]END


# [normalize_defs]
# 処理内容: JSONパース直後の定義全体を正規化します。壊れたスプライトは1件ずつ
#           スキップし、読み込み自体は続行します。
# 引数 parsed: JSONパース直後の Dictionary です。
# 戻り値: 正規化済み定義 Dictionary（version は常に FORMAT_VERSION）。
static func normalize_defs(parsed: Dictionary) -> Dictionary:
	var source_version: int = int(parsed.get("version", LEGACY_FORMAT_VERSION))

	var defs: Dictionary = {}
	# 読み込み結果は常に v2 形式なので、元が v1 でも version は v2 を名乗ります。
	defs["version"] = FORMAT_VERSION
	# 元ファイルのバージョンは、保存時に keep_v1 を判断したい利用側のために残します。
	defs["source_version"] = source_version

	# atlases: { 別名(String) : パス(String) } のみを通します。
	var atlases: Dictionary = {}
	var parsed_atlases = parsed.get("atlases", {})
	if typeof(parsed_atlases) == TYPE_DICTIONARY:
		for alias in parsed_atlases:
			if typeof(parsed_atlases[alias]) == TYPE_STRING:
				atlases[String(alias)] = String(parsed_atlases[alias])
	defs["atlases"] = atlases

	var sprites: Array = []
	var parsed_sprites = parsed.get("sprites", [])
	if typeof(parsed_sprites) == TYPE_ARRAY:
		for entry in parsed_sprites:
			if typeof(entry) != TYPE_DICTIONARY:
				push_warning("TKSpriteDefinitions: sprites 配列に Dictionary 以外の要素があります。スキップします。")
				continue
			var sprite: Dictionary = normalize_sprite(entry)
			if sprite.is_empty():
				continue
			sprites.append(sprite)
	defs["sprites"] = sprites
	return defs
# [normalize_defs]END


# [normalize_sprite]
# 処理内容: JSON由来のスプライト1件を v2 形式へ正規化します。数値のint化・配列長
#           チェック・必須キー欠落チェックを行い、v2の任意フィールドを既定値で補完します。
# 引数 entry: JSONパース直後のスプライト定義 Dictionary です。
# 戻り値: 正規化済み Dictionary。必須キー欠落など復旧不能な場合は空 Dictionary です。
static func normalize_sprite(entry: Dictionary) -> Dictionary:
	# id / atlas / layout は必須です。
	if not entry.has("id") or not entry.has("atlas") or not entry.has("layout"):
		push_warning("TKSpriteDefinitions: id/atlas/layout が欠けたスプライト定義をスキップします: " + str(entry.get("name", "?")))
		return {}

	var sprite: Dictionary = {}
	sprite["id"] = int(entry["id"])
	sprite["name"] = String(entry.get("name", "SPRITE_%d" % int(entry["id"])))
	sprite["atlas"] = String(entry["atlas"])
	sprite["layout"] = String(entry["layout"])

	# rect: [x, y, w, h] の4要素配列を int 配列へ正規化します。
	if entry.has("rect"):
		var rect_arr = entry["rect"]
		if typeof(rect_arr) == TYPE_ARRAY and rect_arr.size() == 4:
			sprite["rect"] = [int(rect_arr[0]), int(rect_arr[1]), int(rect_arr[2]), int(rect_arr[3])]

	# frames: [[x,y,w,h], ...] の明示列挙を int 配列の配列へ正規化します。
	if entry.has("frames"):
		var frames_in = entry["frames"]
		if typeof(frames_in) == TYPE_ARRAY:
			var frames_out: Array = []
			for f in frames_in:
				if typeof(f) == TYPE_ARRAY and f.size() == 4:
					frames_out.append([int(f[0]), int(f[1]), int(f[2]), int(f[3])])
			sprite["frames"] = frames_out

	# 任意の数値パラメータ群です。存在するものだけ int 化して持ちます。
	if entry.has("frame_count"):
		sprite["frame_count"] = int(entry["frame_count"])
	if entry.has("original_orientation"):
		sprite["original_orientation"] = int(entry["original_orientation"])
	if entry.has("roughness"):
		sprite["roughness"] = int(entry["roughness"])
	if entry.has("visual_period_dirs"):
		sprite["visual_period_dirs"] = int(entry["visual_period_dirs"])

	# draw_size: [w, h]。描画サイズの指定です。
	sprite["draw_size"] = _normalize_int_pair(entry.get("draw_size", null))
	if sprite["draw_size"].is_empty():
		sprite.erase("draw_size")

	# --- ここから v2 の追加フィールドです。省略時は既定値で補完します。 ---

	# durations: フレームごとの表示ミリ秒です（空 = 未指定）。
	var durations: Array = []
	var durations_in = entry.get("durations", null)
	if typeof(durations_in) == TYPE_ARRAY:
		for d in durations_in:
			durations.append(int(d))
	sprite["durations"] = durations

	# offsets: トリム時のフレーム原点補正 [[x,y], ...] です（空 = 補正なし）。
	var offsets: Array = []
	var offsets_in = entry.get("offsets", null)
	if typeof(offsets_in) == TYPE_ARRAY:
		for o in offsets_in:
			var pair: Array = _normalize_int_pair(o)
			if not pair.is_empty():
				offsets.append(pair)
	sprite["offsets"] = offsets

	# source_size: トリム前の元サイズ [w,h] です（空 = 未指定）。
	sprite["source_size"] = _normalize_int_pair(entry.get("source_size", null))

	# pivot: 描画基準点です。省略時は左上 [0,0]（v1互換）。
	var pivot: Array = _normalize_int_pair(entry.get("pivot", null))
	sprite["pivot"] = pivot if not pivot.is_empty() else [0, 0]

	# tags: { タグ名 : [from, to] } のアニメ区間です。
	var tags: Dictionary = {}
	var tags_in = entry.get("tags", null)
	if typeof(tags_in) == TYPE_DICTIONARY:
		for tag_name in tags_in:
			var range_in = tags_in[tag_name]
			if typeof(range_in) == TYPE_ARRAY and range_in.size() == 2:
				tags[String(tag_name)] = [int(range_in[0]), int(range_in[1])]
	sprite["tags"] = tags

	# source: 生成元の記録です。ライブラリは中身を解釈せず保持のみ行います。
	var source_in = entry.get("source", null)
	sprite["source"] = source_in.duplicate(true) if typeof(source_in) == TYPE_DICTIONARY else {}

	# generated: インポータが生成した定義かどうかです（手編集との衝突検出用）。
	sprite["generated"] = bool(entry.get("generated", false))

	# extras: 利用側の自由領域です。ライブラリは中身を解釈しません。
	var extras_in = entry.get("extras", null)
	var extras: Dictionary = extras_in.duplicate(true) if typeof(extras_in) == TYPE_DICTIONARY else {}
	# v1 の native_bullet はここへ取り込みます（v1で書き戻す場合に復元できます）。
	if entry.has("native_bullet") and typeof(entry["native_bullet"]) == TYPE_DICTIONARY:
		extras["native_bullet"] = (entry["native_bullet"] as Dictionary).duplicate(true)
	sprite["extras"] = extras

	# comment: 自由記述メモです。ローダーは内容を解釈しません。
	if entry.has("comment"):
		sprite["comment"] = String(entry["comment"])
	return sprite
# [normalize_sprite]END


# [_normalize_int_pair]
# 処理内容: [x, y] の2要素配列を int 配列へ正規化します。
# 引数 value: JSON由来の値です（配列以外なら空を返します）。
# 戻り値: [int, int]。正規化できない場合は空配列です。
static func _normalize_int_pair(value) -> Array:
	if typeof(value) == TYPE_ARRAY and value.size() == 2:
		return [int(value[0]), int(value[1])]
	return []
# [_normalize_int_pair]END


# [save_file]
# 処理内容: 定義 Dictionary をキー順固定・インデント2のJSONとして保存します。
#           キー順を固定するのは、ツールでの保存前後の差分を最小にするためです。
# 引数 path: 保存先パスです。
# 引数 defs: load_file() 形式の正規化済み定義です。
# 引数 keep_v1: true なら v1 形式で書き出します（v2固有の値は失われます）。
# 戻り値: 成功時 true です。
static func save_file(path: String, defs: Dictionary, keep_v1: bool = false) -> bool:
	var out: Dictionary = {}
	out["version"] = LEGACY_FORMAT_VERSION if keep_v1 else FORMAT_VERSION
	out["atlases"] = defs.get("atlases", {})

	var dropped: bool = false
	var out_sprites: Array = []
	for sprite in defs.get("sprites", []):
		if keep_v1 and _has_v2_payload(sprite):
			dropped = true
		out_sprites.append(sprite_to_canonical(sprite, keep_v1))
	out["sprites"] = out_sprites

	if dropped:
		push_warning("TKSpriteDefinitions: keep_v1 のため v2 固有フィールド（durations/offsets/tags等）を出力から除外しました: " + path)

	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("TKSpriteDefinitions: 保存先を開けません: " + path)
		return false
	# 第3引数 sort_keys は既定が true で、指定しないとキーがアルファベット順に
	# 並べ替えられます。差分を最小にするため、組み立てた順のまま書き出します。
	file.store_string(JSON.stringify(out, "  ", false))
	file.close()
	return true
# [save_file]END


# [_has_v2_payload]
# 処理内容: v1 で書き出すと失われる値を持っているかを判定します。
# 引数 sprite: 正規化済みスプライト定義です。
# 戻り値: v2固有の値を持っていれば true です。
static func _has_v2_payload(sprite: Dictionary) -> bool:
	if not (sprite.get("durations", []) as Array).is_empty():
		return true
	if not (sprite.get("offsets", []) as Array).is_empty():
		return true
	if not (sprite.get("source_size", []) as Array).is_empty():
		return true
	if not (sprite.get("tags", {}) as Dictionary).is_empty():
		return true
	if not (sprite.get("source", {}) as Dictionary).is_empty():
		return true
	if bool(sprite.get("generated", false)):
		return true
	var pivot: Array = sprite.get("pivot", [])
	if pivot.size() == 2 and (int(pivot[0]) != 0 or int(pivot[1]) != 0):
		return true
	# extras のうち native_bullet だけは v1 の同名キーとして書き戻せます。
	for key in (sprite.get("extras", {}) as Dictionary):
		if String(key) != "native_bullet":
			return true
	return false
# [_has_v2_payload]END


# [sprite_to_canonical]
# 処理内容: スプライト1件を保存用の固定キー順 Dictionary へ組み直します。
#           既定値のままのキーは出力しないため、v1由来のファイルを読んで保存し直しても
#           出力が膨らみません。
# 引数 sprite: 正規化済みスプライト定義です。
# 引数 keep_v1: true なら v2固有キーを出力せず、extras.native_bullet を v1形式へ戻します。
# 戻り値: キー順固定の Dictionary です。
static func sprite_to_canonical(sprite: Dictionary, keep_v1: bool = false) -> Dictionary:
	var out: Dictionary = {}
	out["id"] = int(sprite.get("id", -1))
	out["name"] = String(sprite.get("name", ""))
	out["atlas"] = String(sprite.get("atlas", ""))
	out["layout"] = String(sprite.get("layout", LAYOUT_SINGLE))
	if sprite.has("rect"):
		out["rect"] = sprite["rect"]
	if sprite.has("frames"):
		out["frames"] = sprite["frames"]
	if sprite.has("frame_count"):
		out["frame_count"] = int(sprite["frame_count"])
	if sprite.has("original_orientation"):
		out["original_orientation"] = int(sprite["original_orientation"])
	if sprite.has("roughness"):
		out["roughness"] = int(sprite["roughness"])
	if sprite.has("visual_period_dirs"):
		out["visual_period_dirs"] = int(sprite["visual_period_dirs"])
	if sprite.has("draw_size"):
		out["draw_size"] = sprite["draw_size"]

	var extras: Dictionary = sprite.get("extras", {})
	if keep_v1:
		if extras.has("native_bullet"):
			out["native_bullet"] = extras["native_bullet"]
	else:
		var pivot: Array = sprite.get("pivot", [])
		if pivot.size() == 2 and (int(pivot[0]) != 0 or int(pivot[1]) != 0):
			out["pivot"] = pivot
		if not (sprite.get("durations", []) as Array).is_empty():
			out["durations"] = sprite["durations"]
		if not (sprite.get("offsets", []) as Array).is_empty():
			out["offsets"] = sprite["offsets"]
		if not (sprite.get("source_size", []) as Array).is_empty():
			out["source_size"] = sprite["source_size"]
		if not (sprite.get("tags", {}) as Dictionary).is_empty():
			out["tags"] = sprite["tags"]
		if not (sprite.get("source", {}) as Dictionary).is_empty():
			out["source"] = sprite["source"]
		if bool(sprite.get("generated", false)):
			out["generated"] = true
		if not extras.is_empty():
			out["extras"] = extras

	if sprite.has("comment"):
		out["comment"] = String(sprite["comment"])
	return out
# [sprite_to_canonical]END


# [build_frames]
# 処理内容: single/row/frames レイアウトのスプライト定義から、サーバー登録用の
#           Rect2 配列を組み立てます。rotated/spin は実行時生成のため対象外です。
# 引数 sprite: 正規化済みスプライト定義です。
# 戻り値: フレーム矩形の Array[Rect2]。組み立て不能なら空配列です。
static func build_frames(sprite: Dictionary) -> Array[Rect2]:
	var result: Array[Rect2] = []
	var layout: String = String(sprite.get("layout", LAYOUT_SINGLE))

	if layout == LAYOUT_FRAMES:
		# 明示列挙: frames の各 [x,y,w,h] をそのまま Rect2 化します。
		for f in sprite.get("frames", []):
			result.append(Rect2(float(f[0]), float(f[1]), float(f[2]), float(f[3])))
		return result

	# single / row は先頭矩形 rect が必須です。
	if not sprite.has("rect"):
		return result
	var r: Array = sprite["rect"]
	var rect := Rect2(float(r[0]), float(r[1]), float(r[2]), float(r[3]))

	if layout == LAYOUT_SINGLE:
		result.append(rect)
		return result

	if layout == LAYOUT_ROW:
		# 先頭矩形から横並びに frame_count 枚を切り出します。
		var frame_count: int = int(sprite.get("frame_count", 1))
		for frame_index in range(frame_count):
			result.append(Rect2(
				rect.position.x + rect.size.x * float(frame_index),
				rect.position.y,
				rect.size.x,
				rect.size.y
			))
		return result

	# rotated / spin はここでは組み立てません（TKSpriteAtlasBuilder が生成します）。
	return result
# [build_frames]END


# [get_frame_count]
# 処理内容: そのスプライトが最終的に持つフレーム枚数を返します。rotated/spin は
#           実行時生成後の枚数を計算で求めます（§6.5.2）。
# 引数 sprite: 正規化済みスプライト定義です。
# 戻り値: フレーム枚数。判定できない場合は 0 です。
static func get_frame_count(sprite: Dictionary) -> int:
	var layout: String = String(sprite.get("layout", LAYOUT_SINGLE))
	if layout == LAYOUT_FRAMES:
		return (sprite.get("frames", []) as Array).size()
	if layout == LAYOUT_SINGLE:
		return 1 if sprite.has("rect") else 0
	if layout == LAYOUT_ROW or layout == LAYOUT_SPIN:
		return maxi(int(sprite.get("frame_count", 0)), 0)
	if layout == LAYOUT_ROTATED:
		var roughness: int = clampi(int(sprite.get("roughness", 4)), ROUGHNESS_MIN, ROUGHNESS_MAX)
		return ((DIRECTION_RESOLUTION / 4) >> roughness) * 4
	return 0
# [get_frame_count]END


# [get_tag_range]
# 処理内容: アニメタグの [開始フレーム, 終了フレーム] を返します。
# 引数 sprite: 正規化済みスプライト定義です。
# 引数 tag_name: タグ名です。
# 戻り値: Vector2i(from, to)。タグが無い場合は Vector2i(-1, -1) です。
static func get_tag_range(sprite: Dictionary, tag_name: String) -> Vector2i:
	var tags: Dictionary = sprite.get("tags", {})
	if not tags.has(tag_name):
		return Vector2i(-1, -1)
	var range_arr: Array = tags[tag_name]
	return Vector2i(int(range_arr[0]), int(range_arr[1]))
# [get_tag_range]END


# [validate]
# 処理内容: 定義全体を検証し、問題点を "ERROR:"/"WARN:" 接頭辞つき文字列で列挙します。
#           ERROR = 該当スプライトが登録不能。WARN = 登録は可能だが要確認。
# 引数 defs: load_file() 形式の正規化済み定義です。
# 引数 atlas_sizes: { 別名 : Vector2i(画像サイズ) }。空なら範囲外チェックを省略します。
# 戻り値: 問題点メッセージの PackedStringArray。空なら問題なしです。
static func validate(defs: Dictionary, atlas_sizes: Dictionary = {}) -> PackedStringArray:
	var messages: PackedStringArray = PackedStringArray()
	var atlases: Dictionary = defs.get("atlases", {})
	if atlases.is_empty():
		messages.append("ERROR: atlases が空です。")

	# id 重複チェック用の出現テーブルです（検証中のみ使用する一時領域）。
	var seen_ids: Dictionary = {}

	for sprite in defs.get("sprites", []):
		var sprite_name: String = String(sprite.get("name", "?"))
		var id: int = int(sprite.get("id", -1))
		var prefix: String = "[%d:%s] " % [id, sprite_name]

		# id の重複は後勝ちで上書きされるため ERROR 扱いにします。
		if seen_ids.has(id):
			messages.append("ERROR: " + prefix + "id が重複しています（%s と同一）。" % String(seen_ids[id]))
		seen_ids[id] = sprite_name

		# atlas 参照先の存在チェックです。
		var atlas_alias: String = String(sprite.get("atlas", ""))
		if not atlases.has(atlas_alias):
			messages.append("ERROR: " + prefix + "未定義のアトラス別名です: " + atlas_alias)

		# layout の妥当性チェックです。
		var layout: String = String(sprite.get("layout", ""))
		if not VALID_LAYOUTS.has(layout):
			messages.append("ERROR: " + prefix + "不明な layout です: " + layout)
			continue

		# layout ごとの必須パラメータチェックです。
		if layout == LAYOUT_FRAMES:
			if (sprite.get("frames", []) as Array).is_empty():
				messages.append("ERROR: " + prefix + "layout=frames に frames がありません。")
		else:
			if not sprite.has("rect"):
				messages.append("ERROR: " + prefix + "rect がありません。")
				continue
		if layout == LAYOUT_ROW and int(sprite.get("frame_count", 0)) <= 0:
			messages.append("ERROR: " + prefix + "layout=row に正の frame_count がありません。")
		if layout == LAYOUT_SPIN and int(sprite.get("frame_count", 0)) <= 0:
			messages.append("ERROR: " + prefix + "layout=spin に正の frame_count がありません。")
		if layout == LAYOUT_SPIN and int(sprite.get("visual_period_dirs", DIRECTION_RESOLUTION)) <= 0:
			messages.append("ERROR: " + prefix + "visual_period_dirs は正の値が必要です。")
		if layout == LAYOUT_ROTATED:
			var roughness: int = int(sprite.get("roughness", 4))
			if roughness < ROUGHNESS_MIN or roughness > ROUGHNESS_MAX:
				messages.append("WARN: " + prefix + "roughness %d は %d〜%d の範囲外です（clampされます）。" % [roughness, ROUGHNESS_MIN, ROUGHNESS_MAX])

		# --- ここから v2 フィールドの検証です。 ---
		var frame_count: int = get_frame_count(sprite)

		var durations: Array = sprite.get("durations", [])
		if not durations.is_empty() and frame_count > 0 and durations.size() != frame_count:
			messages.append("ERROR: " + prefix + "durations の要素数 %d がフレーム数 %d と一致しません。" % [durations.size(), frame_count])
		for duration_msec in durations:
			if int(duration_msec) <= 0:
				messages.append("WARN: " + prefix + "durations に 0 以下の値があります。")
				break

		var offsets: Array = sprite.get("offsets", [])
		if not offsets.is_empty() and frame_count > 0 and offsets.size() != frame_count:
			messages.append("ERROR: " + prefix + "offsets の要素数 %d がフレーム数 %d と一致しません。" % [offsets.size(), frame_count])

		var source_size: Array = sprite.get("source_size", [])
		if source_size.size() == 2 and (int(source_size[0]) <= 0 or int(source_size[1]) <= 0):
			messages.append("WARN: " + prefix + "source_size に 0 以下の値があります。")

		for tag_name in (sprite.get("tags", {}) as Dictionary):
			var tag_range: Vector2i = get_tag_range(sprite, String(tag_name))
			if tag_range.x < 0 or tag_range.y < tag_range.x:
				messages.append("ERROR: " + prefix + "タグ '%s' の範囲 [%d,%d] が不正です。" % [String(tag_name), tag_range.x, tag_range.y])
			elif frame_count > 0 and tag_range.y >= frame_count:
				messages.append("ERROR: " + prefix + "タグ '%s' の終端 %d がフレーム数 %d を超えています。" % [String(tag_name), tag_range.y, frame_count])

		# アトラス画像サイズが与えられていれば、切り出し矩形の範囲外チェックをします。
		if atlas_sizes.has(atlas_alias):
			var tex_size: Vector2i = atlas_sizes[atlas_alias]
			for frame_rect in expand_check_rects(sprite):
				if frame_rect.position.x < 0 or frame_rect.position.y < 0 \
						or frame_rect.end.x > float(tex_size.x) or frame_rect.end.y > float(tex_size.y):
					messages.append("WARN: " + prefix + "矩形 %s がアトラス範囲 %s を食み出しています。" % [str(frame_rect), str(tex_size)])
					break
	return messages
# [validate]END


# [expand_check_rects]
# 処理内容: 範囲外チェック用に、スプライト定義が参照する全矩形を列挙します。
#           rotated/spin は元絵の rect 1つだけをチェック対象にします。
# 引数 sprite: 正規化済みスプライト定義です。
# 戻り値: チェック対象矩形の Array[Rect2] です。
static func expand_check_rects(sprite: Dictionary) -> Array[Rect2]:
	var layout: String = String(sprite.get("layout", LAYOUT_SINGLE))
	if layout == LAYOUT_ROTATED or layout == LAYOUT_SPIN:
		var result: Array[Rect2] = []
		if sprite.has("rect"):
			var r: Array = sprite["rect"]
			result.append(Rect2(float(r[0]), float(r[1]), float(r[2]), float(r[3])))
		return result
	return build_frames(sprite)
# [expand_check_rects]END
