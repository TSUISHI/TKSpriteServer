#ifndef TK_SPRITE_SERVER_REGISTER_TYPES_H
#define TK_SPRITE_SERVER_REGISTER_TYPES_H

// ===========================================================================
// register_types.h — GDExtension 登録処理の宣言
// ===========================================================================

#include <godot_cpp/core/class_db.hpp>

using namespace godot;

// SCENE レベルで ClassDB へクラスを登録する。
void initialize_tk_sprite_server_module(ModuleInitializationLevel p_level);

// 終了時のクリーンアップ。
void uninitialize_tk_sprite_server_module(ModuleInitializationLevel p_level);

#endif // TK_SPRITE_SERVER_REGISTER_TYPES_H
