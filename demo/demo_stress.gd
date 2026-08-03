extends Node2D

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  demo_stress.gd — 大量スプライト描画のストレステスト兼 FLIP/拡縮デモ       ║
# ╠═══════════════════════════════════════════════════════════════════════════╣
# ║  設計書 §10 / §4.4                                                         ║
# ║                                                                            ║
# ║  【役割】                                                                  ║
# ║  ・TKSpriteServer.create() でバックエンド（native / gdscript）を自動選択  ║
# ║    して大量スプライトを動かし、FPS を確認します。                         ║
# ║  ・反転（set_sprite_flip）と拡縮（update_sprite_scaled）を実行時に        ║
# ║    切り替えて目視確認できるようにします。                                 ║
# ║  ・プレースホルダ画像はゲーム素材を一切使わず、実行時に Image で          ║
# ║    手続き的に生成します（16x16 の 4 フレーム横並びアトラス）。            ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

# --- 定数 --------------------------------------------------------------------

# 登録するプレースホルダの sprite_id（1種類のみ使用）です。
const SPRITE_ID: int = 0

# 生成可能なスプライトの最大数です。TKSpriteServer.create() の max_sprites に渡します。
const MAX_SPRITES: int = 20000

# ↑/↓ キー1回あたりのスプライト数増減幅です。
const SPRITE_COUNT_STEP: int = 1000

# 起動直後に生成しておくスプライト数です。
const INITIAL_SPRITE_COUNT: int = 1000

# スプライトの移動速度の範囲（ピクセル/秒）です。
const MIN_SPEED: float = 60.0
const MAX_SPEED: float = 220.0

# S キーで循環させる拡縮倍率です（等倍 → 2倍 → 0.5倍）。
const _SCALE_MODES: Array[Vector2] = [
	Vector2(1.0, 1.0),
	Vector2(2.0, 2.0),
	Vector2(0.5, 0.5),
]
const _SCALE_MODE_NAMES: Array[String] = ["x1", "x2", "x0.5"]

# V キーの視認モードで使う倍率と配置です。反転が目視できるよう大きく静止表示します。
const VISUAL_SCALE: Vector2 = Vector2(6.0, 6.0)
const VISUAL_SPRITE_COUNT: int = 4
const VISUAL_ORIGIN: Vector2 = Vector2(40.0, 250.0)

# HUD の黒帯の高さです。視認モードのスプライトはこの下へ置きます。
const HUD_HEIGHT: float = 170.0
const VISUAL_SPACING: float = 140.0

# プレースホルダアトラス（64x16、16x16 の 4 フレーム）内での各フレームの矩形です。
const _FRAME_RECTS: Array[Rect2] = [
	Rect2(0.0, 0.0, 16.0, 16.0),
	Rect2(16.0, 0.0, 16.0, 16.0),
	Rect2(32.0, 0.0, 16.0, 16.0),
	Rect2(48.0, 0.0, 16.0, 16.0),
]

# --- 状態 ----------------------------------------------------------------

var _server: Object = null
var _prefer_native: bool = true

var _texture: ImageTexture = null

var _plane_back: RID = RID()
var _plane_medium: RID = RID()
var _plane_front: RID = RID()
var _plane_effect: RID = RID()

# 座標・速度は index*2 = x, index*2+1 = y の並びで固定長バッファに保持します。
# _process() 内で毎フレーム新規確保しないための措置です。
var _positions: PackedFloat32Array = PackedFloat32Array()
var _velocities: PackedFloat32Array = PackedFloat32Array()
var _link_ids: PackedInt32Array = PackedInt32Array()
var _active_count: int = 0

var _flip_h_state: bool = false
var _flip_v_state: bool = false
var _scale_mode_index: int = 0

# 視認モード中は移動を止め、VISUAL_SCALE で拡大して横一列に並べます。
var _visual_mode: bool = false

# サーバー処理時間の計測用です。vsync や GPU 負荷に影響されない
# 「_update_sprites + commit_frame にかかった時間」だけを測ります。
const PROFILE_SAMPLE_FRAMES: int = 60
var _profile_accum_usec: int = 0
var _profile_frames: int = 0
var _avg_ms: float = 0.0
var _last_avg_ms_x100: int = -1

var _backend_name: String = "unknown"

var _hud_label: Label = null
var _last_fps: int = -1
var _last_count: int = -1
var _last_flip_h: bool = false
var _last_flip_v: bool = false
var _last_scale_index: int = -1
var _last_backend_name: String = ""


# [_ready]
# 処理内容: 描画プレーンの生成、プレースホルダ画像の生成、バッファの確保、
#           HUD の構築、サーバーの初回生成と初期スプライトの生成を行います。
# 引数: なし。
# 戻り値: なし。
func _ready() -> void:
	randomize()
	# ベンチマーク用途のデモなので、vsync と FPS 上限を外して実力値を測れるようにします。
	# vsync が有効なままだと 60 で頭打ちになり、バックエンド間の本当の差が見えません。
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	_create_canvas_planes()
	_texture = _create_placeholder_atlas()

	_positions.resize(MAX_SPRITES * 2)
	_velocities.resize(MAX_SPRITES * 2)
	_link_ids.resize(MAX_SPRITES)
	for i in range(MAX_SPRITES):
		_link_ids[i] = -1

	_build_hud()
	_recreate_server()
	_change_sprite_count(INITIAL_SPRITE_COUNT)
	return  # end of function
# [_ready]END


# [_exit_tree]
# 処理内容: 生成した RID（描画プレーン4枚）とサーバーのリソースを解放します。
#           解放を忘れるとエディタ実行を繰り返した際に RenderingServer 側へ
#           canvas_item が残り続けます。
# 引数: なし。
# 戻り値: なし。
func _exit_tree() -> void:
	if _server != null and _server.has_method(&"free_all_rids"):
		_server.free_all_rids()
	if _plane_back.is_valid():
		RenderingServer.free_rid(_plane_back)
	if _plane_medium.is_valid():
		RenderingServer.free_rid(_plane_medium)
	if _plane_front.is_valid():
		RenderingServer.free_rid(_plane_front)
	if _plane_effect.is_valid():
		RenderingServer.free_rid(_plane_effect)
	return  # end of function
# [_exit_tree]END


# [_create_canvas_planes]
# 処理内容: 描画に使う canvas_item を4枚（背面・中間・前面・エフェクト）
#           生成し、自分自身の canvas へぶら下げます。
# 引数: なし。
# 戻り値: なし。
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


# [_create_placeholder_atlas]
# 処理内容: ゲーム素材を使わず、16x16 の4フレーム横並び（64x16）の
#           プレースホルダ画像を手続き的に生成します。
#           フレーム0=塗りつぶし円、1=左向き三角、2=四角枠、3=斜め線。
#           1と3は左右非対称にし、反転（FLIP）が目視で分かるようにします。
# 引数: なし。
# 戻り値: 生成した ImageTexture です。
func _create_placeholder_atlas() -> ImageTexture:
	# Image.create() は Godot 4.3 で非推奨になったため create_empty() を使います。
	var img := Image.create_empty(64, 16, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.0, 0.0, 0.0, 0.0))
	var white := Color(1.0, 1.0, 1.0, 1.0)

	# フレーム0: 右向き三角（頂点が右端）+ 左下の3x3ブロック。
	# 上下左右どちらの反転でも見た目が変わるように、両軸で非対称にしています。
	for x in range(16):
		var h0 := ((15.0 - float(x)) / 15.0) * 6.0
		var y0_min := int(round(8.0 - h0))
		var y0_max := int(round(8.0 + h0))
		for y in range(y0_min, y0_max + 1):
			if y >= 0 and y < 16:
				img.set_pixel(x, y, white)
	for y in range(13, 16):
		for x in range(0, 3):
			img.set_pixel(x, y, white)

	# フレーム1: 左向き三角（頂点が左端、底辺が右端＝左右非対称）
	for x in range(16):
		var half := (float(x) / 15.0) * 5.5
		var y_min := int(round(8.0 - half))
		var y_max := int(round(8.0 + half))
		for y in range(y_min, y_max + 1):
			if y >= 0 and y < 16:
				img.set_pixel(16 + x, y, white)

	# フレーム2: L字（左辺と下辺のみ）。四角枠だと上下左右とも対称で
	# 反転が分からないため、両軸で非対称なL字にしています。
	for y in range(16):
		img.set_pixel(32, y, white)
		img.set_pixel(33, y, white)
	for x in range(16):
		img.set_pixel(32 + x, 14, white)
		img.set_pixel(32 + x, 15, white)

	# フレーム3: 斜め線（左上から右下＝左右反転すると右上-左下になり非対称）
	for x in range(16):
		for y in range(16):
			if abs(x - y) <= 1:
				img.set_pixel(48 + x, y, white)

	return ImageTexture.create_from_image(img)
# [_create_placeholder_atlas]END


# [_build_hud]
# 処理内容: FPS・バックエンド名・スプライト数・flip状態・拡縮倍率・
#           操作説明を表示する CanvasLayer + Label を構築します。
# 引数: なし。
# 戻り値: なし。
func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)

	# スプライトも白のため、帯を敷かないと文字が完全に埋もれます。
	# 半透明の黒帯 + 文字の黒縁取りで、背後に何が流れていても読めるようにします。
	var bg := ColorRect.new()
	bg.color = Color(0.0, 0.0, 0.0, 0.72)
	bg.position = Vector2.ZERO
	bg.size = Vector2(get_viewport_rect().size.x, HUD_HEIGHT)
	layer.add_child(bg)

	_hud_label = Label.new()
	_hud_label.position = Vector2(8.0, 8.0)
	_hud_label.add_theme_color_override("font_color", Color.WHITE)
	_hud_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_hud_label.add_theme_constant_override("outline_size", 4)
	layer.add_child(_hud_label)
	return  # end of function
# [_build_hud]END


# [_recreate_server]
# 処理内容: 現在のサーバーを破棄し、_prefer_native の設定でバックエンドを
#           作り直します。描画プレーンとプレースホルダテクスチャを再登録し、
#           既にアクティブなスプライトがあれば同じ座標のまま新サーバーへ
#           再登録します（B キーでのバックエンド切替と初回生成の両方で使用）。
# 引数: なし。
# 戻り値: なし。
func _recreate_server() -> void:
	if _server != null:
		remove_child(_server)
		if _server.has_method(&"free_all_rids"):
			_server.free_all_rids()
		_server.queue_free()
		_server = null

	_server = TKSpriteServer.create(MAX_SPRITES, true, _prefer_native)
	add_child(_server)
	_backend_name = TKSpriteServer.get_backend_name(_server)
	# headless 実行でもどちらのバックエンドが選ばれたか確認できるようにします。
	print("[TKSpriteServer] backend = ", _backend_name)

	_server.set_plane_rids(_plane_back, _plane_medium, _plane_front)
	_server.set_effect_plane_rid(_plane_effect)
	_server.sprite_textures[SPRITE_ID] = {"texture": _texture, "frames": _FRAME_RECTS}
	_server.set_sprite_draw_size(SPRITE_ID, Vector2(16.0, 16.0))

	for i in range(_active_count):
		_link_ids[i] = _server.allocate_link_id(SPRITE_ID, _flip_h_state, _flip_v_state)
	return  # end of function
# [_recreate_server]END


# [_process]
# 処理内容: 毎フレーム、全アクティブスプライトの座標更新・反射・サーバーへの
#           反映を行い、最後に commit_frame() を呼びます。HUD の更新も行います。
# 引数 delta: 前フレームからの経過秒数です。
# 戻り値: なし。
func _process(delta: float) -> void:
	# ここからここまでがライブラリの担当範囲です。vsync 待ちや他ノードの
	# 処理は含まれないため、バックエンド間の素の差がそのまま出ます。
	var t0 := Time.get_ticks_usec()
	_update_sprites(delta)
	_server.commit_frame()
	_profile_accum_usec += Time.get_ticks_usec() - t0
	_profile_frames += 1
	if _profile_frames >= PROFILE_SAMPLE_FRAMES:
		_avg_ms = float(_profile_accum_usec) / float(_profile_frames) / 1000.0
		_profile_accum_usec = 0
		_profile_frames = 0

	_update_hud()
	return  # end of function
# [_process]END


# [_update_sprites]
# 処理内容: PackedFloat32Array に保持した座標・速度を使って全スプライトを
#           移動させ、画面端で反射させたうえでサーバーへ反映します。
#           新規の Array/Dictionary/String はここでは確保しません。
# 引数 delta: 前フレームからの経過秒数です。
# 戻り値: なし。
func _update_sprites(delta: float) -> void:
	# 視認モードでは移動させず、拡大して並べたまま描画します。
	if _visual_mode:
		for i in range(_active_count):
			var vi := i * 2
			_server.update_sprite_scaled(_link_ids[i], Vector2(_positions[vi], _positions[vi + 1]), VISUAL_SCALE, i % _FRAME_RECTS.size(), Color.WHITE, -1, -1)
		return  # end of function

	var bounds := get_viewport_rect().size
	var scale: Vector2 = _SCALE_MODES[_scale_mode_index]
	# update_sprite系の座標は「左上基準」です。中心基準で反射させると
	# 右端・下端で半分はみ出すため、スプライト1枚分のサイズで境界を取ります。
	var sprite_w := 16.0 * scale.x
	var sprite_h := 16.0 * scale.y
	var max_x := maxf(0.0, bounds.x - sprite_w)
	var max_y := maxf(0.0, bounds.y - sprite_h)

	for i in range(_active_count):
		var base_idx := i * 2
		var pos_x := _positions[base_idx] + _velocities[base_idx] * delta
		var pos_y := _positions[base_idx + 1] + _velocities[base_idx + 1] * delta

		if pos_x < 0.0:
			pos_x = 0.0
			_velocities[base_idx] = abs(_velocities[base_idx])
		elif pos_x > max_x:
			pos_x = max_x
			_velocities[base_idx] = -abs(_velocities[base_idx])

		if pos_y < 0.0:
			pos_y = 0.0
			_velocities[base_idx + 1] = abs(_velocities[base_idx + 1])
		elif pos_y > max_y:
			pos_y = max_y
			_velocities[base_idx + 1] = -abs(_velocities[base_idx + 1])

		_positions[base_idx] = pos_x
		_positions[base_idx + 1] = pos_y

		# フレームを個体ごとに変えます。全個体を frame=0（丸）で描くと
		# 左右対称なので反転が目視できなくなるためです。
		_server.update_sprite_scaled(_link_ids[i], Vector2(pos_x, pos_y), scale, i % _FRAME_RECTS.size(), Color.WHITE, -1, -1)
	return  # end of function
# [_update_sprites]END


# [_change_sprite_count]
# 処理内容: アクティブなスプライト数を delta ぶん増減させます。
#           0〜MAX_SPRITES の範囲へクランプします。
# 引数 delta: 増減量（負値で減少）です。
# 戻り値: なし。
func _change_sprite_count(delta: int) -> void:
	var new_count: int = clampi(_active_count + delta, 0, MAX_SPRITES)
	if new_count == _active_count:
		return

	if new_count > _active_count:
		for i in range(_active_count, new_count):
			_spawn_sprite(i)
	else:
		for i in range(new_count, _active_count):
			_despawn_sprite(i)

	_active_count = new_count
	return  # end of function
# [_change_sprite_count]END


# [_spawn_sprite]
# 処理内容: 指定インデックスへ新規スプライトを1体生成します。
#           初期座標はランダム、速度もランダムな方向・速さで決めます。
# 引数 index: バッファ内のスロット番号です。
# 戻り値: なし。
func _spawn_sprite(index: int) -> void:
	var bounds := get_viewport_rect().size
	var pos_x := randf() * bounds.x
	var pos_y := randf() * bounds.y
	var angle := randf() * TAU
	var speed := randf_range(MIN_SPEED, MAX_SPEED)

	var base_idx := index * 2
	_positions[base_idx] = pos_x
	_positions[base_idx + 1] = pos_y
	_velocities[base_idx] = cos(angle) * speed
	_velocities[base_idx + 1] = sin(angle) * speed

	_link_ids[index] = _server.allocate_link_id(SPRITE_ID, _flip_h_state, _flip_v_state)
	return  # end of function
# [_spawn_sprite]END


# [_despawn_sprite]
# 処理内容: 指定インデックスのスプライトをサーバーから破棄します。
# 引数 index: バッファ内のスロット番号です。
# 戻り値: なし。
func _despawn_sprite(index: int) -> void:
	var link_id: int = _link_ids[index]
	if link_id >= 0:
		_server.destroy_sprite(link_id)
	_link_ids[index] = -1
	return  # end of function
# [_despawn_sprite]END


# [_toggle_flip_h]
# 処理内容: 全アクティブスプライトの flip_h をトグルします
#           （set_sprite_flip の動作確認用）。
# 引数: なし。
# 戻り値: なし。
func _toggle_flip_h() -> void:
	_flip_h_state = not _flip_h_state
	for i in range(_active_count):
		_server.set_sprite_flip(_link_ids[i], _flip_h_state, _flip_v_state)
	return  # end of function
# [_toggle_flip_h]END


# [_toggle_flip_v]
# 処理内容: 全アクティブスプライトの flip_v をトグルします。
# 引数: なし。
# 戻り値: なし。
func _toggle_flip_v() -> void:
	_flip_v_state = not _flip_v_state
	for i in range(_active_count):
		_server.set_sprite_flip(_link_ids[i], _flip_h_state, _flip_v_state)
	return  # end of function
# [_toggle_flip_v]END


# [_toggle_visual_mode]
# 処理内容: 反転の目視確認用モードを切り替えます。ONにするとスプライトを
#           VISUAL_SPRITE_COUNT 体まで減らし、移動を止めて拡大表示します。
#           4種のフレームがそれぞれ1体ずつ並ぶので、F/Gキーで向きが変わる
#           様子と、位置がずれていないかを同時に確認できます。
# 引数: なし。
# 戻り値: なし。
func _toggle_visual_mode() -> void:
	_visual_mode = not _visual_mode
	if _visual_mode:
		_change_sprite_count(VISUAL_SPRITE_COUNT - _active_count)
		for i in range(_active_count):
			var base_idx := i * 2
			_positions[base_idx] = VISUAL_ORIGIN.x + float(i) * VISUAL_SPACING
			_positions[base_idx + 1] = VISUAL_ORIGIN.y
	else:
		_change_sprite_count(INITIAL_SPRITE_COUNT - _active_count)
		for i in range(_active_count):
			_respawn_position(i)
	return  # end of function
# [_toggle_visual_mode]END


# [_respawn_position]
# 処理内容: 指定インデックスの座標と速度だけをランダムに置き直します。
#           視認モードから通常モードへ戻すときに使います。
# 引数 index: バッファ内のスロット番号です。
# 戻り値: なし。
func _respawn_position(index: int) -> void:
	var bounds := get_viewport_rect().size
	var angle := randf() * TAU
	var speed := randf_range(MIN_SPEED, MAX_SPEED)
	var base_idx := index * 2
	_positions[base_idx] = randf() * bounds.x
	_positions[base_idx + 1] = randf() * bounds.y
	_velocities[base_idx] = cos(angle) * speed
	_velocities[base_idx + 1] = sin(angle) * speed
	return  # end of function
# [_respawn_position]END


# [_cycle_scale_mode]
# 処理内容: 拡縮モードを 等倍 → 2倍 → 0.5倍 の順に循環させます。
#           実際の反映は毎フレームの update_sprite_scaled 呼び出し側で行います。
# 引数: なし。
# 戻り値: なし。
func _cycle_scale_mode() -> void:
	_scale_mode_index = (_scale_mode_index + 1) % _SCALE_MODES.size()
	return  # end of function
# [_cycle_scale_mode]END


# [_toggle_backend]
# 処理内容: prefer_native を反転させ、サーバーを作り直します
#           （B キー押下時に呼ばれます）。
# 引数: なし。
# 戻り値: なし。
func _toggle_backend() -> void:
	_prefer_native = not _prefer_native
	_recreate_server()
	return  # end of function
# [_toggle_backend]END


# [_update_hud]
# 処理内容: FPS・バックエンド名・スプライト数・flip状態・拡縮倍率のいずれかが
#           前回表示時から変化していた場合のみ、Label のテキストを再生成します。
#           変化していないフレームでは文字列を新規に確保しません。
# 引数: なし。
# 戻り値: なし。
func _update_hud() -> void:
	var fps_int: int = int(round(Engine.get_frames_per_second()))
	# バックエンド名はサーバー再生成時にしか変わらないため、毎フレームの
	# 文字列生成を避けてキャッシュ値を使います。
	var backend_name: String = _backend_name

	var avg_ms_x100: int = int(round(_avg_ms * 100.0))
	if fps_int == _last_fps and _active_count == _last_count \
			and _flip_h_state == _last_flip_h and _flip_v_state == _last_flip_v \
			and _scale_mode_index == _last_scale_index and backend_name == _last_backend_name \
			and avg_ms_x100 == _last_avg_ms_x100:
		return
	_last_avg_ms_x100 = avg_ms_x100

	_last_fps = fps_int
	_last_count = _active_count
	_last_flip_h = _flip_h_state
	_last_flip_v = _flip_v_state
	_last_scale_index = _scale_mode_index
	_last_backend_name = backend_name

	_hud_label.text = "FPS: %d   Server: %.2f ms/frame\nBackend: %s\nSprites: %d / %d\nFlip H:%s V:%s\nScale: %s\nVisual check mode: %s\n\n[V] visual check  [UP/DOWN] sprite count  [F] flip_h  [G] flip_v  [S] scale  [B] backend  [ESC] quit" % [
		fps_int, _avg_ms, backend_name, _active_count, MAX_SPRITES,
		str(_flip_h_state), str(_flip_v_state), _SCALE_MODE_NAMES[_scale_mode_index],
		str(_visual_mode),
	]
	return  # end of function
# [_update_hud]END


# [_input]
# 処理内容: ↑/↓/F/G/S/B/ESC の各キー入力を処理します。
# 引数 event: 入力イベントです。
# 戻り値: なし。
func _input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key_event: InputEventKey = event
	if not key_event.pressed or key_event.echo:
		return

	match key_event.keycode:
		KEY_UP:
			_change_sprite_count(SPRITE_COUNT_STEP)
		KEY_DOWN:
			_change_sprite_count(-SPRITE_COUNT_STEP)
		KEY_F:
			_toggle_flip_h()
		KEY_G:
			_toggle_flip_v()
		KEY_S:
			_cycle_scale_mode()
		KEY_V:
			_toggle_visual_mode()
		KEY_B:
			_toggle_backend()
		KEY_ESCAPE:
			get_tree().quit()
	return  # end of function
# [_input]END
