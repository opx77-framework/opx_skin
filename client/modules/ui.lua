-- The outfits menu (opx_menu) and its name form (opx_dialog through Menu.dialog). Shows and asks; the server
-- decides (and answers through opx_core NotifyLocale with the keys of locales/*.json).

local OPX = assert(require('@opx_core'))
local Menu = assert(require('@opx_menu'))

local Ui = {}

local T = OPX.Locale()
local main = nil     -- the open outfits menu, or nil
local options = nil  -- { canSave, canDelete, max } of the open menu
local rows = {}      -- { { id, name } } as the server sent them
local closing = false -- the server closed it: no 'closed' notice back

function Ui.text(key, params) return T(key, params or {}) end

local function askName(title, default)
	local values = Menu.dialog({
		title = title, submitLabel = Ui.text('submit'),
		fields = { { name = 'name', label = Ui.text('name'), default = default, minLength = 1, maxLength = 32 } },
	})
	return values and type(values.name) == 'string' and values.name or nil
end

-- The actions on one outfit, as a child menu.
local function openOutfit(row)
	local elements = {
		{ label = Ui.text('wear'), value = 'wear', icon = 'check', description = Ui.text('wear_desc') },
		{ label = Ui.text('rename'), value = 'rename', icon = 'edit' },
	}
	if options.canDelete then elements[#elements + 1] = { label = Ui.text('delete'), value = 'delete', icon = 'trash' } end
	Menu.open({
		id = 'opx_skin_outfit', title = row.name, parent = main, elements = elements,
		onSelect = function(element, menu)
			if element.value == 'wear' then
				TriggerServerEvent('opx_skin:outfits:wear', row.id)
				menu:close()
			elseif element.value == 'rename' then
				local name = askName(Ui.text('rename'), row.name)
				if name then TriggerServerEvent('opx_skin:outfits:rename', row.id, name) end
				menu:close()
			elseif element.value == 'delete' then
				local yes = Menu.confirm({
					title = Ui.text('delete'), message = Ui.text('delete_confirm', { name = row.name }),
					confirmLabel = Ui.text('delete'), cancelLabel = Ui.text('cancel'),
				})
				if yes then TriggerServerEvent('opx_skin:outfits:delete', row.id) end
				menu:close()
			end
		end,
	})
end

local function elements()
	local list = {}
	if options.canSave then
		list[1] = {
			label = Ui.text('save_current'), value = 'save', icon = 'plus', description = Ui.text('save_desc'),
			disabled = #rows >= options.max, rightLabel = ('%d/%d'):format(#rows, options.max),
		}
	end
	for i, row in ipairs(rows) do
		list[#list + 1] = { label = row.name, value = i, icon = 'bag' }
	end
	if #rows == 0 then list[#list + 1] = { label = Ui.text('empty'), value = 'empty', disabled = true } end
	list[#list + 1] = { label = Ui.text('close'), value = 'close', icon = 'close' }
	return list
end

-- Only rows the server could have sent: integer id, short string name.
local function integer(value)
	return type(value) == 'number' and value == value and math.tointeger(value) or nil
end

local function cleanRows(list)
	local out = {}
	for _, row in ipairs(type(list) == 'table' and list or {}) do
		if type(row) == 'table' and integer(row.id) and type(row.name) == 'string' then
			out[#out + 1] = { id = integer(row.id), name = row.name:sub(1, 128) }
		end
	end
	return out
end

-- The server opened a session: { title?, canSave, canDelete, max, list }.
function Ui.open(data)
	if type(data) ~= 'table' then return end
	options = {
		canSave = data.canSave == true, canDelete = data.canDelete == true,
		max = integer(data.max) or 12,
	}
	rows = cleanRows(data.list)
	closing = false
	local menu, reason = Menu.open({
		id = 'opx_skin_outfits', title = type(data.title) == 'string' and data.title or Ui.text('title'),
		subtitle = Ui.text('subtitle'), elements = elements(),
		onSelect = function(element, menu)
			if element.value == 'save' then
				local name = askName(Ui.text('save_current'))
				if name then TriggerServerEvent('opx_skin:outfits:save', name) end
			elseif type(element.value) == 'number' and rows[element.value] then
				openOutfit(rows[element.value])
			elseif element.value == 'close' then
				menu:close()
			end
		end,
		onClose = function(menu)
			if main ~= menu then return end
			main = nil
			if not closing then TriggerServerEvent('opx_skin:outfits:closed') end
		end,
	})
	main = menu
	if not menu then
		print(('[opx_skin] outfits menu refused: %s'):format(tostring(reason)))
		TriggerServerEvent('opx_skin:outfits:closed')
	end
end

-- New list after a change: the open menu follows.
function Ui.setList(list)
	if not main or not main:isOpen() or not options then return end
	rows = cleanRows(list)
	main:setElements(elements(), true)
end

-- fromServer: the session already ended there.
function Ui.close(fromServer)
	closing = fromServer == true
	if main then main:close() end
	main = nil
end

OPX.OnPlayerUnloaded(function() Ui.close(false) end)

return Ui
