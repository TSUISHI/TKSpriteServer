extends RefCounted

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  demo_stress_native_update.gd — ネイティブ専用の高速更新ループ             ║
# ╠═══════════════════════════════════════════════════════════════════════════╣
# ║  【なぜ別ファイルなのか】                                                  ║
# ║  GDScript から GDExtension のメソッドを呼ぶとき、変数が Object 型だと      ║
# ║  毎回メソッド名の検索と Variant への詰め替えが走ります。変数を            ║
# ║  TKSpriteServerNative 型で受け、省略可能な引数もすべて明示して呼ぶと、    ║
# ║  この固定費が大きく下がります（20,000体で 1体あたり約 730ns → 438ns）。   ║
# ║                                                                            ║
# ║  ただし TKSpriteServerNative を型注釈に書いたスクリプトは、GDExtension    ║
# ║  が読み込まれていない環境ではパースに失敗し、丸ごと読み込めなくなります。 ║
# ║  そのため高速ループはこのファイルへ分離し、呼び出し側は                    ║
# ║  ClassDB.class_exists("TKSpriteServerNative") が真のときだけ              ║
# ║  load() します。バイナリの無いプラットフォームでは、このファイルは        ║
# ║  一度も読み込まれません。                                                  ║
# ║                                                                            ║
# ║  【配列の扱い】                                                            ║
# ║  update_all() は渡された配列を読むだけで、書き換えません。                ║
# ║  PackedFloat32Array などは書き込み時コピーのため、呼び出し先で書き換えると ║
# ║  配列全体が複製され、節約したぶんを失います。座標計算は呼び出し側で        ║
# ║  済ませてから渡してください。                                              ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

var _server: TKSpriteServerNative = null


# [setup]
# 処理内容: ネイティブサーバーを型付きで保持します。
# 引数 server: TKSpriteServer.create() が返したサーバーです。
# 戻り値: ネイティブバックエンドとして受け取れたら true です。
func setup(server: Object) -> bool:
	_server = server as TKSpriteServerNative
	return _server != null
# [setup]END


# [update_all]
# 処理内容: 算出済みの座標をサーバーへ流し込みます。省略可能な引数まで
#           すべて明示しているのは、省略すると高速パスから外れるためです。
# 引数 link_ids:    更新対象の link_id 配列です。
# 引数 positions:   index*2 = x, index*2+1 = y の並びの座標配列です（読むだけです）。
# 引数 count:       更新する体数です。
# 引数 scale:       拡縮倍率です。
# 引数 frame_count: フレーム数です。個体ごとに frame を変えるために使います。
# 戻り値: なし。
func update_all(link_ids: PackedInt32Array, positions: PackedFloat32Array, count: int, scale: Vector2, frame_count: int) -> void:
	for i in range(count):
		var base_idx := i * 2
		_server.update_sprite_scaled(link_ids[i], Vector2(positions[base_idx], positions[base_idx + 1]), scale, i % frame_count, Color.WHITE, -1, -1)
	return  # end of function
# [update_all]END
