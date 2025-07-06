-------------- TYPES -----------------

---@class muffin.Node
---@field symbol lsp.DocumentSymbol
---@field parent muffin.Node?
---@field children muffin.Node[]
---@field id integer

---@enum extmark_type
local EXTMARK_TYPE = {
	symbol_source = 1,
	symbol_icon = 2,
}

---@class muffin.Extmark
---@field type extmark_type
---@field extmark_id integer
---@field buf_id integer

---@class muffin.Active
---@field win_id integer
---@field prev_win_id integer
---@field prev_cursor_pos integer[]
---@field tree muffin.Node[]
---@field node muffin.Node?
---@field restore_on_close boolean?
---@field extmarks muffin.Extmark[]
---@field autocmd_ids integer[]
---@field request_window_update boolean

---@class muffin.HighlightedText
---@field text string text to show
---@field highlight string highlight group name

---@alias muffin.SymbolIconProvider fun(kind: lsp.SymbolKind): muffin.HighlightedText?
---@alias muffin.FileIconProvider fun(path: string): muffin.HighlightedText?

---@class muffin.Config
---@field symbol_icon_provider muffin.SymbolIconProvider
---@field file_icon_provider muffin.FileIconProvider

--------------------------------------

---@param s string
---@return string
local function trim(s)
	return s:match("^%s*(.-)%s*$")
end

-- Returns Muffin namespace id
---@return integer id
local function namespace()
	return vim.api.nvim_create_namespace("Muffin")
end

---@return integer
local function new_buf()
	local buf_id = vim.api.nvim_create_buf(false, true)

	vim.api.nvim_buf_set_name(buf_id, "muffin://" .. buf_id)

	vim.bo[buf_id].filetype = "muffin"

	return buf_id
end

---@param buf_id integer
---@param title muffin.HighlightedText[]
---@param width integer
---@param height integer
---@return integer
local function new_win(buf_id, title, width, height)
	local title_segments = {}

	for _, segment in ipairs(title) do
		-- TODO: merge with FloatTitle
		table.insert(title_segments, { segment.text, segment.highlight })
	end

	local win_id = vim.api.nvim_open_win(buf_id, true, {
		title = title_segments,
		relative = "editor",
		style = "minimal",
		width = width,
		height = height,
		row = vim.o.lines - 1,
		col = vim.o.columns - 1,
	})

	vim.wo[win_id].foldenable = false
	vim.wo[win_id].foldmethod = "manual"
	vim.wo[win_id].list = true
	vim.wo[win_id].listchars = "extends:…"
	vim.wo[win_id].scrolloff = 0
	vim.wo[win_id].wrap = false
	vim.wo[win_id].cursorline = true

	return win_id
end

local function delete_autocmds()
	for _, id in ipairs(Muffin.active.autocmd_ids) do
		vim.api.nvim_del_autocmd(id)
	end

	Muffin.active.autocmd_ids = {}
end

local function setup_autocmds()
	local buf_id = vim.api.nvim_win_get_buf(Muffin.active.win_id)

	vim.keymap.set("n", "q", vim.cmd.quit, { buffer = buf_id })

	vim.keymap.set("n", "<cr>", function()
		Muffin.active.restore_on_close = false
		vim.cmd.quit()
	end, { buffer = buf_id })

	vim.keymap.set("n", "c", function()
		vim.api.nvim_buf_call(vim.api.nvim_win_get_buf(Muffin.active.prev_win_id), function()
			local range = Muffin.active.node.symbol.range

			local line_start = range.start.line + 1
			local line_end = range["end"].line + 1

			require("vim._comment").toggle_lines(line_start, line_end)
		end)
	end, { buffer = buf_id })

	vim.keymap.set("n", "h", function()
		local parent = Muffin.active.node.parent
		if not parent then
			return
		end

		Muffin.active.node = parent
		Muffin.active.request_window_update = true

		Muffin.sync()
	end, { buffer = buf_id })

	vim.keymap.set("n", "l", function()
		local children = Muffin.active.node.children
		if #children == 0 then
			return
		end

		Muffin.active.node = children[1]
		Muffin.active.request_window_update = true

		Muffin.sync()
	end, { buffer = buf_id })

	local cursor_moved_autocmd_id = vim.api.nvim_create_autocmd("CursorMoved", {
		buffer = buf_id,
		callback = function()
			local cursor = vim.api.nvim_win_get_cursor(0)
			local row = cursor[1]

			local node = Muffin.active_current_nodes()[row]

			Muffin.active.node = node

			Muffin.sync()
		end,
	})

	local buf_leave_autocmd_id = vim.api.nvim_create_autocmd("BufLeave", {
		buffer = buf_id,
		callback = function()
			Muffin.close()
		end,
	})

	for _, id in ipairs({ cursor_moved_autocmd_id, buf_leave_autocmd_id }) do
		table.insert(Muffin.active.autocmd_ids, id)
	end
end

---@param range lsp.Range
---@param pos lsp.Position
---@return boolean
local function range_contains_pos(range, pos)
	local r_start = range.start
	local r_end = range["end"]

	-- pos line out of range
	if not (r_start.line <= pos.line and pos.line <= r_start.line) then
		return false
	end

	-- same line for start and end
	if r_start.line == r_end.line then
		return r_start.character <= pos.character and pos.character <= r_end.character
	end

	-- pos on start line
	if r_start.line == pos.line then
		return r_start.character <= pos.character
	end

	-- pos on end line
	if r_end.line == pos.line then
		return pos.character <= r_end.character
	end

	return true
end

---@param pos lsp.Position
---@param range lsp.Range
---@return integer
local function pos_distance_to_range(pos, range)
	---@param p lsp.Position
	---@return integer
	local function pack(p)
		local n = tonumber(p.line .. p.character)

		assert(type(n) == "number")

		return n
	end

	if range_contains_pos(range, pos) then
		return 0
	end

	local n = pack(pos)

	local to_start = math.abs(n - pack(range.start))
	local to_end = math.abs(n - pack(range["end"]))

	return math.min(to_start, to_end)
end

--- Convert document symbols into hierarchy tree
---@param document_symbols lsp.DocumentSymbol[]
---@param parent muffin.Node?
---@return muffin.Node[] Tree
local function build_tree(document_symbols, parent)
	local nodes = {}

	for i, symbol in ipairs(document_symbols) do
		---@type muffin.Node
		local node = {
			symbol = symbol,
			id = i,
			parent = parent,
			children = {},
		}

		node.children = build_tree(symbol.children or {}, node)

		table.insert(nodes, node)
	end

	return nodes
end

---@param pos lsp.Position
---@param tree muffin.Node[]
---@return {node: muffin.Node, distance: integer}?
local function get_closest_node_raw(pos, tree)
	---@alias res {node: muffin.Node, distance: integer}

	---@param a res
	---@param b res
	---@return res
	local function min(a, b)
		return a.distance < b.distance and a or b
	end

	if #tree == 0 then
		return nil
	end

	---@type res
	local min_res = { node = tree[1], distance = math.huge }

	for _, node in ipairs(tree) do
		---@type res
		local res = { node = node, distance = pos_distance_to_range(pos, node.symbol.range) }
		local res_inner = get_closest_node_raw(pos, node.children)

		min_res = min(min_res, res)

		if res_inner then
			min_res = min(min_res, res_inner)
		end
	end

	return min_res
end

---@param pos lsp.Position
---@param tree muffin.Node[]
---@return muffin.Node?
local function get_closest_node(pos, tree)
	local res = get_closest_node_raw(pos, tree)

	return res and res.node or nil
end

local M = {}

---@return muffin.SymbolIconProvider
local function create_icon_provider()
	if not MiniIcons then
		return function()
			return nil
		end
	end

	local symbol_kinds = {
		File = 1,
		Module = 2,
		Namespace = 3,
		Package = 4,
		Class = 5,
		Method = 6,
		Property = 7,
		Field = 8,
		Constructor = 9,
		Enum = 10,
		Interface = 11,
		Function = 12,
		Variable = 13,
		Constant = 14,
		String = 15,
		Number = 16,
		Boolean = 17,
		Array = 18,
		Object = 19,
		Key = 20,
		Null = 21,
		EnumMember = 22,
		Struct = 23,
		Event = 24,
		Operator = 25,
		TypeParameter = 26,
	}

	---@type table<lsp.SymbolKind, muffin.HighlightedText>
	local map = {}

	for name, id in pairs(symbol_kinds) do
		local icon, hl = MiniIcons.get("lsp", name)

		map[id] = { text = icon, highlight = hl }
	end

	return function(kind)
		return map[kind]
	end
end

---@return muffin.HighlightedText[]
local function new_active_window_title()
	local parent = (Muffin.active.node or {}).parent

	if parent then
		local title = parent.symbol.name
		local highlight = ""

		local icon = Muffin.config.symbol_icon_provider(parent.symbol.kind)

		if icon then
			title = icon.text .. " " .. title
			highlight = icon.highlight
		end

		return { { text = trim(title), highlight = highlight } }
	end

	local buf_id = vim.api.nvim_win_get_buf(Muffin.active.prev_win_id)
	local buf_name = vim.api.nvim_buf_get_name(buf_id)

	---@type muffin.HighlightedText[]
	local segments = {}

	local icon = Muffin.config.file_icon_provider(buf_name)
	if icon then
		table.insert(segments, icon)
		table.insert(segments, { text = " ", highlight = "" })
	end

	table.insert(segments, { text = vim.fs.basename(buf_name), highlight = "" })

	return segments
end

---@param filter extmark_type?
local function delete_extmarks(filter)
	for _, extmark in ipairs(Muffin.active.extmarks) do
		local matches = not filter or filter == extmark.type

		if matches then
			vim.api.nvim_buf_del_extmark(extmark.buf_id, namespace(), extmark.extmark_id)
		end
	end
end

---@type muffin.Config
local DEFAULT_CONFIG = {
	symbol_icon_provider = create_icon_provider(),
	file_icon_provider = function(path)
		if not MiniIcons then
			return nil
		end

		local icon, hl = MiniIcons.get("file", path)

		---@type muffin.HighlightedText
		return { text = icon, highlight = hl }
	end,
}

Muffin = {
	---@type muffin.Active?
	active = nil,

	---@type muffin.Config
	config = DEFAULT_CONFIG,
}

---@param config? muffin.Config
function M.setup(config)
	Muffin.config = vim.tbl_extend("force", DEFAULT_CONFIG, config)
end

---@return boolean
function Muffin.is_active()
	return Muffin.active ~= nil
end

---@return muffin.Node[]
function Muffin.active_current_nodes()
	return ((Muffin.active.node or {}).parent or {}).children or Muffin.active.tree
end

--- Open popup
function Muffin.open()
	if Muffin.is_active() then
		return
	end

	local prev_win_id = vim.api.nvim_get_current_win()
	local prev_cursor_pos = vim.api.nvim_win_get_cursor(0)

	local responses, err = vim.lsp.buf_request_sync(0, vim.lsp.protocol.Methods.textDocument_documentSymbol, {
		textDocument = vim.lsp.util.make_text_document_params(),
	})

	if err then
		return
	end

	if not responses then
		return
	end

	---@type lsp.DocumentSymbol[]
	local symbols = {}

	for _, resp in pairs(responses) do
		for _, sym in ipairs(resp.result) do
			table.insert(symbols, sym)
		end
	end

	local tree = build_tree(symbols)

	local position = vim.lsp.util.make_position_params(0, "utf-8").position

	Muffin.active = {
		win_id = -1,
		prev_win_id = prev_win_id,
		prev_cursor_pos = prev_cursor_pos,
		tree = tree,
		node = get_closest_node(position, tree),
		restore_on_close = true,
		autocmd_ids = {},
		request_window_update = true,
		extmarks = {},
	}

	Muffin.sync()
end

---@param node muffin.Node
---@return muffin.HighlightedText
local function display_node(node)
	local text = node.symbol.name

	local icon = Muffin.config.symbol_icon_provider(node.symbol.kind)

	local highlight = ""

	if icon then
		text = icon.text .. " " .. text
		highlight = icon.highlight
	end

	if #node.children > 0 then
		text = text .. " .."
	end

	local text = " " .. trim(text) .. " "

	return { text = text, highlight = highlight }
end

function Muffin.sync()
	local lines = {}
	local highlights = {}

	local active_current_nodes = Muffin.active_current_nodes()

	local win_width = 0
	local win_height = #active_current_nodes

	for _, node in ipairs(active_current_nodes) do
		local display = display_node(node)

		local width = vim.api.nvim_strwidth(display.text)

		win_width = math.max(win_width, width)

		table.insert(lines, display.text)
		table.insert(highlights, display.highlight)
	end

	if Muffin.active.request_window_update then
		Muffin.active.request_window_update = false

		if Muffin.active.win_id >= 0 then
			delete_autocmds()

			vim.api.nvim_win_close(Muffin.active.win_id, true)
		end

		local buf_id = new_buf()
		local title = new_active_window_title()

		do
			local sum = 0

			for _, segment in ipairs(title) do
				sum = sum + vim.api.nvim_strwidth(segment.text)
			end

			win_width = math.max(win_width, sum)
		end

		local win_id = new_win(buf_id, title, win_width, win_height)

		Muffin.active.win_id = win_id

		setup_autocmds()

		vim.bo[buf_id].modifiable = true
		vim.api.nvim_buf_set_lines(buf_id, 0, -1, false, lines)
		vim.bo[buf_id].modifiable = false

		delete_extmarks(EXTMARK_TYPE.symbol_icon)

		for i, highlight in ipairs(highlights) do
			local id = vim.api.nvim_buf_set_extmark(
				buf_id,
				namespace(),
				i - 1,
				0,
				{ end_row = i - 1, end_col = 4, hl_group = highlight }
			)

			---@type muffin.Extmark
			local extmark = {
				extmark_id = id,
				buf_id = buf_id,
				type = EXTMARK_TYPE.symbol_icon,
			}

			table.insert(Muffin.active.extmarks, extmark)
		end
	end

	local win_id = Muffin.active.win_id

	delete_extmarks(EXTMARK_TYPE.symbol_source)

	if Muffin.active.node then
		vim.api.nvim_win_set_cursor(win_id, { Muffin.active.node.id, 0 })

		local range = Muffin.active.node.symbol.range

		local start_row = range.start.line
		local start_col = range.start.character

		local end_row = range["end"].line
		local end_col = range["end"].character

		vim.api.nvim_win_set_cursor(Muffin.active.prev_win_id, { start_row + 1, start_col })

		local extmark_buf_id = vim.api.nvim_win_get_buf(Muffin.active.prev_win_id)
		local extmark_id = vim.api.nvim_buf_set_extmark(
			extmark_buf_id,
			namespace(),
			start_row,
			start_col,
			{ end_row = end_row, end_col = end_col, hl_group = "Visual" }
		)

		---@type muffin.Extmark
		local extmark = {
			extmark_id = extmark_id,
			buf_id = extmark_buf_id,
			type = EXTMARK_TYPE.symbol_source,
		}

		table.insert(Muffin.active.extmarks, extmark)
	end
end

--- Close popup
---@return boolean
function Muffin.close()
	if not Muffin.is_active() then
		return false
	end

	delete_autocmds()
	delete_extmarks()

	vim.api.nvim_win_close(Muffin.active.win_id, true)

	if Muffin.active.restore_on_close then
		vim.api.nvim_win_set_cursor(Muffin.active.prev_win_id, Muffin.active.prev_cursor_pos)
	end

	Muffin.active = nil

	return true
end

--- Toggle popup
function Muffin.toggle()
	if not Muffin.close() then
		Muffin.open()
	end
end

return M
