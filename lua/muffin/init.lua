-------------- TYPES -----------------

---@class muffin.Node
---@field symbol lsp.DocumentSymbol
---@field parent muffin.Node?
---@field children muffin.Node[]
---@field id integer

---@class muffin.Active
---@field win_id integer
---@field prev_win_id integer
---@field prev_cursor_pos integer[]
---@field tree muffin.Node[]
---@field node muffin.Node?
---@field restore_on_close boolean?
---@field namespace_id integer
---@field extmark_id integer?
---@field autocmd_ids integer[]
---@field request_window_update boolean

---@class muffin.Config
---@field symbol_icon_provider fun(kind: lsp.SymbolKind): string
---@field file_icon_provider fun(path: string): string

--------------------------------------

---@param s string
---@return string
local function trim(s)
	return s:match("^%s*(.-)%s*$")
end

---@return integer
local function new_buf()
	local buf_id = vim.api.nvim_create_buf(false, true)

	vim.api.nvim_buf_set_name(buf_id, "muffin://" .. buf_id)

	vim.bo[buf_id].filetype = "muffin"

	return buf_id
end

---@param buf_id integer
---@param title string
---@param width integer
---@param height integer
---@return integer
local function new_win(buf_id, title, width, height)
	local win_id = vim.api.nvim_open_win(buf_id, true, {
		title = title,
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

local function setup_autocmds()
	local buf_id = vim.api.nvim_win_get_buf(Muffin.active.win_id)

	vim.keymap.set("n", "q", vim.cmd.quit, { buffer = buf_id })

	vim.keymap.set("n", "<cr>", function()
		Muffin.active.restore_on_close = false
		vim.cmd.quit()
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

---@param node muffin.Node
---@param pos lsp.Position
---@return boolean
local function node_contains_pos(node, pos)
	local range = node.symbol.range

	return range.start.line <= pos.line and range["end"].line >= pos.line
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
---@return muffin.Node?
local function get_current_node(pos, tree)
	for _, node in ipairs(tree) do
		if node_contains_pos(node, pos) then
			return get_current_node(pos, node.children) or node
		end
	end

	return nil
end

---@param pos lsp.Position
---@param tree muffin.Node[]
---@return {node: muffin.Node, distance: integer}?
local function get_closest_node(pos, tree)
	local min_distance = 999999

	---@type muffin.Node?
	local closest_node = nil

	for _, node in ipairs(tree) do
		local range = node.symbol.range

		local distance = math.min(math.abs(range["end"].line - pos.line), math.abs(range.start.line - pos.line))

		local inner = get_closest_node(pos, node.children)

		if inner and inner.distance <= distance then
			distance = inner.distance
			node = inner.node
		end

		if distance <= min_distance then
			min_distance = distance
			closest_node = node
		end
	end

	return { node = closest_node, distance = min_distance }
end

--- Get tree node under cursor
---@param pos lsp.Position
---@param tree muffin.Node[]
---@return muffin.Node?
local function get_node_for_pos(pos, tree)
	return get_current_node(pos, tree) or get_closest_node(pos, tree).node
end

local M = {}

---@return fun(kind: lsp.SymbolKind): string icon_provider
local function create_icon_provider()
	if not MiniIcons then
		return function()
			return ""
		end
	end

	---@type table<lsp.SymbolKind, string>
	local cache = {}

	return function(kind)
		local icon = cache[kind]

		if icon ~= nil then
			return icon
		end

		for kind_name, kind_id in pairs(vim.lsp.protocol.SymbolKind) do
			if kind_id == kind then
				icon = MiniIcons.get("lsp", kind_name)

				cache[kind] = icon

				return icon
			end
		end

		icon = MiniIcons.get("lsp", "")

		cache[kind] = icon

		return icon
	end
end

---@type muffin.Config
local DEFAULT_CONFIG = {
	symbol_icon_provider = create_icon_provider(),
	file_icon_provider = function(path)
		if not MiniIcons then
			return ""
		end

		local icon = MiniIcons.get("file", path)

		return icon
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

function Muffin.active_current_nodes()
	return ((Muffin.active.node or {}).parent or {}).children or Muffin.active.tree
end

---@return string
local function new_active_window_title()
	local parent = (Muffin.active.node or {}).parent

	if parent then
		local icon = Muffin.config.symbol_icon_provider(parent.symbol.kind)
		local title = icon .. " " .. parent.symbol.name

		return trim(title)
	end

	local buf_id = vim.api.nvim_win_get_buf(Muffin.active.prev_win_id)
	local buf_name = vim.api.nvim_buf_get_name(buf_id)

	local icon = Muffin.config.file_icon_provider(buf_name)

	return trim(icon .. " " .. vim.fs.basename(buf_name))
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
	local node_under_cursor = get_node_for_pos(position, tree)

	Muffin.active = {
		win_id = -1,
		prev_win_id = prev_win_id,
		prev_cursor_pos = prev_cursor_pos,
		tree = tree,
		node = node_under_cursor,
		restore_on_close = true,
		namespace_id = vim.api.nvim_create_namespace("Muffin"),
		autocmd_ids = {},
		request_window_update = true,
	}

	Muffin.sync()
end

---@param node muffin.Node
---@return string
local function display_node(node)
	local icon = Muffin.config.symbol_icon_provider(node.symbol.kind)
	local display = string.format("%s %s", icon, node.symbol.name)

	if #node.children > 0 then
		display = display .. " .."
	end

	return " " .. trim(display) .. " "
end

function Muffin.sync()
	local replacement = {}
	local active_current_nodes = Muffin.active_current_nodes()

	local win_width = 0
	local win_height = #active_current_nodes

	for _, node in ipairs(active_current_nodes) do
		local display = display_node(node)

		local width = vim.api.nvim_strwidth(display)

		win_width = math.max(win_width, width)

		table.insert(replacement, display)
	end

	if Muffin.active.request_window_update then
		Muffin.active.request_window_update = false

		if Muffin.active.win_id >= 0 then
			for _, id in ipairs(Muffin.active.autocmd_ids) do
				vim.api.nvim_del_autocmd(id)
			end

			Muffin.active.autocmd_ids = {}

			vim.api.nvim_win_close(Muffin.active.win_id, true)
		end

		local buf_id = new_buf()
		local title = new_active_window_title()

		win_width = math.max(win_width, vim.api.nvim_strwidth(title))

		local win_id = new_win(buf_id, title, win_width, win_height)

		Muffin.active.win_id = win_id

		setup_autocmds()
	end

	local win_id = Muffin.active.win_id
	local buf_id = vim.api.nvim_win_get_buf(win_id)

	vim.bo[buf_id].modifiable = true

	vim.api.nvim_buf_set_lines(buf_id, 0, -1, false, replacement)

	if Muffin.active.extmark_id then
		vim.api.nvim_buf_del_extmark(
			vim.api.nvim_win_get_buf(Muffin.active.prev_win_id),
			Muffin.active.namespace_id,
			Muffin.active.extmark_id
		)
	end

	if Muffin.active.node then
		vim.api.nvim_win_set_cursor(win_id, { Muffin.active.node.id, 0 })

		local range = Muffin.active.node.symbol.range

		local start_row = range.start.line + 1
		local start_col = range.start.character

		local end_row = range["end"].line + 1
		local end_col = range["end"].character

		vim.api.nvim_win_set_cursor(Muffin.active.prev_win_id, { start_row, start_col })
		Muffin.active.extmark_id = vim.api.nvim_buf_set_extmark(
			vim.api.nvim_win_get_buf(Muffin.active.prev_win_id),
			Muffin.active.namespace_id,
			start_row - 1,
			start_col,
			{ end_row = end_row - 1, end_col = end_col, hl_group = "Visual" }
		)
	end

	vim.bo[buf_id].modifiable = false
end

--- Close popup
---@return boolean
function Muffin.close()
	if not Muffin.is_active() then
		return false
	end

	for _, id in ipairs(Muffin.active.autocmd_ids) do
		vim.api.nvim_del_autocmd(id)
	end

	vim.api.nvim_win_close(Muffin.active.win_id, true)

	if Muffin.active.restore_on_close then
		vim.api.nvim_win_set_cursor(Muffin.active.prev_win_id, Muffin.active.prev_cursor_pos)
	end

	vim.api.nvim_buf_del_extmark(
		vim.api.nvim_win_get_buf(Muffin.active.prev_win_id),
		Muffin.active.namespace_id,
		Muffin.active.extmark_id
	)

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
