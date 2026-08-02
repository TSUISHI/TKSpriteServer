# tk_sprite_server_gd.gd — TKSpriteServer GDScriptバックエンド
#
# 2Dレトロゲーム向けに書いた SpriteServer.gd を公開ライブラリ向けに移植したものです。
# sprite_slots（Dictionary配列）+ free_list + active_link_ids による
# swap-with-last のO(1)削除という構造はそのまま維持しています。
#
# 移植元からの主な変更点:
#   1. プール上限 MAX_SPRITES(定数50000) を可変の max_sprites(既定4096) にし、
#      setup() で確保タイミングと上限を選べるようにした。
#   2. FLIP/FLOP（反転）を canvas_item の transform スケール符号で実際に描画へ反映した
#      （移植元は flip_h/flip_v をスロットへ保存するだけで描画に使っていなかった）。
#   3. 公開API（set_sprite_flip / get_sprite_flip / update_sprite_scaled /
#      get_sprite_id_from_link / get_stats / clear_all）を追加した。
#
# 設計書: CLAUDE_SPEC_TKSpriteServerKit.md §4.3 / §4.4

class_name TKSpriteServerGD extends Node

const INVALID_LINK_ID: int = -1
const DRAW_MISSING_SPRITE_FALLBACK: bool = false

var max_sprites: int = 4096
var pixel_snap: bool = true

var sprite_slots: Array[Dictionary] = []
var free_list: Array[int] = []
var active_link_ids: Array[int] = []
var active_link_count: int = 0
var transient_link_ids: Array[int] = []
var sprite_textures: Dictionary = {}
var sprite_draw_sizes: Dictionary = {}
var sprite_buffer_over: bool = false

var _pool_allocated: bool = false

var back_plane_rid: RID
var medium_plane_rid: RID
var front_plane_rid: RID
var effect_plane_rid: RID
var text_plane_rid: RID
var sprite_text_link_ids: PackedInt32Array = PackedInt32Array()
var sprite_text_glyphs: PackedInt32Array = PackedInt32Array()
var sprite_text_cols: int = 0
var sprite_text_rows: int = 0
var sprite_text_cell_width: int = 0
var sprite_text_cell_height: int = 0
var sprite_text_glyph_base_id: int = 0
var sprite_text_plane_type: int = 4
var sprite_text_priority: int = 0
var sprite_text_cursor_col: int = 0
var sprite_text_cursor_row: int = 0

# [_ready]
# 処理内容: setup()が事前に呼ばれていなければ既定値(max_sprites=4096, pixel_snap=true)でプールを確保します。
#           setup()が既に呼ばれていた場合は二重確保しません。
# 引数: なし。
# 戻り値: なし。
func _ready() -> void:
	if not _pool_allocated:
		_allocate_pool()
	return  # end of function
# [_ready]END

# [setup]
# 処理内容: プール上限とピクセルスナップ設定を確定してからスロットを確保し直します。
#           _ready()より前でも後でも呼べます。既に確保済みだった場合は先に全RIDを解放してから再確保します。
# 引数 p_max_sprites: 同時に発行できるlink_idの上限です。1未満は1に丸めます。
# 引数 p_pixel_snap: 描画座標を整数ピクセルへ丸めるかどうかです。
# 戻り値: なし。
func setup(p_max_sprites: int = 4096, p_pixel_snap: bool = true) -> void:
	if _pool_allocated:
		free_all_rids()
	max_sprites = maxi(1, p_max_sprites)
	pixel_snap = p_pixel_snap
	_allocate_pool()
	return  # end of function
# [setup]END

# [_allocate_pool]
# 処理内容: sprite_slots / active_link_ids を max_sprites 個ぶん確保し、free_listを満杯状態で初期化します。
# 引数: なし。
# 戻り値: なし。
func _allocate_pool() -> void:
	sprite_slots.resize(max_sprites)
	active_link_ids.resize(max_sprites)
	active_link_count = 0
	free_list.clear()
	for i in range(max_sprites - 1, -1, -1):
		sprite_slots[i] = {
			"active": false,
			"active_index": -1,
			"rid": RID(),
			"sprite_id": -1,
			"pos": Vector2.ZERO,
			"flip_h": false,
			"flip_v": false,
			"frame": 0,
			"color": Color.WHITE,
			"draw_size": Vector2.ZERO,
			"plane_type": 1,
			"priority": 0,
			"plane_rid": RID()
		}
		free_list.append(i)
	_pool_allocated = true
	return  # end of function
# [_allocate_pool]END

# [set_plane_rids]
# 処理内容: 背景・中景・前景のCanvasItem RIDを保持します。
# 引数 back: 背景プレーンのRIDです。
# 引数 medium: 中景プレーンのRIDです。
# 引数 front: 前景プレーンのRIDです。
# 戻り値: なし。
func set_plane_rids(back: RID, medium: RID, front: RID) -> void:
	back_plane_rid = back
	medium_plane_rid = medium
	front_plane_rid = front
	return  # end of function
# [set_plane_rids]END

# [set_effect_plane_rid]
# 処理内容: エフェクト用プレーンのCanvasItem RIDを保持します。
# 引数 plane_rid: エフェクトプレーンのRIDです。
# 戻り値: なし。
func set_effect_plane_rid(plane_rid: RID) -> void:
	effect_plane_rid = plane_rid
	return  # end of function
# [set_effect_plane_rid]END

# [set_text_plane_rid]
# 処理内容: 文字HUD用プレーンのCanvasItem RIDを保持します。
# 引数 plane_rid: 文字HUDプレーンのRIDです。
# 戻り値: なし。
func set_text_plane_rid(plane_rid: RID) -> void:
	text_plane_rid = plane_rid
	return  # end of function
# [set_text_plane_rid]END

# [init_sprite_text]
# 処理内容: 文字HUD用のセルグリッドを初期化します。
# 引数 cols: 横方向のセル数です。
# 引数 rows: 縦方向のセル数です。
# 引数 cell_width: 1セルの幅(px)です。
# 引数 cell_height: 1セルの高さ(px)です。
# 引数 glyph_base_id: 数字0に対応するsprite_idです（以降は連番）。
# 引数 plane_type: 描画するプレーン種別です。
# 引数 priority: 描画優先度です。
# 戻り値: なし。
func init_sprite_text(cols: int, rows: int, cell_width: int, cell_height: int, glyph_base_id: int, plane_type: int, priority: int) -> void:
	if cols <= 0 or rows <= 0 or cell_width <= 0 or cell_height <= 0:
		return
	var cell_count = cols * rows
	sprite_text_link_ids.resize(cell_count)
	sprite_text_link_ids.fill(INVALID_LINK_ID)
	sprite_text_glyphs.resize(cell_count)
	sprite_text_glyphs.fill(-1)
	sprite_text_cols = cols
	sprite_text_rows = rows
	sprite_text_cell_width = cell_width
	sprite_text_cell_height = cell_height
	sprite_text_glyph_base_id = glyph_base_id
	sprite_text_plane_type = plane_type
	sprite_text_priority = priority
	sprite_text_cursor_col = 0
	sprite_text_cursor_row = 0
	return  # end of function
# [init_sprite_text]END

# [sprlocate]
# 処理内容: 次に sprprint()/sprprintint() が表示する開始セルを指定します。
# 座標基準: (0, 0) はウィンドウ全体ではなく、ゲーム画面内の左上です。
# グリッド数は初期化時に渡されたセル寸法から計算済みです。
# 有効座標の最大値は横 sprite_text_cols - 1、縦 sprite_text_rows - 1 です。
# 引数 col: 開始列です。
# 引数 row: 開始行です。
# 戻り値: なし。
func sprlocate(col: int, row: int) -> void:
	if col < 0 or row < 0 or col >= sprite_text_cols or row >= sprite_text_rows:
		sprite_text_cursor_col = sprite_text_cols
		sprite_text_cursor_row = sprite_text_rows
		return  # end of function
	sprite_text_cursor_col = col
	sprite_text_cursor_row = row
	return  # end of function
# [sprlocate]END

# [sprprint]
# 処理内容: 文字列を1文字ずつグリフ番号へ変換し、文字HUDへ書き込みます。
# 引数 text: 表示したい文字列です（0-9, A-Z のみグリフを持ちます）。
# 戻り値: なし。
func sprprint(text: String) -> void:
	for glyph in text:
		var glyph_index = -1
		match glyph:
			"0": glyph_index = 0
			"1": glyph_index = 1
			"2": glyph_index = 2
			"3": glyph_index = 3
			"4": glyph_index = 4
			"5": glyph_index = 5
			"6": glyph_index = 6
			"7": glyph_index = 7
			"8": glyph_index = 8
			"9": glyph_index = 9
			"A": glyph_index = 10
			"B": glyph_index = 11
			"C": glyph_index = 12
			"D": glyph_index = 13
			"E": glyph_index = 14
			"F": glyph_index = 15
			"G": glyph_index = 16
			"H": glyph_index = 17
			"I": glyph_index = 18
			"J": glyph_index = 19
			"K": glyph_index = 20
			"L": glyph_index = 21
			"M": glyph_index = 22
			"N": glyph_index = 23
			"O": glyph_index = 24
			"P": glyph_index = 25
			"Q": glyph_index = 26
			"R": glyph_index = 27
			"S": glyph_index = 28
			"T": glyph_index = 29
			"U": glyph_index = 30
			"V": glyph_index = 31
			"W": glyph_index = 32
			"X": glyph_index = 33
			"Y": glyph_index = 34
			"Z": glyph_index = 35
			_: glyph_index = -1
		_sprite_text_put(glyph_index)
	return  # end of function
# [sprprint]END

# [sprprintint]
# 処理内容: 整数値を指定桁数のグリフとして文字HUDへ書き込みます。
# 引数 value: 表示したい整数値です（負値は0扱い）。
# 引数 digits: 表示桁数です。
# 戻り値: なし。
func sprprintint(value: int, digits: int) -> void:
	if digits <= 0:
		return
	if value < 0:
		value = 0
	var divisor = 1
	for divisor_index in range(1, digits):
		divisor *= 10
	for digit_index in range(digits):
		var glyph_index = -1
		if value >= divisor or digit_index == digits - 1:
			glyph_index = (value / divisor) % 10
		if divisor > 1:
			divisor /= 10
		_sprite_text_put(glyph_index)
	return  # end of function
# [sprprintint]END

# [sprcls]
# 処理内容: 文字HUD上の全セルのスプライトを破棄し、カーソルを原点へ戻します。
# 引数: なし。
# 戻り値: なし。
func sprcls() -> void:
	for cell_index in range(sprite_text_link_ids.size()):
		var link_id = sprite_text_link_ids[cell_index]
		if link_id != INVALID_LINK_ID:
			destroy_sprite(link_id)
			sprite_text_link_ids[cell_index] = INVALID_LINK_ID
			sprite_text_glyphs[cell_index] = -1
	sprite_text_cursor_col = 0
	sprite_text_cursor_row = 0
	return  # end of function
# [sprcls]END

# [_sprite_text_put]
# 処理内容: カーソル位置に1グリフ分のスプライトを配置・更新・撤去し、カーソルを1つ進めます。
# 引数 glyph_index: 表示したいグリフ番号です。負値ならそのセルを空にします。
# 戻り値: なし。
func _sprite_text_put(glyph_index: int) -> void:
	if sprite_text_cursor_row >= sprite_text_rows:
		sprite_text_cursor_col = sprite_text_cols
		sprite_text_cursor_row = sprite_text_rows - 1
		return
	if sprite_text_cursor_col >= sprite_text_cols:
		sprite_text_cursor_col = 0
		sprite_text_cursor_row += 1
		if sprite_text_cursor_row >= sprite_text_rows:
			sprite_text_cursor_col = sprite_text_cols
			sprite_text_cursor_row = sprite_text_rows - 1
			return
	if sprite_text_cursor_col < 0 or sprite_text_cursor_row < 0:
		sprite_text_cursor_col += 1
		return
	if sprite_text_cursor_col >= 0 and sprite_text_cursor_row >= 0:
		var cell_index = sprite_text_cursor_row * sprite_text_cols + sprite_text_cursor_col
		if sprite_text_glyphs[cell_index] != glyph_index:
			var link_id = sprite_text_link_ids[cell_index]
			if glyph_index < 0:
				if link_id != INVALID_LINK_ID:
					destroy_sprite(link_id)
					sprite_text_link_ids[cell_index] = INVALID_LINK_ID
			else:
				# セルが既に使用中なら旧グリフのスプライトを破棄してから作り直します（update_sprite は sprite_id を差し替えないため、旧数字が残るのを防ぐ）。
				if link_id != INVALID_LINK_ID:
					destroy_sprite(link_id)
					sprite_text_link_ids[cell_index] = INVALID_LINK_ID
				link_id = allocate_link_id(sprite_text_glyph_base_id + glyph_index, false, false, sprite_text_plane_type, sprite_text_priority)
				sprite_text_link_ids[cell_index] = link_id
				if link_id != INVALID_LINK_ID:
					update_sprite(link_id, Vector2(sprite_text_cursor_col * sprite_text_cell_width, sprite_text_cursor_row * sprite_text_cell_height), 0, Color.WHITE, sprite_text_plane_type, sprite_text_priority)
			sprite_text_glyphs[cell_index] = glyph_index
	sprite_text_cursor_col += 1
	return  # end of function
# [_sprite_text_put]END

# [allocate_link_id]
# 処理内容: 空きスロットを1つ取り出し、描画個体用のlink_idを発行します。
# 引数 sprite_id: 描画するスプライトIDです。
# 引数 flip_h: 左右反転の初期値です。commit_frame()のtransformへ実際に反映されます。
# 引数 flip_v: 上下反転の初期値です。commit_frame()のtransformへ実際に反映されます。
# 引数 plane_type: 0=背景、1=中景、2=前景です。
# 引数 priority: 同一プレーン内の描画優先度です。
# 戻り値: 成功時はlink_id、失敗時はINVALID_LINK_IDです。
func allocate_link_id(sprite_id: int, flip_h: bool = false, flip_v: bool = false, plane_type: int = 1, priority: int = 0) -> int:
	if free_list.is_empty() or active_link_count >= max_sprites:
		sprite_buffer_over = true
		return INVALID_LINK_ID

	var link_id = free_list.pop_back()
	var rid = RenderingServer.canvas_item_create()
	var plane_rid = get_plane_rid(plane_type)
	RenderingServer.canvas_item_set_parent(rid, plane_rid)

	var slot = sprite_slots[link_id]
	slot["active"] = true
	slot["active_index"] = active_link_count
	slot["rid"] = rid
	slot["sprite_id"] = sprite_id
	slot["pos"] = Vector2(-1000, -1000)
	slot["flip_h"] = flip_h
	slot["flip_v"] = flip_v
	slot["frame"] = 0
	slot["color"] = Color.WHITE
	slot["draw_size"] = Vector2.ZERO
	slot["plane_type"] = plane_type
	slot["priority"] = priority
	slot["plane_rid"] = plane_rid
	sprite_slots[link_id] = slot

	active_link_ids[active_link_count] = link_id
	active_link_count += 1
	return link_id
# [allocate_link_id]END

# [update_sprite]
# 処理内容: 発行済みlink_idの表示座標、アニメフレーム、色、描画プレーンを更新します。
#           draw_sizeは毎回ゼロへリセットします（stretched/scaled系はこの後に上書きする想定です）。
#           flip_h/flip_vはここではリセットしません（allocate_link_id時とset_sprite_flip()でのみ変わります）。
# 引数 link_id: allocate_link_id()で発行されたIDです。
# 引数 pos: 画面上の描画座標です。
# 引数 frame: アニメーションフレーム番号です。
# 引数 color: 個体色です。
# 引数 plane_type: 0=背景、1=中景、2=前景です。-1なら現在値を維持します。
# 引数 priority: 描画優先度です。-1なら現在値を維持します。
# 戻り値: なし。
func update_sprite(link_id: int, pos: Vector2, frame: int = 0, color: Color = Color.WHITE, plane_type: int = -1, priority: int = -1) -> void:
	if link_id < 0 or link_id >= sprite_slots.size():
		return
	var slot = sprite_slots[link_id]
	if not slot["active"]:
		return

	slot["pos"] = snap_render_position(pos)
	slot["frame"] = frame
	slot["color"] = color
	slot["draw_size"] = Vector2.ZERO
	if plane_type >= 0:
		slot["plane_type"] = plane_type
	if priority >= 0:
		slot["priority"] = priority
	sprite_slots[link_id] = slot
	return  # end of function
# [update_sprite]END

# [update_sprite_stretched]
# 処理内容: 発行済みlink_idを、指定した表示矩形サイズ(絶対ピクセル)へ拡縮して更新します。
# 補足: レーザーパーツ群を1本の論理レーザーとして1回で描画するためのlink単位サイズです。
# 引数 link_id: 対象のlink_idです。
# 引数 pos: 画面上の描画座標です。
# 引数 draw_size: 表示したい絶対ピクセルサイズです。
# 引数 frame: アニメーションフレーム番号です。
# 引数 color: 個体色です。
# 引数 plane_type: 0=背景、1=中景、2=前景です。-1なら現在値を維持します。
# 引数 priority: 描画優先度です。-1なら現在値を維持します。
# 戻り値: なし。
func update_sprite_stretched(link_id: int, pos: Vector2, draw_size: Vector2, frame: int = 0, color: Color = Color.WHITE, plane_type: int = -1, priority: int = -1) -> void:
	update_sprite(link_id, pos, frame, color, plane_type, priority)
	if link_id < 0 or link_id >= sprite_slots.size():
		return
	var slot = sprite_slots[link_id]
	if not slot["active"]:
		return
	slot["draw_size"] = Vector2(maxf(1.0, roundf(draw_size.x)), maxf(1.0, roundf(draw_size.y)))
	sprite_slots[link_id] = slot
	return  # end of function
# [update_sprite_stretched]END

# [update_sprite_scaled]
# 処理内容: 元スプライトの基準サイズ(get_sprite_draw_size)に倍率scaleを掛けた絶対ピクセルサイズを求め、
#           update_sprite_stretched()と同じ経路で反映します。
# 引数 link_id: 対象のlink_idです。
# 引数 pos: 画面上の描画座標です。
# 引数 scale: 基準サイズに対する倍率です。等倍以外はドット絵が歪むため推奨しません。
# 引数 frame: アニメーションフレーム番号です。
# 引数 color: 個体色です。
# 引数 plane_type: 0=背景、1=中景、2=前景です。-1なら現在値を維持します。
# 引数 priority: 描画優先度です。-1なら現在値を維持します。
# 戻り値: なし。
func update_sprite_scaled(link_id: int, pos: Vector2, scale: Vector2, frame: int = 0, color: Color = Color.WHITE, plane_type: int = -1, priority: int = -1) -> void:
	var sprite_id = get_sprite_id_from_link(link_id)
	if sprite_id < 0:
		return
	var base_size: Vector2 = get_sprite_draw_size(sprite_id)
	var scaled_size: Vector2 = Vector2(base_size.x * scale.x, base_size.y * scale.y)
	update_sprite_stretched(link_id, pos, scaled_size, frame, color, plane_type, priority)
	return  # end of function
# [update_sprite_scaled]END

# [set_sprite_flip]
# 処理内容: 発行済みlink_idの反転状態を実行中に切り替えます。次回commit_frame()のtransformへ反映されます。
# 引数 link_id: 対象のlink_idです。
# 引数 flip_h: 左右反転するかどうかです。
# 引数 flip_v: 上下反転するかどうかです。
# 戻り値: なし。
func set_sprite_flip(link_id: int, flip_h: bool, flip_v: bool) -> void:
	if link_id < 0 or link_id >= sprite_slots.size():
		return
	var slot = sprite_slots[link_id]
	if not slot["active"]:
		return
	slot["flip_h"] = flip_h
	slot["flip_v"] = flip_v
	sprite_slots[link_id] = slot
	return  # end of function
# [set_sprite_flip]END

# [get_sprite_flip]
# 処理内容: 発行済みlink_idの現在の反転状態を返します。
# 引数 link_id: 対象のlink_idです。
# 戻り値: x=flip_h(0/1), y=flip_v(0/1)。無効なlink_idやfree状態のときはVector2i(0,0)です。
func get_sprite_flip(link_id: int) -> Vector2i:
	if link_id < 0 or link_id >= sprite_slots.size():
		return Vector2i.ZERO
	var slot = sprite_slots[link_id]
	if not slot["active"]:
		return Vector2i.ZERO
	var fh: int = 1 if slot["flip_h"] else 0
	var fv: int = 1 if slot["flip_v"] else 0
	return Vector2i(fh, fv)
# [get_sprite_flip]END

# [get_sprite_id_from_link]
# 処理内容: 発行済みlink_idに紐づくsprite_idを返します。
# 引数 link_id: 対象のlink_idです。
# 戻り値: sprite_id。無効なlink_idやfree状態のときは-1です。
func get_sprite_id_from_link(link_id: int) -> int:
	if link_id < 0 or link_id >= sprite_slots.size():
		return -1
	var slot = sprite_slots[link_id]
	if not slot["active"]:
		return -1
	return int(slot["sprite_id"])
# [get_sprite_id_from_link]END

# [destroy_sprite]
# 処理内容: 指定link_idのRIDを解放し、有効ID配列からO(1)で取り除きます。
# 引数 link_id: 破棄したい描画個体IDです。
# 戻り値: なし。
func destroy_sprite(link_id: int) -> void:
	if link_id < 0 or link_id >= sprite_slots.size():
		return
	var slot = sprite_slots[link_id]
	if not slot["active"]:
		return

	var rid: RID = slot["rid"]
	if rid != RID():
		RenderingServer.free_rid(rid)

	var active_index = int(slot["active_index"])
	active_link_count -= 1
	if active_index != active_link_count:
		var moved_link_id = active_link_ids[active_link_count]
		active_link_ids[active_index] = moved_link_id
		var moved_slot = sprite_slots[moved_link_id]
		moved_slot["active_index"] = active_index
		sprite_slots[moved_link_id] = moved_slot
	active_link_ids[active_link_count] = INVALID_LINK_ID

	slot["active"] = false
	slot["active_index"] = -1
	slot["rid"] = RID()
	slot["sprite_id"] = -1
	slot["pos"] = Vector2.ZERO
	slot["draw_size"] = Vector2.ZERO
	slot["plane_rid"] = RID()
	sprite_slots[link_id] = slot
	free_list.append(link_id)
	return  # end of function
# [destroy_sprite]END

# [commit_frame]
# 処理内容: 使用中スロットだけをRenderingServerへ反映します。
#           反転(flip_h/flip_v)はcanvas_itemのtransformのスケール符号で表現し、
#           左上基準のずれをox/oyで補正します。拡縮はdraw_slot()側のdest_rectが正値のまま担当するため、
#           ここで二重に反転させないよう注意してください。
# 引数: なし。
# 戻り値: なし。
func commit_frame() -> void:
	for i in range(active_link_count):
		var link_id = active_link_ids[i]
		var slot = sprite_slots[link_id]
		var rid: RID = slot["rid"]
		if rid == RID():
			continue

		var plane_rid = get_plane_rid(slot["plane_type"])
		if slot["plane_rid"] != plane_rid:
			slot["plane_rid"] = plane_rid
			sprite_slots[link_id] = slot
			RenderingServer.canvas_item_set_parent(rid, plane_rid)

		RenderingServer.canvas_item_clear(rid)
		RenderingServer.canvas_item_set_draw_index(rid, int(slot["priority"]))

		var draw_size: Vector2 = get_slot_effective_draw_size(slot)
		var sx: float = -1.0 if slot["flip_h"] else 1.0
		var sy: float = -1.0 if slot["flip_v"] else 1.0
		var ox: float = draw_size.x if slot["flip_h"] else 0.0
		var oy: float = draw_size.y if slot["flip_v"] else 0.0
		# 原点補正を足した後にもう一度スナップします。draw_sizeが非整数のとき
		# （利用者が小数の描画サイズを登録した場合など）に反転側だけ半端な座標になるのを防ぎます。
		RenderingServer.canvas_item_set_transform(rid, Transform2D(Vector2(sx, 0.0), Vector2(0.0, sy), snap_render_position(slot["pos"] + Vector2(ox, oy))))

		# 実効描画サイズは算出済みなので渡します（1スプライトあたり2回計算するのを避けるため）。
		draw_slot(rid, slot, draw_size)

	clear_transient_links()
	return  # end of function
# [commit_frame]END

# [request_draw]
# 処理内容: 旧API互換用に、1フレームだけ有効な描画要求を作ります。
# 引数 sprite_id: 描画するスプライトIDです。
# 引数 pos: 画面上の描画座標です。
# 引数 flip_h: 左右反転するかどうかです。
# 引数 flip_v: 上下反転するかどうかです。
# 引数 plane_type: 0=背景、1=中景、2=前景です。
# 引数 priority: 描画優先度です。
# 戻り値: なし。
func request_draw(sprite_id: int, pos: Vector2, flip_h: bool, flip_v: bool, plane_type: int, priority: int) -> void:
	var link_id = allocate_link_id(sprite_id, flip_h, flip_v, plane_type, priority)
	if link_id == INVALID_LINK_ID:
		return
	update_sprite(link_id, pos, 0, Color.WHITE, plane_type, priority)
	transient_link_ids.append(link_id)
	return  # end of function
# [request_draw]END

# [flush_and_decay]
# 処理内容: 旧API互換用のフレーム反映関数です。内部ではcommit_frame()を呼びます。
# 引数: なし。
# 戻り値: なし。
func flush_and_decay() -> void:
	commit_frame()
	return  # end of function
# [flush_and_decay]END

# [free_all_rids]
# 処理内容: 確保済みRIDをすべて解放し、スロットと管理配列を初期状態へ戻します。
#           setup()での再確保前のクリーンアップとしても使うため、範囲は max_sprites ではなく
#           その時点の sprite_slots のサイズを基準にします。
# 引数: なし。
# 戻り値: なし。
func free_all_rids() -> void:
	for i in range(active_link_count):
		var link_id = active_link_ids[i]
		var slot = sprite_slots[link_id]
		if slot["rid"] != RID():
			RenderingServer.free_rid(slot["rid"])

	active_link_count = 0
	active_link_ids.fill(INVALID_LINK_ID)
	free_list.clear()
	for i in range(sprite_slots.size() - 1, -1, -1):
		var slot = sprite_slots[i]
		slot["active"] = false
		slot["active_index"] = -1
		slot["rid"] = RID()
		slot["sprite_id"] = -1
		slot["draw_size"] = Vector2.ZERO
		slot["plane_rid"] = RID()
		sprite_slots[i] = slot
		free_list.append(i)
	transient_link_ids.clear()
	sprite_textures.clear()
	return  # end of function
# [free_all_rids]END

# [clear_all]
# 処理内容: free_all_rids()の別名です（C++版のAPI名に合わせています）。
# 引数: なし。
# 戻り値: なし。
func clear_all() -> void:
	free_all_rids()
	return  # end of function
# [clear_all]END

# [get_stats]
# 処理内容: 現在のプール利用状況を返します。頻繁には呼ばれない想定のためDictionaryを新規生成します。
# 引数: なし。
# 戻り値: active_link_count / max_sprites / free_count / sprite_buffer_over / backend を持つDictionaryです。
func get_stats() -> Dictionary:
	return {
		"active_link_count": active_link_count,
		"max_sprites": max_sprites,
		"free_count": free_list.size(),
		"sprite_buffer_over": sprite_buffer_over,
		"backend": "gdscript"
	}
# [get_stats]END

# [get_plane_rid]
# 処理内容: プレーン種別から対応するCanvasItem RIDを返します。
# 引数 plane_type: 0=背景、1=中景、2=前景です。
# 戻り値: 対応するRIDです。不明な値は中景扱いです。
func get_plane_rid(plane_type: int) -> RID:
	if plane_type == 0:
		return back_plane_rid
	if plane_type == 2:
		return front_plane_rid
	if plane_type == 3 and effect_plane_rid != RID():
		return effect_plane_rid
	if plane_type == 4 and text_plane_rid != RID():
		return text_plane_rid
	return medium_plane_rid
# [get_plane_rid]END

# [get_slot_effective_draw_size]
# 処理内容: スロットの実効描画サイズを返します。draw_slot()とcommit_frame()の両方から呼ばれる共通ヘルパーです。
#           slot["draw_size"]が正値ならそれを使い、そうでなければget_sprite_draw_size()の既定サイズを使います。
# 引数 slot: sprite_idやdraw_sizeを持つスロット情報です。
# 戻り値: 実効描画サイズ(px)です。
func get_slot_effective_draw_size(slot: Dictionary) -> Vector2:
	var draw_size: Vector2 = slot["draw_size"]
	if draw_size.x <= 0.0 or draw_size.y <= 0.0:
		draw_size = get_sprite_draw_size(int(slot["sprite_id"]))
	return draw_size
# [get_slot_effective_draw_size]END

# [draw_slot]
# 処理内容: 1つのスロット情報を指定RIDへ描画します。dest_rectは常に正値のままとし、
#           反転はcommit_frame()側のtransformが担当するため、ここでは二重に反転させません。
# 引数 rid: 描画先CanvasItem RIDです。
# 引数 slot: sprite_idや座標などを持つスロット情報です。
# 引数 effective_draw_size: 算出済みの実効描画サイズです。ZERO以下なら内部で求め直します。
# 戻り値: なし。
func draw_slot(rid: RID, slot: Dictionary, effective_draw_size: Vector2 = Vector2.ZERO) -> void:
	var sprite_id = int(slot["sprite_id"])
	if sprite_textures.has(sprite_id):
		var tex_data = sprite_textures[sprite_id]
		var source_rect: Rect2
		if tex_data.has("frames"):
			var frames: Array = tex_data["frames"]
			# frames が空だと剰余演算でゼロ除算になるため、描画せずに抜けます。
			if frames.is_empty():
				return
			source_rect = frames[int(slot["frame"]) % frames.size()]
		elif tex_data.has("rect"):
			source_rect = tex_data["rect"]
		else:
			return
		var draw_size: Vector2 = effective_draw_size
		if draw_size.x <= 0.0 or draw_size.y <= 0.0:
			draw_size = get_slot_effective_draw_size(slot)
		var dest_rect = Rect2(Vector2.ZERO, draw_size)
		# テクスチャ未設定の登録ミスでクラッシュしないようにします。
		var texture = tex_data.get("texture")
		if texture == null:
			return
		RenderingServer.canvas_item_add_texture_rect_region(rid, dest_rect, texture.get_rid(), source_rect, slot["color"])
		return

	if DRAW_MISSING_SPRITE_FALLBACK:
		var color = Color.WHITE if sprite_id == 0 else Color.YELLOW
		RenderingServer.canvas_item_add_rect(rid, Rect2(0, 0, 16, 16), color)
	return  # end of function
# [draw_slot]END

# [snap_render_position]
# 処理内容: 低解像度の拡大表示で小数座標が不規則な揺れに見えるのを避けるため、描画座標を整数ピクセルへ丸めます。
# 引数 pos: 丸めたい描画座標です。
# 戻り値: 設定に応じて丸めた描画座標です。
func snap_render_position(pos: Vector2) -> Vector2:
	if not pixel_snap:
		return pos
	return pos.round()
# [snap_render_position]END

# [set_sprite_draw_size]
# 処理内容: sprite_idごとの既定描画サイズを登録します。
# 引数 sprite_id: 対象のスプライトIDです。
# 引数 size: 既定描画サイズ(px)です。
# 戻り値: なし。
func set_sprite_draw_size(sprite_id: int, size: Vector2) -> void:
	sprite_draw_sizes[sprite_id] = size
	return  # end of function
# [set_sprite_draw_size]END

# [get_sprite_draw_size]
# 処理内容: sprite_idの既定描画サイズを返します。登録がなければテクスチャ情報から推定し、それも無ければ16x16を返します。
# 引数 sprite_id: 対象のスプライトIDです。
# 戻り値: 既定描画サイズ(px)です。
func get_sprite_draw_size(sprite_id: int) -> Vector2:
	var size: Vector2 = sprite_draw_sizes.get(sprite_id, Vector2.ZERO)
	if size.x > 0.0 and size.y > 0.0:
		return size
	if sprite_textures.has(sprite_id):
		var tex_data = sprite_textures[sprite_id]
		if tex_data.has("frames"):
			var frames: Array = tex_data["frames"]
			if not frames.is_empty():
				return frames[0].size
		if tex_data.has("rect"):
			return tex_data["rect"].size
	return Vector2(16.0, 16.0)
# [get_sprite_draw_size]END

# [clear_transient_links]
# 処理内容: request_draw()で作った一時link_idをフレーム末尾で破棄します。
# 引数: なし。
# 戻り値: なし。
func clear_transient_links() -> void:
	var i = transient_link_ids.size() - 1
	while i >= 0:
		destroy_sprite(transient_link_ids[i])
		i -= 1
	transient_link_ids.clear()
	return  # end of function
# [clear_transient_links]END
