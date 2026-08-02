// ===========================================================================
// tk_sprite_server_native.cpp — TKSpriteServerNative 実装
// ===========================================================================
// GDExtension C++ 側でスプライト描画を担うクラスの実装。
// GDScript 側からリンクID経由で呼ばれることを前提に設計されている。
//
// 主な設計方針:
//   - スプライトプールは setup()/_ready() 時に一度だけ確保し、以後動的確保なし
//   - アクティブリストは swap-with-last で O(1) 削除を実現
//   - dirty フラグにより RenderingServer への呼び出しを最小化
//   - 反転(FLIP/FLOP)は canvas_item の transform スケール符号で表現し、
//     左上基準のずれを ox/oy で補正する（GDScript版 commit_frame と同じ数式）
// ===========================================================================

#include "tk_sprite_server_native.h"

#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/classes/texture2d.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/property_info.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/rect2.hpp>
#include <godot_cpp/variant/transform2d.hpp>

#include <algorithm>
#include <cmath>

using namespace godot;

// ---------------------------------------------------------------------------
// _bind_methods — GDScript から呼べるようにメソッドを ClassDB に登録する
// ---------------------------------------------------------------------------
// D_METHOD の第2引数以降は GDScript 側でのパラメータ名（デバッガ・補完に使われる）。
// DEFVAL() でデフォルト引数を指定できる（後ろから順に省略可能）。
void TKSpriteServerNative::_bind_methods() {
    // 初期化系
    ClassDB::bind_method(D_METHOD("setup", "max_sprites", "pixel_snap"), &TKSpriteServerNative::setup, DEFVAL(4096), DEFVAL(true));
    ClassDB::bind_method(D_METHOD("set_plane_rids", "back", "medium", "front"), &TKSpriteServerNative::set_plane_rids);
    ClassDB::bind_method(D_METHOD("set_effect_plane_rid", "plane_rid"), &TKSpriteServerNative::set_effect_plane_rid);
    ClassDB::bind_method(D_METHOD("set_text_plane_rid", "plane_rid"), &TKSpriteServerNative::set_text_plane_rid);
    ClassDB::bind_method(D_METHOD("init_sprite_text", "cols", "rows", "cell_width", "cell_height", "glyph_base_id", "plane_type", "priority"), &TKSpriteServerNative::init_sprite_text);
    ClassDB::bind_method(D_METHOD("sprlocate", "col", "row"), &TKSpriteServerNative::sprlocate);
    ClassDB::bind_method(D_METHOD("sprprint", "text"), &TKSpriteServerNative::sprprint);
    ClassDB::bind_method(D_METHOD("sprprintint", "value", "digits"), &TKSpriteServerNative::sprprintint);
    ClassDB::bind_method(D_METHOD("sprcls"), &TKSpriteServerNative::sprcls);
    ClassDB::bind_method(D_METHOD("set_sprite_draw_size", "sprite_id", "size"), &TKSpriteServerNative::set_sprite_draw_size);
    ClassDB::bind_method(D_METHOD("get_sprite_draw_size", "sprite_id"), &TKSpriteServerNative::get_sprite_draw_size);

    // スプライト管理（毎フレーム呼ばれる中心 API）
    ClassDB::bind_method(D_METHOD("allocate_link_id", "sprite_id", "flip_h", "flip_v", "plane_type", "priority"), &TKSpriteServerNative::allocate_link_id, DEFVAL(false), DEFVAL(false), DEFVAL(1), DEFVAL(0));
    ClassDB::bind_method(D_METHOD("update_sprite", "link_id", "pos", "frame", "color", "plane_type", "priority"), &TKSpriteServerNative::update_sprite, DEFVAL(0), DEFVAL(Color(1, 1, 1, 1)), DEFVAL(-1), DEFVAL(-1));
    ClassDB::bind_method(D_METHOD("update_sprite_stretched", "link_id", "pos", "draw_size", "frame", "color", "plane_type", "priority"), &TKSpriteServerNative::update_sprite_stretched, DEFVAL(0), DEFVAL(Color(1, 1, 1, 1)), DEFVAL(-1), DEFVAL(-1));
    ClassDB::bind_method(D_METHOD("update_sprite_scaled", "link_id", "pos", "scale", "frame", "color", "plane_type", "priority"), &TKSpriteServerNative::update_sprite_scaled, DEFVAL(0), DEFVAL(Color(1, 1, 1, 1)), DEFVAL(-1), DEFVAL(-1));
    ClassDB::bind_method(D_METHOD("set_sprite_flip", "link_id", "flip_h", "flip_v"), &TKSpriteServerNative::set_sprite_flip);
    ClassDB::bind_method(D_METHOD("get_sprite_flip", "link_id"), &TKSpriteServerNative::get_sprite_flip);
    ClassDB::bind_method(D_METHOD("get_sprite_id_from_link", "link_id"), &TKSpriteServerNative::get_sprite_id_from_link);
    ClassDB::bind_method(D_METHOD("destroy_sprite", "link_id"), &TKSpriteServerNative::destroy_sprite);

    // 単発描画・フレーム管理・クリーンアップ
    ClassDB::bind_method(D_METHOD("request_draw", "sprite_id", "pos", "flip_h", "flip_v", "plane_type", "priority"), &TKSpriteServerNative::request_draw);
    ClassDB::bind_method(D_METHOD("commit_frame"), &TKSpriteServerNative::commit_frame);
    ClassDB::bind_method(D_METHOD("flush_and_decay"), &TKSpriteServerNative::flush_and_decay);
    ClassDB::bind_method(D_METHOD("clear_all"), &TKSpriteServerNative::clear_all);
    ClassDB::bind_method(D_METHOD("free_all_rids"), &TKSpriteServerNative::free_all_rids);

    // 統計
    ClassDB::bind_method(D_METHOD("get_stats"), &TKSpriteServerNative::get_stats);

    // プロパティアクセサ
    ClassDB::bind_method(D_METHOD("get_sprite_textures"), &TKSpriteServerNative::get_sprite_textures);
    ClassDB::bind_method(D_METHOD("set_sprite_textures", "value"), &TKSpriteServerNative::set_sprite_textures);
    ClassDB::bind_method(D_METHOD("get_active_link_count"), &TKSpriteServerNative::get_active_link_count);
    ClassDB::bind_method(D_METHOD("set_active_link_count", "value"), &TKSpriteServerNative::set_active_link_count);
    ClassDB::bind_method(D_METHOD("get_sprite_buffer_over"), &TKSpriteServerNative::get_sprite_buffer_over);
    ClassDB::bind_method(D_METHOD("set_sprite_buffer_over", "value"), &TKSpriteServerNative::set_sprite_buffer_over);

    // Inspector に表示するプロパティ
    ADD_PROPERTY(PropertyInfo(Variant::DICTIONARY, "sprite_textures"), "set_sprite_textures", "get_sprite_textures");
    ADD_PROPERTY(PropertyInfo(Variant::INT, "active_link_count"), "set_active_link_count", "get_active_link_count");
    ADD_PROPERTY(PropertyInfo(Variant::BOOL, "sprite_buffer_over"), "set_sprite_buffer_over", "get_sprite_buffer_over");
}

// ---------------------------------------------------------------------------
// コンストラクタ / デストラクタ
// ---------------------------------------------------------------------------
// プールはここでは確保しない。setup() が明示的に呼ばれるか、
// _ready()(NOTIFICATION_READY) の時点で未確保なら既定値(4096, pixel_snap=true)で確保する。
TKSpriteServerNative::TKSpriteServerNative() {}

// デストラクタは Godot が Node のライフサイクル管理をするため特別な処理不要
TKSpriteServerNative::~TKSpriteServerNative() {}

// ---------------------------------------------------------------------------
// _notification — NOTIFICATION_READY で未確保なら既定値でプールを確保する
// ---------------------------------------------------------------------------
void TKSpriteServerNative::_notification(int p_what) {
    switch (p_what) {
        case NOTIFICATION_READY:
            if (!pool_allocated) {
                _allocate_pool();
            }
            break;
        default:
            break;
    }
}

// ---------------------------------------------------------------------------
// setup — プール上限とピクセルスナップ設定を確定してからスロットを確保し直す
// ---------------------------------------------------------------------------
// 既に確保済みだった場合は先に全RIDを解放してから再確保する。
// 上限は生成後に変えない前提だが、setup() を再度呼ばれた場合はここで対応する。
void TKSpriteServerNative::setup(int p_max_sprites, bool p_pixel_snap) {
    if (pool_allocated) {
        free_all_rids();
    }
    max_sprites = std::max(1, p_max_sprites);
    pixel_snap = p_pixel_snap;
    _allocate_pool();
}

// ---------------------------------------------------------------------------
// _allocate_pool — pool / active_link_ids を max_sprites 個ぶん確保する
// ---------------------------------------------------------------------------
// 降順に free_ids へ積むことで pop_back() 時に 0, 1, 2, ... の順でIDが払い出される。
void TKSpriteServerNative::_allocate_pool() {
    pool.clear();
    pool.resize(max_sprites);
    active_link_ids.assign(max_sprites, -1);
    active_link_count = 0;
    transient_link_ids.clear();
    transient_link_ids.reserve(max_sprites);

    free_ids.clear();
    free_ids.reserve(max_sprites);
    for (int i = max_sprites - 1; i >= 0; --i) {
        free_ids.push_back(i);
    }
    pool_allocated = true;
}

// ---------------------------------------------------------------------------
// set_plane_rids — 3つの描画レイヤーの canvas_item RID を登録する
// ---------------------------------------------------------------------------
// 利用者側の SubViewport が _ready() でノードを作成した後に呼ぶ。
// back=0, medium=1(default), front=2 に対応する。
void TKSpriteServerNative::set_plane_rids(RID back, RID medium, RID front) {
    back_plane_rid = back;
    medium_plane_rid = medium;
    front_plane_rid = front;
}

// エフェクトレイヤー（plane_type=3）の RID を登録する
void TKSpriteServerNative::set_effect_plane_rid(RID plane_rid) {
    effect_plane_rid = plane_rid;
}

// スプライト文字HUDレイヤー（plane_type=4）の RID を登録する
void TKSpriteServerNative::set_text_plane_rid(RID plane_rid) {
    text_plane_rid = plane_rid;
}

// sprite_id の描画サイズ（ピクセル単位）をキャッシュする
void TKSpriteServerNative::set_sprite_draw_size(int sprite_id, Vector2 size) {
    sprite_draw_sizes[sprite_id] = size;
}

// ---------------------------------------------------------------------------
// get_sprite_draw_size — sprite_id の描画サイズを返す
// ---------------------------------------------------------------------------
// sprite_draw_sizes に登録がない場合はフォールバックとして 16×16 を返す。
Vector2 TKSpriteServerNative::get_sprite_draw_size(int sprite_id) const {
    const Vector2 *size = sprite_draw_sizes.getptr(sprite_id);
    if (size != nullptr) {
        return *size;
    }
    return Vector2(16.0, 16.0);  // 未登録スプライトのデフォルトサイズ
}

// ---------------------------------------------------------------------------
// allocate_link_id — 空きスロットを確保してリンクIDを返す
// ---------------------------------------------------------------------------
// スタック先頭の空き ID を取り出し、RenderingServer に canvas_item を生成して
// 指定レイヤー（plane_rid）の子に登録する。
// 返り値 -1 はプール枯渇（sprite_buffer_over フラグも立てる）。
int TKSpriteServerNative::allocate_link_id(int sprite_id, bool flip_h, bool flip_v, int plane_type, int priority) {
    if (free_ids.empty() || active_link_count >= max_sprites) {
        sprite_buffer_over = true;
        return -1;
    }

    int id = free_ids.back();
    free_ids.pop_back();

    SpriteData &data = pool[id];
    data.active = true;
    data.active_index = active_link_count;  // active_link_ids 内の位置
    data.sprite_id = sprite_id;
    data.plane_type = plane_type;
    data.priority = priority;

    // Godot の RenderingServer に canvas_item を作成し、対応レイヤーの子として登録
    data.rid = RenderingServer::get_singleton()->canvas_item_create();
    data.plane_rid = get_plane_rid(plane_type);
    if (data.plane_rid.is_valid()) {
        RenderingServer::get_singleton()->canvas_item_set_parent(data.rid, data.plane_rid);
    }

    // 初期位置は画面外（見えない場所）に設定
    data.frame = 0.0f;
    data.x = -1000.0f;
    data.y = -1000.0f;
    data.flip_h = flip_h;
    data.flip_v = flip_v;
    data.draw_size = Vector2();
    data.color = Color(1, 1, 1, 1);

    // 全 dirty フラグを立てて最初の commit_frame で確実に更新されるようにする
    data.parent_dirty = true;
    data.draw_index_dirty = true;
    data.transform_dirty = true;
    data.visual_dirty = true;

    active_link_ids[active_link_count] = id;
    active_link_count++;
    return id;
}

// ---------------------------------------------------------------------------
// update_sprite — スプライトの位置・フレーム・カラー・レイヤー・優先度を更新する
// ---------------------------------------------------------------------------
// 実際の RenderingServer 呼び出しは commit_frame() に委ねる。
// 変化がない項目の dirty フラグは立てない（無駄な描画コール削減）。
// draw_size はここで毎回ゼロへリセットする。flip_h/flip_v はリセットしない
// （allocate_link_id 時の初期値と set_sprite_flip() でのみ変わる）。
void TKSpriteServerNative::update_sprite(int link_id, Vector2 pos, int frame, Color color, int plane_type, int priority) {
    update_sprite_internal(link_id, pos, frame, color, plane_type, priority, true);
}

// ---------------------------------------------------------------------------
// update_sprite_internal — update_sprite / update_sprite_stretched の共通実装
// ---------------------------------------------------------------------------
// reset_draw_size の意味は宣言側のコメントを参照。
void TKSpriteServerNative::update_sprite_internal(int link_id, Vector2 pos, int frame, Color color, int plane_type, int priority, bool reset_draw_size) {
    if (link_id < 0 || link_id >= static_cast<int>(pool.size())) {
        return;
    }

    SpriteData &data = pool[link_id];
    if (!data.active) {
        return;
    }

    // ピクセルにスナップしてサブピクセルぶれを防ぐ
    Vector2 snapped_pos = snap_render_position(pos);
    const float next_x = static_cast<float>(snapped_pos.x);
    const float next_y = static_cast<float>(snapped_pos.y);
    const float next_frame = static_cast<float>(frame);

    // 座標変化のみ transform_dirty を立てる
    if (data.x != next_x || data.y != next_y) {
        data.x = next_x;
        data.y = next_y;
        data.transform_dirty = true;
    }

    // フレーム、カラー、通常サイズへの復帰時だけ visual_dirty を立てる
    const bool draw_size_was_set = reset_draw_size && (data.draw_size != Vector2());
    if (data.frame != next_frame || data.color != color || draw_size_was_set) {
        data.frame = next_frame;
        data.color = color;
        if (draw_size_was_set) {
            data.draw_size = Vector2();
            // 反転中はdraw_sizeが原点補正(ox/oy)にも影響するため、transformも更新対象にする
            if (data.flip_h || data.flip_v) {
                data.transform_dirty = true;
            }
        }
        data.visual_dirty = true;
    }

    // plane_type が変わった場合は親 canvas_item の付け替えが必要
    if (plane_type >= 0 && data.plane_type != plane_type) {
        data.plane_type = plane_type;
        data.parent_dirty = true;
    }
    // priority（描画順）が変わった場合
    if (priority >= 0 && data.priority != priority) {
        data.priority = priority;
        data.draw_index_dirty = true;
    }
}

// ---------------------------------------------------------------------------
// update_sprite_stretched — link単位の表示矩形サイズ(絶対ピクセル)を指定して更新する
// ---------------------------------------------------------------------------
void TKSpriteServerNative::update_sprite_stretched(int link_id, Vector2 pos, Vector2 draw_size, int frame, Color color, int plane_type, int priority) {
    // reset_draw_size=false で呼ぶ。ここでゼロへ戻してしまうと、同じサイズを
    // 指定し続けているだけの呼び出しでも毎フレーム再描画になるため。
    update_sprite_internal(link_id, pos, frame, color, plane_type, priority, false);
    if (link_id < 0 || link_id >= static_cast<int>(pool.size())) {
        return;
    }
    SpriteData &data = pool[link_id];
    if (!data.active) {
        return;
    }
    const Vector2 next_draw_size(
        std::max(1.0f, std::roundf(draw_size.x)),
        std::max(1.0f, std::roundf(draw_size.y))
    );
    if (data.draw_size != next_draw_size) {
        data.draw_size = next_draw_size;
        data.visual_dirty = true;
        // 反転中はdraw_sizeが原点補正(ox/oy)にも影響するため、transformも更新対象にする
        if (data.flip_h || data.flip_v) {
            data.transform_dirty = true;
        }
    }
}

// ---------------------------------------------------------------------------
// update_sprite_scaled — 基準サイズに倍率scaleを掛けた絶対ピクセルサイズで更新する
// ---------------------------------------------------------------------------
void TKSpriteServerNative::update_sprite_scaled(int link_id, Vector2 pos, Vector2 scale, int frame, Color color, int plane_type, int priority) {
    const int sprite_id = get_sprite_id_from_link(link_id);
    if (sprite_id < 0) {
        return;
    }
    const Vector2 base_size = get_sprite_draw_size(sprite_id);
    const Vector2 scaled_size(base_size.x * scale.x, base_size.y * scale.y);
    update_sprite_stretched(link_id, pos, scaled_size, frame, color, plane_type, priority);
}

// ---------------------------------------------------------------------------
// set_sprite_flip — 発行済みlink_idの反転状態を実行中に切り替える
// ---------------------------------------------------------------------------
// 次回commit_frame()のtransformへ反映される。再描画(visual_dirty)は不要。
void TKSpriteServerNative::set_sprite_flip(int link_id, bool flip_h, bool flip_v) {
    if (link_id < 0 || link_id >= static_cast<int>(pool.size())) {
        return;
    }
    SpriteData &data = pool[link_id];
    if (!data.active) {
        return;
    }
    if (data.flip_h != flip_h || data.flip_v != flip_v) {
        data.flip_h = flip_h;
        data.flip_v = flip_v;
        data.transform_dirty = true;
    }
}

// get_sprite_flip — 発行済みlink_idの現在の反転状態を返す（x=flip_h, y=flip_v。0/1）
Vector2i TKSpriteServerNative::get_sprite_flip(int link_id) const {
    if (link_id < 0 || link_id >= static_cast<int>(pool.size())) {
        return Vector2i();
    }
    const SpriteData &data = pool[link_id];
    if (!data.active) {
        return Vector2i();
    }
    return Vector2i(data.flip_h ? 1 : 0, data.flip_v ? 1 : 0);
}

// get_sprite_id_from_link — 発行済みlink_idに紐づくsprite_idを返す（無効なら-1）
int TKSpriteServerNative::get_sprite_id_from_link(int link_id) const {
    if (link_id < 0 || link_id >= static_cast<int>(pool.size())) {
        return -1;
    }
    const SpriteData &data = pool[link_id];
    if (!data.active) {
        return -1;
    }
    return data.sprite_id;
}

// ---------------------------------------------------------------------------
// destroy_sprite — スプライトを破棄してスロットを返却する
// ---------------------------------------------------------------------------
// swap-with-last: active_link_ids の末尾の ID をこのスロットの位置へ移動し、
// active_link_count をデクリメントするだけで O(1) 削除を実現する。
void TKSpriteServerNative::destroy_sprite(int link_id) {
    if (link_id < 0 || link_id >= static_cast<int>(pool.size())) {
        return;
    }

    SpriteData &data = pool[link_id];
    if (!data.active) {
        return;
    }

    // Godot の RenderingServer から canvas_item を削除
    if (data.rid.is_valid()) {
        RenderingServer::get_singleton()->free_rid(data.rid);
    }

    // swap-with-last でアクティブリストから除去
    int active_index = data.active_index;
    active_link_count--;
    if (active_index >= 0 && active_index != active_link_count) {
        // 末尾の要素をこのスロットへ移動
        int moved_link_id = active_link_ids[active_link_count];
        active_link_ids[active_index] = moved_link_id;
        pool[moved_link_id].active_index = active_index;
    }
    if (active_link_count >= 0 && active_link_count < static_cast<int>(active_link_ids.size())) {
        active_link_ids[active_link_count] = -1;  // 末尾をクリア
    }

    // スロットをリセットして free_ids に返却
    data.active = false;
    data.active_index = -1;
    data.sprite_id = -1;
    data.draw_size = Vector2();
    data.rid = RID();
    data.plane_rid = RID();
    free_ids.push_back(link_id);
}

// ---------------------------------------------------------------------------
// request_draw — 1フレームだけ有効な描画要求を作る
// ---------------------------------------------------------------------------
void TKSpriteServerNative::request_draw(int sprite_id, Vector2 pos, bool flip_h, bool flip_v, int plane_type, int priority) {
    int link_id = allocate_link_id(sprite_id, flip_h, flip_v, plane_type, priority);
    if (link_id < 0) {
        return;
    }
    update_sprite(link_id, pos, 0, Color(1, 1, 1, 1), plane_type, priority);
    transient_link_ids.push_back(link_id);
}

// flush_and_decay — commit_frame の後方互換エイリアス
void TKSpriteServerNative::flush_and_decay() {
    commit_frame();
}

// ---------------------------------------------------------------------------
// commit_frame — 毎フレーム末尾で呼ぶ描画確定処理
// ---------------------------------------------------------------------------
// 処理順:
//   1. 全アクティブスプライトの dirty フラグを処理し RenderingServer を呼ぶ
//      (parent_dirty → canvas_item_set_parent,
//       draw_index_dirty → canvas_item_set_draw_index,
//       transform_dirty → canvas_item_set_transform,
//       visual_dirty → canvas_item_clear + draw_slot)
//   2. clear_transient_links で一時スプライトを全破棄
//
// 反転(flip_h/flip_v)はcanvas_itemのtransformのスケール符号で表現し、
// 左上基準のずれをox/oyで補正する（GDScript版 commit_frame と同じ数式）。
// 拡縮はdraw_slot()側のdest_rectが正値のまま担当するため、ここで二重に反転させない。
void TKSpriteServerNative::commit_frame() {
    RenderingServer *rs = RenderingServer::get_singleton();

    for (int i = 0; i < active_link_count; ++i) {
        int link_id = active_link_ids[i];
        if (link_id < 0 || link_id >= static_cast<int>(pool.size())) {
            continue;
        }

        SpriteData &data = pool[link_id];
        if (!data.active || !data.rid.is_valid()) {
            continue;
        }

        // 親プレーンが変わっていたら再登録
        RID plane_rid = get_plane_rid(data.plane_type);
        if ((data.parent_dirty || data.plane_rid != plane_rid) && plane_rid.is_valid()) {
            data.plane_rid = plane_rid;
            rs->canvas_item_set_parent(data.rid, plane_rid);
            data.parent_dirty = false;
        }

        if (data.draw_index_dirty) {
            rs->canvas_item_set_draw_index(data.rid, data.priority);
            data.draw_index_dirty = false;
        }

        if (data.transform_dirty) {
            // draw_size が正値ならそれ、でなければ get_sprite_draw_size(sprite_id)
            const Vector2 draw_size = get_slot_effective_draw_size(data);
            const float sx = data.flip_h ? -1.0f : 1.0f;
            const float sy = data.flip_v ? -1.0f : 1.0f;
            const float ox = data.flip_h ? draw_size.x : 0.0f;  // 描画基準が左上のため、反転時は1枚分ずらす
            const float oy = data.flip_v ? draw_size.y : 0.0f;
            const Vector2 origin = snap_render_position(Vector2(data.x, data.y) + Vector2(ox, oy));
            rs->canvas_item_set_transform(data.rid, Transform2D(Vector2(sx, 0.0f), Vector2(0.0f, sy), origin));
            data.transform_dirty = false;
        }

        if (data.visual_dirty) {
            rs->canvas_item_clear(data.rid);
            // 実効描画サイズは算出済みなので渡す（1スプライトあたり2回計算するのを避けるため）
            const Vector2 draw_size = get_slot_effective_draw_size(data);
            draw_slot(data.rid, data, draw_size);  // テクスチャ矩形を canvas_item に追加
            data.visual_dirty = false;
        }
    }

    clear_transient_links();
}

// ---------------------------------------------------------------------------
// clear_all — 全スプライト・RID を解放する（free_all_rids の別名）
// ---------------------------------------------------------------------------
void TKSpriteServerNative::clear_all() {
    free_all_rids();
}

// ---------------------------------------------------------------------------
// free_all_rids — 全スプライトと関連 RID を完全に解放してプールを初期化する
// ---------------------------------------------------------------------------
// setup()での再確保前のクリーンアップとしても使うため、範囲は max_sprites ではなく
// その時点の pool のサイズを基準にする。
void TKSpriteServerNative::free_all_rids() {
    RenderingServer *rs = RenderingServer::get_singleton();

    // アクティブな全スプライトの RID を解放
    for (int i = 0; i < active_link_count; ++i) {
        int link_id = active_link_ids[i];
        if (link_id < 0 || link_id >= static_cast<int>(pool.size())) {
            continue;
        }
        SpriteData &data = pool[link_id];
        if (data.rid.is_valid()) {
            rs->free_rid(data.rid);
        }
    }

    // プール全体を初期化し、全 ID を free_ids に返却
    free_ids.clear();
    for (int i = static_cast<int>(pool.size()) - 1; i >= 0; --i) {
        SpriteData &data = pool[i];
        data.active = false;
        data.active_index = -1;
        data.sprite_id = -1;
        data.draw_size = Vector2();
        data.rid = RID();
        data.plane_rid = RID();
        data.parent_dirty = true;
        data.draw_index_dirty = true;
        data.transform_dirty = true;
        data.visual_dirty = true;
        free_ids.push_back(i);
    }
    std::fill(active_link_ids.begin(), active_link_ids.end(), -1);
    transient_link_ids.clear();
    active_link_count = 0;
    sprite_textures.clear();
}

// ---------------------------------------------------------------------------
// get_stats — 現在のプール利用状況を返す
// ---------------------------------------------------------------------------
// 頻繁には呼ばれない想定のため Dictionary を都度新規生成する（commit_frame内では呼ばない）。
Dictionary TKSpriteServerNative::get_stats() const {
    Dictionary stats;
    stats["active_link_count"] = active_link_count;
    stats["max_sprites"] = max_sprites;
    stats["free_count"] = static_cast<int>(free_ids.size());
    stats["sprite_buffer_over"] = sprite_buffer_over;
    stats["backend"] = String("native");
    return stats;
}

// ---------------------------------------------------------------------------
// プロパティアクセサ
// ---------------------------------------------------------------------------
Dictionary TKSpriteServerNative::get_sprite_textures() const {
    return sprite_textures;
}

void TKSpriteServerNative::set_sprite_textures(Dictionary value) {
    sprite_textures = value;
}

int TKSpriteServerNative::get_active_link_count() const {
    return active_link_count;
}

// 主に Godot Inspector またはデバッグ用に使用（通常は C++ が自動管理）
void TKSpriteServerNative::set_active_link_count(int value) {
    active_link_count = value;
}

bool TKSpriteServerNative::get_sprite_buffer_over() const {
    return sprite_buffer_over;
}

void TKSpriteServerNative::set_sprite_buffer_over(bool value) {
    sprite_buffer_over = value;
}

// ---------------------------------------------------------------------------
// get_plane_rid — plane_type 番号から対応するプレーン RID を返す
// ---------------------------------------------------------------------------
// 0=back, 1=medium(default), 2=front, 3=effect, 4=text（存在しない場合は medium にフォールバック）
RID TKSpriteServerNative::get_plane_rid(int plane_type) const {
    if (plane_type == 0) {
        return back_plane_rid;
    }
    if (plane_type == 2) {
        return front_plane_rid;
    }
    if (plane_type == 3 && effect_plane_rid.is_valid()) {
        return effect_plane_rid;
    }
    if (plane_type == 4 && text_plane_rid.is_valid()) {
        return text_plane_rid;
    }
    return medium_plane_rid;  // デフォルト（type=1 またはフォールバック）
}

// ---------------------------------------------------------------------------
// スプライト文字HUD — 固定グリッド。通常パスでは再確保を行わない。
// ---------------------------------------------------------------------------
void TKSpriteServerNative::init_sprite_text(int cols, int rows, int cell_width, int cell_height, int glyph_base_id, int plane_type, int priority) {
    if (cols <= 0 || rows <= 0 || cell_width <= 0 || cell_height <= 0) {
        return;
    }
    const int cell_count = cols * rows;
    sprite_text_link_ids.assign(cell_count, -1);
    sprite_text_glyphs.assign(cell_count, -1);
    sprite_text_cols = cols;
    sprite_text_rows = rows;
    sprite_text_cell_width = cell_width;
    sprite_text_cell_height = cell_height;
    sprite_text_glyph_base_id = glyph_base_id;
    sprite_text_plane_type = plane_type;
    sprite_text_priority = priority;
    sprite_text_cursor_col = 0;
    sprite_text_cursor_row = 0;
}

void TKSpriteServerNative::sprlocate(int col, int row) {
    if (col < 0 || row < 0 || col >= sprite_text_cols || row >= sprite_text_rows) {
        sprite_text_cursor_col = sprite_text_cols;
        sprite_text_cursor_row = sprite_text_rows;
        return;
    }
    sprite_text_cursor_col = col;
    sprite_text_cursor_row = row;
}

void TKSpriteServerNative::sprprint(const String &text) {
    const char32_t *chars = text.ptr();
    for (int char_index = 0; chars[char_index] != 0; ++char_index) {
        const char32_t glyph = chars[char_index];
        int glyph_index = -1;
        if (glyph >= U'0' && glyph <= U'9') {
            glyph_index = static_cast<int>(glyph - U'0');
        } else if (glyph >= U'A' && glyph <= U'Z') {
            glyph_index = 10 + static_cast<int>(glyph - U'A');
        }
        _sprite_text_put(glyph_index);
    }
}

void TKSpriteServerNative::sprprintint(int value, int digits) {
    if (digits <= 0) {
        return;
    }
    if (value < 0) {
        value = 0;
    }
    int divisor = 1;
    for (int divisor_index = 1; divisor_index < digits; ++divisor_index) {
        divisor *= 10;
    }
    for (int digit_index = 0; digit_index < digits; ++digit_index) {
        int glyph_index = -1;
        if (value >= divisor || digit_index == digits - 1) {
            glyph_index = (value / divisor) % 10;
        }
        if (divisor > 1) {
            divisor /= 10;
        }
        _sprite_text_put(glyph_index);
    }
}

void TKSpriteServerNative::sprcls() {
    for (int cell_index = 0; cell_index < static_cast<int>(sprite_text_link_ids.size()); ++cell_index) {
        const int link_id = sprite_text_link_ids[cell_index];
        if (link_id >= 0) {
            destroy_sprite(link_id);
            sprite_text_link_ids[cell_index] = -1;
            sprite_text_glyphs[cell_index] = -1;
        }
    }
    sprite_text_cursor_col = 0;
    sprite_text_cursor_row = 0;
}

// ---------------------------------------------------------------------------
// _sprite_text_put — カーソル位置に1グリフ分のスプライトを配置・更新・撤去する
// ---------------------------------------------------------------------------
// sprprint/sprprintint 共通のヘルパー。glyph_index が負値ならそのセルを空にする。
// 呼び出し後、カーソルを1つ進める（GDScript版 _sprite_text_put と同じ挙動）。
void TKSpriteServerNative::_sprite_text_put(int glyph_index) {
    if (sprite_text_cursor_row >= sprite_text_rows) {
        sprite_text_cursor_col = sprite_text_cols;
        sprite_text_cursor_row = sprite_text_rows - 1;
        return;
    }
    if (sprite_text_cursor_col >= sprite_text_cols) {
        sprite_text_cursor_col = 0;
        sprite_text_cursor_row++;
        if (sprite_text_cursor_row >= sprite_text_rows) {
            sprite_text_cursor_col = sprite_text_cols;
            sprite_text_cursor_row = sprite_text_rows - 1;
            return;
        }
    }
    // 負座標で開始した間はセルに触れず、カーソルだけを進める
    if (sprite_text_cursor_col < 0 || sprite_text_cursor_row < 0) {
        sprite_text_cursor_col++;
        return;
    }
    const int cell_index = sprite_text_cursor_row * sprite_text_cols + sprite_text_cursor_col;
    if (sprite_text_glyphs[cell_index] != glyph_index) {
        const int old_link_id = sprite_text_link_ids[cell_index];
        if (glyph_index < 0) {
            if (old_link_id >= 0) {
                destroy_sprite(old_link_id);
                sprite_text_link_ids[cell_index] = -1;
            }
        } else {
            // セルが既に使用中なら、glyph(sprite_id)は update_sprite では差し替えられないため、
            // 旧グリフのスプライトを必ず破棄してから新グリフで作り直す（旧数字が残るのを防ぐ）。
            if (old_link_id >= 0) {
                destroy_sprite(old_link_id);
                sprite_text_link_ids[cell_index] = -1;
            }
            int link_id = allocate_link_id(sprite_text_glyph_base_id + glyph_index, false, false, sprite_text_plane_type, sprite_text_priority);
            sprite_text_link_ids[cell_index] = link_id;
            if (link_id >= 0) {
                update_sprite(link_id, Vector2(sprite_text_cursor_col * sprite_text_cell_width, sprite_text_cursor_row * sprite_text_cell_height), 0, Color(1, 1, 1, 1), sprite_text_plane_type, sprite_text_priority);
            }
        }
        sprite_text_glyphs[cell_index] = glyph_index;
    }
    sprite_text_cursor_col++;
}

// ---------------------------------------------------------------------------
// get_slot_effective_draw_size — スロットの実効描画サイズを返す
// ---------------------------------------------------------------------------
// draw_slot()とcommit_frame()の両方から呼ばれる共通ヘルパー。
// data.draw_sizeが正値ならそれを使い、そうでなければget_sprite_draw_size()の既定サイズを使う。
Vector2 TKSpriteServerNative::get_slot_effective_draw_size(const SpriteData &data) const {
    if (data.draw_size.x > 0.0f && data.draw_size.y > 0.0f) {
        return data.draw_size;
    }
    return get_sprite_draw_size(data.sprite_id);
}

// ---------------------------------------------------------------------------
// snap_render_position — 座標をピクセルにスナップする
// ---------------------------------------------------------------------------
// 低解像度の拡大表示で小数座標が不規則な揺れに見えるのを避けるため、描画座標を整数ピクセルへ丸める。
// pixel_snap が無効なら何もしない。
Vector2 TKSpriteServerNative::snap_render_position(Vector2 pos) const {
    if (!pixel_snap) {
        return pos;
    }
    return pos.round();
}

// ---------------------------------------------------------------------------
// draw_slot — canvas_item にテクスチャ矩形として1スプライトを描画する
// ---------------------------------------------------------------------------
// sprite_textures[sprite_id] を参照してテクスチャと source_rect を取得する。
// "frames" キーがあればフレームアニメーション、"rect" キーがあれば静止画扱い。
// dest_rect は常に正値のままとし、反転はcommit_frame()側のtransformが担当するため、
// ここでは二重に反転させない。
// effective_draw_size は commit_frame() で算出済みの値（1スプライトあたり2回計算しない）。
void TKSpriteServerNative::draw_slot(const RID &rid, const SpriteData &data, const Vector2 &effective_draw_size) {
    if (!sprite_textures.has(data.sprite_id)) {
        return;
    }

    Dictionary texture_data = sprite_textures[data.sprite_id];
    Rect2 source_rect;
    if (texture_data.has("frames")) {
        // フレームアニメーション: data.frame をインデックスとして使用
        Array frames = texture_data["frames"];
        // frames が空だと剰余演算でゼロ除算になるため、描画せずに抜ける
        if (frames.is_empty()) {
            return;
        }
        source_rect = frames[static_cast<int>(data.frame) % frames.size()];
    } else if (texture_data.has("rect")) {
        // 静止画（単一矩形）
        source_rect = texture_data["rect"];
    } else {
        return;
    }

    if (!texture_data.has("texture")) {
        return;
    }

    // テクスチャ未設定の登録ミスでクラッシュしないようにする
    Ref<Texture2D> texture = texture_data["texture"];
    if (texture.is_null()) {
        return;
    }

    // dest_rect は (0,0) 起点で draw_size の大きさ（transform で位置決め済み）
    const Vector2 draw_size = (effective_draw_size.x > 0.0f && effective_draw_size.y > 0.0f)
        ? effective_draw_size
        : get_slot_effective_draw_size(data);
    Rect2 dest_rect(Vector2(), draw_size);
    RenderingServer::get_singleton()->canvas_item_add_texture_rect_region(rid, dest_rect, texture->get_rid(), source_rect, data.color);
}

// ---------------------------------------------------------------------------
// clear_transient_links — request_draw で作った一時スプライトを全破棄する
// ---------------------------------------------------------------------------
// 末尾から逆順で破棄する（destroy_sprite の swap-with-last と相性が良い）。
void TKSpriteServerNative::clear_transient_links() {
    for (int i = static_cast<int>(transient_link_ids.size()) - 1; i >= 0; --i) {
        destroy_sprite(transient_link_ids[i]);
    }
    transient_link_ids.clear();
}
