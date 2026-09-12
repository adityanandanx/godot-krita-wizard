# Krita Wizard

Import [Krita](https://krita.org) (`.kra`) files directly into **Godot 4** — no Krita binary, no export step. Pick a `.kra` file in your project and get textures out: one merged texture, one texture per layer, or flattened groups. Pure GDScript, works on any platform Godot runs on.

## Features

- **Automatic importers** for `.kra` files: merged texture, per-layer split, and tileset texture
- **Layers wizard dock**: pick layers/groups, set options, generate PNGs
- **Layer groups**: flatten a group into one texture (`@merge` tag, Merge checkbox, or `merge_groups` option)
- **Blend modes**: normal, multiply, screen, overlay, hard/soft light, darken, lighten, dodge, burn, add, subtract, divide, difference, exclusion, behind, erase (anything else falls back to normal with a warning)
- **Transparency & selection masks** (filter/transform/colorize masks warn and are skipped)
- **Naming-convention tags**: `@scale=`, `@trim`/`@notrim`, `@exclude`, `@merge`/`@nomerge`
- **Stable output names**: hiding or reordering layers never renames the other textures, so scene references don't break

## Requirements

- Godot 4.x (uses `ZIPReader`, `XMLParser`, `WorkerThreadPool` — all engine built-ins)
- Krita documents in **8-bit RGBA**. Other color spaces/depths report a clear error instead of importing.

## Install

1. Clone this repo into your project's `addons/` folder so you get `addons/krita_wizard/`:
   ```sh
   cd your-godot-project/addons
   git clone https://github.com/adityanandanx/krita-wizard krita_wizard
   ```
2. In Godot: **Project → Project Settings → Plugins** → enable **Krita Wizard**.
3. Drop a `.kra` file anywhere in your project. Pick its importer in the **Import** dock.

## Importers

| Importer | Result |
|---|---|
| Krita Texture | One merged texture of the document |
| Krita Texture (Split By Layer) | One texture per paint layer via `.kra_layer_tex` sidecars (+ a manifest resource) |
| Krita Layer Texture | Internal: imports a single `.kra_layer_tex` sidecar |
| Krita Tileset Texture | Same as Krita Texture (tile grid slicing is not implemented yet) |
| Krita (No Import) | Tracks the file without importing |

Common options:

| Option | Meaning |
|---|---|
| `layer/exclude_layers_pattern` | Glob; matching layers are skipped |
| `layer/only_visible_layers` | Skip layers hidden in Krita |
| `layer/merge_groups` | *(split only)* Emit one texture per top-level group instead of per layer |
| `sheet/trim` | Crop output to content (default off) |
| `sheet/scale` | Float resize factor, e.g. `0.5` to downscale |
| `sheet/frame_padding` | *(tileset)* Accepted, currently unused |
| `output/layers_resources_folder` | *(split only)* Where sidecars go (default: next to the source) |

Split-import notes:
- Sidecars are named `<doc>_<LayerName>.kra_layer_tex` — stable across hide/show/reorder, so attached textures update in place instead of being recreated.
- Only layers whose pixels or options actually changed get reimported.
- Deleting/renaming a layer removes its stale sidecar and texture artifacts automatically.

## Layers wizard dock

**Project → Krita Wizard → Layers Wizard Dock…**

1. Select a `.kra` source (button or drag-and-drop).
2. Check layers in the tree. Column meanings:
   - **Layer** — tri-state checkbox (dash = partially selected); dimmed rows won't export. Checking a group selects its whole subtree.
   - **Info** — blend mode and effective opacity when they differ from defaults.
   - **Merge** *(groups only)* — export the group as one flattened PNG from the checked descendants.
   - **Trim** — trim this row's PNG to content. Seeded from the `@trim` tag when present, otherwise from the global Trim option; flipping the global option re-applies it to every row, and rows stay individually flippable.
3. Set exclude pattern, visible-only, split/merge, scale, output folder and filename prefix.
4. **Generate PNGs** — files are numbered bottom-layer-first (`prefix_00_Background.png`, …) so they sort correctly.

**Project → Krita Wizard → Config…** edits the project-wide defaults for the above.

## Layer name tags

Whitespace-separated `@tags` anywhere in a layer or group name override export options for that entry (tags are stripped from generated filenames):

| Tag | Effect |
|---|---|
| `@scale=0.5` | Resize factor for this entry |
| `@trim` / `@trim=false` / `@notrim` | Force trimming on/off |
| `@exclude` / `@ignore` | Skip this entry (and, for groups, its whole subtree) |
| `@merge` / `@nomerge` | Force-flatten / force-expand this group in split contexts |

Example: a group named `Hero @merge`, a layer named `Sketch @exclude`, a layer named `Icon @scale=0.5 @notrim`.

## Notes & limitations

- Animation (timeline, keyframes, onion skin) is not imported — static pixels only.
- Exotic blend modes and non-transparency masks fall back gracefully with a one-time log warning.
- Group opacity below 100% and non-trivial groups render isolated (own canvas), matching Krita; simple groups blend flat.
- Resizing up uses nearest-neighbor, downscaling uses bilinear.

## License

MIT — see [LICENSE](LICENSE).
