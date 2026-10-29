local M = {}
local api = vim.api
local git = require("rediff.git")
local stacks = {}

function M.position(root, comparison)
	local stack = stacks[root]
	if stack then
		for index, item in ipairs(stack) do
			if item.comparison == comparison then
				return index, #stack
			end
		end
	end
end

local function remember(root)
	local s = require("rediff.review").state
	if not s or s.root ~= root then
		return
	end
	local index = M.position(root, s.comparison)
	if not index then
		return
	end
	local view = { path = s.current and s.current.path, layout = s.layout, panes = {} }
	for _, side in ipairs({ "tree", "old", "new" }) do
		local win = s[side .. "_win"]
		if win and api.nvim_win_is_valid(win) then
			view.panes[side] = api.nvim_win_call(win, vim.fn.winsaveview)
			if win == api.nvim_get_current_win() then
				view.focus = side
			end
		end
	end
	stacks[root][index].view = view
end

local function select(root, stack, index)
	local review = require("rediff.review")
	local item = stack[index]
	remember(root)
	local previous = stacks[root]
	stacks[root] = stack
	local ok, err = pcall(review.open, root, item.comparison)
	if not ok then
		stacks[root] = previous
		error(err)
	end
	local view = item.view
	if not view then
		return
	end
	local s = review.state
	review.view(view.layout)
	for i, entry in ipairs(s.entries) do
		if entry.path == view.path then
			review.show(i)
			break
		end
	end
	for side, position in pairs(view.panes) do
		local win = s[side .. "_win"]
		if win and api.nvim_win_is_valid(win) then
			api.nvim_win_call(win, function()
				vim.fn.winrestview(position)
			end)
		end
	end
	if view.focus and s[view.focus .. "_win"] then
		api.nvim_set_current_win(s[view.focus .. "_win"])
	end
end

function M.set(root, comparisons)
	local stack = {}
	for _, comparison in ipairs(comparisons) do
		table.insert(stack, { comparison = comparison })
	end
	select(root, stack, 1)
end

function M.move(root, direction)
	local review = require("rediff.review")
	local s = review.state
	local index = s and M.position(root, s.comparison)
	assert(index, "Choose a comparison with :git stack first")
	local stack = stacks[root]
	local next_index = index + direction
	if next_index < 1 or next_index > #stack then
		vim.notify(direction > 0 and "Top of comparison stack" or "Bottom of comparison stack")
		return
	end
	select(root, stack, next_index)
end

function M.choose(root)
	local stack = stacks[root]
	if not stack then
		return false
	end
	local s = require("rediff.review").state
	local current = s and M.position(root, s.comparison)
	local rows = {}
	for index, item in ipairs(stack) do
		local marker = index == current and " * " or "   "
		rows[index] = index .. marker .. git.comparison_label(item.comparison)
	end
	require("fzf-lua").fzf_exec(rows, {
		prompt = "Comparisons> ",
		header = "base → target · Enter select · Space gu up / Space gd down in Review",
		fzf_opts = { ["--no-sort"] = true },
		actions = {
			["default"] = function(selected)
				if not selected[1] then
					return
				end
				local index = tonumber(selected[1]:match("^%d+"))
				local ok, err = pcall(select, root, stack, index)
				if not ok then
					vim.notify(tostring(err), vim.log.levels.ERROR)
				end
			end,
		},
	})
	return true
end

function M.refresh(root)
	local s = require("rediff.review").state
	assert(s and s.comparison, "Open a comparison before refreshing refs")
	local comparison = s.comparison
	local refreshed =
		git.comparison(root, comparison.base_ref or comparison.base, comparison.head_ref or comparison.head)
	local index = M.position(root, comparison)
	if not index then
		M.set(root, { refreshed })
		return
	end
	remember(root)
	local stack = vim.deepcopy(stacks[root])
	stack[index].comparison = refreshed
	select(root, stack, index)
end

return M
