# test_aseprite_file.gd — TKAsepriteFile（経路B / .aseprite 直読み）の自己完結テスト
#
# 実行方法:
#   Godot --headless --path <プロジェクト> --script res://tests/test_aseprite_file.gd
#
# Aseprite 本体には依存しません。テスト自身が ASE バイナリを組み立てて書き出し、
# それを読み戻して検証します（往復テスト）。

extends SceneTree

var failure_count: int = 0

const WORK_DIR: String = "user://tk_test_ase_file"

# 色成分の比較許容誤差です。8bit 換算で ±2 まで許します。
const COLOR_EPSILON: float = 2.5 / 255.0


# [_initialize]
# 処理内容: 作業ディレクトリを用意し、全テストを実行します。
# 戻り値: なし
func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(WORK_DIR)

	test_rgba_raw_cel()
	test_compressed_cel()
	test_indexed_and_palette()
	test_grayscale()
	test_two_layers_composite()
	test_layer_opacity()
	test_linked_cel()
	test_negative_cel_position()
	test_tags_and_pivot()
	test_unknown_chunk_skipped()
	test_broken_file_returns_empty()
	test_import_aseprite_roundtrip()
	test_id_stability_on_reimport()
	test_end_to_end_registration()

	if failure_count == 0:
		print("test_aseprite_file: ALL PASS")
	else:
		print("test_aseprite_file: FAILED %d" % failure_count)
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


# [check_color]
# 処理内容: 色を許容誤差付きで比較します。
# 引数 actual:   実際の色です。
# 引数 expected: 期待する色です。
# 引数 label:    失敗時に表示する内容です。
# 戻り値: なし
func check_color(actual: Color, expected: Color, label: String) -> void:
	var ok: bool = absf(actual.r - expected.r) <= COLOR_EPSILON \
		and absf(actual.g - expected.g) <= COLOR_EPSILON \
		and absf(actual.b - expected.b) <= COLOR_EPSILON \
		and absf(actual.a - expected.a) <= COLOR_EPSILON
	if not ok:
		failure_count += 1
		print("  FAIL: %s (actual=%s expected=%s)" % [label, str(actual), str(expected)])
# [check_color]END


# ============================================================================
#  バイナリ組み立てヘルパ
#  PackedByteArray は値渡しになるため、すべて「書き込み後の配列を返す」形にします。
# ============================================================================

# [put_u8]
# 処理内容: 1 バイトを追加します。
# 引数 buf:   追加先です。
# 引数 value: 値です。
# 戻り値: 追加後の配列です。
func put_u8(buf: PackedByteArray, value: int) -> PackedByteArray:
	buf.append(value & 0xFF)
	return buf
# [put_u8]END


# [put_u16]
# 処理内容: リトルエンディアンで 2 バイトを追加します。
# 引数 buf:   追加先です。
# 引数 value: 値です。
# 戻り値: 追加後の配列です。
func put_u16(buf: PackedByteArray, value: int) -> PackedByteArray:
	buf.append(value & 0xFF)
	buf.append((value >> 8) & 0xFF)
	return buf
# [put_u16]END


# [put_u32]
# 処理内容: リトルエンディアンで 4 バイトを追加します。
# 引数 buf:   追加先です。
# 引数 value: 値です。
# 戻り値: 追加後の配列です。
func put_u32(buf: PackedByteArray, value: int) -> PackedByteArray:
	buf.append(value & 0xFF)
	buf.append((value >> 8) & 0xFF)
	buf.append((value >> 16) & 0xFF)
	buf.append((value >> 24) & 0xFF)
	return buf
# [put_u32]END


# [put_fill]
# 処理内容: 同じ値を指定個数ぶん追加します。
# 引数 buf:   追加先です。
# 引数 count: 個数です。
# 引数 value: 値です。
# 戻り値: 追加後の配列です。
func put_fill(buf: PackedByteArray, count: int, value: int) -> PackedByteArray:
	for index in range(count):
		buf.append(value & 0xFF)
	return buf
# [put_fill]END


# [put_string]
# 処理内容: WORD 長 + UTF-8 バイト列を追加します。
# 引数 buf:  追加先です。
# 引数 text: 文字列です。
# 戻り値: 追加後の配列です。
func put_string(buf: PackedByteArray, text: String) -> PackedByteArray:
	var bytes: PackedByteArray = text.to_utf8_buffer()
	buf = put_u16(buf, bytes.size())
	buf.append_array(bytes)
	return buf
# [put_string]END


# [make_header]
# 処理内容: 128 バイトのファイルヘッダを組み立てます。
# 引数 frame_count:       フレーム数です。
# 引数 width:             キャンバス幅です。
# 引数 height:            キャンバス高さです。
# 引数 color_depth:       32 / 16 / 8 です。
# 引数 transparent_index: 透明色のパレット番号です。
# 戻り値: ヘッダのバイト列です。
func make_header(frame_count: int, width: int, height: int, color_depth: int, transparent_index: int) -> PackedByteArray:
	var buf := PackedByteArray()
	buf = put_u32(buf, 0)
	buf = put_u16(buf, 0xA5E0)
	buf = put_u16(buf, frame_count)
	buf = put_u16(buf, width)
	buf = put_u16(buf, height)
	buf = put_u16(buf, color_depth)
	buf = put_u32(buf, 1)
	buf = put_u16(buf, 100)
	buf = put_u32(buf, 0)
	buf = put_u32(buf, 0)
	buf = put_u8(buf, transparent_index)
	buf = put_fill(buf, 3, 0)
	buf = put_u16(buf, 0)
	buf = put_u8(buf, 1)
	buf = put_u8(buf, 1)
	buf = put_u16(buf, 0)
	buf = put_u16(buf, 0)
	buf = put_u16(buf, 16)
	buf = put_u16(buf, 16)
	buf = put_fill(buf, 84, 0)
	return buf
# [make_header]END


# [make_chunk]
# 処理内容: チャンクヘッダ（サイズ + 種別）を付けたチャンクを作ります。
# 引数 chunk_type: チャンク種別です。
# 引数 body:       チャンク本体です。
# 戻り値: チャンク全体のバイト列です。
func make_chunk(chunk_type: int, body: PackedByteArray) -> PackedByteArray:
	var buf := PackedByteArray()
	buf = put_u32(buf, body.size() + 6)
	buf = put_u16(buf, chunk_type)
	buf.append_array(body)
	return buf
# [make_chunk]END


# [make_frame]
# 処理内容: フレームヘッダを付けた 1 フレームぶんのバイト列を作ります。
# 引数 duration: 表示時間（ミリ秒）です。
# 引数 chunks:   チャンクのバイト列の配列です。
# 戻り値: フレーム全体のバイト列です。
func make_frame(duration: int, chunks: Array) -> PackedByteArray:
	var body := PackedByteArray()
	for chunk in chunks:
		body.append_array(chunk)
	var buf := PackedByteArray()
	buf = put_u32(buf, body.size() + 16)
	buf = put_u16(buf, 0xF1FA)
	buf = put_u16(buf, 0xFFFF)
	buf = put_u16(buf, duration)
	buf = put_fill(buf, 2, 0)
	buf = put_u32(buf, chunks.size())
	buf.append_array(body)
	return buf
# [make_frame]END


# [make_layer_body]
# 処理内容: レイヤーチャンクの本体を作ります。
# 引数 visible:    可視かどうかです。
# 引数 layer_type: 0 通常 / 1 グループ / 2 タイルマップ です。
# 引数 blend_mode: ブレンドモードです。
# 引数 opacity:    不透明度です。
# 引数 layer_name: レイヤー名です。
# 戻り値: チャンク本体のバイト列です。
func make_layer_body(visible: bool, layer_type: int, blend_mode: int, opacity: int, layer_name: String) -> PackedByteArray:
	var buf := PackedByteArray()
	buf = put_u16(buf, 1 if visible else 0)
	buf = put_u16(buf, layer_type)
	buf = put_u16(buf, 0)
	buf = put_u16(buf, 0)
	buf = put_u16(buf, 0)
	buf = put_u16(buf, blend_mode)
	buf = put_u8(buf, opacity)
	buf = put_fill(buf, 3, 0)
	buf = put_string(buf, layer_name)
	return buf
# [make_layer_body]END


# [make_cel_head]
# 処理内容: セルチャンク本体の共通部分（16 バイト）を作ります。
# 引数 layer_index: レイヤー番号です。
# 引数 pos_x:       X 位置です。負でも構いません。
# 引数 pos_y:       Y 位置です。負でも構いません。
# 引数 opacity:     不透明度です。
# 引数 cel_type:    セル種別です。
# 戻り値: 共通部分のバイト列です。
func make_cel_head(layer_index: int, pos_x: int, pos_y: int, opacity: int, cel_type: int) -> PackedByteArray:
	var buf := PackedByteArray()
	buf = put_u16(buf, layer_index)
	buf = put_u16(buf, pos_x if pos_x >= 0 else pos_x + 65536)
	buf = put_u16(buf, pos_y if pos_y >= 0 else pos_y + 65536)
	buf = put_u8(buf, opacity)
	buf = put_u16(buf, cel_type)
	buf = put_u16(buf, 0)
	buf = put_fill(buf, 5, 0)
	return buf
# [make_cel_head]END


# [make_cel_raw]
# 処理内容: 生画素セル（種別0）のチャンクを作ります。
# 引数 layer_index: レイヤー番号です。
# 引数 pos_x:       X 位置です。
# 引数 pos_y:       Y 位置です。
# 引数 opacity:     不透明度です。
# 引数 width:       セル幅です。
# 引数 height:      セル高さです。
# 引数 pixels:      画素バイト列です。
# 戻り値: チャンク全体のバイト列です。
func make_cel_raw(layer_index: int, pos_x: int, pos_y: int, opacity: int, width: int, height: int, pixels: PackedByteArray) -> PackedByteArray:
	var body: PackedByteArray = make_cel_head(layer_index, pos_x, pos_y, opacity, 0)
	body = put_u16(body, width)
	body = put_u16(body, height)
	body.append_array(pixels)
	return make_chunk(0x2005, body)
# [make_cel_raw]END


# [make_cel_linked]
# 処理内容: リンクセル（種別1）のチャンクを作ります。
# 引数 layer_index: レイヤー番号です。
# 引数 pos_x:       X 位置です。
# 引数 pos_y:       Y 位置です。
# 引数 opacity:     不透明度です。
# 引数 link_frame:  リンク先のフレーム番号です。
# 戻り値: チャンク全体のバイト列です。
func make_cel_linked(layer_index: int, pos_x: int, pos_y: int, opacity: int, link_frame: int) -> PackedByteArray:
	var body: PackedByteArray = make_cel_head(layer_index, pos_x, pos_y, opacity, 1)
	body = put_u16(body, link_frame)
	return make_chunk(0x2005, body)
# [make_cel_linked]END


# [make_cel_compressed]
# 処理内容: 圧縮セル（種別2）のチャンクを作ります。画素は zlib 形式で包みます。
# 引数 layer_index: レイヤー番号です。
# 引数 pos_x:       X 位置です。
# 引数 pos_y:       Y 位置です。
# 引数 opacity:     不透明度です。
# 引数 width:       セル幅です。
# 引数 height:      セル高さです。
# 引数 pixels:      圧縮前の画素バイト列です。
# 戻り値: チャンク全体のバイト列です。
func make_cel_compressed(layer_index: int, pos_x: int, pos_y: int, opacity: int, width: int, height: int, pixels: PackedByteArray) -> PackedByteArray:
	var body: PackedByteArray = make_cel_head(layer_index, pos_x, pos_y, opacity, 2)
	body = put_u16(body, width)
	body = put_u16(body, height)
	body.append_array(wrap_zlib(pixels))
	return make_chunk(0x2005, body)
# [make_cel_compressed]END


# [wrap_zlib]
# 処理内容: raw deflate を zlib 形式（2 バイトヘッダ + adler32 の 4 バイト）で包みます。
#           Aseprite の圧縮セルと同じ形にするために必要です。
# 引数 raw: 圧縮前のバイト列です。
# 戻り値: zlib 形式のバイト列です。
func wrap_zlib(raw: PackedByteArray) -> PackedByteArray:
	var deflated: PackedByteArray = raw.compress(FileAccess.COMPRESSION_DEFLATE)
	var buf := PackedByteArray()
	buf.append(0x78)
	buf.append(0x9C)
	buf.append_array(deflated)
	var checksum: int = adler32(raw)
	buf.append((checksum >> 24) & 0xFF)
	buf.append((checksum >> 16) & 0xFF)
	buf.append((checksum >> 8) & 0xFF)
	buf.append(checksum & 0xFF)
	return buf
# [wrap_zlib]END


# [adler32]
# 処理内容: zlib のチェックサムを計算します。
# 引数 bytes: 対象のバイト列です。
# 戻り値: adler32 の値です。
func adler32(bytes: PackedByteArray) -> int:
	var part_a: int = 1
	var part_b: int = 0
	for value in bytes:
		part_a = (part_a + value) % 65521
		part_b = (part_b + part_a) % 65521
	return (part_b << 16) | part_a
# [adler32]END


# [make_tags_chunk]
# 処理内容: タグチャンクを作ります。
# 引数 tags: {"name","from","to","direction"} の配列です。
# 戻り値: チャンク全体のバイト列です。
func make_tags_chunk(tags: Array) -> PackedByteArray:
	var body := PackedByteArray()
	body = put_u16(body, tags.size())
	body = put_fill(body, 8, 0)
	for tag_variant in tags:
		var tag: Dictionary = tag_variant
		body = put_u16(body, int(tag["from"]))
		body = put_u16(body, int(tag["to"]))
		body = put_u8(body, int(tag["direction"]))
		body = put_u16(body, 0)
		body = put_fill(body, 6, 0)
		body = put_fill(body, 3, 0)
		body = put_u8(body, 0)
		body = put_string(body, String(tag["name"]))
	return make_chunk(0x2018, body)
# [make_tags_chunk]END


# [make_palette_chunk]
# 処理内容: パレットチャンク(0x2019)を作ります。
# 引数 colors: Color の配列です。0 番から順に割り当てます。
# 戻り値: チャンク全体のバイト列です。
func make_palette_chunk(colors: Array) -> PackedByteArray:
	var body := PackedByteArray()
	body = put_u32(body, colors.size())
	body = put_u32(body, 0)
	body = put_u32(body, colors.size() - 1)
	body = put_fill(body, 8, 0)
	for color_variant in colors:
		var color: Color = color_variant
		body = put_u16(body, 0)
		body = put_u8(body, int(round(color.r * 255.0)))
		body = put_u8(body, int(round(color.g * 255.0)))
		body = put_u8(body, int(round(color.b * 255.0)))
		body = put_u8(body, int(round(color.a * 255.0)))
	return make_chunk(0x2019, body)
# [make_palette_chunk]END


# [make_slice_chunk]
# 処理内容: pivot だけを持つスライスチャンクを作ります。
# 引数 slice_name: スライス名です。
# 引数 pivot_x:    pivot の X です。
# 引数 pivot_y:    pivot の Y です。
# 戻り値: チャンク全体のバイト列です。
func make_slice_chunk(slice_name: String, pivot_x: int, pivot_y: int) -> PackedByteArray:
	var body := PackedByteArray()
	body = put_u32(body, 1)
	body = put_u32(body, 2)
	body = put_u32(body, 0)
	body = put_string(body, slice_name)
	body = put_u32(body, 0)
	body = put_u32(body, 0)
	body = put_u32(body, 0)
	body = put_u32(body, 8)
	body = put_u32(body, 8)
	body = put_u32(body, pivot_x)
	body = put_u32(body, pivot_y)
	return make_chunk(0x2022, body)
# [make_slice_chunk]END


# [make_rgba_pixels]
# 処理内容: 単色で埋めた 32bpp の画素バイト列を作ります。
# 引数 count: 画素数です。
# 引数 color: 色です。
# 戻り値: 画素バイト列です。
func make_rgba_pixels(count: int, color: Color) -> PackedByteArray:
	var buf := PackedByteArray()
	for index in range(count):
		buf.append(int(round(color.r * 255.0)))
		buf.append(int(round(color.g * 255.0)))
		buf.append(int(round(color.b * 255.0)))
		buf.append(int(round(color.a * 255.0)))
	return buf
# [make_rgba_pixels]END


# [write_ase]
# 処理内容: 組み立てたバイト列をファイルへ書き出します。
# 引数 path:  保存先パスです。
# 引数 bytes: 内容です。
# 戻り値: なし
func write_ase(path: String, bytes: PackedByteArray) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	check(file != null, "ASEファイルを書けない: " + path)
	if file == null:
		return
	file.store_buffer(bytes)
	file.close()
# [write_ase]END


# ============================================================================
#  テスト本体
# ============================================================================

# [test_rgba_raw_cel]
# 処理内容: 32bpp・生画素セルの基本的な読み込みを検証します。
# 戻り値: なし
func test_rgba_raw_cel() -> void:
	var path: String = WORK_DIR + "/raw.aseprite"
	var layer: PackedByteArray = make_chunk(0x2004, make_layer_body(true, 0, 0, 255, "Layer 1"))
	var cel0: PackedByteArray = make_cel_raw(0, 1, 1, 255, 2, 2, make_rgba_pixels(4, Color(1.0, 0.0, 0.0, 1.0)))
	var cel1: PackedByteArray = make_cel_raw(0, 0, 0, 255, 1, 1, make_rgba_pixels(1, Color(0.0, 1.0, 0.0, 1.0)))

	var bytes: PackedByteArray = make_header(2, 4, 4, 32, 0)
	bytes.append_array(make_frame(100, [layer, cel0]))
	bytes.append_array(make_frame(250, [cel1]))
	write_ase(path, bytes)

	var doc: Dictionary = TKAsepriteFile.load_file(path)
	check(not doc.is_empty(), "raw: 解析に失敗した")
	if doc.is_empty():
		return
	check(int(doc["width"]) == 4 and int(doc["height"]) == 4, "raw: キャンバスサイズが違う")
	check(int(doc["frame_count"]) == 2, "raw: フレーム数が違う")
	check((doc["layers"] as Array).size() == 1, "raw: レイヤー数が違う")
	check(String((doc["layers"] as Array)[0]["name"]) == "Layer 1", "raw: レイヤー名が違う")

	var durations: Array = TKAsepriteFile.get_frame_durations(doc)
	check(durations.size() == 2 and int(durations[0]) == 100 and int(durations[1]) == 250, "raw: 表示時間が違う")

	var images: Array = TKAsepriteFile.build_frame_images(doc)
	check(images.size() == 2, "raw: 合成画像の枚数が違う")
	if images.size() < 2:
		return
	var frame0: Image = images[0]
	check(frame0.get_width() == 4 and frame0.get_height() == 4, "raw: 合成画像のサイズが違う")
	check_color(frame0.get_pixel(1, 1), Color(1.0, 0.0, 0.0, 1.0), "raw: セル内の画素が赤でない")
	check_color(frame0.get_pixel(2, 2), Color(1.0, 0.0, 0.0, 1.0), "raw: セル右下の画素が赤でない")
	check(frame0.get_pixel(0, 0).a == 0.0, "raw: セル外が透明でない")
	check_color((images[1] as Image).get_pixel(0, 0), Color(0.0, 1.0, 0.0, 1.0), "raw: フレーム1が緑でない")
# [test_rgba_raw_cel]END


# [test_compressed_cel]
# 処理内容: zlib 形式の圧縮セルが展開できることを検証します。
#           Godot の COMPRESSION_DEFLATE は raw deflate を期待するため、
#           zlib ヘッダ剥がしが実装されていないとここで失敗します。
# 戻り値: なし
func test_compressed_cel() -> void:
	var path: String = WORK_DIR + "/compressed.aseprite"
	var layer: PackedByteArray = make_chunk(0x2004, make_layer_body(true, 0, 0, 255, "Layer 1"))
	var pixels: PackedByteArray = make_rgba_pixels(16, Color(0.0, 0.0, 1.0, 1.0))
	var cel: PackedByteArray = make_cel_compressed(0, 0, 0, 255, 4, 4, pixels)

	var bytes: PackedByteArray = make_header(1, 4, 4, 32, 0)
	bytes.append_array(make_frame(50, [layer, cel]))
	write_ase(path, bytes)

	var doc: Dictionary = TKAsepriteFile.load_file(path)
	check(not doc.is_empty(), "compressed: 解析に失敗した")
	if doc.is_empty():
		return
	var images: Array = TKAsepriteFile.build_frame_images(doc)
	check(images.size() == 1, "compressed: 合成画像の枚数が違う")
	if images.is_empty():
		return
	check_color((images[0] as Image).get_pixel(0, 0), Color(0.0, 0.0, 1.0, 1.0), "compressed: 展開結果が青でない")
	check_color((images[0] as Image).get_pixel(3, 3), Color(0.0, 0.0, 1.0, 1.0), "compressed: 展開結果の末尾が青でない")
# [test_compressed_cel]END


# [test_indexed_and_palette]
# 処理内容: インデックスカラーとパレット展開、透明色番号の扱いを検証します。
# 戻り値: なし
func test_indexed_and_palette() -> void:
	var path: String = WORK_DIR + "/indexed.aseprite"
	var palette: PackedByteArray = make_palette_chunk([
		Color(0.0, 0.0, 0.0, 1.0),
		Color(1.0, 0.0, 0.0, 1.0),
		Color(0.0, 1.0, 0.0, 1.0)
	])
	var layer: PackedByteArray = make_chunk(0x2004, make_layer_body(true, 0, 0, 255, "Layer 1"))
	var pixels := PackedByteArray([0, 1, 2, 1])
	var cel: PackedByteArray = make_cel_raw(0, 0, 0, 255, 2, 2, pixels)

	var bytes: PackedByteArray = make_header(1, 2, 2, 8, 0)
	bytes.append_array(make_frame(100, [palette, layer, cel]))
	write_ase(path, bytes)

	var doc: Dictionary = TKAsepriteFile.load_file(path)
	check(not doc.is_empty(), "indexed: 解析に失敗した")
	if doc.is_empty():
		return
	check((doc["palette"] as PackedColorArray).size() == 3, "indexed: パレット数が違う")

	var images: Array = TKAsepriteFile.build_frame_images(doc)
	if images.is_empty():
		check(false, "indexed: 合成画像が無い")
		return
	var frame: Image = images[0]
	check(frame.get_pixel(0, 0).a == 0.0, "indexed: 透明色番号が透明になっていない")
	check_color(frame.get_pixel(1, 0), Color(1.0, 0.0, 0.0, 1.0), "indexed: 番号1が赤でない")
	check_color(frame.get_pixel(0, 1), Color(0.0, 1.0, 0.0, 1.0), "indexed: 番号2が緑でない")
	check_color(frame.get_pixel(1, 1), Color(1.0, 0.0, 0.0, 1.0), "indexed: 番号1（2つ目）が赤でない")
# [test_indexed_and_palette]END


# [test_grayscale]
# 処理内容: グレースケール(16bpp)が R=G=B へ展開され、アルファが保たれることを検証します。
# 戻り値: なし
func test_grayscale() -> void:
	var path: String = WORK_DIR + "/gray.aseprite"
	var layer: PackedByteArray = make_chunk(0x2004, make_layer_body(true, 0, 0, 255, "Layer 1"))
	var pixels := PackedByteArray([200, 255, 100, 128])
	var cel: PackedByteArray = make_cel_raw(0, 0, 0, 255, 2, 1, pixels)

	var bytes: PackedByteArray = make_header(1, 2, 1, 16, 0)
	bytes.append_array(make_frame(100, [layer, cel]))
	write_ase(path, bytes)

	var doc: Dictionary = TKAsepriteFile.load_file(path)
	check(not doc.is_empty(), "gray: 解析に失敗した")
	if doc.is_empty():
		return
	var images: Array = TKAsepriteFile.build_frame_images(doc)
	if images.is_empty():
		check(false, "gray: 合成画像が無い")
		return
	var frame: Image = images[0]
	var level: float = 200.0 / 255.0
	check_color(frame.get_pixel(0, 0), Color(level, level, level, 1.0), "gray: 不透明画素の展開が違う")
	var second: Color = frame.get_pixel(1, 0)
	check(absf(second.a - 128.0 / 255.0) <= COLOR_EPSILON, "gray: 半透明画素のアルファが違う")
	check(absf(second.r - second.g) <= COLOR_EPSILON and absf(second.g - second.b) <= COLOR_EPSILON, "gray: R=G=B になっていない")
# [test_grayscale]END


# [test_two_layers_composite]
# 処理内容: 複数レイヤーの重ね順と、不可視レイヤーが合成されないことを検証します。
# 戻り値: なし
func test_two_layers_composite() -> void:
	var path: String = WORK_DIR + "/layers.aseprite"
	var layer0: PackedByteArray = make_chunk(0x2004, make_layer_body(true, 0, 0, 255, "Bottom"))
	var layer1: PackedByteArray = make_chunk(0x2004, make_layer_body(true, 0, 0, 255, "Top"))
	var layer2: PackedByteArray = make_chunk(0x2004, make_layer_body(false, 0, 0, 255, "Hidden"))

	var cel0: PackedByteArray = make_cel_raw(0, 0, 0, 255, 2, 2, make_rgba_pixels(4, Color(1.0, 0.0, 0.0, 1.0)))
	var cel1: PackedByteArray = make_cel_raw(1, 0, 0, 255, 1, 1, make_rgba_pixels(1, Color(0.0, 1.0, 0.0, 1.0)))
	var cel2: PackedByteArray = make_cel_raw(2, 0, 0, 255, 2, 2, make_rgba_pixels(4, Color(0.0, 0.0, 1.0, 1.0)))

	var bytes: PackedByteArray = make_header(1, 2, 2, 32, 0)
	bytes.append_array(make_frame(100, [layer0, layer1, layer2, cel0, cel1, cel2]))
	write_ase(path, bytes)

	var doc: Dictionary = TKAsepriteFile.load_file(path)
	check(not doc.is_empty(), "layers: 解析に失敗した")
	if doc.is_empty():
		return
	check((doc["layers"] as Array).size() == 3, "layers: レイヤー数が違う")

	var images: Array = TKAsepriteFile.build_frame_images(doc)
	if images.is_empty():
		check(false, "layers: 合成画像が無い")
		return
	var frame: Image = images[0]
	check_color(frame.get_pixel(0, 0), Color(0.0, 1.0, 0.0, 1.0), "layers: 上のレイヤーが優先されていない")
	check_color(frame.get_pixel(1, 0), Color(1.0, 0.0, 0.0, 1.0), "layers: 下のレイヤーが残っていない")
	check_color(frame.get_pixel(1, 1), Color(1.0, 0.0, 0.0, 1.0), "layers: 不可視レイヤーが合成されている")
# [test_two_layers_composite]END


# [test_layer_opacity]
# 処理内容: レイヤー不透明度による半透明合成の結果を検証します。
# 戻り値: なし
func test_layer_opacity() -> void:
	var path: String = WORK_DIR + "/opacity.aseprite"
	var layer0: PackedByteArray = make_chunk(0x2004, make_layer_body(true, 0, 0, 255, "Bottom"))
	var layer1: PackedByteArray = make_chunk(0x2004, make_layer_body(true, 0, 0, 128, "Top"))
	var cel0: PackedByteArray = make_cel_raw(0, 0, 0, 255, 1, 1, make_rgba_pixels(1, Color(1.0, 0.0, 0.0, 1.0)))
	var cel1: PackedByteArray = make_cel_raw(1, 0, 0, 255, 1, 1, make_rgba_pixels(1, Color(0.0, 1.0, 0.0, 1.0)))

	var bytes: PackedByteArray = make_header(1, 1, 1, 32, 0)
	bytes.append_array(make_frame(100, [layer0, layer1, cel0, cel1]))
	write_ase(path, bytes)

	var doc: Dictionary = TKAsepriteFile.load_file(path)
	check(not doc.is_empty(), "opacity: 解析に失敗した")
	if doc.is_empty():
		return
	check(int((doc["layers"] as Array)[1]["opacity"]) == 128, "opacity: レイヤー不透明度が読めていない")

	var images: Array = TKAsepriteFile.build_frame_images(doc)
	if images.is_empty():
		check(false, "opacity: 合成画像が無い")
		return
	var source_alpha: float = 128.0 / 255.0
	var expected := Color(1.0 - source_alpha, source_alpha, 0.0, 1.0)
	check_color((images[0] as Image).get_pixel(0, 0), expected, "opacity: 半透明合成の結果が違う")
# [test_layer_opacity]END


# [test_linked_cel]
# 処理内容: リンクセル(種別1)がリンク先の画像を再利用することを検証します。
# 戻り値: なし
func test_linked_cel() -> void:
	var path: String = WORK_DIR + "/linked.aseprite"
	var layer: PackedByteArray = make_chunk(0x2004, make_layer_body(true, 0, 0, 255, "Layer 1"))
	var cel0: PackedByteArray = make_cel_raw(0, 1, 0, 255, 1, 1, make_rgba_pixels(1, Color(1.0, 1.0, 0.0, 1.0)))
	var cel1: PackedByteArray = make_cel_linked(0, 1, 0, 255, 0)

	var bytes: PackedByteArray = make_header(2, 2, 2, 32, 0)
	bytes.append_array(make_frame(100, [layer, cel0]))
	bytes.append_array(make_frame(100, [cel1]))
	write_ase(path, bytes)

	var doc: Dictionary = TKAsepriteFile.load_file(path)
	check(not doc.is_empty(), "linked: 解析に失敗した")
	if doc.is_empty():
		return
	var images: Array = TKAsepriteFile.build_frame_images(doc)
	check(images.size() == 2, "linked: 合成画像の枚数が違う")
	if images.size() < 2:
		return
	check_color((images[1] as Image).get_pixel(1, 0), Color(1.0, 1.0, 0.0, 1.0), "linked: リンク先の画素が再利用されていない")
	check((images[1] as Image).get_pixel(0, 0).a == 0.0, "linked: リンクセルの位置がずれている")
# [test_linked_cel]END


# [test_negative_cel_position]
# 処理内容: 負座標セルとキャンバスからはみ出すセルで、交差部分だけが描かれることを検証します。
# 戻り値: なし
func test_negative_cel_position() -> void:
	var path: String = WORK_DIR + "/clip.aseprite"
	var layer0: PackedByteArray = make_chunk(0x2004, make_layer_body(true, 0, 0, 255, "Neg"))
	var layer1: PackedByteArray = make_chunk(0x2004, make_layer_body(true, 0, 0, 255, "Over"))
	var cel0: PackedByteArray = make_cel_raw(0, -2, -2, 255, 4, 4, make_rgba_pixels(16, Color(1.0, 0.0, 0.0, 1.0)))
	var cel1: PackedByteArray = make_cel_raw(1, 3, 3, 255, 4, 4, make_rgba_pixels(16, Color(0.0, 0.0, 1.0, 1.0)))

	var bytes: PackedByteArray = make_header(1, 4, 4, 32, 0)
	bytes.append_array(make_frame(100, [layer0, layer1, cel0, cel1]))
	write_ase(path, bytes)

	var doc: Dictionary = TKAsepriteFile.load_file(path)
	check(not doc.is_empty(), "clip: 解析に失敗した")
	if doc.is_empty():
		return
	check(int((doc["frames"] as Array)[0]["cels"][0]["x"]) == -2, "clip: 負のセル座標が読めていない")

	var images: Array = TKAsepriteFile.build_frame_images(doc)
	if images.is_empty():
		check(false, "clip: 合成画像が無い")
		return
	var frame: Image = images[0]
	check_color(frame.get_pixel(0, 0), Color(1.0, 0.0, 0.0, 1.0), "clip: 負座標セルの交差部が描かれていない")
	check_color(frame.get_pixel(1, 1), Color(1.0, 0.0, 0.0, 1.0), "clip: 負座標セルの右下端が描かれていない")
	check(frame.get_pixel(2, 2).a == 0.0, "clip: 負座標セルがはみ出して描かれている")
	check_color(frame.get_pixel(3, 3), Color(0.0, 0.0, 1.0, 1.0), "clip: はみ出しセルの交差部が描かれていない")
# [test_negative_cel_position]END


# [test_tags_and_pivot]
# 処理内容: タグチャンクとスライスチャンクの pivot が読めることを検証します。
# 戻り値: なし
func test_tags_and_pivot() -> void:
	var path: String = WORK_DIR + "/tags.aseprite"
	var layer: PackedByteArray = make_chunk(0x2004, make_layer_body(true, 0, 0, 255, "Layer 1"))
	var tags: PackedByteArray = make_tags_chunk([
		{ "name": "WALK", "from": 0, "to": 1, "direction": 0 },
		{ "name": "JUMP", "from": 2, "to": 2, "direction": 1 }
	])
	var slice: PackedByteArray = make_slice_chunk("pivot", 4, 6)
	var cel: PackedByteArray = make_cel_raw(0, 0, 0, 255, 1, 1, make_rgba_pixels(1, Color(1.0, 1.0, 1.0, 1.0)))

	var bytes: PackedByteArray = make_header(3, 2, 2, 32, 0)
	bytes.append_array(make_frame(100, [layer, tags, slice, cel]))
	bytes.append_array(make_frame(100, [cel]))
	bytes.append_array(make_frame(100, [cel]))
	write_ase(path, bytes)

	var doc: Dictionary = TKAsepriteFile.load_file(path)
	check(not doc.is_empty(), "tags: 解析に失敗した")
	if doc.is_empty():
		return
	var doc_tags: Array = doc["tags"]
	check(doc_tags.size() == 2, "tags: タグ数が違う")
	if doc_tags.size() == 2:
		check(String(doc_tags[0]["name"]) == "WALK" and int(doc_tags[0]["from"]) == 0 and int(doc_tags[0]["to"]) == 1, "tags: 1つ目のタグが違う")
		check(String(doc_tags[1]["name"]) == "JUMP" and int(doc_tags[1]["from"]) == 2 and int(doc_tags[1]["direction"]) == 1, "tags: 2つ目のタグが違う")
	var pivot: Array = doc["pivot"]
	check(pivot.size() == 2 and int(pivot[0]) == 4 and int(pivot[1]) == 6, "tags: pivot が違う")
# [test_tags_and_pivot]END


# [test_unknown_chunk_skipped]
# 処理内容: 未知チャンクを挟んでも後続のチャンクが正しく読めることを検証します。
# 戻り値: なし
func test_unknown_chunk_skipped() -> void:
	var path: String = WORK_DIR + "/unknown.aseprite"
	var layer: PackedByteArray = make_chunk(0x2004, make_layer_body(true, 0, 0, 255, "Layer 1"))
	var junk := PackedByteArray()
	junk = put_fill(junk, 37, 0xAB)
	var unknown: PackedByteArray = make_chunk(0x2007, junk)
	var cel: PackedByteArray = make_cel_raw(0, 0, 0, 255, 1, 1, make_rgba_pixels(1, Color(1.0, 0.0, 1.0, 1.0)))

	var bytes: PackedByteArray = make_header(1, 2, 2, 32, 0)
	bytes.append_array(make_frame(100, [layer, unknown, cel]))
	write_ase(path, bytes)

	var doc: Dictionary = TKAsepriteFile.load_file(path)
	check(not doc.is_empty(), "unknown: 解析に失敗した")
	if doc.is_empty():
		return
	var images: Array = TKAsepriteFile.build_frame_images(doc)
	if images.is_empty():
		check(false, "unknown: 合成画像が無い")
		return
	check_color((images[0] as Image).get_pixel(0, 0), Color(1.0, 0.0, 1.0, 1.0), "unknown: 未知チャンクの後のセルが読めていない")
# [test_unknown_chunk_skipped]END


# [test_broken_file_returns_empty]
# 処理内容: 壊れたファイルでクラッシュせず空 Dictionary が返ることを検証します。
# 戻り値: なし
func test_broken_file_returns_empty() -> void:
	var bad_magic_path: String = WORK_DIR + "/bad_magic.aseprite"
	var bad: PackedByteArray = make_header(1, 2, 2, 32, 0)
	bad[4] = 0x00
	bad[5] = 0x00
	write_ase(bad_magic_path, bad)
	check(TKAsepriteFile.load_file(bad_magic_path).is_empty(), "broken: 識別値不正が空にならない")

	var truncated_path: String = WORK_DIR + "/truncated.aseprite"
	var full: PackedByteArray = make_header(2, 2, 2, 32, 0)
	full.append_array(make_frame(100, [make_chunk(0x2004, make_layer_body(true, 0, 0, 255, "L"))]))
	write_ase(truncated_path, full.slice(0, full.size() - 4))
	check(TKAsepriteFile.load_file(truncated_path).is_empty(), "broken: 途中で切れたファイルが空にならない")

	var missing: Dictionary = TKAsepriteFile.load_file(WORK_DIR + "/does_not_exist.aseprite")
	check(missing.is_empty(), "broken: 存在しないファイルが空にならない")
# [test_broken_file_returns_empty]END


# [test_import_aseprite_roundtrip]
# 処理内容: 経路B の入口 import_aseprite() が定義JSONを組み立てられることを検証します。
# 戻り値: なし
func test_import_aseprite_roundtrip() -> void:
	var path: String = WORK_DIR + "/import.aseprite"
	var png_path: String = WORK_DIR + "/import_sheet.png"
	var layer: PackedByteArray = make_chunk(0x2004, make_layer_body(true, 0, 0, 255, "Layer 1"))
	var tags: PackedByteArray = make_tags_chunk([{ "name": "WALK", "from": 0, "to": 1, "direction": 0 }])
	var cel0: PackedByteArray = make_cel_raw(0, 0, 0, 255, 2, 2, make_rgba_pixels(4, Color(1.0, 0.0, 0.0, 1.0)))
	var cel1: PackedByteArray = make_cel_raw(0, 0, 0, 255, 2, 2, make_rgba_pixels(4, Color(0.0, 1.0, 0.0, 1.0)))

	var bytes: PackedByteArray = make_header(2, 2, 2, 32, 0)
	bytes.append_array(make_frame(120, [layer, tags, cel0]))
	bytes.append_array(make_frame(180, [cel1]))
	write_ase(path, bytes)

	var defs: Dictionary = TKAsepriteImporter.import_aseprite(path, png_path, {}, false, "HERO", "main")
	check(not defs.is_empty(), "import: 取り込みに失敗した")
	if defs.is_empty():
		return

	var sprites: Array = defs["sprites"]
	check(sprites.size() == 1, "import: スプライト数が違う")
	if sprites.is_empty():
		return
	var sprite: Dictionary = sprites[0]
	check(String(sprite["name"]) == "HERO", "import: スプライト名が違う")
	check(String(sprite["atlas"]) == "main", "import: アトラス別名が違う")
	check(String(sprite["layout"]) == TKSpriteDefinitions.LAYOUT_FRAMES, "import: layout が frames でない")

	var frames: Array = sprite["frames"]
	check(frames.size() == 2, "import: フレーム数が違う")
	if frames.size() == 2:
		check(int(frames[0][0]) == 0 and int(frames[0][2]) == 2 and int(frames[0][3]) == 2, "import: 1枚目の矩形が違う")
		check(int(frames[1][0]) == 2 and int(frames[1][1]) == 0, "import: 2枚目が横一列に並んでいない")
	var durations: Array = sprite["durations"]
	check(durations.size() == 2 and int(durations[0]) == 120 and int(durations[1]) == 180, "import: 表示時間が違う")
	check((sprite["tags"] as Dictionary).has("WALK"), "import: タグが取り込まれていない")

	check(FileAccess.file_exists(png_path), "import: シートPNGが書き出されていない")
	var sheet := Image.new()
	check(sheet.load(png_path) == OK, "import: シートPNGが読めない")
	check(sheet.get_width() == 4 and sheet.get_height() == 2, "import: シートPNGの大きさが違う")
	check_color(sheet.get_pixel(0, 0), Color(1.0, 0.0, 0.0, 1.0), "import: シート左半分が赤でない")
	check_color(sheet.get_pixel(2, 0), Color(0.0, 1.0, 0.0, 1.0), "import: シート右半分が緑でない")
# [test_import_aseprite_roundtrip]END


# [test_id_stability_on_reimport]
# 処理内容: 同じ .aseprite を2回取り込んでも id が変わらないことを検証します。
# 戻り値: なし
func test_id_stability_on_reimport() -> void:
	var path: String = WORK_DIR + "/import.aseprite"
	var png_path: String = WORK_DIR + "/import_sheet.png"

	var existing: Dictionary = {
		"version": 2,
		"atlases": { "main": "res://dummy.png" },
		"sprites": [
			{ "id": 5, "name": "OTHER", "atlas": "main", "layout": TKSpriteDefinitions.LAYOUT_FRAMES, "frames": [[0, 0, 1, 1]] },
			{ "id": 9, "name": "HERO", "atlas": "main", "layout": TKSpriteDefinitions.LAYOUT_FRAMES, "frames": [[0, 0, 1, 1]], "draw_size": [16, 16] }
		]
	}

	var first: Dictionary = TKAsepriteImporter.import_aseprite(path, png_path, existing, false, "HERO", "main")
	check(not first.is_empty(), "stability: 1回目の取り込みに失敗した")
	if first.is_empty():
		return
	var first_id: int = find_sprite_id(first, "HERO")
	check(first_id == 9, "stability: 既存IDが維持されていない（%d）" % first_id)
	check(find_sprite_draw_size(first, "HERO").size() == 2, "stability: 手編集の draw_size が失われている")

	var second: Dictionary = TKAsepriteImporter.import_aseprite(path, png_path, first, false, "HERO", "main")
	check(find_sprite_id(second, "HERO") == 9, "stability: 2回目でIDが変わった")
	check((second["sprites"] as Array).size() == 2, "stability: 2回目でスプライトが増えた")
# [test_id_stability_on_reimport]END


# [test_end_to_end_registration]
# 処理内容: .aseprite を直接読み込んで定義ファイルとシートPNGを作り、そのままサーバーへ
#           登録できるところまでを通しで検証します。Aseprite 本体が無くても素材を
#           使えることの証明です。
# 戻り値: なし
func test_end_to_end_registration() -> void:
	var ase_path: String = WORK_DIR + "/e2e.aseprite"
	var png_path: String = WORK_DIR + "/e2e_sheet.png"
	var defs_path: String = WORK_DIR + "/e2e_defs.json"

	var layer: PackedByteArray = make_chunk(0x2004, make_layer_body(true, 0, 0, 255, "Layer 1"))
	var tags: PackedByteArray = make_tags_chunk([{ "name": "SPIN", "from": 0, "to": 1, "direction": 0 }])
	var cel0: PackedByteArray = make_cel_compressed(0, 0, 0, 255, 4, 4, make_rgba_pixels(16, Color(1.0, 0.5, 0.0, 1.0)))
	var cel1: PackedByteArray = make_cel_compressed(0, 0, 0, 255, 4, 4, make_rgba_pixels(16, Color(0.0, 0.5, 1.0, 1.0)))

	var bytes: PackedByteArray = make_header(2, 4, 4, 32, 0)
	bytes.append_array(make_frame(100, [layer, tags, cel0]))
	bytes.append_array(make_frame(100, [cel1]))
	write_ase(ase_path, bytes)

	var saved: bool = TKAsepriteImporter.import_aseprite_into_file(ase_path, png_path, defs_path, false, "E2E", "e2e")
	check(saved, "e2e: 定義ファイルの保存に失敗した")
	check(FileAccess.file_exists(defs_path), "e2e: 定義ファイルが作られていない")
	if not saved:
		return

	var server: Object = TKSpriteServer.create(16, true, true)
	check(server != null, "e2e: サーバーを作成できない")
	if server == null:
		return
	print("test_aseprite_file: e2e backend=%s" % TKSpriteServer.get_backend_name(server))

	var registered: int = TKSpriteRegistry.register_all(server, defs_path)
	check(registered == 1, "e2e: 登録数が違う（%d）" % registered)

	var defs: Dictionary = TKSpriteDefinitions.load_file(defs_path)
	var sprite_id: int = TKSpriteRegistry.get_sprite_id_by_name(defs, "E2E")
	check(sprite_id >= 0, "e2e: 登録したスプライトIDが引けない")

	var textures: Dictionary = server.sprite_textures
	check(textures.has(sprite_id), "e2e: サーバーにスプライトが登録されていない")
	if textures.has(sprite_id):
		var entry: Dictionary = textures[sprite_id]
		check(entry.has("frames"), "e2e: フレーム情報が登録されていない")
		if entry.has("frames"):
			check((entry["frames"] as Array).size() == 2, "e2e: 登録フレーム数が違う")

	server.free_all_rids()
	if server is Node:
		(server as Node).free()
# [test_end_to_end_registration]END


# [find_sprite_id]
# 処理内容: 定義から名前でスプライトIDを探します。
# 引数 defs:        定義 Dictionary です。
# 引数 sprite_name: 探す名前です。
# 戻り値: 見つかったIDです。無ければ -1 です。
func find_sprite_id(defs: Dictionary, sprite_name: String) -> int:
	for sprite_variant in (defs.get("sprites", []) as Array):
		var sprite: Dictionary = sprite_variant
		if String(sprite.get("name", "")) == sprite_name:
			return int(sprite.get("id", -1))
	return -1
# [find_sprite_id]END


# [find_sprite_draw_size]
# 処理内容: 定義から名前で draw_size を探します。
# 引数 defs:        定義 Dictionary です。
# 引数 sprite_name: 探す名前です。
# 戻り値: draw_size の配列です。無ければ空配列です。
func find_sprite_draw_size(defs: Dictionary, sprite_name: String) -> Array:
	for sprite_variant in (defs.get("sprites", []) as Array):
		var sprite: Dictionary = sprite_variant
		if String(sprite.get("name", "")) == sprite_name:
			return sprite.get("draw_size", [])
	return []
# [find_sprite_draw_size]END
