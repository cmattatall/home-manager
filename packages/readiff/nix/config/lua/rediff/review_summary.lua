local M = {}
local api = vim.api
local namespace = api.nvim_create_namespace("rediff.file-summary")

function M.update(s)
	if not s.summary_win or not api.nvim_win_is_valid(s.summary_win) then
		return
	end
	local chunks = { { " No file selected", "ReviewFileSummary" } }
	if s.current and s.diff and api.nvim_win_is_valid(s.new_win) then
		local added, deleted = 0, 0
		for _, change in ipairs(s.diff.changes) do
			added = added + change.modified.end_line - change.modified.start_line
			deleted = deleted + change.original.end_line - change.original.start_line
		end
		-- Empty diff buffers contain a placeholder line for Neovim's renderer.
		if s.current.old == "" then
			added = s.current.new == "" and 0 or api.nvim_buf_line_count(s.new_buf)
			deleted = 0
		elseif s.current.new == "" then
			added, deleted = 0, api.nvim_buf_line_count(s.old_buf)
		end

		local win = api.nvim_get_current_win() == s.old_win and s.old_win or s.new_win
		local side = win == s.old_win and "original" or "modified"
		local cursor = api.nvim_win_get_cursor(win)[1]
		local views = { modified = vim.fn.getwininfo(s.new_win)[1] }
		if s.old_win then
			views.original = vim.fn.getwininfo(s.old_win)[1]
		end
		local topfill = api.nvim_win_call(s.new_win, function()
			return vim.fn.winsaveview().topfill
		end)
		local position, above, below = 0, 0, 0
		local continues_above, continues_below = false, false
		for index, change in ipairs(s.diff.changes) do
			if position == 0 or change[side].start_line <= cursor then
				position = index
			end
			local original_lines = change.original.end_line - change.original.start_line
			local modified_lines = change.modified.end_line - change.modified.start_line
			local visible_side = s.old_win and original_lines > modified_lines and "original" or "modified"
			local view = views[visible_side]
			local line_count = api.nvim_buf_line_count(view.bufnr)
			local range = change[visible_side]
			local first = math.max(1, math.min(range.start_line, line_count))
			local last = math.max(first, math.min(range.end_line - 1, line_count))
			local top, bottom = view.topline, view.botline
			-- Merged deletions occupy virtual rows above their new-side anchor.
			local virtual_at_top = s.layout == "merged" and first == top and original_lines > 0
			if virtual_at_top and original_lines > topfill then
				continues_above = true
			end
			if last < top then
				above = above + 1
			elseif first > bottom and not (virtual_at_top and topfill > 0) then
				below = below + 1
			else
				continues_above = continues_above or first < top
				continues_below = continues_below or last > bottom
			end
		end

		local width = api.nvim_win_get_width(s.summary_win)
		local compact = width < 85
		local name = vim.fn.strtrans(s.current.path)
		if vim.fn.strdisplaywidth(name) > width - 70 then
			name = "File"
		end
		local hunk_position = compact and (position .. "/" .. #s.diff.changes)
			or (position .. " of " .. #s.diff.changes)
		chunks = {
			{ " " .. name .. "  ", "ReviewFileSummary" },
			{ "+" .. added, "ReviewAdded" },
			{ "  ", "ReviewFileSummary" },
			{ "−" .. deleted, "ReviewDeleted" },
			{ " · Hunk " .. hunk_position, "ReviewFileSummary" },
		}
		if above > 0 then
			table.insert(chunks, { " · ↑ " .. above .. " above", "ReviewFileSummary" })
		elseif continues_above then
			table.insert(chunks, { " · ↑ Starts above", "ReviewFileSummary" })
		end
		if below > 0 then
			local label = below == 1 and " more hunk below" or " more hunks below"
			if compact then
				label = " below"
			end
			table.insert(chunks, { " · ↓ " .. below .. label, "ReviewFileSummary" })
		elseif continues_below then
			table.insert(chunks, { " · ↓ Continues below", "ReviewFileSummary" })
		end
		if #s.diff.changes > 0 then
			table.insert(chunks, { " · ] next", "ReviewFileSummary" })
		end
	end

	local parts = {}
	for _, chunk in ipairs(chunks) do
		table.insert(parts, chunk[1])
	end
	local text = table.concat(parts)
	if api.nvim_buf_get_lines(s.summary_buf, 0, 1, false)[1] == text then
		return
	end
	vim.bo[s.summary_buf].modifiable = true
	api.nvim_buf_set_lines(s.summary_buf, 0, -1, false, { text })
	vim.bo[s.summary_buf].modifiable = false
	api.nvim_buf_clear_namespace(s.summary_buf, namespace, 0, -1)
	local column = 0
	for _, chunk in ipairs(chunks) do
		api.nvim_buf_set_extmark(s.summary_buf, namespace, 0, column, {
			end_col = column + #chunk[1],
			hl_group = chunk[2],
		})
		column = column + #chunk[1]
	end
end

function M.open(s)
	s.summary_buf = api.nvim_create_buf(false, true)
	vim.bo[s.summary_buf].filetype = "rediff-file-summary"
	vim.bo[s.summary_buf].bufhidden = "wipe"
	s.summary_win = api.nvim_open_win(s.summary_buf, false, {
		split = "above",
		win = s.old_win,
		height = 1,
		focusable = false,
	})
	local options = {
		winfixheight = true,
		number = false,
		relativenumber = false,
		signcolumn = "no",
		foldcolumn = "0",
		wrap = false,
		winbar = "",
		cursorline = false,
		winhighlight = "Normal:ReviewFileSummary,NormalNC:ReviewFileSummary",
	}
	for name, value in pairs(options) do
		vim.wo[s.summary_win][name] = value
	end
	local group = api.nvim_create_augroup("rediff.file-summary." .. s.id, { clear = true })
	api.nvim_create_autocmd({ "CursorMoved", "WinScrolled", "WinResized", "TabEnter" }, {
		group = group,
		callback = function()
			if require("rediff.review").active() == s then
				M.update(s)
			end
		end,
	})
	api.nvim_create_autocmd("BufWipeout", {
		group = group,
		buffer = s.summary_buf,
		once = true,
		callback = function()
			api.nvim_del_augroup_by_id(group)
		end,
	})
end

return M
