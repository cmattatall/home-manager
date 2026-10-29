local M = {}
local api = vim.api
local links = api.nvim_create_namespace("rediff-git-links")

function M.open(title, footer, wrap)
	local p = { buf = api.nvim_create_buf(false, true) }
	vim.bo[p.buf].bufhidden = "wipe"
	local width = math.max(1, math.min(110, vim.o.columns - 4))
	p.win = api.nvim_open_win(p.buf, true, {
		relative = "editor",
		row = 2,
		col = math.max(0, math.floor((vim.o.columns - width - 2) / 2)),
		width = width,
		height = 4,
		style = "minimal",
		border = "single",
		title = " " .. vim.fn.strtrans(title) .. " ",
	})
	vim.wo[p.win].wrap = wrap ~= false
	vim.wo[p.win].linebreak = false
	function p.alive()
		return api.nvim_buf_is_valid(p.buf) and api.nvim_win_is_valid(p.win)
	end
	function p.show(lines, err)
		if not p.alive() then
			return
		end
		if err then
			lines = { "Lookup failed", "" }
			vim.list_extend(lines, vim.split(err, "\n"))
		end
		lines = vim.tbl_map(vim.fn.strtrans, lines)
		vim.list_extend(lines, { "", footer or "q/Esc close · y yank URL · modifier-click opens locally" })
		vim.bo[p.buf].modifiable = true
		api.nvim_buf_set_lines(p.buf, 0, -1, false, lines)
		vim.bo[p.buf].modifiable = false
		api.nvim_buf_clear_namespace(p.buf, links, 0, -1)
		local height = 0
		for i, line in ipairs(lines) do
			height = height + (wrap == false and 1 or math.max(1, math.ceil(vim.fn.strdisplaywidth(line) / width)))
			local start, finish = line:find("https://%S+")
			if start then
				api.nvim_buf_set_extmark(p.buf, links, i - 1, start - 1, {
					end_col = finish,
					hl_group = "Underlined",
					url = line:sub(start, finish),
				})
			end
		end
		api.nvim_win_set_height(p.win, math.max(1, math.min(height, vim.o.lines - 7)))
	end
	function p.map(key, action, desc)
		vim.keymap.set("n", key, action, { buffer = p.buf, nowait = true, desc = desc })
	end
	function p.close()
		api.nvim_win_close(p.win, true)
	end
	p.map("q", p.close, "Close Git popup")
	p.map("<Esc>", p.close, "Close Git popup")
	p.map("y", function()
		local url = api.nvim_get_current_line():match("https://%S+")
		if url then
			vim.fn.setreg('"', url)
			vim.notify("URL yanked; terminal copy also works over SSH")
		else
			vim.notify("Move to a URL to yank it")
		end
	end, "Yank URL to the unnamed register")
	p.show({ "Loading…" })
	return p
end

return M
