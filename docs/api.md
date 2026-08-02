# API reference

All classes are registered globally by the plugin, so they can be used without
`preload()`. Everything except the server instance itself is a static utility class.

- [`TKSpriteServer`](#tkspriteserver) — backend selection facade
- [The server instance](#the-server-instance) — the actual sprite server
- [`TKSpriteRegistry`](#tkspriteregistry) — register a definition file into a server
- [`TKSpriteDefinitions`](#tkspritedefinitions) — read, write and validate definition files
- [`TKSpriteAtlasBuilder`](#tkspriteatlasbuilder) — generate rotation and spin atlases
- [`TKAsepriteImporter`](#tkaspriteimporter) — import Aseprite exports

See also [sprite_definitions.md](sprite_definitions.md) for the JSON schema and
[aseprite.md](aseprite.md) for the Aseprite workflow.

---

## TKSpriteServer

A static facade. It never becomes an instance itself — it creates one.

### `static create(max_sprites: int = 4096, pixel_snap: bool = true, prefer_native: bool = true) -> Object`

Creates a sprite server and calls `setup()` on it.

The native backend is used when it is registered in `ClassDB` **and** exposes every
method in the compatibility list. Otherwise the GDScript backend is used and a warning
naming the missing methods is pushed. Pass `prefer_native = false` to force the GDScript
backend (the stress demo uses this to compare the two).

`pixel_snap` rounds render positions to whole pixels, which is what you normally want
for pixel art.

**The return value is a `Node`.** You must add it to the scene tree yourself:

```gdscript
var server: Object = TKSpriteServer.create(4096, true)
add_child(server)
```

### `static is_native_available() -> bool`

True when the GDExtension class exists and can be instantiated. This does not check API
compatibility — `create()` does that.

### `static get_backend_name(server: Object) -> String`

Returns `"native"`, `"gdscript"` or `"unknown"`. Useful for a debug HUD.

---

## The server instance

Both backends expose the same API, so the calls below apply whichever one `create()`
returned.

### Setup

| Method | Description |
|---|---|
| `setup(max_sprites: int, pixel_snap: bool)` | Allocates the pool. `create()` already calls this |
| `set_plane_rids(back: RID, medium: RID, front: RID)` | The three canvas items sprites are drawn into |
| `set_effect_plane_rid(plane_rid: RID)` | Optional fourth plane |
| `set_text_plane_rid(plane_rid: RID)` | Optional plane for the sprite-text HUD |

Create the canvas items with `RenderingServer.canvas_item_create()` and parent them to
your node's canvas:

```gdscript
var back: RID = RenderingServer.canvas_item_create()
RenderingServer.canvas_item_set_parent(back, get_canvas())
```

### Planes and priority

`plane_type` selects the target plane:

| Value | Plane |
|---|---|
| `0` | back |
| `1` | medium (default) |
| `2` | front |
| `3` | effect — falls back to medium if `set_effect_plane_rid()` was never called |
| `4` | text — falls back to medium if `set_text_plane_rid()` was never called |

Any other value is treated as medium.

`priority` orders sprites **within one plane**. It becomes the canvas item draw index, so
a higher value is drawn later, i.e. in front.

### The sprite table

Before a sprite id can be drawn it must exist in `server.sprite_textures`:

```gdscript
server.sprite_textures[sprite_id] = {
	"texture": my_texture,                       # Texture2D
	"frames": [Rect2(0, 0, 16, 16), ...],        # one Rect2 per frame
}
server.set_sprite_draw_size(sprite_id, Vector2(32, 32))
```

The native backend exposes `sprite_textures` as a bound property rather than a plain
member. Reading it gives you a copy, so when registering many sprites, build the whole
dictionary and assign it back **once** instead of mutating it per entry.
`TKSpriteRegistry` already does this.

| Method | Description |
|---|---|
| `set_sprite_draw_size(sprite_id: int, size: Vector2)` | Default on-screen size for that sprite id |
| `get_sprite_draw_size(sprite_id: int) -> Vector2` | The registered size, or the **first frame's size** when none was registered — it does not return zero |

### Persistent sprites

| Method | Description |
|---|---|
| `allocate_link_id(sprite_id, flip_h = false, flip_v = false, plane_type = 1, priority = 0) -> int` | Reserves a slot and returns its link id, or `-1` when the pool is exhausted |
| `update_sprite(link_id, pos, frame = 0, color = Color.WHITE, plane_type = -1, priority = -1)` | Position, frame and colour. `-1` keeps the current plane/priority. **Resets the draw size to the sprite default** |
| `update_sprite_scaled(link_id, pos, scale: Vector2, ...)` | Same, scaled by a factor |
| `update_sprite_stretched(link_id, pos, draw_size: Vector2, ...)` | Same, scaled to an explicit pixel size |
| `set_sprite_flip(link_id, flip_h: bool, flip_v: bool)` | Change flip after allocation |
| `get_sprite_flip(link_id) -> Vector2i` | Current flip as `(h, v)` |
| `get_sprite_id_from_link(link_id) -> int` | The sprite id behind a link id |
| `destroy_sprite(link_id)` | Returns the slot to the pool |

`color` is a **multiply**. A coloured sprite can therefore never be tinted to pure white;
use an overbright colour such as `Color(1.8, 1.8, 1.8)` for a hit flash, and note that a
genuinely black pixel stays black at any gain.

Always check the result of `allocate_link_id()`: returning `-1` means the pool is full,
and the server also raises its `sprite_buffer_over` flag.

### One-shot drawing

`request_draw(sprite_id, pos, flip_h, flip_v, plane_type, priority)` draws a sprite for a
single frame without you holding a link id. Internally it allocates a transient slot that
is released by the next `commit_frame()`, so it consumes pool capacity like any other
sprite.

### Frame lifecycle

`commit_frame()` pushes every active slot to the `RenderingServer` and releases transient
slots. **Call it exactly once per frame, after all updates.** Nothing appears on screen
until you do.

| Method | Description |
|---|---|
| `clear_all()` | Releases every sprite but keeps the pool |
| `free_all_rids()` | Frees the underlying canvas item RIDs. Call before discarding the server |
| `get_stats() -> Dictionary` | Pool usage and `"backend"` |

### Sprite-text HUD

A text layer built from sprite glyphs, for score displays and debug overlays.

| Method | Description |
|---|---|
| `init_sprite_text(cols, rows, cell_width, cell_height, glyph_base_id, plane_type, priority)` | Grid size, cell size and the sprite id of glyph 0 |
| `sprlocate(col: int, row: int)` | Move the cursor |
| `sprprint(text: String)` | Print at the cursor |
| `sprprintint(value: int, digits: int)` | Print a zero-padded integer |
| `sprcls()` | Clear the text layer |

Glyph *n* is drawn with sprite id `glyph_base_id + n`.

---

## TKSpriteRegistry

Turns a definition file into registered sprites. Start-up only — never per frame.

### `static register_all(server, defs_path: String, draw_size_scale: Vector2 = Vector2.ONE, progress_callback: Callable = Callable()) -> int`

Loads the definition file and registers every sprite it contains. Returns the number
registered, or `0` if the file could not be read. `rotated` and `spin` entries have their
atlases generated here, which is why a progress callback is offered.

`draw_size_scale` multiplies every `draw_size` in the file. Use it when your game works in
logical units that differ from screen pixels; coordinate conversion itself stays your
responsibility.

### `static register_defs(server, defs: Dictionary, draw_size_scale = Vector2.ONE, progress_callback = Callable()) -> int`

The same, from an already-loaded definition dictionary. Validation findings are pushed as
warnings and broken entries are skipped rather than aborting the load.

### `static get_sprite_id_by_name(defs: Dictionary, sprite_name: String) -> int`

Looks up an id by name so game code can avoid hard-coded numbers. Returns `-1` if absent.

---

## TKSpriteDefinitions

Reads, writes and validates definition files. It does not load textures or touch a
server. Start-up and tooling only.

| Method | Description |
|---|---|
| `static load_file(path: String) -> Dictionary` | Reads a file and returns it normalised to schema v2. Empty on failure |
| `static parse_text(text: String, source_label := "(text)") -> Dictionary` | The same, from a JSON string |
| `static normalize_defs(parsed: Dictionary) -> Dictionary` | Normalises an already-parsed dictionary |
| `static save_file(path: String, defs: Dictionary, keep_v1: bool = false) -> bool` | Writes the file. `keep_v1` restores the v1 shape |
| `static validate(defs: Dictionary, atlas_sizes: Dictionary) -> Array` | Returns human-readable findings, e.g. rects outside the atlas |
| `static get_frame_count(sprite: Dictionary) -> int` | Frame count for any layout |
| `static get_tag_range(sprite: Dictionary, tag_name: String) -> Vector2i` | Start and end frame of a tag |

A v1 file loads unchanged and always comes back in the v2 shape, so callers never branch
on version. The original version is preserved in `source_version`. Keys left at their
default are omitted on save, so a v1 file can round-trip without gaining keys.

---

## TKSpriteAtlasBuilder

Generates atlases at run time from a single source image. Results are cached per process
on all generation parameters; `clear_cache()` releases them.

Every build function returns:

```gdscript
{
	"texture": ImageTexture,
	"frames": Array,        # Array[Rect2], ready for sprite_textures
	"image": Image,
	"frame_size": Vector2i,
	"total_frames": int,
}
```

An empty dictionary means failure.

### Direction numbers

A full turn is **256 directions**, increasing clockwise. Direction `0` points right, `64`
down, `128` left, `192` up. `original_orientation` tells the builder which way the source
image already points.

### `static build_rotated(image_path, crop_rect: Rect2i, original_orientation := 64, roughness := 4, progress_callback := Callable()) -> Dictionary`

Builds one frame per direction. `roughness` trades frames for memory:

| roughness | frames | step |
|---|---|---|
| 0 | 256 | 1.4° |
| 3 | 32 | 11.25° |
| 4 (default) | 16 | 22.5° |
| 6 | 4 | 90° |

Only the first quadrant is really rotated; the other three are mirrored from it, so
generation costs a quarter of the naive approach. Rotation is nearest-neighbour, which
keeps pixel art crisp, and the canvas is expanded automatically when a 45° rotation would
clip the corners.

`build_rotated_from_image(source: Image, ...)` is the same without file loading or caching.

### `static build_spin(image_path, crop_rect: Rect2i, original_orientation: int, frame_count: int, visual_period_dirs := 256) -> Dictionary`

Builds an evenly spaced spin animation for objects that rotate in place, such as coins.
`visual_period_dirs` is how many directions the artwork takes to look the same again —
`256` for a full turn, `64` for art with 4-fold symmetry.

`build_spin_from_image(source: Image, ...)` is the uncached variant.

### Helpers

| Method | Description |
|---|---|
| `static direction_to_frame_index(direction: int, roughness: int) -> int` | Maps a direction number to a frame in a rotated atlas |
| `static rotate_image_nearest(source: Image, angle_rad: float, out_w: int, out_h: int) -> Image` | The nearest-neighbour rotation used internally |
| `static load_source_image(path: String) -> Image` | Loads an image, including files Godot has not imported |
| `static save_atlas_png(result: Dictionary, path: String) -> bool` | Writes a generated atlas out, e.g. to bake it |
| `static clear_cache()` | Drops the process-wide cache |

---

## TKAsepriteImporter

Imports the JSON that `aseprite --data` produces. See [aseprite.md](aseprite.md) for the
full workflow.

| Method | Description |
|---|---|
| `static import_sheet_into_file(json_path, defs_path, split_by_tag := false, sprite_name := "", atlas_alias := "") -> bool` | Load, merge and save in one call |
| `static import_sheet(json_path, existing_defs, split_by_tag := false, sprite_name := "", atlas_alias := "") -> Dictionary` | The merge step alone |

Both `--format json-array` and `--format json-hash` are accepted.

**Re-import contract:** sprites are matched **by name**. An existing name keeps its id, a
new name gets `max_id + 1`, and `draw_size`, `comment` and `extras` are carried over from
the previous entry — so hand edits survive a re-import.
