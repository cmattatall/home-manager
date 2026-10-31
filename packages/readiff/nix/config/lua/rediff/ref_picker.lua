local M = {}
local api = vim.api
local endpoints = api.nvim_create_namespace("rediff.ref-endpoints")
local browsing = api.nvim_create_namespace("rediff.ref-browsing")
local decoration = api.nvim_create_namespace("rediff.ref-decoration")
local active

local function write(buf, lines)
	vim.bo[buf].modifiable = true
	api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
end

local function fit(text, width)
	text = vim.fn.strtrans(text)
	if vim.fn.strdisplaywidth(text) > width then
		text = vim.fn.strcharpart(text, 0, width - 1)
		while vim.fn.strdisplaywidth(text) > width - 1 do
			text = vim.fn.strcharpart(text, 0, vim.fn.strchars(text) - 1)
		end
		text = text .. "…"
	end
	return text .. string.rep(" ", math.max(0, width - vim.fn.strdisplaywidth(text)))
end

function M.open(root, opts)
	if active then
		active()
	end
	if vim.o.columns < 80 or vim.o.lines < 24 then
		vim.notify("The ref picker needs at least 80 columns and 24 lines", vim.log.levels.WARN)
		return
	end
	local comparison = vim.deepcopy(opts.comparison)
	comparison.pr = nil
	local source_win = api.nvim_get_current_win()
	local windows, buffers, jobs = {}, {}, {}
	local commits, rows, matches = {}, {}, {}
	local selected, graph_width, lane_width = nil, 0, 6
	local panel_width, sidebar_width = 0, 0
	local closed, loading = false, true
	local group = api.nvim_create_augroup("rediff.ref-picker", { clear = true })

	local function close()
		if closed then
			return
		end
		closed = true
		active = nil
		vim.cmd.stopinsert()
		api.nvim_del_augroup_by_id(group)
		for job in pairs(jobs) do
			if not job:is_closing() then
				job:kill(15)
			end
		end
		for _, win in pairs(windows) do
			if api.nvim_win_is_valid(win) then
				api.nvim_win_close(win, true)
			end
		end
		for _, buf in pairs(buffers) do
			if api.nvim_buf_is_valid(buf) then
				api.nvim_buf_delete(buf, { force = true })
			end
		end
		if api.nvim_win_is_valid(source_win) then
			api.nvim_set_current_win(source_win)
		end
	end
	active = close

	api.nvim_set_hl(0, "RediffRefBase", { fg = "#f6c177", bg = "#393126" })
	api.nvim_set_hl(0, "RediffRefTarget", { fg = "#9ccfd8", bg = "#23353e" })
	api.nvim_set_hl(0, "RediffRefBrowse", { underline = true, sp = "#c4a7e7" })
	api.nvim_set_hl(0, "RediffRefBaseLabel", { fg = "#191724", bg = "#f6c177", bold = true })
	api.nvim_set_hl(0, "RediffRefTargetLabel", { fg = "#191724", bg = "#9ccfd8", bold = true })
	api.nvim_set_hl(0, "RediffRefTitle", { fg = "#c4a7e7", bold = true })
	api.nvim_set_hl(0, "RediffRefMuted", { fg = "#908caa" })
	api.nvim_set_hl(0, "RediffRefGraph", { fg = "#b3adc8" })
	api.nvim_set_hl(0, "RediffRefChip", { fg = "#c4a7e7", bg = "#26233a" })
	api.nvim_set_hl(0, "RediffRefMatch", { bg = "#302e45" })
	api.nvim_set_hl(0, "RediffRefSurface", { bg = "#191724", fg = "#e0def4" })
	api.nvim_set_hl(0, "RediffRefBorder", { bg = "#191724", fg = "#524f67" })

	local function highlight(buf, row, start, finish, group)
		api.nvim_buf_set_extmark(buf, decoration, row, start, {
			end_col = finish,
			hl_group = group,
			priority = 90,
		})
	end

	local function pane(name, title, row, col, width, height)
		local config = {
			relative = "editor",
			row = row,
			col = col,
			width = width,
			height = height,
			style = "minimal",
			border = "single",
			title = title ~= "" and " " .. title .. " " or nil,
			zindex = 60,
		}
		if name == "results" or name == "details" then
			config.border, config.title = "none", nil
			config.zindex = 61
		elseif name == "search" or name == "apply" then
			config.zindex = 62
		end
		if name == "background" then
			config.border, config.title = "none", nil
			config.zindex, config.focusable = 59, false
		end
		if windows[name] then
			api.nvim_win_set_config(windows[name], config)
			return
		end
		local buf = api.nvim_create_buf(false, true)
		buffers[name] = buf
		vim.bo[buf].filetype = "rediff-ref-" .. name
		windows[name] = api.nvim_open_win(buf, false, config)
		vim.wo[windows[name]].wrap = false
		vim.wo[windows[name]].cursorline = false
		vim.wo[windows[name]].scrolloff = 2
		vim.wo[windows[name]].winhighlight = "Normal:RediffRefSurface,NormalFloat:RediffRefSurface,"
			.. "FloatBorder:RediffRefBorder,FloatTitle:RediffRefTitle,WinBar:RediffRefSurface,WinBarNC:RediffRefSurface"
	end

	local function layout()
		panel_width = math.min(176, vim.o.columns - 6)
		local height = math.min(44, vim.o.lines - 3)
		local top = math.max(1, math.floor((vim.o.lines - height) / 2))
		local left = math.floor((vim.o.columns - panel_width - 2) / 2)
		sidebar_width = math.max(26, math.floor(panel_width * 0.29))
		graph_width = panel_width - sidebar_width - 3
		local content_row = top + 5
		local content_height = height - 10
		local results_height = math.max(3, math.min(#matches * 3, math.floor(content_height * 0.3)))
		pane("background", "", 0, 0, vim.o.columns, vim.o.lines - 1)
		pane("header", "", top, left, panel_width, 3)
		pane("apply", "", top + 1, left + panel_width - 14, 12, 1)
		pane("sidebar", "Find commits", content_row, left, sidebar_width, content_height)
		pane("search", "", content_row + 2, left + 2, sidebar_width - 4, 1)
		pane("results", "", content_row + 6, left + 2, sidebar_width - 2, results_height)
		pane(
			"details",
			"",
			content_row + results_height + 7,
			left + 2,
			sidebar_width - 2,
			math.max(2, content_height - results_height - 6)
		)
		pane(
			"graph",
			"History · all refs · " .. #commits .. " commits",
			content_row,
			left + sidebar_width + 3,
			graph_width,
			content_height
		)
		pane("footer", "", top + height - 3, left, panel_width, 1)
		vim.wo[windows.results].winbar = "%#RediffRefMuted#" .. #matches .. " matches"
		vim.wo[windows.details].winbar = "%#RediffRefTitle#Selected commit"
		local hint = sidebar_width >= 32 and "Type to filter · =ref for exact" or "Fuzzy search / =ref"
		write(buffers.sidebar, { " " .. hint })
		api.nvim_buf_clear_namespace(buffers.sidebar, decoration, 0, -1)
		highlight(buffers.sidebar, 0, 0, #hint + 1, "RediffRefMuted")
		local keys = " Ctrl-b base  Ctrl-t target  Ctrl-y compare  Tab switch  Esc cancel"
		if panel_width >= 100 then
			keys = " Enter reveal · Ctrl-b base · Ctrl-t target · Ctrl-y compare · Tab graph/search · Esc cancel"
		end
		write(buffers.footer, { keys })
	end
	layout()

	local function run(args, done)
		local argv = { "git", "--no-pager", "-C", root }
		vim.list_extend(argv, args)
		local job
		job = vim.system(
			argv,
			{ text = false, timeout = 30000 },
			vim.schedule_wrap(function(result)
				jobs[job] = nil
				if not closed then
					done(result)
				end
			end)
		)
		jobs[job] = true
	end

	local function paint_endpoints()
		local function label(sha, ref)
			if not sha then
				return "Working files"
			end
			if not ref or vim.startswith(sha, ref) then
				return sha:sub(1, 8)
			end
			return ref .. " · " .. sha:sub(1, 8)
		end
		local half = math.min(55, math.floor((panel_width - 19) / 2))
		local base_badge = panel_width >= 100 and " OLD / BASE " or " BASE "
		local target_badge = panel_width >= 100 and " NEW / TARGET " or " TARGET "
		local base = fit(base_badge .. " " .. label(comparison.base, comparison.base_ref), half)
		local target = fit(target_badge .. " " .. label(comparison.head, comparison.head_ref), half)
		write(buffers.header, { "", " " .. base .. " → " .. target, "" })
		api.nvim_buf_clear_namespace(buffers.header, endpoints, 0, -1)
		api.nvim_buf_set_extmark(buffers.header, endpoints, 1, 1, {
			end_col = 1 + #base_badge,
			hl_group = "RediffRefBaseLabel",
		})
		local target_start = 1 + #base + #" → "
		api.nvim_buf_set_extmark(buffers.header, endpoints, 1, target_start, {
			end_col = target_start + #target_badge,
			hl_group = "RediffRefTargetLabel",
		})
		api.nvim_buf_clear_namespace(buffers.graph, endpoints, 0, -1)
		for _, commit in ipairs(commits) do
			local is_base, is_target = commit.sha == comparison.base, commit.sha == comparison.head
			if is_base or is_target then
				local highlight = is_base and "RediffRefBase" or "RediffRefTarget"
				api.nvim_buf_set_extmark(buffers.graph, endpoints, commit.row - 1, 0, {
					end_row = commit.row,
					hl_group = highlight,
					hl_eol = true,
					priority = 110,
				})
				if is_base and is_target then
					local line = api.nvim_buf_get_lines(buffers.graph, commit.row - 1, commit.row, false)[1]
					local middle = #vim.fn.strcharpart(line, 0, math.floor(vim.fn.strchars(line) / 2))
					api.nvim_buf_set_extmark(buffers.graph, endpoints, commit.row - 1, middle, {
						end_row = commit.row,
						hl_group = "RediffRefTarget",
						hl_eol = true,
						priority = 111,
					})
				end
			end
		end
	end

	local function render_graph()
		local lines = {}
		local author_width = graph_width >= 100 and 16 or 9
		local ref_width = graph_width >= 80 and 18 or 0
		local date_width = graph_width >= 65 and 11 or 0
		local subject_width = math.max(8, graph_width - lane_width - author_width - ref_width - date_width - 12)
		vim.wo[windows.graph].winbar = "%#RediffRefMuted# "
			.. fit("Graph", lane_width)
			.. fit("SHA", 10)
			.. (ref_width > 0 and fit("Refs", ref_width) or "")
			.. fit("Subject", subject_width)
			.. " "
			.. fit("Author", author_width)
			.. (date_width > 0 and " Date" or "")
		local glyphs = { ["*"] = "●", ["|"] = "│", ["/"] = "╱", ["\\"] = "╲", ["_"] = "─", ["-"] = "─" }
		local fields = {}
		for _, row in ipairs(rows) do
			local graph = row.graph:gsub("[*|/\\_%-]", glyphs)
			if row.sha then
				local prefix = " " .. fit(graph, lane_width)
				local refs = ""
				if ref_width > 0 then
					local names = row.refs ~= "" and row.refs:gsub("HEAD %-> ", "") or "—"
					refs = fit(names, ref_width - 2) .. "  "
				end
				local identity = prefix .. fit(row.short, 10)
				local subject = identity .. refs .. fit(row.subject, subject_width) .. " "
				table.insert(
					lines,
					subject .. fit(row.author, author_width) .. (date_width > 0 and " " .. row.date or "")
				)
				table.insert(fields, {
					row = #lines - 1,
					graph = #prefix,
					refs = #identity,
					subject = #identity + #refs,
					author = #subject,
					ref_highlight = row.refs ~= "" and "RediffRefChip" or "RediffRefMuted",
				})
			else
				table.insert(lines, " " .. graph)
			end
		end
		write(buffers.graph, #lines > 0 and lines or { loading and "Loading history…" or "No commits" })
		api.nvim_buf_clear_namespace(buffers.graph, decoration, 0, -1)
		for index, line in ipairs(lines) do
			highlight(buffers.graph, index - 1, 0, #line, "RediffRefGraph")
		end
		for _, field in ipairs(fields) do
			highlight(buffers.graph, field.row, field.graph, field.refs, "RediffRefMuted")
			if ref_width > 0 then
				highlight(buffers.graph, field.row, field.refs, field.subject - 2, field.ref_highlight)
			end
			highlight(buffers.graph, field.row, field.subject, field.author, "RediffRefSurface")
			highlight(buffers.graph, field.row, field.author, #lines[field.row + 1], "RediffRefMuted")
		end
		paint_endpoints()
	end

	local function select_commit(commit)
		selected = commit
		api.nvim_buf_clear_namespace(buffers.graph, browsing, 0, -1)
		api.nvim_buf_clear_namespace(buffers.results, browsing, 0, -1)
		if not commit then
			write(buffers.details, { "No matching commit" })
			return
		end
		for index, match in ipairs(matches) do
			if match.sha == commit.sha then
				local first_row = (index - 1) * 3
				api.nvim_buf_set_extmark(buffers.results, browsing, first_row, 0, {
					end_row = first_row + 2,
					hl_group = "RediffRefMatch",
					hl_eol = true,
				})
				api.nvim_win_set_cursor(windows.results, { first_row + 1, 0 })
				break
			end
		end
		api.nvim_buf_set_extmark(buffers.graph, browsing, commit.row - 1, 0, {
			end_row = commit.row,
			hl_group = "RediffRefBrowse",
			hl_eol = true,
			priority = 120,
		})
		api.nvim_win_set_cursor(windows.graph, { commit.row, 0 })
		local details = {
			"SHA     " .. commit.short,
			"Author  " .. commit.author .. " <" .. commit.email .. ">",
			"Date    " .. commit.date,
			"Refs    " .. (commit.refs ~= "" and commit.refs or "—"),
			"Subject " .. commit.subject,
			"",
			"Loading files…",
		}
		write(buffers.details, details)
		run(
			{ "show", "--format=", "--name-status", "-z", "--no-renames", "--no-ext-diff", commit.sha, "--" },
			function(result)
				if selected ~= commit then
					return
				end
				local files = vim.split(result.stdout or "", "\0", { trimempty = true })
				details[7] = result.code == 0 and ("Changed files (" .. #files / 2 .. ")") or "Could not load files"
				for index = 1, #files, 2 do
					table.insert(details, files[index] .. "  " .. vim.fn.strtrans(files[index + 1]))
				end
				write(buffers.details, details)
				api.nvim_buf_clear_namespace(buffers.details, decoration, 0, -1)
				for row = 0, 4 do
					highlight(buffers.details, row, 0, 7, "RediffRefMuted")
				end
				highlight(buffers.details, 0, 8, #details[1], "RediffRefTarget")
				highlight(buffers.details, 6, 0, #details[7], "RediffRefTitle")
				for row = 7, #details - 1 do
					highlight(buffers.details, row, 0, 1, "RediffRefBase")
				end
			end
		)
	end

	local filter
	local function load_history(extra)
		loading = true
		local args = {
			"log",
			"--all",
			"--graph",
			"--topo-order",
			"--color=never",
			"--no-show-signature",
			"--no-notes",
			"--date=short",
			"--decorate=short",
			"--abbrev=8",
			"--format=%x00%H%x00%h%x00%an%x00%ad%x00%D%x00%s%x00%ae%n",
			comparison.base,
		}
		if comparison.head then
			table.insert(args, comparison.head)
		end
		if extra then
			table.insert(args, extra)
		end
		table.insert(args, "--")
		run(args, function(result)
			loading = false
			if result.code ~= 0 then
				write(buffers.graph, { "Could not load history", vim.fn.strtrans(result.stderr or "Git failed") })
				return
			end
			commits, rows, lane_width = {}, {}, 6
			for _, line in ipairs(vim.split(result.stdout, "\n", { trimempty = true })) do
				local fields = vim.split(line, "\0", { plain = true })
				local row = { graph = fields[1] }
				lane_width = math.max(lane_width, #row.graph)
				if fields[2] then
					row.sha, row.short = fields[2], fields[3]
					row.author, row.date = vim.fn.strtrans(fields[4]), fields[5]
					row.refs, row.subject = vim.fn.strtrans(fields[6]), vim.fn.strtrans(fields[7])
					row.email = vim.fn.strtrans(fields[8])
					row.search = table.concat({ row.sha, row.author, row.date, row.refs, row.subject }, " ")
					row.row = #rows + 1
					table.insert(commits, row)
				end
				table.insert(rows, row)
			end
			render_graph()
			filter()
		end)
	end

	local function show_matches(found, selection)
		matches = found
		layout()
		local lines = {}
		for _, commit in ipairs(matches) do
			table.insert(lines, fit(commit.short .. " " .. commit.subject, sidebar_width - 2))
			table.insert(lines, fit("  " .. commit.author .. " · " .. commit.date, sidebar_width - 2))
			table.insert(lines, "")
		end
		write(buffers.results, #lines > 0 and lines or { loading and "Loading history…" or "No matches" })
		api.nvim_buf_clear_namespace(buffers.results, decoration, 0, -1)
		for index = 1, #lines, 3 do
			highlight(buffers.results, index - 1, 0, 8, "RediffRefTitle")
			highlight(buffers.results, index, 0, #lines[index + 1], "RediffRefMuted")
		end
		local title = #matches == 1 and "1 match" or (#matches .. " matches")
		vim.wo[windows.results].winbar = "%#RediffRefMuted#" .. title
		api.nvim_win_set_cursor(windows.results, { 1, 0 })
		select_commit(selection or matches[1])
	end

	filter = function()
		local query = api.nvim_buf_get_lines(buffers.search, 0, 1, false)[1] or ""
		if query:sub(1, 1) ~= "=" then
			show_matches(query == "" and commits or vim.fn.matchfuzzy(commits, query, { key = "search" }))
			return
		end
		show_matches({})
		run({ "rev-parse", "--verify", "--end-of-options", query:sub(2) .. "^{commit}" }, function(result)
			if api.nvim_buf_get_lines(buffers.search, 0, 1, false)[1] ~= query then
				return
			end
			local sha = vim.trim(result.stdout or "")
			for _, commit in ipairs(commits) do
				if commit.sha == sha then
					show_matches({ commit })
					return
				end
			end
			if result.code == 0 then
				load_history(sha)
			else
				show_matches({})
			end
		end)
	end

	local function assign(endpoint)
		if not selected then
			return
		end
		if endpoint == "head" and opts.worktree then
			vim.notify(":git base compares against working files. Use :git diff to select two commits")
			return
		end
		comparison[endpoint], comparison[endpoint .. "_ref"] = selected.sha, selected.short
		paint_endpoints()
	end

	local function apply()
		close()
		opts.on_select(comparison)
	end

	local function search()
		api.nvim_set_current_win(windows.search)
		-- Queue after the terminal picker's pending mode change when opened from fzf.
		local keys = api.nvim_replace_termcodes("<Cmd>startinsert<CR>", true, false, true)
		api.nvim_feedkeys(keys, "n", false)
	end

	local function reveal()
		vim.cmd.stopinsert()
		api.nvim_set_current_win(windows.graph)
	end

	local function move_match(delta)
		local index = math.floor((api.nvim_win_get_cursor(windows.results)[1] - 1) / 3) + 1
		index = math.max(1, math.min(#matches, index + delta))
		select_commit(matches[index])
	end

	local function move_graph(delta)
		local row = api.nvim_win_get_cursor(windows.graph)[1] + delta
		while rows[row] do
			if rows[row].sha then
				select_commit(rows[row])
				return
			end
			row = row + delta
		end
	end

	for name, buf in pairs(buffers) do
		local function map(modes, key, action)
			vim.keymap.set(modes, key, action, { buffer = buf, nowait = true, silent = true })
		end
		map({ "n", "i" }, "<Esc>", close)
		map("n", "q", close)
		map({ "n", "i" }, "<C-b>", function()
			assign("base")
		end)
		map({ "n", "i" }, "<C-t>", function()
			assign("head")
		end)
		map({ "n", "i" }, "<C-y>", apply)
		map("n", "/", search)
		map({ "n", "i" }, "<Tab>", function()
			if api.nvim_get_current_win() == windows.graph then
				search()
			else
				reveal()
			end
		end)
		map({ "n", "i" }, "<CR>", name == "apply" and apply or reveal)
		if name == "apply" then
			map({ "n", "i" }, "<LeftRelease>", apply)
		end
		if name == "graph" or name == "results" then
			local move = name == "graph" and move_graph or move_match
			for _, key in ipairs({ "j", "<Down>" }) do
				map("n", key, function()
					move(1)
				end)
			end
			for _, key in ipairs({ "k", "<Up>" }) do
				map("n", key, function()
					move(-1)
				end)
			end
		end
		if name == "search" then
			map({ "n", "i" }, "<Down>", function()
				move_match(1)
			end)
			map({ "n", "i" }, "<Up>", function()
				move_match(-1)
			end)
			map({ "n", "i" }, "<C-n>", function()
				move_match(1)
			end)
			map({ "n", "i" }, "<C-p>", function()
				move_match(-1)
			end)
		end
	end
	api.nvim_create_autocmd(
		{ "TextChangedI", "TextChanged" },
		{ group = group, buffer = buffers.search, callback = filter }
	)
	api.nvim_create_autocmd("CursorMoved", {
		group = group,
		buffer = buffers.graph,
		callback = function()
			local row = rows[api.nvim_win_get_cursor(windows.graph)[1]]
			if row and row.sha and row ~= selected then
				select_commit(row)
			end
		end,
	})
	api.nvim_create_autocmd("CursorMoved", {
		group = group,
		buffer = buffers.results,
		callback = function()
			local index = math.floor((api.nvim_win_get_cursor(windows.results)[1] - 1) / 3) + 1
			local commit = matches[index]
			if commit ~= selected then
				select_commit(commit)
			end
		end,
	})
	api.nvim_create_autocmd("VimResized", {
		group = group,
		callback = function()
			if vim.o.columns < 80 or vim.o.lines < 24 then
				close()
			else
				layout()
				render_graph()
				show_matches(matches, selected)
			end
		end,
	})
	api.nvim_create_autocmd({ "TabLeave", "DirChanged" }, { group = group, callback = close })
	api.nvim_create_autocmd("WinClosed", {
		group = group,
		callback = function(event)
			for _, win in pairs(windows) do
				if tonumber(event.match) == win then
					close()
					return
				end
			end
		end,
	})
	write(buffers.apply, { "  Compare   " })
	highlight(buffers.apply, 0, 0, 12, "RediffRefTitle")
	write(buffers.search, { "" })
	vim.bo[buffers.search].modifiable = true
	vim.wo[windows.details].wrap = true
	vim.wo[windows.details].linebreak = true
	vim.wo[windows.details].breakindent = true
	vim.wo[windows.details].breakindentopt = "shift:8"
	render_graph()
	load_history()
	vim.schedule(function()
		if not closed then
			search()
		end
	end)
end

return M
