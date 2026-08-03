@tool
extends EditorPlugin

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  plugin.gd — TKSpriteServer エディタプラグイン登録                        ║
# ╠═══════════════════════════════════════════════════════════════════════════╣
# ║  設計書 §9                                                                 ║
# ║                                                                            ║
# ║  【役割】                                                                  ║
# ║  ・スプライト定義エディタをエディタ下部パネルへ登録します。                ║
# ║  ・Aseprite インポータ（EditorImportPlugin）を登録します。                  ║
# ║                                                                            ║
# ║  【現在の状態】                                                            ║
# ║  ・定義エディタの下部パネル登録は有効です。Aseprite の                     ║
# ║    EditorImportPlugin（経路C）は未実装のためコメントアウトしています。     ║
# ║  ・ランタイム側（TKSpriteServer.create() など）はこのプラグインを          ║
# ║    有効化しなくても動作します。プラグインはエディタ機能専用です。          ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

const DOCK_TITLE: String = "Sprite Definitions"

# 下部パネルへ追加したツール本体です。無効化時に取り外すため保持します。
var _definition_dock: Control = null

# Aseprite の EditorImportPlugin です（Phase 5 で有効化します）。
var _aseprite_import_plugin: EditorImportPlugin = null


# [_enter_tree]
# 処理内容: プラグイン有効化時にエディタ用 UI とインポータを登録します。
# 引数: なし。
# 戻り値: なし。
func _enter_tree() -> void:
	# スプライト定義エディタを下部パネルへ登録します。
	_definition_dock = preload("res://addons/tk_sprite_server/tools/tk_sprite_definition_dock.gd").new()
	add_control_to_bottom_panel(_definition_dock, DOCK_TITLE)

	# --- Phase 5 で有効化します ---------------------------------------------
	# _aseprite_import_plugin = preload("res://addons/tk_sprite_server/tools/tk_aseprite_import_plugin.gd").new()
	# add_import_plugin(_aseprite_import_plugin)
	return  # end of function
# [_enter_tree]END


# [_exit_tree]
# 処理内容: プラグイン無効化時に登録したものをすべて取り外します。
#           取り外し忘れるとエディタ再読み込み時に UI が二重に残ります。
# 引数: なし。
# 戻り値: なし。
func _exit_tree() -> void:
	if _definition_dock != null:
		remove_control_from_bottom_panel(_definition_dock)
		_definition_dock.queue_free()
		_definition_dock = null

	if _aseprite_import_plugin != null:
		remove_import_plugin(_aseprite_import_plugin)
		_aseprite_import_plugin = null
	return  # end of function
# [_exit_tree]END
