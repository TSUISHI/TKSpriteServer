// ===========================================================================
// register_types.cpp — GDExtension エントリーポイント実装
// ===========================================================================
// Godot が libtksprite.<platform>.<target>.<arch> をロードするときに最初に
// 実行する C エクスポート関数 tk_sprite_server_init を定義する。
//
// この名前は addons/tk_sprite_server/tk_sprite_server.gdextension の
// entry_symbol と完全に一致していなければならない。片方だけ変更すると
// 「GDExtension entry point not found」でロードに失敗する。
//
// 処理の流れ:
//   1. tk_sprite_server_init が DLL ロード時に Godot から呼ばれる
//   2. InitObject を構築し、initialize/uninitialize のコールバックを登録する
//   3. init() で godot-cpp のバインディングを有効化する
//   4. MODULE_INITIALIZATION_LEVEL_SCENE のタイミングで
//      initialize_tk_sprite_server_module が呼ばれ、ClassDB へ登録される
// ===========================================================================

#include "register_types.h"
#include "tk_sprite_server_native.h"

#include <gdextension_interface.h>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

// ---------------------------------------------------------------------------
// initialize_tk_sprite_server_module — ClassDB へのクラス登録
// ---------------------------------------------------------------------------
// SCENE レベルでのみ実行する（SERVER/EDITOR レベルでは何もしない）。
// register_class<T>() により GDScript から生成できるようになる。
void initialize_tk_sprite_server_module(ModuleInitializationLevel p_level) {
    if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
        return;
    }
    // TKSpriteServerNative: スプライトプールと描画を担うコアクラス
    ClassDB::register_class<TKSpriteServerNative>();
}

// ---------------------------------------------------------------------------
// uninitialize_tk_sprite_server_module — クリーンアップ
// ---------------------------------------------------------------------------
// 解放すべきグローバル資源は持たないため現状は空実装。
void uninitialize_tk_sprite_server_module(ModuleInitializationLevel p_level) {
    if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
        return;
    }
}

// ---------------------------------------------------------------------------
// tk_sprite_server_init — GDExtension エントリーポイント
// ---------------------------------------------------------------------------
extern "C" {
GDExtensionBool GDE_EXPORT tk_sprite_server_init(
        GDExtensionInterfaceGetProcAddress p_get_proc_address,
        const GDExtensionClassLibraryPtr p_library,
        GDExtensionInitialization *r_initialization) {
    GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);

    init_obj.register_initializer(initialize_tk_sprite_server_module);
    init_obj.register_terminator(uninitialize_tk_sprite_server_module);
    init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);

    return init_obj.init();
}
}
