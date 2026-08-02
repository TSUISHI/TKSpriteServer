# User guide

日本語版は [guide.ja.md](guide.ja.md) を参照してください。

This guide walks through actually using TKSpriteServer, from an empty project to a
scene with thousands of moving sprites. For exact signatures see
[api.md](api.md).

## Contents

1. [Is this addon for you?](#1-is-this-addon-for-you)
2. [Installing](#2-installing)
3. [Your first sprite](#3-your-first-sprite)
4. [Moving many sprites](#4-moving-many-sprites)
5. [Layers](#5-layers)
6. [Flipping and scaling](#6-flipping-and-scaling)
7. [Definition files instead of code](#7-definition-files-instead-of-code)
8. [Sprites that face a direction](#8-sprites-that-face-a-direction)
9. [The sprite-text HUD](#9-the-sprite-text-hud)
10. [Shutting down cleanly](#10-shutting-down-cleanly)
11. [Getting the most out of it](#11-getting-the-most-out-of-it)
12. [Troubleshooting](#12-troubleshooting)

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

## 2. Installing

1. Copy `addons/tk_sprite_server/` into your project's `addons/` folder.
2. Enable **TKSpriteServer** in Project Settings → Plugins.
3. Restart the editor so the GDExtension is loaded.

Windows x86_64 binaries are bundled. On other platforms nothing breaks — the addon falls
back to a pure GDScript backend with the same API and the same visual result, just
slower. You can check which one you got at run time with `TKSpriteServer.get_backend_name()`.

## 3. Your first sprite

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

## 4. Moving many sprites

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

## 5. Layers

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

## 6. Flipping and scaling

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

## 7. Definition files instead of code

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

## 8. Sprites that face a direction

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

## 9. The sprite-text HUD

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

## 10. Shutting down cleanly

The server owns `RenderingServer` RIDs, which are not freed automatically when the node
goes away:

```gdscript
func _exit_tree() -> void:
	if _server != null:
		_server.free_all_rids()
```

Do the same before you replace a server (for example when switching backends at run
time), or the RIDs leak for the rest of the session.

## 11. Getting the most out of it

- **Call `commit_frame()` once per frame, at the very end.** Calling it more often does
  redundant work; forgetting it means nothing renders.
- **Allocate link ids once, not per frame.** Use `request_draw()` only for genuinely
  one-off drawing — it allocates a transient slot every call.
- **Size the pool for your worst case.** `create(max_sprites, ...)` allocates up front;
  `allocate_link_id()` starts failing at the limit rather than growing.
- **Don't fight the dirty flag.** Passing the same values costs almost nothing, so there
  is no need to track "did this sprite move" yourself.
- **Register sprites at load time.** `TKSpriteRegistry` and `TKSpriteDefinitions` are
  start-up tools; keep them out of the frame loop.
- **Cache the backend name** if you show it in a HUD; don't call it every frame.

## 12. Troubleshooting

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
