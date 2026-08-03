# User guide

日本語版は [guide.ja.md](guide.ja.md) を参照してください。

This guide walks through actually using TKSpriteServer, from an empty project to a
scene with thousands of moving sprites. For exact signatures see
[api.md](api.md).

## Contents

1. [Is this addon for you?](#1-is-this-addon-for-you)
2. [How it draws this fast](#2-how-it-draws-this-fast)
3. [Installing](#3-installing)
4. [Your first sprite](#4-your-first-sprite)
5. [Moving many sprites](#5-moving-many-sprites)
6. [Layers](#6-layers)
7. [Flipping and scaling](#7-flipping-and-scaling)
8. [Definition files instead of code](#8-definition-files-instead-of-code)
9. [Sprites that face a direction](#9-sprites-that-face-a-direction)
10. [The sprite-text HUD](#10-the-sprite-text-hud)
11. [Shutting down cleanly](#11-shutting-down-cleanly)
12. [Getting the most out of it](#12-getting-the-most-out-of-it)
13. [Troubleshooting](#13-troubleshooting)

---

## 1. Is this addon for you?

TKSpriteServer draws sprites straight through the `RenderingServer`. There are no
`Sprite2D` nodes, no scene tree churn, and no per-sprite node overhead.

It is a good fit when you have **a lot of simple sprites that you update yourself every
frame** — a shoot-'em-up with hundreds of bullets, a particle-heavy action game, a
tile-based simulation, anything with a fixed logical resolution and pixel art.

It is the wrong tool when you want each sprite to be a node with its own signals,
physics body, animation player and editor-placed transform. That is what `Sprite2D` and
`AnimatedSprite2D` are for, and they are the better answer for a few dozen sprites.

The mental model is closer to a 2D graphics library than to the Godot scene tree: you own
the game state, and every frame you tell the server where things are.

## 2. How it draws this fast

Knowing what the server does internally makes the design decisions above it much easier.
Every trick below serves one goal: doing less work during the frame.

**No nodes — it draws straight through `RenderingServer`**

Each sprite is one canvas item RID, not a `Sprite2D`, parented to a plane (a canvas item of
its own). There is no scene-tree insertion, no `_process` propagation, and no per-node
memory.

**A link id is a slot in a fixed-size pool**

The pool is allocated in one go by `create(max_sprites, ...)` and never grows afterwards.
`allocate_link_id()` hands back one free slot; `destroy_sprite()` removes it in O(1) by
swapping with the last active entry. Nothing is allocated or freed per frame — the price is
that `allocate_link_id()` returns `-1` once the pool is full.

What gets recycled is **the pool index — the link id number — and nothing else**.
`destroy_sprite()` frees the sprite's canvas item RID immediately and pushes the number onto
a stack; the next `allocate_link_id()` pops that same number back but creates a fresh canvas
item for it. An identical link id is a completely different sprite, and nothing is kept
dormant for reuse. That is why creating and destroying sprites is not free — see
[12. Getting the most out of it](#12-getting-the-most-out-of-it).

**Updates are buffered and committed in one pass by `commit_frame()`**

`update_sprite()` only writes into the server's own state; it never touches the
`RenderingServer`. Every actual draw call happens inside `commit_frame()`. The native
backend keeps four dirty flags per sprite — parent, draw index, transform, and visual — and
issues **only the calls whose input actually changed**. A sprite that merely moved gets a new
transform and keeps its existing texture rect. That is why calling `update_sprite()` with
unchanged values every frame costs almost nothing.

**Rotation happens when the atlas is built, not when the sprite is drawn**

For speed, the server does not rotate anything at draw time. Instead, **the rotated artwork
is baked into the atlas**. The `rotated` and `spin` layouts generate every direction from a
single source image at load time and lay them out as one horizontal strip in one texture. At
run time all you change is the frame index, so rotation costs nothing. Even the generation
step only truly rotates the first quadrant (64 directions' worth); the other three are
derived by flipping, so a quarter of the work produces the whole circle. Rotation uses
nearest-neighbour sampling, so pixel-art edges stay crisp.

**Atlases are shared, and sprites on the same texture flow through together**

Every sprite gets its own link id, but each `atlases` alias in a definition file is loaded as
exactly one texture, shared by every sprite that names it. Sprites that use the same texture
and sit next to each other in draw order are processed as one batch by Godot's 2D renderer,
so **one packed atlas beats several small images**. Assigning planes and `priority` so the
texture does not keep changing is what makes that pay off.

**Generated atlases are cached and reused**

Rotation and spin results are cached per process, keyed by image path, crop rect,
orientation and roughness. When the same sprite is requested again — a scene rebuilt, the
same source referenced from several definition files — the cached texture is reused instead
of being regenerated. The cache is never evicted automatically; it stays for the life of the
process unless you call `TKSpriteAtlasBuilder.clear_cache()`. It buys load time with memory,
so generate at start-up or from a tool, never inside the frame loop.

**Top-left coordinates, integer snapping, flips through the transform**

Positions are top-left based, not centre based. A flip is the sign of the transform's scale
(`-1`), with the top-left offset cancelled out by shifting the origin by one sprite width or
height. The final position is rounded to whole pixels so that fractional coordinates don't
shimmer when a low resolution is scaled up.

## 3. Installing

1. Copy `addons/tk_sprite_server/` into your project's `addons/` folder.
2. Enable **TKSpriteServer** in Project Settings → Plugins.
3. Restart the editor so the GDExtension is loaded.

Windows x86_64 binaries are bundled. On other platforms nothing breaks — the addon falls
back to a pure GDScript backend with the same API and the same visual result, just
slower. You can check which one you got at run time with `TKSpriteServer.get_backend_name()`.

## 4. Your first sprite

Three things have to happen before anything appears:

1. **Planes** — canvas items to draw into.
2. **A sprite table entry** — which texture and which rectangle within it.
3. **`commit_frame()`** — called once per frame, or nothing is rendered.

```gdscript
extends Node2D

var _server: Object
var _link_id: int

func _ready() -> void:
	# 1. Planes. Three canvas items, parented to this node's canvas.
	var back: RID = RenderingServer.canvas_item_create()
	var medium: RID = RenderingServer.canvas_item_create()
	var front: RID = RenderingServer.canvas_item_create()
	for plane_rid in [back, medium, front]:
		RenderingServer.canvas_item_set_parent(plane_rid, get_canvas())

	# The server is a Node, so it has to go into the scene tree.
	_server = TKSpriteServer.create(4096, true)
	add_child(_server)
	_server.set_plane_rids(back, medium, front)

	# 2. Sprite table. Sprite id 0 is a 16x16 region of our texture.
	var texture: Texture2D = preload("res://art/player.png")
	_server.sprite_textures[0] = {
		"texture": texture,
		"frames": [Rect2(0, 0, 16, 16)],
	}
	_server.set_sprite_draw_size(0, Vector2(16, 16))

	# Reserve one sprite. Keep the link id — it is your handle to it.
	_link_id = _server.allocate_link_id(0)

func _process(_delta: float) -> void:
	_server.update_sprite(_link_id, Vector2(100.0, 80.0))
	# 3. Once per frame, after every update.
	_server.commit_frame()
```

A **link id** is a handle to one on-screen sprite. Allocate it once, reuse it every
frame, and destroy it when the object dies. Do not allocate one per frame.

A **sprite id** is an entry in the sprite table — a texture plus its frame rectangles.
Many link ids can share one sprite id.

## 5. Moving many sprites

The pattern scales without changing shape. Keep your own arrays, and push them to the
server each frame:

```gdscript
const COUNT: int = 5000

var _links: PackedInt32Array = PackedInt32Array()
var _positions: PackedVector2Array = PackedVector2Array()
var _velocities: PackedVector2Array = PackedVector2Array()

func _spawn_all() -> void:
	_links.resize(COUNT)
	_positions.resize(COUNT)
	_velocities.resize(COUNT)
	for i in range(COUNT):
		_links[i] = _server.allocate_link_id(0)
		_positions[i] = Vector2(randf() * 640.0, randf() * 360.0)
		_velocities[i] = Vector2(randf_range(-60.0, 60.0), randf_range(-60.0, 60.0))

func _process(delta: float) -> void:
	for i in range(COUNT):
		_positions[i] += _velocities[i] * delta
		_server.update_sprite(_links[i], _positions[i])
	_server.commit_frame()
```

Sprites that did not change are not redrawn — the server tracks a dirty flag per slot —
so calling `update_sprite()` with the same values every frame is cheap.

`allocate_link_id()` returns `-1` when the pool set by `create(max_sprites, ...)` is full.
Check it when you spawn things dynamically:

```gdscript
var link_id: int = _server.allocate_link_id(BULLET_SPRITE_ID)
if link_id < 0:
	return  # pool exhausted; skip this bullet
```

Free a sprite with `destroy_sprite(link_id)` when the object dies, otherwise the pool
drains.

## 6. Layers

Sprites go to one of five planes, chosen with `plane_type`:

| `plane_type` | Plane | Typical use |
|---|---|---|
| `0` | back | background, terrain |
| `1` | medium (default) | enemies, the player, bullets |
| `2` | front | foreground obstacles |
| `3` | effect | explosions above everything |
| `4` | text | the sprite-text HUD |

Planes 3 and 4 only exist if you supplied them with `set_effect_plane_rid()` and
`set_text_plane_rid()`; otherwise they fall back to medium.

Within one plane, `priority` decides who is on top — a higher value is drawn later, so it
appears in front.

```gdscript
_link_id = _server.allocate_link_id(sprite_id, false, false, 2, 10)   # front plane
_server.update_sprite(_link_id, pos, 0, Color.WHITE, 0, 5)            # move it to back
```

Pass `-1` for `plane_type` or `priority` to keep the current value.

## 7. Flipping and scaling

Flipping can be set when allocating, or changed at any time:

```gdscript
_server.set_sprite_flip(_link_id, true, false)   # face left
```

Flips are applied through the transform, and the origin is compensated so a flipped
sprite stays in the same place. Positions are top-left based, not centre based.

There are two ways to change size:

```gdscript
_server.update_sprite_scaled(_link_id, pos, Vector2(2.0, 2.0))     # twice as big
_server.update_sprite_stretched(_link_id, pos, Vector2(64.0, 32.0)) # exactly 64x32 px
```

One thing to know: **plain `update_sprite()` resets the size back to the sprite's default.**
If a sprite is permanently scaled, keep calling the scaled variant every frame — don't
mix the two on the same sprite.

`color` multiplies the sprite. It darkens and tints, but it cannot brighten a coloured
sprite to white. For a hit flash, use an overbright colour such as
`Color(1.8, 1.8, 1.8)`; a pixel that is genuinely black stays black no matter how high
you push it.

## 8. Definition files instead of code

Writing `sprite_textures[id] = {...}` by hand stops being pleasant at about the tenth
sprite. A definition file moves all of it into JSON:

```json
{
  "version": 2,
  "atlases": { "main": "res://art/atlas.png" },
  "sprites": [
    {
      "id": 0, "name": "PLAYER", "atlas": "main",
      "layout": "row", "rect": [0, 0, 16, 16], "frame_count": 4,
      "draw_size": [16, 16]
    }
  ]
}
```

One call registers everything:

```gdscript
TKSpriteRegistry.register_all(_server, "res://devdata/sprite_definitions.json")
```

Look sprites up by name so ids stay out of your code:

```gdscript
var defs: Dictionary = TKSpriteDefinitions.load_file(DEFS_PATH)
var player_id: int = TKSpriteRegistry.get_sprite_id_by_name(defs, "PLAYER")
```

You do not have to write the JSON by hand either. With the plugin enabled there is a
**Sprite Definitions** panel in the editor's bottom dock where you can drag frame
rectangles over the atlas and save. The full schema is in
[sprite_definitions.md](sprite_definitions.md), and Aseprite users should read
[aseprite.md](aseprite.md) — an exported sheet imports in one call and keeps its ids
across re-imports.

## 9. Sprites that face a direction

For something that must point in the direction it is travelling — a ship, a homing
missile, a rotating rock — you do not need to draw every angle. Mark the sprite `rotated`
and the atlas is generated at load time from one source image:

```json
{
  "id": 5, "name": "MISSILE", "atlas": "main",
  "layout": "rotated", "rect": [0, 64, 16, 16],
  "original_orientation": 64, "roughness": 3,
  "draw_size": [16, 16]
}
```

Directions are numbered **0–255 clockwise**: `0` right, `64` down, `128` left, `192` up.
`original_orientation` says which way your artwork already points. `roughness` picks how
many frames get generated — `3` gives 32 directions, `4` gives 16, `0` gives all 256.

At run time, convert an angle to a frame:

```gdscript
var direction: int = int(velocity.angle() / TAU * 256.0) & 255
var frame: int = TKSpriteAtlasBuilder.direction_to_frame_index(direction, 3)
_server.update_sprite(_link_id, pos, frame)
```

For an object that spins in place instead — a coin, a pickup — use `layout: "spin"` with
a `frame_count`, and play the frames as a normal animation.

Rotation is nearest-neighbour, so pixel art stays crisp, and results are cached per
process. Generating hundreds of directions for many sprites does cost time at load, which
is what the `progress_callback` argument of `register_all()` is for.

## 10. The sprite-text HUD

If your font is a sprite sheet — one glyph per frame — you get a text layer for free:

```gdscript
_server.set_text_plane_rid(text_plane)
# 40x30 cells of 8x8 pixels, glyph 0 living at sprite id 200, on plane 4
_server.init_sprite_text(40, 30, 8, 8, 200, 4, 0)

func _update_hud() -> void:
	_server.sprcls()
	_server.sprlocate(2, 1)
	_server.sprprint("SCORE")
	_server.sprlocate(8, 1)
	_server.sprprintint(score, 7)   # zero padded to 7 digits
```

Glyph *n* is drawn with sprite id `glyph_base_id + n`, so lay your font out in that order.

## 11. Shutting down cleanly

The server owns `RenderingServer` RIDs, which are not freed automatically when the node
goes away:

```gdscript
func _exit_tree() -> void:
	if _server != null:
		_server.free_all_rids()
```

Do the same before you replace a server (for example when switching backends at run
time), or the RIDs leak for the rest of the session.

## 12. Getting the most out of it

- **Call `commit_frame()` once per frame, at the very end.** Calling it more often does
  redundant work; forgetting it means nothing renders.
- **Allocate link ids once, not per frame.** Use `request_draw()` only for genuinely
  one-off drawing — it allocates a transient slot every call. What that costs depends on
  how many sprites are alive, not on how many you destroy (below).
- **If sprites come and go constantly, hide them instead of destroying them.** For bullets
  and effects it is cheaper to keep the link id and move the sprite off-screen, or update it
  with a transparent colour, than to call `destroy_sprite()` and allocate again. Replacing
  one sprite costs more the more sprites share the plane. Measured on the native backend,
  Godot 4.6.3 / Windows — `destroy_sprite()` + `allocate_link_id()` plus what that adds to
  `commit_frame()`, per sprite:

  | Sprites alive | Cost of replacing one |
  |---|---|
  | 1,000 | ~5 µs |
  | 10,000 | ~14 µs |
  | 20,000 | ~25 µs |

  As a rule of thumb, **`replacements per frame × sprites alive × 1.2 ns`**. Replacing 50
  sprites a frame out of 2,000 costs 0.12 ms per frame and does not matter; replacing 200 a
  frame out of 20,000 costs about 4.9 ms per frame and does.
- **Size the pool for your worst case.** `create(max_sprites, ...)` allocates up front;
  `allocate_link_id()` starts failing at the limit rather than growing.
- **Don't fight the dirty flag.** Passing the same values costs almost nothing, so there
  is no need to track "did this sprite move" yourself.
- **On the native backend, call through a typed variable and pass every argument.**
  Crossing from GDScript into the GDExtension costs about 700 ns per sprite at 20,000
  sprites, and that cost barely depends on **how many arguments you pass or what the method
  does** — a one-argument getter measured about the same as a six-argument
  `update_sprite()`. Holding the server in a variable typed as `TKSpriteServerNative` and
  spelling out even the optional arguments brings it down from 730 ns to 438 ns per sprite.
  Measured on `demo_stress` with 20,000 sprites, the update plus `commit_frame()` went from
  **19.8 ms to 12.2 ms per frame — 38% less**.

  Omitting optional arguments drops you off the fast path, so
  `update_sprite(link, pos, frame, Color.WHITE, -1, -1)` is *faster* than
  `update_sprite(link, pos, frame)`. Filling in the defaults costs more than passing them.

  Note that **a script that names `TKSpriteServerNative` in a type annotation fails to parse
  where the GDExtension is absent, and the whole file then fails to load.** If you ship to
  platforms with no binary, keep the typed loop in a file of its own and `load()` it only
  when `ClassDB.class_exists()` says the class is there.

  ```gdscript
  # The caller names no extension type, so it loads everywhere.
  var _fast: RefCounted = null
  if ClassDB.class_exists("TKSpriteServerNative"):
      var s: Script = load("res://your_game/fast_update.gd")
      if s != null and s.can_instantiate():
          var updater: RefCounted = s.new()
          if updater.setup(_server):
              _fast = updater
  ```

  **Do not write to an array you passed in.** `PackedFloat32Array` and friends are
  copy-on-write, so writing to one while another reference is alive copies the whole array
  and eats the saving. Do the position maths on the calling side and only read from the
  array in the fast loop. See [demo/demo_stress.gd](../demo/demo_stress.gd) and
  [demo/demo_stress_native_update.gd](../demo/demo_stress_native_update.gd) for a worked
  example.
- **Register sprites at load time.** `TKSpriteRegistry` and `TKSpriteDefinitions` are
  start-up tools; keep them out of the frame loop.
- **Cache the backend name** if you show it in a HUD; don't call it every frame.

## 13. Troubleshooting

**Nothing appears.**
In order: did you call `commit_frame()`? Did you call `set_plane_rids()`? Are the plane
canvas items parented to a canvas (`RenderingServer.canvas_item_set_parent(rid, get_canvas())`)?
Did you add the server to the scene tree with `add_child()`? Is there an entry in
`sprite_textures` for that sprite id?

**`get_backend_name()` says `gdscript` and I expected `native`.**
Either there is no binary for your platform, or the editor has not rescanned the
extension. Restart the editor once. If a warning names missing methods, the binary is
older than the GDScript side — rebuild or update it.

**`allocate_link_id()` returns `-1`.**
The pool is full. Raise `max_sprites` in `create()`, or make sure dead objects call
`destroy_sprite()`.

**A scaled sprite snaps back to its original size.**
Something called plain `update_sprite()` on it. Use `update_sprite_scaled()` or
`update_sprite_stretched()` consistently for that sprite.

**A flipped sprite is offset by its own width.**
That would mean the origin compensation was bypassed — set flips with
`set_sprite_flip()` or the `allocate_link_id()` arguments rather than by any other route.

**A definition warns that a rect is outside the atlas.**
The frame rectangle runs past the image. For `row` layouts remember the whole strip has
to fit: `x + width * frame_count` must be inside the atlas. Running the definition
through `TKSpriteDefinitions.validate()` lists every such problem at once.
