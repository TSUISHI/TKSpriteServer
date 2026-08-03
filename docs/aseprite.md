# Aseprite workflow

TKSpriteServer reads the JSON that Aseprite exports alongside a sprite sheet, so frame
rectangles, timings and tags come across without being retyped.

It can also read `.aseprite` files directly, with no export step and no Aseprite
installation — see [Reading `.aseprite` directly](#reading-aseprite-directly) below.

## Exporting from Aseprite

Either use *File → Export Sprite Sheet* with **Output → JSON Data** enabled, or the CLI:

```bash
aseprite -b player.aseprite --sheet player.png --data player.json --format json-array --list-tags
```

Both `--format json-array` and `--format json-hash` are accepted. Add `--list-tags` if
you want tags to come through, and `--trim` if you want trimmed frames — trimming is
handled, and the per-frame origin correction lands in `offsets`.

## Importing

One call loads the definition file, merges the sheet into it and saves it back:

```gdscript
TKAsepriteImporter.import_sheet_into_file(
	"res://art/player.json",           # Aseprite data JSON
	"res://devdata/sprite_definitions.json",
	false,                             # split_by_tag
	"PLAYER",                          # sprite name (defaults to the file name)
	"main"                             # atlas alias
)
```

If the definition file does not exist yet, it is created.

With `split_by_tag = true`, each Aseprite tag becomes its own sprite — `PLAYER_WALK`,
`PLAYER_JUMP` and so on — each with its own 0-based frame range. With `false` you get one
sprite whose `tags` map holds the ranges.

## What maps to what

| Aseprite | Definition file |
|---|---|
| `frame` | `frames` |
| `duration` | `durations` |
| `spriteSourceSize` | `offsets` — omitted entirely when every offset is zero |
| `sourceSize` | `source_size` |
| `frameTags` | `tags` |
| first slice pivot | `pivot` |
| — | `source: { "type": "aseprite", "file": ... }` |

## Re-importing

This is the part worth understanding, because it is what makes the workflow survivable.

**Sprites are matched by name.** A name that already exists keeps its sprite id, so
nothing in your game code has to change when the art is updated. A new name gets
`max_id + 1`.

**Hand edits survive.** `draw_size`, `comment` and `extras` are carried over from the
previous entry rather than reset, so tweaks you made in the editor panel or by hand are
not lost when the artist re-exports.

Frame data itself is replaced, which is the point of re-importing.

## A note on frame ordering

With `--format json-hash` the frames arrive as a dictionary keyed by file name, and those
keys are **re-sorted by the trailing number in the name**, not as text. Sorting as text
would put `player 10` before `player 2` and silently scramble the animation. If you write
your own tooling against these files, do the same.

## Reading `.aseprite` directly

There is a second route that skips the export step entirely: point it at the `.aseprite`
file itself. Aseprite does not have to be installed — the file is parsed in GDScript.

```gdscript
TKAsepriteImporter.import_aseprite_into_file(
	"res://art/player.aseprite",       # the source file
	"res://art/player.png",            # sheet PNG to write
	"res://devdata/sprite_definitions.json",
	false,                             # split_by_tag
	"PLAYER",                          # sprite name (defaults to the file name)
	"main"                             # atlas alias
)
```

Layers are composited bottom to top into one image per frame, the frames are laid out in a
horizontal strip, and that strip is written to the PNG path you gave. From there the result
joins the same code path as the JSON route, so **name matching, id stability and hand-edit
merging behave identically** — everything under "Re-importing" above applies unchanged.

If you only want the pixels, the parser is usable on its own:

```gdscript
var doc: Dictionary = TKAsepriteFile.load_file("res://art/player.aseprite")
var images: Array = TKAsepriteFile.build_frame_images(doc)   # Array of RGBA8 Image
var durations: Array = TKAsepriteFile.get_frame_durations(doc)
```

`doc` also carries `layers`, `tags`, `palette` and `pivot`, so you can build your own
pipeline on top of it.

### What is supported

| Area | Supported |
|---|---|
| Colour modes | RGBA, grayscale, indexed (the transparent index is honoured) |
| Cel types | raw, linked, zlib-compressed |
| Layers | visibility and opacity, groups skipped, any nesting depth |
| Metadata | tags, palette, the first slice pivot |

Blend modes other than Normal are treated as Normal and warn once per layer. Tilemap layers
and tilesets are not read. Both limitations are deliberate: full parity costs a great deal
and buys little for sprite work.

### Which route should you use?

Use the export route when a build pipeline already runs Aseprite, or when you want control
over packing (`--sheet-type packed`, `--trim`). The strip produced by the direct route is
one frame after another at full canvas size — simple and predictable, but not compact.

Use the direct route when you want `.aseprite` files to be the only art source in the repo,
with no export step to forget.
