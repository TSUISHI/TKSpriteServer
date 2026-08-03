# tk_aseprite_file.gd — .aseprite / .ase バイナリを直接読み込む（経路B）
#
# Aseprite 本体も外部ツールも使わずに、GDScript だけで ASE ファイルを解析し、
# レイヤーを合成した Image の配列を取り出します。res:// に置いた .aseprite を
# そのまま素材として使えるようにするための土台です。
#
# 対応するチャンク:
#   0x2004 Layer   … レイヤー名・可視性・不透明度・ブレンドモード
#   0x2005 Cel     … 画素データ（type 0=生 / 1=リンク / 2=zlib圧縮）
#   0x2018 Tags    … アニメタグ
#   0x2019 Palette … インデックスカラー展開
#   0x0004 / 0x0011 旧 Palette … 古いファイル用の保険
#   0x2022 Slice   … pivot
#
# 対応カラーモード: RGBA(32) / グレースケール(16) / インデックス(8)
#
# レイヤー合成は Normal ブレンドのみです。その他のブレンドモードは警告を出した上で
# Normal として扱います（全モードの実装は費用対効果が低いため）。
# タイルマップレイヤーとタイルセットは未対応です。
#
# 設計書: CLAUDE_SPEC_TKSpriteServerKit.md §8.2
#
# 【メモリ規則】ツール実行時・起動時にのみ使用します。毎フレーム呼んではいけません。

class_name TKAsepriteFile extends RefCounted


# ファイル先頭と各フレーム先頭に置かれる識別値です。
const MAGIC_FILE: int = 0xA5E0
const MAGIC_FRAME: int = 0xF1FA

# 解析するチャンク種別です。
const CHUNK_OLD_PALETTE_A: int = 0x0004
const CHUNK_OLD_PALETTE_B: int = 0x0011
const CHUNK_LAYER: int = 0x2004
const CHUNK_CEL: int = 0x2005
const CHUNK_TAGS: int = 0x2018
const CHUNK_PALETTE: int = 0x2019
const CHUNK_SLICE: int = 0x2022

# レイヤー種別です。画像レイヤーだけを合成対象にします。
const LAYER_TYPE_IMAGE: int = 0
const LAYER_TYPE_GROUP: int = 1
const LAYER_TYPE_TILEMAP: int = 2

# セル種別です。
const CEL_RAW: int = 0
const CEL_LINKED: int = 1
const CEL_COMPRESSED: int = 2
const CEL_COMPRESSED_TILEMAP: int = 3

# 壊れたファイルで巨大なループへ入らないための上限です。
const MAX_FRAMES: int = 4096
const MAX_CHUNKS_PER_FRAME: int = 8192
const MAX_LAYERS: int = 1024
const MAX_CANVAS: int = 16384

# ファイルヘッダのフラグ bit0 が立っていればレイヤー不透明度が有効値です。
const HEADER_FLAG_LAYER_OPACITY: int = 1

# 圧縮セルの展開がどの経路で成功したかを 1 度だけ報告するための記録です。
# Godot の COMPRESSION_DEFLATE は raw deflate を期待しますが、Aseprite は zlib 形式で
# 書き出すため、どちらの経路を通ったかは移植時の判断材料になります。
static var _reported_decompress_route: String = ""


# [load_file]
# 処理内容: .aseprite ファイルを開いて解析します。
# 引数 path: 読み込むファイルのパスです。
# 戻り値: 解析結果の文書 Dictionary です。失敗時は空 Dictionary です。
static func load_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_error("TKAsepriteFile: ファイルが見つかりません: " + path)
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("TKAsepriteFile: ファイルを開けません: " + path)
		return {}
	var doc: Dictionary = parse_file(file, path)
	file.close()
	return doc
# [load_file]END


# [parse_file]
# 処理内容: 開いたファイルを先頭から解析し、文書 Dictionary を組み立てます。
#           画素のパレット展開は、パレットチャンクを読み終えたあとで一括して行います
#           （チャンク順に依存しないようにするためです）。
# 引数 file:         読み込み位置が先頭にあるファイルです。
# 引数 source_label: エラー表示と source 記録に使う元のパスです。
# 戻り値: 文書 Dictionary です。失敗時は空 Dictionary です。
static func parse_file(file: FileAccess, source_label: String) -> Dictionary:
	var header: Dictionary = read_header(file)
	if header.is_empty():
		push_error("TKAsepriteFile: ヘッダが不正です: " + source_label)
		return {}

	var frame_count: int = int(header["frame_count"])
	var color_depth: int = int(header["color_depth"])
	var opacity_valid: bool = (int(header["flags"]) & HEADER_FLAG_LAYER_OPACITY) != 0

	var layers: Array = []
	var frames: Array = []
	var tags: Array = []
	var pivot: Array = []
	var palette := PackedColorArray()
	var has_new_palette: bool = false
	var file_length: int = file.get_length()

	for frame_index in range(frame_count):
		var frame_start: int = file.get_position()
		if frame_start + 16 > file_length:
			push_error("TKAsepriteFile: フレーム %d の途中でファイルが終わりました: %s" % [frame_index, source_label])
			return {}

		var frame_bytes: int = file.get_32()
		var frame_magic: int = file.get_16()
		if frame_magic != MAGIC_FRAME:
			push_error("TKAsepriteFile: フレーム %d の識別値が不正です: %s" % [frame_index, source_label])
			return {}
		if frame_bytes < 16:
			push_error("TKAsepriteFile: フレーム %d のサイズが不正です: %s" % [frame_index, source_label])
			return {}

		var old_chunk_count: int = file.get_16()
		var duration: int = file.get_16()
		file.get_buffer(2)
		var new_chunk_count: int = file.get_32()
		var chunk_count: int = new_chunk_count if new_chunk_count != 0 else old_chunk_count
		if chunk_count > MAX_CHUNKS_PER_FRAME:
			push_error("TKAsepriteFile: フレーム %d のチャンク数が異常です: %s" % [frame_index, source_label])
			return {}

		var frame_end: int = mini(frame_start + frame_bytes, file_length)
		var cels: Array = []

		for chunk_index in range(chunk_count):
			var chunk_start: int = file.get_position()
			if chunk_start + 6 > frame_end:
				break
			var chunk_size: int = file.get_32()
			var chunk_type: int = file.get_16()
			if chunk_size < 6:
				push_error("TKAsepriteFile: チャンクサイズが不正です: " + source_label)
				return {}
			var chunk_end: int = mini(chunk_start + chunk_size, frame_end)

			match chunk_type:
				CHUNK_LAYER:
					if layers.size() >= MAX_LAYERS:
						push_error("TKAsepriteFile: レイヤー数が上限を超えました: " + source_label)
						return {}
					layers.append(read_layer_chunk(file, opacity_valid))
				CHUNK_CEL:
					var cel: Dictionary = read_cel_chunk(file, color_depth, chunk_end)
					if not cel.is_empty():
						cels.append(cel)
				CHUNK_TAGS:
					tags = read_tags_chunk(file)
				CHUNK_PALETTE:
					palette = read_palette_chunk(file, palette)
					has_new_palette = true
				CHUNK_OLD_PALETTE_A:
					if not has_new_palette:
						palette = read_old_palette_chunk(file, palette, false)
				CHUNK_OLD_PALETTE_B:
					if not has_new_palette:
						palette = read_old_palette_chunk(file, palette, true)
				CHUNK_SLICE:
					var slice_pivot: Array = read_slice_chunk(file)
					if pivot.is_empty() and not slice_pivot.is_empty():
						pivot = slice_pivot
				_:
					pass

			file.seek(chunk_end)

		frames.append({ "duration": duration, "cels": cels })
		file.seek(frame_end)

	var doc: Dictionary = {
		"width": int(header["width"]),
		"height": int(header["height"]),
		"color_depth": color_depth,
		"frame_count": frames.size(),
		"transparent_index": int(header["transparent_index"]),
		"palette": palette,
		"layers": layers,
		"frames": frames,
		"tags": tags,
		"pivot": pivot,
		"source": source_label
	}
	build_cel_images(doc)
	return doc
# [parse_file]END


# [read_header]
# 処理内容: ファイル先頭の 128 バイトのヘッダを読みます。読み終えた位置は必ず 128 になります。
# 引数 file: 読み込み位置が先頭にあるファイルです。
# 戻り値: ヘッダ値の Dictionary です。識別値が不正なら空 Dictionary です。
static func read_header(file: FileAccess) -> Dictionary:
	if file.get_length() < 128:
		return {}
	file.seek(0)
	var _file_size: int = file.get_32()
	var magic: int = file.get_16()
	if magic != MAGIC_FILE:
		return {}
	var frame_count: int = file.get_16()
	var width: int = file.get_16()
	var height: int = file.get_16()
	var color_depth: int = file.get_16()
	var flags: int = file.get_32()

	if frame_count <= 0 or frame_count > MAX_FRAMES:
		return {}
	if width <= 0 or height <= 0 or width > MAX_CANVAS or height > MAX_CANVAS:
		return {}
	if color_depth != 32 and color_depth != 16 and color_depth != 8:
		return {}

	# speed(非推奨) と 0 が 2 つ続きます。
	file.get_16()
	file.get_32()
	file.get_32()

	var transparent_index: int = file.get_8()
	# 無視する 3 バイトと色数、画素比、グリッド情報、予約領域をまとめて飛ばします。
	file.seek(128)

	return {
		"frame_count": frame_count,
		"width": width,
		"height": height,
		"color_depth": color_depth,
		"flags": flags,
		"transparent_index": transparent_index
	}
# [read_header]END


# [read_string]
# 処理内容: WORD 長 + UTF-8 バイト列の文字列を読みます。
# 引数 file: 読み込み位置が文字列の先頭にあるファイルです。
# 戻り値: 読み取った文字列です。
static func read_string(file: FileAccess) -> String:
	var length: int = file.get_16()
	if length <= 0:
		return ""
	var bytes: PackedByteArray = file.get_buffer(length)
	return bytes.get_string_from_utf8()
# [read_string]END


# [read_short]
# 処理内容: 符号あり 16bit を読みます。
# 引数 file: 読み込み位置が値の先頭にあるファイルです。
# 戻り値: 符号を復元した値です。
static func read_short(file: FileAccess) -> int:
	var value: int = file.get_16()
	if value >= 32768:
		return value - 65536
	return value
# [read_short]END


# [read_long]
# 処理内容: 符号あり 32bit を読みます。
# 引数 file: 読み込み位置が値の先頭にあるファイルです。
# 戻り値: 符号を復元した値です。
static func read_long(file: FileAccess) -> int:
	var value: int = file.get_32()
	if value >= 2147483648:
		return value - 4294967296
	return value
# [read_long]END


# [read_layer_chunk]
# 処理内容: レイヤーチャンク(0x2004)を読みます。グループもタイルマップも添字を消費するため、
#           除外せずに必ず 1 件として返します。
# 引数 file:          読み込み位置がチャンク本体の先頭にあるファイルです。
# 引数 opacity_valid: ファイルヘッダのフラグで不透明度が有効かどうかです。
# 戻り値: レイヤー情報の Dictionary です。
static func read_layer_chunk(file: FileAccess, opacity_valid: bool) -> Dictionary:
	var flags: int = file.get_16()
	var layer_type: int = file.get_16()
	var child_level: int = file.get_16()
	file.get_16()
	file.get_16()
	var blend_mode: int = file.get_16()
	var opacity: int = file.get_8()
	file.get_buffer(3)
	var layer_name: String = read_string(file)

	if not opacity_valid:
		opacity = 255
	if layer_type == LAYER_TYPE_TILEMAP:
		push_warning("TKAsepriteFile: タイルマップレイヤーは未対応です。無視します: " + layer_name)
	elif blend_mode != 0:
		push_warning("TKAsepriteFile: 未対応のブレンドモードです。Normal として扱います: " + layer_name)

	return {
		"name": layer_name,
		"visible": (flags & 1) != 0,
		"opacity": opacity,
		"blend_mode": blend_mode,
		"type": layer_type,
		"child_level": child_level
	}
# [read_layer_chunk]END


# [read_cel_chunk]
# 処理内容: セルチャンク(0x2005)を読みます。画素はここでは展開せず、生バイトのまま保持し、
#           パレットが確定したあとで build_cel_images() が Image へ変換します。
# 引数 file:        読み込み位置がチャンク本体の先頭にあるファイルです。
# 引数 color_depth: ファイルの色深度です。
# 引数 chunk_end:   このチャンクの終端位置です。圧縮データの長さ算出に使います。
# 戻り値: セル情報の Dictionary です。未対応種別なら空 Dictionary です。
static func read_cel_chunk(file: FileAccess, color_depth: int, chunk_end: int) -> Dictionary:
	var layer_index: int = file.get_16()
	var pos_x: int = read_short(file)
	var pos_y: int = read_short(file)
	var opacity: int = file.get_8()
	var cel_type: int = file.get_16()
	var _z_index: int = read_short(file)
	file.get_buffer(5)

	var cel: Dictionary = {
		"layer": layer_index,
		"x": pos_x,
		"y": pos_y,
		"opacity": opacity,
		"type": cel_type,
		"link_frame": -1,
		"image": null
	}

	match cel_type:
		CEL_RAW:
			var raw_w: int = file.get_16()
			var raw_h: int = file.get_16()
			var raw_size: int = raw_w * raw_h * get_pixel_stride(color_depth)
			cel["_width"] = raw_w
			cel["_height"] = raw_h
			cel["_bytes"] = file.get_buffer(raw_size)
			cel["_compressed"] = false
		CEL_LINKED:
			cel["link_frame"] = file.get_16()
		CEL_COMPRESSED:
			var packed_w: int = file.get_16()
			var packed_h: int = file.get_16()
			var remain: int = chunk_end - file.get_position()
			if remain <= 0:
				return {}
			cel["_width"] = packed_w
			cel["_height"] = packed_h
			cel["_bytes"] = file.get_buffer(remain)
			cel["_compressed"] = true
		CEL_COMPRESSED_TILEMAP:
			push_warning("TKAsepriteFile: 圧縮タイルマップセルは未対応です。無視します。")
			return {}
		_:
			push_warning("TKAsepriteFile: 未知のセル種別です。無視します: %d" % cel_type)
			return {}

	return cel
# [read_cel_chunk]END


# [read_tags_chunk]
# 処理内容: タグチャンク(0x2018)を読みます。
# 引数 file: 読み込み位置がチャンク本体の先頭にあるファイルです。
# 戻り値: タグ情報の配列です。
static func read_tags_chunk(file: FileAccess) -> Array:
	var tag_count: int = file.get_16()
	file.get_buffer(8)
	var tags: Array = []
	for index in range(tag_count):
		var from_frame: int = file.get_16()
		var to_frame: int = file.get_16()
		var direction: int = file.get_8()
		file.get_16()
		file.get_buffer(6)
		file.get_buffer(3)
		file.get_8()
		var tag_name: String = read_string(file)
		tags.append({
			"name": tag_name,
			"from": from_frame,
			"to": to_frame,
			"direction": direction
		})
	return tags
# [read_tags_chunk]END


# [read_palette_chunk]
# 処理内容: パレットチャンク(0x2019)を読み、指定範囲だけを差し替えます。
# 引数 file:    読み込み位置がチャンク本体の先頭にあるファイルです。
# 引数 palette: これまでのパレットです。
# 戻り値: 更新後のパレットです。
static func read_palette_chunk(file: FileAccess, palette: PackedColorArray) -> PackedColorArray:
	var total_size: int = file.get_32()
	var first_index: int = file.get_32()
	var last_index: int = file.get_32()
	file.get_buffer(8)

	var result := PackedColorArray(palette)
	if total_size > 0 and total_size <= 65536:
		result.resize(total_size)
	if last_index < first_index:
		return result

	for index in range(first_index, last_index + 1):
		var entry_flags: int = file.get_16()
		var red: int = file.get_8()
		var green: int = file.get_8()
		var blue: int = file.get_8()
		var alpha: int = file.get_8()
		if (entry_flags & 1) != 0:
			read_string(file)
		if index >= 0 and index < result.size():
			result[index] = Color8(red, green, blue, alpha)
	return result
# [read_palette_chunk]END


# [read_old_palette_chunk]
# 処理内容: 旧パレットチャンク(0x0004 / 0x0011)を読みます。新形式が無い古いファイル用です。
# 引数 file:    読み込み位置がチャンク本体の先頭にあるファイルです。
# 引数 palette: これまでのパレットです。
# 引数 six_bit: 0x0011 のとき true です。成分が 0〜63 なので 4 倍します。
# 戻り値: 更新後のパレットです。
static func read_old_palette_chunk(file: FileAccess, palette: PackedColorArray, six_bit: bool) -> PackedColorArray:
	var packet_count: int = file.get_16()
	var result := PackedColorArray(palette)
	var cursor: int = 0
	for packet_index in range(packet_count):
		cursor += file.get_8()
		var color_count: int = file.get_8()
		if color_count == 0:
			color_count = 256
		if cursor + color_count > result.size():
			result.resize(cursor + color_count)
		for color_index in range(color_count):
			var red: int = file.get_8()
			var green: int = file.get_8()
			var blue: int = file.get_8()
			if six_bit:
				red = mini(red * 4, 255)
				green = mini(green * 4, 255)
				blue = mini(blue * 4, 255)
			result[cursor + color_index] = Color8(red, green, blue, 255)
		cursor += color_count
	return result
# [read_old_palette_chunk]END


# [read_slice_chunk]
# 処理内容: スライスチャンク(0x2022)を読み、pivot だけを取り出します。
# 引数 file: 読み込み位置がチャンク本体の先頭にあるファイルです。
# 戻り値: [pivot_x, pivot_y] です。pivot を持たなければ空配列です。
static func read_slice_chunk(file: FileAccess) -> Array:
	var key_count: int = file.get_32()
	var flags: int = file.get_32()
	file.get_32()
	read_string(file)

	var has_nine_patch: bool = (flags & 1) != 0
	var has_pivot: bool = (flags & 2) != 0
	if not has_pivot:
		return []

	for key_index in range(key_count):
		file.get_32()
		read_long(file)
		read_long(file)
		file.get_32()
		file.get_32()
		if has_nine_patch:
			read_long(file)
			read_long(file)
			file.get_32()
			file.get_32()
		var pivot_x: int = read_long(file)
		var pivot_y: int = read_long(file)
		return [pivot_x, pivot_y]
	return []
# [read_slice_chunk]END


# [get_pixel_stride]
# 処理内容: 色深度から 1 画素あたりのバイト数を返します。
# 引数 color_depth: 32 / 16 / 8 のいずれかです。
# 戻り値: 画素バイト数です。
static func get_pixel_stride(color_depth: int) -> int:
	match color_depth:
		32:
			return 4
		16:
			return 2
		8:
			return 1
	return 0
# [get_pixel_stride]END


# [decompress_cel_bytes]
# 処理内容: 圧縮セルの画素データを展開します。
#           Aseprite は zlib 形式（先頭 2 バイトのヘッダと末尾 4 バイトの adler32）で書き出しますが、
#           Godot の COMPRESSION_DEFLATE は raw deflate を期待するため、まず前後を取り除いて試します。
# 引数 bytes:         チャンクから取り出した圧縮バイト列です。
# 引数 expected_size: 展開後に期待するバイト数です。
# 戻り値: 展開後のバイト列です。失敗時は空の PackedByteArray です。
static func decompress_cel_bytes(bytes: PackedByteArray, expected_size: int) -> PackedByteArray:
	if expected_size <= 0 or bytes.is_empty():
		return PackedByteArray()

	if bytes.size() >= 6 and (bytes[0] & 0x0F) == 8:
		var body: PackedByteArray = bytes.slice(2, bytes.size() - 4)
		var stripped: PackedByteArray = body.decompress(expected_size, FileAccess.COMPRESSION_DEFLATE)
		if stripped.size() == expected_size:
			_report_decompress_route("zlib")
			return stripped

	var raw: PackedByteArray = bytes.decompress(expected_size, FileAccess.COMPRESSION_DEFLATE)
	if raw.size() == expected_size:
		_report_decompress_route("deflate")
		return raw

	var gzipped: PackedByteArray = bytes.decompress(expected_size, FileAccess.COMPRESSION_GZIP)
	if gzipped.size() == expected_size:
		_report_decompress_route("gzip")
		return gzipped

	push_error("TKAsepriteFile: 圧縮セルを展開できません（期待 %d バイト）。" % expected_size)
	return PackedByteArray()
# [decompress_cel_bytes]END


# [_report_decompress_route]
# 処理内容: 圧縮セルの展開に成功した経路を 1 度だけ出力します。移植先の環境で
#           どの経路が効いているかを確認するための記録です。
# 引数 route: 経路名です。
# 戻り値: なし。
static func _report_decompress_route(route: String) -> void:
	if _reported_decompress_route == route:
		return
	_reported_decompress_route = route
	print("TKAsepriteFile: 圧縮セルの展開経路 = " + route)
	return  # end of function
# [_report_decompress_route]END


# [cel_bytes_to_image]
# 処理内容: セルの生画素バイト列を RGBA8 の Image へ変換します。
# 引数 bytes:             展開済みの画素バイト列です。
# 引数 width:             セルの幅です。
# 引数 height:            セルの高さです。
# 引数 color_depth:       32 / 16 / 8 です。
# 引数 palette:           インデックスカラー用のパレットです。
# 引数 transparent_index: 完全透明として扱うパレット番号です。
# 戻り値: RGBA8 の Image です。失敗時は null です。
static func cel_bytes_to_image(
	bytes: PackedByteArray,
	width: int,
	height: int,
	color_depth: int,
	palette: PackedColorArray,
	transparent_index: int
) -> Image:
	if width <= 0 or height <= 0:
		return null
	var stride: int = get_pixel_stride(color_depth)
	var pixel_count: int = width * height
	if stride <= 0 or bytes.size() < pixel_count * stride:
		push_error("TKAsepriteFile: セルの画素数が足りません（%d 画素ぶん必要）。" % pixel_count)
		return null

	if color_depth == 32:
		var direct: PackedByteArray = bytes.slice(0, pixel_count * 4)
		return Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, direct)

	var out := PackedByteArray()
	out.resize(pixel_count * 4)

	if color_depth == 16:
		for index in range(pixel_count):
			var level: int = bytes[index * 2]
			var level_alpha: int = bytes[index * 2 + 1]
			out[index * 4] = level
			out[index * 4 + 1] = level
			out[index * 4 + 2] = level
			out[index * 4 + 3] = level_alpha
	else:
		var palette_size: int = palette.size()
		for index in range(pixel_count):
			var entry: int = bytes[index]
			if entry == transparent_index or entry >= palette_size:
				out[index * 4] = 0
				out[index * 4 + 1] = 0
				out[index * 4 + 2] = 0
				out[index * 4 + 3] = 0
				continue
			var color: Color = palette[entry]
			out[index * 4] = int(round(color.r * 255.0))
			out[index * 4 + 1] = int(round(color.g * 255.0))
			out[index * 4 + 2] = int(round(color.b * 255.0))
			out[index * 4 + 3] = int(round(color.a * 255.0))

	return Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, out)
# [cel_bytes_to_image]END


# [build_cel_images]
# 処理内容: 保持していたセルの生バイト列を Image へ変換し、作業用キーを取り除きます。
#           パレットが確定してから呼ぶ必要があるため、解析の最後に 1 度だけ実行します。
# 引数 doc: 解析途中の文書 Dictionary です。内容を直接書き換えます。
# 戻り値: なし。
static func build_cel_images(doc: Dictionary) -> void:
	var color_depth: int = int(doc["color_depth"])
	var palette: PackedColorArray = doc["palette"]
	var transparent_index: int = int(doc["transparent_index"])
	var frames: Array = doc["frames"]

	for frame in frames:
		var cels: Array = (frame as Dictionary)["cels"]
		for cel_variant in cels:
			var cel: Dictionary = cel_variant
			if not cel.has("_bytes"):
				continue
			var cel_width: int = int(cel["_width"])
			var cel_height: int = int(cel["_height"])
			var stride: int = get_pixel_stride(color_depth)
			var expected: int = cel_width * cel_height * stride
			var pixels: PackedByteArray = cel["_bytes"]
			if bool(cel["_compressed"]):
				pixels = decompress_cel_bytes(pixels, expected)
			if pixels.size() >= expected and expected > 0:
				cel["image"] = cel_bytes_to_image(pixels, cel_width, cel_height, color_depth, palette, transparent_index)
			cel.erase("_bytes")
			cel.erase("_width")
			cel.erase("_height")
			cel.erase("_compressed")
	return  # end of function
# [build_cel_images]END


# [resolve_linked_cel]
# 処理内容: リンクセル(type 1)が指す先のセルを探します。
# 引数 doc:         文書 Dictionary です。
# 引数 frame_index: リンク先のフレーム番号です。
# 引数 layer_index: レイヤー番号です。
# 戻り値: 見つかったセルの Dictionary です。無ければ空 Dictionary です。
static func resolve_linked_cel(doc: Dictionary, frame_index: int, layer_index: int) -> Dictionary:
	var frames: Array = doc["frames"]
	if frame_index < 0 or frame_index >= frames.size():
		return {}
	var cels: Array = (frames[frame_index] as Dictionary)["cels"]
	for cel_variant in cels:
		var cel: Dictionary = cel_variant
		if int(cel["layer"]) == layer_index and cel["image"] != null:
			return cel
	return {}
# [resolve_linked_cel]END


# [composite_frame]
# 処理内容: 1 フレームぶんのレイヤーを下から順に Normal ブレンドで合成します。
# 引数 doc:         文書 Dictionary です。
# 引数 frame_index: 合成するフレーム番号です。
# 戻り値: キャンバスと同じ大きさの RGBA8 Image です。失敗時は null です。
static func composite_frame(doc: Dictionary, frame_index: int) -> Image:
	var frames: Array = doc["frames"]
	if frame_index < 0 or frame_index >= frames.size():
		return null

	var canvas_width: int = int(doc["width"])
	var canvas_height: int = int(doc["height"])
	var canvas := Image.create(canvas_width, canvas_height, false, Image.FORMAT_RGBA8)
	canvas.fill(Color(0.0, 0.0, 0.0, 0.0))

	var layers: Array = doc["layers"]
	var cels: Array = (frames[frame_index] as Dictionary)["cels"]

	for layer_index in range(layers.size()):
		var layer: Dictionary = layers[layer_index]
		if not bool(layer["visible"]):
			continue
		if int(layer["type"]) != LAYER_TYPE_IMAGE:
			continue

		for cel_variant in cels:
			var cel: Dictionary = cel_variant
			if int(cel["layer"]) != layer_index:
				continue

			var cel_image = cel["image"]
			var pos_x: int = int(cel["x"])
			var pos_y: int = int(cel["y"])
			if int(cel["type"]) == CEL_LINKED:
				var linked: Dictionary = resolve_linked_cel(doc, int(cel["link_frame"]), layer_index)
				if linked.is_empty():
					continue
				cel_image = linked["image"]
			if cel_image == null:
				continue

			var alpha: float = (float(layer["opacity"]) / 255.0) * (float(cel["opacity"]) / 255.0)
			blend_cel_into(canvas, cel_image, pos_x, pos_y, alpha)

	return canvas
# [composite_frame]END


# [blend_cel_into]
# 処理内容: セル画像 1 枚を Normal ブレンドで下地へ重ねます。キャンバスからはみ出す分と
#           負座標は交差範囲だけを描きます。
# 引数 dst:       重ね先の画像です。直接書き換えます。
# 引数 cel_image: 重ねる画像です。
# 引数 pos_x:     重ねる位置の X です。負になりえます。
# 引数 pos_y:     重ねる位置の Y です。負になりえます。
# 引数 alpha:     レイヤーとセルの不透明度を掛け合わせた実効アルファです。
# 戻り値: なし。
static func blend_cel_into(dst: Image, cel_image: Image, pos_x: int, pos_y: int, alpha: float) -> void:
	if dst == null or cel_image == null or alpha <= 0.0:
		return
	var start_x: int = maxi(0, pos_x)
	var start_y: int = maxi(0, pos_y)
	var end_x: int = mini(dst.get_width(), pos_x + cel_image.get_width())
	var end_y: int = mini(dst.get_height(), pos_y + cel_image.get_height())
	if start_x >= end_x or start_y >= end_y:
		return

	for y in range(start_y, end_y):
		for x in range(start_x, end_x):
			var src: Color = cel_image.get_pixel(x - pos_x, y - pos_y)
			var src_alpha: float = src.a * alpha
			if src_alpha <= 0.0:
				continue
			var base: Color = dst.get_pixel(x, y)
			var out_alpha: float = src_alpha + base.a * (1.0 - src_alpha)
			if out_alpha <= 0.0:
				dst.set_pixel(x, y, Color(0.0, 0.0, 0.0, 0.0))
				continue
			var keep: float = base.a * (1.0 - src_alpha)
			var out_red: float = (src.r * src_alpha + base.r * keep) / out_alpha
			var out_green: float = (src.g * src_alpha + base.g * keep) / out_alpha
			var out_blue: float = (src.b * src_alpha + base.b * keep) / out_alpha
			dst.set_pixel(x, y, Color(out_red, out_green, out_blue, out_alpha))
	return  # end of function
# [blend_cel_into]END


# [build_frame_images]
# 処理内容: 全フレームを合成して Image の配列を返します。
# 引数 doc: 文書 Dictionary です。
# 戻り値: フレーム順の Image 配列です。文書が空なら空配列です。
static func build_frame_images(doc: Dictionary) -> Array:
	if doc.is_empty():
		return []
	var images: Array = []
	var frames: Array = doc["frames"]
	for frame_index in range(frames.size()):
		var image: Image = composite_frame(doc, frame_index)
		if image == null:
			continue
		images.append(image)
	return images
# [build_frame_images]END


# [get_frame_durations]
# 処理内容: 各フレームの表示時間（ミリ秒）を配列で返します。
# 引数 doc: 文書 Dictionary です。
# 戻り値: フレーム順の表示時間配列です。
static func get_frame_durations(doc: Dictionary) -> Array:
	var durations: Array = []
	if doc.is_empty():
		return durations
	var frames: Array = doc["frames"]
	for frame in frames:
		durations.append(int((frame as Dictionary)["duration"]))
	return durations
# [get_frame_durations]END
