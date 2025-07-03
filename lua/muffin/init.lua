local H = {}

---@return integer
function H.new_buf()
	local buf_id = vim.api.nvim_create_buf(false, true)

	vim.api.nvim_buf_set_name(buf_id, "muffin://" .. buf_id)

	vim.bo[buf_id].filetype = "muffin"

	return buf_id
end

---@param buf_id integer
---@return integer
function H.new_win(buf_id)
	local lines = vim.o.lines
	local columns = vim.o.columns

	local width = math.floor(columns * 0.3)
	local height = math.floor(lines * 0.75)

	local win_id = vim.api.nvim_open_win(buf_id, true, {
		title = "Muffin",
		relative = "editor",
		style = "minimal",
		width = width,
		height = height,
		row = lines - 1,
		col = columns - 1,
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

local function setup_autocmds(buf_id)
	vim.keymap.set("n", "q", vim.cmd.quit, { buffer = buf_id })

	vim.keymap.set("n", "h", function()
		local parent = Muffin.active.node.parent
		if not parent then
			return
		end

		Muffin.active.node = parent
		Muffin.sync()
	end, { buffer = buf_id })

	vim.keymap.set("n", "l", function()
		local children = Muffin.active.node.children
		if #children == 0 then
			return
		end

		Muffin.active.node = children[1]
		Muffin.sync()
	end, { buffer = buf_id })

	vim.api.nvim_create_autocmd("CursorMoved", {
		buffer = buf_id,
		callback = function()
			local cursor = vim.api.nvim_win_get_cursor(0)
			local row = cursor[1]

			local node = Muffin.active_current_nodes()[row]

			Muffin.active.node = node

			Muffin.sync()
		end,
	})

	vim.api.nvim_create_autocmd("BufLeave", {
		buffer = buf_id,
		callback = function()
			Muffin.close()
		end,
	})
end

---@class muffin.Node
---@field symbol lsp.DocumentSymbol
---@field parent muffin.Node?
---@field children muffin.Node[]
---@field id integer

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

--- Get tree node under cursor
---@param pos lsp.Position
---@param tree muffin.Node[]
---@return muffin.Node?
local function get_node_for_pos(pos, tree)
	for _, node in ipairs(tree) do
		if node_contains_pos(node, pos) then
			return get_node_for_pos(pos, node.children) or node
		end
	end

	return nil
end

local M = {}

---@class muffin.Active
---@field win_id integer
---@field prev_win_id integer
---@field prev_cursor_pos integer[]
---@field tree muffin.Node[]
---@field node muffin.Node?

Muffin = {
	---@type muffin.Active?
	active = nil,
}

local default_config = {}

---@param config? table
function M.setup(config)
	config = vim.tbl_extend("force", default_config, config or {})
end

---@return boolean
function Muffin.is_active()
	return Muffin.active ~= nil
end

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
	local node_under_cursor = get_node_for_pos(position, tree)

	local buf_id = H.new_buf()
	local win_id = H.new_win(buf_id)

	setup_autocmds(buf_id)

	Muffin.active = {
		win_id = win_id,
		prev_win_id = prev_win_id,
		prev_cursor_pos = prev_cursor_pos,
		tree = tree,
		node = node_under_cursor,
	}

	Muffin.sync()
end

function Muffin.sync()
	local win_id = Muffin.active.win_id
	local buf_id = vim.api.nvim_win_get_buf(win_id)

	local replacement = {}

	for _, item in ipairs(Muffin.active_current_nodes()) do
		table.insert(replacement, item.symbol.name)
	end

	vim.bo[buf_id].modifiable = true

	vim.api.nvim_buf_set_lines(buf_id, 0, -1, false, replacement)

	if Muffin.active.node then
		vim.api.nvim_win_set_cursor(win_id, { Muffin.active.node.id, 0 })

		local start_pos = Muffin.active.node.symbol.range.start

		vim.api.nvim_win_set_cursor(Muffin.active.prev_win_id, { start_pos.line + 1, start_pos.character })
	end

	vim.bo[buf_id].modifiable = false
end

--- Close popup
---@return boolean
function Muffin.close()
	if not Muffin.is_active() then
		return false
	end

	vim.api.nvim_win_close(Muffin.active.win_id, true)
	vim.api.nvim_win_set_cursor(Muffin.active.prev_win_id, Muffin.active.prev_cursor_pos)

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
