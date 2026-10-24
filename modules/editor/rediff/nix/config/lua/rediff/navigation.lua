local M = {}
local api = vim.api
local review = require("rediff.review")
local git = require("rediff.git")
local definition_generation = 0
local automatic_preview = false
local last_automatic_position
local preview_win
local context_path

local function tree_path(win, row)
	local s = review.active()
	if s and win == s.tree_win then
		local entry = s.entries[s.rows[row]]
		if entry then
			return entry.path, vim.fs.joinpath(s.root, entry.path)
		end
	elseif vim.bo[api.nvim_win_get_buf(win)].filetype == "neo-tree" then
		local tree = require("neo-tree.sources.manager").get_state_for_window(win)
		local node = tree and tree.tree and tree.tree:get_node(row)
		if node and (node.type == "file" or node.type == "directory" or node.type == "link") then
			local root, code = git.run(tree.path, { "rev-parse", "--show-toplevel" }, nil, true)
			root = code == 0 and vim.trim(root) or tree.path
			return vim.fs.relpath(root, node.path), node.path
		end
	end
end

function M.tree_menu()
	context_path = nil
	pcall(vim.cmd, [[nunmenu PopUp.Copy\ Relative\ Path]])
	local mouse = vim.fn.getmousepos()
	if mouse.winid == 0 or mouse.line == 0 then
		return
	end
	context_path = tree_path(mouse.winid, mouse.line)
	if context_path then
		vim.cmd(
			[[nnoremenu <silent> 1.10 PopUp.Copy\ Relative\ Path <Cmd>lua require('rediff.navigation').copy_tree_path()<CR>]]
		)
	end
end

function M.copy_tree_path()
	if context_path then
		vim.fn.setreg("+", context_path, "v")
	end
end

function M.copy_path(absolute)
	local win = api.nvim_get_current_win()
	local relative, full = tree_path(win, api.nvim_win_get_cursor(win)[1])
	local s = review.active()
	if s and s.current and (win == s.old_win or win == s.new_win) then
		relative = s.current.path
		full = vim.fs.joinpath(s.root, relative)
	end
	local path = absolute and full or relative
	if path then
		vim.fn.setreg("+", path, "v")
	end
end

function M.close_definition_preview()
	definition_generation = definition_generation + 1
	if preview_win and api.nvim_win_is_valid(preview_win) then
		api.nvim_win_close(preview_win, true)
	end
	preview_win = nil
end

local function preview_definition(items)
	local item = items[1]
	local shown = { item }
	for _, candidate in ipairs(items) do
		if candidate.kind == "Type" and item.kind ~= "Type" then
			table.insert(shown, candidate)
			break
		end
	end
	local height = math.min(18, math.floor(vim.o.lines * 0.45))
	local count = #shown == 1 and height or math.max(1, math.floor((height - 3) / 2))
	local lines, syntax = {}, nil
	for index, location in ipairs(shown) do
		local target = vim.fn.bufadd(location.filename)
		vim.fn.bufload(target)
		syntax = syntax or vim.bo[target].filetype
		if #shown > 1 then
			if index > 1 then
				table.insert(lines, "")
			end
			table.insert(
				lines,
				location.kind .. " · " .. vim.fn.fnamemodify(location.filename, ":t") .. ":" .. location.lnum
			)
		end
		vim.list_extend(lines, api.nvim_buf_get_lines(target, location.lnum - 1, location.lnum - 1 + count, false))
	end
	local _, win = vim.lsp.util.open_floating_preview(lines, syntax, {
		border = "single",
		title = " Symbol · " .. vim.fn.fnamemodify(item.filename, ":t") .. ":" .. item.lnum .. " · Space l: expand ",
		focusable = false,
		max_width = math.min(88, math.floor(vim.o.columns * 0.8)),
		max_height = height,
		close_events = { "CursorMoved", "CursorMovedI", "InsertEnter", "BufLeave", "TextChanged" },
	})
	preview_win = win
end

local function browse_definitions(items, source)
	local actions = require("telescope.actions")
	local config = require("telescope.config").values
	local opts = {
		prompt_title = "Symbol definitions · current worktree",
		results_title = "Read-only · j/k: select · Ctrl-d/u: scroll · Esc: close",
		initial_mode = "normal",
		sorting_strategy = "ascending",
		layout_strategy = "flex",
		layout_config = {
			width = 0.9,
			height = 0.8,
			prompt_position = "top",
			flip_columns = 120,
			flip_lines = 0,
			vertical = { preview_cutoff = 0 },
		},
		preview_title = "Source",
		previewer = config.qflist_previewer({
			preview = {
				filetype_hook = function(_, _, opts)
					if api.nvim_win_is_valid(opts.winid) then
						vim.wo[opts.winid].wrap = true
					end
					return true
				end,
			},
		}),
		sorter = config.generic_sorter({}),
		attach_mappings = function()
			-- Selection only changes the preview; never replace a source/review pane.
			for _, action in ipairs({
				"select_default",
				"select_horizontal",
				"select_vertical",
				"select_tab",
				"send_to_qflist",
				"send_selected_to_qflist",
				"open_qflist",
			}) do
				actions[action]:replace(function() end)
			end
			return true
		end,
	}
	if source then
		opts.bufnr = source
		return require("telescope.builtin").lsp_dynamic_workspace_symbols(opts)
	end
	opts.finder = require("telescope.finders").new_table({
		results = items,
		entry_maker = require("telescope.make_entry").gen_from_quickfix({}),
	})
	require("telescope.pickers").new({}, opts):find()
end

function M.definition(peek, automatic, method)
	peek = peek or "preview"
	M.close_definition_preview()
	local s = review.active()
	local win, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
	local snapshot = s and (buf == s.old_buf or buf == s.new_buf) and s.current or nil
	assert(snapshot or vim.bo[buf].buftype == "", "Select a symbol in a source buffer")
	local cursor = api.nvim_win_get_cursor(win)
	local source, offset = buf, 0
	if snapshot then
		local path = s.root .. "/" .. snapshot.path
		assert(vim.fn.filereadable(path) == 1, "This source file no longer exists in the worktree")
		-- LSP needs a real URI, not review://. Leave both diff panes intact.
		source = vim.fn.bufadd(path)
		vim.fn.bufload(source)
		api.nvim_buf_call(source, function()
			vim.cmd("checktime")
		end)
		local old = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n") .. "\n"
		local new = table.concat(api.nvim_buf_get_lines(source, 0, -1, false), "\n") .. "\n"
		for _, hunk in ipairs(vim.diff(old, new, { result_type = "indices" })) do
			local first, count, _, added = unpack(hunk)
			if count == 0 then
				if first >= cursor[1] then
					break
				end
			elseif first > cursor[1] then
				break
			else
				assert(
					cursor[1] >= first + count,
					"This line changed in the source file; refresh Review or open the current file"
				)
			end
			offset = offset + added - count
		end
	end
	local tick = api.nvim_buf_get_changedtick(source)
	definition_generation = definition_generation + 1
	local generation = definition_generation
	local function current()
		return generation == definition_generation
			and review.active() == s
			and (not snapshot or s.current == snapshot)
			and api.nvim_get_current_win() == win
			and api.nvim_win_get_buf(win) == buf
			and vim.deep_equal(api.nvim_win_get_cursor(win), cursor)
			and api.nvim_buf_is_valid(source)
			and api.nvim_buf_get_changedtick(source) == tick
			and vim.api.nvim_get_mode().mode == "n"
	end
	local methods = method and { method }
		or { "textDocument/definition", "textDocument/typeDefinition", "textDocument/hover" }
	local function supported_methods()
		return vim.tbl_filter(function(method)
			return #vim.lsp.get_clients({ bufnr = source, method = method }) > 0
		end, methods)
	end
	local function request()
		if method == "workspace/symbol" then
			return browse_definitions(nil, source)
		end
		-- The pinned Neovim requests definitions from the current buffer/cursor.
		api.nvim_buf_call(source, function()
			local view = vim.fn.winsaveview()
			api.nvim_win_set_cursor(0, { cursor[1] + offset, cursor[2] })
			-- Query together: variables can have both a declaration and a type's source.
			-- Capture each client's position now, before restoring the source window.
			local pending, responses = #supported_methods(), {}
			local function finish()
				vim.schedule(function()
					if not current() then
						return
					end
					local items, seen, hover = {}, {}, {}
					for _, method in ipairs(methods) do
						for id, response in pairs(responses[method] or {}) do
							local client = vim.lsp.get_client_by_id(id)
							if client and response.result and not response.err then
								if method == "textDocument/hover" then
									vim.list_extend(
										hover,
										vim.lsp.util.convert_input_to_markdown_lines(response.result.contents)
									)
								else
									local locations = response.result.uri and { response.result } or response.result
									local symbols = method == "textDocument/documentSymbol"
									local entries = symbols
											and vim.lsp.util.symbols_to_items(
												response.result,
												source,
												client.offset_encoding
											)
										or vim.lsp.util.locations_to_items(locations, client.offset_encoding)
									for _, item in ipairs(entries) do
										local key = item.filename .. ":" .. item.lnum .. ":" .. item.col
										if not seen[key] then
											seen[key] = true
											item.kind = method == "textDocument/typeDefinition" and "Type"
												or "Definition"
											table.insert(items, item)
										end
									end
								end
							end
						end
					end
					if #items > 0 then
						if peek == "preview" then
							preview_definition(items)
						else
							browse_definitions(items)
						end
					elseif #hover > 0 then
						local _, float = vim.lsp.util.open_floating_preview(hover, "markdown", {
							border = "single",
							title = " Symbol information ",
							focusable = false,
							max_width = math.min(88, math.floor(vim.o.columns * 0.8)),
							max_height = math.min(18, math.floor(vim.o.lines * 0.45)),
							close_events = {
								"CursorMoved",
								"CursorMovedI",
								"InsertEnter",
								"BufLeave",
								"TextChanged",
							},
						})
						preview_win = float
					elseif not automatic then
						vim.notify("No symbol information found", vim.log.levels.INFO)
					end
				end)
			end
			for _, method in ipairs(supported_methods()) do
				vim.lsp.buf_request_all(source, method, function(client)
					local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
					if method == "textDocument/references" then
						params.context = { includeDeclaration = true }
					end
					return params
				end, function(results)
					responses[method] = results
					pending = pending - 1
					if pending == 0 then
						finish()
					end
				end)
			end
			vim.fn.winrestview(view)
		end)
	end
	if #supported_methods() > 0 then
		return request()
	end
	-- First lookup may have to wait for the server's asynchronous initialization.
	local waiting = true
	local attach = api.nvim_create_autocmd("LspAttach", {
		buffer = source,
		callback = function()
			vim.schedule(function()
				if waiting and current() and #supported_methods() > 0 then
					waiting = false
					request()
				end
			end)
		end,
	})
	api.nvim_exec_autocmds("FileType", { buffer = source })
	if not automatic then
		vim.notify("Starting definition lookup; waiting for the language server…")
	end
	vim.defer_fn(function()
		pcall(api.nvim_del_autocmd, attach)
		if waiting and current() and not automatic then
			vim.notify(
				"No compatible language server attached. See :checkhealth vim.lsp and try again.",
				vim.log.levels.WARN
			)
		end
		waiting = false
	end, 15000)
end

function M.setup_definitions()
	local function peek()
		local expand = preview_win and api.nvim_win_is_valid(preview_win)
		local ok, err = pcall(M.definition, expand and true or "preview")
		if not ok then
			vim.notify(tostring(err), vim.log.levels.WARN)
		end
	end
	local function inspect(method)
		return function()
			local ok, err = pcall(M.definition, true, false, method)
			if not ok then
				vim.notify(tostring(err), vim.log.levels.WARN)
			end
		end
	end
	local bindings = {
		{ "<leader>l", "Peek symbol and type; repeat to expand", peek },
		{ "<leader>t", "Toggle automatic symbol previews", "<Cmd>DefinitionPreviewAutoToggle<CR>" },
		{ "gd", "Peek definition (never jump)", peek },
		{ "<M-CR>", "Peek definition (Option+Enter)", peek },
		{ "<C-]>", "Peek definition (never jump)", peek },
		{ "grt", "Peek symbol and type", peek },
		{ "grr", "Browse references", inspect("textDocument/references") },
		{ "gri", "Browse implementations", inspect("textDocument/implementation") },
		{ "gO", "Browse file symbols", inspect("textDocument/documentSymbol") },
		{ "<leader>s", "Browse file symbols", inspect("textDocument/documentSymbol") },
		{ "<leader>S", "Browse workspace symbols", inspect("workspace/symbol") },
	}
	for _, binding in ipairs(bindings) do
		vim.keymap.set("n", binding[1], binding[3], { desc = binding[2] })
	end
	api.nvim_create_user_command("Symbols", inspect("textDocument/documentSymbol"), {})
	api.nvim_create_user_command("WorkspaceSymbols", inspect("workspace/symbol"), {})
	api.nvim_create_user_command("Lsp", function(opts)
		assert(opts.args == "help", "Usage: :lsp help")
		M.close_definition_preview()
		local lines = {
			"LSP · Editing and Review",
			"",
			"Automatic display: " .. (automatic_preview and "ON" or "OFF") .. " (session only)",
			"Space t toggles automatic symbol previews on/off.",
			"Pause the text cursor on a symbol to preview it (not mouse hover).",
			":DefinitionPreviewAutoToggle   Toggle on/off",
			":DefinitionPreviewAutoEnable   Turn on",
			":DefinitionPreviewAutoDisable  Turn off",
			"Or: Space p, then search for DefinitionPreviewAutoToggle.",
			"",
			"Read-only inspection of current source; Review panes stay intact.",
			"",
		}
		for _, binding in ipairs(bindings) do
			table.insert(lines, string.format("%-14s %s", binding[1]:gsub("<leader>", "Space "), binding[2]))
		end
		vim.list_extend(lines, {
			"",
			"Browser: j/k select · i search · Ctrl-d/u scroll · Esc close",
			"Enter / split / tab actions never open a source file.",
			"K and gT disabled; gk retains its normal screen-line movement.",
			"",
			"Commands: :DefinitionPreview · :Definitions · :Symbols · :WorkspaceSymbols",
			"",
			"Editing only (requires server support):",
			"grn rename · gra code actions · grx code lens · gq format",
			"[d / ]d diagnostics · Ctrl-w d diagnostic details",
			"Insert: Ctrl-s signature help · Ctrl-x Ctrl-o completion",
			"Review blocks source-changing LSP actions (grn/gra/grx).",
			"gq keeps its existing annotation behavior in Review.",
		})
		local buf = api.nvim_create_buf(false, true)
		api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.bo[buf].bufhidden = "wipe"
		vim.bo[buf].modifiable = false
		api.nvim_open_win(buf, true, {
			relative = "editor",
			row = 1,
			col = 1,
			width = 1,
			height = 1,
			style = "minimal",
		})
		-- Use the editor's existing centered, scrollable help overlay and close keys.
		vim.bo[buf].filetype = "help"
	end, {
		nargs = 1,
		complete = function()
			return { "help" }
		end,
		desc = "LSP shortcut help",
	})
	vim.cmd([[cnoreabbrev <expr> lsp getcmdtype() == ':' && getcmdline() == 'lsp' && getcmdpos() == 4 ? 'Lsp' : 'lsp']])
	vim.keymap.set("n", "K", "<Nop>", { desc = "Hover shortcut disabled" })
	vim.keymap.set("n", "gT", "<Nop>", { desc = "Previous-tab shortcut disabled" })
	api.nvim_create_user_command("Definitions", function()
		M.definition(true)
	end, { desc = "Browse symbol and type definitions" })
	vim.keymap.set("n", "<Esc>", M.close_definition_preview, { desc = "Close definition preview" })
	api.nvim_create_user_command("DefinitionPreview", peek, { desc = "Preview definition under cursor" })
	for _, action in ipairs({ "Enable", "Disable", "Toggle" }) do
		api.nvim_create_user_command("DefinitionPreviewAuto" .. action, function()
			automatic_preview = action == "Enable" or (action == "Toggle" and not automatic_preview)
			last_automatic_position = nil
			M.close_definition_preview()
			vim.notify("Automatic definition preview " .. (automatic_preview and "enabled" or "disabled"))
		end, { desc = action .. " automatic definition previews" })
	end
	api.nvim_create_autocmd("CursorHold", {
		group = api.nvim_create_augroup("RediffDefinitionPreview", { clear = true }),
		-- Loading Review's hidden source must run outside the non-nested autocmd
		-- so BufRead/FileType can detect its language and start the LSP client.
		callback = vim.schedule_wrap(function()
			if not automatic_preview or vim.api.nvim_get_mode().mode ~= "n" then
				return
			end
			local win, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
			if api.nvim_win_get_config(win).relative ~= "" then
				return
			end
			local s = review.active()
			if vim.bo[buf].buftype ~= "" and not (s and (buf == s.old_buf or buf == s.new_buf)) then
				return
			end
			local cursor = api.nvim_win_get_cursor(win)
			local position = { win, buf, cursor, api.nvim_buf_get_changedtick(buf) }
			if vim.deep_equal(last_automatic_position, position) then
				return
			end
			last_automatic_position = position
			if vim.fn.match(api.nvim_get_current_line():sub(cursor[2] + 1), [[^\k]]) ~= 0 then
				return
			end
			-- Background lookups must not interrupt reading on unsupported/changed lines.
			pcall(M.definition, "preview", true)
		end),
	})
end

function M.explorer()
	local s = review.active()
	if s then
		api.nvim_set_current_win(s.tree_win)
	else
		require("neo-tree.command").execute({ action = "focus", source = "filesystem", position = "left" })
	end
end

function M.diff()
	local s = review.active()
	if s then
		api.nvim_set_current_win(s.new_win)
	else
		vim.cmd("wincmd l")
	end
end

local function pick_review(text)
	local s = assert(review.active())
	local entries, items, targets = s.entries, {}, {}
	local skipped = 0
	local function add(label, target)
		table.insert(targets, target)
		table.insert(items, #targets .. "\t" .. label)
	end
	for index, entry in ipairs(entries) do
		local label = "[" .. entry.group .. "] " .. vim.fn.strtrans(entry.path)
		if not text then
			add(label, { index = index })
		else
			local ok, snapshot = pcall(git.snapshot, s.root, entry)
			if ok then
				for _, side in ipairs({ "old", "new" }) do
					for line, content in ipairs(git.lines(snapshot[side])) do
						add(string.format("%s:%d (%s)  %s", label, line, side, vim.fn.strtrans(content)), {
							index = index,
							side = side,
							line = line,
							snapshot = snapshot,
						})
					end
				end
			else
				skipped = skipped + 1
			end
		end
	end
	if skipped > 0 then
		vim.notify("Search skipped " .. skipped .. " unsupported/unreadable files", vim.log.levels.WARN)
	end
	require("fzf-lua").fzf_exec(items, {
		prompt = text and "Review text> " or "Changed files> ",
		previewer = false,
		fzf_opts = { ["--delimiter"] = "\t", ["--with-nth"] = "2..", ["--no-multi"] = true },
		actions = {
			["enter"] = function(selected)
				if not selected[1] then
					return
				end
				local ok, err = pcall(function()
					assert(review.active() == s and s.entries == entries, "Review changed; reopen the picker")
					local target = assert(targets[tonumber(selected[1]:match("^(%d+)"))])
					if target.snapshot then
						git.validate(s.root, target.snapshot)
					end
					review.show(target.index)
					if target.side then
						assert(s.current.id == target.snapshot.id, "Search result changed; search again")
						if target.side == "old" and not s.old_win then
							review.view("split")
						end
						api.nvim_set_current_win(target.side == "old" and s.old_win or s.new_win)
						api.nvim_win_set_cursor(0, { target.line, 0 })
						vim.cmd("normal! zz")
					end
				end)
				if not ok then
					vim.notify(tostring(err), vim.log.levels.ERROR)
				end
			end,
		},
	})
end

local function project_options()
	local ok, root = pcall(git.root)
	return {
		cwd = ok and root or vim.fn.getcwd(),
		-- Default file actions can otherwise replace the explorer itself.
		actions = {
			["enter"] = function(selected, opts)
				if vim.bo.filetype == "neo-tree" then
					vim.cmd("wincmd l")
				end
				require("fzf-lua").actions.file_edit(selected, opts)
			end,
		},
	}
end

function M.files()
	if review.active() then
		return pick_review(false)
	end
	local opts = project_options()
	opts.cmd = "rg --files --hidden -g '!.git'"
	require("fzf-lua").files(opts)
end

function M.text()
	if review.active() then
		return pick_review(true)
	end
	local opts = project_options()
	opts.rg_opts =
		"--hidden --glob=!.git --column --line-number --no-heading --color=always --smart-case --max-columns=4096 -e"
	require("fzf-lua").grep_project(opts)
end

return M
