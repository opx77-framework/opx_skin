-- Saved outfits (named sets of the 7 slots): memory is the authority, each change written at once in
-- opx_skin's own table (callback form). Loaded per character on opx:playerLoaded, dropped on unload.
-- Without a database the outfits last for the session (ids are then negative and never written).
-- Also the outfits menu session: the menu's net requests are accepted only while it is open.

Outfits = { db = 'starting', lists = {}, sessions = {} }

local SCHEMA = [[CREATE TABLE IF NOT EXISTS opx_skin_outfits (
	id INT UNSIGNED NOT NULL AUTO_INCREMENT,
	citizen_id VARCHAR(64) NOT NULL,
	name VARCHAR(64) NOT NULL,
	slots TEXT NOT NULL,
	created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
	PRIMARY KEY (id),
	INDEX idx_opx_skin_outfits_citizen (citizen_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]]

local localId = 0 -- session-only ids (no database): -1, -2...

-- lists[src] = { citizenId, items = { { id, name, slots } } | nil while loading }

-- Helpers ----------------------------------------------------------------------------------------

-- A name: one line, no control characters, trimmed, 1..32 characters (UTF-8), or nil.
function Outfits.toName(value)
	if type(value) ~= 'string' then return nil end
	local text = value:gsub('%c', ' '):gsub('^%s+', ''):gsub('%s+$', '')
	if text == '' or #text > 128 or not utf8.len(text) or utf8.len(text) > 32 then return nil end
	return text
end

local function citizenOf(src)
	local ok, data = pcall(Open77.exports.callSync, 'opx_core', 'GetPlayer', src)
	if ok and type(data) == 'table' and type(data.citizenId) == 'string' and data.citizenId ~= '' then
		return data.citizenId
	end
	return nil
end

local function copyList(items)
	local out = {}
	for i, o in ipairs(items) do out[i] = { id = o.id, name = o.name, slots = Skin.copy(o.slots) } end
	return out
end

local function find(items, id)
	for i, o in ipairs(items) do
		if o.id == id then return o, i end
	end
	return nil
end

-- A write in callback form (never yields). A refusal both returns false and schedules the callback.
local function write(sql, params, what)
	local ok, refused, reason = pcall(Open77.database.update, sql, params, function(_, failure)
		if failure then Skin.log('%s failed: %s', what, tostring(failure)) end
	end)
	if not ok then Skin.log('%s refused: %s', what, tostring(refused)) end
	return ok and refused ~= false
end

-- Loading ----------------------------------------------------------------------------------------

local function decodeRow(row)
	local id = math.tointeger(tonumber(row.id) or 0)
	local name = Outfits.toName(row.name)
	local ok, slots = pcall(json.decode, row.slots)
	slots = ok and Skin.cleanSlots(slots, true) or nil
	if not id or id < 1 or not name or not slots then return nil end
	return { id = id, name = name, slots = Skin.full(slots) }
end

-- Loads the outfits of the player's character (callback form).
function Outfits.load(src, citizenId)
	local entry = { citizenId = citizenId, items = nil }
	Outfits.lists[src] = entry
	if Outfits.db == 'none' then entry.items = {} return end
	if Outfits.db ~= 'ready' then return end -- loaded when the schema is ready
	local ok, refused, reason = pcall(Open77.database.query,
		'SELECT id, name, slots FROM opx_skin_outfits WHERE citizen_id = ? ORDER BY id LIMIT 200', { citizenId },
		function(rows, failure)
			if Outfits.lists[src] ~= entry then return end -- left or switched character meanwhile
			if failure or type(rows) ~= 'table' then
				Skin.log('outfits of %s not loaded: %s', citizenId, tostring(failure))
				return
			end
			local items = {}
			for _, row in ipairs(rows) do
				local o = type(row) == 'table' and decodeRow(row)
				if o then items[#items + 1] = o end
			end
			entry.items = items
		end)
	if not ok or refused == false then Skin.log('outfits query refused: %s', tostring(ok and reason or refused)) end
end

function Outfits.forget(src)
	Outfits.lists[src] = nil
	Outfits.sessions[src] = nil
end

-- The loaded list of a player, or nil.
local function items(src)
	local entry = Outfits.lists[src]
	if not entry or not entry.items then return nil end
	if citizenOf(src) ~= entry.citizenId then return nil end
	return entry.items, entry
end

-- Exports' logic --------------------------------------------------------------------------------------

function Outfits.get(src)
	local list = items(src)
	if not list then return nil, 'not_loaded' end
	return copyList(list)
end

-- (yields: may ask GetClothing) id | false, reason
function Outfits.save(src, name, slots)
	local list, entry = items(src)
	if not list then return false, 'not_loaded' end
	name = Outfits.toName(name)
	if not name then return false, 'invalid_name' end
	if #list >= (tonumber(Config.outfits.max) or 12) then return false, 'limit' end
	local clean
	if slots == nil then
		local current, why = Skin.getClothing(src)
		if not current then return false, why end
		clean = current
	else
		clean = Skin.cleanSlots(slots, true)
		if not clean then return false, 'invalid_slots' end
	end
	clean = Skin.full(clean)

	local id
	if Outfits.db == 'ready' then
		local done, insertId, failure = false, nil, nil
		local ok, refused, reason = pcall(Open77.database.insert,
			'INSERT INTO opx_skin_outfits (citizen_id, name, slots) VALUES (?, ?, ?)',
			{ entry.citizenId, name, json.encode(clean) }, function(value, why)
				done, insertId, failure = true, value, why
			end)
		if not ok or refused == false then return false, 'db_error' end
		local deadline = GetGameTimer() + 10000
		while not done and GetGameTimer() < deadline do Wait(50) end
		insertId = math.tointeger(tonumber(insertId) or 0)
		if not done or failure or not insertId or insertId < 1 then
			Skin.log('outfit insert failed: %s', tostring(failure or reason or 'timeout'))
			return false, 'db_error'
		end
		id = insertId
	else
		localId = localId - 1
		id = localId
	end
	-- The player may have left or switched character while the insert ran.
	if Outfits.lists[src] ~= entry then return false, 'not_loaded' end
	if #entry.items >= (tonumber(Config.outfits.max) or 12) then
		if id > 0 then write('DELETE FROM opx_skin_outfits WHERE id = ?', { id }, 'outfit delete') end
		return false, 'limit'
	end
	entry.items[#entry.items + 1] = { id = id, name = name, slots = clean }
	return id
end

function Outfits.rename(src, id, name)
	local list = items(src)
	if not list then return false, 'not_loaded' end
	id = math.tointeger(tonumber(id) or 0)
	local o = id and find(list, id)
	if not o then return false, 'not_found' end
	name = Outfits.toName(name)
	if not name then return false, 'invalid_name' end
	o.name = name
	if id > 0 then write('UPDATE opx_skin_outfits SET name = ? WHERE id = ?', { name, id }, 'outfit rename') end
	return true
end

function Outfits.delete(src, id)
	local list = items(src)
	if not list then return false, 'not_loaded' end
	id = math.tointeger(tonumber(id) or 0)
	local o, index = nil, nil
	if id then o, index = find(list, id) end
	if not o then return false, 'not_found' end
	table.remove(list, index)
	if id > 0 then write('DELETE FROM opx_skin_outfits WHERE id = ?', { id }, 'outfit delete') end
	return true
end

-- (yields) SetClothing with the 7 slots of the outfit.
function Outfits.wear(src, id, owner, generation)
	local list = items(src)
	if not list then return false, 'not_loaded' end
	id = math.tointeger(tonumber(id) or 0)
	local o = id and find(list, id)
	if not o then return false, 'not_found' end
	return Skin.setClothing(src, Skin.copy(o.slots), owner, generation, 'outfit ' .. o.name)
end

-- Character deleted: its rows go.
function Outfits.purge(citizenId)
	if type(citizenId) ~= 'string' or citizenId == '' or Outfits.db ~= 'ready' then return end
	write('DELETE FROM opx_skin_outfits WHERE citizen_id = ?', { citizenId }, 'outfits purge')
end

-- Menu session -----------------------------------------------------------------------------------------

local function position(src)
	local ok, pos = pcall(Open77.players.position, src)
	if ok and type(pos) == 'table' and type(pos.x) == 'number' and type(pos.y) == 'number'
		and type(pos.z) == 'number' then
		return pos
	end
	return nil
end

-- What the client menu shows.
local function menuList(list)
	local out = {}
	for i, o in ipairs(list) do out[i] = { id = o.id, name = o.name } end
	return out
end

function Outfits.sendList(src)
	local s, list = Outfits.sessions[src], items(src)
	if not s or not list then return end
	pcall(TriggerClientEvent, 'opx_skin:outfits:list', src, menuList(list))
end

-- OpenOutfits: true | false, reason.
function Outfits.open(src, options)
	src = Skin.connected(src)
	if not src then return false, 'invalid_player' end
	if options ~= nil and type(options) ~= 'table' then return false, 'invalid_options' end
	options = options or {}
	if options.title ~= nil and type(options.title) ~= 'string' then return false, 'invalid_options' end
	local list = items(src)
	if not list then return false, 'not_loaded' end
	local pos = position(src)
	if not pos then return false, 'not_ready' end
	local title = options.title and options.title:gsub('%c', ' '):sub(1, 48) or nil
	Outfits.sessions[src] = {
		x = pos.x, y = pos.y, z = pos.z, bucket = pos.bucket,
		expires = GetGameTimer() + (tonumber(Config.outfits.sessionMinutes) or 5) * 60000,
		canSave = options.canSave ~= false, canDelete = options.canDelete ~= false,
	}
	pcall(TriggerClientEvent, 'opx_skin:outfits:open', src, {
		title = title ~= '' and title or nil, canSave = options.canSave ~= false,
		canDelete = options.canDelete ~= false, list = menuList(list), max = tonumber(Config.outfits.max) or 12,
	})
	return true
end

function Outfits.close(src, tell)
	if not Outfits.sessions[src] then return end
	Outfits.sessions[src] = nil
	if tell then pcall(TriggerClientEvent, 'opx_skin:outfits:close', src) end
end

-- The open session of a player, still valid (time, distance, bucket), or nil (closed then).
function Outfits.session(src)
	local s = Outfits.sessions[src]
	if not s then return nil end
	local pos = position(src)
	local reach = tonumber(Config.outfits.sessionDistance) or 4.0
	local valid = GetGameTimer() <= s.expires and pos ~= nil and pos.bucket == s.bucket
	if valid then
		local dx, dy, dz = pos.x - s.x, pos.y - s.y, pos.z - s.z
		valid = dx * dx + dy * dy + dz * dz <= reach * reach
	end
	if not valid then
		Outfits.close(src, true)
		return nil
	end
	return s
end

-- Every open session is checked (timeout, walked away).
function Outfits.sweep()
	for src in pairs(Outfits.sessions) do Outfits.session(src) end
end

-- Schema at start (callback form), then the characters already loaded (hot reload) get their outfits.
CreateThread(function()
	if type(Open77.database) ~= 'table' then
		Outfits.db = 'none'
		Skin.log('no database bridge: outfits last for the session (enable the database, database.access)')
	else
		local queued, reason = Open77.database.ready(function()
			Open77.database.update(SCHEMA, {}, function(_, failure)
				if failure then
					Skin.log('schema failed: %s (outfits last for the session)', tostring(failure))
					Outfits.db = 'none'
				else
					Outfits.db = 'ready'
				end
				for src, entry in pairs(Outfits.lists) do
					if not entry.items then Outfits.load(src, entry.citizenId) end
				end
			end)
		end)
		if not queued then
			Outfits.db = 'none'
			Skin.log('database unavailable: %s (outfits last for the session)', tostring(reason))
		end
	end
	for src, entry in pairs(Outfits.lists) do
		if not entry.items and Outfits.db == 'none' then entry.items = {} end
	end
end)

-- Exposed for main.lua.
Outfits.citizenOf = citizenOf
