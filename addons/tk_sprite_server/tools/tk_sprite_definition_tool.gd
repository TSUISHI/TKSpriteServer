@tool
extends Control
class_name TKSpriteDefinitionTool

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  tk_sprite_definition_tool.gd  —  スプライト定義JSONの編集ツール           ║
# ╠═══════════════════════════════════════════════════════════════════════════╣
# ║  実行時ツールとしても、エディタ下部パネルとしても使えます。               ║
# ║                                                                            ║
# ║  【役割】                                                                  ║
# ║  ・sprite_definitions.json を視覚的に編集する開発時専用ツールです。        ║
# ║  ・ゲーム本編とは完全に独立して動きます（SpriteServer等は使いません）。    ║
# ║                                                                            ║
# ║  【画面構成】                                                              ║
# ║   ┌──────────┬────────────────────┬──────────┐                             ║
# ║   │①一覧      │②アトラスプレビュー │③プロパティ│                             ║
# ║   ├──────────┴────────────────────┴──────────┤                             ║
# ║   │④アニメ/回転プレビュー  ⑤ステータスバー   │                             ║
# ║   └───────────────────────────────────────────┘                            ║
# ║                                                                            ║
# ║  【主な操作】                                                              ║
# ║   マウス   : 矩形内ドラッグ=移動 / ハンドル=リサイズ / 空き領域ドラッグ=新規 ║
# ║              ホイール=ズーム / 中ボタンドラッグ=パン                       ║
# ║   キー     : 矢印=1px移動 / Shift+矢印=8px / Ctrl+矢印=リサイズ            ║
# ║              PgUp/PgDn=フレーム / Tab=スプライト切替 / Ctrl+S=保存         ║
# ║              Ctrl+F=検索 / Ctrl+Z=Undo / Ctrl+Y=Redo / ESC=終了              ║
# ║   パッド   : 十字=1px / LB+十字=8px / RB+十字=リサイズ / X,Y=フレーム      ║
# ║              LT,RT=スプライト切替 / 右スティック=パン / BACK=Undo          ║
# ║              START長押し=保存                                              ║
# ║                                                                            ║
# ║  【依存】                                                                  ║
# ║  ・TKSpriteDefinitions（データ入出力）と TKSpriteAtlasBuilder（回転        ║
# ║    プレビュー生成）の2つだけです。ゲーム側への依存はありません。           ║
# ║  ・実行時ツールとしても、エディタ下部パネル（TKSpriteDefinitionDock）      ║
# ║    としても使えます。ドック時は editor_mode を true にしてください。       ║
# ║                                                                            ║
# ║  【メモリ規則】                                                            ║
# ║  ・開発時専用ツールのため起動時・編集操作時の確保は許容します。            ║
# ║    ただし毎フレーム処理（_process/_draw）では新規確保をしません。          ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

# データ入出力モジュールです。class_nameのグローバル登録に依存しないよう preload で束縛します。
const SpriteDefs = preload("res://addons/tk_sprite_server/core/tk_sprite_definitions.gd")
# 回転プレビュー生成に使うアトラスビルダーです。同じく preload で束縛します。
const AtlasBuilder = preload("res://addons/tk_sprite_server/core/tk_sprite_atlas_builder.gd")

# ── 外部から設定される値です ───────────────────────────────────────────────
# エディタ下部パネルとして開かれている場合は true です。true のときはキーボードと
# ゲームパッドの処理を止めます（エディタ自身のショートカットと衝突するためです）。
var editor_mode: bool = false
var defs_path: String = "res://demo/devdata/sprite_definitions.json"  # 編集対象のJSONパスです。

# ── データ状態です ─────────────────────────────────────────────────────────
var defs: Dictionary = {}             # SpriteDefs.load_file() 形式の編集中データです。
var current_index: int = -1           # defs["sprites"] 配列上の選択添字です。-1は未選択です。
var current_frame: int = 0            # 選択中フレーム番号です（frames編集・プレビュー用）。
var dirty: bool = false               # 未保存の変更があるかどうかです。

# ── アトラステクスチャのキャッシュです（別名→Texture2D）───────────────────
var atlas_texture_cache: Dictionary = {}

# ── 回転生成プレビューのキャッシュです（rotated/spin選択時のみ有効）────────
var rotation_preview_texture: Texture2D = null      # 生成済みプレビューアトラスです。
var rotation_preview_frames: Array[Rect2] = []      # 生成済みフレーム矩形列です。

# ── Undo/Redo（固定長リングバッファ、設計書§5.3）───────────────────────────
const UNDO_CAPACITY: int = 64
var undo_snapshots: Array = []        # _ready()でUNDO_CAPACITYへresizeする固定長領域です。
var undo_start: int = 0               # リング上の論理先頭の物理添字です。
var undo_len: int = 0                 # 有効スナップショット数です。
var undo_pos: int = -1                # 現在状態の論理位置です（0〜undo_len-1）。
var nudge_chain: bool = false         # 矢印キー連打を1回のUndo単位へまとめるための状態です。

# ── UIノード参照です ────────────────────────────────────────────────────────
var sprite_list: ItemList
var filter_edit: LineEdit
var atlas_view: AtlasView
var anim_preview: AnimPreview
var status_label: Label
var summary_label: Label
var file_dialog: FileDialog
var quit_dialog: ConfirmationDialog
var reload_dialog: ConfirmationDialog

var name_edit: LineEdit
var comment_edit: LineEdit
var id_spin: SpinBox
var atlas_option: OptionButton
var layout_option: OptionButton
var rect_x_spin: SpinBox
var rect_y_spin: SpinBox
var rect_w_spin: SpinBox
var rect_h_spin: SpinBox
var frame_count_spin: SpinBox
var draw_w_spin: SpinBox
var draw_h_spin: SpinBox
var orientation_spin: SpinBox
var roughness_spin: SpinBox
var vpd_spin: SpinBox
var native_check: CheckBox
var native_multimesh_check: CheckBox
var native_fc_spin: SpinBox
var native_dir_spin: SpinBox
var native_anim_spin: SpinBox
var anim_speed_spin: SpinBox
var direction_slider: HSlider

# レイアウト種別ごとの表示切替対象行です（"行名" : Control）。
var param_rows: Dictionary = {}

# UI再構築中にシグナルハンドラがデータを書き戻すのを防ぐガードです。
var syncing_ui: bool = false

# ── パッド入力のリピート管理です ────────────────────────────────────────────
const PAD_DEADZONE: float = 0.3
const PAD_REPEAT_DELAY: float = 0.4      # 初回リピートまでの秒数です。
const PAD_REPEAT_INTERVAL: float = 0.0667  # リピート間隔（秒間15回）です。
var pad_dir_prev: Vector2i = Vector2i.ZERO
var pad_repeat_timer: float = 0.0
var pad_lt_prev: bool = false
var pad_rt_prev: bool = false
var pad_back_prev: bool = false
var pad_x_prev: bool = false
var pad_y_prev: bool = false
var pad_start_hold: float = 0.0
var stick_accum: Vector2 = Vector2.ZERO

# ── レイアウト定数です ──────────────────────────────────────────────────────
const TOOL_FONT_SIZE: int = 32
const TOOL_DRAW_FONT_SIZE: int = 28
const TOOL_DRAW_INFO_FONT_SIZE: int = 26
const TOOL_CONTROL_HEIGHT: float = 60.0
const PANEL_MARGIN: float = 16.0
const LEFT_PANEL_WIDTH: float = 560.0
const RIGHT_PANEL_WIDTH: float = 760.0
const BOTTOM_PANEL_HEIGHT: float = 300.0
const STATUS_BAR_HEIGHT: float = 56.0

# [_ready]
# 処理内容: ツールUI全体を構築し、定義ファイルを読み込んで初期表示します。
# 引数: なし。
# 戻り値: なし。
func _ready() -> void:
    # Undoリングバッファを固定長で確保します（以後resizeしません）。
    undo_snapshots.resize(UNDO_CAPACITY)

    build_ui()
    reload_defs_from_disk(false)
    return  # end of function
# [_ready]END

# [build_ui]
# 処理内容: 4ペイン＋ステータスバー＋各ダイアログのUIノードを組み立てます。
# 引数: なし。
# 戻り値: なし。
func build_ui() -> void:
    # 2604x1140の開発画面で文字・入力欄・ボタンを従来の約2倍へ拡大します。
    var tool_theme := Theme.new()
    tool_theme.default_font_size = TOOL_FONT_SIZE
    theme = tool_theme

    # ── ①左ペイン: スプライト一覧です ──────────────────────────────────────
    var left_panel := VBoxContainer.new()
    left_panel.anchor_bottom = 1.0
    left_panel.offset_left = PANEL_MARGIN
    left_panel.offset_top = PANEL_MARGIN
    left_panel.offset_right = LEFT_PANEL_WIDTH
    left_panel.offset_bottom = -(BOTTOM_PANEL_HEIGHT + STATUS_BAR_HEIGHT + PANEL_MARGIN)
    left_panel.add_theme_constant_override("separation", 12)
    add_child(left_panel)

    filter_edit = LineEdit.new()
    filter_edit.custom_minimum_size = Vector2(0.0, TOOL_CONTROL_HEIGHT)
    filter_edit.placeholder_text = "検索（id または名前）"
    filter_edit.text_changed.connect(_on_filter_changed)
    left_panel.add_child(filter_edit)

    # ファイル操作は一覧の直上にも置き、読込/保存の入口を常に見える状態にします。
    var file_buttons := HBoxContainer.new()
    left_panel.add_child(file_buttons)
    var load_button := Button.new()
    load_button.text = "読込"
    load_button.custom_minimum_size = Vector2(150.0, TOOL_CONTROL_HEIGHT)
    load_button.pressed.connect(request_reload_defs)
    file_buttons.add_child(load_button)
    var quick_save_button := Button.new()
    quick_save_button.text = "保存"
    quick_save_button.custom_minimum_size = Vector2(150.0, TOOL_CONTROL_HEIGHT)
    quick_save_button.pressed.connect(save_defs)
    file_buttons.add_child(quick_save_button)

    sprite_list = ItemList.new()
    sprite_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
    sprite_list.add_theme_constant_override("v_separation", 12)
    sprite_list.item_selected.connect(_on_list_item_selected)
    left_panel.add_child(sprite_list)

    var list_buttons := HBoxContainer.new()
    left_panel.add_child(list_buttons)
    var add_button := Button.new()
    add_button.text = "追加"
    add_button.custom_minimum_size = Vector2(150.0, TOOL_CONTROL_HEIGHT)
    add_button.pressed.connect(_on_add_pressed)
    list_buttons.add_child(add_button)
    var dup_button := Button.new()
    dup_button.text = "複製"
    dup_button.custom_minimum_size = Vector2(150.0, TOOL_CONTROL_HEIGHT)
    dup_button.pressed.connect(_on_duplicate_pressed)
    list_buttons.add_child(dup_button)
    var del_button := Button.new()
    del_button.text = "削除"
    del_button.custom_minimum_size = Vector2(150.0, TOOL_CONTROL_HEIGHT)
    del_button.pressed.connect(_on_delete_pressed)
    list_buttons.add_child(del_button)

    # ── ②中央ペイン: アトラスプレビューです ────────────────────────────────
    atlas_view = AtlasView.new(self)
    atlas_view.anchor_right = 1.0
    atlas_view.anchor_bottom = 1.0
    atlas_view.offset_left = LEFT_PANEL_WIDTH + PANEL_MARGIN
    atlas_view.offset_top = PANEL_MARGIN
    atlas_view.offset_right = -(RIGHT_PANEL_WIDTH + PANEL_MARGIN)
    atlas_view.offset_bottom = -(BOTTOM_PANEL_HEIGHT + STATUS_BAR_HEIGHT + PANEL_MARGIN)
    atlas_view.clip_contents = true
    atlas_view.focus_mode = Control.FOCUS_NONE
    atlas_view.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
    add_child(atlas_view)

    # ── ③右ペイン: プロパティパネルです ────────────────────────────────────
    var right_scroll := ScrollContainer.new()
    right_scroll.anchor_left = 1.0
    right_scroll.anchor_right = 1.0
    right_scroll.anchor_bottom = 1.0
    right_scroll.offset_left = -RIGHT_PANEL_WIDTH
    right_scroll.offset_top = PANEL_MARGIN
    right_scroll.offset_right = -PANEL_MARGIN
    right_scroll.offset_bottom = -(BOTTOM_PANEL_HEIGHT + STATUS_BAR_HEIGHT + PANEL_MARGIN)
    add_child(right_scroll)

    var props := VBoxContainer.new()
    props.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    props.custom_minimum_size = Vector2(RIGHT_PANEL_WIDTH - PANEL_MARGIN * 3.0, 0.0)
    props.add_theme_constant_override("separation", 10)
    right_scroll.add_child(props)

    # 選択中スプライトの実データを読み取り専用でまとめて表示します。
    summary_label = Label.new()
    summary_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    summary_label.custom_minimum_size = Vector2(0.0, 288.0)
    props.add_child(summary_label)

    # 名前とidです。
    name_edit = LineEdit.new()
    name_edit.custom_minimum_size = Vector2(0.0, TOOL_CONTROL_HEIGHT)
    name_edit.text_changed.connect(_on_name_changed)
    add_prop_row(props, "名前", name_edit, "name")
    comment_edit = LineEdit.new()
    comment_edit.custom_minimum_size = Vector2(0.0, TOOL_CONTROL_HEIGHT)
    comment_edit.text_changed.connect(_on_comment_changed)
    add_prop_row(props, "コメント", comment_edit, "comment")
    id_spin = make_spin(0.0, 999999.0)
    id_spin.value_changed.connect(_on_id_changed)
    add_prop_row(props, "id", id_spin, "id")

    # アトラス選択です。
    atlas_option = OptionButton.new()
    atlas_option.custom_minimum_size = Vector2(0.0, TOOL_CONTROL_HEIGHT)
    atlas_option.item_selected.connect(_on_atlas_selected)
    add_prop_row(props, "アトラス", atlas_option, "atlas")
    var atlas_add_button := Button.new()
    atlas_add_button.text = "画像ファイルを追加..."
    atlas_add_button.custom_minimum_size = Vector2(0.0, TOOL_CONTROL_HEIGHT)
    atlas_add_button.pressed.connect(_on_atlas_add_pressed)
    props.add_child(atlas_add_button)

    # レイアウト種別です。
    layout_option = OptionButton.new()
    layout_option.custom_minimum_size = Vector2(0.0, TOOL_CONTROL_HEIGHT)
    for layout_name in SpriteDefs.VALID_LAYOUTS:
        layout_option.add_item(layout_name)
    layout_option.item_selected.connect(_on_layout_selected)
    add_prop_row(props, "layout", layout_option, "layout")

    # 切り取り矩形の数値直接入力です。
    rect_x_spin = make_spin(-4096.0, 8192.0)
    rect_y_spin = make_spin(-4096.0, 8192.0)
    rect_w_spin = make_spin(1.0, 8192.0)
    rect_h_spin = make_spin(1.0, 8192.0)
    rect_x_spin.value_changed.connect(_on_rect_spin_changed)
    rect_y_spin.value_changed.connect(_on_rect_spin_changed)
    rect_w_spin.value_changed.connect(_on_rect_spin_changed)
    rect_h_spin.value_changed.connect(_on_rect_spin_changed)
    add_prop_row(props, "矩形 x", rect_x_spin, "rect_x")
    add_prop_row(props, "矩形 y", rect_y_spin, "rect_y")
    add_prop_row(props, "矩形 幅", rect_w_spin, "rect_w")
    add_prop_row(props, "矩形 高", rect_h_spin, "rect_h")

    # アニメーションフレーム数です（row/spin用）。
    frame_count_spin = make_spin(1.0, 256.0)
    frame_count_spin.value_changed.connect(_on_frame_count_changed)
    add_prop_row(props, "フレーム数", frame_count_spin, "frame_count")

    # 表示サイズです（0=矩形サイズをそのまま使用）。
    draw_w_spin = make_spin(0.0, 4096.0)
    draw_h_spin = make_spin(0.0, 4096.0)
    draw_w_spin.value_changed.connect(_on_draw_size_changed)
    draw_h_spin.value_changed.connect(_on_draw_size_changed)
    add_prop_row(props, "表示幅(0=自動)", draw_w_spin, "draw_w")
    add_prop_row(props, "表示高(0=自動)", draw_h_spin, "draw_h")

    # 回転生成パラメータです（rotated/spin用）。
    orientation_spin = make_spin(0.0, 255.0)
    orientation_spin.value_changed.connect(_on_rotation_param_changed)
    add_prop_row(props, "元絵の方向(0-255)", orientation_spin, "orientation")
    roughness_spin = make_spin(0.0, 6.0)
    roughness_spin.value_changed.connect(_on_rotation_param_changed)
    add_prop_row(props, "粗さ(0-6)", roughness_spin, "roughness")
    vpd_spin = make_spin(1.0, 256.0)
    vpd_spin.value_changed.connect(_on_rotation_param_changed)
    add_prop_row(props, "視覚周期(dirs)", vpd_spin, "vpd")

    # rotated用の方向確認スライダーです（プレビューのフレーム選択）。
    direction_slider = HSlider.new()
    direction_slider.custom_minimum_size = Vector2(0.0, TOOL_CONTROL_HEIGHT)
    direction_slider.min_value = 0.0
    direction_slider.max_value = 255.0
    direction_slider.step = 1.0
    direction_slider.value_changed.connect(_on_direction_slider_changed)
    add_prop_row(props, "方向プレビュー", direction_slider, "direction")

    # native弾種登録の設定です。
    native_check = CheckBox.new()
    native_check.text = "native弾登録あり"
    native_check.custom_minimum_size = Vector2(0.0, TOOL_CONTROL_HEIGHT)
    native_check.toggled.connect(_on_native_toggled)
    props.add_child(native_check)
    param_rows["native_head"] = native_check
    native_multimesh_check = CheckBox.new()
    native_multimesh_check.text = "use_multimesh"
    native_multimesh_check.custom_minimum_size = Vector2(0.0, TOOL_CONTROL_HEIGHT)
    native_multimesh_check.toggled.connect(_on_native_param_changed_bool)
    props.add_child(native_multimesh_check)
    param_rows["native_mm"] = native_multimesh_check
    native_fc_spin = make_spin(0.0, 256.0)
    native_fc_spin.value_changed.connect(_on_native_param_changed)
    add_prop_row(props, "nb frame_count", native_fc_spin, "native_fc")
    native_dir_spin = make_spin(0.0, 256.0)
    native_dir_spin.value_changed.connect(_on_native_param_changed)
    add_prop_row(props, "nb direction_count", native_dir_spin, "native_dir")
    native_anim_spin = make_spin(0.0, 255.0)
    native_anim_spin.value_changed.connect(_on_native_param_changed)
    add_prop_row(props, "nb anim_every", native_anim_spin, "native_anim")

    # アニメプレビューの再生速度です（1フレーム進めるまでの表示フレーム数）。
    anim_speed_spin = make_spin(1.0, 60.0)
    anim_speed_spin.value = 8.0
    add_prop_row(props, "再生間隔(frames)", anim_speed_spin, "anim_speed")

    # 保存・Undo・Redoボタンです。
    var action_buttons := HBoxContainer.new()
    props.add_child(action_buttons)
    var reload_button := Button.new()
    reload_button.text = "読込"
    reload_button.custom_minimum_size = Vector2(110.0, TOOL_CONTROL_HEIGHT)
    reload_button.pressed.connect(request_reload_defs)
    action_buttons.add_child(reload_button)
    var save_button := Button.new()
    save_button.text = "保存 (Ctrl+S)"
    save_button.custom_minimum_size = Vector2(230.0, TOOL_CONTROL_HEIGHT)
    save_button.pressed.connect(save_defs)
    action_buttons.add_child(save_button)
    var undo_button := Button.new()
    undo_button.text = "Undo"
    undo_button.custom_minimum_size = Vector2(130.0, TOOL_CONTROL_HEIGHT)
    undo_button.pressed.connect(perform_undo)
    action_buttons.add_child(undo_button)
    var redo_button := Button.new()
    redo_button.text = "Redo"
    redo_button.custom_minimum_size = Vector2(130.0, TOOL_CONTROL_HEIGHT)
    redo_button.pressed.connect(perform_redo)
    action_buttons.add_child(redo_button)

    # ── ④下ペイン: アニメ／回転生成プレビューです ──────────────────────────
    anim_preview = AnimPreview.new(self)
    anim_preview.anchor_top = 1.0
    anim_preview.anchor_right = 1.0
    anim_preview.anchor_bottom = 1.0
    anim_preview.offset_left = PANEL_MARGIN
    anim_preview.offset_top = -(BOTTOM_PANEL_HEIGHT + STATUS_BAR_HEIGHT)
    anim_preview.offset_right = -PANEL_MARGIN
    anim_preview.offset_bottom = -STATUS_BAR_HEIGHT
    anim_preview.clip_contents = true
    anim_preview.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
    add_child(anim_preview)

    # ── ⑤ステータスバーです ────────────────────────────────────────────────
    status_label = Label.new()
    status_label.anchor_top = 1.0
    status_label.anchor_right = 1.0
    status_label.anchor_bottom = 1.0
    status_label.offset_left = PANEL_MARGIN
    status_label.offset_top = -STATUS_BAR_HEIGHT
    status_label.offset_right = -PANEL_MARGIN
    add_child(status_label)

    # ── ダイアログ類です ────────────────────────────────────────────────────
    file_dialog = FileDialog.new()
    file_dialog.access = FileDialog.ACCESS_RESOURCES
    file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
    file_dialog.filters = PackedStringArray(["*.png ; PNG画像"])
    file_dialog.file_selected.connect(_on_atlas_file_selected)
    add_child(file_dialog)

    quit_dialog = ConfirmationDialog.new()
    quit_dialog.dialog_text = "未保存の変更があります。保存せずに終了しますか？"
    quit_dialog.confirmed.connect(_on_quit_confirmed)
    add_child(quit_dialog)

    reload_dialog = ConfirmationDialog.new()
    reload_dialog.dialog_text = "未保存の変更があります。破棄して定義JSONを読み込み直しますか？"
    reload_dialog.confirmed.connect(_on_reload_confirmed)
    add_child(reload_dialog)
    return  # end of function
# [build_ui]END

# [make_spin]
# 処理内容: ツール共通仕様（整数ステップ・範囲指定）のSpinBoxを作ります。
# 引数 min_value: 最小値です。
# 引数 max_value: 最大値です。
# 戻り値: 生成したSpinBoxです。
func make_spin(min_value: float, max_value: float) -> SpinBox:
    var spin := SpinBox.new()
    spin.min_value = min_value
    spin.max_value = max_value
    spin.step = 1.0
    spin.allow_greater = false
    spin.custom_minimum_size = Vector2(0.0, TOOL_CONTROL_HEIGHT)
    spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    return spin
# [make_spin]END

# [add_prop_row]
# 処理内容: 「ラベル＋入力コントロール」の1行をプロパティパネルへ追加し、
#           レイアウト種別による表示切替のために param_rows へ登録します。
# 引数 parent: 追加先コンテナです。
# 引数 label_text: 行ラベルの文字列です。
# 引数 control: 入力コントロールです。
# 引数 row_key: param_rows へ登録するキーです。
# 戻り値: なし。
func add_prop_row(parent: Container, label_text: String, control: Control, row_key: String) -> void:
    var row := HBoxContainer.new()
    var label := Label.new()
    label.text = label_text
    label.custom_minimum_size = Vector2(270.0, TOOL_CONTROL_HEIGHT)
    row.add_child(label)
    control.custom_minimum_size = Vector2(control.custom_minimum_size.x, TOOL_CONTROL_HEIGHT)
    control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    row.add_child(control)
    parent.add_child(row)
    param_rows[row_key] = row
    return  # end of function
# [add_prop_row]END

# ═══════════════════════════════════════════════════════════════════════════
#  データアクセス系
# ═══════════════════════════════════════════════════════════════════════════

# [get_current_sprite]
# 処理内容: 選択中スプライトの定義Dictionaryを返します。
# 戻り値: 選択中の定義です。未選択なら空Dictionaryです。
func get_current_sprite() -> Dictionary:
    var sprites: Array = defs["sprites"]
    if current_index < 0 or current_index >= sprites.size():
        return {}
    return sprites[current_index]
# [get_current_sprite]END

# [get_current_texture]
# 処理内容: 選択中スプライトが参照するアトラスのTexture2Dを返します。
#           一度loadしたテクスチャは別名キーでキャッシュします。
# 戻り値: Texture2D。未選択・load失敗時は null です。
func get_current_texture() -> Texture2D:
    var sprite := get_current_sprite()
    if sprite.is_empty():
        return null
    var alias: String = String(sprite.get("atlas", ""))
    if atlas_texture_cache.has(alias):
        return atlas_texture_cache[alias]
    var atlases: Dictionary = defs["atlases"]
    if not atlases.has(alias):
        return null
    var res = load(String(atlases[alias]))
    if res == null or not res is Texture2D:
        return null
    atlas_texture_cache[alias] = res
    return res
# [get_current_texture]END

# [get_edit_rect]
# 処理内容: 現在編集対象の矩形を返します。frames列挙レイアウトでは選択中フレームの
#           矩形、それ以外では先頭矩形 rect です。
# 戻り値: 編集対象のRect2i。対象が無ければ空サイズのRect2iです。
func get_edit_rect() -> Rect2i:
    var sprite := get_current_sprite()
    if sprite.is_empty():
        return Rect2i()
    if String(sprite.get("layout", "")) == SpriteDefs.LAYOUT_FRAMES:
        var frames: Array = sprite.get("frames", [])
        if frames.is_empty():
            return Rect2i()
        var index: int = clampi(current_frame, 0, frames.size() - 1)
        var f: Array = frames[index]
        return Rect2i(int(f[0]), int(f[1]), int(f[2]), int(f[3]))
    if not sprite.has("rect"):
        return Rect2i()
    var r: Array = sprite["rect"]
    return Rect2i(int(r[0]), int(r[1]), int(r[2]), int(r[3]))
# [get_edit_rect]END

# [set_edit_rect]
# 処理内容: 現在編集対象の矩形を書き換え、UI（数値入力・プレビュー）へ反映します。
#           幅高さは1未満にならないようクランプします。
# 引数 rect: 新しい矩形です。
# 戻り値: なし。
func set_edit_rect(rect: Rect2i) -> void:
    var sprite := get_current_sprite()
    if sprite.is_empty():
        return
    rect.size.x = maxi(rect.size.x, 1)
    rect.size.y = maxi(rect.size.y, 1)
    var value: Array = [rect.position.x, rect.position.y, rect.size.x, rect.size.y]
    if String(sprite.get("layout", "")) == SpriteDefs.LAYOUT_FRAMES:
        var frames: Array = sprite.get("frames", [])
        if frames.is_empty():
            return
        frames[clampi(current_frame, 0, frames.size() - 1)] = value
    else:
        sprite["rect"] = value
    dirty = true
    refresh_property_values()
    invalidate_rotation_preview()
    atlas_view.queue_redraw()
    anim_preview.queue_redraw()
    update_status()
    return  # end of function
# [set_edit_rect]END

# [get_display_frames]
# 処理内容: アトラスプレビューへ重ね描きする全フレーム矩形を返します。
#           rotated/spin は元絵1枚だけを対象にします。
# 戻り値: フレーム矩形の Array[Rect2] です。
func get_display_frames() -> Array[Rect2]:
    var sprite := get_current_sprite()
    if sprite.is_empty():
        return []
    return SpriteDefs.expand_check_rects(sprite)
# [get_display_frames]END

# [get_preview_frame_count]
# 処理内容: アニメプレビューの総フレーム数を返します。
# 戻り値: フレーム数です。
func get_preview_frame_count() -> int:
    var sprite := get_current_sprite()
    if sprite.is_empty():
        return 0
    var layout: String = String(sprite.get("layout", ""))
    if layout == SpriteDefs.LAYOUT_ROTATED or layout == SpriteDefs.LAYOUT_SPIN:
        ensure_rotation_preview()
        return rotation_preview_frames.size()
    return SpriteDefs.build_frames(sprite).size()
# [get_preview_frame_count]END

# ═══════════════════════════════════════════════════════════════════════════
#  回転生成プレビュー
# ═══════════════════════════════════════════════════════════════════════════

# [invalidate_rotation_preview]
# 処理内容: 回転生成プレビューのキャッシュを破棄します。矩形・パラメータ変更時に呼びます。
# 戻り値: なし。
func invalidate_rotation_preview() -> void:
    rotation_preview_texture = null
    rotation_preview_frames = []
    return  # end of function
# [invalidate_rotation_preview]END

# [ensure_rotation_preview]
# 処理内容: rotated/spin レイアウトのプレビュー用アトラスを（未生成なら）生成します。
#           生成規則は build_rotated_sprite_atlas / build_spin_animation_atlas と
#           同一です（フレームiの方向番号→回転角の式を揃えています）。
#           回転処理そのものは TKSpriteAtlasBuilder.rotate_image_nearest() です。
# 戻り値: なし。生成結果は rotation_preview_texture / rotation_preview_frames に入ります。
func ensure_rotation_preview() -> void:
    if rotation_preview_texture != null:
        return
    var sprite := get_current_sprite()
    if sprite.is_empty() or not sprite.has("rect"):
        return
    var layout: String = String(sprite.get("layout", ""))
    if layout != SpriteDefs.LAYOUT_ROTATED and layout != SpriteDefs.LAYOUT_SPIN:
        return
    var texture := get_current_texture()
    if texture == null:
        return
    var full_image: Image = texture.get_image()
    if full_image == null:
        return
    if full_image.is_compressed():
        full_image.decompress()
    full_image.convert(Image.FORMAT_RGBA8)

    # 元絵の切り取りです。
    var r: Array = sprite["rect"]
    var fw: int = maxi(int(r[2]), 1)
    var fh: int = maxi(int(r[3]), 1)
    var src := Image.create_empty(fw, fh, false, Image.FORMAT_RGBA8)
    src.blit_rect(full_image, Rect2i(int(r[0]), int(r[1]), fw, fh), Vector2i.ZERO)

    # フレーム数と「フレーム番号→方向番号」の刻みを決めます。
    var orientation: int = int(sprite.get("original_orientation", 64))
    var total_frames: int = 0
    var dir_step: float = 0.0
    if layout == SpriteDefs.LAYOUT_ROTATED:
        var roughness: int = clampi(int(sprite.get("roughness", 4)), 0, 6)
        total_frames = 4 * (64 >> roughness)
        dir_step = 256.0 / float(total_frames)
    else:
        total_frames = maxi(int(sprite.get("frame_count", 1)), 1)
        dir_step = float(int(sprite.get("visual_period_dirs", 256))) / float(total_frames)

    # 横一列のプレビューアトラスを生成します。
    var atlas := Image.create_empty(total_frames * fw, fh, false, Image.FORMAT_RGBA8)
    var frames: Array[Rect2] = []
    for frame_index in range(total_frames):
        var dir_no: float = float(frame_index) * dir_step
        var angle_rad: float = (dir_no - float(orientation)) * (TAU / 256.0)
        var frame_img: Image = AtlasBuilder.rotate_image_nearest(src, angle_rad, fw, fh)
        atlas.blit_rect(frame_img, Rect2i(0, 0, fw, fh), Vector2i(frame_index * fw, 0))
        frames.append(Rect2(float(frame_index * fw), 0.0, float(fw), float(fh)))
    rotation_preview_texture = ImageTexture.create_from_image(atlas)
    rotation_preview_frames = frames
    return  # end of function
# [ensure_rotation_preview]END

# ═══════════════════════════════════════════════════════════════════════════
#  一覧・選択・プロパティ同期
# ═══════════════════════════════════════════════════════════════════════════

# [refresh_sprite_list]
# 処理内容: フィルタ文字列を適用してスプライト一覧を作り直します。
#           各項目のメタデータへ sprites 配列の添字を入れて対応付けます。
# 戻り値: なし。
func refresh_sprite_list() -> void:
    var previous_scroll_value: float = sprite_list.get_v_scroll_bar().value
    sprite_list.clear()
    var filter_text: String = filter_edit.text.strip_edges().to_lower()
    var sprites: Array = defs["sprites"]
    for sprite_index in range(sprites.size()):
        var sprite: Dictionary = sprites[sprite_index]
        var item_text: String = "%4d : %s" % [int(sprite.get("id", -1)), String(sprite.get("name", "?"))]
        if filter_text != "" and not item_text.to_lower().contains(filter_text):
            continue
        var list_index: int = sprite_list.add_item(item_text)
        sprite_list.set_item_metadata(list_index, sprite_index)
        if sprite_index == current_index:
            sprite_list.select(list_index)
    sprite_list.get_v_scroll_bar().value = previous_scroll_value
    return  # end of function
# [refresh_sprite_list]END

# [select_sprite]
# 処理内容: 指定添字のスプライトを選択状態にし、全ペインを更新します。
# 引数 sprite_index: defs["sprites"] 配列上の添字です。
# 戻り値: なし。
func select_sprite(sprite_index: int) -> void:
    var sprites: Array = defs["sprites"]
    if sprites.is_empty():
        current_index = -1
    else:
        current_index = clampi(sprite_index, 0, sprites.size() - 1)
    current_frame = 0
    invalidate_rotation_preview()
    refresh_property_panel()
    for list_index in range(sprite_list.item_count):
        if int(sprite_list.get_item_metadata(list_index)) == current_index:
            sprite_list.select(list_index)
            sprite_list.ensure_current_is_visible()
            break
    atlas_view.queue_redraw()
    anim_preview.reset_playback()
    anim_preview.queue_redraw()
    update_status()
    return  # end of function
# [select_sprite]END

# [refresh_property_panel]
# 処理内容: 選択中スプライトの値をプロパティパネル全体へ反映し、レイアウト種別に
#           応じた行の表示/非表示も更新します。シグナルの書き戻しは syncing_ui で防ぎます。
# 戻り値: なし。
func refresh_property_panel() -> void:
    syncing_ui = true
    var sprite := get_current_sprite()

    # アトラス別名の選択肢を作り直します。
    atlas_option.clear()
    var alias_list: Array = defs["atlases"].keys()
    for alias_index in range(alias_list.size()):
        atlas_option.add_item(String(alias_list[alias_index]))
        if not sprite.is_empty() and String(alias_list[alias_index]) == String(sprite.get("atlas", "")):
            atlas_option.select(alias_index)

    if sprite.is_empty():
        name_edit.text = ""
        comment_edit.text = ""
        syncing_ui = false
        update_param_visibility()
        return

    name_edit.text = String(sprite.get("name", ""))
    comment_edit.text = String(sprite.get("comment", ""))
    id_spin.value = float(int(sprite.get("id", 0)))
    var layout: String = String(sprite.get("layout", SpriteDefs.LAYOUT_SINGLE))
    var layout_index: int = SpriteDefs.VALID_LAYOUTS.find(layout)
    if layout_index >= 0:
        layout_option.select(layout_index)
    frame_count_spin.value = float(int(sprite.get("frame_count", 1)))
    orientation_spin.value = float(int(sprite.get("original_orientation", 64)))
    roughness_spin.value = float(int(sprite.get("roughness", 4)))
    vpd_spin.value = float(int(sprite.get("visual_period_dirs", 256)))
    if sprite.has("draw_size"):
        var ds: Array = sprite["draw_size"]
        draw_w_spin.value = float(int(ds[0]))
        draw_h_spin.value = float(int(ds[1]))
    else:
        draw_w_spin.value = 0.0
        draw_h_spin.value = 0.0
    var has_native: bool = sprite.has("native_bullet")
    native_check.button_pressed = has_native
    if has_native:
        var nb: Dictionary = sprite["native_bullet"]
        native_multimesh_check.button_pressed = bool(nb.get("use_multimesh", false))
        native_fc_spin.value = float(int(nb.get("frame_count", 0)))
        native_dir_spin.value = float(int(nb.get("direction_count", 0)))
        native_anim_spin.value = float(int(nb.get("anim_every_frames", 0)))
    refresh_property_values()
    syncing_ui = false
    update_param_visibility()
    return  # end of function
# [refresh_property_panel]END

# [refresh_property_values]
# 処理内容: 編集対象矩形のx/y/w/hだけをSpinBoxへ反映します（ドラッグ中の軽量更新用）。
# 戻り値: なし。
func refresh_property_values() -> void:
    var was_syncing: bool = syncing_ui
    syncing_ui = true
    var rect := get_edit_rect()
    rect_x_spin.value = float(rect.position.x)
    rect_y_spin.value = float(rect.position.y)
    rect_w_spin.value = float(rect.size.x)
    rect_h_spin.value = float(rect.size.y)
    syncing_ui = was_syncing
    return  # end of function
# [refresh_property_values]END

# [update_param_visibility]
# 処理内容: レイアウト種別・native設定の有無に応じて、関係ない入力行を隠します。
# 戻り値: なし。
func update_param_visibility() -> void:
    var sprite := get_current_sprite()
    var layout: String = String(sprite.get("layout", SpriteDefs.LAYOUT_SINGLE)) if not sprite.is_empty() else ""
    var is_rotated: bool = layout == SpriteDefs.LAYOUT_ROTATED
    var is_spin: bool = layout == SpriteDefs.LAYOUT_SPIN
    param_rows["frame_count"].visible = layout == SpriteDefs.LAYOUT_ROW or is_spin
    param_rows["orientation"].visible = is_rotated or is_spin
    param_rows["roughness"].visible = is_rotated
    param_rows["vpd"].visible = is_spin
    param_rows["direction"].visible = is_rotated
    var has_native: bool = not sprite.is_empty() and sprite.has("native_bullet")
    param_rows["native_mm"].visible = has_native
    param_rows["native_fc"].visible = has_native
    param_rows["native_dir"].visible = has_native
    param_rows["native_anim"].visible = has_native
    return  # end of function
# [update_param_visibility]END

# [update_status]
# 処理内容: ステータスバーへ選択状態・矩形座標・ズーム・保存状態・範囲外警告を表示します。
# 戻り値: なし。
func update_status() -> void:
    var sprite := get_current_sprite()
    if sprite.is_empty():
        if summary_label != null:
            summary_label.text = "定義: 未選択\n読込元: %s\nsprites: %d件\n保存状態: %s" % [
                defs_path,
                int(defs.get("sprites", []).size()),
                "未保存" if dirty else "保存済"
            ]
        status_label.text = "スプライト未選択 | ESC=終了"
        return
    var rect := get_edit_rect()
    var warn_text: String = ""
    var texture := get_current_texture()
    var texture_text: String = "未読込"
    if texture != null:
        texture_text = "%d x %d px" % [texture.get_width(), texture.get_height()]
        if rect.position.x < 0 or rect.position.y < 0 \
                or rect.end.x > texture.get_width() or rect.end.y > texture.get_height():
            warn_text = " | ⚠矩形がアトラス範囲外"
    var dirty_text: String = " | 未保存*" if dirty else " | 保存済"
    var total_frames: int = maxi(get_preview_frame_count(), 1)
    if summary_label != null:
        var draw_text: String = "自動"
        if sprite.has("draw_size"):
            var ds: Array = sprite["draw_size"]
            draw_text = "%d x %d" % [int(ds[0]), int(ds[1])]
        summary_label.text = "選択中定義\nid: %d\nname: %s\natlas: %s (%s)\nlayout: %s\nrect: x=%d y=%d w=%d h=%d\nframes: %d / draw_size: %s / native: %s\ncomment: %s" % [
            int(sprite.get("id", -1)),
            String(sprite.get("name", "?")),
            String(sprite.get("atlas", "")),
            texture_text,
            String(sprite.get("layout", "")),
            rect.position.x, rect.position.y, rect.size.x, rect.size.y,
            total_frames,
            draw_text,
            "ON" if sprite.has("native_bullet") else "OFF",
            String(sprite.get("comment", ""))
        ]
    status_label.text = "[%d:%s] x=%d y=%d w=%d h=%d | frame %d/%d | zoom %.2fx%s%s | ESC=終了" % [
        int(sprite.get("id", -1)), String(sprite.get("name", "?")),
        rect.position.x, rect.position.y, rect.size.x, rect.size.y,
        current_frame + 1, total_frames,
        atlas_view.zoom, dirty_text, warn_text
    ]
    return  # end of function
# [update_status]END

# ═══════════════════════════════════════════════════════════════════════════
#  Undo / Redo（固定長リングバッファ）
# ═══════════════════════════════════════════════════════════════════════════

# [push_undo_snapshot]
# 処理内容: 現在の編集状態のスナップショットをUndoリングへ積みます。
#           現在位置より先（Redo側）の履歴は破棄します。満杯時は最古を捨てます。
# 戻り値: なし。
func push_undo_snapshot() -> void:
    # Redo側の履歴を破棄します。
    undo_len = undo_pos + 1
    # 満杯なら最古の1件を捨ててリング先頭を進めます。
    if undo_len >= UNDO_CAPACITY:
        undo_start = (undo_start + 1) % UNDO_CAPACITY
        undo_len -= 1
        undo_pos -= 1
    var physical: int = (undo_start + undo_len) % UNDO_CAPACITY
    undo_snapshots[physical] = {
        "sprites": defs["sprites"].duplicate(true),
        "atlases": defs["atlases"].duplicate(true),
        "index": current_index,
        "frame": current_frame
    }
    undo_len += 1
    undo_pos = undo_len - 1
    return  # end of function
# [push_undo_snapshot]END

# [restore_undo_snapshot]
# 処理内容: 指定論理位置のスナップショットを編集状態へ復元し、全UIを更新します。
# 引数 logical_pos: 0〜undo_len-1 の論理位置です。
# 戻り値: なし。
func restore_undo_snapshot(logical_pos: int) -> void:
    var physical: int = (undo_start + logical_pos) % UNDO_CAPACITY
    var snapshot: Dictionary = undo_snapshots[physical]
    defs["sprites"] = snapshot["sprites"].duplicate(true)
    defs["atlases"] = snapshot["atlases"].duplicate(true)
    current_index = int(snapshot["index"])
    current_frame = int(snapshot["frame"])
    dirty = true
    invalidate_rotation_preview()
    refresh_sprite_list()
    refresh_property_panel()
    atlas_view.queue_redraw()
    anim_preview.queue_redraw()
    update_status()
    return  # end of function
# [restore_undo_snapshot]END

# [perform_undo]
# 処理内容: 1段階Undoします（現在位置の1つ前のスナップショットを復元）。
# 戻り値: なし。
func perform_undo() -> void:
    nudge_chain = false
    if undo_pos <= 0:
        return
    undo_pos -= 1
    restore_undo_snapshot(undo_pos)
    return  # end of function
# [perform_undo]END

# [perform_redo]
# 処理内容: 1段階Redoします（現在位置の1つ先のスナップショットを復元）。
# 戻り値: なし。
func perform_redo() -> void:
    nudge_chain = false
    if undo_pos >= undo_len - 1:
        return
    undo_pos += 1
    restore_undo_snapshot(undo_pos)
    return  # end of function
# [perform_redo]END

# [commit_edit]
# 処理内容: 1回の編集操作の完了を記録します（Undoスナップショット＋未保存フラグ）。
#           矢印キー・十字キーの連打は nudge=true でまとめ、チェーンの最初だけ積みます。
# 引数 nudge: 連打をまとめたい微調整操作なら true です。
# 戻り値: なし。
func commit_edit(nudge: bool = false) -> void:
    dirty = true
    if nudge:
        if not nudge_chain:
            nudge_chain = true
            push_undo_snapshot()
        else:
            # チェーン継続中は直近スナップショットを最新状態で置き換えます。
            var physical: int = (undo_start + undo_pos) % UNDO_CAPACITY
            undo_snapshots[physical] = {
                "sprites": defs["sprites"].duplicate(true),
                "atlases": defs["atlases"].duplicate(true),
                "index": current_index,
                "frame": current_frame
            }
    else:
        nudge_chain = false
        push_undo_snapshot()
    update_status()
    return  # end of function
# [commit_edit]END

# ═══════════════════════════════════════════════════════════════════════════
#  保存・終了
# ═══════════════════════════════════════════════════════════════════════════

# [reload_defs_from_disk]
# 処理内容: defs_path の定義JSONを読み込み直し、一覧・プロパティ・プレビュー・Undo基点を
#           すべて読み込み直後の状態へ揃えます。読込失敗時は空の雛形から編集を始めます。
# 引数 show_message: trueならステータスバーへ読込完了メッセージを出します。
# 戻り値: なし。
func reload_defs_from_disk(show_message: bool = true) -> void:
    var loaded: Dictionary = SpriteDefs.load_file(defs_path)
    if loaded.is_empty():
        loaded = {"version": SpriteDefs.FORMAT_VERSION, "atlases": {}, "sprites": []}

    defs = loaded
    dirty = false
    current_index = -1
    current_frame = 0
    nudge_chain = false
    atlas_texture_cache.clear()
    invalidate_rotation_preview()

    undo_snapshots.fill(null)
    undo_start = 0
    undo_len = 0
    undo_pos = -1

    refresh_sprite_list()
    if not defs["sprites"].is_empty():
        select_sprite(0)
    else:
        refresh_property_panel()
        atlas_view.queue_redraw()
        anim_preview.reset_playback()
        anim_preview.queue_redraw()
        update_status()
    push_undo_snapshot()

    if show_message:
        status_label.text = "読み込みました: " + defs_path + " | " + status_label.text
    return  # end of function
# [reload_defs_from_disk]END

# [request_reload_defs]
# 処理内容: 読込ボタンの入口です。未保存変更があれば確認ダイアログを出し、
#           保存済みならそのまま定義JSONを読み込み直します。
# 戻り値: なし。
func request_reload_defs() -> void:
    if dirty:
        reload_dialog.popup_centered()
        return
    reload_defs_from_disk()
    return  # end of function
# [request_reload_defs]END

# [save_defs]
# 処理内容: 検証してERRORが無ければJSONへ保存します。ERRORがあれば保存せず
#           ステータスバーへ先頭のERRORを表示します（WARNは保存を妨げません）。
# 戻り値: なし。
func save_defs() -> void:
    var messages: PackedStringArray = SpriteDefs.validate(defs)
    for message in messages:
        if message.begins_with("ERROR:"):
            status_label.text = "保存中止: " + message
            return
    if SpriteDefs.save_file(defs_path, defs):
        dirty = false
        update_status()
        status_label.text = "保存しました: " + defs_path + " | " + status_label.text
    else:
        status_label.text = "保存に失敗しました: " + defs_path
    return  # end of function
# [save_defs]END

# [request_quit]
# 処理内容: 終了操作の入口です。未保存変更があれば確認ダイアログを出します。
# 戻り値: なし。
func request_quit() -> void:
    if dirty:
        quit_dialog.popup_centered()
        return
    get_tree().quit()
    return  # end of function
# [request_quit]END

# [_on_quit_confirmed]
# 処理内容: 「保存せずに終了」の確認後にアプリを終了します。
# 戻り値: なし。
func _on_quit_confirmed() -> void:
    get_tree().quit()
    return  # end of function
# [_on_quit_confirmed]END

# [_on_reload_confirmed]
# 処理内容: 未保存変更を破棄する確認後に、定義JSONを読み込み直します。
# 戻り値: なし。
func _on_reload_confirmed() -> void:
    reload_defs_from_disk()
    return  # end of function
# [_on_reload_confirmed]END

# ═══════════════════════════════════════════════════════════════════════════
#  UIシグナルハンドラ
# ═══════════════════════════════════════════════════════════════════════════

# [_on_filter_changed]
# 処理内容: 検索フィルタ変更で一覧を作り直します。
# 引数 _new_text: 入力文字列です（未使用、refresh側で参照します）。
# 戻り値: なし。
func _on_filter_changed(_new_text: String) -> void:
    refresh_sprite_list()
    return  # end of function
# [_on_filter_changed]END

# [_on_list_item_selected]
# 処理内容: 一覧クリックでスプライトを選択します。
# 引数 list_index: ItemList上の添字です。メタデータから配列添字を取り出します。
# 戻り値: なし。
func _on_list_item_selected(list_index: int) -> void:
    select_sprite(int(sprite_list.get_item_metadata(list_index)))
    return  # end of function
# [_on_list_item_selected]END

# [_on_add_pressed]
# 処理内容: 新規スプライト定義を追加して選択します。idは既存最大値+1を割り当てます。
# 戻り値: なし。
func _on_add_pressed() -> void:
    var sprites: Array = defs["sprites"]
    var alias_list: Array = defs["atlases"].keys()
    var default_alias: String = String(alias_list[0]) if not alias_list.is_empty() else ""
    sprites.append({
        "id": find_max_id() + 1,
        "name": "NEW_SPRITE",
        "atlas": default_alias,
        "layout": SpriteDefs.LAYOUT_SINGLE,
        "rect": [0, 0, 16, 16]
    })
    commit_edit()
    refresh_sprite_list()
    select_sprite(sprites.size() - 1)
    return  # end of function
# [_on_add_pressed]END

# [_on_duplicate_pressed]
# 処理内容: 選択中スプライトを複製して選択します。idは既存最大値+1です。
# 戻り値: なし。
func _on_duplicate_pressed() -> void:
    var sprite := get_current_sprite()
    if sprite.is_empty():
        return
    var copy: Dictionary = sprite.duplicate(true)
    copy["id"] = find_max_id() + 1
    copy["name"] = String(copy.get("name", "SPRITE")) + "_COPY"
    defs["sprites"].append(copy)
    commit_edit()
    refresh_sprite_list()
    select_sprite(defs["sprites"].size() - 1)
    return  # end of function
# [_on_duplicate_pressed]END

# [_on_delete_pressed]
# 処理内容: 選択中スプライトを削除します。
# 戻り値: なし。
func _on_delete_pressed() -> void:
    if current_index < 0 or current_index >= defs["sprites"].size():
        return
    defs["sprites"].remove_at(current_index)
    commit_edit()
    refresh_sprite_list()
    select_sprite(mini(current_index, defs["sprites"].size() - 1))
    return  # end of function
# [_on_delete_pressed]END

# [find_max_id]
# 処理内容: 定義済みスプライトの最大idを返します（新規id割り当て用）。
# 戻り値: 最大id。定義が無ければ -1 です。
func find_max_id() -> int:
    var max_id: int = -1
    for sprite in defs["sprites"]:
        max_id = maxi(max_id, int(sprite.get("id", -1)))
    return max_id
# [find_max_id]END

# [_on_name_changed]
# 処理内容: 名前入力を定義へ即時反映し、一覧表示を更新します。
# 引数 new_text: 入力された名前です。
# 戻り値: なし。
func _on_name_changed(new_text: String) -> void:
    if syncing_ui:
        return
    var sprite := get_current_sprite()
    if sprite.is_empty():
        return
    sprite["name"] = new_text
    commit_edit()
    refresh_sprite_list()
    return  # end of function
# [_on_name_changed]END

# [_on_comment_changed]
# 処理内容: コメント入力を定義へ即時反映します。空文字なら保存JSONから comment キーを外します。
# 引数 new_text: 入力されたコメントです。
# 戻り値: なし。
func _on_comment_changed(new_text: String) -> void:
    if syncing_ui:
        return
    var sprite := get_current_sprite()
    if sprite.is_empty():
        return
    if new_text == "":
        sprite.erase("comment")
    else:
        sprite["comment"] = new_text
    commit_edit()
    return  # end of function
# [_on_comment_changed]END

# [_on_id_changed]
# 処理内容: id変更を定義へ反映します。重複はステータスバーで警告します（保存時にブロック）。
# 引数 new_value: 新しいid値です。
# 戻り値: なし。
func _on_id_changed(new_value: float) -> void:
    if syncing_ui:
        return
    var sprite := get_current_sprite()
    if sprite.is_empty():
        return
    sprite["id"] = int(new_value)
    commit_edit()
    refresh_sprite_list()
    return  # end of function
# [_on_id_changed]END

# [_on_atlas_selected]
# 処理内容: アトラス別名の選択変更を定義へ反映します。
# 引数 option_index: OptionButton上の添字です。
# 戻り値: なし。
func _on_atlas_selected(option_index: int) -> void:
    if syncing_ui:
        return
    var sprite := get_current_sprite()
    if sprite.is_empty():
        return
    sprite["atlas"] = atlas_option.get_item_text(option_index)
    invalidate_rotation_preview()
    commit_edit()
    atlas_view.queue_redraw()
    anim_preview.queue_redraw()
    return  # end of function
# [_on_atlas_selected]END

# [_on_atlas_add_pressed]
# 処理内容: アトラス画像追加のFileDialogを開きます。
# 戻り値: なし。
func _on_atlas_add_pressed() -> void:
    file_dialog.popup_centered_ratio(0.7)
    return  # end of function
# [_on_atlas_add_pressed]END

# [_on_atlas_file_selected]
# 処理内容: 選択されたPNGを新しいアトラス別名として登録し、選択中スプライトへ割り当てます。
#           別名はファイル名（拡張子なし小文字）です。既存の別名ならパスを更新します。
# 引数 path: 選択された res:// パスです。
# 戻り値: なし。
func _on_atlas_file_selected(path: String) -> void:
    var alias: String = path.get_file().get_basename().to_lower()
    defs["atlases"][alias] = path
    atlas_texture_cache.erase(alias)
    var sprite := get_current_sprite()
    if not sprite.is_empty():
        sprite["atlas"] = alias
    invalidate_rotation_preview()
    commit_edit()
    refresh_property_panel()
    atlas_view.queue_redraw()
    anim_preview.queue_redraw()
    return  # end of function
# [_on_atlas_file_selected]END

# [_on_layout_selected]
# 処理内容: レイアウト種別の変更を定義へ反映します。frames列挙へ切り替えた場合は
#           現在の rect を先頭フレームとして frames を初期化します。
# 引数 option_index: VALID_LAYOUTS の添字です。
# 戻り値: なし。
func _on_layout_selected(option_index: int) -> void:
    if syncing_ui:
        return
    var sprite := get_current_sprite()
    if sprite.is_empty():
        return
    var new_layout: String = SpriteDefs.VALID_LAYOUTS[option_index]
    var old_layout: String = String(sprite.get("layout", ""))
    if new_layout == old_layout:
        return
    sprite["layout"] = new_layout
    if new_layout == SpriteDefs.LAYOUT_FRAMES and not sprite.has("frames"):
        # rectを1枚目として明示列挙を初期化します。
        var rect := get_edit_rect()
        if sprite.has("rect"):
            sprite["frames"] = [[rect.position.x, rect.position.y, rect.size.x, rect.size.y]]
    if new_layout != SpriteDefs.LAYOUT_FRAMES and not sprite.has("rect") and sprite.has("frames"):
        # 明示列挙から戻すときは先頭フレームをrectへ採用します。
        var frames: Array = sprite["frames"]
        if not frames.is_empty():
            sprite["rect"] = frames[0]
    current_frame = 0
    invalidate_rotation_preview()
    commit_edit()
    refresh_property_panel()
    atlas_view.queue_redraw()
    anim_preview.reset_playback()
    anim_preview.queue_redraw()
    return  # end of function
# [_on_layout_selected]END

# [_on_rect_spin_changed]
# 処理内容: 矩形数値入力（x/y/w/h）の変更を編集対象矩形へ反映します。
# 引数 _new_value: 変更後の値です（4つのSpinBoxをまとめて読むため未使用）。
# 戻り値: なし。
func _on_rect_spin_changed(_new_value: float) -> void:
    if syncing_ui:
        return
    set_edit_rect(Rect2i(
        int(rect_x_spin.value), int(rect_y_spin.value),
        int(rect_w_spin.value), int(rect_h_spin.value)
    ))
    commit_edit()
    return  # end of function
# [_on_rect_spin_changed]END

# [_on_frame_count_changed]
# 処理内容: フレーム数変更を定義へ反映します（row/spin用）。
# 引数 new_value: 新しいフレーム数です。
# 戻り値: なし。
func _on_frame_count_changed(new_value: float) -> void:
    if syncing_ui:
        return
    var sprite := get_current_sprite()
    if sprite.is_empty():
        return
    sprite["frame_count"] = int(new_value)
    invalidate_rotation_preview()
    commit_edit()
    atlas_view.queue_redraw()
    anim_preview.reset_playback()
    anim_preview.queue_redraw()
    return  # end of function
# [_on_frame_count_changed]END

# [_on_draw_size_changed]
# 処理内容: 表示サイズ変更を定義へ反映します。両方0なら draw_size キー自体を消して
#           「矩形サイズをそのまま使う」状態にします。
# 引数 _new_value: 変更後の値です（2つのSpinBoxをまとめて読むため未使用）。
# 戻り値: なし。
func _on_draw_size_changed(_new_value: float) -> void:
    if syncing_ui:
        return
    var sprite := get_current_sprite()
    if sprite.is_empty():
        return
    var draw_w: int = int(draw_w_spin.value)
    var draw_h: int = int(draw_h_spin.value)
    if draw_w <= 0 and draw_h <= 0:
        sprite.erase("draw_size")
    else:
        sprite["draw_size"] = [draw_w, draw_h]
    commit_edit()
    return  # end of function
# [_on_draw_size_changed]END

# [_on_rotation_param_changed]
# 処理内容: 回転生成パラメータ（方向・粗さ・視覚周期）の変更を定義へ反映し、
#           回転プレビューを再生成させます。
# 引数 _new_value: 変更後の値です（複数SpinBoxをまとめて読むため未使用）。
# 戻り値: なし。
func _on_rotation_param_changed(_new_value: float) -> void:
    if syncing_ui:
        return
    var sprite := get_current_sprite()
    if sprite.is_empty():
        return
    sprite["original_orientation"] = int(orientation_spin.value)
    sprite["roughness"] = int(roughness_spin.value)
    sprite["visual_period_dirs"] = int(vpd_spin.value)
    invalidate_rotation_preview()
    commit_edit()
    anim_preview.reset_playback()
    anim_preview.queue_redraw()
    return  # end of function
# [_on_rotation_param_changed]END

# [_on_direction_slider_changed]
# 処理内容: rotated用の方向プレビュースライダーです。方向番号から表示フレームを
#           選びます（frame = direction * total / 256、build側の変換式と同一）。
# 引数 new_value: 方向番号（0〜255）です。
# 戻り値: なし。
func _on_direction_slider_changed(new_value: float) -> void:
    var total: int = get_preview_frame_count()
    if total <= 0:
        return
    current_frame = clampi(int(new_value) * total / 256, 0, total - 1)
    anim_preview.queue_redraw()
    update_status()
    return  # end of function
# [_on_direction_slider_changed]END

# [_on_native_toggled]
# 処理内容: native弾登録の有無を切り替えます。ONで既定値のnative_bulletを作り、
#           OFFでキーごと削除します。
# 引数 pressed: チェック状態です。
# 戻り値: なし。
func _on_native_toggled(pressed: bool) -> void:
    if syncing_ui:
        return
    var sprite := get_current_sprite()
    if sprite.is_empty():
        return
    if pressed:
        sprite["native_bullet"] = {
            "use_multimesh": false,
            "frame_count": 0,
            "direction_count": 0,
            "anim_every_frames": 0
        }
    else:
        sprite.erase("native_bullet")
    commit_edit()
    refresh_property_panel()
    return  # end of function
# [_on_native_toggled]END

# [_on_native_param_changed]
# 処理内容: native弾パラメータ（数値3種）の変更を定義へ反映します。
# 引数 _new_value: 変更後の値です（まとめて読むため未使用）。
# 戻り値: なし。
func _on_native_param_changed(_new_value: float) -> void:
    if syncing_ui:
        return
    apply_native_params()
    return  # end of function
# [_on_native_param_changed]END

# [_on_native_param_changed_bool]
# 処理内容: native弾パラメータ（use_multimesh）の変更を定義へ反映します。
# 引数 _pressed: 変更後の値です（まとめて読むため未使用）。
# 戻り値: なし。
func _on_native_param_changed_bool(_pressed: bool) -> void:
    if syncing_ui:
        return
    apply_native_params()
    return  # end of function
# [_on_native_param_changed_bool]END

# [apply_native_params]
# 処理内容: native系入力コントロール4つの現在値を native_bullet へまとめて書き込みます。
# 戻り値: なし。
func apply_native_params() -> void:
    var sprite := get_current_sprite()
    if sprite.is_empty() or not sprite.has("native_bullet"):
        return
    sprite["native_bullet"] = {
        "use_multimesh": native_multimesh_check.button_pressed,
        "frame_count": int(native_fc_spin.value),
        "direction_count": int(native_dir_spin.value),
        "anim_every_frames": int(native_anim_spin.value)
    }
    commit_edit()
    return  # end of function
# [apply_native_params]END

# ═══════════════════════════════════════════════════════════════════════════
#  キーボード・コントローラー入力
# ═══════════════════════════════════════════════════════════════════════════

# [_unhandled_input]
# 処理内容: GUIコントロールに食われなかったキー入力を処理します。
#           矢印=1px移動 / Shift+矢印=8px / Ctrl+矢印=リサイズ / PgUp,PgDn=フレーム /
#           Tab=スプライト切替 / Ctrl+S=保存 / Ctrl+F=検索 / Ctrl+Z=Undo / Ctrl+Y=Redo / ESC=終了。
# 引数 event: 入力イベントです。キーリピート（echo）も微調整として受け付けます。
# 戻り値: なし。
func _unhandled_input(event: InputEvent) -> void:
    # エディタドックとして開かれているときは、エディタ自身のショートカットと
    # 衝突するためキー処理を行いません。
    if editor_mode:
        return
    if not event is InputEventKey:
        return
    var key := event as InputEventKey
    if not key.pressed:
        # キーを離したら微調整チェーンを区切り、次の操作を新しいUndo単位にします。
        nudge_chain = false
        return

    var handled: bool = true
    var step: int = 8 if key.shift_pressed else 1
    match key.keycode:
        KEY_ESCAPE:
            if not key.echo:
                request_quit()
        KEY_LEFT:
            nudge_edit_rect(-step, 0, key.ctrl_pressed)
        KEY_RIGHT:
            nudge_edit_rect(step, 0, key.ctrl_pressed)
        KEY_UP:
            nudge_edit_rect(0, -step, key.ctrl_pressed)
        KEY_DOWN:
            nudge_edit_rect(0, step, key.ctrl_pressed)
        KEY_PAGEUP:
            step_current_frame(-1)
        KEY_PAGEDOWN:
            step_current_frame(1)
        KEY_TAB:
            if not key.echo:
                step_sprite_selection(-1 if key.shift_pressed else 1)
        KEY_F:
            if key.ctrl_pressed and not key.echo:
                filter_edit.grab_focus()
                filter_edit.select_all()
            else:
                handled = false
        KEY_S:
            if key.ctrl_pressed and not key.echo:
                save_defs()
            else:
                handled = false
        KEY_Z:
            if key.ctrl_pressed and not key.echo:
                perform_undo()
            else:
                handled = false
        KEY_Y:
            if key.ctrl_pressed and not key.echo:
                perform_redo()
            else:
                handled = false
        _:
            handled = false
    if handled:
        get_viewport().set_input_as_handled()
    return  # end of function
# [_unhandled_input]END

# [nudge_edit_rect]
# 処理内容: 編集対象矩形をキー／十字キー操作で微調整します。
# 引数 dx: X方向の変化量（ピクセル）です。
# 引数 dy: Y方向の変化量（ピクセル）です。
# 引数 resize: trueなら移動ではなく幅高さを伸縮します。
# 戻り値: なし。
func nudge_edit_rect(dx: int, dy: int, resize: bool) -> void:
    var rect := get_edit_rect()
    if rect.size.x <= 0 and rect.size.y <= 0:
        return
    if resize:
        rect.size.x += dx
        rect.size.y += dy
    else:
        rect.position.x += dx
        rect.position.y += dy
    set_edit_rect(rect)
    commit_edit(true)
    return  # end of function
# [nudge_edit_rect]END

# [step_current_frame]
# 処理内容: 選択フレーム番号を前後へ動かします（frames編集とプレビュー確認用）。
# 引数 direction: +1で次、-1で前のフレームです。
# 戻り値: なし。
func step_current_frame(direction: int) -> void:
    var total: int = get_preview_frame_count()
    if total <= 0:
        return
    current_frame = wrapi(current_frame + direction, 0, total)
    atlas_view.queue_redraw()
    anim_preview.queue_redraw()
    update_status()
    return  # end of function
# [step_current_frame]END

# [step_sprite_selection]
# 処理内容: 選択スプライトを前後へ切り替えます（Tab / LT,RT用）。
# 引数 direction: +1で次、-1で前のスプライトです。
# 戻り値: なし。
func step_sprite_selection(direction: int) -> void:
    var count: int = defs["sprites"].size()
    if count <= 0:
        return
    nudge_chain = false
    select_sprite(wrapi(current_index + direction, 0, count))
    return  # end of function
# [step_sprite_selection]END

# [_process]
# 処理内容: コントローラー入力のポーリングとステータスバーの定期更新を行います。
#           十字キーのリピート、スティックのアナログ移動、LT/RT・ボタンのエッジ検出を
#           まとめて処理します（毎フレームの新規確保はしません）。
# 引数 delta: 前フレームからの経過秒です。
# 戻り値: なし。
func _process(delta: float) -> void:
    # エディタドックではゲームパッド操作を受け付けません（実行時ツール専用です）。
    if editor_mode:
        return
    # ── 十字キー: 矩形の微調整（リピートつき）─────────────────────────────
    var dir := Vector2i.ZERO
    if Input.is_joy_button_pressed(0, JOY_BUTTON_DPAD_LEFT):
        dir.x -= 1
    if Input.is_joy_button_pressed(0, JOY_BUTTON_DPAD_RIGHT):
        dir.x += 1
    if Input.is_joy_button_pressed(0, JOY_BUTTON_DPAD_UP):
        dir.y -= 1
    if Input.is_joy_button_pressed(0, JOY_BUTTON_DPAD_DOWN):
        dir.y += 1
    var lb_held: bool = Input.is_joy_button_pressed(0, JOY_BUTTON_LEFT_SHOULDER)
    var rb_held: bool = Input.is_joy_button_pressed(0, JOY_BUTTON_RIGHT_SHOULDER)
    if dir != Vector2i.ZERO:
        if dir != pad_dir_prev:
            # 押した瞬間は即座に1回適用し、以後はリピート間隔で繰り返します。
            apply_pad_nudge(dir, lb_held, rb_held)
            pad_repeat_timer = PAD_REPEAT_DELAY
        else:
            pad_repeat_timer -= delta
            if pad_repeat_timer <= 0.0:
                apply_pad_nudge(dir, lb_held, rb_held)
                pad_repeat_timer = PAD_REPEAT_INTERVAL
    else:
        if pad_dir_prev != Vector2i.ZERO:
            nudge_chain = false
    pad_dir_prev = dir

    # ── 左スティック: 矩形のアナログ移動です（int化した分だけ適用）──────────
    var left_stick := Vector2(
        Input.get_joy_axis(0, JOY_AXIS_LEFT_X),
        Input.get_joy_axis(0, JOY_AXIS_LEFT_Y)
    )
    if left_stick.length() > PAD_DEADZONE:
        stick_accum += left_stick * delta * 30.0
        var move_x: int = int(stick_accum.x)
        var move_y: int = int(stick_accum.y)
        if move_x != 0 or move_y != 0:
            stick_accum -= Vector2(float(move_x), float(move_y))
            nudge_edit_rect(move_x, move_y, false)
    else:
        stick_accum = Vector2.ZERO

    # ── 右スティック: アトラスプレビューのパンです ──────────────────────────
    var right_stick := Vector2(
        Input.get_joy_axis(0, JOY_AXIS_RIGHT_X),
        Input.get_joy_axis(0, JOY_AXIS_RIGHT_Y)
    )
    if right_stick.length() > PAD_DEADZONE:
        atlas_view.pan -= right_stick * delta * 300.0
        atlas_view.queue_redraw()

    # ── LT/RT: スプライト切替（エッジ検出）──────────────────────────────────
    var lt_held: bool = Input.get_joy_axis(0, JOY_AXIS_TRIGGER_LEFT) > 0.5
    var rt_held: bool = Input.get_joy_axis(0, JOY_AXIS_TRIGGER_RIGHT) > 0.5
    if lt_held and not pad_lt_prev:
        step_sprite_selection(-1)
    if rt_held and not pad_rt_prev:
        step_sprite_selection(1)
    pad_lt_prev = lt_held
    pad_rt_prev = rt_held

    # ── X/Y: フレーム選択（エッジ検出）──────────────────────────────────────
    var x_held: bool = Input.is_joy_button_pressed(0, JOY_BUTTON_X)
    var y_held: bool = Input.is_joy_button_pressed(0, JOY_BUTTON_Y)
    if x_held and not pad_x_prev:
        step_current_frame(-1)
    if y_held and not pad_y_prev:
        step_current_frame(1)
    pad_x_prev = x_held
    pad_y_prev = y_held

    # ── BACK: Undo（エッジ検出）／ START長押し: 保存 ────────────────────────
    var back_held: bool = Input.is_joy_button_pressed(0, JOY_BUTTON_BACK)
    if back_held and not pad_back_prev:
        perform_undo()
    pad_back_prev = back_held
    if Input.is_joy_button_pressed(0, JOY_BUTTON_START):
        pad_start_hold += delta
        if pad_start_hold >= 0.5:
            pad_start_hold = -10.0  # 保存の連続発火を防ぐ番兵値です（離すまで再発火しません）。
            save_defs()
    else:
        pad_start_hold = 0.0
    return  # end of function
# [_process]END

# [apply_pad_nudge]
# 処理内容: 十字キー1回ぶんの微調整を適用します。LB押下で8px、RB押下でリサイズです。
# 引数 dir: 十字キーの方向です。
# 引数 lb_held: LBが押されているかです（8px単位）。
# 引数 rb_held: RBが押されているかです（リサイズ）。
# 戻り値: なし。
func apply_pad_nudge(dir: Vector2i, lb_held: bool, rb_held: bool) -> void:
    var step: int = 8 if lb_held else 1
    nudge_edit_rect(dir.x * step, dir.y * step, rb_held)
    return  # end of function
# [apply_pad_nudge]END

# ═══════════════════════════════════════════════════════════════════════════
#  内部クラス①: AtlasView（アトラスプレビューと矩形のマウス編集）
# ═══════════════════════════════════════════════════════════════════════════

class AtlasView extends Control:
    # ドラッグ操作の種別です。
    const DRAG_NONE: int = 0    # ドラッグしていません。
    const DRAG_MOVE: int = 1    # 矩形の移動中です。
    const DRAG_RESIZE: int = 2  # ハンドルによるリサイズ中です。
    const DRAG_PAN: int = 3     # 中ボタンによる画面パン中です。
    const DRAG_CREATE: int = 4  # 空き領域ドラッグによる矩形の新規指定中です。

    # リサイズ対象辺のビットマスクです（DRAG_RESIZE時に使用します）。
    const EDGE_LEFT: int = 1
    const EDGE_RIGHT: int = 2
    const EDGE_TOP: int = 4
    const EDGE_BOTTOM: int = 8

    const HANDLE_HIT_RADIUS: float = 12.0  # 2倍UIに合わせたハンドルのヒット判定半径（ビュー座標px）です。
    const ZOOM_MIN: float = 1.0
    const ZOOM_MAX: float = 16.0

    var tool_ref  # SpriteDefinitionTool 本体への参照です。
    var zoom: float = 4.0
    var pan: Vector2 = Vector2(32.0, 112.0)
    var drag_mode: int = DRAG_NONE
    var drag_edges: int = 0
    var drag_offset: Vector2i = Vector2i.ZERO   # 移動ドラッグ時の「矩形左上−マウス」差分です。
    var drag_anchor: Vector2i = Vector2i.ZERO   # 新規作成・リサイズの基準点（アトラス座標）です。

    # [AtlasView._init]
    # 処理内容: ツール本体への参照を受け取ります。
    # 引数 owner_tool: SpriteDefinitionTool です。
    func _init(owner_tool) -> void:
        tool_ref = owner_tool
        return  # end of function
    # [AtlasView._init]END

    # [AtlasView.to_view]
    # 処理内容: アトラス座標をビュー座標へ変換します。
    func to_view(atlas_pos: Vector2) -> Vector2:
        return atlas_pos * zoom + pan
    # [AtlasView.to_view]END

    # [AtlasView.to_atlas]
    # 処理内容: ビュー座標をアトラス座標へ変換します。
    func to_atlas(view_pos: Vector2) -> Vector2:
        return (view_pos - pan) / zoom
    # [AtlasView.to_atlas]END

    # [AtlasView._draw]
    # 処理内容: 下地・テクスチャ・グリッド・フレーム矩形・編集ハンドルを描画します。
    func _draw() -> void:
        # 下地です。
        draw_rect(Rect2(Vector2.ZERO, size), Color(0.13, 0.13, 0.16, 1.0), true)
        var font := get_theme_default_font()
        draw_string(font, Vector2(32.0, 44.0), "アトラスプレビュー",
            HORIZONTAL_ALIGNMENT_LEFT, -1.0, TOOL_DRAW_FONT_SIZE, Color(0.9, 0.9, 0.9, 1.0))
        var texture: Texture2D = tool_ref.get_current_texture()
        if texture == null:
            draw_string(font, Vector2(32.0, 88.0),
                "アトラス画像がありません（「読込」または右の「画像ファイルを追加...」を確認）",
                HORIZONTAL_ALIGNMENT_LEFT, -1.0, TOOL_DRAW_INFO_FONT_SIZE, Color(0.8, 0.8, 0.8, 1.0))
            return

        # 透明部が分かるように、テクスチャ領域へ市松模様を敷きます。
        var tex_size := Vector2(float(texture.get_width()), float(texture.get_height()))
        var sprite: Dictionary = tool_ref.get_current_sprite()
        draw_string(font, Vector2(32.0, 88.0),
            "%s | %d x %d px | zoom %.2fx" % [
                String(sprite.get("atlas", "")), texture.get_width(), texture.get_height(), zoom
            ],
            HORIZONTAL_ALIGNMENT_LEFT, -1.0, TOOL_DRAW_INFO_FONT_SIZE, Color(0.72, 0.72, 0.76, 1.0))
        var tex_view_rect := Rect2(to_view(Vector2.ZERO), tex_size * zoom)
        draw_rect(tex_view_rect, Color(0.22, 0.22, 0.26, 1.0), true)
        var cell: float = 16.0
        var cell_origin := tex_view_rect.position
        var col_count: int = int(ceil(tex_view_rect.size.x / cell))
        var row_count: int = int(ceil(tex_view_rect.size.y / cell))
        for row in range(row_count):
            for col in range(col_count):
                if (row + col) % 2 == 0:
                    continue
                var cell_rect := Rect2(
                    cell_origin + Vector2(float(col) * cell, float(row) * cell),
                    Vector2(cell, cell)
                )
                # テクスチャ領域からはみ出すセルは切り詰めます。
                cell_rect = cell_rect.intersection(tex_view_rect)
                if cell_rect.size.x > 0.0 and cell_rect.size.y > 0.0:
                    draw_rect(cell_rect, Color(0.27, 0.27, 0.31, 1.0), true)

        # テクスチャ本体です（texture_filter=NEAREST によりドット絵のまま拡大されます）。
        draw_texture_rect(texture, tex_view_rect, false)

        # グリッドです（拡大率が低いときは省略します）。
        if zoom >= 4.0:
            var grid_step: float = 8.0
            var grid_color := Color(1.0, 1.0, 1.0, 0.07)
            var grid_x: float = 0.0
            while grid_x <= tex_size.x:
                draw_line(to_view(Vector2(grid_x, 0.0)), to_view(Vector2(grid_x, tex_size.y)), grid_color, 1.0)
                grid_x += grid_step
            var grid_y: float = 0.0
            while grid_y <= tex_size.y:
                draw_line(to_view(Vector2(0.0, grid_y)), to_view(Vector2(tex_size.x, grid_y)), grid_color, 1.0)
                grid_y += grid_step

        # フレーム矩形のオーバーレイです。先頭（編集対象）は緑、選択中フレームは橙、
        # その他は半透明黄で描きます。
        var frames: Array[Rect2] = tool_ref.get_display_frames()
        for frame_index in range(frames.size()):
            var frame_view := Rect2(to_view(frames[frame_index].position), frames[frame_index].size * zoom)
            var frame_color := Color(1.0, 1.0, 0.2, 0.4)
            if frame_index == 0:
                frame_color = Color(0.2, 1.0, 0.3, 0.9)
            elif frame_index == tool_ref.current_frame:
                frame_color = Color(1.0, 0.6, 0.1, 0.9)
            draw_rect(frame_view, frame_color, false, 1.0)

        # 編集対象矩形のハンドル（四隅＋四辺中点）です。
        var edit_rect: Rect2i = tool_ref.get_edit_rect()
        if edit_rect.size.x > 0 and edit_rect.size.y > 0:
            var handle_color := Color(0.2, 1.0, 0.3, 1.0)
            for handle_pos in get_handle_positions(edit_rect):
                draw_rect(Rect2(handle_pos - Vector2(6.0, 6.0), Vector2(12.0, 12.0)), handle_color, true)

            # 範囲外警告です。アトラスから食み出した編集矩形は赤枠を重ねます。
            if edit_rect.position.x < 0 or edit_rect.position.y < 0 \
                    or edit_rect.end.x > int(tex_size.x) or edit_rect.end.y > int(tex_size.y):
                var warn_view := Rect2(to_view(Vector2(edit_rect.position)), Vector2(edit_rect.size) * zoom)
                draw_rect(warn_view, Color(1.0, 0.2, 0.2, 0.9), false, 2.0)
        return  # end of function
    # [AtlasView._draw]END

    # [AtlasView.get_handle_positions]
    # 処理内容: 編集矩形の四隅と四辺中点、計8個のハンドル位置（ビュー座標）を返します。
    # 引数 edit_rect: 編集対象矩形（アトラス座標）です。
    # 戻り値: ハンドル位置の PackedVector2Array です。
    func get_handle_positions(edit_rect: Rect2i) -> PackedVector2Array:
        var top_left := to_view(Vector2(edit_rect.position))
        var bottom_right := to_view(Vector2(edit_rect.end))
        var center := (top_left + bottom_right) * 0.5
        var handles := PackedVector2Array()
        handles.append(top_left)
        handles.append(Vector2(center.x, top_left.y))
        handles.append(Vector2(bottom_right.x, top_left.y))
        handles.append(Vector2(top_left.x, center.y))
        handles.append(Vector2(bottom_right.x, center.y))
        handles.append(Vector2(top_left.x, bottom_right.y))
        handles.append(Vector2(center.x, bottom_right.y))
        handles.append(bottom_right)
        return handles
    # [AtlasView.get_handle_positions]END

    # [AtlasView.get_handle_edges]
    # 処理内容: ハンドル添字（get_handle_positionsの並び順）からリサイズ対象辺の
    #           ビットマスクを返します。
    # 引数 handle_index: 0〜7 のハンドル添字です。
    # 戻り値: EDGE_* のビットマスクです。
    func get_handle_edges(handle_index: int) -> int:
        match handle_index:
            0:
                return EDGE_LEFT | EDGE_TOP
            1:
                return EDGE_TOP
            2:
                return EDGE_RIGHT | EDGE_TOP
            3:
                return EDGE_LEFT
            4:
                return EDGE_RIGHT
            5:
                return EDGE_LEFT | EDGE_BOTTOM
            6:
                return EDGE_BOTTOM
            7:
                return EDGE_RIGHT | EDGE_BOTTOM
        return 0
    # [AtlasView.get_handle_edges]END

    # [AtlasView._gui_input]
    # 処理内容: マウス操作を処理します。ホイール=ズーム、中ボタン=パン、
    #           左ボタン=ハンドルリサイズ／矩形移動／空き領域での新規矩形指定です。
    # 引数 event: 入力イベントです。
    func _gui_input(event: InputEvent) -> void:
        if event is InputEventMouseButton:
            var button := event as InputEventMouseButton
            if button.button_index == MOUSE_BUTTON_WHEEL_UP and button.pressed:
                apply_zoom(1.25, button.position)
                accept_event()
                return
            if button.button_index == MOUSE_BUTTON_WHEEL_DOWN and button.pressed:
                apply_zoom(1.0 / 1.25, button.position)
                accept_event()
                return
            if button.button_index == MOUSE_BUTTON_MIDDLE:
                drag_mode = DRAG_PAN if button.pressed else DRAG_NONE
                accept_event()
                return
            if button.button_index == MOUSE_BUTTON_LEFT:
                if button.pressed:
                    start_left_drag(button.position)
                else:
                    if drag_mode != DRAG_NONE and drag_mode != DRAG_PAN:
                        # ドラッグ編集の完了を1回のUndo単位として記録します。
                        tool_ref.commit_edit()
                    drag_mode = DRAG_NONE
                accept_event()
                return
        if event is InputEventMouseMotion:
            var motion := event as InputEventMouseMotion
            if drag_mode == DRAG_PAN:
                pan += motion.relative
                queue_redraw()
                accept_event()
            elif drag_mode == DRAG_MOVE:
                var atlas_pos := to_atlas(motion.position)
                var rect: Rect2i = tool_ref.get_edit_rect()
                rect.position = Vector2i(int(round(atlas_pos.x)), int(round(atlas_pos.y))) + drag_offset
                tool_ref.set_edit_rect(rect)
                accept_event()
            elif drag_mode == DRAG_RESIZE:
                apply_resize_drag(motion.position)
                accept_event()
            elif drag_mode == DRAG_CREATE:
                apply_create_drag(motion.position)
                accept_event()
        return  # end of function
    # [AtlasView._gui_input]END

    # [AtlasView.apply_zoom]
    # 処理内容: マウス位置を中心にズーム倍率を変更します（その点のアトラス座標を維持）。
    # 引数 factor: 倍率の掛け率です。
    # 引数 pivot_view: ズーム中心のビュー座標です。
    func apply_zoom(factor: float, pivot_view: Vector2) -> void:
        var new_zoom: float = clampf(zoom * factor, ZOOM_MIN, ZOOM_MAX)
        if is_equal_approx(new_zoom, zoom):
            return
        var pivot_atlas := to_atlas(pivot_view)
        zoom = new_zoom
        pan = pivot_view - pivot_atlas * zoom
        queue_redraw()
        tool_ref.update_status()
        return  # end of function
    # [AtlasView.apply_zoom]END

    # [AtlasView.start_left_drag]
    # 処理内容: 左ボタン押下時のドラッグ種別を決めます。
    #           ハンドル上=リサイズ、編集矩形内=移動、それ以外=新規矩形指定です。
    # 引数 view_pos: 押下位置のビュー座標です。
    func start_left_drag(view_pos: Vector2) -> void:
        var edit_rect: Rect2i = tool_ref.get_edit_rect()
        if edit_rect.size.x > 0 and edit_rect.size.y > 0:
            # ハンドルのヒット判定です。
            var handles := get_handle_positions(edit_rect)
            for handle_index in range(handles.size()):
                if handles[handle_index].distance_to(view_pos) <= HANDLE_HIT_RADIUS:
                    drag_mode = DRAG_RESIZE
                    drag_edges = get_handle_edges(handle_index)
                    return
            # 矩形内側なら移動です。移動中の相対位置を保つため差分を記録します。
            var atlas_pos := to_atlas(view_pos)
            var atlas_point := Vector2i(int(floor(atlas_pos.x)), int(floor(atlas_pos.y)))
            if edit_rect.has_point(atlas_point):
                drag_mode = DRAG_MOVE
                drag_offset = edit_rect.position - atlas_point
                return
        # 空き領域からのドラッグは新規矩形の指定です（現在の編集対象を上書きします）。
        var anchor := to_atlas(view_pos)
        drag_anchor = Vector2i(int(round(anchor.x)), int(round(anchor.y)))
        drag_mode = DRAG_CREATE
        tool_ref.set_edit_rect(Rect2i(drag_anchor, Vector2i(1, 1)))
        return  # end of function
    # [AtlasView.start_left_drag]END

    # [AtlasView.apply_resize_drag]
    # 処理内容: リサイズドラッグ中の矩形更新です。drag_edges の辺だけを動かします。
    # 引数 view_pos: 現在のマウス位置（ビュー座標）です。
    func apply_resize_drag(view_pos: Vector2) -> void:
        var atlas_pos := to_atlas(view_pos)
        var mouse_atlas := Vector2i(int(round(atlas_pos.x)), int(round(atlas_pos.y)))
        var rect: Rect2i = tool_ref.get_edit_rect()
        var left: int = rect.position.x
        var top: int = rect.position.y
        var right: int = rect.end.x
        var bottom: int = rect.end.y
        if drag_edges & EDGE_LEFT:
            left = mini(mouse_atlas.x, right - 1)
        if drag_edges & EDGE_RIGHT:
            right = maxi(mouse_atlas.x, left + 1)
        if drag_edges & EDGE_TOP:
            top = mini(mouse_atlas.y, bottom - 1)
        if drag_edges & EDGE_BOTTOM:
            bottom = maxi(mouse_atlas.y, top + 1)
        tool_ref.set_edit_rect(Rect2i(left, top, right - left, bottom - top))
        return  # end of function
    # [AtlasView.apply_resize_drag]END

    # [AtlasView.apply_create_drag]
    # 処理内容: 新規矩形指定ドラッグ中の更新です。アンカー点と現在点を対角とする
    #           矩形を編集対象へ反映します。
    # 引数 view_pos: 現在のマウス位置（ビュー座標）です。
    func apply_create_drag(view_pos: Vector2) -> void:
        var atlas_pos := to_atlas(view_pos)
        var mouse_atlas := Vector2i(int(round(atlas_pos.x)), int(round(atlas_pos.y)))
        var left: int = mini(drag_anchor.x, mouse_atlas.x)
        var top: int = mini(drag_anchor.y, mouse_atlas.y)
        var right: int = maxi(drag_anchor.x, mouse_atlas.x)
        var bottom: int = maxi(drag_anchor.y, mouse_atlas.y)
        tool_ref.set_edit_rect(Rect2i(left, top, maxi(right - left, 1), maxi(bottom - top, 1)))
        return  # end of function
    # [AtlasView.apply_create_drag]END

# ═══════════════════════════════════════════════════════════════════════════
#  内部クラス②: AnimPreview（アニメーション／回転生成プレビュー）
# ═══════════════════════════════════════════════════════════════════════════

class AnimPreview extends Control:
    const PREVIEW_SCALE_LARGE: float = 4.0  # 拡大表示の倍率です。

    var tool_ref  # SpriteDefinitionTool 本体への参照です。
    var play_frame: float = 0.0  # 再生中の現在フレーム（小数で進めて int で表示）です。

    # [AnimPreview._init]
    # 処理内容: ツール本体への参照を受け取ります。
    # 引数 owner_tool: SpriteDefinitionTool です。
    func _init(owner_tool) -> void:
        tool_ref = owner_tool
        return  # end of function
    # [AnimPreview._init]END

    # [AnimPreview.reset_playback]
    # 処理内容: 再生位置を先頭フレームへ戻します（選択変更・パラメータ変更時）。
    func reset_playback() -> void:
        play_frame = 0.0
        return  # end of function
    # [AnimPreview.reset_playback]END

    # [AnimPreview._process]
    # 処理内容: アニメ再生を進めます。再生間隔は anim_speed_spin（表示フレーム数）です。
    #           rotated レイアウトは方向スライダーで確認するため自動再生しません。
    # 引数 delta: 前フレームからの経過秒です。
    func _process(delta: float) -> void:
        var sprite: Dictionary = tool_ref.get_current_sprite()
        if sprite.is_empty():
            return
        if String(sprite.get("layout", "")) == SpriteDefs.LAYOUT_ROTATED:
            queue_redraw()
            return
        var total: int = tool_ref.get_preview_frame_count()
        if total > 1:
            # 60fps換算で every_frames 表示フレームごとに1コマ進めます。
            var every_frames: float = maxf(float(tool_ref.anim_speed_spin.value), 1.0)
            play_frame += delta * 60.0 / every_frames
            if play_frame >= float(total):
                play_frame = fmod(play_frame, float(total))
        queue_redraw()
        return  # end of function
    # [AnimPreview._process]END

    # [AnimPreview._draw]
    # 処理内容: 現在フレームを等倍と拡大の2つ並べて描画します。
    #           rotated/spin は生成済みプレビューアトラス、それ以外は元アトラスから
    #           切り出して描きます。
    func _draw() -> void:
        draw_rect(Rect2(Vector2.ZERO, size), Color(0.09, 0.09, 0.11, 1.0), true)
        var font := get_theme_default_font()
        draw_string(font, Vector2(32.0, 44.0), "スプライトプレビュー",
            HORIZONTAL_ALIGNMENT_LEFT, -1.0, TOOL_DRAW_FONT_SIZE, Color(0.9, 0.9, 0.9, 1.0))
        var sprite: Dictionary = tool_ref.get_current_sprite()
        if sprite.is_empty():
            draw_string(font, Vector2(32.0, 92.0), "スプライト未選択",
                HORIZONTAL_ALIGNMENT_LEFT, -1.0, TOOL_DRAW_INFO_FONT_SIZE, Color(0.76, 0.76, 0.8, 1.0))
            return

        # 描画に使うテクスチャとフレーム列を決めます。
        var layout: String = String(sprite.get("layout", ""))
        var texture: Texture2D = null
        var frames: Array[Rect2] = []
        if layout == SpriteDefs.LAYOUT_ROTATED or layout == SpriteDefs.LAYOUT_SPIN:
            tool_ref.ensure_rotation_preview()
            texture = tool_ref.rotation_preview_texture
            frames = tool_ref.rotation_preview_frames
            if texture == null:
                draw_string(font, Vector2(32.0, 92.0),
                    "回転プレビューを生成できません（矩形またはアトラスが未設定です）",
                    HORIZONTAL_ALIGNMENT_LEFT, -1.0, TOOL_DRAW_INFO_FONT_SIZE, Color(0.8, 0.8, 0.8, 1.0))
                return
        else:
            texture = tool_ref.get_current_texture()
            frames = SpriteDefs.build_frames(sprite)
        if texture == null or frames.is_empty():
            draw_string(font, Vector2(32.0, 92.0), "プレビュー対象の画像またはフレームがありません",
                HORIZONTAL_ALIGNMENT_LEFT, -1.0, TOOL_DRAW_INFO_FONT_SIZE, Color(0.76, 0.76, 0.8, 1.0))
            return

        # 表示フレームを決めます。rotatedはスライダー選択、それ以外は自動再生です。
        var frame_index: int = 0
        if layout == SpriteDefs.LAYOUT_ROTATED:
            frame_index = clampi(tool_ref.current_frame, 0, frames.size() - 1)
        else:
            frame_index = clampi(int(play_frame), 0, frames.size() - 1)
        var src_rect: Rect2 = frames[frame_index]

        # 等倍と拡大を横へ並べます。
        var draw_x: float = 32.0
        var base_y: float = (size.y - src_rect.size.y) * 0.5
        draw_texture_rect_region(texture, Rect2(Vector2(draw_x, base_y), src_rect.size), src_rect)
        draw_x += src_rect.size.x + 48.0
        var large_size := src_rect.size * PREVIEW_SCALE_LARGE
        var large_y: float = (size.y - large_size.y) * 0.5
        draw_texture_rect_region(texture, Rect2(Vector2(draw_x, large_y), large_size), src_rect)

        # フレーム番号の表示です。
        draw_string(font, Vector2(draw_x + large_size.x + 48.0, size.y * 0.5),
            "frame %d / %d | %s | %dx%d" % [
                frame_index + 1, frames.size(), layout, int(src_rect.size.x), int(src_rect.size.y)
            ],
            HORIZONTAL_ALIGNMENT_LEFT, -1.0, TOOL_DRAW_INFO_FONT_SIZE, Color(0.8, 0.8, 0.8, 1.0))
        return  # end of function
    # [AnimPreview._draw]END
