# test_definition_tool.gd — 定義エディタ（ツール本体とドック）の起動テスト
#
# 実行方法:
#   Godot --headless --path <プロジェクト> --script res://tests/test_definition_tool.gd
#
# UI 全体の操作までは検証しません。移植で壊れやすい以下の3点だけを見ます。
#   1. ドック経由でツールが起動し、定義JSONを読み込めること
#   2. エディタモードでキーボード／ゲームパッド処理が止まること
#   3. 回転プレビューが TKSpriteAtlasBuilder 経由で生成できること（旧 host 依存の置換）

extends SceneTree

const DOCK_SCRIPT = preload("res://addons/tk_sprite_server/tools/tk_sprite_definition_dock.gd")
const DEFS_PATH: String = "res://demo/devdata/sprite_definitions.json"

const IMPORT_WORK_DIR: String = "user://tk_test_import_dialog"
const IMPORT_ASE_PATH: String = "user://tk_test_import_dialog/dialog.aseprite"
const IMPORT_PNG_PATH: String = "user://tk_test_import_dialog/dialog.png"
const IMPORT_DEFS_PATH: String = "user://tk_test_import_dialog/defs.json"

var failure_count: int = 0
var _dock: Control = null
var _elapsed_frames: int = 0
var _last_import_success: bool = false
var _last_import_message: String = ""


# [_initialize]
# 処理内容: ドックを生成してツリーへ追加します。UI 構築は _ready 後に進むため、
#           検証は _process で数フレーム待ってから行います。
# 戻り値: なし
func _initialize() -> void:
	_dock = DOCK_SCRIPT.new()
	root.add_child(_dock)
# [_initialize]END


# [_process]
# 処理内容: 数フレーム待ってから検証を行い、終了します。
# 引数 delta: 経過秒です。
# 戻り値: true を返すとメインループが終了します。
func _process(delta: float) -> bool:
	_elapsed_frames += 1
	if _elapsed_frames < 3:
		return false

	run_checks()
	run_import_checks()

	if failure_count == 0:
		print("test_definition_tool: ALL PASS")
	else:
		print("test_definition_tool: FAILED %d" % failure_count)
		quit(1)
		return true
	quit(0)
	return true
# [_process]END


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


# [run_checks]
# 処理内容: ドックとツール本体の状態を検証します。
# 戻り値: なし
func run_checks() -> void:
	var tool_instance: Control = _dock.get_tool_instance()
	check(tool_instance != null, "ドックがツール本体を生成していない")
	if tool_instance == null:
		return

	check(bool(tool_instance.editor_mode), "editor_mode が立っていない")
	check(String(tool_instance.defs_path) == DEFS_PATH, "defs_path が渡っていない: " + String(tool_instance.defs_path))

	var defs: Dictionary = tool_instance.defs
	check(not defs.is_empty(), "定義が読み込まれていない")
	var sprites: Array = defs.get("sprites", [])
	check(sprites.size() == 5, "読み込まれたスプライト数が 5 でない: %d" % sprites.size())

	# エディタモードではゲームパッド処理を行いません（_process が即 return します）。
	tool_instance._process(0.016)

	# 回転プレビューの生成です。rotated の ARROW（roughness=3 なので 32 枚）を選びます。
	var arrow_index: int = -1
	for index in range(sprites.size()):
		if String(sprites[index].get("layout", "")) == "rotated":
			arrow_index = index
	check(arrow_index >= 0, "rotated の定義が見つからない")
	if arrow_index < 0:
		return

	tool_instance.current_index = arrow_index
	tool_instance.rotation_preview_texture = null
	tool_instance.ensure_rotation_preview()
	check(tool_instance.rotation_preview_texture != null, "回転プレビューが生成されていない")
	check((tool_instance.rotation_preview_frames as Array).size() == 32, "回転プレビューの枚数が 32 でない: %d" % (tool_instance.rotation_preview_frames as Array).size())
# [run_checks]END


# [run_import_checks]
# 処理内容: 「Aseprite から取り込み」ボタンとダイアログを検証します。
#           リポジトリ内の定義ファイルは書き換えず、作業はすべて user:// で行います。
# 戻り値: なし
func run_import_checks() -> void:
	# 1. ツールバーにボタンがあること。
	check(_find_button_by_text(_dock, _dock.IMPORT_BUTTON_TEXT) != null, "取り込みボタンが見つからない")

	var dialog = _dock._import_dialog
	check(dialog != null, "取り込みダイアログが生成されていない")
	if dialog == null:
		return

	# 2. 拡張子から経路が決まること。
	check(dialog.detect_route("res://a.aseprite") == dialog.ROUTE_ASEPRITE, "経路判定: .aseprite が誤り")
	check(dialog.detect_route("res://a.ASE") == dialog.ROUTE_ASEPRITE, "経路判定: .ASE が誤り")
	check(dialog.detect_route("res://a.json") == dialog.ROUTE_JSON, "経路判定: .json が誤り")
	check(dialog.detect_route("res://a.png") == dialog.ROUTE_UNKNOWN, "経路判定: .png が誤り")

	dialog.import_finished.connect(_on_import_finished)

	# 3. 元ファイル未指定なら失敗し、理由が通知されること。
	DirAccess.make_dir_recursive_absolute(IMPORT_WORK_DIR)
	dialog.defs_path = IMPORT_DEFS_PATH
	dialog.configure("", "", "", "", false)
	_last_import_success = true
	check(dialog.run_import() == false, "元ファイル未指定なのに成功した")
	check(_last_import_success == false, "失敗が import_finished で通知されていない")
	check(not _last_import_message.is_empty(), "失敗理由が空")

	# 4. 実際の .aseprite を取り込めること。
	_write_sample_ase(IMPORT_ASE_PATH)
	dialog.configure(IMPORT_ASE_PATH, IMPORT_PNG_PATH, "DIALOG_HERO", "dialog", false)
	check(dialog.run_import() == true, "取り込みに失敗した: " + _last_import_message)
	check(FileAccess.file_exists(IMPORT_DEFS_PATH), "定義ファイルが作られていない")

	var defs: Dictionary = TKSpriteDefinitions.load_file(IMPORT_DEFS_PATH)
	var sprite_id: int = TKSpriteRegistry.get_sprite_id_by_name(defs, "DIALOG_HERO")
	check(sprite_id >= 0, "取り込んだスプライトが定義に無い")
	check((defs.get("sprites", []) as Array).size() == 1, "スプライト数が 1 でない")

	# 5. 2回目でも id が変わらないこと（GUI 経由でも再インポート契約が効くこと）。
	check(dialog.run_import() == true, "2回目の取り込みに失敗した")
	var defs_again: Dictionary = TKSpriteDefinitions.load_file(IMPORT_DEFS_PATH)
	check(TKSpriteRegistry.get_sprite_id_by_name(defs_again, "DIALOG_HERO") == sprite_id, "再取り込みで id が変わった")
	check((defs_again.get("sprites", []) as Array).size() == 1, "再取り込みでスプライトが増えた")
# [run_import_checks]END


# [_on_import_finished]
# 処理内容: ダイアログからの通知を記録します。
# 引数 success: 成否です。
# 引数 message: 内容です。
# 戻り値: なし
func _on_import_finished(success: bool, message: String) -> void:
	_last_import_success = success
	_last_import_message = message
# [_on_import_finished]END


# [_find_button_by_text]
# 処理内容: ノード木から指定した文言のボタンを探します。
# 引数 node: 探索の起点です。
# 引数 text: 探すボタンの文言です。
# 戻り値: 見つかった Button。無ければ null です。
func _find_button_by_text(node: Node, text: String) -> Button:
	for child in node.get_children():
		if child is Button and (child as Button).text == text:
			return child as Button
		var found: Button = _find_button_by_text(child, text)
		if found != null:
			return found
	return null
# [_find_button_by_text]END


# [_write_sample_ase]
# 処理内容: 検証用の .aseprite を組み立てて書き出します。このマシンには .aseprite が
#           存在せず Aseprite も未インストールのため、テスト自身が作ります。
#           1レイヤー・2フレーム・4x4・32bpp の最小構成です。
# 引数 path: 書き出し先です。
# 戻り値: なし
func _write_sample_ase(path: String) -> void:
	var layer := PackedByteArray()
	layer = _u16(layer, 1)
	layer = _u16(layer, 0)
	layer = _u16(layer, 0)
	layer = _u16(layer, 0)
	layer = _u16(layer, 0)
	layer = _u16(layer, 0)
	layer.append(255)
	layer = _fill(layer, 3, 0)
	layer = _u16(layer, 7)
	layer.append_array("Layer 1".to_utf8_buffer())

	var bytes: PackedByteArray = _ase_header(2, 4, 4)
	bytes.append_array(_ase_frame(100, [_chunk(0x2004, layer), _cel(Color(1.0, 0.0, 0.0, 1.0))]))
	bytes.append_array(_ase_frame(100, [_cel(Color(0.0, 1.0, 0.0, 1.0))]))

	var file := FileAccess.open(path, FileAccess.WRITE)
	check(file != null, "検証用 .aseprite を書けない: " + path)
	if file == null:
		return
	file.store_buffer(bytes)
	file.close()
# [_write_sample_ase]END


# [_ase_header]
# 処理内容: 128 バイトの ASE ファイルヘッダを作ります。
# 引数 frame_count: フレーム数です。
# 引数 width:       幅です。
# 引数 height:      高さです。
# 戻り値: ヘッダのバイト列です。
func _ase_header(frame_count: int, width: int, height: int) -> PackedByteArray:
	var buf := PackedByteArray()
	buf = _u32(buf, 0)
	buf = _u16(buf, 0xA5E0)
	buf = _u16(buf, frame_count)
	buf = _u16(buf, width)
	buf = _u16(buf, height)
	buf = _u16(buf, 32)
	buf = _u32(buf, 1)
	buf = _u16(buf, 100)
	buf = _u32(buf, 0)
	buf = _u32(buf, 0)
	buf = _fill(buf, 4, 0)
	buf = _u16(buf, 0)
	buf = _fill(buf, 2, 1)
	buf = _fill(buf, 8, 0)
	buf = _fill(buf, 84, 0)
	return buf
# [_ase_header]END


# [_ase_frame]
# 処理内容: フレームヘッダを付けた 1 フレームぶんのバイト列を作ります。
# 引数 duration: 表示時間です。
# 引数 chunks:   チャンクの配列です。
# 戻り値: フレームのバイト列です。
func _ase_frame(duration: int, chunks: Array) -> PackedByteArray:
	var body := PackedByteArray()
	for chunk in chunks:
		body.append_array(chunk)
	var buf := PackedByteArray()
	buf = _u32(buf, body.size() + 16)
	buf = _u16(buf, 0xF1FA)
	buf = _u16(buf, 0xFFFF)
	buf = _u16(buf, duration)
	buf = _fill(buf, 2, 0)
	buf = _u32(buf, chunks.size())
	buf.append_array(body)
	return buf
# [_ase_frame]END


# [_chunk]
# 処理内容: チャンクヘッダを付けます。
# 引数 chunk_type: 種別です。
# 引数 body:       本体です。
# 戻り値: チャンクのバイト列です。
func _chunk(chunk_type: int, body: PackedByteArray) -> PackedByteArray:
	var buf := PackedByteArray()
	buf = _u32(buf, body.size() + 6)
	buf = _u16(buf, chunk_type)
	buf.append_array(body)
	return buf
# [_chunk]END


# [_cel]
# 処理内容: 4x4 の単色生画素セルチャンクを作ります。
# 引数 color: 塗る色です。
# 戻り値: チャンクのバイト列です。
func _cel(color: Color) -> PackedByteArray:
	var body := PackedByteArray()
	body = _u16(body, 0)
	body = _u16(body, 0)
	body = _u16(body, 0)
	body.append(255)
	body = _u16(body, 0)
	body = _u16(body, 0)
	body = _fill(body, 5, 0)
	body = _u16(body, 4)
	body = _u16(body, 4)
	for index in range(16):
		body.append(int(round(color.r * 255.0)))
		body.append(int(round(color.g * 255.0)))
		body.append(int(round(color.b * 255.0)))
		body.append(255)
	return _chunk(0x2005, body)
# [_cel]END


# [_u16]
# 処理内容: リトルエンディアンで 2 バイト追加します。
# 引数 buf:   追加先です。
# 引数 value: 値です。
# 戻り値: 追加後の配列です。
func _u16(buf: PackedByteArray, value: int) -> PackedByteArray:
	buf.append(value & 0xFF)
	buf.append((value >> 8) & 0xFF)
	return buf
# [_u16]END


# [_u32]
# 処理内容: リトルエンディアンで 4 バイト追加します。
# 引数 buf:   追加先です。
# 引数 value: 値です。
# 戻り値: 追加後の配列です。
func _u32(buf: PackedByteArray, value: int) -> PackedByteArray:
	buf.append(value & 0xFF)
	buf.append((value >> 8) & 0xFF)
	buf.append((value >> 16) & 0xFF)
	buf.append((value >> 24) & 0xFF)
	return buf
# [_u32]END


# [_fill]
# 処理内容: 同じ値を指定個数ぶん追加します。
# 引数 buf:   追加先です。
# 引数 count: 個数です。
# 引数 value: 値です。
# 戻り値: 追加後の配列です。
func _fill(buf: PackedByteArray, count: int, value: int) -> PackedByteArray:
	for index in range(count):
		buf.append(value & 0xFF)
	return buf
# [_fill]END
