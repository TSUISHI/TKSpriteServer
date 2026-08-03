#ifndef TK_SPRITE_SERVER_NATIVE_H
#define TK_SPRITE_SERVER_NATIVE_H

// ===========================================================================
// TKSpriteServerNative — GDExtension C++ スプライトサーバー（公開版コア）
// ===========================================================================
// 2Dレトロゲーム向けに内製した SpriteServerNative（sprite_server_native.h/.cpp）から、
// ゲーム固有機能（ネイティブ敵弾・点数アイテム・粒粒地形・MultiMesh バッチ）
// を一切持ち込まずに汎用部分だけを新規に書き起こしたクラス。
//
// 挙動の正解は tk_sprite_server_gd.gd（GDScript版・動作確認済み）であり、
// このネイティブ版は同じ見た目・同じ挙動になるように実装する。
//
// 主な責務:
//   1. スプライトプール管理 (allocate_link_id / update_sprite / destroy_sprite)
//   2. canvas_item 経由の直接描画（dirty フラグで差分更新するため高速）
//   3. スプライト文字HUD (init_sprite_text / sprlocate / sprprint / sprprintint / sprcls)
//   4. 一時スプライト (request_draw → commit_frame で自動破棄)
//   5. 拡大縮小と反転（FLIP/FLOP）
//
// 描画レイヤー (plane_type):
//   0=back, 1=medium(デフォルト), 2=front, 3=effect, 4=text
//
// 移植元からの主な変更点:
//   - プール上限 MAX_SPRITES(定数50000) を可変の max_sprites(既定4096) にし、
//     setup() で確保タイミングと上限を選べるようにした。コンストラクタでは
//     確保せず、_ready()(NOTIFICATION_READY) 時点で未確保なら既定値で確保する。
//   - pixel_snap も定数からメンバ変数へ変更した。
//   - SpriteData の sx/sy（未使用だった）を flip_h/flip_v（bool）へ置き換え、
//     commit_frame() の transform で実際に反転を描画へ反映するようにした。
//   - 通常スプライトの MultiMesh バッチ経路（batches/BatchData/init_multimesh）
//     は canvas_item 経路と二重描画になるため公開版から外した
//     （設計書 §4.4.3 案B）。
// ===========================================================================

#include <godot_cpp/classes/node2d.hpp>
#include <godot_cpp/templates/hash_map.hpp>
#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/rid.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector2i.hpp>

#include <vector>

namespace godot {

class TKSpriteServerNative : public Node2D {
    GDCLASS(TKSpriteServerNative, Node2D)

private:
    // -----------------------------------------------------------------------
    // 定数
    // -----------------------------------------------------------------------
    static constexpr int DEFAULT_MAX_SPRITES = 4096; // setup() 未呼び出し時に _ready() が使う既定プール上限

    // -----------------------------------------------------------------------
    // SpriteData — スプライト1枚分の状態
    // -----------------------------------------------------------------------
    // アクティブな各スプライトは pool[] に格納される。
    // dirty フラグで RenderingServer への更新を必要最小限に抑えている
    // （この最適化がネイティブ版の速さの理由であり、GDScript版には無い）。
    struct SpriteData {
        bool active = false;        // このスロットが使用中かどうか
        int active_index = -1;      // active_link_ids[] 内での位置（swap-with-last 用）
        int sprite_id = -1;         // 使用するスプライト種別ID（テクスチャ・フレーム定義を引く）
        int plane_type = 1;         // 描画レイヤー: 0=back, 1=medium, 2=front, 3=effect, 4=text
        int priority = 0;           // 同レイヤー内の描画順（draw_index）
        RID rid;                    // RenderingServer が管理する canvas_item の RID
        RID plane_rid;              // 現在紐付いている親プレーン canvas_item の RID
        float x = 0.0f;             // 描画 X 座標
        float y = 0.0f;             // 描画 Y 座標
        float frame = 0.0f;         // アニメーションフレーム番号
        bool flip_h = false;        // 左右反転
        bool flip_v = false;        // 上下反転
        Vector2 draw_size;           // link単位の描画サイズ。ZEROならsprite_id既定サイズ
        Color color = Color(1, 1, 1, 1); // 乗算カラー（アルファ含む）
        bool parent_dirty = true;         // 親プレーン変更が必要か
        bool draw_index_dirty = true;     // 描画順変更が必要か
        bool transform_dirty = true;      // 座標/反転/実効サイズ変更が必要か
        bool visual_dirty = true;         // フレーム/カラー/サイズ変更が必要か
    };

    // -----------------------------------------------------------------------
    // スプライトプール本体
    // -----------------------------------------------------------------------
    int max_sprites = DEFAULT_MAX_SPRITES; // 同時に発行できるlink_idの上限（setup()で変更可、生成後は不変）
    bool pixel_snap = true;                // 描画座標を整数ピクセルへ丸めるかどうか
    bool pool_allocated = false;           // _allocate_pool() を実行済みかどうか（二重確保防止）

    std::vector<SpriteData> pool;           // サイズ max_sprites のスプライトスロット配列
    std::vector<int> free_ids;              // 未使用スロットのIDスタック（LIFO）
    std::vector<int> active_link_ids;       // アクティブスロットのIDリスト（[0, active_link_count) が有効）
    std::vector<int> transient_link_ids;    // request_draw() で作った一時リンク（commit_frame 後に自動破棄）

    HashMap<int, Vector2> sprite_draw_sizes; // sprite_id → 描画サイズ

    // -----------------------------------------------------------------------
    // テクスチャ辞書（GDScript から受け取る）
    // -----------------------------------------------------------------------
    // sprite_textures[sprite_id] = { "texture": Texture2D, "frames": [Rect2, ...] }
    // または { "texture": Texture2D, "rect": Rect2 }
    Dictionary sprite_textures;

    // -----------------------------------------------------------------------
    // 描画プレーン RID（利用者側の SubViewport canvas から渡される）
    // -----------------------------------------------------------------------
    RID back_plane_rid;     // 背面レイヤー（plane_type=0）
    RID medium_plane_rid;   // 中間レイヤー（plane_type=1、デフォルト）
    RID front_plane_rid;    // 前面レイヤー（plane_type=2）
    RID effect_plane_rid;   // エフェクトレイヤー（plane_type=3）
    RID text_plane_rid;     // スプライト文字レイヤー（plane_type=4）

    // スプライト文字HUDの固定グリッドです。空白セルのglyphは-1です。
    std::vector<int> sprite_text_link_ids;
    std::vector<int> sprite_text_glyphs;
    int sprite_text_cols = 0;
    int sprite_text_rows = 0;
    int sprite_text_cell_width = 0;
    int sprite_text_cell_height = 0;
    int sprite_text_glyph_base_id = 0;
    int sprite_text_plane_type = 4;
    int sprite_text_priority = 0;
    int sprite_text_cursor_col = 0;
    int sprite_text_cursor_row = 0;

    int active_link_count = 0;      // 現在アクティブなスプライト数
    bool sprite_buffer_over = false; // max_sprites を超えようとしたときに立つフラグ

    // -----------------------------------------------------------------------
    // プライベートヘルパー関数
    // -----------------------------------------------------------------------
    // sprite_slots / active_link_ids を max_sprites 個ぶん確保し、free_idsを満杯状態で初期化する
    void _allocate_pool();
    // plane_type 番号から対応するプレーン RID を返す
    RID get_plane_rid(int plane_type) const;
    // スロットの実効描画サイズを返す（draw_sizeが正値ならそれ、でなければget_sprite_draw_size()の既定サイズ）
    Vector2 get_slot_effective_draw_size(const SpriteData &data) const;
    // update_sprite / update_sprite_stretched の共通実装。
    // reset_draw_size=true のとき draw_size をゼロへ戻す（update_sprite の従来挙動）。
    // stretched/scaled 系から呼ぶときは false を渡す。true で通すと
    // 「毎フレーム同じサイズを指定しているだけ」でも draw_size が
    // 非ゼロ→ゼロ→非ゼロと往復して visual_dirty が必ず立ち、
    // dirty フラグ最適化が丸ごと無効化されてしまうため。
    void update_sprite_internal(int link_id, Vector2 pos, int frame, Color color, int plane_type, int priority, bool reset_draw_size);
    // 座標をピクセルにスナップする（ちらつき防止）。pixel_snap=falseなら何もしない
    Vector2 snap_render_position(Vector2 pos) const;
    // 1スプライトをテクスチャ矩形として canvas_item に描画する
    // effective_draw_size は commit_frame 側で算出済みの値を渡す（1スプライトあたり2回計算しない）
    void draw_slot(const RID &rid, const SpriteData &data, const Vector2 &effective_draw_size);
    // transient_link_ids に積まれた一時リンクを全て破棄する
    void clear_transient_links();
    // カーソル位置に1グリフ分のスプライトを配置・更新・撤去し、カーソルを1つ進める（sprprint/sprprintint共通）
    void _sprite_text_put(int glyph_index);

protected:
    // GDScript から呼び出せるよう ClassDB にメソッドを登録する
    static void _bind_methods();
    // NOTIFICATION_READY で setup() 未呼び出しなら既定値でプールを確保する
    void _notification(int p_what);

public:
    TKSpriteServerNative();
    ~TKSpriteServerNative();

    // -----------------------------------------------------------------------
    // 初期化 API
    // -----------------------------------------------------------------------
    // プール上限とピクセルスナップ設定を確定してからスロットを確保し直す。
    // _ready()より前でも後でも呼べる。既に確保済みだった場合は先に全RIDを解放してから再確保する。
    void setup(int p_max_sprites = 4096, bool p_pixel_snap = true);
    // 描画レイヤーの canvas_item RID を設定する（SubViewport のセットアップ後に呼ぶ）
    void set_plane_rids(RID back, RID medium, RID front);
    // エフェクトレイヤーの RID を別途設定する（plane_type=3 用）
    void set_effect_plane_rid(RID plane_rid);
    void set_text_plane_rid(RID plane_rid);
    void init_sprite_text(int cols, int rows, int cell_width, int cell_height, int glyph_base_id, int plane_type, int priority);
    void sprlocate(int col, int row);
    void sprprint(const String &text);
    void sprprintint(int value, int digits);
    void sprcls();
    // sprite_id の描画サイズを登録する（境界ボックス計算・カリングに使用）
    void set_sprite_draw_size(int sprite_id, Vector2 size);
    // sprite_id の描画サイズを返す（未登録なら 16x16）
    Vector2 get_sprite_draw_size(int sprite_id) const;

    // -----------------------------------------------------------------------
    // スプライト管理 API（毎フレーム呼ばれる中心 API）
    // -----------------------------------------------------------------------
    // スプライトスロットを確保してリンクIDを返す（-1 なら枯渇）
    int allocate_link_id(int sprite_id, bool flip_h = false, bool flip_v = false, int plane_type = 1, int priority = 0);
    // リンクIDのスプライト状態を更新する（dirty フラグのみ立て、実描画は commit_frame で行う）
    // draw_sizeは毎回ゼロへリセットする。flip状態はここではリセットしない。
    void update_sprite(int link_id, Vector2 pos, int frame = 0, Color color = Color(1, 1, 1, 1), int plane_type = -1, int priority = -1);
    // リンクIDを指定した表示矩形サイズ(絶対ピクセル)へ拡縮して更新する
    void update_sprite_stretched(int link_id, Vector2 pos, Vector2 draw_size, int frame = 0, Color color = Color(1, 1, 1, 1), int plane_type = -1, int priority = -1);
    // 元スプライトの基準サイズ(get_sprite_draw_size)に倍率scaleを掛けてupdate_sprite_stretched()と同じ経路で反映する
    void update_sprite_scaled(int link_id, Vector2 pos, Vector2 scale, int frame = 0, Color color = Color(1, 1, 1, 1), int plane_type = -1, int priority = -1);
    // 発行済みlink_idの反転状態を実行中に切り替える（transform_dirtyのみ立てる）
    void set_sprite_flip(int link_id, bool flip_h, bool flip_v);
    // 発行済みlink_idの現在の反転状態を返す（x=flip_h, y=flip_v。0/1）
    Vector2i get_sprite_flip(int link_id) const;
    // 発行済みlink_idに紐づくsprite_idを返す（無効なら-1）
    int get_sprite_id_from_link(int link_id) const;
    // リンクIDのスプライトを破棄し、スロットを返却する
    void destroy_sprite(int link_id);

    // -----------------------------------------------------------------------
    // 単発描画（一時スプライト）
    // -----------------------------------------------------------------------
    // 1フレームだけ表示したいスプライトをリクエストする（commit_frame 後に自動破棄）
    void request_draw(int sprite_id, Vector2 pos, bool flip_h, bool flip_v, int plane_type, int priority);

    // -----------------------------------------------------------------------
    // フレーム終端処理
    // -----------------------------------------------------------------------
    // flush_and_decay: commit_frame の別名（後方互換用）
    void flush_and_decay();
    // dirty フラグを処理して RenderingServer に変更を一括送信する
    void commit_frame();

    // -----------------------------------------------------------------------
    // クリーンアップ
    // -----------------------------------------------------------------------
    void clear_all();       // free_all_rids の別名
    void free_all_rids();   // 全スプライト・全 RID を解放してプールを初期化する

    // -----------------------------------------------------------------------
    // 統計
    // -----------------------------------------------------------------------
    // active_link_count / max_sprites / free_count / sprite_buffer_over / backend("native") を返す
    Dictionary get_stats() const;

    // -----------------------------------------------------------------------
    // プロパティアクセサ（Godot Inspector / GDScript 用）
    // -----------------------------------------------------------------------
    Dictionary get_sprite_textures() const;
    void set_sprite_textures(Dictionary value);
    int get_active_link_count() const;
    void set_active_link_count(int value);
    bool get_sprite_buffer_over() const;
    void set_sprite_buffer_over(bool value);
};

}

#endif // TK_SPRITE_SERVER_NATIVE_H
