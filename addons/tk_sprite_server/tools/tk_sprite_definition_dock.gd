@tool
extends Control
class_name TKSpriteDefinitionDock

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  tk_sprite_definition_dock.gd — 定義エディタのエディタ下部パネル用ラッパ  ║
# ╠═══════════════════════════════════════════════════════════════════════════╣
# ║  【役割】                                                                  ║
# ║  ・TKSpriteDefinitionTool を Godot エディタの下部パネルで開くための、      ║
# ║    パス指定バーだけを足した薄いラッパです。                                ║
# ║  ・ツール本体は実行時ツールとしても使えるままです。このラッパは            ║
# ║    editor_mode = true を立て、キーボードとゲームパッドの処理を止めます     ║
# ║    （エディタ自身のショートカットと衝突するためです）。                    ║
# ║                                                                            ║
# ║  【使い方】                                                                ║
# ║  ・プロジェクト設定でこのアドオンを有効にすると、下部パネルに              ║
# ║    「Sprite Definitions」タブが現れます。                                   ║
# ║  ・編集したい定義JSONのパスを入れて「読み込み」を押します。                ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

# ツール本体です。class_name のグローバル登録に依存しないよう preload で束縛します。
const DefinitionTool = preload("res://addons/tk_sprite_server/tools/tk_sprite_definition_tool.gd")

# 下部パネルの既定の高さです。狭いとプレビューが潰れるため確保します。
const DOCK_MIN_HEIGHT: float = 480.0

# 起動時に開く定義JSONのパスです。
const DEFAULT_DEFS_PATH: String = "res://demo/devdata/sprite_definitions.json"

# 取り込みボタンの文言です。テストからも参照します。
const IMPORT_BUTTON_TEXT: String = "Aseprite から取り込み"

const ImportDialog = preload("res://addons/tk_sprite_server/tools/tk_aseprite_import_dialog.gd")

var _path_edit: LineEdit = null
var _tool_container: Control = null
var _tool_instance: Control = null
var _import_button: Button = null
var _import_dialog: ConfirmationDialog = null
var _status_label: Label = null


# [_ready]
# 処理内容: パス指定バーとツール表示領域を作り、既定のパスで読み込みます。
# 戻り値: なし
func _ready() -> void:
	custom_minimum_size = Vector2(0.0, DOCK_MIN_HEIGHT)

	var layout := VBoxContainer.new()
	layout.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(layout)

	var toolbar := HBoxContainer.new()
	layout.add_child(toolbar)

	var label := Label.new()
	label.text = "定義JSON:"
	toolbar.add_child(label)

	_path_edit = LineEdit.new()
	_path_edit.text = DEFAULT_DEFS_PATH
	_path_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toolbar.add_child(_path_edit)

	var load_button := Button.new()
	load_button.text = "読み込み"
	load_button.pressed.connect(_on_load_pressed)
	toolbar.add_child(load_button)

	_import_button = Button.new()
	_import_button.text = IMPORT_BUTTON_TEXT
	_import_button.pressed.connect(_on_import_pressed)
	toolbar.add_child(_import_button)

	_status_label = Label.new()
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	layout.add_child(_status_label)

	_import_dialog = ImportDialog.new()
	_import_dialog.import_finished.connect(_on_import_finished)
	add_child(_import_dialog)

	_tool_container = Control.new()
	_tool_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	layout.add_child(_tool_container)

	open_definitions(DEFAULT_DEFS_PATH)
	return  # end of function
# [_ready]END


# [open_definitions]
# 処理内容: 指定した定義JSONでツールを作り直します。既に開いていたものは破棄します。
# 引数 defs_path: 編集する定義JSONのパスです。
# 戻り値: なし
func open_definitions(defs_path: String) -> void:
	if _tool_instance != null:
		_tool_container.remove_child(_tool_instance)
		_tool_instance.queue_free()
		_tool_instance = null

	if not FileAccess.file_exists(defs_path):
		push_warning("TKSpriteDefinitionDock: 定義ファイルが見つかりません: " + defs_path)
		return

	# defs_path と editor_mode は _ready より前に設定する必要があるため、
	# ツリーへ追加する前に書き込みます。
	var tool_instance: Control = DefinitionTool.new()
	tool_instance.defs_path = defs_path
	tool_instance.editor_mode = true
	tool_instance.set_anchors_preset(Control.PRESET_FULL_RECT)
	_tool_container.add_child(tool_instance)
	_tool_instance = tool_instance
	return  # end of function
# [open_definitions]END


# [get_tool_instance]
# 処理内容: 表示中のツール本体を返します（テストや外部からの操作用）。
# 戻り値: ツール本体。未生成なら null です。
func get_tool_instance() -> Control:
	return _tool_instance
# [get_tool_instance]END


# [_on_load_pressed]
# 処理内容: 「読み込み」ボタンで、入力されたパスの定義を開き直します。
# 戻り値: なし
func _on_load_pressed() -> void:
	open_definitions(_path_edit.text.strip_edges())
	return  # end of function
# [_on_load_pressed]END


# [_on_import_pressed]
# 処理内容: 取り込みダイアログを開きます。定義がまだ読み込まれていないときは、
#           マージ先が無い状態での取り込みを防ぐため開きません。
# 戻り値: なし
func _on_import_pressed() -> void:
	if _tool_instance == null:
		_set_status("先に定義JSONを読み込んでください。")
		return
	_import_dialog.defs_path = _path_edit.text.strip_edges()
	_import_dialog.popup_centered()
	return  # end of function
# [_on_import_pressed]END


# [_on_import_finished]
# 処理内容: 取り込み結果を受け取ります。成功したときだけ定義を読み直して画面へ反映します。
# 引数 success: 成否です。
# 引数 message: 表示する内容です。
# 戻り値: なし
func _on_import_finished(success: bool, message: String) -> void:
	_set_status(message)
	if success:
		open_definitions(_path_edit.text.strip_edges())
	return  # end of function
# [_on_import_finished]END


# [_set_status]
# 処理内容: 状態ラベルへ文字列を出します。
# 引数 text: 表示する内容です。
# 戻り値: なし
func _set_status(text: String) -> void:
	if _status_label != null:
		_status_label.text = text
	return  # end of function
# [_on_load_pressed]END
