---@meta

-- opx_skin exports and events: the clothing API of OPX (opx_core provider slot `skin`). Not loaded by the
-- manifest (LuaLS annotations only). Reach it through the slot, never by name:
--   local skin = exports.opx_core:GetProvider('skin')   -- nil when none runs
--   Open77.exports.call(skin, 'SetClothing', src, { Head = false }):await()
--
-- Who stores what: the platform (open77_appearance) keeps the saved clothes of each character; opx_skin
-- writes them through Open77.clothing.set (the player's client applies them, open77_equipment relays the
-- change, open77_appearance validates and stores it). Uniforms and previews use the platform's single
-- temporary outfit (open77_appearance setTemporaryOutfit), never stored: opx_skin is the only OPX resource
-- that holds it and shows the preview, else the uniform, else nothing. A resource that calls
-- setTemporaryOutfit itself blocks opx_skin ('owned_by_other_resource').
-- Saved outfits (named sets) are opx_skin's own table opx_skin_outfits:
--   id, citizen_id, name (1..32 characters), slots (JSON of the 7 slots), created_at.
--
-- ASYNC exports may wait (client round trip, database): call them with
-- Open77.exports.call(provider, name, ...):await() from a thread; exports.opx_skin:Name(...) raises
-- export_yielded on them. SYNC exports answer from memory at once.
-- Ownership: a preview or uniform belongs to the calling resource (name + VM generation); it ends when that
-- resource stops or reloads (checked every second and on open77:resource:stopped), on disconnect and on a
-- character change. A uniform and a fitting exclude each other ('fitting' / 'uniform_active').
-- Never dress a dead or downed player: the client only applies changes while the player is alive.

---@alias OpxSkinSlot 'Head'|'Face'|'InnerChest'|'OuterChest'|'Legs'|'Feet'|'Outfit'

--- Slot -> item record ('Items.*', 1..160 bytes, no control character) or false (empty). An omitted slot
--- is left unchanged (SetClothing) or shows the saved look (SetPreview). Underwear is never touched.
---@alias OpxSkinSlots table<OpxSkinSlot, string|false>

---@class OpxSkinUniform
---@field male? OpxSkinSlots
---@field female? OpxSkinSlots

---@class OpxSkinOutfit
---@field id integer negative when no database (session only)
---@field name string
---@field slots OpxSkinSlots all 7 keys

---@class OpxSkinOutfitsOptions
---@field title? string menu title (default "Outfits")
---@field canSave? boolean default true: "Save current clothes" row
---@field canDelete? boolean default true

---@class OpxSkinGarments
---@field total integer garments in the whole list
---@field items { record: string, label: string }[] at most 60

---@alias OpxSkinError
---| 'invalid_player' not a connected player id
---| 'invalid_slots' not a slots table (unknown key, bad record) or empty where one key is needed
---| 'invalid_outfit' SetUniform: no slots for the player's family
---| 'family_unknown' SetUniform with male/female sets: the body family is not known yet
---| 'invalid_owner' the caller's VM generation could not be read
---| 'not_owner' Clear*: another resource owns it
---| 'busy' a SetClothing is running, or another resource previews on the player
---| 'uniform_active' the player wears a uniform
---| 'fitting' SetUniform while a preview is on
---| 'owned_by_other_resource' another resource's uniform (SetUniform), or a non-OPX holder of the platform slot
---| 'rate_limited' SetPreview faster than Config.previewMinMs
---| 'equipment_unavailable' open77_equipment is not running
---| 'appearance_unavailable' open77_appearance export failed
---| 'presentation_not_ready' the platform has no record for the player yet (loading)
---| 'invalid_outfit_items' a garment is unknown, not selectable, or not for the player's body family
---| 'request_timeout' the client did not answer in Config.requestTimeoutMs
---| 'player_left' disconnected or changed character while waiting
---| 'invalid_snapshot' the client's answer was incomplete
---| 'not_loaded' no character loaded / outfits not loaded yet
---| 'not_found' no outfit with that id
---| 'invalid_name' outfit name not 1..32 characters
---| 'limit' Config.outfits.max reached
---| 'db_error' the outfit row could not be written
---| 'failed' unexpected error (printed)
---| string any other platform or client refusal

---@class OpxSkinExports
local opx_skin = {}

-- Contract (a replacement implements these) ------------------------------------------------------------

--- ASYNC. The character's saved clothes (never the uniform / preview): all 7 keys. From memory when known;
--- asks the client when unknown or fresh == true and nothing temporary is shown.
---@param fresh? boolean
---@return OpxSkinSlots|nil slots
---@return OpxSkinError|nil reason
function opx_skin.GetClothing(playerId, fresh) end

--- ASYNC. Persistent change (omitted slots unchanged). Refused in uniform and during another resource's
--- preview; ends the caller's own preview. Admission by the server catalogue, then applied by the client;
--- after Config.settleMs raises opx:skin:clothingChanged. options.reason (string) is only logged.
--- true is the client's confirmation, not a database proof (see README).
---@param slots OpxSkinSlots at least one key
---@param options? { reason?: string }
---@return boolean ok
---@return OpxSkinError|nil reason
function opx_skin.SetClothing(playerId, slots, options) end

--- SYNC. Non-persistent projection owned by the caller, replaces its previous preview; seen by the player
--- and by players around. Omitted slots show the saved look.
---@param slots OpxSkinSlots at least one key
---@return boolean ok
---@return OpxSkinError|nil reason
function opx_skin.SetPreview(playerId, slots) end

--- SYNC. Back to the saved look (or the uniform). No preview = true.
---@return boolean ok
---@return 'not_owner'|'invalid_player'|nil reason
function opx_skin.ClearPreview(playerId) end

--- SYNC. A uniform owned by the caller (it may replace its own). Never stored.
---@param outfit OpxSkinSlots|OpxSkinUniform
---@return boolean ok
---@return OpxSkinError|nil reason
function opx_skin.SetUniform(playerId, outfit) end

--- SYNC. Removes the caller's uniform. No uniform = true.
---@return boolean ok
---@return 'not_owner'|'invalid_player'|nil reason
function opx_skin.ClearUniform(playerId) end

--- SYNC.
---@return { owner: string }|nil
function opx_skin.GetUniform(playerId) end

-- Additions (opx_skin only) -----------------------------------------------------------------------------

--- SYNC. Copies of the character's saved outfits.
---@return OpxSkinOutfit[]|nil outfits
---@return 'not_loaded'|'invalid_player'|nil reason
function opx_skin.GetOutfits(playerId) end

--- ASYNC. slots default = GetClothing. Returns the new id.
---@param name string 1..32 characters, trimmed
---@param slots? OpxSkinSlots
---@return integer|false id
---@return OpxSkinError|nil reason
function opx_skin.SaveOutfit(playerId, name, slots) end

--- ASYNC. SetClothing with the 7 slots of the outfit.
---@return boolean ok
---@return OpxSkinError|nil reason
function opx_skin.WearOutfit(playerId, id) end

--- SYNC.
---@return boolean ok
---@return OpxSkinError|nil reason
function opx_skin.RenameOutfit(playerId, id, name) end

--- SYNC.
---@return boolean ok
---@return OpxSkinError|nil reason
function opx_skin.DeleteOutfit(playerId, id) end

--- SYNC. Opens the outfits menu (opx_menu) on the player: wear / save current / rename / delete. Its
--- requests are accepted while the session lasts: Config.outfits.sessionMinutes, within
--- Config.outfits.sessionDistance metres of where it opened, until the player closes it or CloseOutfits.
---@param options? OpxSkinOutfitsOptions
---@return boolean ok
---@return 'invalid_player'|'invalid_options'|'not_loaded'|'not_ready'|nil reason
function opx_skin.OpenOutfits(playerId, options) end

--- SYNC.
---@return true
function opx_skin.CloseOutfits(playerId) end

-- Client exports (contract): Open77.exports.call(skin, name, ...):await() on the client --------------------

--- ASYNC (the first call per slot and family builds the list, later calls answer at once). Garments of a
--- slot sorted by label, from position offset + 1, at most `limit` (1..60, default 60). Built from
--- Open77.equipment.records minus Config.hide patterns and non-visual items; label = catalogue label, else
--- the game's name, else the record made readable. family default = the local body's.
---@param slot OpxSkinSlot
---@param offset? integer default 0
---@param limit? integer default 60
---@param family? 'male'|'female'
---@return OpxSkinGarments|nil
---@return 'invalid_slot'|'invalid_range'|string|nil reason
function opx_skin.GetGarments(slot, offset, limit, family) end

--- ASYNC. Position (1-based, same order as GetGarments) of a record, or nil.
---@return integer|nil
function opx_skin.FindGarment(slot, record, family) end

-- Host events (server, AddEventHandler):
--   opx:skin:clothingChanged (playerId, slots)  after a successful SetClothing (slots = the 7 saved slots)
--   opx:skin:uniformChanged (playerId, owner|nil) a uniform put on (owner = resource) or gone
---@alias OpxSkinClothingChangedEvent fun(playerId: integer, slots: OpxSkinSlots)
---@alias OpxSkinUniformChangedEvent fun(playerId: integer, owner: string|nil)

-- Replacing the skin provider:
-- 1. Implement the seven server exports of the contract and the two client exports with the same names,
--    arguments, results and reasons (callers test `ok` and show `reason`).
-- 2. Raise opx:skin:clothingChanged and opx:skin:uniformChanged as above.
-- 3. Point opx_core Config.providers.skin to your resource. The outfit exports and the menu are optional.
-- 4. Hold the platform's temporary outfit yourself (uniforms and previews of every caller), or callers
--    get 'owned_by_other_resource' from each other.
