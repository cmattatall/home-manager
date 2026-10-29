local M = {}
local api = vim.api
local git = require("rediff.git")
local panels = {}

local function guarded(fn)
	local ok, err = pcall(fn)
	if not ok then
		vim.notify(tostring(err), vim.log.levels.ERROR)
	end
end

local function render(panel, review)
	local selected = panel.rows and panel.rows[api.nvim_win_get_cursor(panel.win)[1]]
	panel.selected_ref = selected and selected.ref or panel.selected_ref
	local lines, rows = {}, {}
	local checkout = git.reference(review.root)
	local comparison = review.comparison
	local compact = api.nvim_win_get_width(panel.win) < 36
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
	local function append(branch, depth)
		if not matches(branch) then
			return
		end
		local collapsed = panel.collapsed[branch.ref] and panel.filter == ""
		local marker = #branch.children == 0 and "  " or (collapsed and "▸ " or "▾ ")
		local label = string.rep("  ", depth) .. marker .. branch.ref
		if #branch.parents > 1 then
			label = label .. " ? parent unclear"
		elseif #branch.parents == 0 then
			label = label .. " (root)"
		end
		if vim.tbl_contains(branch.names, checkout) then
			label = label .. (compact and " * HEAD" or " * checkout")
		end
		if comparison and comparison.head == branch.commit then
			label = label .. (compact and " · review" or " · reviewing")
			if comparison.pr then
				label = label .. " #" .. comparison.pr.number
			end
		end
		if #branch.names > 1 then
			label = label .. " [" .. table.concat(branch.names, ", ", 2) .. "]"
		end
		table.insert(lines, label)
		table.insert(rows, branch)
		if not collapsed then
			for _, child in ipairs(branch.children) do
				append(child, depth + 1)
			end
		end
	end
	for _, branch in ipairs(panel.branches) do
		if #branch.parents ~= 1 then
			append(branch, 0)
		end
	end
	if #lines == 0 then
		lines = { panel.filter == "" and "No branch refs in this repository" or "No matching branches" }
	end
	vim.list_extend(lines, { "", "Enter review · h/l fold", "/ filter · r refresh · q close" })
	vim.bo[panel.buf].modifiable = true
	api.nvim_buf_set_lines(panel.buf, 0, -1, false, lines)
	vim.bo[panel.buf].modifiable = false
	panel.rows = rows
	local title = " STACKS · inferred"
	if panel.filter ~= "" then
		title = title .. " / " .. vim.fn.strtrans(panel.filter):gsub("%%", "%%%%")
	end
	vim.wo[panel.win].winbar = title
	for row, branch in ipairs(rows) do
		if branch.ref == panel.selected_ref then
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
			panel.selected_ref = branch.ref
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

function M.resize(s)
	local panel = panels[s.root]
	if panel and panel.visible and panel.win and api.nvim_win_is_valid(panel.win) then
		api.nvim_win_set_width(panel.win, math.min(44, math.floor(vim.o.columns / 3)))
		api.nvim_win_set_height(panel.win, math.max(4, math.floor((vim.o.lines - 4) / 2)))
		if s.old_win and api.nvim_win_is_valid(s.old_win) then
			local width = api.nvim_win_get_width(s.old_win) + api.nvim_win_get_width(s.new_win)
			api.nvim_win_set_width(s.old_win, math.floor(width / 2))
		end
		render(panel, s)
	end
end

function M.restore(s)
	local panel = panels[s.root]
	if not panel or not panel.visible then
		return
	end
	if not panel.win or not api.nvim_win_is_valid(panel.win) then
		panel.rows = nil
		panel.buf = api.nvim_create_buf(false, true)
		api.nvim_buf_set_name(panel.buf, "review://" .. s.id .. "/stacks")
		vim.bo[panel.buf].bufhidden = "wipe"
		vim.bo[panel.buf].filetype = "rediff-stacks"
		api.nvim_win_call(s.tree_win, function()
			vim.cmd("aboveleft split")
			panel.win = api.nvim_get_current_win()
			api.nvim_win_set_buf(panel.win, panel.buf)
		end)
		for name, value in pairs({
			number = false,
			relativenumber = false,
			signcolumn = "no",
			wrap = false,
			cursorline = true,
			winfixheight = true,
			winfixwidth = true,
			winhighlight = "CursorLine:ReviewTreeSelection,WinBar:ReviewFocusedPane,WinBarNC:ReviewInactivePane",
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
				open_branch(panel, s, branch)
			end
		end, "Review branch against its parent")
		for key, collapse in pairs({ h = true, l = false }) do
			map(key, function()
				local branch = panel.rows[api.nvim_win_get_cursor(panel.win)[1]]
				if branch then
					panel.collapsed[branch.ref] = collapse
					render(panel, s)
				end
			end, "Fold branch chain")
		end
		map("r", function()
			panel.branches = require("rediff.branch_stack").branches(s.root)
			render(panel, s)
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
			api.nvim_win_close(panel.win, true)
			api.nvim_win_set_width(s.tree_win, math.min(28, math.floor(vim.o.columns / 5)))
		end, "Close stacks panel")
	end
	M.resize(s)
end

function M.open(root)
	local branches = require("rediff.branch_stack").branches(root)
	local review = require("rediff.review")
	if not review.state then
		review.open(root)
	end
	api.nvim_set_current_tabpage(review.state.tab)
	local panel = panels[root] or { collapsed = {}, filter = "" }
	panels[root] = panel
	panel.branches = branches
	panel.visible = true
	M.restore(review.state)
	api.nvim_set_current_win(panel.win)
end

return M
