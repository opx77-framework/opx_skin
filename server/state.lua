-- Per-player clothing state, validation and every platform call. Decides everything.
--
-- The platform owns the clothes: open77_appearance keeps the saved record (SQL), open77_equipment (client)
-- applies it and forwards local changes. opx_skin writes saved clothes with Open77.clothing.set (the
-- player's client applies them, the relay stores them) and is the only OPX holder of the platform's single
-- temporary outfit (setTemporaryOutfit), on which it shows the preview of a fitting, else the uniform of a
-- job, else nothing. Memory per player:
--   worn     the 7 saved slots as last known (never the uniform / preview), or nil while unknown
--   uniform  { owner, generation, slots } of the resource that dressed him, or nil
--   preview  { owner, generation, slots } of the resource fitting him (the creator), or nil
--   busy     a SetClothing is running
--   epoch    bumped on every projection change: a snapshot answered across a change is thrown away

Skin = { players = {} }

local APPEARANCE = 'open77_appearance'
local RESOURCE = GetCurrentResourceName()

-- The 7 slots, in display order. Underwear is never touched (the platform refuses it in both paths).
Skin.SLOTS = { 'Head', 'Face', 'InnerChest', 'OuterChest', 'Legs', 'Feet', 'Outfit' }
local IS_SLOT = {}
for _, slot in ipairs(Skin.SLOTS) do IS_SLOT[slot] = true end

-- Snapshot rows of the open77_equipment relay use the old slot names.
local ROW_SLOT = {
	head = 'Head', face = 'Face', inner_chest = 'InnerChest', outer_chest = 'OuterChest',
	legs = 'Legs', feet = 'Feet', outfit = 'Outfit',
}

-- Helpers ----------------------------------------------------------------------------------------

-- A player id from anything (positive integer within uint32), or nil. Natives abort on anything else.
function Skin.toSource(value)
	local id = tonumber(value)
	if not id or id ~= id or id < 1 or id > 0xFFFFFFFF or id % 1 ~= 0 then return nil end
	return math.tointeger(id)
end

-- A connected player id, or nil.
function Skin.connected(value)
	local src = Skin.toSource(value)
	if not src then return nil end
	local ok, name = pcall(GetPlayerName, src)
	return (ok and name ~= nil and name ~= false) and src or nil
end

-- An item record: string of 1..160 bytes without control characters.
function Skin.isRecord(value)
	return type(value) == 'string' and #value >= 1 and #value <= 160 and not value:find('[%z\1-\31\127]')
end

-- A clean slots table (only the 7 slots, record or false), or nil. needOne: at least one key.
function Skin.cleanSlots(value, needOne)
	if type(value) ~= 'table' then return nil end
	local clean, count = {}, 0
	for slot, item in pairs(value) do
		if not IS_SLOT[slot] then return nil end
		if item ~= false and not Skin.isRecord(item) then return nil end
		clean[slot] = item
		count = count + 1
	end
	if needOne and count == 0 then return nil end
	return clean
end

function Skin.copy(slots)
	if type(slots) ~= 'table' then return nil end
	local out = {}
	for k, v in pairs(slots) do out[k] = v end
	return out
end

-- All 7 keys: `slots` over `base` (missing in both = false).
function Skin.full(slots, base)
	local out = {}
	for _, slot in ipairs(Skin.SLOTS) do
		local v = slots and slots[slot]
		if v == nil and base then v = base[slot] end
		out[slot] = v or false
	end
	return out
end

-- Snapshot rows of the relay -> the 7 slots, or nil when a row is missing.
function Skin.fromRows(rows)
	if type(rows) ~= 'table' then return nil end
	local out, seen = {}, 0
	for _, row in ipairs(rows) do
		local slot = type(row) == 'table' and ROW_SLOT[row.slot]
		if slot and out[slot] == nil then
			out[slot] = (row.equipped == true and Skin.isRecord(row.record)) and row.record or false
			seen = seen + 1
		end
	end
	return seen == #Skin.SLOTS and out or nil
end

function Skin.log(text, ...)
	print(('[opx_skin] ' .. text):format(...))
end

-- The calling resource and its VM generation (an export's caller, else opx_skin itself).
function Skin.caller()
	local owner = GetInvokingResource()
	if type(owner) ~= 'string' or owner == '' then return RESOURCE, Open77.resource.generation() end
	local generation = type(GetInvokingResourceGeneration) == 'function' and GetInvokingResourceGeneration() or nil
	if type(generation) ~= 'number' or generation == 0 then
		local ok, value = pcall(Open77.resource.generation, owner)
		generation = ok and value or nil
	end
	return owner, generation
end

-- An owned entry (uniform / preview) whose owner VM still runs.
function Skin.live(entry)
	if not entry or type(entry.generation) ~= 'number' or entry.generation == 0 then return false end
	local ok, current = pcall(Open77.resource.generation, entry.owner)
	return ok and current == entry.generation
end

-- The state of a connected player (created on first use).
function Skin.state(src)
	local p = Skin.players[src]
	if not p then
		p = { epoch = 0, lastPreview = nil }
		Skin.players[src] = p
	end
	return p
end

function Skin.forget(src)
	Skin.players[src] = nil
end

-- Platform calls ------------------------------------------------------------------------------------

-- A synchronous export of open77_appearance: ok, a, b | false, 'appearance_unavailable'.
local function appearance(name, ...)
	local called, a, b = pcall(Open77.exports.callSync, APPEARANCE, name, ...)
	if not called then return false, 'appearance_unavailable' end
	return true, a, b
end

-- The body family the platform knows ('male' | 'female'), else opx_core's, else nil.
function Skin.family(src)
	local ok, info = appearance('character', src)
	if ok and type(info) == 'table' and (info.family == 'male' or info.family == 'female') then return info.family end
	local called, data = pcall(Open77.exports.callSync, 'opx_core', 'GetPlayer', src)
	if called and type(data) == 'table' and (data.family == 'male' or data.family == 'female') then return data.family end
	return nil
end

-- Shows what the player should wear on top of his saved clothes: the preview, else the uniform, else nothing.
-- true | false, platform reason.
function Skin.project(src, p)
	local want = (Skin.live(p.preview) and p.preview.slots) or (Skin.live(p.uniform) and p.uniform.slots) or nil
	local called, ok, reason
	if want then
		called, ok, reason = appearance('setTemporaryOutfit', src, want)
	else
		called, ok, reason = appearance('clearTemporaryOutfit', src)
	end
	if not called then return false, ok end
	if ok ~= true then return false, type(reason) == 'string' and reason or 'refused' end
	return true
end

-- Clothing requests (Open77.clothing.*) answer on the resource-local event open77:clothing:completed.
local pending = {} -- [requestId] = { done, accepted, reason, result }

AddEventHandler('open77:clothing:completed', function(playerId, requestId, _, accepted, reason, result)
	local w = type(requestId) == 'string' and pending[requestId]
	if not w or w.player ~= tonumber(playerId) then return end
	w.done, w.accepted, w.reason, w.result = true, accepted == true, reason, result
end)

-- Waits for one request (yields). accepted, reason, result. Gives up when the player's state changed
-- (disconnect, character switch) or after Config.requestTimeoutMs.
local function await(src, p, requestId)
	local w = { player = src }
	pending[requestId] = w
	local deadline = GetGameTimer() + (tonumber(Config.requestTimeoutMs) or 12000)
	while not w.done do
		if Skin.players[src] ~= p then pending[requestId] = nil return false, 'player_left' end
		if GetGameTimer() > deadline then pending[requestId] = nil return false, 'request_timeout' end
		Wait(50)
	end
	pending[requestId] = nil
	if Skin.players[src] ~= p then return false, 'player_left' end
	if not w.accepted then return false, (type(w.reason) == 'string' and w.reason ~= '') and w.reason or 'refused' end
	return true, nil, w.result
end

local function equipmentRunning()
	return GetResourceState('open77_equipment') == 'running'
end

-- Asks the client what it wears (yields): the 7 slots, or nil, reason. Stored in `worn` when nothing
-- temporary was shown meanwhile.
function Skin.snapshot(src)
	local p = Skin.players[src]
	if not p then return nil, 'not_ready' end
	if not equipmentRunning() then return nil, 'equipment_unavailable' end
	if p.busy or Skin.live(p.preview) then return nil, 'busy' end
	if Skin.live(p.uniform) then return nil, 'uniform_active' end
	local epoch = p.epoch
	local ok, requestId, reason = pcall(Open77.clothing.requestSnapshot, src)
	if not ok or not requestId then return nil, tostring(ok and reason or requestId) end
	local accepted, why, rows = await(src, p, requestId)
	if not accepted then return nil, why end
	if p.epoch ~= epoch or p.busy then return nil, 'busy' end
	local slots = Skin.fromRows(rows)
	if not slots then return nil, 'invalid_snapshot' end
	p.worn = slots
	return Skin.copy(slots)
end

-- Fills `worn` after a load (2 s, then every 5 s, 6 tries). Runs in its own thread.
function Skin.learn(src)
	local p = Skin.players[src]
	if not p then return end
	CreateThread(function()
		Wait(2000)
		for _ = 1, 6 do
			if Skin.players[src] ~= p or p.worn then return end
			if Skin.snapshot(src) then return end
			Wait(5000)
		end
	end)
end

-- Contract ---------------------------------------------------------------------------------------------

-- GetClothing (may yield): the saved 7 slots, from memory or from the client.
function Skin.getClothing(src, fresh)
	src = Skin.connected(src)
	if not src then return nil, 'invalid_player' end
	local p = Skin.state(src)
	if p.worn and fresh ~= true then return Skin.copy(p.worn) end
	if p.busy then return nil, 'busy' end
	if Skin.live(p.uniform) or Skin.live(p.preview) then
		-- The client wears the costume: only memory can tell the saved look.
		if p.worn then return Skin.copy(p.worn) end
		return nil, Skin.live(p.preview) and 'busy' or 'uniform_active'
	end
	return Skin.snapshot(src)
end

-- SetClothing (yields): persistent change through the player's client. true | false, reason.
function Skin.setClothing(src, slots, owner, generation, why)
	src = Skin.connected(src)
	if not src then return false, 'invalid_player' end
	local clean = Skin.cleanSlots(slots, true)
	if not clean then return false, 'invalid_slots' end
	if not equipmentRunning() then return false, 'equipment_unavailable' end
	local p = Skin.state(src)
	if p.busy then return false, 'busy' end
	if Skin.live(p.uniform) then return false, 'uniform_active' end
	if Skin.live(p.preview) and (p.preview.owner ~= owner or p.preview.generation ~= generation) then
		return false, 'busy'
	end

	p.busy = true
	p.epoch = p.epoch + 1
	local ran, ok, reason = pcall(function()
		-- Admission: the server catalogue and the player's family, through the temporary outfit.
		local called, admitted, refusal = appearance('setTemporaryOutfit', src, clean)
		if not called then return false, admitted end
		if admitted ~= true then
			Skin.project(src, p) -- the caller's preview (if any) is shown again
			return false, type(refusal) == 'string' and refusal or 'refused'
		end
		-- Nothing temporary while the client writes: its changes must reach the saved record.
		p.preview = nil
		local cleared, why = Skin.project(src, p)
		if not cleared then return false, why end

		local sent, requestId, dispatch = pcall(Open77.clothing.set, src, clean)
		if not sent or not requestId then return false, tostring(sent and dispatch or requestId) end
		local accepted, refused, rows = await(src, p, requestId)
		if not accepted then return false, refused end
		Wait(math.max(0, tonumber(Config.settleMs) or 700))
		if Skin.players[src] ~= p then return false, 'player_left' end
		p.worn = Skin.fromRows(rows) or (p.worn and Skin.full(clean, p.worn)) or nil
		return true
	end)
	p.busy = false
	if not ran then
		Skin.log('SetClothing of %d failed: %s', src, tostring(ok))
		return false, 'failed'
	end
	if not ok then return false, reason end
	if Skin.players[src] == p and p.worn then
		if type(why) == 'string' then Skin.log('clothes of %d changed (%s)', src, why:sub(1, 64)) end
		TriggerEvent('opx:skin:clothingChanged', src, Skin.copy(p.worn))
	end
	return true
end

-- SetPreview (sync): a projection owned by the caller, all 7 keys (missing ones = saved look).
function Skin.setPreview(src, slots, owner, generation)
	src = Skin.connected(src)
	if not src then return false, 'invalid_player' end
	local clean = Skin.cleanSlots(slots, true)
	if not clean then return false, 'invalid_slots' end
	local p = Skin.state(src)
	local now = GetGameTimer()
	if p.lastPreview and now - p.lastPreview < (tonumber(Config.previewMinMs) or 80) then return false, 'rate_limited' end
	if p.busy then return false, 'busy' end
	if Skin.live(p.uniform) then return false, 'uniform_active' end
	local old = p.preview
	if Skin.live(old) and (old.owner ~= owner or old.generation ~= generation) then return false, 'busy' end
	p.lastPreview = now
	p.preview = { owner = owner, generation = generation, slots = p.worn and Skin.full(clean, p.worn) or clean }
	local ok, reason = Skin.project(src, p)
	if not ok then
		p.preview = Skin.live(old) and old or nil
		return false, reason
	end
	p.epoch = p.epoch + 1
	return true
end

-- ClearPreview (sync): back to the saved look (or the uniform). No preview = true.
function Skin.clearPreview(src, owner, generation)
	src = Skin.toSource(src)
	if not src then return false, 'invalid_player' end
	local p = Skin.players[src]
	if not p or not Skin.live(p.preview) then
		if p then p.preview = nil end
		return true
	end
	if p.preview.owner ~= owner or p.preview.generation ~= generation then return false, 'not_owner' end
	p.preview = nil
	p.epoch = p.epoch + 1
	if Skin.connected(src) then Skin.project(src, p) end
	return true
end

-- The uniform slots of an outfit: a slots table, or { male = slots, female = slots } by body family.
local function uniformSlots(src, outfit)
	if type(outfit) ~= 'table' then return nil end
	if outfit.male ~= nil or outfit.female ~= nil then
		local family = Skin.family(src)
		if not family then return nil, 'family_unknown' end
		return Skin.cleanSlots(outfit[family], true)
	end
	return Skin.cleanSlots(outfit, true)
end

-- SetUniform (sync): owned by the caller, replaces its own.
function Skin.setUniform(src, outfit, owner, generation)
	src = Skin.connected(src)
	if not src then return false, 'invalid_player' end
	local slots, why = uniformSlots(src, outfit)
	if not slots then return false, why or 'invalid_outfit' end
	local p = Skin.state(src)
	if p.busy then return false, 'busy' end
	if Skin.live(p.preview) then return false, 'fitting' end
	local old = p.uniform
	local oldLive = Skin.live(old)
	if oldLive and old.owner ~= owner then return false, 'owned_by_other_resource' end
	p.uniform = { owner = owner, generation = generation, slots = slots }
	local ok, reason = Skin.project(src, p)
	if not ok then
		p.uniform = oldLive and old or nil
		return false, reason
	end
	p.epoch = p.epoch + 1
	if not oldLive then TriggerEvent('opx:skin:uniformChanged', src, owner) end
	return true
end

-- ClearUniform (sync). No uniform = true.
function Skin.clearUniform(src, owner)
	src = Skin.toSource(src)
	if not src then return false, 'invalid_player' end
	local p = Skin.players[src]
	if not p or not Skin.live(p.uniform) then
		if p then p.uniform = nil end
		return true
	end
	if p.uniform.owner ~= owner then return false, 'not_owner' end
	p.uniform = nil
	p.epoch = p.epoch + 1
	if Skin.connected(src) then Skin.project(src, p) end
	TriggerEvent('opx:skin:uniformChanged', src, nil)
	return true
end

function Skin.getUniform(src)
	src = Skin.toSource(src)
	local p = src and Skin.players[src]
	if not p or not Skin.live(p.uniform) then return nil end
	return { owner = p.uniform.owner }
end

-- A character goes (unload, switch): what was shown on him ends now. The platform also retires a
-- temporary outfit on character selection; this covers an unload without one.
function Skin.release(src)
	local p = Skin.players[src]
	if not p then return end
	local hadUniform = Skin.live(p.uniform)
	local shown = hadUniform or Skin.live(p.preview)
	Skin.forget(src)
	if shown and Skin.connected(src) then appearance('clearTemporaryOutfit', src) end
	if hadUniform then TriggerEvent('opx:skin:uniformChanged', src, nil) end
end

-- Owners that stopped (or reloaded): their uniform / preview ends and the projection follows.
function Skin.sweep()
	for src, p in pairs(Skin.players) do
		local changed, uniformGone = false, false
		if p.preview and not Skin.live(p.preview) then p.preview, changed = nil, true end
		if p.uniform and not Skin.live(p.uniform) then p.uniform, changed, uniformGone = nil, true, true end
		if changed then
			p.epoch = p.epoch + 1
			if Skin.connected(src) and not p.busy then Skin.project(src, p) end
			if uniformGone then TriggerEvent('opx:skin:uniformChanged', src, nil) end
		end
	end
end
