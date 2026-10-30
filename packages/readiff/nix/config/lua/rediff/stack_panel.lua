local M = {}
local api = vim.api
local git = require("rediff.git")
local panels = {}
local highlights = api.nvim_create_namespace("rediff.stack-panel")
local menu_target

local function guarded(fn)
	local ok, err = pcall(fn)
	if not ok then
		vim.notify(tostring(err), vim.log.levels.ERROR)
	end
end

local function row_key(row)
	return (row.kind or "branch") .. ":" .. (row.ref or "")
end

local function render(panel, review)
	local selected = panel.rows and panel.rows[api.nvim_win_get_cursor(panel.win)[1]]
	panel.selected = selected and row_key(selected) or panel.selected
	local lines, rows, marks = {}, {}, {}
	local checkout = git.reference(review.root)
	local head, code = git.run(review.root, { "rev-parse", "--verify", "HEAD^{commit}" }, nil, true)
	local checkout_commit = code == 0 and vim.trim(head) or nil
	local comparison = review.comparison
	local base = comparison and comparison.base or checkout_commit
	local target = comparison and comparison.head
	local displayed = {}
	local width = api.nvim_win_get_width(panel.win)
	local working_files = { kind = "worktree", ref = "Working files" }
	local range = {}
	local current
	for _, branch in ipairs(panel.branches) do
		if branch.commit == (target or checkout_commit) then
			current = branch
		end
	end
	while current do
		range[current.commit] = true
		if current.commit == base then
			break
		end
		current = #current.parents == 1 and current.parents[1] or nil
	end
	if not current then
		range = {}
	end

	local function add(row, prefix, label)
		local badges = {}
		if row.commit and row.commit == checkout_commit then
			table.insert(badges, "Checkout")
		end
		if row.commit and row.commit == base then
			table.insert(badges, "BASE")
		end
		if (row.commit and row.commit == target) or (row.kind == "worktree" and not target) then
			table.insert(badges, "TARGET")
		end
		local endpoint = vim.tbl_contains(badges, "BASE") or vim.tbl_contains(badges, "TARGET")
		local marker = endpoint and "○ " or "● "
		local text = prefix .. marker .. vim.fn.strtrans(label)
		local suffix = table.concat(badges, " · ")
		local padding = width - vim.fn.strdisplaywidth(text) - vim.fn.strdisplaywidth(suffix) - 1
		if suffix ~= "" and padding >= 1 then
			text = text .. string.rep(" ", padding) .. suffix
		end
		table.insert(lines, text)
		rows[#lines] = row
		marks[#lines] = endpoint and "ReviewStackEndpoint" or (range[row.commit] and "ReviewStackRange" or nil)
		if suffix ~= "" and padding < 1 then
			local indent =
				math.min(vim.fn.strdisplaywidth(prefix) + 2, math.max(1, width - vim.fn.strdisplaywidth(suffix) - 1))
			table.insert(lines, string.rep(" ", indent) .. suffix)
			rows[#lines] = row
			marks[#lines] = endpoint and "ReviewStackEndpoint" or nil
		end
		if row.commit then
			displayed[row.commit] = true
		end
	end

	local function matches(branch)
		if table.concat(branch.names, " "):lower():find(panel.filter:lower(), 1, true) then
			return true
		end
		for _, child in ipairs(branch.children) do
			if matches(child) then
				return true
			end
		end
		return false
	end
	local worktree_shown = false
	local function append(branch, prefix, last)
		if not matches(branch) then
			return
		end
		local collapsed = panel.collapsed[branch.ref] and panel.filter == ""
		local label = branch.ref .. (collapsed and #branch.children > 0 and " ▸" or "")
		if #branch.parents > 1 then
			label = label .. " ? parent unclear"
		end
		if comparison and comparison.head == branch.commit then
			if comparison.pr then
				label = label .. " #" .. comparison.pr.number
			end
		end
		if #branch.names > 1 then
			label = label .. " [" .. table.concat(branch.names, ", ", 2) .. "]"
		end
		add(branch, prefix .. (last and "└─" or "├─"), label)
		local child_prefix = prefix .. (last and "  " or "│ ")
		if not collapsed then
			for index, child in ipairs(branch.children) do
				append(child, child_prefix, index == #branch.children and branch.commit ~= checkout_commit)
			end
		end
		if branch.commit == checkout_commit then
			add(working_files, child_prefix .. "└─", "Working files")
			worktree_shown = true
		end
	end
	local roots = {}
	for _, branch in ipairs(panel.branches) do
		if #branch.parents ~= 1 then
			table.insert(roots, branch)
		end
	end
	for index, branch in ipairs(roots) do
		append(branch, "", index == #roots)
	end
	if #lines == 0 then
		lines = { panel.filter == "" and "No branch refs in this repository" or "No matching branches" }
	end
	for _, endpoint in ipairs({
		{ commit = base, ref = comparison and comparison.base_ref or checkout },
		{ commit = target, ref = comparison and comparison.head_ref },
	}) do
		if endpoint.commit and not displayed[endpoint.commit] then
			endpoint.kind = "commit"
			endpoint.ref = endpoint.ref or endpoint.commit
			add(endpoint, "", endpoint.commit:sub(1, 12) .. " (" .. endpoint.ref .. ")")
		end
	end
	if not worktree_shown then
		add(working_files, "", "Working files · " .. checkout)
	end
	table.insert(lines, "")
	add({ kind = "local", ref = "Local changes" }, "", "Local changes")
	vim.bo[panel.buf].modifiable = true
	api.nvim_buf_set_lines(panel.buf, 0, -1, false, lines)
	vim.bo[panel.buf].modifiable = false
	panel.rows = rows
	api.nvim_buf_clear_namespace(panel.buf, highlights, 0, -1)
	for row, highlight in pairs(marks) do
		api.nvim_buf_set_extmark(panel.buf, highlights, row - 1, 0, { line_hl_group = highlight })
	end
	local title = " STACKS"
	if panel.filter ~= "" then
		title = title .. " / " .. vim.fn.strtrans(panel.filter):gsub("%%", "%%%%")
	end
	vim.wo[panel.win].winbar = title
	local height = math.min(#lines + 1, math.floor((vim.o.lines - 4) / 2))
	api.nvim_win_set_height(panel.win, math.max(4, height))
	for row = 1, #lines do
		local branch = rows[row]
		if branch and row_key(branch) == panel.selected then
			api.nvim_win_set_cursor(panel.win, { row, 0 })
			return
		end
	end
	api.nvim_win_set_cursor(panel.win, { 1, 0 })
end

local function open_branch(panel, s, branch)
	local function select(parent)
		if not parent then
			return
		end
		guarded(function()
			assert(require("rediff.review").state == s, "Review changed. Select the branch again")
			panel.selected = row_key(branch)
			local chain = { parent, branch }
			while #chain[1].parents == 1 do
				table.insert(chain, 1, chain[1].parents[1])
			end
			local selected = #chain - 1
			while #chain[#chain].children == 1 do
				table.insert(chain, chain[#chain].children[1])
			end
			local comparisons = {}
			for index = 1, #chain - 1 do
				local base, head = chain[index], chain[index + 1]
				table.insert(comparisons, {
					base = base.commit,
					head = head.commit,
					base_ref = base.ref,
					head_ref = head.ref,
				})
			end
			require("rediff.comparison_stack").set(s.root, comparisons, selected)
			M.restore(require("rediff.review").state)
			api.nvim_set_current_win(panel.win)
		end)
	end
	if #branch.parents == 0 then
		vim.notify("This branch has no ancestor branch ref. Select a child to review, or use :git diff")
	elseif #branch.parents == 1 then
		select(branch.parents[1])
	else
		local rows = {}
		for index, parent in ipairs(branch.parents) do
			rows[index] = index .. " · " .. table.concat(parent.names, " / ")
		end
		require("fzf-lua").fzf_exec(rows, {
			prompt = "Parent branch> ",
			header = "Choose parent of " .. branch.ref .. " · Esc cancel",
			actions = {
				["default"] = function(selected)
					local index = selected[1] and tonumber(selected[1]:match("^%d+"))
					select(index and branch.parents[index])
				end,
			},
		})
	end
end

local function select_endpoint(panel, s, row, action)
	panel.selected = row_key(row)
	if row.kind == "local" then
		require("rediff.review").open(s.root)
	else
		local previous = s.comparison or git.comparison(s.root, "HEAD")
		local comparison = {
			base = previous.base,
			base_ref = previous.base_ref,
			head = previous.head,
			head_ref = previous.head_ref,
		}
		if action == "base" then
			comparison.base, comparison.base_ref = row.commit, row.ref
		else
			comparison.head = row.commit
			comparison.head_ref = row.commit and row.ref or nil
		end
		require("rediff.comparison_stack").set(s.root, { comparison })
	end
	api.nvim_set_current_win(panel.win)
end

function M.action(action)
	local context = menu_target
	menu_target = nil
	guarded(function()
		assert(context and require("rediff.review").active() == context.review, "Review changed. Reopen the menu")
		if action == "parent" then
			open_branch(context.panel, context.review, context.row)
		else
			select_endpoint(context.panel, context.review, context.row, action)
		end
	end)
end

local function show_menu(panel, s)
	local row = panel.rows[api.nvim_win_get_cursor(panel.win)[1]]
	if not row then
		return
	end
	menu_target = { panel = panel, review = s, row = row }
	pcall(vim.cmd, "nunmenu RediffStack")
	if row.kind == "local" then
		vim.cmd(
			[[nnoremenu <silent> RediffStack.Local\ changes <Cmd>lua require('rediff.stack_panel').action('local')<CR>]]
		)
	else
		vim.cmd(
			[[nnoremenu <silent> RediffStack.Review\ against\ parent <Cmd>lua require('rediff.stack_panel').action('parent')<CR>]]
		)
		vim.cmd(
			[[nnoremenu <silent> RediffStack.Use\ as\ base <Cmd>lua require('rediff.stack_panel').action('base')<CR>]]
		)
		vim.cmd(
			[[nnoremenu <silent> RediffStack.Use\ as\ target <Cmd>lua require('rediff.stack_panel').action('target')<CR>]]
		)
		if row.kind or #row.parents == 0 then
			vim.cmd([[menu disable RediffStack.Review\ against\ parent]])
		end
		if not row.commit then
			vim.cmd([[menu disable RediffStack.Use\ as\ base]])
		end
	end
	local border = vim.o.pumborder
	local menu_buf = panel.buf
	local escape = vim.fn.maparg("<Esc>", "n", false, true)
	-- The native menu needs literal Escape rather than the graph's Lua mapping.
	vim.keymap.set("n", "<Esc>", "<Esc>", { buffer = menu_buf })
	vim.o.pumborder = "single"
	vim.cmd("popup RediffStack")
	vim.o.pumborder = border
	if api.nvim_buf_is_valid(menu_buf) then
		api.nvim_buf_call(menu_buf, function()
			vim.fn.mapset("n", false, escape)
		end)
	end
end

function M.refresh(s)
	local panel = panels[s.root]
	if not panel or not panel.visible or not panel.win or not api.nvim_win_is_valid(panel.win) then
		return
	end
	local refs = git.run(s.root, { "for-each-ref", "--format=%(refname) %(objectname)", "refs/heads", "refs/remotes" })
	if refs ~= panel.refs then
		panel.branches = require("rediff.branch_stack").branches(s.root)
		panel.refs = refs
	end
	render(panel, s)
end

function M.resize(s)
	local panel = panels[s.root]
	if panel and panel.visible and panel.win and api.nvim_win_is_valid(panel.win) then
		api.nvim_win_set_width(panel.win, math.min(44, math.floor(vim.o.columns / 3)))
		render(panel, s)
		if s.old_win and api.nvim_win_is_valid(s.old_win) then
			local width = api.nvim_win_get_width(s.old_win) + api.nvim_win_get_width(s.new_win)
			api.nvim_win_set_width(s.old_win, math.floor(width / 2))
		end
	end
end

function M.restore(s)
	local panel = panels[s.root]
	if not panel then
		panel = { collapsed = {}, filter = "", visible = true, branches = {} }
		panels[s.root] = panel
	end
	if not panel.visible then
		return
	end
	if not panel.win or not api.nvim_win_is_valid(panel.win) then
		panel.rows = nil
		panel.buf = api.nvim_create_buf(false, true)
		api.nvim_buf_set_name(panel.buf, "review://" .. s.id .. "/stacks")
		vim.bo[panel.buf].bufhidden = "wipe"
		vim.bo[panel.buf].filetype = "rediff-stacks"
		panel.win = api.nvim_open_win(panel.buf, false, { split = "above", win = s.tree_win, height = 4 })
		for name, value in pairs({
			number = false,
			relativenumber = false,
			signcolumn = "no",
			wrap = false,
			cursorline = true,
			winfixheight = true,
			winfixwidth = true,
			winhighlight = "CursorLine:ReviewTreeSelection,WinBar:ReviewInactivePane,WinBarNC:ReviewInactivePane",
		}) do
			vim.wo[panel.win][name] = value
		end
		local function map(key, fn, description)
			vim.keymap.set("n", key, function()
				guarded(fn)
			end, { buffer = panel.buf, desc = description })
		end
		map("<CR>", function()
			local branch = panel.rows[api.nvim_win_get_cursor(panel.win)[1]]
			if branch then
				if branch.kind then
					select_endpoint(panel, s, branch, "target")
				else
					open_branch(panel, s, branch)
				end
			end
		end, "Review branch against its parent")
		for _, key in ipairs({ "a", "<Menu>" }) do
			map(key, function()
				show_menu(panel, s)
			end, "Comparison actions")
		end
		map("<RightMouse>", function()
			local mouse = vim.fn.getmousepos()
			if mouse.winid == panel.win and mouse.line > 0 then
				api.nvim_set_current_win(panel.win)
				api.nvim_win_set_cursor(panel.win, { mouse.line, 0 })
				show_menu(panel, s)
			end
		end, "Comparison actions")
		for key, collapse in pairs({ h = true, l = false }) do
			map(key, function()
				local branch = panel.rows[api.nvim_win_get_cursor(panel.win)[1]]
				if branch and not branch.kind then
					panel.collapsed[branch.ref] = collapse
					render(panel, s)
				end
			end, "Fold branch chain")
		end
		map("r", function()
			panel.refs = nil
			M.refresh(s)
		end, "Rescan local branch refs")
		map("/", function()
			vim.ui.input({ prompt = "Filter branches: ", default = panel.filter }, function(input)
				if input and api.nvim_buf_is_valid(panel.buf) then
					panel.filter = input
					render(panel, s)
				end
			end)
		end, "Filter branches")
		map("<Esc>", function()
			panel.filter = ""
			render(panel, s)
			api.nvim_set_current_win(s.tree_win)
		end, "Clear branch filter and focus files")
		map("<Tab>", function()
			api.nvim_set_current_win(s.tree_win)
		end, "Focus files")
		map("q", function()
			panel.visible = false
			s.stack_win = nil
			api.nvim_win_close(panel.win, true)
			api.nvim_win_set_width(s.tree_win, math.min(28, math.floor(vim.o.columns / 5)))
		end, "Close stacks panel")
	end
	s.stack_win = panel.win
	M.refresh(s)
	M.resize(s)
end

function M.open(root)
	local review = require("rediff.review")
	if not review.state then
		review.open(root)
	end
	api.nvim_set_current_tabpage(review.state.tab)
	local panel = panels[root] or { collapsed = {}, filter = "", branches = {} }
	panels[root] = panel
	panel.refs = nil
	panel.visible = true
	M.restore(review.state)
	api.nvim_set_current_win(panel.win)
end

return M
