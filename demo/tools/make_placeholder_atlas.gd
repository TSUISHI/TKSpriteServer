# make_placeholder_atlas.gd — デモ用プレースホルダ画像の生成ツール
#
# 実行方法:
#   Godot --headless --path <プロジェクト> --script res://demo/tools/make_placeholder_atlas.gd
#
# res://demo/assets/placeholder_atlas.png を生成します。16x16 のセルを 5列 x 5行 に
# 並べた 80x80 の画像で、定義JSON demo/devdata/sprite_definitions.json が参照します。
# 生成物はリポジトリに含めるため、通常は再実行の必要はありません。
#
#   行0 (y= 0): PULSE  — 大きさの変わる円 5フレーム（layout: row）
#   行1 (y=16): SHAPES — 三角・四角枠・星（layout: frames）
#   行2 (y=32): RING   — 円環 1枚（layout: single）
#   行3 (y=48): ARROW  — 下向きの矢印 1枚（layout: rotated の元絵）
#   行4 (y=64): COIN   — 非対称な菱形 1枚（layout: spin の元絵）
#
# 素材は幾何形状のみで、既存ゲームの画像は一切使いません。

extends SceneTree

const OUTPUT_PATH: String = "res://demo/assets/placeholder_atlas.png"
const CELL: int = 16

const COLOR_MAIN: Color = Color(0.90, 0.94, 1.00, 1.0)
const COLOR_ACCENT: Color = Color(1.00, 0.55, 0.25, 1.0)
const COLOR_SUB: Color = Color(0.35, 0.80, 1.00, 1.0)


# [_initialize]
# 処理内容: アトラス画像を組み立てて PNG として保存します。
# 戻り値: なし
func _initialize() -> void:
	var image := Image.create_empty(CELL * 5, CELL * 5, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))

	draw_pulse_row(image)
	draw_shapes_row(image)
	draw_ring(image)
	draw_arrow(image)
	draw_coin(image)

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT_PATH.get_base_dir()))
	var result: int = image.save_png(OUTPUT_PATH)
	if result != OK:
		print("make_placeholder_atlas: 保存に失敗しました: %d" % result)
		quit(1)
		return
	print("make_placeholder_atlas: %s を生成しました (%dx%d)" % [OUTPUT_PATH, image.get_width(), image.get_height()])
	quit(0)
# [_initialize]END


# [fill_disc]
# 処理内容: セル内に塗りつぶし円を描きます。
# 引数 image:  描画先です。
# 引数 origin: セルの左上座標です。
# 引数 radius: 半径（ピクセル）です。
# 引数 color:  色です。
# 戻り値: なし
func fill_disc(image: Image, origin: Vector2i, radius: float, color: Color) -> void:
	var center: float = float(CELL - 1) * 0.5
	for y in range(CELL):
		for x in range(CELL):
			var dx: float = float(x) - center
			var dy: float = float(y) - center
			if dx * dx + dy * dy <= radius * radius:
				image.set_pixel(origin.x + x, origin.y + y, color)
# [fill_disc]END


# [draw_pulse_row]
# 処理内容: 行0 に、半径の異なる円を5フレーム分描きます（row レイアウト用）。
# 引数 image: 描画先です。
# 戻り値: なし
func draw_pulse_row(image: Image) -> void:
	for frame_index in range(5):
		var radius: float = 2.0 + float(frame_index) * 1.2
		var color: Color = COLOR_MAIN.lerp(COLOR_ACCENT, float(frame_index) / 4.0)
		fill_disc(image, Vector2i(frame_index * CELL, 0), radius, color)
# [draw_pulse_row]END


# [draw_shapes_row]
# 処理内容: 行1 に三角・四角枠・星を描きます（frames レイアウト用）。
# 引数 image: 描画先です。
# 戻り値: なし
func draw_shapes_row(image: Image) -> void:
	var top: int = CELL

	# 上向きの三角です。
	for y in range(2, 14):
		var half: int = (y - 2) / 2
		for x in range(7 - half, 8 + half + 1):
			image.set_pixel(x, top + y, COLOR_SUB)

	# 四角の枠です。
	for index in range(3, 13):
		image.set_pixel(CELL + index, top + 3, COLOR_MAIN)
		image.set_pixel(CELL + index, top + 12, COLOR_MAIN)
		image.set_pixel(CELL + 3, top + index, COLOR_MAIN)
		image.set_pixel(CELL + 12, top + index, COLOR_MAIN)

	# 4方向に腕を伸ばした星です。
	var star_origin := Vector2i(CELL * 2, top)
	for length in range(0, 7):
		image.set_pixel(star_origin.x + 7, star_origin.y + 7 - length, COLOR_ACCENT)
		image.set_pixel(star_origin.x + 7, star_origin.y + 7 + length, COLOR_ACCENT)
		image.set_pixel(star_origin.x + 7 - length, star_origin.y + 7, COLOR_ACCENT)
		image.set_pixel(star_origin.x + 7 + length, star_origin.y + 7, COLOR_ACCENT)
	for length in range(1, 4):
		image.set_pixel(star_origin.x + 7 - length, star_origin.y + 7 - length, COLOR_ACCENT)
		image.set_pixel(star_origin.x + 7 + length, star_origin.y + 7 - length, COLOR_ACCENT)
		image.set_pixel(star_origin.x + 7 - length, star_origin.y + 7 + length, COLOR_ACCENT)
		image.set_pixel(star_origin.x + 7 + length, star_origin.y + 7 + length, COLOR_ACCENT)
# [draw_shapes_row]END


# [draw_ring]
# 処理内容: 行2 に円環を描きます（single レイアウト用）。
# 引数 image: 描画先です。
# 戻り値: なし
func draw_ring(image: Image) -> void:
	var origin := Vector2i(0, CELL * 2)
	fill_disc(image, origin, 6.5, COLOR_SUB)
	fill_disc(image, origin, 3.5, Color(0, 0, 0, 0))
# [draw_ring]END


# [draw_arrow]
# 処理内容: 行3 に下向きの矢印を描きます（rotated の元絵、方向番号 64 = 真下）。
#           回転しても中心がずれないよう、セル中心を基準に描きます。
# 引数 image: 描画先です。
# 戻り値: なし
func draw_arrow(image: Image) -> void:
	var origin := Vector2i(0, CELL * 3)
	# 縦の軸です（上から下へ）。
	for y in range(3, 12):
		image.set_pixel(origin.x + 7, origin.y + y, COLOR_MAIN)
		image.set_pixel(origin.x + 8, origin.y + y, COLOR_MAIN)
	# 下端の矢じりです。
	for offset in range(0, 4):
		for x in range(7 - offset, 9 + offset):
			image.set_pixel(origin.x + x, origin.y + 8 + offset, COLOR_ACCENT)
	# 左右非対称にするための印です（回転方向が目で分かるようにします）。
	image.set_pixel(origin.x + 10, origin.y + 5, COLOR_SUB)
	image.set_pixel(origin.x + 10, origin.y + 6, COLOR_SUB)
# [draw_arrow]END


# [draw_coin]
# 処理内容: 行4 に非対称な菱形を描きます（spin の元絵）。
# 引数 image: 描画先です。
# 戻り値: なし
func draw_coin(image: Image) -> void:
	var origin := Vector2i(0, CELL * 4)
	# 中心から広がる菱形です。
	for y in range(CELL):
		var distance_y: int = absi(y - 7)
		var half: int = 6 - distance_y
		if half < 0:
			continue
		for x in range(7 - half, 8 + half):
			image.set_pixel(origin.x + x, origin.y + y, COLOR_ACCENT)
	# 片側だけに入れる切り欠きです（回転が見て分かるようにします）。
	for x in range(8, 12):
		image.set_pixel(origin.x + x, origin.y + 7, COLOR_MAIN)
# [draw_coin]END
