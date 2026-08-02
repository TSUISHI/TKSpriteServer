class_name TKSpriteServer extends RefCounted

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  tk_sprite_server.gd — バックエンド自動切替ファサード                      ║
# ╠═══════════════════════════════════════════════════════════════════════════╣
# ║  設計書: CLAUDE_SPEC_TKSpriteServerKit.md §6.1 / §4.3 / §4.4                ║
# ║                                                                            ║
# ║  【役割】                                                                  ║
# ║  ・ネイティブ実装 TKSpriteServerNative（ClassDB 登録の Node2D 派生）が     ║
# ║    利用可能ならそれを生成し、API 互換性を検査したうえで返します。          ║
# ║  ・利用不可・非互換の場合は GDScript 実装 TKSpriteServerGD へ              ║
# ║    自動フォールバックします。                                             ║
# ║  ・元ロジックは移植元ゲームの create_sprite_server() /                     ║
# ║    should_try_native_sprite_server() / is_sprite_server_compatible() を    ║
# ║    ライブラリ側へ移設したものです。                                       ║
# ║                                                                            ║
# ║  【重要】戻り値は Node です。                                             ║
# ║  create() が返すサーバーは TKSpriteServerNative（Node2D 派生）または       ║
# ║  TKSpriteServerGD（Node 派生を想定）であり、いずれも Node です。           ║
# ║  呼び出し側は戻り値を必ずシーンツリーへ add_child() してください。         ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

# ネイティブ実装が ClassDB に登録される際のクラス名です。
const NATIVE_CLASS_NAME: String = "TKSpriteServerNative"

# GDScript 実装のスクリプトパスです。class_name のグローバル登録に依存せず、
# create() 実行時に load() で解決します（preload だと両ファイルが相互に
# 依存した場合に解決順の問題が起きるため）。
const GD_SERVER_SCRIPT_PATH: String = "res://addons/tk_sprite_server/core/tk_sprite_server_gd.gd"

# _is_compatible() が総当たりする必須メソッド名の一覧です。
# API 契約から setup() と get_stats() を除いた全メソッドを列挙します。
const REQUIRED_METHODS: Array[StringName] = [
	&"set_plane_rids",
	&"set_effect_plane_rid",
	&"set_text_plane_rid",
	&"set_sprite_draw_size",
	&"get_sprite_draw_size",
	&"allocate_link_id",
	&"update_sprite",
	&"update_sprite_stretched",
	&"update_sprite_scaled",
	&"set_sprite_flip",
	&"get_sprite_flip",
	&"get_sprite_id_from_link",
	&"destroy_sprite",
	&"request_draw",
	&"commit_frame",
	&"clear_all",
	&"free_all_rids",
]


# [is_native_available]
# 処理内容: ネイティブ実装 TKSpriteServerNative が ClassDB に登録済みで、
#           かつ実際にインスタンス化可能かを確認します。
# 引数: なし。
# 戻り値: 登録済みかつインスタンス化可能なら true です。
static func is_native_available() -> bool:
	if not ClassDB.class_exists(NATIVE_CLASS_NAME):
		return false
	if not ClassDB.can_instantiate(NATIVE_CLASS_NAME):
		return false
	return true
# [is_native_available]END


# [create]
# 処理内容: ネイティブ優先でサーバーを生成します。ネイティブが利用不可、
#           または API 互換性チェックに落ちた場合は GDScript 実装へ
#           自動フォールバックします。
# 引数 max_sprites: 生成時に確保するスプライト上限数です。
# 引数 pixel_snap: 描画位置を整数座標へ丸めるかどうかです。
# 引数 prefer_native: false を渡すと強制的に GDScript 実装を使います
#                      （デモのバックエンド切替などに使用）。
# 戻り値: setup() 済みのサーバーインスタンスです（Node）。
#         呼び出し側が add_child() でシーンツリーへ入れる必要があります。
static func create(max_sprites: int = 4096, pixel_snap: bool = true, prefer_native: bool = true) -> Object:
	var server: Object = null

	if prefer_native and is_native_available():
		var native_server: Object = ClassDB.instantiate(NATIVE_CLASS_NAME)
		if native_server != null:
			if _is_compatible(native_server):
				server = native_server
			else:
				push_warning("TKSpriteServerNative is available, but does not expose the full TKSpriteServer-compatible API. Falling back to TKSpriteServerGD.")
				native_server.free()

	if server == null:
		var gd_script: Script = load(GD_SERVER_SCRIPT_PATH)
		server = gd_script.new()

	if server.has_method(&"setup"):
		server.setup(max_sprites, pixel_snap)

	return server
# [create]END


# [_is_compatible]
# 処理内容: サーバーが必須メソッドを一通り実装しているかを has_method() の
#           総当たりで検査します。不足しているメソッド名があれば
#           push_warning に列挙します。
# 引数 server: 検査対象のサーバーインスタンスです。
# 戻り値: 必須メソッドが全て揃っていれば true です。
static func _is_compatible(server: Object) -> bool:
	if server == null:
		return false

	var missing_methods: Array[StringName] = []
	for method_name in REQUIRED_METHODS:
		if not server.has_method(method_name):
			missing_methods.append(method_name)

	if not missing_methods.is_empty():
		push_warning("TKSpriteServer: backend is missing required methods: %s" % [missing_methods])
		return false

	return true
# [_is_compatible]END


# [get_backend_name]
# 処理内容: 生成済みサーバーがどちらの実装かを判定します。判定は
#           ClassDB に登録されたネイティブクラス名かどうかで行います。
# 引数 server: create() が返したサーバーインスタンスです。
# 戻り値: "native" / "gdscript" / "unknown" のいずれかです。
static func get_backend_name(server: Object) -> String:
	if server == null:
		return "unknown"

	if server.get_class() == NATIVE_CLASS_NAME:
		return "native"

	var server_script: Script = server.get_script()
	if server_script != null and server_script.get_global_name() == "TKSpriteServerGD":
		return "gdscript"

	return "unknown"
# [get_backend_name]END
