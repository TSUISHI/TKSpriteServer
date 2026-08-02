# test_atlas_builder.gd — TKSpriteAtlasBuilder の自己完結テスト
#
# 実行方法:
#   Godot --headless --path <プロジェクト> --script res://tests/test_atlas_builder.gd
#
# 画像アセットには依存しません（テスト内で手続き的に画像を作ります）。

extends SceneTree

var failure_count: int = 0


# [_initialize]
# 処理内容: 全テストを順に実行し、失敗が1件でもあれば終了コード1で終了します。
# 戻り値: なし
func _initialize() -> void:
	test_rotate_image_nearest()
	test_build_rotated()
	test_canvas_expansion()
	test_quadrant_symmetry()
	test_build_spin()
	test_cache_and_png()

	if failure_count == 0:
		print("test_atlas_builder: ALL PASS")
	else:
		print("test_atlas_builder: FAILED %d" % failure_count)
		quit(1)
		return
	quit(0)
# [_initialize]END


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


# [make_arrow_image]
# 処理内容: 右向きの非対称な矢印を描いたテスト用画像を作ります。中心からの
#           張り出しが小さいため、キャンバス拡張は起きません。
# 引数 size: 正方形の一辺のピクセル数（奇数を想定）。
# 戻り値: FORMAT_RGBA8 の Image です。
func make_arrow_image(size: int) -> Image:
	var image := Image.create_empty(size, size, false, Image.FORMAT_RGBA8)
	var center: int = size / 2
	# 中心から右へ伸びる軸と、その先端の1px（左右非対称にするため上側だけ）を描きます。
	for x in range(center, size - 2):
		image.set_pixel(x, center, Color(1, 1, 1, 1))
	image.set_pixel(size - 3, center - 1, Color(1, 0, 0, 1))
	return image
# [make_arrow_image]END


# [test_rotate_image_nearest]
# 処理内容: 回転の符号（時計回り）と中心の保存を確認します。
# 戻り値: なし
func test_rotate_image_nearest() -> void:
	var image := Image.create_empty(5, 5, false, Image.FORMAT_RGBA8)
	# 中心(2,2) の右隣 (4,2) に印を置きます。
	image.set_pixel(4, 2, Color(1, 1, 1, 1))

	var identity: Image = TKSpriteAtlasBuilder.rotate_image_nearest(image, 0.0, 5, 5)
	check(identity.get_pixel(4, 2).a > 0.0, "0ラジアン回転で位置が変わった")

	# 時計回り90°: 右(3時) → 下(6時) へ移ります。
	var rotated: Image = TKSpriteAtlasBuilder.rotate_image_nearest(image, PI * 0.5, 5, 5)
	check(rotated.get_pixel(2, 4).a > 0.0, "時計回り90°で右の印が下へ来ていない")
	check(rotated.get_pixel(4, 2).a == 0.0, "回転後も元位置に印が残っている")

	# 反時計回り90°: 右 → 上 です。
	var counter: Image = TKSpriteAtlasBuilder.rotate_image_nearest(image, -PI * 0.5, 5, 5)
	check(counter.get_pixel(2, 0).a > 0.0, "反時計回り90°で右の印が上へ来ていない")

	# 出力サイズ指定が効いていることを確認します。
	var resized: Image = TKSpriteAtlasBuilder.rotate_image_nearest(image, 0.0, 9, 7)
	check(resized.get_width() == 9 and resized.get_height() == 7, "出力サイズ指定が反映されていない")
# [test_rotate_image_nearest]END


# [test_build_rotated]
# 処理内容: roughness ごとのフレーム数と、方向番号→フレーム番号の対応を確認します。
# 戻り値: なし
func test_build_rotated() -> void:
	var source: Image = make_arrow_image(17)
	var result: Dictionary = TKSpriteAtlasBuilder.build_rotated_from_image(source, Rect2i(0, 0, 17, 17), 0, 4)
	check(not result.is_empty(), "build_rotated_from_image が失敗した")
	check(int(result.get("total_frames", 0)) == 16, "roughness=4 のフレーム数が 16 でない: %d" % int(result.get("total_frames", 0)))

	var frames: Array = result.get("frames", [])
	check(frames.size() == 16, "frames の要素数が 16 でない")
	var frame_size: Vector2i = result.get("frame_size", Vector2i.ZERO)
	check(frames[0] == Rect2(0, 0, frame_size.x, frame_size.y), "先頭フレーム矩形が不正")
	check(frames[15] == Rect2(15 * frame_size.x, 0, frame_size.x, frame_size.y), "最終フレーム矩形が不正")

	var texture = result.get("texture", null)
	check(texture is ImageTexture, "texture が ImageTexture でない")
	check((texture as ImageTexture).get_width() == 16 * frame_size.x, "アトラス幅がフレーム幅×枚数と一致しない")

	# 進捗コールバックが最後まで呼ばれることを確認します。
	var progress: Array = [0, 0]
	var callback: Callable = func(done: int, total: int) -> void:
		progress[0] = done
		progress[1] = total
	TKSpriteAtlasBuilder.build_rotated_from_image(source, Rect2i(0, 0, 17, 17), 0, 5, callback)
	check(progress[1] == 2 and progress[0] == 2, "進捗コールバックの値が不正: %s" % str(progress))

	# roughness の両端です。
	var coarse: Dictionary = TKSpriteAtlasBuilder.build_rotated_from_image(source, Rect2i(0, 0, 17, 17), 0, 6)
	check(int(coarse.get("total_frames", 0)) == 4, "roughness=6 のフレーム数が 4 でない")
	var fine: Dictionary = TKSpriteAtlasBuilder.build_rotated_from_image(source, Rect2i(0, 0, 17, 17), 0, 0)
	check(int(fine.get("total_frames", 0)) == 256, "roughness=0 のフレーム数が 256 でない")

	# 方向番号 → フレーム番号の対応です（16枚なら 1フレーム = 16方向）。
	check(TKSpriteAtlasBuilder.direction_to_frame_index(0, 16) == 0, "方向0 のフレーム番号が 0 でない")
	check(TKSpriteAtlasBuilder.direction_to_frame_index(64, 16) == 4, "方向64(下) のフレーム番号が 4 でない")
	check(TKSpriteAtlasBuilder.direction_to_frame_index(128, 16) == 8, "方向128(左) のフレーム番号が 8 でない")
	check(TKSpriteAtlasBuilder.direction_to_frame_index(192, 16) == 12, "方向192(上) のフレーム番号が 12 でない")
	check(TKSpriteAtlasBuilder.direction_to_frame_index(-64, 16) == 12, "負の方向番号が折り返されていない")
	check(TKSpriteAtlasBuilder.direction_to_frame_index(255, 256) == 255, "roughness=0 の 1:1 対応になっていない")
# [test_build_rotated]END


# [test_canvas_expansion]
# 処理内容: 45°回転で角がはみ出す絵に対し、キャンバスが中心を保ったまま拡張される
#           ことを確認します。
# 戻り値: なし
func test_canvas_expansion() -> void:
	# 全面を塗った 16x16 は 45°回転で対角がはみ出します。
	var filled := Image.create_empty(16, 16, false, Image.FORMAT_RGBA8)
	filled.fill(Color(1, 1, 1, 1))
	var expanded: Dictionary = TKSpriteAtlasBuilder.build_rotated_from_image(filled, Rect2i(0, 0, 16, 16), 0, 4)
	var expanded_size: Vector2i = expanded.get("frame_size", Vector2i.ZERO)
	check(expanded_size.x > 16 and expanded_size.y > 16, "はみ出す絵でキャンバスが拡張されていない: %s" % str(expanded_size))

	# 中心付近だけに絵がある場合は拡張されません。
	var small := Image.create_empty(16, 16, false, Image.FORMAT_RGBA8)
	small.set_pixel(8, 8, Color(1, 1, 1, 1))
	small.set_pixel(9, 8, Color(1, 1, 1, 1))
	var kept: Dictionary = TKSpriteAtlasBuilder.build_rotated_from_image(small, Rect2i(0, 0, 16, 16), 0, 4)
	check((kept.get("frame_size", Vector2i.ZERO) as Vector2i) == Vector2i(16, 16), "拡張不要な絵でキャンバスが変わった")

	# roughness=6 のときは拡張検査を行いません（移植元と同じ挙動）。
	var no_check: Dictionary = TKSpriteAtlasBuilder.build_rotated_from_image(filled, Rect2i(0, 0, 16, 16), 0, 6)
	check((no_check.get("frame_size", Vector2i.ZERO) as Vector2i) == Vector2i(16, 16), "roughness=6 でキャンバスが拡張された")
# [test_canvas_expansion]END


# [test_quadrant_symmetry]
# 処理内容: 第1象限だけを実回転し、残りを反転で展開する規則どおりになっているかを
#           画素単位で確認します。
# 戻り値: なし
func test_quadrant_symmetry() -> void:
	var source: Image = make_arrow_image(17)
	var result: Dictionary = TKSpriteAtlasBuilder.build_rotated_from_image(source, Rect2i(0, 0, 17, 17), 0, 4)
	var atlas: Image = result.get("image", null)
	check(atlas != null, "アトラス画像が返っていない")
	if atlas == null:
		return
	var frame_size: Vector2i = result.get("frame_size", Vector2i.ZERO)

	# フレーム8（方向128 = 左）はフレーム0（方向0 = 右）の水平+垂直反転と一致します。
	var frame0: Image = Image.create_empty(frame_size.x, frame_size.y, false, Image.FORMAT_RGBA8)
	frame0.blit_rect(atlas, Rect2i(0, 0, frame_size.x, frame_size.y), Vector2i.ZERO)
	var frame8: Image = Image.create_empty(frame_size.x, frame_size.y, false, Image.FORMAT_RGBA8)
	frame8.blit_rect(atlas, Rect2i(8 * frame_size.x, 0, frame_size.x, frame_size.y), Vector2i.ZERO)

	var flipped: Image = frame0.duplicate()
	flipped.flip_x()
	flipped.flip_y()
	check(flipped.get_data() == frame8.get_data(), "方向128 のフレームが方向0 の180°反転と一致しない")

	# 元絵が右向きなので、方向0 のフレームは元絵とほぼ同じはずです（回転角0）。
	check(frame0.get_pixel(frame_size.x / 2, frame_size.y / 2).a > 0.0, "方向0 のフレーム中心が透明になっている")
# [test_quadrant_symmetry]END


# [test_build_spin]
# 処理内容: 均等回転アニメのフレーム数と、割り切れない指定の扱いを確認します。
# 戻り値: なし
func test_build_spin() -> void:
	var source: Image = make_arrow_image(17)
	var result: Dictionary = TKSpriteAtlasBuilder.build_spin_from_image(source, Rect2i(0, 0, 17, 17), 0, 8, 256)
	check(int(result.get("total_frames", 0)) == 8, "spin のフレーム数が 8 でない")
	check((result.get("frame_size", Vector2i.ZERO) as Vector2i) == Vector2i(17, 17), "spin でフレームサイズが変わった")
	check((result.get("frames", []) as Array).size() == 8, "spin の frames 要素数が 8 でない")

	# 90°対称の絵向けに visual_period_dirs を縮められます。
	var quarter: Dictionary = TKSpriteAtlasBuilder.build_spin_from_image(source, Rect2i(0, 0, 17, 17), 0, 4, 64)
	check(int(quarter.get("total_frames", 0)) == 4, "visual_period_dirs=64 のフレーム数が 4 でない")

	# 不正な引数は空 Dictionary です。
	check(TKSpriteAtlasBuilder.build_spin_from_image(source, Rect2i(0, 0, 17, 17), 0, 0, 256).is_empty(), "frame_count=0 が拒否されていない")
	check(TKSpriteAtlasBuilder.build_rotated_from_image(source, Rect2i(0, 0, 0, 0), 0, 4).is_empty(), "空の crop_rect が拒否されていない")
# [test_build_spin]END


# [test_cache_and_png]
# 処理内容: PNG書き出しと、ファイルパス経由の生成キャッシュを確認します。
# 戻り値: なし
func test_cache_and_png() -> void:
	TKSpriteAtlasBuilder.clear_cache()
	check(TKSpriteAtlasBuilder.get_cache_count() == 0, "clear_cache 後もキャッシュが残っている")

	# 元画像を PNG として書き出し、パス経由の読み込み経路を通します。
	var source: Image = make_arrow_image(17)
	var source_path: String = "user://tk_test_arrow.png"
	check(source.save_png(source_path) == OK, "テスト用PNGの保存に失敗")

	var first: Dictionary = TKSpriteAtlasBuilder.build_rotated(source_path, Rect2i(0, 0, 17, 17), 0, 4)
	check(not first.is_empty(), "パス経由の build_rotated が失敗した")
	check(TKSpriteAtlasBuilder.get_cache_count() == 1, "生成結果がキャッシュされていない")

	var second: Dictionary = TKSpriteAtlasBuilder.build_rotated(source_path, Rect2i(0, 0, 17, 17), 0, 4)
	check(TKSpriteAtlasBuilder.get_cache_count() == 1, "同一パラメータで再生成された")
	check(second.get("texture", null) == first.get("texture", null), "キャッシュが同じテクスチャを返していない")

	# パラメータが変われば別エントリになります。
	TKSpriteAtlasBuilder.build_rotated(source_path, Rect2i(0, 0, 17, 17), 0, 5)
	check(TKSpriteAtlasBuilder.get_cache_count() == 2, "パラメータ違いが別エントリになっていない")

	# 生成済みアトラスの PNG 書き出しです。
	var atlas_path: String = "user://tk_test_atlas.png"
	check(TKSpriteAtlasBuilder.save_atlas_png(first, atlas_path), "アトラスPNGの書き出しに失敗")
	check(FileAccess.file_exists(atlas_path), "アトラスPNGが作られていない")
	check(not TKSpriteAtlasBuilder.save_atlas_png({}, atlas_path), "画像なしの書き出しが成功扱いになった")

	# 読み込めないパスは空 Dictionary です。
	check(TKSpriteAtlasBuilder.build_rotated("user://tk_test_missing.png", Rect2i(0, 0, 8, 8)).is_empty(), "存在しないパスが拒否されていない")

	TKSpriteAtlasBuilder.clear_cache()
# [test_cache_and_png]END
