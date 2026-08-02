# make_screenshots.gd — 紹介用スクリーンショットの撮影ツール
#
# 実行方法（--headless は付けません。描画結果を読み出すため実ウィンドウが必要です）:
#   Godot --path <プロジェクト> --script res://tools/make_screenshots.gd \
#         -- <シーンパス> <出力PNGパス> [スプライト数] [切り出し高さ]
#
# 指定シーンを起動し、CAPTURE_FRAME フレーム目の画面を PNG へ保存して終了します。
# 第3引数を渡し、かつシーンが _change_sprite_count() を持つ場合だけ、撮影前に体数を変更します。
# 第4引数を渡すと、画面上部からその高さ分だけを切り出して保存します（余白の除去用）。

extends SceneTree

# 撮影するフレーム番号です。アニメーションが動き出し、FPS 表示が安定するまで待ちます。
const CAPTURE_FRAME: int = 180

var _output_path: String = ""
var _sprite_count: int = -1
var _crop_height: int = 0
var _scene_root: Node = null
var _frame: int = 0


# [_initialize]
# 処理内容: 引数を読み、対象シーンを起動します。
# 戻り値: なし
func _initialize() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.size() < 2:
		print("make_screenshots: 引数が足りません。-- <シーンパス> <出力PNGパス> [スプライト数]")
		quit(1)
		return

	_output_path = args[1]
	if args.size() >= 3:
		_sprite_count = args[2].to_int()
	if args.size() >= 4:
		_crop_height = args[3].to_int()

	var packed: PackedScene = load(args[0])
	if packed == null:
		print("make_screenshots: シーンを読み込めません: " + args[0])
		quit(1)
		return

	_scene_root = packed.instantiate()
	root.add_child(_scene_root)
# [_initialize]END


# [_process]
# 処理内容: 一定フレーム待ってから画面を保存し、終了します。
# 引数 _delta: フレーム時間です（未使用）。
# 戻り値: true を返すと SceneTree が終了します。
func _process(_delta: float) -> bool:
	_frame += 1

	# 体数の変更は、シーンの _ready が終わった直後の1回だけ行います。
	if _frame == 2 and _sprite_count > 0:
		if _scene_root != null and _scene_root.has_method("_change_sprite_count"):
			_scene_root._change_sprite_count(_sprite_count - _scene_root.get("_active_count"))

	if _frame < CAPTURE_FRAME:
		return false

	var image: Image = root.get_texture().get_image()
	if image == null:
		print("make_screenshots: 画面を取得できませんでした。")
		return true

	if _crop_height > 0 and _crop_height < image.get_height():
		image = image.get_region(Rect2i(0, 0, image.get_width(), _crop_height))

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_output_path.get_base_dir()))
	var result: int = image.save_png(_output_path)
	if result != OK:
		print("make_screenshots: 保存に失敗しました: %d" % result)
		return true

	print("make_screenshots: %s を保存しました (%dx%d)" % [_output_path, image.get_width(), image.get_height()])
	return true
# [_process]END
