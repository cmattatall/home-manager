local M = {}
local api = vim.api
local frame

function M.update(review)
	local win = api.nvim_get_current_win()
	if not review or #api.nvim_list_uis() == 0 then
		if frame and api.nvim_win_is_valid(frame) then
			api.nvim_win_close(frame, true)
		end
		frame = nil
		return
	end

	if win == review.tree_win or win == review.stack_win or win == review.filter_win then
		review.focus_mode = "tree"
	elseif win == review.old_win or win == review.new_win or win == review.composer_win then
		review.focus_mode = "review"
	end
	local windows = review.focus_mode == "review" and { review.new_win, review.old_win }
		or { review.tree_win, review.stack_win }
	local row, col = math.huge, math.huge
	local end_row, end_col = 0, 0
	for _, pane in ipairs(windows) do
		local position = api.nvim_win_get_position(pane)
		row = math.min(row, position[1])
		col = math.min(col, position[2])
		end_row = math.max(end_row, position[1] + api.nvim_win_get_height(pane))
		end_col = math.max(end_col, position[2] + api.nvim_win_get_width(pane))
	end
	local height, width = end_row - row, end_col - col
	local top, left = row > 0, col > 0
	local bottom = row + height < vim.o.lines - vim.o.cmdheight - 1
	local right = col + width < vim.o.columns
	local border = {
		top and left and "┌" or "",
		top and "─" or "",
		top and right and "┐" or "",
		right and "│" or "",
		bottom and right and "┘" or "",
		bottom and "─" or "",
		bottom and left and "└" or "",
		left and "│" or "",
	}
	local config = {
		relative = "editor",
		row = row - (top and 1 or 0),
		col = col - (left and 1 or 0),
		width = width,
		height = height,
		border = border,
		style = "minimal",
		focusable = false,
		mouse = false,
		zindex = 49,
		noautocmd = true,
	}
	if frame and api.nvim_win_is_valid(frame) then
		api.nvim_win_set_config(frame, config)
	else
		local buf = api.nvim_create_buf(false, true)
		vim.bo[buf].bufhidden = "wipe"
		frame = api.nvim_open_win(buf, false, config)
		-- Native separator highlights belong to neighboring windows. A transparent
		-- frame surrounds the focus area and lets mouse events through.
		vim.wo[frame].winblend = 100
		vim.wo[frame].winhighlight = "Normal:ReviewPaneTransparent,FloatBorder:ReviewPaneBorder"
	end
end

return M
