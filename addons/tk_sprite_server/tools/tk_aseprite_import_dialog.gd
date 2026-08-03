@tool
extends ConfirmationDialog

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  tk_aseprite_import_dialog.gd — Aseprite 取り込み設定ダイアログ           ║
# ╠═══════════════════════════════════════════════════════════════════════════╣
# ║  設計書 §8.4                                                               ║
# ║                                                                            ║
# ║  【役割】                                                                  ║
# ║  ・定義エディタから経路A（書き出しJSON）と経路B（.aseprite 直読み）を      ║
# ║    呼び出すための入力欄をまとめます。                                      ║
# ║  ・経路は元ファイルの拡張子から自動で決まります。利用者は選びません。      ║
# ║                                                                            ║
# ║  【ドックから分離してある理由】                                            ║
# ║  ・エディタを起動しなくても、new() して run_import() を直接呼べば          ║
# ║    ヘッドレスで取り込み処理そのものを検証できるためです。                  ║
# ║                                                                            ║
# ║  【メモリ規則】エディタ操作時にのみ使用します。毎フレーム呼んではいけません。║
# ╚═══════════════════════════════════════════════════════════════════════════╝

class_name TKAsepriteImportDialog

# 取り込みが終わったことを伝えます。失敗時も必ず出します。
signal import_finished(success: bool, message: String)

# 元ファイルの種別です。
enum { ROUTE_UNKNOWN, ROUTE_ASEPRITE, ROUTE_JSON }

# マージ先の定義JSONのパスです。ドックが表示中のパスを入れます。
var defs_path: String = ""

var _source_edit: LineEdit = null
var _sheet_edit: LineEdit = null
var _name_edit: LineEdit = null
var _alias_edit: LineEdit = null
var _split_check: CheckBox = null
var _hint_label: Label = null
var _file_dialog: FileDialog = null


# [_ready]
# 処理内容: 入力欄を組み立てます。
# 戻り値: なし
func _ready() -> void:
	title = "Aseprite から取り込み"
	ok_button_text = "取り込む"
	cancel_button_text = "やめる"

	var layout := VBoxContainer.new()
	layout.custom_minimum_size = Vector2(520.0, 0.0)
	add_child(layout)

	var grid := GridContainer.new()
	grid.columns = 3
	layout.add_child(grid)

	_source_edit = _add_row(grid, "元ファイル:", true)
	_sheet_edit = _add_row(grid, "シートPNG:", false)
	_name_edit = _add_row(grid, "スプライト名:", false)
	_alias_edit = _add_row(grid, "アトラス別名:", false)

	grid.add_child(Label.new())
	_split_check = CheckBox.new()
	_split_check.text = "タグごとに別スプライトへ分割する"
	grid.add_child(_split_check)
	grid.add_child(Control.new())

	_hint_label = Label.new()
	_hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint_label.text = "拡張子で経路が決まります。.aseprite / .ase は直読み、.json は書き出しの取り込みです。"
	layout.add_child(_hint_label)

	_source_edit.text_changed.connect(_on_source_changed)
	confirmed.connect(_on_confirmed)
	_update_sheet_field()
	return  # end of function
# [_ready]END


# [_add_row]
# 処理内容: ラベルと入力欄の1行を作ります。参照ボタンが要る行だけボタンも足します。
# 引数 grid:        追加先のグリッドです。
# 引数 label_text:  行の見出しです。
# 引数 with_browse: true なら「参照」ボタンを付けます。
# 戻り値: 作った LineEdit です。
func _add_row(grid: GridContainer, label_text: String, with_browse: bool) -> LineEdit:
	var label := Label.new()
	label.text = label_text
	grid.add_child(label)

	var edit := LineEdit.new()
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.custom_minimum_size = Vector2(320.0, 0.0)
	grid.add_child(edit)

	if with_browse:
		var browse := Button.new()
		browse.text = "参照"
		browse.pressed.connect(_on_browse_pressed)
		grid.add_child(browse)
	else:
		grid.add_child(Control.new())
	return edit
# [_add_row]END


# [configure]
# 処理内容: 入力欄をまとめて設定します。テストと外部からの呼び出し用です。
# 引数 source_path:     元ファイルのパスです。
# 引数 sheet_png_path:  書き出すシートPNGのパスです。空なら自動補完します。
# 引数 sprite_name:     スプライト名です。
# 引数 atlas_alias:     アトラス別名です。
# 引数 split_by_tag:    タグごとに分割するかどうかです。
# 戻り値: なし
func configure(
	source_path: String,
	sheet_png_path: String = "",
	sprite_name: String = "",
	atlas_alias: String = "",
	split_by_tag: bool = false
) -> void:
	if _source_edit == null:
		push_error("TKAsepriteImportDialog: UI がまだ組み立てられていません。")
		return
	_source_edit.text = source_path
	_name_edit.text = sprite_name
	_alias_edit.text = atlas_alias
	_split_check.button_pressed = split_by_tag
	_update_sheet_field()
	if not sheet_png_path.is_empty():
		_sheet_edit.text = sheet_png_path
	return  # end of function
# [configure]END


# [detect_route]
# 処理内容: 元ファイルの拡張子から取り込み経路を決めます。
# 引数 source_path: 元ファイルのパスです。
# 戻り値: ROUTE_ASEPRITE / ROUTE_JSON / ROUTE_UNKNOWN です。
func detect_route(source_path: String) -> int:
	var extension: String = source_path.get_extension().to_lower()
	if extension == "aseprite" or extension == "ase":
		return ROUTE_ASEPRITE
	if extension == "json":
		return ROUTE_JSON
	return ROUTE_UNKNOWN
# [detect_route]END


# [run_import]
# 処理内容: 入力内容にしたがって取り込みを実行し、結果を import_finished で伝えます。
#           失敗した場合、定義ファイルは書き換えられません。
# 戻り値: 成功時 true です。
func run_import() -> bool:
	if defs_path.is_empty():
		return _finish(false, "取り込み先の定義JSONが指定されていません。")

	var source_path: String = _source_edit.text.strip_edges() if _source_edit != null else ""
	if source_path.is_empty():
		return _finish(false, "元ファイルが指定されていません。")
	if not FileAccess.file_exists(source_path):
		return _finish(false, "元ファイルが見つかりません: " + source_path)

	var split_by_tag: bool = _split_check.button_pressed
	var sprite_name: String = _name_edit.text.strip_edges()
	var atlas_alias: String = _alias_edit.text.strip_edges()

	var route: int = detect_route(source_path)
	var succeeded: bool = false
	match route:
		ROUTE_ASEPRITE:
			var sheet_path: String = _sheet_edit.text.strip_edges()
			if sheet_path.is_empty():
				sheet_path = source_path.get_basename() + ".png"
			succeeded = TKAsepriteImporter.import_aseprite_into_file(
				source_path, sheet_path, defs_path, split_by_tag, sprite_name, atlas_alias
			)
		ROUTE_JSON:
			succeeded = TKAsepriteImporter.import_sheet_into_file(
				source_path, defs_path, split_by_tag, sprite_name, atlas_alias
			)
		_:
			return _finish(false, "対応していない拡張子です（.aseprite / .ase / .json のみ）: " + source_path)

	if not succeeded:
		return _finish(false, "取り込みに失敗しました。出力ログを確認してください: " + source_path)
	return _finish(true, "取り込みました: " + source_path.get_file())
# [run_import]END


# [_finish]
# 処理内容: 結果を通知します。失敗時は理由をエラーとしても残します。
# 引数 success: 成否です。
# 引数 message: 表示する内容です。
# 戻り値: success をそのまま返します。
func _finish(success: bool, message: String) -> bool:
	if not success:
		push_error("TKAsepriteImportDialog: " + message)
	import_finished.emit(success, message)
	return success
# [_finish]END


# [_update_sheet_field]
# 処理内容: 経路に応じてシートPNG欄の有効・無効と既定値を切り替えます。
#           経路A では使わないため無効化しますが、内容は消しません
#           （利用者が拡張子を打ち直したときに戻せるようにするためです）。
# 戻り値: なし
func _update_sheet_field() -> void:
	if _source_edit == null or _sheet_edit == null:
		return
	var source_path: String = _source_edit.text.strip_edges()
	var route: int = detect_route(source_path)
	var uses_sheet: bool = route == ROUTE_ASEPRITE
	_sheet_edit.editable = uses_sheet
	if uses_sheet and _sheet_edit.text.strip_edges().is_empty():
		_sheet_edit.text = source_path.get_basename() + ".png"
	return  # end of function
# [_update_sheet_field]END


# [_on_source_changed]
# 処理内容: 元ファイル欄が変わったときにシートPNG欄を追随させます。
# 引数 new_text: 入力された内容です。
# 戻り値: なし
func _on_source_changed(new_text: String) -> void:
	_update_sheet_field()
	return  # end of function
# [_on_source_changed]END


# [_on_browse_pressed]
# 処理内容: 元ファイルを選ぶファイルダイアログを開きます。エディタ外でも動くよう、
#           EditorFileDialog ではなく標準の FileDialog を使います。
# 戻り値: なし
func _on_browse_pressed() -> void:
	if _file_dialog == null:
		_file_dialog = FileDialog.new()
		_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		_file_dialog.access = FileDialog.ACCESS_RESOURCES
		_file_dialog.add_filter("*.aseprite, *.ase", "Aseprite")
		_file_dialog.add_filter("*.json", "Aseprite data JSON")
		_file_dialog.file_selected.connect(_on_file_selected)
		add_child(_file_dialog)
	_file_dialog.popup_centered_ratio(0.6)
	return  # end of function
# [_on_browse_pressed]END


# [_on_file_selected]
# 処理内容: ファイルダイアログで選ばれたパスを元ファイル欄へ入れます。
# 引数 path: 選ばれたパスです。
# 戻り値: なし
func _on_file_selected(path: String) -> void:
	_source_edit.text = path
	_update_sheet_field()
	return  # end of function
# [_on_file_selected]END


# [_on_confirmed]
# 処理内容: 「取り込む」が押されたときに取り込みを実行します。
# 戻り値: なし
func _on_confirmed() -> void:
	run_import()
	return  # end of function
# [_on_confirmed]END
