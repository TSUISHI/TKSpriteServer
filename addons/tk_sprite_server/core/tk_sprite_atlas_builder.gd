# tk_sprite_atlas_builder.gd — 1枚のドット絵から回転アトラスを実行時生成する
#
# 2Dレトロゲーム向けに書いた build_rotated_sprite_atlas() / build_spin_animation_atlas() /
# _rotate_image_nearest() を公開ライブラリ向けに移植したものです。
# 手描きで 16〜64 方向を用意しなくても、元絵 1 枚から全方向アトラスが得られます。
#
# 移植元からの主な変更点:
#   1. サーバーへ直接登録するのをやめ、{ "texture", "frames", ... } を返す純関数にした
#      （登録は TKSpriteRegistry の役目）。
#   2. Image を直接渡す build_rotated_from_image() / build_spin_from_image() を追加し、
#      ファイルを介さずに生成できるようにした（手続き生成や Aseprite 直読み用）。
#   3. 生成キャッシュ・PNG書き出し・進捗コールバックを追加した（§6.5.5）。
#
# 方向番号の規約（§6.5.1）: 256分割・時計回りに増加。
#   0 = 右(3時), 64 = 下(6時), 128 = 左(9時), 192 = 上(12時)。
#
# 設計書: CLAUDE_SPEC_TKSpriteServerKit.md §6.5
#
# 【メモリ規則】生成は起動時またはツール実行時に行います。毎フレーム呼んではいけません。

class_name TKSpriteAtlasBuilder extends RefCounted

# 方向の分割数です。1周 = 256方向。
const DIRECTION_RESOLUTION: int = 256
# 1象限あたりの方向数です（256 / 4）。
const DIRECTIONS_PER_QUADRANT: int = 64
# roughness の許容範囲です。0 = 256枚、6 = 4枚。
const ROUGHNESS_MIN: int = 0
const ROUGHNESS_MAX: int = 6
# 1周のラジアンです。
const FULL_ROTATION_RAD: float = 2.0 * PI

# 生成結果のプロセス内キャッシュです（キー: _make_cache_key() の文字列）。
# 同一パラメータでの再生成を避けます。clear_cache() で解放できます。
static var _atlas_cache: Dictionary = {}


# [build_rotated]
# 処理内容: 画像ファイルから全方向の回転アトラスを生成します。
# 引数 image_path:            元画像のパス（res:// / user:// / 絶対パス）。
# 引数 crop_rect:             元画像から切り取る領域です。
# 引数 original_orientation:  元画像が向いている方向番号です（既定 64 = 真下）。
# 引数 roughness:             生成精度 0〜6 です（既定 4 = 16方向）。
# 引数 progress_callback:     func(done: int, total: int) を受け取る任意のコールバックです。
# 戻り値: { "texture": ImageTexture, "frames": Array[Rect2], "image": Image,
#          "frame_size": Vector2i, "total_frames": int }。失敗時は空 Dictionary です。
static func build_rotated(
	image_path: String,
	crop_rect: Rect2i,
	original_orientation: int = 64,
	roughness: int = 4,
	progress_callback: Callable = Callable()
) -> Dictionary:
	var cache_key: String = _make_cache_key("rot", image_path, crop_rect, original_orientation, roughness, 0)
	if _atlas_cache.has(cache_key):
		return (_atlas_cache[cache_key] as Dictionary).duplicate()

	var source: Image = load_source_image(image_path)
	if source == null:
		push_warning("TKSpriteAtlasBuilder: 画像を読み込めませんでした: " + image_path)
		return {}

	var result: Dictionary = build_rotated_from_image(source, crop_rect, original_orientation, roughness, progress_callback)
	if not result.is_empty():
		_atlas_cache[cache_key] = result
	return result.duplicate()
# [build_rotated]END


# [build_rotated_from_image]
# 処理内容: Image から全方向の回転アトラスを生成します。キャッシュは使いません。
#           第1象限だけを実回転で作り、残り3象限は反転で展開します（実回転が1/4）。
# 引数 source:               元画像です。
# 引数 crop_rect:            元画像から切り取る領域です。
# 引数 original_orientation: 元画像が向いている方向番号です。
# 引数 roughness:            生成精度 0〜6 です。
# 引数 progress_callback:    func(done: int, total: int) の任意コールバックです。
# 戻り値: build_rotated() と同じ Dictionary です。失敗時は空 Dictionary です。
static func build_rotated_from_image(
	source: Image,
	crop_rect: Rect2i,
	original_orientation: int = 64,
	roughness: int = 4,
	progress_callback: Callable = Callable()
) -> Dictionary:
	if source == null or crop_rect.size.x <= 0 or crop_rect.size.y <= 0:
		push_warning("TKSpriteAtlasBuilder: build_rotated_from_image の引数が不正です。")
		return {}

	roughness = clampi(roughness, ROUGHNESS_MIN, ROUGHNESS_MAX)
	# 方向番号を 0〜255 へ正規化します（負値も正しく折り返します）。
	original_orientation = ((original_orientation % DIRECTION_RESOLUTION) + DIRECTION_RESOLUTION) % DIRECTION_RESOLUTION

	var frame_w: int = crop_rect.size.x
	var frame_h: int = crop_rect.size.y

	# 切り取り領域を独立した Image として抽出します（元画像は変更しません）。
	var src_cropped := Image.create_empty(frame_w, frame_h, false, Image.FORMAT_RGBA8)
	src_cropped.blit_rect(source, crop_rect, Vector2i.ZERO)

	# ── STEP 1: 方向0（右向き）フレームを生成します ────────────────────────────
	# 元画像は original_orientation 方向を向いているため、方向0へ揃えるには
	# 反時計回りに original_orientation 方向分だけ戻します。
	var dir0_angle_rad: float = float(-original_orientation) * (FULL_ROTATION_RAD / float(DIRECTION_RESOLUTION))
	var dir0_img: Image = rotate_image_nearest(src_cropped, dir0_angle_rad, frame_w, frame_h)

	# ── STEP 2: 45°回転時のはみ出し検査とキャンバス拡張（1回だけ）──────────────
	if roughness <= 5:
		var extent: Vector2 = _measure_diagonal_extent(dir0_img)
		var overflow_x: bool = extent.x > float(frame_w) * 0.5
		var overflow_y: bool = extent.y > float(frame_h) * 0.5
		if overflow_x or overflow_y:
			# 中心を保ったまま両側へ均等に拡張し、方向0フレームを作り直します。
			var new_w: int = maxi(frame_w, ceili(extent.x * 2.0 + 1.0))
			var new_h: int = maxi(frame_h, ceili(extent.y * 2.0 + 1.0))
			dir0_img = rotate_image_nearest(src_cropped, dir0_angle_rad, new_w, new_h)
			frame_w = new_w
			frame_h = new_h

	# ── STEP 3: 第1象限のフレームを方向昇順で生成します ────────────────────────
	# frames_per_quadrant = 64 >> roughness、フレームi の方向番号 = i << roughness。
	var frames_per_quadrant: int = DIRECTIONS_PER_QUADRANT >> roughness
	var q0_frames: Array = []
	q0_frames.resize(frames_per_quadrant)
	q0_frames[0] = dir0_img

	var has_progress: bool = progress_callback.is_valid()
	if has_progress:
		progress_callback.call(1, frames_per_quadrant)

	# 各フレームは常に元画像から1回の回転で作ります。二段階回転を避けることで、
	# 最近傍サンプリングの丸め誤差がフレーム間で累積しません。
	for frame_index in range(1, frames_per_quadrant):
		var dir_no: int = frame_index << roughness
		var angle_rad: float = float(dir_no - original_orientation) * (FULL_ROTATION_RAD / float(DIRECTION_RESOLUTION))
		q0_frames[frame_index] = rotate_image_nearest(src_cropped, angle_rad, frame_w, frame_h)
		if has_progress:
			progress_callback.call(frame_index + 1, frames_per_quadrant)

	# ── STEP 4: 反転演算で4象限（全方向）へ展開します ──────────────────────────
	#   象限0 (方向  0〜 63): src[qi]      反転なし
	#   象限1 (方向 64〜127): src[N-1-qi]  水平反転
	#   象限2 (方向128〜191): src[qi]      水平+垂直反転（=180°回転）
	#   象限3 (方向192〜255): src[N-1-qi]  垂直反転
	# 象限1・3でソースを逆順にするのは、象限の境界で絵が連続するようにするためです。
	var total_frames: int = frames_per_quadrant * 4
	var atlas_img := Image.create_empty(total_frames * frame_w, frame_h, false, Image.FORMAT_RGBA8)
	for atlas_index in range(total_frames):
		var quadrant: int = atlas_index / frames_per_quadrant
		var quadrant_index: int = atlas_index % frames_per_quadrant
		var source_index: int = quadrant_index
		var flip_h: bool = false
		var flip_v: bool = false
		match quadrant:
			0:
				source_index = quadrant_index
			1:
				source_index = frames_per_quadrant - 1 - quadrant_index
				flip_h = true
			2:
				source_index = quadrant_index
				flip_h = true
				flip_v = true
			_:
				source_index = frames_per_quadrant - 1 - quadrant_index
				flip_v = true
		# duplicate() してから反転します（第1象限の元フレームを壊さないため）。
		var frame_img: Image = (q0_frames[source_index] as Image).duplicate()
		if flip_h:
			frame_img.flip_x()
		if flip_v:
			frame_img.flip_y()
		atlas_img.blit_rect(frame_img, Rect2i(0, 0, frame_w, frame_h), Vector2i(atlas_index * frame_w, 0))

	# 中間画像への参照を切り、RefCounted に解放させます。
	q0_frames.clear()

	return _make_result(atlas_img, total_frames, frame_w, frame_h)
# [build_rotated_from_image]END


# [build_spin]
# 処理内容: 画像ファイルから、その場で一定速度で回るアニメのアトラスを生成します。
#           方向依存ではないコインやアイテム用です。
# 引数 image_path:            元画像のパスです。
# 引数 crop_rect:             切り取り領域です。
# 引数 original_orientation:  元画像が向いている方向番号です。
# 引数 frame_count:           生成するフレーム数です。
# 引数 visual_period_dirs:    見た目が1周する方向数です（256 = 360°、64 = 90°対称の絵向け）。
# 戻り値: build_rotated() と同じ Dictionary です。失敗時は空 Dictionary です。
static func build_spin(
	image_path: String,
	crop_rect: Rect2i,
	original_orientation: int,
	frame_count: int,
	visual_period_dirs: int = DIRECTION_RESOLUTION
) -> Dictionary:
	var cache_key: String = _make_cache_key("spin", image_path, crop_rect, original_orientation, frame_count, visual_period_dirs)
	if _atlas_cache.has(cache_key):
		return (_atlas_cache[cache_key] as Dictionary).duplicate()

	var source: Image = load_source_image(image_path)
	if source == null:
		push_warning("TKSpriteAtlasBuilder: 画像を読み込めませんでした: " + image_path)
		return {}

	var result: Dictionary = build_spin_from_image(source, crop_rect, original_orientation, frame_count, visual_period_dirs)
	if not result.is_empty():
		_atlas_cache[cache_key] = result
	return result.duplicate()
# [build_spin]END


# [build_spin_from_image]
# 処理内容: Image から均等回転アニメのアトラスを生成します。キャッシュは使いません。
#           フレームi の方向番号 = i * (visual_period_dirs / frame_count) です。
# 引数 source:               元画像です。
# 引数 crop_rect:            切り取り領域です。
# 引数 original_orientation: 元画像が向いている方向番号です。
# 引数 frame_count:          生成するフレーム数です。
# 引数 visual_period_dirs:   見た目が1周する方向数です。
# 戻り値: build_rotated() と同じ Dictionary です。失敗時は空 Dictionary です。
static func build_spin_from_image(
	source: Image,
	crop_rect: Rect2i,
	original_orientation: int,
	frame_count: int,
	visual_period_dirs: int = DIRECTION_RESOLUTION
) -> Dictionary:
	if source == null or frame_count <= 0 or visual_period_dirs <= 0 \
			or crop_rect.size.x <= 0 or crop_rect.size.y <= 0:
		push_warning("TKSpriteAtlasBuilder: build_spin_from_image の引数が不正です: frame_count=%d visual_period_dirs=%d" \
			% [frame_count, visual_period_dirs])
		return {}
	if visual_period_dirs % frame_count != 0:
		# 整数演算で方向を刻むため、割り切れないと最終フレームが1周に届きません。
		push_warning("TKSpriteAtlasBuilder: visual_period_dirs(%d) が frame_count(%d) で割り切れません。" \
			% [visual_period_dirs, frame_count])

	var frame_w: int = crop_rect.size.x
	var frame_h: int = crop_rect.size.y
	var src_cropped := Image.create_empty(frame_w, frame_h, false, Image.FORMAT_RGBA8)
	src_cropped.blit_rect(source, crop_rect, Vector2i.ZERO)

	var atlas_img := Image.create_empty(frame_count * frame_w, frame_h, false, Image.FORMAT_RGBA8)
	var direction_step: int = visual_period_dirs / frame_count
	for frame_index in range(frame_count):
		var dir_no: int = frame_index * direction_step
		var angle_rad: float = float(dir_no - original_orientation) * (FULL_ROTATION_RAD / float(DIRECTION_RESOLUTION))
		var frame_img: Image = rotate_image_nearest(src_cropped, angle_rad, frame_w, frame_h)
		atlas_img.blit_rect(frame_img, Rect2i(0, 0, frame_w, frame_h), Vector2i(frame_index * frame_w, 0))

	return _make_result(atlas_img, frame_count, frame_w, frame_h)
# [build_spin_from_image]END


# [rotate_image_nearest]
# 処理内容: Image を最近傍サンプリングで時計回りに回転し、指定サイズの新しい Image を
#           返します。新しい色は作らないため、ドット絵の輪郭と色数が保たれます。
#           範囲外は透明のままです。
# 引数 src:       回転元の Image です。
# 引数 angle_rad: 時計回りの回転角（ラジアン）。負値は反時計回りです。
# 引数 dst_w:     出力の幅です。
# 引数 dst_h:     出力の高さです。
# 戻り値: FORMAT_RGBA8 の回転済み Image です。
# 補足: 出力→入力の逆引きで対応付けるため、出力の全ピクセルを漏れなく塗れます。
static func rotate_image_nearest(src: Image, angle_rad: float, dst_w: int, dst_h: int) -> Image:
	var dst := Image.create_empty(dst_w, dst_h, false, Image.FORMAT_RGBA8)
	var src_w: int = src.get_width()
	var src_h: int = src.get_height()

	# cos/sin は内側ループで呼ばず、ここで一度だけ求めます。
	var cos_a: float = cos(angle_rad)
	var sin_a: float = sin(angle_rad)

	# 各画像の中心座標です。ピクセル中心で扱うため (幅-1)/2 を使います。
	var src_cx: float = float(src_w - 1) * 0.5
	var src_cy: float = float(src_h - 1) * 0.5
	var dst_cx: float = float(dst_w - 1) * 0.5
	var dst_cy: float = float(dst_h - 1) * 0.5

	for dy in range(dst_h):
		for dx in range(dst_w):
			var ox: float = float(dx) - dst_cx
			var oy: float = float(dy) - dst_cy
			# 逆回転で元画像の対応座標を求め、最近傍整数へ丸めます。
			var sx: int = roundi(ox * cos_a + oy * sin_a + src_cx)
			var sy: int = roundi(-ox * sin_a + oy * cos_a + src_cy)
			if sx >= 0 and sx < src_w and sy >= 0 and sy < src_h:
				dst.set_pixel(dx, dy, src.get_pixel(sx, sy))
	return dst
# [rotate_image_nearest]END


# [direction_to_frame_index]
# 処理内容: 方向番号を、生成済みアトラスのフレーム番号へ変換します。
# 引数 direction_no: 方向番号です（範囲外は 0〜255 へ折り返します）。
# 引数 total_frames: アトラスの総フレーム数です。
# 戻り値: フレーム番号です。total_frames が 0 以下なら 0 です。
static func direction_to_frame_index(direction_no: int, total_frames: int) -> int:
	if total_frames <= 0:
		return 0
	var normalized: int = ((direction_no % DIRECTION_RESOLUTION) + DIRECTION_RESOLUTION) % DIRECTION_RESOLUTION
	return normalized * total_frames / DIRECTION_RESOLUTION
# [direction_to_frame_index]END


# [load_source_image]
# 処理内容: 元画像を Image として読み込みます。インポート済みリソースと、インポート
#           されていない生ファイル（user:// や絶対パス）の両方に対応します。
# 引数 image_path: 画像のパスです。
# 戻り値: Image。読み込めない場合は null です。
static func load_source_image(image_path: String) -> Image:
	if ResourceLoader.exists(image_path):
		var res = load(image_path)
		if res is Texture2D:
			return (res as Texture2D).get_image()
		if res is Image:
			return res as Image
	# インポートされていないファイルは直接読み込みます。
	var image := Image.new()
	if image.load(image_path) == OK:
		return image
	return null
# [load_source_image]END


# [save_atlas_png]
# 処理内容: 生成結果を PNG として書き出します。実行時生成のコストを避けたい場合に、
#           生成済みアトラスを静的アセットへ差し替えるために使います。
# 引数 result: build_rotated() / build_spin() の戻り値です。
# 引数 path:   保存先パスです。
# 戻り値: 成功時 true です。
static func save_atlas_png(result: Dictionary, path: String) -> bool:
	var image = result.get("image", null)
	if not (image is Image):
		push_error("TKSpriteAtlasBuilder: save_atlas_png に画像が含まれていません。")
		return false
	return (image as Image).save_png(path) == OK
# [save_atlas_png]END


# [clear_cache]
# 処理内容: 生成結果のプロセス内キャッシュを空にします。
# 戻り値: なし
static func clear_cache() -> void:
	_atlas_cache.clear()
# [clear_cache]END


# [get_cache_count]
# 処理内容: キャッシュに保持している生成結果の件数を返します（デバッグ・テスト用）。
# 戻り値: 件数です。
static func get_cache_count() -> int:
	return _atlas_cache.size()
# [get_cache_count]END


# [_make_result]
# 処理内容: 生成したアトラス画像から、共通の戻り値 Dictionary を組み立てます。
#           フレームは横一列に並ぶため、フレームi の矩形は (i*w, 0, w, h) です。
# 引数 atlas_img:    生成したアトラス画像です。
# 引数 total_frames: フレーム数です。
# 引数 frame_w:      1フレームの幅です。
# 引数 frame_h:      1フレームの高さです。
# 戻り値: { "texture", "frames", "image", "frame_size", "total_frames" } です。
static func _make_result(atlas_img: Image, total_frames: int, frame_w: int, frame_h: int) -> Dictionary:
	var frames: Array[Rect2] = []
	for frame_index in range(total_frames):
		frames.append(Rect2(float(frame_index * frame_w), 0.0, float(frame_w), float(frame_h)))
	return {
		"texture": ImageTexture.create_from_image(atlas_img),
		"frames": frames,
		"image": atlas_img,
		"frame_size": Vector2i(frame_w, frame_h),
		"total_frames": total_frames
	}
# [_make_result]END


# [_measure_diagonal_extent]
# 処理内容: 45°回転したときに不透明ピクセルが中心からどこまで届くかを実測します。
#           角が欠けるかどうかの判定に使います（45°が最も張り出す角度です）。
# 引数 image: 検査する画像です。
# 戻り値: 中心からの最大到達距離 Vector2(x, y) です。
static func _measure_diagonal_extent(image: Image) -> Vector2:
	const COS45: float = 0.70710678118654752
	const SIN45: float = 0.70710678118654752
	var width: int = image.get_width()
	var height: int = image.get_height()
	var center_x: float = float(width - 1) * 0.5
	var center_y: float = float(height - 1) * 0.5
	var max_extent_x: float = 0.0
	var max_extent_y: float = 0.0
	for py in range(height):
		for px in range(width):
			if image.get_pixel(px, py).a > 0.0:
				var ox: float = float(px) - center_x
				var oy: float = float(py) - center_y
				max_extent_x = maxf(max_extent_x, absf(ox * COS45 - oy * SIN45))
				max_extent_y = maxf(max_extent_y, absf(ox * SIN45 + oy * COS45))
	return Vector2(max_extent_x, max_extent_y)
# [_measure_diagonal_extent]END


# [_make_cache_key]
# 処理内容: 生成パラメータからキャッシュキー文字列を作ります。
# 引数 kind:        "rot" / "spin" の種別です。
# 引数 image_path:  元画像のパスです。
# 引数 crop_rect:   切り取り領域です。
# 引数 orientation: 元画像の方向番号です。
# 引数 param_a:     rot なら roughness、spin なら frame_count です。
# 引数 param_b:     spin の visual_period_dirs です（rot では 0）。
# 戻り値: キャッシュキー文字列です。
static func _make_cache_key(kind: String, image_path: String, crop_rect: Rect2i, orientation: int, param_a: int, param_b: int) -> String:
	return "%s|%s|%d,%d,%d,%d|%d|%d|%d" % [
		kind, image_path,
		crop_rect.position.x, crop_rect.position.y, crop_rect.size.x, crop_rect.size.y,
		orientation, param_a, param_b
	]
# [_make_cache_key]END
