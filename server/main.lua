-- Entry: the exports (skin contract + outfits), the outfits menu requests (validated, rate-limited, checked
-- against the open session), the optional command and the lifecycle.

local RESOURCE = GetCurrentResourceName()
local lastCall = {} -- [source] = GetGameTimer() of his last accepted menu request

-- Exports: the caller's identity (owner name + VM generation) owns previews and uniforms. A caller without
-- a usable generation is refused: its ownership could never be checked.
local function caller()
	local owner, generation = Skin.caller()
	if type(generation) ~= 'number' or generation == 0 then return nil end
	return owner, generation
end

-- Contract (a replacement implements these) ------------------------------------------------------------

-- ASYNC: the character's saved clothes (all 7 slots, record|false), or nil, reason.
exports('GetClothing', function(playerId, fresh)
	return Skin.getClothing(playerId, fresh == true)
end)

-- ASYNC: persistent change. true | false, reason.
exports('SetClothing', function(playerId, slots, options)
	local owner, generation = caller()
	if not owner then return false, 'invalid_owner' end
	if options ~= nil and type(options) ~= 'table' then return false, 'invalid_options' end
	local why = options and type(options.reason) == 'string' and options.reason or nil
	return Skin.setClothing(playerId, slots, owner, generation, why)
end)

-- SYNC: non-persistent projection owned by the caller.
exports('SetPreview', function(playerId, slots)
	local owner, generation = caller()
	if not owner then return false, 'invalid_owner' end
	return Skin.setPreview(playerId, slots, owner, generation)
end)

-- SYNC: back to the saved look.
exports('ClearPreview', function(playerId)
	local owner, generation = caller()
	if not owner then return false, 'not_owner' end
	return Skin.clearPreview(playerId, owner, generation)
end)

-- SYNC: a uniform (slots, or { male = slots, female = slots }) owned by the caller.
exports('SetUniform', function(playerId, outfit)
	local owner, generation = caller()
	if not owner then return false, 'invalid_owner' end
	return Skin.setUniform(playerId, outfit, owner, generation)
end)

-- SYNC: removes the caller's uniform.
exports('ClearUniform', function(playerId)
	local owner = caller()
	if not owner then return false, 'not_owner' end
	return Skin.clearUniform(playerId, owner)
end)

-- SYNC: { owner } or nil.
exports('GetUniform', function(playerId)
	return Skin.getUniform(playerId)
end)

-- Additions (opx_skin only) -----------------------------------------------------------------------------

exports('GetOutfits', function(playerId)
	local src = Skin.toSource(playerId)
	if not src then return nil, 'invalid_player' end
	return Outfits.get(src)
end)

-- ASYNC (insert, and GetClothing when slots is nil).
exports('SaveOutfit', function(playerId, name, slots)
	local src = Skin.connected(playerId)
	if not src then return false, 'invalid_player' end
	local id, why = Outfits.save(src, name, slots)
	if id then Outfits.sendList(src) end
	return id, why
end)

-- ASYNC.
exports('WearOutfit', function(playerId, id)
	local owner, generation = caller()
	if not owner then return false, 'invalid_owner' end
	local src = Skin.connected(playerId)
	if not src then return false, 'invalid_player' end
	return Outfits.wear(src, id, owner, generation)
end)

exports('RenameOutfit', function(playerId, id, name)
	local src = Skin.toSource(playerId)
	if not src then return false, 'invalid_player' end
	local ok, why = Outfits.rename(src, id, name)
	if ok then Outfits.sendList(src) end
	return ok, why
end)

exports('DeleteOutfit', function(playerId, id)
	local src = Skin.toSource(playerId)
	if not src then return false, 'invalid_player' end
	local ok, why = Outfits.delete(src, id)
	if ok then Outfits.sendList(src) end
	return ok, why
end)

exports('OpenOutfits', function(playerId, options)
	return Outfits.open(playerId, options)
end)

exports('CloseOutfits', function(playerId)
	local src = Skin.toSource(playerId)
	if src then Outfits.close(src, true) end
	return true
end)

-- Outfits menu requests -------------------------------------------------------------------------------

local function notify(src, key, kind, params)
	pcall(Open77.exports.callSync, 'opx_core', 'NotifyLocale', src, key, params or {}, kind or 'info', nil, 'title')
end

local function allow(src)
	local now = GetGameTimer()
	local last = lastCall[src]
	if last and now - last < (tonumber(Config.rateLimitMs) or 400) then return false end
	lastCall[src] = now
	return true
end

-- Known refusal keys of the locales; anything else reads as a generic failure with the reason.
local KNOWN = {
	busy = true, uniform_active = true, not_loaded = true, invalid_name = true, limit = true, db_error = true,
	not_found = true, equipment_unavailable = true, request_timeout = true, invalid_outfit_items = true,
	presentation_not_ready = true, owned_by_other_resource = true,
}
local function refuse(src, reason)
	if KNOWN[reason] then return notify(src, reason, 'error') end
	notify(src, 'failed', 'error', { reason = tostring(reason) })
end

-- An integer id from a client value (numbers may travel as floats), or nil.
local function toId(value)
	return type(value) == 'number' and value == value and math.tointeger(value) or nil
end

-- Every menu request: a valid source, under the rate limit, with an open session. The handler runs in
-- its own thread (wearing and saving wait for the client / the database).
local function onRequest(name, handler)
	RegisterNetEvent(name, function(...)
		local src = Skin.toSource(source)
		if not src or not allow(src) then return end
		local s = Outfits.session(src)
		if not s then return notify(src, 'session_closed', 'error') end
		local args = table.pack(...)
		CreateThread(function() handler(src, s, table.unpack(args, 1, math.min(args.n, 4))) end)
	end)
end

onRequest('opx_skin:outfits:wear', function(src, _, id)
	id = toId(id)
	if not id then return end
	local ok, why = Outfits.wear(src, id, RESOURCE, Open77.resource.generation())
	if ok then notify(src, 'worn', 'success') else refuse(src, why) end
end)

onRequest('opx_skin:outfits:save', function(src, s, name)
	if not s.canSave or type(name) ~= 'string' then return end
	local id, why = Outfits.save(src, name)
	if id then
		notify(src, 'saved', 'success', { name = Outfits.toName(name) or '' })
		Outfits.sendList(src)
	else
		refuse(src, why)
	end
end)

onRequest('opx_skin:outfits:rename', function(src, _, id, name)
	id = toId(id)
	if not id or type(name) ~= 'string' then return end
	local ok, why = Outfits.rename(src, id, name)
	if ok then
		notify(src, 'renamed', 'success')
		Outfits.sendList(src)
	else
		refuse(src, why)
	end
end)

onRequest('opx_skin:outfits:delete', function(src, s, id)
	id = toId(id)
	if not s.canDelete or not id then return end
	local ok, why = Outfits.delete(src, id)
	if ok then
		notify(src, 'deleted', 'success')
		Outfits.sendList(src)
	else
		refuse(src, why)
	end
end)

-- The client closed the menu: the session ends (no rate limit, no answer).
RegisterNetEvent('opx_skin:outfits:closed', function()
	local src = Skin.toSource(source)
	if src then Outfits.close(src, false) end
end)

-- Command (testing) --------------------------------------------------------------------------------

if type(Config.command) == 'string' and Config.command ~= '' then
	RegisterCommand(Config.command, function(src)
		src = Skin.toSource(src)
		if not src then return print('[opx_skin] use this command in game') end
		local ok, why = Outfits.open(src)
		if not ok then refuse(src, why) end
	end, Config.commandRestricted ~= false)
end

-- Lifecycle --------------------------------------------------------------------------------------------

-- A character is loaded: learn his clothes, load his outfits.
local function loaded(playerId, citizenId)
	local src = Skin.connected(playerId)
	if not src or type(citizenId) ~= 'string' or citizenId == '' then return end
	Skin.release(src)
	Outfits.forget(src)
	Skin.state(src)
	Skin.learn(src)
	Outfits.load(src, citizenId)
end

AddEventHandler('opx:playerLoaded', function(playerId, data)
	loaded(playerId, type(data) == 'table' and data.citizenId or nil)
end)

-- Character switch / relog: everything of the previous character goes.
AddEventHandler('opx:playerUnloaded', function(playerId)
	local src = Skin.toSource(playerId)
	if not src then return end
	Skin.release(src)
	Outfits.forget(src)
	lastCall[src] = nil
end)

AddEventHandler('onPlayerDisconnected', function(playerId)
	local src = Skin.toSource(playerId)
	if not src then return end
	Skin.forget(src) -- the platform retires the temporary outfit itself
	Outfits.forget(src)
	lastCall[src] = nil
end)

AddEventHandler('opx:characterDeleted', function(_, citizenId)
	Outfits.purge(citizenId)
end)

-- Another resource stopped: its uniforms / previews end at once (kept when its new VM already runs).
AddEventHandler('open77:resource:stopped', function(name)
	if type(name) == 'string' and name ~= RESOURCE then Skin.sweep() end
end)

-- Start (also a hot reload): the characters already loaded.
CreateThread(function()
	Wait(1000) -- exports answer once every VM of the start finished preparing
	local ok, list = pcall(Open77.exports.callSync, 'opx_core', 'GetLoadedPlayers')
	if ok and type(list) == 'table' then
		for _, data in ipairs(list) do
			if type(data) == 'table' and not Skin.players[tonumber(data.source) or 0] then
				loaded(data.source, data.citizenId)
			end
		end
	end
	-- Owners that died without a stop event, outfits sessions that expired or walked away.
	while true do
		Wait(1000)
		Skin.sweep()
		Outfits.sweep()
	end
end)

-- Our own stop: the platform retires the temporary outfits we held (generation check); only the clients
-- need telling that the outfits menu is gone.
AddEventHandler('onResourceStop', function(name)
	if name ~= RESOURCE then return end
	for src in pairs(Outfits.sessions) do pcall(TriggerClientEvent, 'opx_skin:outfits:close', src) end
end)
