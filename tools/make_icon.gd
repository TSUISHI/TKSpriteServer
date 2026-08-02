# make_icon.gd — Asset Library 用アイコン画像の生成ツール
#
# 実行方法:
#   Godot --headless --path <プロジェクト> --script res://tools/make_icon.gd
#
# res://media/icon.png を生成します。16x16 のドット絵を 16 倍に拡大した
# 256x256 の PNG で、拡大は最近傍のため輪郭が滲みません。
#
# 図案は「奥・中・手前の 3 プレーンへ積まれたスプライトが右上へ流れていく」様子を
# 3 枚の四角で表したものです。素材は幾何形状のみで、既存ゲームの画像は使いません。

extends SceneTree

const OUTPUT_PATH: String = "res://media/icon.png"

# 元絵の一辺（ドット数）です。
const GRID: int = 16
# 出力時の拡大率です。GRID * SCALE が最終的な辺の長さになります。
const SCALE: int = 16

const COLOR_BG: Color = Color(0.07, 0.08, 0.13, 1.0)
const COLOR_BACK: Color = Color(0.20, 0.35, 0.65, 1.0)
const COLOR_MID: Color = Color(0.25, 0.75, 0.95, 1.0)
const COLOR_FRONT: Color = Color(1.00, 0.60, 0.25, 1.0)

# 四角 1 枚の一辺（ドット数）です。
const BLOCK: int = 5


# [_initialize]
# 処理内容: アイコンを組み立てて PNG として保存します。
# 戻り値: なし
func _initialize() -> void:
	var image := Image.create_empty(GRID, GRID, false, Image.FORMAT_RGBA8)
	image.fill(COLOR_BG)

	# 角を 1 ドットだけ落として、四角い板に見えないようにします。
	image.set_pixel(0, 0, Color(0, 0, 0, 0))
	image.set_pixel(GRID - 1, 0, Color(0, 0, 0, 0))
	image.set_pixel(0, GRID - 1, Color(0, 0, 0, 0))
	image.set_pixel(GRID - 1, GRID - 1, Color(0, 0, 0, 0))

	# 奥から手前の順に描きます。後から描く四角の縁が手前側の区切りになります。
	draw_block(image, Vector2i(1, 9), COLOR_BACK)
	draw_block(image, Vector2i(5, 5), COLOR_MID)
	draw_block(image, Vector2i(9, 1), COLOR_FRONT)

	var scaled: Image = upscale(image)

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT_PATH.get_base_dir()))
	var result: int = scaled.save_png(OUTPUT_PATH)
	if result != OK:
		print("make_icon: 保存に失敗しました: %d" % result)
		quit(1)
		return
	print("make_icon: %s を生成しました (%dx%d)" % [OUTPUT_PATH, scaled.get_width(), scaled.get_height()])
	quit(0)
# [_initialize]END


# [draw_block]
# 処理内容: スプライト 1 枚を表す四角を描きます。周囲 1 ドットを背景色で塗ってから
#           本体を塗るため、重なっても隣の四角と分離して見えます。
# 引数 image:  描画先です。
# 引数 origin: 本体の左上ドット座標です。
# 引数 color:  本体の色です。
# 戻り値: なし
func draw_block(image: Image, origin: Vector2i, color: Color) -> void:
	# 区切りの縁です。
	for y in range(origin.y - 1, origin.y + BLOCK + 1):
		for x in range(origin.x - 1, origin.x + BLOCK + 1):
			if x < 0 or y < 0 or x >= GRID or y >= GRID:
				continue
			image.set_pixel(x, y, COLOR_BG)

	# 本体です。上辺と左辺だけ明るくして、ドット絵らしい立体感を付けます。
	var highlight: Color = color.lightened(0.35)
	for y in range(origin.y, origin.y + BLOCK):
		for x in range(origin.x, origin.x + BLOCK):
			if x < 0 or y < 0 or x >= GRID or y >= GRID:
				continue
			if x == origin.x or y == origin.y:
				image.set_pixel(x, y, highlight)
			else:
				image.set_pixel(x, y, color)
# [draw_block]END


# [upscale]
# 処理内容: 元絵を SCALE 倍に最近傍で拡大します。Image.resize() を使わないのは、
#           補間が入るとドットの輪郭が滲むためです。
# 引数 source: 元絵です。
# 戻り値: 拡大後の画像です。
func upscale(source: Image) -> Image:
	var size: int = GRID * SCALE
	var result := Image.create_empty(size, size, false, Image.FORMAT_RGBA8)
	result.fill(Color(0, 0, 0, 0))
	for y in range(size):
		for x in range(size):
			result.set_pixel(x, y, source.get_pixel(x / SCALE, y / SCALE))
	return result
# [upscale]END
