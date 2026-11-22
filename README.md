# opx_skin

The clothing API of OPX: saved clothes, job uniforms, fitting-room previews and saved outfits. It has no shop and no wardrobe screen of its own: a clothing shop or a wardrobe is opx_creator opened with `scope = 'clothing'`.

## Install
- Needs: `opx_core`, `opx_menu`, `opx_dialog`, and the official `open77_appearance` + `open77_equipment` (they store and apply the clothes). Load after `opx_core`, `opx_menu`, `opx_dialog`, before `opx_creator`.
- Provider of the `skin` slot (`opx_core` `Config.providers.skin = 'opx_skin'`).
- Creates its `opx_skin_outfits` table at start. Without a database, saved outfits last for the session.
- Nothing else may call `open77_appearance:setTemporaryOutfit`: jobs dress players through `SetUniform`.

## In game
- Clothes are changed in the creator (clothing shops, wardrobes) and stay after a relog.
- A uniform covers the saved clothes while on duty; taking it off brings them back.
- Outfits menu (opened by a wardrobe or shop): save the current clothes under a name, wear, rename, delete.
- Optional test command `Config.command` (ACL right `command.<name>` when `Config.commandRestricted`): your outfits menu.

## Config
`config.lua`: `Config.outfits` (max per character, menu session time and distance), `Config.hide` (garments left out of the lists), `Config.settleMs`. Everything else is commented in the file.

## For developers
Get the provider with `exports.opx_core:GetProvider('skin')`; never name opx_skin. Slots: `Head, Face, InnerChest, OuterChest, Legs, Feet, Outfit`, value = item record or `false`. ASYNC exports wait: `Open77.exports.call(skin, name, ...):await()` from a thread.
- `GetClothing(src, fresh?)` async → the 7 saved slots, or `nil, reason`.
- `SetClothing(src, slots, options?)` async → `true` or `false, reason`. Persistent; refused in uniform.
- `SetPreview(src, slots)` / `ClearPreview(src)` → try-on that is never stored (seen by players around).
- `SetUniform(src, outfit)` / `ClearUniform(src)` / `GetUniform(src)` → never stored, removed when your resource stops.
- Outfits: `GetOutfits`, `SaveOutfit` (async), `WearOutfit` (async), `RenameOutfit`, `DeleteOutfit`, `OpenOutfits(src, { title?, canSave?, canDelete? })`, `CloseOutfits`.
- Client: `GetGarments(slot, offset?, limit?, family?)` async → `{ total, items = { { record, label } } }` (60 at most per call), `FindGarment(slot, record, family?)`.
- Events: `opx:skin:clothingChanged (src, slots)`, `opx:skin:uniformChanged (src, owner|nil)`.
- Full contract and "Replacing the skin provider": `types.lua`.

Uniform (job script, server):
```lua
local skin = exports.opx_core:GetProvider('skin')
if skin then
    Open77.exports.callSync(skin, 'SetUniform', src, {
        male = { OuterChest = 'Items.Jacket_01_basic_01', Head = false },
        female = { OuterChest = 'Items.Jacket_01_basic_01', Head = false },
    })
end
-- off duty
if skin then Open77.exports.callSync(skin, 'ClearUniform', src) end
```

Wardrobe (housing, job locker, server):
```lua
exports.opx_core:OpenCreator(src, { mode = 'edit', scope = 'clothing', tag = 'wardrobe' })
-- or the saved outfits
local skin = exports.opx_core:GetProvider('skin')
if skin then Open77.exports.callSync(skin, 'OpenOutfits', src) end
```

Limits: `true` from `SetClothing` means the player's game applied the clothes; the platform stores them a moment later (`Config.settleMs`). Garments are text rows (no pictures).
