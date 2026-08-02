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

var failure_count: int = 0
var _dock: Control = null
var _elapsed_frames: int = 0


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
