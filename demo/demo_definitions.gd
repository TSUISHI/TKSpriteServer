# demo_definitions.gd — 定義JSONからスプライトを登録して再生するデモ
#
# 見どころ:
#   ・TKSpriteRegistry.register_all() だけで、5種の layout をまとめて登録できること
#   ・rotated / spin は 1枚の絵から実行時にアトラスが生成されること
#   ・v2 の durations（フレームごとの表示時間）と tags がそのまま再生に使えること
#   ・バックエンド（native / gdscript）が変わっても同じ結果になること
#
# 操作:
#   スペース / Enter … RING の反転（FLIP/FLOP）を切り替え
#   R                … 定義JSONを読み直して再登録（JSONを編集して結果を確認できます）
#   Esc              … 終了
#
# 画像は demo/assets/placeholder_atlas.png（幾何形状のみ）です。
# 生成し直す場合は demo/tools/make_placeholder_atlas.gd を実行してください。

extends Node2D

# スプライト定義JSONのパスです。
const DEFS_PATH: String = "res://demo/devdata/sprite_definitions.json"
# 同時に確保するスプライトの上限です。デモでは少数しか使いません。
const MAX_SPRITES: int = 64

# 表示位置です。左から順に並べます。
const DISPLAY_ORIGIN: Vector2 = Vector2(140.0, 240.0)
const DISPLAY_SPACING: float = 130.0

# ARROW が 1 秒間に進む方向数です（256 = 1秒で1回転）。
const ARROW_DIRECTIONS_PER_SECOND: float = 96.0
# COIN の1フレームあたりの表示時間（ミリ秒）です。
const COIN_FRAME_MSEC: float = 90.0

var _server: Object = null
var _backend_name: String = "?"
var _defs: Dictionary = {}
var _registered_count: int = 0

var _plane_back: RID
var _plane_medium: RID
var _plane_front: RID
var _plane_effect: RID

# 表示中のスプライトの link_id です（定義の並び順に対応します）。
var _link_ids: PackedInt32Array = PackedInt32Array()
# アニメーション状態です。要素はスプライトの並び順に対応します。
var _frame_indices: PackedInt32Array = PackedInt32Array()
var _frame_timers: PackedFloat32Array = PackedFloat32Array()

var _arrow_direction: float = 0.0
var _coin_timer: float = 0.0
var _ring_flipped: bool = false

var _hud_label: Label = null
var _hud_text_cache: String = ""


# [_ready]
# 処理内容: 描画面とサーバーを用意し、定義JSONからスプライトを登録します。
# 戻り値: なし
func _ready() -> void:
	_create_canvas_planes()
	_create_hud()
	_create_server()
	_load_and_register()
	return  # end of function
# [_ready]END


# [_exit_tree]
# 処理内容: サーバーと canvas_item を解放します。
# 戻り値: なし
func _exit_tree() -> void:
	if _server != null:
		_server.free_all_rids()
		if _server is Node and (_server as Node).get_parent() != null:
			(_server as Node).get_parent().remove_child(_server)
		_server.free()
		_server = null
	for plane_rid in [_plane_back, _plane_medium, _plane_front, _plane_effect]:
		if plane_rid.is_valid():
			RenderingServer.free_rid(plane_rid)
	return  # end of function
# [_exit_tree]END


# [_create_canvas_planes]
# 処理内容: 描画に使う canvas_item を4枚生成し、自分の canvas へぶら下げます。
# 戻り値: なし
func _create_canvas_planes() -> void:
	_plane_back = RenderingServer.canvas_item_create()
	_plane_medium = RenderingServer.canvas_item_create()
	_plane_front = RenderingServer.canvas_item_create()
	_plane_effect = RenderingServer.canvas_item_create()
	RenderingServer.canvas_item_set_parent(_plane_back, get_canvas())
	RenderingServer.canvas_item_set_parent(_plane_medium, get_canvas())
	RenderingServer.canvas_item_set_parent(_plane_front, get_canvas())
	RenderingServer.canvas_item_set_parent(_plane_effect, get_canvas())
	return  # end of function
# [_create_canvas_planes]END


# [_create_server]
# 処理内容: バックエンドを自動選択してサーバーを作り、描画面を渡します。
# 戻り値: なし
func _create_server() -> void:
	_server = TKSpriteServer.create(MAX_SPRITES, true, true)
	if _server == null:
		push_error("demo_definitions: サーバーを作成できませんでした。")
		return
	_backend_name = TKSpriteServer.get_backend_name(_server)
	if _server is Node:
		add_child(_server as Node)
	_server.set_plane_rids(_plane_back, _plane_medium, _plane_front)
	_server.set_effect_plane_rid(_plane_effect)
	return  # end of function
# [_create_server]END


# [_load_and_register]
# 処理内容: 定義JSONを読み込み、サーバーへ登録して表示用リンクを確保し直します。
#           Enter による再読み込みからも呼ばれます。
# 戻り値: なし
func _load_and_register() -> void:
	if _server == null:
		return

	# 再登録の前に、前回のリンクと生成キャッシュを片付けます。
	for link_id in _link_ids:
		_server.destroy_sprite(link_id)
	_link_ids = PackedInt32Array()
	TKSpriteAtlasBuilder.clear_cache()

	_defs = TKSpriteDefinitions.load_file(DEFS_PATH)
	_registered_count = TKSpriteRegistry.register_defs(_server, _defs)
	print("demo_definitions: backend=%s registered=%d" % [_backend_name, _registered_count])

	var sprites: Array = _defs.get("sprites", [])
	_frame_indices.resize(sprites.size())
	_frame_timers.resize(sprites.size())
	for index in range(sprites.size()):
		_frame_indices[index] = 0
		_frame_timers[index] = 0.0
		var sprite_id: int = int(sprites[index]["id"])
		var link_id: int = _server.allocate_link_id(sprite_id, false, false, 1, 0)
		_link_ids.append(link_id)
		_server.update_sprite(link_id, _get_display_position(index), 0)
	return  # end of function
# [_load_and_register]END


# [_process]
# 処理内容: アニメーションを進め、全スプライトの位置とフレームを更新します。
# 引数 delta: 前フレームからの経過秒です。
# 戻り値: なし
func _process(delta: float) -> void:
	if _server == null:
		return
	_handle_input()

	var sprites: Array = _defs.get("sprites", [])
	for index in range(mini(sprites.size(), _link_ids.size())):
		var sprite: Dictionary = sprites[index]
		var frame: int = _advance_frame(index, sprite, delta)
		_server.update_sprite(_link_ids[index], _get_display_position(index), frame)

	_server.commit_frame()
	_update_hud()
	return  # end of function
# [_process]END


# [_advance_frame]
# 処理内容: スプライト1件のアニメーションを1フレーム分進め、表示フレーム番号を返します。
#           rotated は方向番号から、spin は一定間隔で、それ以外は durations で進めます。
# 引数 index:  スプライトの並び順です。
# 引数 sprite: 定義です。
# 引数 delta:  経過秒です。
# 戻り値: 表示するフレーム番号です。
func _advance_frame(index: int, sprite: Dictionary, delta: float) -> int:
	var layout: String = String(sprite.get("layout", TKSpriteDefinitions.LAYOUT_SINGLE))
	var frame_count: int = _get_registered_frame_count(int(sprite["id"]))
	if frame_count <= 1:
		return 0

	if layout == TKSpriteDefinitions.LAYOUT_ROTATED:
		# 方向番号を進め、生成済みアトラスのフレーム番号へ変換します。
		_arrow_direction = fposmod(_arrow_direction + ARROW_DIRECTIONS_PER_SECOND * delta, float(TKSpriteAtlasBuilder.DIRECTION_RESOLUTION))
		return TKSpriteAtlasBuilder.direction_to_frame_index(int(_arrow_direction), frame_count)

	if layout == TKSpriteDefinitions.LAYOUT_SPIN:
		_coin_timer += delta * 1000.0
		while _coin_timer >= COIN_FRAME_MSEC:
			_coin_timer -= COIN_FRAME_MSEC
			_frame_indices[index] = (_frame_indices[index] + 1) % frame_count
		return _frame_indices[index]

	# durations があればそれに従い、無ければ一定間隔で進めます。
	var durations: Array = sprite.get("durations", [])
	var current: int = _frame_indices[index]
	var duration_msec: float = 120.0
	if current < durations.size():
		duration_msec = maxf(float(durations[current]), 1.0)
	_frame_timers[index] += delta * 1000.0
	if _frame_timers[index] >= duration_msec:
		_frame_timers[index] -= duration_msec
		_frame_indices[index] = (current + 1) % frame_count
	return _frame_indices[index]
# [_advance_frame]END


# [_get_registered_frame_count]
# 処理内容: サーバーへ登録済みのフレーム数を返します。rotated / spin は実行時生成の
#           結果を見る必要があるため、定義ではなく登録内容から取ります。
# 引数 sprite_id: スプライトIDです。
# 戻り値: フレーム数です。単一矩形なら 1 です。
func _get_registered_frame_count(sprite_id: int) -> int:
	var textures: Dictionary = _server.sprite_textures
	if not textures.has(sprite_id):
		return 0
	var entry: Dictionary = textures[sprite_id]
	if entry.has("frames"):
		return (entry["frames"] as Array).size()
	return 1
# [_get_registered_frame_count]END


# [_get_display_position]
# 処理内容: 並び順から表示位置を求めます。
# 引数 index: スプライトの並び順です。
# 戻り値: 表示位置です。
func _get_display_position(index: int) -> Vector2:
	return DISPLAY_ORIGIN + Vector2(DISPLAY_SPACING * float(index), 0.0)
# [_get_display_position]END


# [_handle_input]
# 処理内容: キー操作を処理します。
# 戻り値: なし
func _handle_input() -> void:
	if Input.is_action_just_pressed(&"ui_cancel"):
		get_tree().quit()
		return
	if Input.is_action_just_pressed(&"ui_accept"):
		# RING（single レイアウト）の反転を切り替えます。
		_ring_flipped = not _ring_flipped
		var ring_index: int = _find_sprite_index_by_name("RING")
		if ring_index >= 0 and ring_index < _link_ids.size():
			_server.set_sprite_flip(_link_ids[ring_index], _ring_flipped, _ring_flipped)
	return  # end of function
# [_handle_input]END


# [_unhandled_key_input]
# 処理内容: 定義JSONの再読み込み（R キー）を受け付けます。JSONを編集してから
#           押すと、その場で結果を確認できます。
# 引数 event: 入力イベントです。
# 戻り値: なし
func _unhandled_key_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not (event as InputEventKey).pressed:
		return
	if (event as InputEventKey).keycode == KEY_R:
		_load_and_register()
	return  # end of function
# [_unhandled_key_input]END


# [_find_sprite_index_by_name]
# 処理内容: 定義の並び順から、名前でスプライトの位置を探します。
# 引数 sprite_name: スプライト名です。
# 戻り値: 並び順。見つからなければ -1 です。
func _find_sprite_index_by_name(sprite_name: String) -> int:
	var sprites: Array = _defs.get("sprites", [])
	for index in range(sprites.size()):
		if String(sprites[index].get("name", "")) == sprite_name:
			return index
	return -1
# [_find_sprite_index_by_name]END


# [_create_hud]
# 処理内容: 情報表示用の CanvasLayer と Label を作ります。
# 戻り値: なし
func _create_hud() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 10
	add_child(layer)
	_hud_label = Label.new()
	_hud_label.position = Vector2(16.0, 12.0)
	_hud_label.add_theme_color_override("font_color", Color(1, 1, 1, 1))
	layer.add_child(_hud_label)
	return  # end of function
# [_create_hud]END


# [_update_hud]
# 処理内容: バックエンド名と各スプライトの状態を表示します。内容が変わったときだけ
#           Label を更新します。
# 戻り値: なし
func _update_hud() -> void:
	var lines: PackedStringArray = PackedStringArray()
	lines.append("TKSpriteServer / definitions demo    backend: %s" % _backend_name)
	lines.append("registered: %d sprites from %s" % [_registered_count, DEFS_PATH])
	lines.append("[Space] flip RING   [R] reload definitions   [Esc] quit")
	lines.append("")
	var sprites: Array = _defs.get("sprites", [])
	for index in range(sprites.size()):
		var sprite: Dictionary = sprites[index]
		lines.append("%-7s %-8s frames=%-3d frame=%d" % [
			String(sprite.get("name", "?")),
			String(sprite.get("layout", "?")),
			_get_registered_frame_count(int(sprite["id"])),
			_frame_indices[index] if index < _frame_indices.size() else 0
		])
	var text: String = "\n".join(lines)
	if text != _hud_text_cache:
		_hud_text_cache = text
		_hud_label.text = text
	return  # end of function
# [_update_hud]END
