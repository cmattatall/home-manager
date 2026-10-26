local M = { state = nil }
local api = vim.api
local git = require("rediff.git")
local feedback = require("rediff.feedback")
local harness = require("rediff.harness")
local selection = require("rediff.selection")
local awareness = require("rediff.awareness")
local tree_ns = api.nvim_create_namespace("rediff.tree")
local active_ns = api.nvim_create_namespace("rediff.active-file")
local hunk_ns = api.nvim_create_namespace("rediff.hunk")
local annotation_ns = api.nvim_create_namespace("rediff.annotations")
local composer_ns = api.nvim_create_namespace("rediff.composer")
local reviews = {} -- Pending annotations belong to this editor process, not the next launch.
local saved_guicursor
local status_highlights = {
	A = "ReviewAdded",
	M = "ReviewModified",
	U = "ReviewUntracked",
	D = "ReviewDeleted",
	R = "ReviewRenamed",
}

local function highlight_tree_selection(s)
	local cursor = api.nvim_win_get_cursor(s.tree_win)[1]
	local focused = vim.wo[s.tree_win].cursorline
	for group, row in pairs(s.group_rows or {}) do
		local highlight = group == "staged" and "ReviewStaged" or "ReviewUnstaged"
		if focused and cursor == row then
			highlight = "ReviewTreeSelection"
		end
		-- Header backgrounds override CursorLine, including on closed folds.
		api.nvim_buf_set_extmark(s.tree_buf, tree_ns, row - 1, 0, { id = row, line_hl_group = highlight })
	end
	api.nvim_buf_clear_namespace(s.tree_buf, active_ns, 0, -1)
	-- The preview marker is context for diff focus, not a second tree selection.
	if not focused and s.current then
		for row, index in pairs(s.rows) do
			if index == s.index then
				api.nvim_buf_set_extmark(s.tree_buf, active_ns, row - 1, 0, { line_hl_group = "ReviewActiveFile" })
				break
			end
		end
	end
end

local function tree_focus(focused)
	local s = M.state
	if s and s.tree_win and api.nvim_win_is_valid(s.tree_win) then
		vim.wo[s.tree_win].cursorline = focused
		highlight_tree_selection(s)
	end
	if focused then
		saved_guicursor = saved_guicursor or vim.o.guicursor
		vim.o.guicursor = (saved_guicursor ~= "" and saved_guicursor .. "," or "") .. "n:ver1-ReviewTreeCursor-blinkon0"
	elseif saved_guicursor then
		vim.o.guicursor = saved_guicursor
		saved_guicursor = nil
	end
end

local function notify(message, level)
	vim.notify(message, level or vim.log.levels.INFO, { title = "rediff" })
end

local function guard(fn)
	return function(...)
		local ok, err = pcall(fn, ...)
		if not ok then
			notify(tostring(err), vim.log.levels.ERROR)
		end
	end
end

local function state()
	return assert(M.state, "Enter Review with <leader>r first")
end

function M.active()
	return M.state and api.nvim_get_current_tabpage() == M.state.tab and M.state or nil
end

-- Annotation operations work on either a Review pane or a protected file buffer.
local function annotation_state()
	return assert(M.active() or require("rediff.annotations").context(), "Enable annotation mode with Space a first")
end

function M.notes(root)
	if not reviews[root] then
		reviews[root] = {
			root = root,
			directory = feedback.directory(root),
			comments = {},
			drafts = {},
			snapshots = {},
			annotation_status = {},
			harness = harness.get(root).target,
		}
	end
	return reviews[root]
end

local function annotation_key(anchor)
	local spans = anchor.selection.spans
	return table.concat({ anchor.snapshot_id, anchor.side, spans[1].line, spans[#spans].line }, ":")
end

local function annotation_changed(s, anchor)
	return M.notes(s.root).annotation_status[annotation_key(anchor)] == "changed"
end

local function composer_title(s)
	local anchor = s.draft.anchor
	local spans = anchor.selection.spans
	local first, last = spans[1].line, spans[#spans].line
	local title = {
		{
			" Note · " .. first .. (last ~= first and "–" .. last or "") .. " · " .. anchor.side .. " ",
			"ReviewAnnotation",
		},
	}
	if annotation_changed(s, anchor) then
		table.insert(title, { "◆ (changed since annotated) ", "ReviewAnnotationChanged" })
	end
	return title
end

-- File views and Review retain the same collections across mode transitions.
local function retain(items, predicate)
	for i = #items, 1, -1 do
		if not predicate(items[i]) then
			table.remove(items, i)
		end
	end
end

local function entry_key(entry)
	return entry.group
		.. "\0"
		.. entry.path
		.. (entry.group == "branch" and ("\0" .. entry.base .. "\0" .. entry.head) or "")
end

local function tree_group(entry)
	return entry.group == "untracked" and "unstaged" or entry.group
end

local function save(s)
	s = s or annotation_state()
	feedback.write(s.directory .. "/draft.json", {
		harness = s.harness,
	})
end

local function map(buf, mode, key, fn, description)
	vim.keymap.set(mode, key, guard(fn), { buffer = buf, desc = description })
end

local function map_staging(buf)
	if buf ~= state().tree_buf then
		map(buf, "n", "s", function()
			M.stage(false)
		end, "Stage/unstage Git hunk at cursor")
		map(buf, "n", "r", function()
			M.revert()
		end, "Revert Git hunk at cursor")
		map(buf, "x", "r", function()
			local region = selection.capture(buf, vim.fn.mode(), vim.fn.getpos("v"), vim.fn.getpos("."))
			vim.cmd.normal({ args = { api.nvim_replace_termcodes("<Esc>", true, false, true) }, bang = true })
			M.revert(region.spans[1].line, region.spans[#region.spans].line)
		end, "Revert selected Git hunks")
	end
	map(buf, "n", "S", function()
		M.stage(true)
	end, "Stage/unstage entire file")
end

local function map_hunks(buf)
	for key, direction in pairs({ ["]"] = 1, ["["] = -1 }) do
		-- Updating a mapping in place retains its old precedence.
		pcall(vim.keymap.del, "n", key, { buffer = buf })
		vim.keymap.set(
			"n",
			key,
			guard(function()
				for _ = 1, vim.v.count1 do
					M.jump_hunk(direction)
				end
			end),
			{
				buffer = buf,
				nowait = true,
				desc = direction > 0 and "Next hunk in Git group" or "Previous hunk in Git group",
			}
		)
	end
	for key, direction in pairs({ ["<C-S-]>"] = 1, ["<C-S-[>"] = -1 }) do
		map(buf, "n", key, function()
			for _ = 1, vim.v.count1 do
				M.jump_hunk(direction, true)
			end
		end, direction > 0 and "Next unseen hunk in Git group" or "Previous unseen hunk in Git group")
	end
end

local function reject_write()
	error("Review buffers do not write files. Use :w for feedback, or :ReviewOutbox for exports.")
end

local function owned_buffer(name, lines, editable)
	local buf = api.nvim_create_buf(false, true)
	api.nvim_buf_set_name(buf, name)
	vim.bo[buf].buftype = "acwrite"
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].swapfile = false
	vim.bo[buf].undofile = false
	vim.bo[buf].readonly = false
	local undo_levels = vim.bo[buf].undolevels
	vim.bo[buf].undolevels = -1
	api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].undolevels = undo_levels
	vim.bo[buf].modified = false
	vim.bo[buf].modifiable = editable or false
	api.nvim_create_autocmd("BufWriteCmd", {
		buffer = buf,
		callback = function(event)
			if event.match ~= api.nvim_buf_get_name(buf) then
				reject_write()
			end
			if editable then
				M.save_composer()
				local win = annotation_state().composer_win
				-- Defer closing so :wq can finish without closing a source pane too.
				vim.schedule(function()
					if api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == buf then
						api.nvim_win_close(win, true)
					end
				end)
			else
				M.submit()
			end
			if api.nvim_buf_is_valid(buf) then
				vim.bo[buf].modified = false
			end
		end,
	})
	api.nvim_create_autocmd({ "FileWriteCmd", "FileAppendCmd", "FilterWritePre" }, {
		buffer = buf,
		callback = reject_write,
	})
	return buf
end

local function set_lines(buf, lines)
	vim.bo[buf].modifiable = true
	api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modified = false
	vim.bo[buf].modifiable = false
end

local function wrap_comment(text, width)
	local lines = {}
	for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
		line = vim.fn.strtrans(line)
		while vim.fn.strdisplaywidth(line) > width do
			local count = 1
			while vim.fn.strdisplaywidth(vim.fn.strcharpart(line, 0, count + 1)) <= width do
				count = count + 1
			end
			table.insert(lines, vim.fn.strcharpart(line, 0, count))
			line = vim.fn.strcharpart(line, count)
		end
		table.insert(lines, line)
	end
	return lines
end

local function opposite_line(line, side, changes)
	local offset = 0
	for _, change in ipairs(changes) do
		local source = change[side == "old" and "original" or "modified"]
		local target = change[side == "old" and "modified" or "original"]
		if line < source.start_line then
			break
		end
		if line < source.end_line then
			return target.start_line + math.min(line - source.start_line, target.end_line - target.start_line - 1)
		end
		offset = target.end_line - source.end_line
	end
	return line + offset
end

local function side_at_cursor()
	local s = annotation_state()
	local buf = api.nvim_get_current_buf()
	assert(buf == s.old_buf or buf == s.new_buf, "Focus a source pane first")
	return buf == s.old_buf and "old" or "new", buf
end

local function comments_at_cursor()
	local s = annotation_state()
	local side, line = side_at_cursor(), api.nvim_win_get_cursor(0)[1]
	local matches = {}
	for _, comment in ipairs(s.comments) do
		if
			s.current
			and comment.snapshot_id == s.current.id
			and comment.side == side
			and comment.line <= line
			and comment.line_end >= line
		then
			table.insert(matches, comment)
		end
	end
	return matches
end

local function render_tree_annotations(s)
	api.nvim_buf_clear_namespace(s.tree_buf, annotation_ns, 0, -1)
	local annotated = {}
	for _, comment in ipairs(s.comments) do
		annotated[comment.file] = annotated[comment.file] == "changed" and "changed"
			or (annotation_changed(s, comment) and "changed" or "current")
	end
	for row, index in pairs(s.rows) do
		local status = annotated[s.entries[index].path]
		if status then
			api.nvim_buf_set_extmark(s.tree_buf, annotation_ns, row - 1, 0, {
				virt_text = {
					{
						status == "changed" and "◆" or "●",
						status == "changed" and "ReviewAnnotationChanged" or "ReviewAnnotation",
					},
				},
				virt_text_pos = "right_align",
				hl_mode = "combine",
			})
		end
	end
end

local function render_comments(selection_only, s)
	s = s or annotation_state()
	if not selection_only and s.tree_buf then
		render_tree_annotations(s)
	end
	local selected = {}
	local buf = api.nvim_get_current_buf()
	if (M.active() == s or require("rediff.annotations").active() == s) and (buf == s.old_buf or buf == s.new_buf) then
		for _, comment in ipairs(comments_at_cursor()) do
			selected[comment.id] = true
			if comment.id == s.annotation_id then
				selected = { [comment.id] = true }
				break
			end
		end
	end
	if selection_only and vim.deep_equal(selected, s.cursor_comments) then
		return
	end
	s.cursor_comments = selected
	for _, buf in pairs({ s.old_buf, s.new_buf }) do
		api.nvim_buf_clear_namespace(buf, annotation_ns, 0, -1)
	end
	if not s.current or not api.nvim_win_is_valid(s.new_win) then
		return
	end
	local function place(buf, line, lines, priority, leftcol)
		api.nvim_buf_set_extmark(buf, annotation_ns, math.max(0, math.min(line, api.nvim_buf_line_count(buf)) - 1), 0, {
			virt_lines = lines,
			virt_lines_above = line < 1,
			virt_lines_leftcol = leftcol or false,
			priority = priority,
		})
	end
	for i, comment in ipairs(s.comments) do
		if comment.snapshot_id == s.current.id and (comment.side ~= "old" or s.old_win) then
			local old = comment.side == "old"
			local win = old and s.old_win or s.new_win
			local active = selected[comment.id]
			local gutter = vim.fn.getwininfo(win)[1].textoff
			gutter = active and math.max(3, gutter) or gutter
			local width = math.max(1, api.nvim_win_get_width(win) - gutter - 2)
			local lines, padding = {}, {}
			for row, text in ipairs(wrap_comment(comment.text, width)) do
				lines[row] = { { (row == 1 and "● " or "  ") .. text, "ReviewAnnotation" } }
				if active then
					table.insert(lines[row], 1, {
						row == 1 and string.rep(" ", gutter - 3) .. ">> " or string.rep(" ", gutter),
						"ReviewAnnotation",
					})
				end
				padding[row] = {}
			end
			if annotation_changed(s, comment) then
				local badge = wrap_comment("◆ (changed since annotated)", width)
				for row = #badge, 1, -1 do
					table.insert(
						lines,
						1,
						{ { (active and string.rep(" ", gutter) or "") .. badge[row], "ReviewAnnotationChanged" } }
					)
					table.insert(padding, 1, {})
				end
			end
			place(old and s.old_buf or s.new_buf, comment.line_end, lines, 250 + i, active)
			if s.old_win then
				place(
					old and s.new_buf or s.old_buf,
					opposite_line(comment.line_end, comment.side, s.diff.changes),
					padding,
					250 + i
				)
			end
		end
	end
	if s.composer_win and api.nvim_win_is_valid(s.composer_win) then
		api.nvim_win_set_config(s.composer_win, { title = composer_title(s) })
	end
	vim.cmd.redrawstatus()
end

M.render_comments = render_comments

-- Freshness belongs to the annotation, not to the full immutable file snapshot.
-- Keep it out of comments so a status change cannot alter feedback identity.
function M.refresh_annotations(root)
	local notes = M.notes(root)
	local current, by_file, statuses = {}, {}, {}
	local anchors = vim.list_slice(notes.comments)
	for _, draft in ipairs(notes.drafts) do
		table.insert(anchors, draft.anchor)
	end
	for _, anchor in ipairs(anchors) do
		local snapshot = assert(notes.snapshots[anchor.snapshot_id], "Missing annotation snapshot")
		local key = entry_key(snapshot)
		if by_file[key] == nil then
			local ok, value = pcall(git.snapshot, root, snapshot)
			by_file[key] = ok and value or false
		end
		local latest = by_file[key]
		current[snapshot.id] = latest
		statuses[annotation_key(anchor)] = not latest and "unverified"
			or (
				selection.changed(snapshot[anchor.side], latest[anchor.side], anchor.selection) and "changed"
				or "current"
			)
	end
	local changed = not vim.deep_equal(notes.annotation_status, statuses)
	notes.annotation_status = statuses
	if changed then
		if M.state == notes and notes.new_buf and api.nvim_buf_is_valid(notes.new_buf) then
			render_comments(false, notes)
		end
		require("rediff.annotations").refresh()
	end
	return current
end

local function hunk_range(change, side, buf)
	local range = change[side == "old" and "original" or "modified"]
	local count = api.nvim_buf_line_count(buf)
	local first = math.max(1, math.min(range.start_line, count))
	return first, math.max(first, math.min(range.end_line - 1, count))
end

local function mark_hunk(index)
	local s = state()
	s.selected_hunk = index
	for _, pane in ipairs({ { s.old_buf, "old" }, { s.new_buf, "new" } }) do
		local buf, side = unpack(pane)
		api.nvim_buf_clear_namespace(buf, hunk_ns, 0, -1)
		local change = index and s.diff.changes[index]
		if change then
			local first, last = hunk_range(change, side, buf)
			for line = first, last do
				api.nvim_buf_set_extmark(buf, hunk_ns, line - 1, 0, {
					sign_text = line == first and "▶" or "┃",
					sign_hl_group = "ReviewHunk",
					priority = 5000, -- Keep the selected hunk visible above comment signs.
				})
			end
		end
	end
end

local function select_tree_file(keep_fold)
	local s = state()
	for row, item in pairs(s.rows) do
		if item == s.index then
			local entry = s.entries[item]
			local group = tree_group(entry)
			if not keep_fold or not s.collapsed[group] then
				s.tree_selection[group] = entry_key(entry)
			end
			if not keep_fold and s.collapsed[group] then
				s.collapsed[group] = nil
				api.nvim_win_call(s.tree_win, function()
					vim.cmd(row .. "foldopen!")
				end)
			end
			api.nvim_win_set_cursor(s.tree_win, { s.collapsed[group] and s.group_rows[group] or row, 0 })
			break
		end
	end
	highlight_tree_selection(s)
end

local function focus_hunk(index, keep_fold)
	local s = state()
	mark_hunk(index)
	select_tree_file(keep_fold)
	local panes = { { s.new_win, s.new_buf, "new" } }
	if s.old_win then
		table.insert(panes, 1, { s.old_win, s.old_buf, "old" })
	end
	for _, pane in ipairs(panes) do
		local win, buf, side = unpack(pane)
		local first, last = hunk_range(s.diff.changes[index], side, buf)
		api.nvim_win_call(win, function()
			api.nvim_win_set_cursor(win, { first, 0 })
			local height = api.nvim_win_text_height(win, { start_row = first - 1, end_row = last - 1 }).all
			local margin = math.max(0, math.floor((api.nvim_win_get_height(win) - height) / 2))
			if height >= api.nvim_win_get_height(win) then
				margin = 2
			end
			vim.cmd("normal! zt")
			if margin > 0 then
				vim.cmd.normal({
					args = { margin .. api.nvim_replace_termcodes("<C-y>", true, false, true) },
					bang = true,
				})
			end
		end)
	end
end

function M.show(index, snapshot, keep_fold)
	local s = state()
	local wrap = s.wrap or false
	snapshot = snapshot or git.snapshot(s.root, assert(s.entries[index], "No changed file selected"))
	s.index, s.current = index, snapshot
	s.annotation_id = nil
	s.exhausted_group = nil
	s.snapshots[snapshot.id] = snapshot
	local old_lines, new_lines = git.lines(snapshot.old), git.lines(snapshot.new)
	-- These are full-file replacements, not incremental edits. Drop old syntax
	-- trees before changing the text rather than copying/editing each old node.
	for _, buf in ipairs({ s.old_buf, s.new_buf }) do
		local highlighter = vim.treesitter.highlighter.active[buf]
		if highlighter then
			highlighter.tree:invalidate(true)
		end
	end
	set_lines(s.old_buf, old_lines)
	set_lines(s.new_buf, new_lines)
	-- Codediff's empty-file path requires one empty line, just like Neovim.
	-- Zero-element arrays silently produce no hunks for added/deleted files.
	old_lines = api.nvim_buf_get_lines(s.old_buf, 0, -1, false)
	new_lines = api.nvim_buf_get_lines(s.new_buf, 0, -1, false)
	local ft = vim.filetype.match({ filename = snapshot.path }) or ""
	for _, buf in ipairs({ s.old_buf, s.new_buf }) do
		if vim.bo[buf].filetype ~= ft then
			vim.bo[buf].filetype = ft
		end
	end
	-- Filetype plugins can create closed folds that survive snapshot reuse.
	-- Keep source panes fully visible; the tree owns its separate group folds.
	for _, win in ipairs({ s.new_win, s.old_win }) do
		vim.wo[win].foldmethod = "manual"
		vim.wo[win].foldenable = false
		api.nvim_win_call(win, function()
			vim.cmd("normal! zE")
		end)
	end
	-- <nowait> only wins when defined after competing buffer-local prefixes.
	-- Filetype plugins (e.g. Markdown's [[/]]) install these on every switch.
	map_hunks(s.old_buf)
	map_hunks(s.new_buf)
	map_staging(s.old_buf)
	map_staging(s.new_buf)
	local renderer = require("codediff.ui.view.render")
	local path = " %<" .. vim.fn.strtrans(snapshot.path):gsub("%%", "%%%%")
	local buffer_snapshot = snapshot.group == "buffer"
	if s.layout == "merged" then
		vim.wo[s.new_win].winbar = path
			.. (buffer_snapshot and " %= BUFFER SNAPSHOT " or " %= MERGED · red: old / green: new ")
		vim.wo[s.new_win].scrollbind = false
		vim.wo[s.new_win].wrap = false
		s.diff = assert(require("codediff.core.diff").compute_diff(old_lines, new_lines, renderer.diff_options()))
		require("codediff.ui.inline").render_inline_diff(s.new_buf, s.diff, old_lines, new_lines, { filetype = ft })
	else
		vim.wo[s.old_win].winbar = path
			.. " %= OLD · "
			.. (snapshot.base and snapshot.base:sub(1, 12) or (buffer_snapshot and "BUFFER" or (snapshot.group == "staged" and "HEAD" or "INDEX")))
			.. " "
		vim.wo[s.new_win].winbar = path
			.. " %= NEW · "
			.. (snapshot.base and snapshot.head:sub(1, 12) or (buffer_snapshot and "BUFFER" or (snapshot.group == "staged" and "INDEX" or "WORKTREE")))
			.. " "
		s.diff = renderer.compute_and_render(
			s.old_buf,
			s.new_buf,
			old_lines,
			new_lines,
			true,
			true,
			s.old_win,
			s.new_win,
			true
		)
	end
	-- The renderer sets nowrap; restore the user's choice after every refresh.
	s.wrap = wrap
	if s.old_win then
		vim.wo[s.old_win].wrap = wrap
	end
	vim.wo[s.new_win].wrap = wrap
	require("rediff.difftastic").highlight(s, snapshot)
	render_comments(false, s)
	api.nvim_set_current_win(s.new_win)
	mark_hunk(nil)
	if #s.diff.changes > 0 then
		focus_hunk(1, keep_fold)
	else
		select_tree_file(keep_fold)
	end
	awareness.render()
end

function M.view(layout)
	local s = assert(M.active(), "Enter Review first")
	layout = layout or (s.layout == "merged" and "split" or "merged")
	assert(layout == "split" or layout == "merged", "Usage: view [split|merged]")
	if layout == s.layout then
		return
	end
	local selected, annotation_id = s.selected_hunk, s.annotation_id
	local source_line = api.nvim_win_get_cursor(s.new_win)
	local focus = api.nvim_get_current_win()
	s.layout = layout
	if layout == "merged" then
		local old_win = s.old_win
		s.old_win = nil
		api.nvim_win_close(old_win, true)
	else
		api.nvim_set_current_win(s.new_win)
		vim.cmd("leftabove vsplit")
		s.old_win = api.nvim_get_current_win()
		api.nvim_win_set_buf(s.old_win, s.old_buf)
	end
	for _, buf in ipairs({ s.old_buf, s.new_buf }) do
		for _, name in ipairs({ "codediff-highlight", "codediff-filler", "codediff-inline" }) do
			api.nvim_buf_clear_namespace(buf, api.nvim_create_namespace(name), 0, -1)
		end
	end
	if s.current then
		M.show(s.index, vim.deepcopy(s.current))
		if selected and s.diff.changes[selected] then
			focus_hunk(selected)
		else
			api.nvim_win_set_cursor(s.new_win, source_line)
		end
	end
	s.annotation_id = annotation_id
	api.nvim_set_current_win(api.nvim_win_is_valid(focus) and focus or s.new_win)
	render_comments(false, s)
end

local function read_changes(s, preferred)
	local reference = s.comparison and (s.comparison.base:sub(1, 12) .. " → " .. s.comparison.head:sub(1, 12))
		or git.reference(s.root)
	local entries = git.entries(s.root, s.comparison)
	if s.file_match then
		retain(entries, s.file_match)
	end
	local index = math.min(s.index or 1, #entries)
	if s.exhausted_group then
		index = nil
		for i, entry in ipairs(entries) do
			if tree_group(entry) == s.exhausted_group then
				index = i
				break
			end
		end
	end
	if preferred then
		for i, entry in ipairs(entries) do
			if entry_key(entry) == entry_key(preferred) then
				index = i
				break
			end
		end
	end
	local ok, snapshot = true, nil
	if entries[index] then
		ok, snapshot = pcall(git.snapshot, s.root, entries[index])
	end
	return {
		entries = entries,
		reference = reference,
		index = index,
		snapshot = ok and snapshot or nil,
		error = not ok and snapshot or nil,
	}
end

function M.refresh(preferred, changes)
	local s = state()
	local heading
	for group, row in pairs(s.group_rows or {}) do
		if api.nvim_win_get_cursor(s.tree_win)[1] == row then
			heading = group
		end
	end
	changes = changes or read_changes(s, preferred)
	s.annotation_id = nil
	s.entries, s.reference = changes.entries, changes.reference
	local lines = {
		s.comparison and " BRANCH DIFF · Commits" or " REVIEW · Git changes",
		" /: filter files",
	}
	if s.file_filter and s.file_filter ~= "" then
		lines[2] = " / " .. vim.fn.strtrans(s.file_filter)
		lines[3] = " / Ctrl-U Enter: clear"
	end
	local rows = {}
	s.group_rows = {}
	for _, group in ipairs(s.groups) do
		local count = 0
		for _, entry in ipairs(s.entries) do
			if tree_group(entry) == group then
				count = count + 1
			end
		end
		table.insert(lines, string.format(" ▾ %s (%d)", group:upper(), count))
		s.group_rows[group] = #lines
		for i, entry in ipairs(s.entries) do
			if tree_group(entry) == group then
				table.insert(lines, " " .. entry.status .. " " .. vim.fn.strtrans(entry.path))
				rows[#lines] = i
			end
		end
		if count == 0 then
			table.insert(lines, "   (none)")
		end
		table.insert(lines, "")
	end
	s.rows = rows
	set_lines(s.tree_buf, lines)
	api.nvim_buf_clear_namespace(s.tree_buf, tree_ns, 0, -1)
	api.nvim_buf_clear_namespace(s.tree_buf, active_ns, 0, -1)
	for row, index in pairs(rows) do
		local highlight = status_highlights[s.entries[index].status]
		if highlight then
			api.nvim_buf_set_extmark(s.tree_buf, tree_ns, row - 1, 1, {
				id = row,
				end_col = 2,
				hl_group = highlight,
				priority = 200,
			})
		end
	end
	api.nvim_win_call(s.tree_win, function()
		vim.cmd("normal! zE")
		for i, group in ipairs(s.groups) do
			local first = s.group_rows[group]
			local last = s.groups[i + 1] and s.group_rows[s.groups[i + 1]] - 2 or #lines - 1
			vim.cmd(string.format("%d,%dfold", first, last))
			if not s.collapsed[group] then
				vim.cmd(first .. "foldopen!")
			end
		end
	end)
	if changes.index and s.entries[changes.index] then
		local ok, err = false, changes.error
		if not err then
			ok, err = pcall(M.show, changes.index, changes.snapshot, true)
		end
		if not ok then
			s.current = nil
			s.diff = nil
			mark_hunk(nil)
			set_lines(s.old_buf, {})
			set_lines(s.new_buf, { tostring(err) })
			notify(tostring(err), vim.log.levels.WARN)
		end
	else
		s.index, s.current = nil, nil
		s.diff = nil
		mark_hunk(nil)
		set_lines(s.old_buf, {})
		set_lines(s.new_buf, {})
		for _, buf in ipairs({ s.old_buf, s.new_buf }) do
			api.nvim_buf_clear_namespace(buf, -1, 0, -1)
		end
		if #s.entries == 0 and s.file_filter and s.file_filter ~= "" then
			vim.wo[s.new_win].winbar = " No matching files · / in tree to change filter"
			if s.old_win then
				vim.wo[s.old_win].winbar = ""
			end
		elseif s.comparison then
			vim.wo[s.new_win].winbar = " No differences between commits "
			if s.old_win then
				vim.wo[s.old_win].winbar = ""
			end
		elseif s.exhausted_group then
			api.nvim_win_set_cursor(s.tree_win, { s.group_rows[s.exhausted_group], 0 })
			vim.wo[s.new_win].winbar = s.exhausted_group == "staged"
					and " No staged changes · :fu to review unstaged changes"
				or " No unstaged changes · :fs to review staged changes"
			if s.old_win then
				vim.wo[s.old_win].winbar = ""
			end
		else
			vim.wo[s.new_win].winbar = " No changes"
			if s.old_win then
				vim.wo[s.old_win].winbar = ""
			end
		end
	end
	if heading then
		api.nvim_win_set_cursor(s.tree_win, { s.group_rows[heading], 0 })
	end
	highlight_tree_selection(s)
	render_tree_annotations(s)
	awareness.scan(s.root)
	save(s)
end

function M.filter_files()
	local s = assert(M.active(), "Enter Review first")
	vim.ui.input(
		{ prompt = "Filter files (glob or re:regex; empty clears): ", default = s.file_filter or "" },
		guard(function(query)
			if query == nil or M.active() ~= s then
				return
			end
			-- Compile before changing state so invalid patterns keep the current filter.
			local pattern, regex, glob = query, nil, nil
			if vim.startswith(pattern, "re:") then
				pattern = pattern:sub(4)
				regex = vim.regex("\\c\\v" .. pattern)
			elseif pattern:find("[*?%[{]") then
				glob = vim.glob.to_lpeg(vim.fn.tolower(pattern))
			end
			local match_path = pattern:find("/", 1, true) ~= nil
			local literal = vim.fn.tolower(pattern)
			local function matches(entry)
				local target = match_path and entry.path or vim.fn.fnamemodify(entry.path, ":t")
				if regex then
					return regex:match_str(target) ~= nil
				end
				target = vim.fn.tolower(target)
				if glob then
					return glob:match(target) ~= nil
				end
				return target:find(literal, 1, true) ~= nil
			end
			s.file_match = query ~= "" and matches or nil
			s.file_filter = query
			s.exhausted_group = nil
			M.refresh(s.current)
			api.nvim_set_current_win(s.tree_win)
		end)
	)
end

function M.tree_fold(collapsed)
	local s = state()
	local row = api.nvim_win_get_cursor(s.tree_win)[1]
	local group = s.comparison and "branch" or (row >= s.group_rows.unstaged and "unstaged" or "staged")
	if (s.collapsed[group] == true) == collapsed then
		return
	end
	s.collapsed[group] = collapsed
	if collapsed then
		local entry = s.entries[s.rows[row] or 0]
		if entry then
			s.tree_selection[group] = entry_key(entry)
		end
		vim.cmd(s.group_rows[group] .. "foldclose")
		api.nvim_win_set_cursor(s.tree_win, { s.group_rows[group], 0 })
	else
		vim.cmd(s.group_rows[group] .. "foldopen!")
		local first, selected
		for i, entry in ipairs(s.entries) do
			if tree_group(entry) == group then
				first = first or i
				if entry_key(entry) == s.tree_selection[group] then
					selected = i
				end
			end
		end
		if selected or first then
			local index = selected or first
			if index == s.index and s.current then
				for file_row, item in pairs(s.rows) do
					if item == index then
						api.nvim_win_set_cursor(s.tree_win, { file_row, 0 })
						break
					end
				end
			else
				M.show(index)
			end
			api.nvim_set_current_win(s.tree_win)
		else
			s.exhausted_group = group
		end
	end
end

function M.refresh_live()
	local s = state()
	local snapshot, entries = s.current, s.entries
	-- Git reads yield to input. Do not apply results after the user changed views,
	-- opened a composer/picker, or left this worktree while the reads were running.
	local changes = read_changes(s, snapshot)
	if not require("rediff.live").ready(s) or s.current ~= snapshot or s.entries ~= entries then
		return false
	end
	local win = api.nvim_get_current_win()
	local tree_entry = s.entries[s.rows[api.nvim_win_get_cursor(s.tree_win)[1]] or 0]
	local views = {}
	for _, pane in ipairs({ s.new_win, s.old_win }) do
		views[pane] = api.nvim_win_call(pane, vim.fn.winsaveview)
	end
	local ok, err = pcall(M.refresh, snapshot, changes)
	if snapshot and s.current and entry_key(snapshot) == entry_key(s.current) then
		for pane, view in pairs(views) do
			api.nvim_win_call(pane, function()
				vim.fn.winrestview(view)
			end)
		end
		mark_hunk(nil)
		local side = win == s.old_win and "old" or "new"
		local buf = side == "old" and s.old_buf or s.new_buf
		local line = api.nvim_win_get_cursor(side == "old" and s.old_win or s.new_win)[1]
		for i, change in ipairs(s.diff.changes) do
			local first, last = hunk_range(change, side, buf)
			if first <= line and line <= last then
				mark_hunk(i)
				break
			end
		end
	end
	if tree_entry then
		for row, index in pairs(s.rows) do
			if entry_key(s.entries[index]) == entry_key(tree_entry) then
				api.nvim_win_set_cursor(s.tree_win, { row, 0 })
				break
			end
		end
	end
	api.nvim_set_current_win(win)
	assert(ok, err)
	-- Live edits must not accumulate full unreferenced file snapshots forever.
	local keep = {}
	if s.current then
		keep[s.current.id] = true
	end
	for _, comment in ipairs(s.comments) do
		keep[comment.snapshot_id] = true
	end
	for _, draft in ipairs(s.drafts) do
		keep[draft.anchor.snapshot_id] = true
	end
	for id in pairs(s.snapshots) do
		if not keep[id] then
			s.snapshots[id] = nil
		end
	end
	return true
end

function M.focus(group)
	local s = assert(M.active(), "Enter Review first")
	assert(not s.comparison, "Staged/unstaged groups are unavailable in branch diff mode; use :Review")
	assert(group == "staged" or group == "unstaged", "Usage: focus staged|unstaged")
	local win = api.nvim_get_current_win()
	for i, entry in ipairs(s.entries) do
		if (entry.group == "staged") == (group == "staged") then
			M.show(i)
			if win == s.tree_win or win == s.old_win then
				api.nvim_set_current_win(win)
			end
			return
		end
	end
	notify(group == "staged" and "No visible STAGED files" or "No visible UNSTAGED files")
end

local function unseen_changes(s)
	local result, tracker = {}, awareness.get(s.root)
	local file = s.current and entry_key(s.current)
	local current = file and tracker.current and tracker.current[file]
	if not current then
		return result
	end
	local displayed = awareness.describe(vim.diff(s.current.old, s.current.new, { ctxlen = 0 }))
	if not vim.deep_equal(displayed.ids, current.ids) then
		return result -- Never navigate using awareness from a different snapshot.
	end
	for _, hunk in ipairs(displayed.hunks) do
		if awareness.hunk_state(tracker, file, hunk.id) == "unseen" then
			for i, change in ipairs(s.diff.changes) do
				for _, side in ipairs({ { "old", "original" }, { "new", "modified" } }) do
					local first, count = hunk[side[1] .. "_start"], hunk[side[1] .. "_count"]
					local range = change[side[2]]
					if count > 0 and range.start_line < first + count and first < range.end_line then
						result[i] = true
					end
				end
			end
		end
	end
	return result
end

function M.jump_hunk(direction, unseen_only)
	local s = state()
	if unseen_only and s.annotation_id then
		notify("Use Space R to return to current files before navigating unseen hunks")
		return
	end
	local win = api.nvim_get_current_win()
	local side = win == s.old_win and "old" or "new"
	local buf = side == "old" and s.old_buf or s.new_buf
	local line = api.nvim_win_get_cursor(side == "old" and s.old_win or s.new_win)[1]
	local changes = s.diff and s.diff.changes or {}
	local unseen = unseen_only and unseen_changes(s)
	local first, last, step = 1, #changes, 1
	if direction < 0 then
		first, last, step = #changes, 1, -1
	end
	for i = first, last, step do
		local start_line, end_line = hunk_range(changes[i], side, buf)
		if
			(not unseen or unseen[i])
			and ((direction > 0 and start_line > line) or (direction < 0 and end_line < line))
		then
			focus_hunk(i)
			return
		end
	end
	-- Wrap within the visible Git group; untracked entries belong to UNSTAGED.
	local previous, selected, snapshot = s.index, s.selected_hunk, s.current
	local staged = s.entries[previous or 0] and s.entries[previous].group == "staged"
	local old_view = s.old_win and api.nvim_win_call(s.old_win, vim.fn.winsaveview)
	local new_view = api.nvim_win_call(s.new_win, vim.fn.winsaveview)
	for offset = 1, #s.entries do
		local i = ((previous or 1) - 1 + direction * offset) % #s.entries + 1
		if
			(s.entries[i].group == "staged") == staged
			and (not unseen_only or awareness.file_state(awareness.get(s.root), entry_key(s.entries[i])) == "unseen")
		then
			local ok, err = true, nil
			-- Wrapping in the displayed file only needs a cursor move. Rebuild it
			-- only if we visited another file while looking for a nonempty diff.
			if i ~= s.index then
				ok, err = pcall(M.show, i, i == previous and snapshot or nil)
			end
			if not ok then
				notify("Skipping " .. s.entries[i].path .. ": " .. tostring(err), vim.log.levels.WARN)
			else
				local eligible = unseen_only and unseen_changes(s)
				local start = direction > 0 and 1 or #s.diff.changes
				local finish = direction > 0 and #s.diff.changes or 1
				for hunk = start, finish, direction do
					if not eligible or eligible[hunk] then
						focus_hunk(hunk)
						api.nvim_set_current_win(win)
						return
					end
				end
			end
		end
	end
	if previous then
		if s.index ~= previous then
			M.show(previous, snapshot)
		end
		if old_view then
			api.nvim_win_call(s.old_win, function()
				vim.fn.winrestview(old_view)
			end)
		end
		api.nvim_win_call(s.new_win, function()
			vim.fn.winrestview(new_view)
		end)
		mark_hunk(selected)
	end
	api.nvim_set_current_win(win)
	notify(unseen_only and "No unseen hunks in this Git group" or "No hunks in this Git group")
end

local function advance_staged_hunk(snapshot, hunk, entries, index)
	local s = state()
	-- Worktree coordinates survive staging, even when the old side shifts.
	if s.current and entry_key(s.current) == entry_key(snapshot) then
		for i, change in ipairs(s.diff.changes) do
			if change.modified.start_line >= hunk.new_start + hunk.new_count then
				focus_hunk(i)
				return true
			end
		end
	end
	local remaining, order = {}, {}
	for i, entry in ipairs(s.entries) do
		if entry.group ~= "staged" then
			remaining[entry_key(entry)] = i
		end
	end
	-- Follow the previous file order, wrapping to earlier hunks only at the end.
	for offset = 1, #entries do
		local key = entry_key(entries[(index - 1 + offset) % #entries + 1])
		if remaining[key] then
			table.insert(order, remaining[key])
			remaining[key] = nil
		end
	end
	-- Include files that appeared while Git was applying the patch.
	for i, entry in ipairs(s.entries) do
		if remaining[entry_key(entry)] then
			table.insert(order, i)
		end
	end
	for _, i in ipairs(order) do
		local ok, err = pcall(M.show, i)
		if ok and #s.diff.changes > 0 then
			focus_hunk(1)
			return true
		elseif not ok then
			notify("Skipping " .. s.entries[i].path .. ": " .. tostring(err), vim.log.levels.WARN)
		end
	end
	s.exhausted_group = "unstaged"
	M.refresh()
	return false
end

function M.stage(whole_file, unstage)
	local s = assert(M.active(), "Enter Review first")
	assert(not s.comparison, "Staging is unavailable in branch diff mode; use :Review for worktree changes")
	assert(not s.annotation_id, "Press Space R to return to current files before staging")
	local win = api.nvim_get_current_win()
	local snapshot, side, line = s.current, "new", 1
	local index = s.index
	local next_entry, tree_group
	if win == s.tree_win then
		assert(whole_file, "Focus a source pane to stage/unstage a hunk; S acts on the selected file")
		index = s.rows[api.nvim_win_get_cursor(win)[1]]
		local entry = assert(s.entries[index], "Select a changed file")
		snapshot = index == s.index and s.current or git.snapshot(s.root, entry)
	else
		side, line = side_at_cursor(), api.nvim_win_get_cursor(win)[1]
	end
	assert(snapshot, "No changed file selected")
	if whole_file then
		snapshot = git.snapshot(s.root, snapshot)
		tree_group = snapshot.group == "staged" and "staged" or "unstaged"
		for i = index + 1, #s.entries do
			if (s.entries[i].group == "staged") == (tree_group == "staged") then
				next_entry = s.entries[i]
				break
			end
		end
		if not next_entry then
			for i = index - 1, 1, -1 do
				if (s.entries[i].group == "staged") == (tree_group == "staged") then
					next_entry = s.entries[i]
					break
				end
			end
		end
	end
	if unstage ~= nil then
		assert(
			(snapshot.group == "staged") == unstage,
			unstage and "Select a STAGED entry" or "Select an UNSTAGED entry"
		)
	end
	local entries = s.entries
	local hunk = git.stage(s.root, snapshot, side, line, whole_file)
	local ok, err = pcall(awareness.acknowledge, s.root, snapshot)
	if not ok then
		notify("Index updated, but change indicators could not be cleared: " .. tostring(err), vim.log.levels.WARN)
	end
	if tree_group then
		s.exhausted_group = tree_group
		M.refresh(next_entry)
	else
		M.refresh(snapshot)
	end
	if hunk and snapshot.group ~= "staged" and not advance_staged_hunk(snapshot, hunk, entries, index) then
		win = s.tree_win
	end
	api.nvim_set_current_win(win)
	notify("Index updated; source files unchanged. Existing comments retain their original snapshots.")
end

function M.revert(first, last)
	local s = assert(M.active(), "Enter Review first")
	assert(not s.comparison, "Reverting is unavailable in branch diff mode; use :Review for worktree changes")
	assert(not s.annotation_id, "Press Space R to return to current files before reverting")
	assert(not s.composer, "Close the annotation before reverting")
	local side = side_at_cursor()
	local snapshot = assert(s.current, "No changed file selected")
	local path = s.root .. "/" .. snapshot.path
	for _, buf in ipairs(api.nvim_list_bufs()) do
		assert(
			not (api.nvim_buf_get_name(buf) == path and vim.bo[buf].modified),
			"File has unsaved edits; save or discard them before reverting"
		)
	end
	local target = vim.deepcopy(harness.get(s.root).target)
	if target.name ~= "custom" and not target.session then
		target = { name = "none" }
	end
	local argv = feedback.command(target)
	local discards = require("rediff.discards")
	discards.load(s.root)
	first = first or api.nvim_win_get_cursor(0)[1]
	local hunks = git.revert(s.root, snapshot, side, first, last)
	local ok, err = pcall(discards.add, s.root, snapshot, hunks, target, argv)
	if not ok then
		notify("Hunks reverted, but notification could not be saved: " .. tostring(err), vim.log.levels.ERROR)
	end
	M.refresh(snapshot)
	vim.cmd("checktime")
	require("rediff.live").changed(s.root)
	if ok then
		notify("Reverted " .. #hunks .. " hunk(s); agent notification queued.")
	end
end

function M.add_comment(anchor, text, existing_id)
	local s = annotation_state()
	assert(vim.trim(text) ~= "", "Comment cannot be empty")
	if existing_id then
		for _, comment in ipairs(s.comments) do
			if comment.id == existing_id then
				comment.text = text
				save()
				M.refresh_annotations(s.root)
				render_comments()
				return comment
			end
		end
		error("Comment no longer exists")
	end
	local first, last = anchor.selection.spans[1], anchor.selection.spans[#anchor.selection.spans]
	local comment = {
		id = vim.fn.sha256(tostring(vim.uv.hrtime()) .. text),
		file = anchor.file,
		line = first.line,
		line_end = last.line,
		side = anchor.side,
		type = "note",
		text = text,
		snapshot_id = anchor.snapshot_id,
		selection = anchor.selection,
	}
	table.insert(s.comments, comment)
	save()
	M.refresh_annotations(s.root)
	render_comments()
	return comment
end

function M.save_composer()
	local s = annotation_state()
	if not s.draft then
		return
	end
	local loaded = s.composer and api.nvim_buf_is_loaded(s.composer)
	local text = loaded and table.concat(api.nvim_buf_get_lines(s.composer, 0, -1, false), "\n") or s.draft.text
	local comment
	if vim.trim(text) ~= "" then
		comment = M.add_comment(s.draft.anchor, text, s.draft.comment_id)
		s.draft.comment_id = comment.id
	end
	retain(s.drafts, function(draft)
		return draft ~= s.draft
	end)
	s.draft.text, s.draft.saved = text, true
	save()
	if loaded then
		vim.bo[s.composer].modified = false
	end
	return comment
end

local function release_composer(s)
	s = s or annotation_state()
	local buf = s.composer
	if api.nvim_buf_is_loaded(buf) then
		s.draft.text = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
	end
	for _, comment in ipairs(s.comments) do
		if s.draft.comment_id == comment.id and s.draft.text == comment.text then
			retain(s.drafts, function(draft)
				return draft ~= s.draft
			end)
			break
		end
	end
	s.draft = nil
	s.composer, s.composer_win = nil, nil
	for _, source in pairs({ s.old_buf, s.new_buf }) do
		if api.nvim_buf_is_valid(source) then
			api.nvim_buf_clear_namespace(source, composer_ns, 0, -1)
		end
	end
	save(s)
	api.nvim_buf_delete(buf, { force = true })
end

M.release_composer = release_composer

local function composer_config(s)
	local anchor = s.draft.anchor
	local win = anchor.side == "old" and s.old_win or s.new_win
	local spans = anchor.selection.spans
	local last = spans[#spans].line
	local height = math.max(1, math.min(6, api.nvim_win_get_height(win) - 4))
	-- The editable float occupies virtual rows, never the source text below it.
	-- Keep this separate from saved notes so refreshing them preserves the gap.
	local padding = {}
	for _ = 1, height + 2 do
		table.insert(padding, { { "" } })
	end
	local function reserve(buf, line)
		api.nvim_buf_set_extmark(buf, composer_ns, math.max(0, math.min(line, api.nvim_buf_line_count(buf)) - 1), 0, {
			id = 1,
			virt_lines = padding,
			virt_lines_above = line < 1,
			-- Sort before saved notes at the same position, even after refresh.
			right_gravity = false,
		})
	end
	reserve(anchor.side == "old" and s.old_buf or s.new_buf, last)
	if s.old_win then
		reserve(anchor.side == "old" and s.new_buf or s.old_buf, opposite_line(last, anchor.side, s.diff.changes))
	end
	local rows = api.nvim_win_text_height(win, { start_row = last - 1, start_vcol = 0, end_row = last - 1 }).all
	local pos = vim.fn.screenpos(win, last, 1)
	local bottom = api.nvim_win_get_position(win)[1] + api.nvim_win_get_height(win)
	if pos.row == 0 or pos.row + rows + height + 1 > bottom then
		-- Make room below the anchor instead of letting Neovim move the float
		-- over the source being annotated. This also reveals reversed selections.
		api.nvim_win_call(win, function()
			api.nvim_win_set_cursor(win, { last, 0 })
			vim.cmd("normal! zt")
		end)
	end
	return {
		relative = "win",
		win = win,
		bufpos = { last - 1, 0 },
		row = rows,
		col = 0,
		width = math.max(1, api.nvim_win_get_width(win) - vim.fn.getwininfo(win)[1].textoff - 2),
		height = height,
		style = "minimal",
		border = "single",
		title = composer_title(s),
		footer = " :w save · :q keep draft ",
	}
end

function M.compose(visual, keys, comment)
	local s = annotation_state()
	assert(not s.file_mode or s.enabled, "Enable annotation mode with Space a first")
	if s.composer and api.nvim_win_is_valid(s.composer_win) then
		api.nvim_set_current_win(s.composer_win)
		if keys then
			api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), "ni", false)
		else
			api.nvim_feedkeys("i", "ni", false)
		end
		return
	end
	if s.composer then
		release_composer()
	end
	local side, buf = side_at_cursor()
	assert(s.current, "No diff to annotate")
	s.snapshots[s.current.id] = s.current
	local line = api.nvim_win_get_cursor(0)[1]
	local anchor = { file = s.current.path, side = side, snapshot_id = s.current.id }
	if visual then
		anchor.selection = selection.capture(buf, vim.fn.mode(), vim.fn.getpos("v"), vim.fn.getpos("."))
		vim.cmd.normal({ args = { api.nvim_replace_termcodes("<Esc>", true, false, true) }, bang = true })
	else
		anchor.selection = selection.line(buf, line)
	end
	if comment then
		anchor = {
			file = comment.file,
			side = comment.side,
			snapshot_id = comment.snapshot_id,
			selection = vim.deepcopy(comment.selection),
		}
	end
	local draft
	for _, pending in ipairs(s.drafts) do
		if pending.comment_id == (comment and comment.id) and vim.deep_equal(pending.anchor, anchor) then
			draft = pending
			break
		end
	end
	if not draft then
		draft = { anchor = anchor, text = comment and comment.text or "", comment_id = comment and comment.id }
		table.insert(s.drafts, draft)
	end
	s.draft = draft
	M.refresh_annotations(s.root)
	local composer = owned_buffer("review://" .. s.id .. "/comment", vim.split(draft.text, "\n"), true)
	s.composer = composer
	vim.bo[composer].filetype = "markdown"
	s.composer_win = api.nvim_open_win(composer, true, composer_config(s))
	vim.wo[s.composer_win].wrap = true
	vim.wo[s.composer_win].linebreak = true
	vim.wo[s.composer_win].winhighlight = "FloatBorder:ReviewAnnotation,FloatTitle:ReviewAnnotation"
	vim.keymap.set("n", "<Esc>", "<Cmd>quit<CR>", { buffer = composer, desc = "Close annotation and keep draft" })
	api.nvim_create_autocmd("QuitPre", {
		buffer = composer,
		callback = function()
			-- Only explicit writes add/update comments; closing retains a draft.
			vim.bo[composer].modified = false
		end,
	})
	api.nvim_create_autocmd("WinClosed", {
		pattern = tostring(s.composer_win),
		once = true,
		callback = function()
			local refocus = api.nvim_get_current_win() == s.composer_win
			vim.schedule(function()
				if s.composer ~= composer then
					return
				end
				local source = s.draft.anchor.side == "old" and s.old_win or s.new_win
				release_composer(s)
				if refocus and source and api.nvim_win_is_valid(source) then
					api.nvim_set_current_win(source)
				end
			end)
		end,
	})
	local resize = api.nvim_create_autocmd("VimResized", {
		callback = function()
			if s.composer == composer and api.nvim_win_is_valid(s.composer_win) then
				api.nvim_win_set_config(s.composer_win, composer_config(s))
			end
		end,
	})
	api.nvim_create_autocmd("BufWipeout", {
		buffer = composer,
		once = true,
		callback = function()
			api.nvim_del_autocmd(resize)
		end,
	})
	api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufLeave" }, {
		buffer = composer,
		callback = function()
			if s.draft and s.composer then
				s.draft.text = table.concat(api.nvim_buf_get_lines(composer, 0, -1, false), "\n")
				s.draft.saved = not vim.bo[composer].modified
			end
		end,
	})
	save()
	if keys then
		api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), "ni", false)
	else
		api.nvim_feedkeys("i", "ni", false)
	end
end

function M.clear_sent(root, path)
	local s = reviews[root]
	if not s then
		return
	end
	local payload = feedback.read(path)
	if not payload or not payload.comments then
		return
	end
	local sent = {}
	for _, comment in ipairs(payload.comments) do
		if comment.id then
			sent[comment.id] = comment
		end
	end
	retain(s.comments, function(comment)
		if not vim.deep_equal(comment, sent[comment.id]) then
			return true
		end
		if s.draft and s.draft.comment_id == comment.id then
			s.draft.comment_id = nil
		end
		for _, draft in ipairs(s.drafts) do
			if draft.comment_id == comment.id then
				draft.comment_id = nil
			end
		end
		if s.annotation_id == comment.id then
			s.annotation_id = nil
		end
		return false
	end)
	if M.state == s then
		render_comments(false, s)
	end
	require("rediff.annotations").refresh()
	-- Delivery can release a historical view after its file event was already applied.
	require("rediff.live").changed(root)
	api.nvim_exec_autocmds("User", { pattern = "ReviewAnnotationsSent", data = { root = root } })
end

function M.submit(retry)
	local s = annotation_state()
	if #s.comments == 0 then
		notify("No agent notes to send to the harness")
		return
	end
	local session = harness.get(s.root)
	if session.restoring or session.connection_error then
		notify(
			session.connection_error or "Checking the saved harness session. Try again shortly.",
			vim.log.levels.WARN
		)
		return
	end
	assert(not feedback.busy(s.root), "Wait for the current feedback delivery before submitting again")
	local argv = harness.command(s.root)
	local current = M.refresh_annotations(s.root)
	local snapshots, snapshot_status, warnings = {}, {}, {}
	for _, comment in ipairs(s.comments) do
		local snapshot = assert(s.snapshots[comment.snapshot_id], "Missing comment snapshot")
		if not snapshots[snapshot.id] then
			local latest = current[snapshot.id]
			local status = not latest and "unverified" or (latest.id == snapshot.id and "current" or "changed")
			snapshot_status[snapshot.id] = status
			snapshots[snapshot.id] = snapshot -- Keep the reviewed text and coordinates, never silently re-anchor.
		end
		if annotation_changed(s, comment) then
			table.insert(warnings, vim.fn.strtrans(comment.file) .. ":" .. comment.line .. "–" .. comment.line_end)
		end
	end
	local id, path = feedback.enqueue(s.root, s.comments, snapshots, argv, nil, snapshot_status)
	if #warnings > 0 then
		notify(
			"Annotated lines changed; sending original review context: " .. table.concat(warnings, ", "),
			vim.log.levels.WARN
		)
	end
	s.last_submission = path
	s.delivery = #argv == 0 and "queued" or "running"
	local ok, err = pcall(harness.deliver, s.root, id, path, argv, retry, function(status)
		s.delivery = status.status
	end)
	if not ok then
		s.delivery = "failed"
		error(err)
	end
	return path
end

function M.select_harness(name, session)
	local s = annotation_state()
	if not name then
		notify("Harness: " .. s.harness.name .. (s.harness.session and (" · " .. s.harness.session) or ""))
		return
	end
	assert(s.delivery ~= "running", "Wait for the current feedback delivery before switching harnesses")
	assert(not session or name == "amp" or name == "claude", "Only built-in harnesses take a session ID")
	local target = { name = name, session = session }
	harness.select(s.root, target)
	s.delivery = "draft"
	save()
end

function M.archive()
	local s = annotation_state()
	assert(not s.composer, "Close the comment composer first")
	feedback.write(s.directory .. "/archive-" .. tostring(vim.uv.hrtime()) .. ".json", {
		comments = s.comments,
		snapshots = s.snapshots,
		drafts = s.drafts,
	})
	for _, items in ipairs({ s.comments, s.snapshots, s.drafts }) do
		for key in pairs(items) do
			items[key] = nil
		end
	end
	s.draft = nil
	s.annotation_id = nil
	if s.current then
		s.snapshots[s.current.id] = s.current
	end
	save()
	render_comments()
	notify("Draft round archived locally; nothing sent to the agent")
end

local function remove_comment(comment, s)
	s = s or annotation_state()
	for i, item in ipairs(s.comments) do
		if item.id == comment.id then
			table.remove(s.comments, i)
			if s.annotation_id == comment.id then
				s.annotation_id = nil
			end
			if s.draft and s.draft.comment_id == comment.id then
				s.draft.comment_id = nil
			end
			for _, draft in ipairs(s.drafts) do
				if draft.comment_id == comment.id then
					draft.comment_id = nil
				end
			end
			save(s)
			render_comments(false, s)
			return
		end
	end
end

function M.delete_comment()
	local s = annotation_state()
	local matches = comments_at_cursor()
	if #matches == 0 then
		notify("No annotation on this line")
	elseif #matches == 1 then
		remove_comment(matches[1])
	else
		vim.ui.select(matches, {
			prompt = "Delete annotation:",
			format_item = function(comment)
				return comment.text:gsub("\n", " ")
			end,
		}, function(comment)
			if annotation_state() == s and comment then
				remove_comment(comment)
			end
		end)
	end
end

local function pick_comments(comments, action)
	local s = annotation_state()
	if #comments == 0 then
		notify("No annotations")
		return
	end
	M.refresh_annotations(s.root)
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")
	local function entry_maker(comment)
		local snapshot = s.snapshots[comment.snapshot_id]
		local label = string.format(
			"%s:%d-%d [%s/%s] %s",
			vim.fn.strtrans(comment.file),
			comment.line,
			comment.line_end,
			snapshot.group,
			comment.side,
			(annotation_changed(s, comment) and "◆ (changed since annotated) " or "")
				.. vim.fn.strtrans((comment.text:gsub("\n", " ")))
		)
		return { value = comment, display = label, ordinal = label }
	end
	require("telescope.pickers")
		.new({}, {
			prompt_title = "Annotations",
			results_title = "d: delete | i /: search | Enter: open",
			initial_mode = "normal",
			previewer = false,
			sorting_strategy = "ascending",
			layout_config = { width = 0.85, height = 0.8, prompt_position = "top" },
			finder = require("telescope.finders").new_table({ results = comments, entry_maker = entry_maker }),
			sorter = require("telescope.config").values.generic_sorter({}),
			attach_mappings = function(prompt_buf, map_key)
				local refresh = api.nvim_create_autocmd("User", {
					pattern = "ReviewAnnotationsSent",
					callback = function(event)
						if event.data.root == s.root then
							retain(comments, function(comment)
								return vim.tbl_contains(s.comments, comment)
							end)
							action_state.get_current_picker(prompt_buf):refresh(
								require("telescope.finders").new_table({ results = comments, entry_maker = entry_maker }),
								{ reset_prompt = false }
							)
						end
					end,
				})
				api.nvim_create_autocmd("BufWipeout", {
					buffer = prompt_buf,
					once = true,
					callback = function()
						api.nvim_del_autocmd(refresh)
					end,
				})
				actions.select_default:replace(guard(function()
					local entry = action_state.get_selected_entry()
					if entry then
						actions.close(prompt_buf)
						if annotation_state() == s then
							action(entry.value)
						end
					end
				end))
				map_key(
					"n",
					"d",
					guard(function()
						action_state.get_current_picker(prompt_buf):delete_selection(function(entry)
							remove_comment(entry.value, s)
						end)
					end)
				)
				map_key("n", "/", function()
					vim.cmd.startinsert({ bang = true })
				end)
				map_key("i", "<Esc>", function()
					vim.cmd.stopinsert()
				end)
				return true
			end,
		})
		:find()
end

function M.jump_comment(comment)
	local s = annotation_state()
	assert(not s.composer, "Save or close the current annotation before jumping")
	assert(vim.tbl_contains(s.comments, comment), "Annotation no longer exists")
	M.refresh_annotations(s.root)
	local snapshot = assert(s.snapshots[comment.snapshot_id], "Missing annotation snapshot")
	if s.file_mode and (not s.enabled or snapshot.id ~= s.current.id) then
		-- Older/other-file anchors use Review's immutable snapshot navigation.
		M.open(s.root)
		s = state()
	end
	if not s.file_mode and snapshot.group == "buffer" and comment.side == "new" then
		M.view("merged")
	elseif comment.side == "old" and s.layout == "merged" then
		M.view("split")
	end
	local index
	for i, entry in ipairs(s.entries or {}) do
		if entry_key(entry) == entry_key(snapshot) then
			index = i
			break
		end
	end
	if not s.file_mode then
		M.show(index, snapshot)
	end
	s.annotation_id = comment.id
	local win = comment.side == "old" and s.old_win or s.new_win
	api.nvim_set_current_win(win)
	local span = comment.selection.spans[1]
	local column =
		math.min(math.max(0, span.start_byte - 1), #api.nvim_buf_get_lines(0, span.line - 1, span.line, false)[1])
	api.nvim_win_set_cursor(win, { span.line, column })
	vim.cmd("normal! zz")
	render_comments()
end

function M.edit_comment(comment)
	local s = annotation_state()
	if comment then
		M.jump_comment(comment)
		M.compose(false, "i", comment)
		return
	end
	if s.composer then
		M.compose()
		return
	end
	local matches = comments_at_cursor()
	for _, item in ipairs(matches) do
		if item.id == s.annotation_id then
			M.edit_comment(item)
			return
		end
	end
	if #matches == 0 then
		M.compose()
	elseif #matches == 1 then
		M.edit_comment(matches[1])
	else
		pick_comments(matches, M.edit_comment)
	end
end

function M.list_comments()
	pick_comments(vim.list_slice(annotation_state().comments), M.jump_comment)
end

function M.next_comment(direction)
	local s = annotation_state()
	if #s.comments == 0 then
		notify("No annotations")
		return
	end
	local buf = api.nvim_get_current_buf()
	if #s.comments == 1 and (buf == s.old_buf or buf == s.new_buf) and comments_at_cursor()[1] == s.comments[1] then
		return
	end
	local index = direction > 0 and 0 or 1
	for i, comment in ipairs(s.comments) do
		if comment.id == s.annotation_id then
			index = i
			break
		end
	end
	M.jump_comment(s.comments[(index - 1 + direction) % #s.comments + 1])
end

function M.leave()
	local s = state()
	tree_focus(false)
	awareness.stop()
	require("rediff.live").stop(s)
	if s.composer then
		release_composer(s)
	end
	save(s)
	M.state = nil
	vim.uv.fs_unlink(s.directory .. "/editor.lock")
	if api.nvim_tabpage_is_valid(s.tab) then
		if api.nvim_tabpage_is_valid(s.previous_tab) then
			api.nvim_set_current_tabpage(s.previous_tab)
			harness.move_pane(s.tab)
		end
		api.nvim_set_current_tabpage(s.tab)
		vim.cmd("tabclose!")
	end
	for _, buf in ipairs({ s.old_buf, s.new_buf, s.tree_buf, s.composer }) do
		if api.nvim_buf_is_valid(buf) then
			api.nvim_buf_delete(buf, { force = true })
		end
	end
	if api.nvim_tabpage_is_valid(s.previous_tab) then
		api.nvim_set_current_tabpage(s.previous_tab)
	end
	api.nvim_exec_autocmds("User", { pattern = "ReviewLeave" })
end

function M.open(root, comparison)
	root = root or (M.state and M.state.root) or git.root()
	if M.state then
		assert(root == M.state.root, "Leave the other repository's Review first")
		if vim.deep_equal(comparison, M.state.comparison) then
			api.nvim_set_current_tabpage(M.state.tab)
			return
		end
	end
	git.entries(root, comparison) -- Validate before changing windows.
	if M.state then
		assert(not M.state.composer, "Save or close the current annotation before switching diff modes")
		M.leave()
	end
	local target = harness.get(root).target
	local directory = feedback.directory(root)
	local lock = directory .. "/editor.lock"
	if vim.fn.filereadable(lock) == 1 then
		local pid = tonumber(vim.fn.readfile(lock)[1])
		assert(pid and not vim.uv.kill(pid, 0), "Another editor owns this review: " .. lock)
		assert(vim.uv.fs_unlink(lock))
	end
	local fd = assert(vim.uv.fs_open(lock, "wx", 384), "Review already open in another editor")
	vim.uv.fs_write(fd, tostring(vim.uv.os_getpid()), 0)
	vim.uv.fs_close(fd)
	local pending = M.notes(root)
	local s = {
		root = root,
		comparison = comparison,
		groups = comparison and { "branch" } or { "staged", "unstaged" },
		directory = directory,
		comments = pending.comments or {},
		drafts = pending.drafts or {},
		snapshots = pending.snapshots or {},
		annotation_status = pending.annotation_status,
		harness = target,
		previous_tab = api.nvim_get_current_tabpage(),
		id = string.format("%.0f", vim.uv.hrtime()),
		delivery = "draft",
		layout = "split",
		collapsed = {},
		tree_selection = {},
	}
	M.state = s
	reviews[root] = s
	vim.cmd.tabnew()
	s.tab = api.nvim_get_current_tabpage()
	vim.cmd("tcd " .. vim.fn.fnameescape(root))
	s.tree_win = api.nvim_get_current_win()
	s.tree_buf = owned_buffer("review://" .. s.id .. "/files", {})
	api.nvim_win_set_buf(s.tree_win, s.tree_buf)
	vim.cmd.vsplit()
	s.old_win = api.nvim_get_current_win()
	s.old_buf = owned_buffer("review://" .. s.id .. "/old", {})
	api.nvim_win_set_buf(s.old_win, s.old_buf)
	vim.cmd.vsplit()
	s.new_win = api.nvim_get_current_win()
	s.new_buf = owned_buffer("review://" .. s.id .. "/new", {})
	api.nvim_win_set_buf(s.new_win, s.new_buf)
	for _, win in ipairs({ s.tree_win, s.old_win, s.new_win }) do
		vim.wo[win].winhighlight = "WinBar:ReviewFocusedPane,WinBarNC:ReviewInactivePane"
	end
	vim.wo[s.tree_win].winbar = " FILE TREE "
	vim.wo[s.tree_win].number = false
	vim.wo[s.tree_win].signcolumn = "no"
	vim.wo[s.tree_win].winfixwidth = true
	vim.wo[s.tree_win].cursorlineopt = "line"
	vim.wo[s.tree_win].winhighlight = vim.wo[s.tree_win].winhighlight .. ",CursorLine:ReviewTreeSelection"
	vim.wo[s.tree_win].foldmethod = "manual"
	vim.wo[s.tree_win].foldenable = true
	vim.wo[s.tree_win].foldminlines = 0
	vim.wo[s.tree_win].foldcolumn = "0"
	vim.wo[s.tree_win].foldtext = "substitute(getline(v:foldstart), '▾', '▸', '')"
	api.nvim_win_call(s.tree_win, function()
		vim.opt_local.fillchars:append({ fold = " " })
	end)
	api.nvim_win_set_width(s.tree_win, math.min(28, math.floor(vim.o.columns / 5)))
	vim.cmd("wincmd =")
	map(s.tree_buf, "n", "q", M.leave, "Leave Review")
	map(s.tree_buf, "n", "/", M.filter_files, "Filter changed file paths")
	for _, key in ipairs({ "h", "<Left>" }) do
		map(s.tree_buf, "n", key, function()
			M.tree_fold(true)
		end, "Collapse Git group")
	end
	for _, key in ipairs({ "l", "<Right>", "<CR>" }) do
		map(s.tree_buf, "n", key, function()
			M.tree_fold(false)
		end, "Expand Git group and restore selection")
	end
	for _, buf in ipairs({ s.old_buf, s.new_buf }) do
		for _, key in ipairs({ "grn", "gra", "grx" }) do
			map(buf, { "n", "x" }, key, function()
				vim.notify("Review is read-only; use Space l to inspect symbols")
			end, "Source-changing LSP action disabled in Review")
		end
		for _, key in ipairs({ "<C-w>]", "<C-w>}", "<C-w><C-]>" }) do
			map(buf, "n", key, function()
				require("rediff.navigation").definition()
			end, "Inspect without leaving Review")
		end
	end
	for _, buf in ipairs({ s.tree_buf, s.old_buf, s.new_buf }) do
		require("rediff.annotations").bind(buf, buf ~= s.tree_buf)
		map_hunks(buf)
		map_staging(buf)
		map(buf, "n", "<D-c>", function()
			require("rediff.navigation").copy_path(false)
		end, "Copy relative file path")
		map(buf, "n", "<C-S-c>", function()
			require("rediff.navigation").copy_path(true)
		end, "Copy full file path")
		map(buf, "n", "<leader>R", M.refresh, "Refresh snapshot")
		map(buf, "n", "<leader>q", M.leave, "Leave Review")
		map(buf, "n", "<Tab>", function()
			api.nvim_set_current_win(api.nvim_get_current_win() == s.tree_win and s.new_win or s.tree_win)
		end, "Focus tree/diff")
		map(buf, "n", "<leader>j", function()
			if #s.entries > 0 then
				M.show((s.index or 0) % #s.entries + 1)
			end
		end, "Next file")
		map(buf, "n", "<leader>k", function()
			if #s.entries > 0 then
				M.show(((s.index or 1) - 2) % #s.entries + 1)
			end
		end, "Previous file")
	end
	M.refresh()
	api.nvim_set_current_win(s.tree_win)
	harness.move_pane(s.previous_tab)
	require("rediff.live").start(s)
	require("rediff.discards").load(s.root)
	awareness.start(s.root)
	api.nvim_exec_autocmds("User", { pattern = "ReviewEnter" })
end

function M.statusline()
	local s = M.active()
	local annotation = require("rediff.annotations").active()
	local root = (s and s.root) or (annotation and annotation.root) or vim.b.rediff_harness_root or vim.fn.getcwd()
	local directory = vim.fn.strtrans(vim.fn.fnamemodify(root, ":~")):gsub("%%", "%%%%")
	if s then
		local file = s.current and vim.fn.strtrans(s.current.path):gsub("%%", "%%%%")
			or (#s.entries > 0 and "No file selected" or "No changes")
		return (s.comparison and "%#RediffMode# BRANCH DIFF %*· " or "%#RediffMode# REVIEW %*· ")
			.. vim.fn.strtrans(s.reference or ""):gsub("%%", "%%%%")
			.. " · "
			.. directory
			.. " · "
			.. harness.statusline(s.root)
			.. " · "
			.. #s.comments
			.. " comments   %<"
			.. file
			.. (s.annotation_id and " · annotation snapshot · Space R to refresh" or "")
			.. "%=%l:%c "
	end
	if annotation then
		return "%#RediffMode# ANNOTATE %*· "
			.. directory
			.. " · Space a to edit · "
			.. #annotation.comments
			.. " notes · "
			.. harness.statusline(annotation.root)
			.. " %<%f %m%=%l:%c %p%%"
	end
	return "%#RediffMode# EDIT · "
		.. vim.fn.mode():upper()
		.. " %*· "
		.. directory
		.. " · "
		.. harness.statusline()
		.. " %<%f %m%=%l:%c %p%%"
end

function M.setup()
	local palette = require("rose-pine.palette")
	api.nvim_set_hl(0, "ReviewStaged", { fg = palette.foam, bg = palette.surface, bold = true })
	api.nvim_set_hl(0, "ReviewUnstaged", { fg = palette.gold, bg = palette.surface, bold = true })
	api.nvim_set_hl(0, "ReviewActiveFile", { bg = palette.highlight_med, bold = true })
	api.nvim_set_hl(0, "ReviewHunk", { fg = palette.gold, bold = true })
	local function review_highlights()
		api.nvim_set_hl(0, "RediffMode", { fg = palette.base, bg = palette.foam, bold = true })
		api.nvim_set_hl(0, "ReviewAdded", { fg = "#4ade80", bold = true })
		api.nvim_set_hl(0, "ReviewModified", { fg = "#facc15", bold = true })
		api.nvim_set_hl(0, "ReviewUntracked", { fg = "#4ade80", bold = true })
		api.nvim_set_hl(0, "ReviewDeleted", { fg = "#f87171", bold = true })
		api.nvim_set_hl(0, "ReviewRenamed", { fg = "#a3a3a3", bold = true })
		api.nvim_set_hl(0, "ReviewUnseen", { fg = palette.iris, bold = true })
		api.nvim_set_hl(0, "ReviewUnseenPulse", { fg = palette.text, bold = true })
		api.nvim_set_hl(0, "ReviewSeen", { fg = palette.foam })
		api.nvim_set_hl(0, "ReviewAnnotation", { fg = "#ff9e64" })
		api.nvim_set_hl(0, "ReviewAnnotationChanged", { fg = palette.iris, bold = true })
		api.nvim_set_hl(0, "ReviewFocusedPane", { fg = palette.base, bg = palette.foam, bold = true })
		api.nvim_set_hl(0, "ReviewInactivePane", { fg = palette.subtle, bg = palette.surface })
		api.nvim_set_hl(0, "ReviewCursorLineInsert", { bg = "#3b5b44" })
		api.nvim_set_hl(0, "ReviewCursorLineDelete", { bg = "#6a4046" })
		-- CursorLine must preserve the status marker's foreground color.
		api.nvim_set_hl(0, "ReviewTreeSelection", { bg = "#33445c", bold = true })
		api.nvim_set_hl(0, "ReviewTreeCursor", { fg = "#33445c", bg = "#33445c", blend = 100 })
	end
	review_highlights()
	local cursorline_ns = api.nvim_create_namespace("rediff.cursorline")
	api.nvim_set_decoration_provider(cursorline_ns, {
		on_win = function(_, win, buf)
			local s = M.active()
			if not s or not s.diff or win ~= api.nvim_get_current_win() then
				return false
			end
			if buf ~= s.old_buf and buf ~= s.new_buf then
				return false
			end
			local side = buf == s.old_buf and "original" or "modified"
			local line = api.nvim_win_get_cursor(win)[1]
			for _, change in ipairs(s.diff.changes) do
				local range = change[side]
				if line >= range.start_line and line < range.end_line then
					api.nvim_buf_set_extmark(buf, cursorline_ns, line - 1, 0, {
						end_row = line,
						hl_group = buf == s.old_buf and "ReviewCursorLineDelete" or "ReviewCursorLineInsert",
						hl_eol = true,
						-- Above diff line fills (150), below changed tokens (200).
						priority = 175,
						ephemeral = true,
					})
					break
				end
			end
			return false
		end,
	})
	-- Check notes even while a composer pins the original source snapshot. This
	-- only updates badges/titles; it never refreshes the source or edits note text.
	do
		local timer = assert(vim.uv.new_timer())
		local checking = false
		timer:start(
			3000,
			3000,
			vim.schedule_wrap(function()
				if #api.nvim_list_uis() == 0 then
					return
				end
				local s = M.active() or require("rediff.annotations").context()
				if s and not checking then
					checking = true
					pcall(M.refresh_annotations, s.root)
					checking = false
				end
			end)
		)
		api.nvim_create_autocmd("VimLeavePre", {
			once = true,
			callback = function()
				timer:stop()
				timer:close()
			end,
		})
	end
	api.nvim_create_autocmd("ColorScheme", { callback = review_highlights })
	api.nvim_create_autocmd("OptionSet", {
		pattern = "wrap",
		callback = function()
			local s, win = M.state, api.nvim_get_current_win()
			if not s or (win ~= s.old_win and win ~= s.new_win) or vim.v.option_command == "setglobal" then
				return
			end
			s.wrap = vim.wo[win].wrap
			local other = win == s.old_win and s.new_win or s.old_win
			if other then
				vim.wo[other].wrap = s.wrap
			end
		end,
	})
	api.nvim_create_autocmd({ "WinEnter", "BufEnter" }, {
		callback = function()
			local s = M.state
			tree_focus(
				s ~= nil and api.nvim_get_current_win() == s.tree_win and api.nvim_get_current_buf() == s.tree_buf
			)
			if s and s.diff then
				render_comments(true, s)
			end
		end,
	})
	api.nvim_create_autocmd({ "WinLeave", "BufLeave" }, {
		callback = function()
			tree_focus(false)
		end,
	})
	api.nvim_create_autocmd("CursorMoved", {
		callback = function()
			local s = M.state
			if not s then
				return
			end
			local buf = api.nvim_get_current_buf()
			if buf == s.tree_buf then
				local cursor = api.nvim_win_get_cursor(0)
				local index = s.rows[cursor[1]]
				-- Closed and empty groups are selectable; hidden files and separators are not.
				local function selectable(row)
					local closed = vim.fn.foldclosed(row)
					local header = row == s.group_rows.staged
						or row == s.group_rows.unstaged
						or row == s.group_rows.branch
					return closed == row or (closed == -1 and (s.rows[row] ~= nil or (header and not s.rows[row + 1])))
				end
				local empty_group = s.exhausted_group and cursor[1] == s.group_rows[s.exhausted_group]
				if not selectable(cursor[1]) and not empty_group then
					local previous = s.tree_cursor or cursor[1]
					local step = cursor[1] < previous and -1 or 1
					for _, direction in ipairs({ step, -step }) do
						local boundary = direction > 0 and api.nvim_buf_line_count(buf) or 1
						for row = cursor[1] + direction, boundary, direction do
							if selectable(row) then
								cursor[1], index = row, s.rows[row]
								break
							end
						end
						if selectable(cursor[1]) then
							break
						end
					end
				end
				api.nvim_win_set_cursor(0, { cursor[1], 0 })
				s.tree_cursor = cursor[1]
				highlight_tree_selection(s)
				if index and (index ~= s.index or not s.current) then
					local entry = s.entries[index]
					local ok, snapshot = pcall(git.snapshot, s.root, entry)
					-- Git reads yield to input; do not reopen a row the user has left.
					if
						M.active() ~= s
						or api.nvim_get_current_win() ~= s.tree_win
						or s.entries[index] ~= entry
						or s.rows[api.nvim_win_get_cursor(s.tree_win)[1]] ~= index
					then
						return
					end
					if not ok then
						notify(tostring(snapshot), vim.log.levels.ERROR)
						return
					end
					guard(M.show)(index, snapshot)
					api.nvim_set_current_win(s.tree_win)
				end
				return
			end
			if not s.diff or (buf ~= s.old_buf and buf ~= s.new_buf) then
				return
			end
			render_comments(true)
			local side = buf == s.old_buf and "old" or "new"
			local line = api.nvim_win_get_cursor(0)[1]
			for i, change in ipairs(s.diff.changes) do
				local first, last = hunk_range(change, side, buf)
				if line >= first and line <= last then
					mark_hunk(i)
					return
				end
			end
			mark_hunk(nil)
		end,
	})
	api.nvim_create_user_command(
		"View",
		guard(function(opts)
			M.view(opts.args ~= "" and opts.args or nil)
		end),
		{
			nargs = "?",
			complete = function()
				return { "split", "merged" }
			end,
		}
	)
	vim.cmd(
		[[cnoreabbrev <expr> view getcmdtype() == ':' && getcmdline() == 'view' && getcmdpos() == 5 && luaeval("require('rediff.review').active() ~= nil") ? 'View' : 'view']]
	)
	api.nvim_create_user_command(
		"Focus",
		guard(function(opts)
			M.focus(opts.args)
		end),
		{
			nargs = 1,
			complete = function()
				return { "staged", "unstaged" }
			end,
		}
	)
	api.nvim_create_user_command(
		"Annotations",
		guard(function(opts)
			assert(M.active() or require("rediff.annotations").active(), "Enable annotation mode with Space a first")
			local actions = {
				list = M.list_comments,
				new = M.compose,
				next = function()
					M.next_comment(1)
				end,
				prev = function()
					M.next_comment(-1)
				end,
			}
			assert(actions[opts.args], "Usage: annotations list|next|prev|new")()
		end),
		{
			nargs = 1,
			complete = function()
				return { "list", "next", "prev", "new" }
			end,
		}
	)
	for alias, command in pairs({
		focus = "Focus",
		fs = "Focus staged",
		fu = "Focus unstaged",
		annotations = "Annotations",
		al = "Annotations list",
	}) do
		vim.cmd(
			string.format(
				[[cnoreabbrev <expr> %s getcmdtype() == ':' && getcmdline() == '%s' && getcmdpos() == %d && luaeval("require('rediff.review').active() ~= nil") ? '%s' : '%s']],
				alias,
				alias,
				#alias + 1,
				command,
				alias
			)
		)
	end
	api.nvim_create_user_command(
		"ReviewHarness",
		guard(function(opts)
			assert(#opts.fargs <= 2, "Usage: ReviewHarness [amp THREAD_ID | claude SESSION_ID | custom | none]")
			M.select_harness(opts.fargs[1], opts.fargs[2])
		end),
		{
			nargs = "*",
			complete = function()
				return { "amp", "claude", "custom", "none" }
			end,
		}
	)
	for _, name in ipairs({ "ReviewStage", "ReviewUnstage" }) do
		api.nvim_create_user_command(
			name,
			guard(function(opts)
				assert(opts.args == "hunk" or opts.args == "file", "Usage: " .. name .. " hunk|file")
				M.stage(opts.args == "file", name == "ReviewUnstage")
			end),
			{
				nargs = 1,
				complete = function()
					return { "hunk", "file" }
				end,
			}
		)
	end
	api.nvim_create_user_command(
		"ReviewRevert",
		guard(function(opts)
			M.revert(opts.line1, opts.line2)
		end),
		{ range = true, desc = "Revert selected Git hunks and notify the agent" }
	)
	api.nvim_create_user_command(
		"Git",
		guard(function(opts)
			local action = opts.fargs[1]
			assert(
				(action == "diff" and #opts.fargs == 3) or (action == "base" and #opts.fargs == 2),
				"Usage: git diff BASE TARGET | git base BASE (commit SHAs, branches, or tags)"
			)
			local root = M.state and M.state.root or git.root()
			local head = opts.fargs[3]
			if action == "base" then
				head = M.state and M.state.comparison and M.state.comparison.head or "HEAD"
			end
			M.open(root, git.comparison(root, opts.fargs[2], head))
		end),
		{
			nargs = "*",
			complete = function(lead, line, position)
				if line:sub(1, position):match("^%s*Git%s+%S*$") then
					return vim.tbl_filter(function(action)
						return vim.startswith(action, lead)
					end, { "base", "diff" })
				end
				return {}
			end,
		}
	)
	vim.cmd([[cnoreabbrev <expr> git getcmdtype() == ':' && getcmdline() == 'git' && getcmdpos() == 4 ? 'Git' : 'git']])
	vim.cmd(
		[[cnoreabbrev <expr> gd getcmdtype() == ':' && getcmdline() == 'gd' && getcmdpos() == 3 ? 'Git diff' : 'gd']]
	)
	local commands = {
		Review = M.open,
		ReviewLeave = M.leave,
		ReviewRefresh = M.refresh,
		ReviewComments = M.list_comments,
		ReviewRevertFlush = function()
			require("rediff.discards").flush(state().root)
		end,
		WriteFeedback = M.submit,
		ReviewRetry = harness.retry,
		ReviewArchive = function()
			if vim.fn.confirm("Archive this round and start empty?", "&Archive\n&Cancel", 2) == 1 then
				M.archive()
			end
		end,
		ReviewOutbox = function()
			local root = M.state and M.state.root or git.root()
			vim.cmd("tabnew " .. vim.fn.fnameescape(feedback.directory(root)))
		end,
	}
	for name, fn in pairs(commands) do
		api.nvim_create_user_command(
			name,
			guard(function()
				fn()
			end),
			{}
		)
	end
	api.nvim_create_autocmd("VimLeavePre", {
		callback = function()
			if M.state then
				require("rediff.live").stop(M.state)
				M.state.draft = nil
				save(M.state)
				vim.uv.fs_unlink(M.state.directory .. "/editor.lock")
			end
		end,
	})
	api.nvim_create_autocmd("TabClosed", {
		callback = function()
			if M.state and not api.nvim_tabpage_is_valid(M.state.tab) then
				M.leave()
			end
		end,
	})
	api.nvim_create_autocmd("WinClosed", {
		callback = function()
			vim.schedule(function()
				local s = M.state
				if not s then
					return
				end
				if
					(s.old_win and not api.nvim_win_is_valid(s.old_win))
					or not api.nvim_win_is_valid(s.new_win)
					or not api.nvim_win_is_valid(s.tree_win)
				then
					M.leave()
				end
			end)
		end,
	})
	api.nvim_create_autocmd("VimResized", {
		callback = function()
			local s = M.state
			if s then
				if api.nvim_win_is_valid(s.tree_win) then
					api.nvim_win_set_width(s.tree_win, math.min(28, math.floor(vim.o.columns / 5)))
				end
				if s.old_win and api.nvim_win_is_valid(s.old_win) and api.nvim_win_is_valid(s.new_win) then
					local width = api.nvim_win_get_width(s.old_win) + api.nvim_win_get_width(s.new_win)
					api.nvim_win_set_width(s.old_win, math.floor(width / 2))
				end
				render_comments(false, s)
			end
		end,
	})
end

return M
