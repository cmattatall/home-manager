local M = {}
local api = vim.api
local popup = require("rediff.git_popup").open
local inline = api.nvim_create_namespace("rediff-inline-blame")
local inline_enabled, generation = true, 0
local inline_buf

local function git(root, args)
	local argv = { "git", "--literal-pathspecs", "-C", root }
	vim.list_extend(argv, args)
	return vim.system(argv, { text = true }):wait(10000)
end

local function context()
	local buf, win = api.nvim_get_current_buf(), api.nvim_get_current_win()
	local s = require("rediff.review").active()
	local c
	if s and (buf == s.old_buf or buf == s.new_buf) then
		local snapshot = assert(s.current, "Select a file in Review first")
		local side = buf == s.old_buf and "old" or "new"
		local head = side == "old" and snapshot.base or snapshot.head
		c = { root = s.root, path = snapshot.path, head = head, text = snapshot[side], side = side }
	else
		assert(vim.bo[buf].buftype == "", "Focus a file or Review source pane first")
		local path = api.nvim_buf_get_name(buf)
		assert(path ~= "", "Open a file first")
		local root = git(vim.fs.dirname(path), { "rev-parse", "--show-toplevel" })
		assert(root.code == 0, vim.trim(root.stderr))
		c = { root = vim.trim(root.stdout) }
		c.path = assert(vim.fs.relpath(c.root, path), "File is outside the repository")
		c.head = vim.trim(git(c.root, { "rev-parse", "--verify", "HEAD" }).stdout)
		local newline = vim.bo[buf].fileformat == "dos" and "\r\n" or "\n"
		c.text = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), newline)
		if vim.bo[buf].endofline then
			c.text = c.text .. newline
		end
	end
	c.buf, c.win, c.tick = buf, win, api.nvim_buf_get_changedtick(buf)
	c.line = api.nvim_win_get_cursor(win)[1]
	assert(c.text ~= "", "There is no source line here")
	return c
end

local function request(argv, c, input, done)
	vim.system(
		argv,
		{ cwd = c.root, stdin = input, text = true, timeout = 15000 },
		vim.schedule_wrap(function(result)
			if result.code ~= 0 then
				local message = vim.trim(result.stderr or "")
				done(nil, message ~= "" and message or "Command failed or timed out")
			else
				done(result.stdout or "")
			end
		end)
	)
end

local function blame(c, all, done)
	if c.head == "" or git(c.root, { "cat-file", "-e", c.head .. ":" .. c.path }).code ~= 0 then
		local rows = {}
		local lines = vim.split(c.text, "\n", { plain = true })
		if lines[#lines] == "" then
			table.remove(lines)
		end
		for i, text in ipairs(lines) do
			rows[i] = { line = i, text = text, uncommitted = true }
		end
		return done(rows)
	end
	local args = { "git", "--literal-pathspecs", "blame", "--line-porcelain" }
	if not all then
		vim.list_extend(args, { "-L", c.line .. "," .. c.line })
	end
	vim.list_extend(args, { "--contents", "-", c.head, "--", c.path })
	request(args, c, c.text, function(output, err)
		if err then
			return done(nil, err)
		end
		local rows, row = {}, nil
		for line in output:gmatch("[^\n]+") do
			local sha, number = line:match("^(%x+) %d+ (%d+)")
			if sha then
				row = { sha = sha, line = tonumber(number), uncommitted = sha:match("^0+$") ~= nil }
			elseif row and line:sub(1, 1) == "\t" then
				row.text = line:sub(2)
				rows[row.line] = row
				row = nil
			elseif row then
				local key, value = line:match("^(%S+) (.*)")
				if key then
					row[key] = value
				end
			end
		end
		if not rows[c.line] then
			return done(nil, "Git returned no blame information for this line")
		end
		done(rows)
	end)
end

local function description(row)
	if row.uncommitted then
		return "Not committed yet"
	end
	local date = os.date("%Y-%m-%d", tonumber(row["author-time"]))
	return row.sha:sub(1, 12) .. " · " .. row.author .. " · " .. date .. " · " .. row.summary
end

local function label(c)
	return c.path .. ":" .. c.line .. (c.side and " · " .. c.side .. " snapshot" or "")
end

function M.copy_link(target)
	local c = target or context()
	local remote = git(c.root, { "remote", "get-url", "origin" })
	assert(remote.code == 0, "Configure a GitHub origin remote to copy a link")
	local address = vim.trim(remote.stdout):gsub("/$", ""):gsub("%.git$", "")
	local repository = address:match("^https://github%.com/([%w_.%-]+/[%w_.%-]+)$")
		or address:match("^git@github%.com:([%w_.%-]+/[%w_.%-]+)$")
		or address:match("^ssh://git@github%.com/([%w_.%-]+/[%w_.%-]+)$")
	assert(repository, "The origin remote must be a github.com HTTPS or SSH URL")

	local head = c.head or vim.trim(git(c.root, { "rev-parse", "--verify", "HEAD" }).stdout)
	assert(head ~= "", "Commit this path before copying a permalink")
	local path = c.path == "." and "" or c.path
	local kind, fragment = "blob", ""
	if target then
		local object = git(c.root, { "cat-file", "-t", head .. ":" .. path })
		assert(object.code == 0, "This path has no committed version to link to")
		kind = vim.trim(object.stdout)
		assert(kind == "blob" or kind == "tree", "Select a committed file or directory")
	else
		local committed = git(c.root, { "show", head .. ":" .. path })
		assert(committed.code == 0, "This file has no committed version to link to")
		local text = c.text:gsub("\r\n", "\n")
		local line = c.line
		for _, hunk in ipairs(vim.diff(committed.stdout, text, { result_type = "indices" })) do
			local _, old_count, new_start, new_count = unpack(hunk)
			if new_count == 0 then
				if c.line <= new_start then
					break
				end
			elseif c.line < new_start then
				break
			else
				assert(c.line >= new_start + new_count, "This line has uncommitted changes and no permalink")
			end
			line = line + old_count - new_count
		end
		fragment = string.format("#L%d", line)
	end

	path = path:gsub("[^%w%-%._~/]", function(character)
		return string.format("%%%02X", character:byte())
	end)
	local url = string.format("https://github.com/%s/%s/%s", repository, kind, head)
	if path ~= "" then
		url = url .. "/" .. path
	end
	url = url .. fragment
	vim.fn.setreg("+", url, "v")
	vim.notify("Permalink copied")
end

local function pull_requests(c, row, p)
	p = p or popup("Git · " .. label(c))
	if row.uncommitted then
		return p.show({ label(c), "", "Not committed yet — no commit or pull request for this line." })
	end
	p.show({ description(row), "", "Looking up pull requests…" })
	-- Display links for the SSH client's terminal to open locally.
	request(
		{
			"gh",
			"api",
			"--paginate",
			"repos/{owner}/{repo}/commits/" .. row.sha .. "/pulls",
			"--jq",
			[[.[] | "#\(.number) \(.title)\n\(.html_url)\n"]],
		},
		c,
		nil,
		function(output, err)
			if err then
				return p.show(nil, err)
			end
			local lines = { label(c), description(row), "" }
			vim.list_extend(
				lines,
				vim.trim(output) == "" and { "No pull request is associated with this commit." }
					or vim.split(vim.trim(output), "\n")
			)
			p.show(lines)
		end
	)
end

function M.blame_line(with_pr)
	local c = context()
	local p = popup("Git · " .. label(c), not with_pr and "p PR links · q/Esc close" or nil)
	blame(c, false, function(rows, err)
		if not p.alive() then
			return
		end
		if err then
			return p.show(nil, err)
		end
		local row = rows[c.line]
		if with_pr then
			return pull_requests(c, row, p)
		end
		p.show({ label(c), "", description(row) })
		p.map("p", function()
			pull_requests(c, row)
		end, "Show this line's PR links")
	end)
end

function M.blame()
	local c = context()
	local p = popup("Git · " .. c.path .. " · blame", "Enter source line · p PR links · q/Esc close", false)
	blame(c, true, function(rows, err)
		if not p.alive() then
			return
		end
		if err then
			return p.show(nil, err)
		end
		local lines = {}
		for i, row in ipairs(rows) do
			local author = row.uncommitted and "Not committed yet" or row.author
			lines[i] = string.format(
				"%4d  %-8s  %-20s │ %s",
				i,
				row.uncommitted and "--------" or row.sha:sub(1, 8),
				vim.fn.strcharpart(author, 0, 20),
				row.text
			)
		end
		p.show(lines)
		api.nvim_win_set_cursor(p.win, { c.line, 0 })
		p.map("p", function()
			local row = rows[api.nvim_win_get_cursor(p.win)[1]]
			if row then
				local selected = vim.tbl_extend("force", c, { line = row.line })
				pull_requests(selected, row)
			end
		end, "Show selected line's PR links")
		p.map("<CR>", function()
			local row = api.nvim_win_get_cursor(p.win)[1]
			if not rows[row] then
				return
			end
			if
				not api.nvim_win_is_valid(c.win)
				or api.nvim_win_get_buf(c.win) ~= c.buf
				or api.nvim_buf_get_changedtick(c.buf) ~= c.tick
			then
				return vim.notify("Source changed; run :git blame again", vim.log.levels.WARN)
			end
			p.close()
			api.nvim_set_current_win(c.win)
			api.nvim_win_set_cursor(c.win, { row, 0 })
		end, "Return to source line")
	end)
end

local function clear_inline()
	generation = generation + 1
	if inline_buf and api.nvim_buf_is_valid(inline_buf) then
		api.nvim_buf_clear_namespace(inline_buf, inline, 0, -1)
	end
	inline_buf = nil
end

local function update_inline()
	if not inline_enabled then
		return
	end
	clear_inline()
	local ok, c = pcall(context)
	if not ok then
		return
	end
	local token = generation
	blame(c, false, function(rows, err)
		if
			token ~= generation
			or not inline_enabled
			or not api.nvim_win_is_valid(c.win)
			or api.nvim_get_current_win() ~= c.win
			or api.nvim_get_current_buf() ~= c.buf
			or api.nvim_buf_get_changedtick(c.buf) ~= c.tick
			or api.nvim_win_get_cursor(c.win)[1] ~= c.line
		then
			return
		end
		if err then
			inline_enabled = false
			return vim.notify(err, vim.log.levels.WARN)
		end
		api.nvim_buf_set_extmark(c.buf, inline, c.line - 1, 0, {
			virt_text = { { "  " .. vim.fn.strtrans(description(rows[c.line])), "Comment" } },
			virt_text_pos = "eol",
			hl_mode = "combine",
		})
		inline_buf = c.buf
	end)
end

function M.toggle_inline()
	inline_enabled = not inline_enabled
	clear_inline()
	update_inline()
	vim.notify("Git inline blame " .. (inline_enabled and "enabled" or "disabled"))
end

function M.setup()
	local group = api.nvim_create_augroup("rediff-inline-blame", { clear = true })
	api.nvim_create_autocmd(
		{ "CursorMoved", "CursorMovedI", "BufLeave", "TextChanged", "TextChangedI", "InsertEnter" },
		{ group = group, callback = clear_inline }
	)
	api.nvim_create_autocmd("CursorHold", { group = group, callback = update_inline })
	api.nvim_create_autocmd("VimEnter", {
		group = group,
		callback = function()
			vim.schedule(update_inline)
		end,
	})
end

return M
