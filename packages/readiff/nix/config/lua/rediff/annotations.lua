-- File-buffer lifecycle and shared annotation controls. The composer, notes,
-- snapshot navigation and delivery remain the same implementation as Review.
local M = {}
local api = vim.api
local views = {}
local ns = api.nvim_create_namespace("rediff.annotations")

function M.active()
	local buf = api.nvim_get_current_buf()
	for source, s in pairs(views) do
		if s.enabled and (buf == source or buf == s.composer) then
			if buf == source then
				s.new_win = api.nvim_get_current_win()
			end
			return s
		end
	end
end

local function visible(root)
	local selected, source_win
	for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
		local s = views[api.nvim_win_get_buf(win)]
		if s and s.enabled and (not root or s.root == root) then
			if selected and selected ~= s then
				return -- Do not choose between different annotated files.
			end
			selected, source_win = s, win
		end
	end
	if selected then
		selected.new_win = source_win
	end
	return selected
end

function M.context()
	return M.active()
		or views[api.nvim_get_current_buf()]
		or (vim.b.rediff_harness_root and visible(vim.b.rediff_harness_root))
end

-- Return an undo operation so file mode restores existing buffer-local maps;
-- deleting our overrides also reveals any original global maps.
function M.bind(buf, source)
	local review = require("rediff.review")
	local previous = {}
	local function map(mode, key, fn, description)
		local old = api.nvim_buf_call(buf, function()
			return vim.fn.maparg(key, mode, false, true)
		end)
		table.insert(previous, { mode = mode, key = key, old = old })
		vim.keymap.set(mode, key, function()
			local ok, err = pcall(fn)
			if not ok then
				vim.notify(tostring(err), vim.log.levels.ERROR, { title = "rediff" })
			end
		end, { buffer = buf, desc = description })
	end
	if source then
		for _, key in ipairs({
			"i",
			"a",
			"o",
			"O",
			"I",
			"A",
			"c",
			"C",
			"r",
			"R",
			"D",
			"x",
			"X",
			"p",
			"P",
			"u",
			"<C-r>",
			".",
			"~",
			">",
			"<",
			"=",
			"J",
			"gJ",
			"gq",
			"gw",
			"gu",
			"gU",
			"g~",
			"gp",
			"gP",
		}) do
			map("n", key, function()
				local prefix = '"' .. vim.v.register .. (vim.v.count > 0 and tostring(vim.v.count) or "")
				if key == "i" then
					review.edit_comment()
				else
					review.compose(false, prefix .. key)
				end
			end, "Comment instead of editing code")
		end
		map("n", "d", review.delete_comment, "Delete annotation on this line")
		for _, key in ipairs({ "a", "i", "<leader>c" }) do
			map("x", key, function()
				review.compose(true)
			end, "Comment on exact selection")
		end
	end
	if source and views[buf] then
		map("n", "<Esc>", function()
			if not views[buf].composer then
				M.toggle()
			end
		end, "Leave file annotation mode when no note is open")
	end
	map("n", "@", review.list_comments, "Find/jump to annotations")
	for key, direction in pairs({ ["}"] = 1, ["{"] = -1 }) do
		map("n", key, function()
			for _ = 1, vim.v.count1 do
				review.next_comment(direction)
			end
		end, direction > 0 and "Next annotation" or "Previous annotation")
	end
	return function()
		api.nvim_buf_call(buf, function()
			for _, binding in ipairs(previous) do
				vim.keymap.del(binding.mode, binding.key, { buffer = buf })
				if binding.old.buffer == 1 then
					vim.fn.mapset(binding.mode, false, binding.old)
				end
			end
		end)
	end
end

local function disable(s)
	assert(not s.composer, "Save or close the annotation before leaving annotation mode")
	s.enabled = false
	s.restore_maps()
	api.nvim_del_autocmd(s.write_autocmd)
	vim.bo[s.new_buf].modifiable = s.modifiable
	api.nvim_buf_clear_namespace(s.new_buf, ns, 0, -1)
	vim.cmd.redrawstatus()
end

function M.toggle()
	local review = require("rediff.review")
	if review.active() then
		vim.notify("Annotation mode is always on in Review", vim.log.levels.INFO, { title = "rediff" })
		return
	end
	local active = M.active()
	if active then
		disable(active)
		return
	end
	local buf, path = api.nvim_get_current_buf(), api.nvim_buf_get_name(0)
	if vim.bo[buf].buftype ~= "" or path == "" then
		local source = visible(vim.b.rediff_harness_root)
		assert(source, "Focus a named source file in a Git checkout to toggle annotations; the harness pane is only for agent input")
		api.nvim_set_current_win(source.new_win)
		disable(source)
		return
	end
	local git = require("rediff.git")
	local root = vim.trim(git.run(vim.fs.dirname(path), { "rev-parse", "--show-toplevel" }))
	root = vim.uv.fs_realpath(root) or root
	path = vim.uv.fs_realpath(path) or path
	assert(path:sub(1, #root + 1) == root .. "/", "File is outside the repository")
	local snapshot = git.buffer_snapshot(root, path:sub(#root + 2), buf)
	local notes = review.notes(root)
	local s = {
		root = root,
		directory = notes.directory,
		comments = notes.comments,
		drafts = notes.drafts,
		snapshots = notes.snapshots,
		harness = notes.harness,
		id = "file-" .. buf,
		file_mode = true,
		enabled = true,
		current = snapshot,
		new_buf = buf,
		new_win = api.nvim_get_current_win(),
		tick = api.nvim_buf_get_changedtick(buf),
		modifiable = vim.bo[buf].modifiable,
	}
	s.snapshots[snapshot.id] = snapshot
	views[buf] = s
	s.restore_maps = M.bind(buf, true)
	s.write_autocmd = api.nvim_create_autocmd("BufWriteCmd", {
		buffer = buf,
		callback = function(event)
			assert(event.match == api.nvim_buf_get_name(buf), "Leave annotation mode with Space a before writing another file")
			review.submit()
		end,
	})
	vim.bo[buf].modifiable = false
	review.render_comments(false, s)
end

function M.refresh()
	for buf, s in pairs(views) do
		if not api.nvim_buf_is_valid(buf) then
			views[buf] = nil
		elseif s.enabled then
			local ids = {}
			for _, comment in ipairs(s.comments) do
				ids[comment.id] = true
			end
			if not ids[s.annotation_id] then
				s.annotation_id = nil
			end
			if s.draft and not ids[s.draft.comment_id] then
				s.draft.comment_id = nil
			end
			-- External reloads must not leave notes attached to different text.
			if s.tick ~= api.nvim_buf_get_changedtick(buf) and not s.composer then
				local text = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
				local captured = table.concat(require("rediff.git").lines(s.current.new), "\n")
				if text ~= captured then
					disable(s)
				end
				s.tick = api.nvim_buf_get_changedtick(buf)
			end
			if
				s.enabled
				and api.nvim_win_is_valid(s.new_win)
				and api.nvim_win_get_tabpage(s.new_win) == api.nvim_get_current_tabpage()
				and api.nvim_win_get_buf(s.new_win) == buf
			then
				require("rediff.review").render_comments(false, s)
			end
		end
	end
end

function M.setup()
	local function toggle()
		local ok, err = pcall(M.toggle)
		if not ok then
			vim.notify(tostring(err), vim.log.levels.ERROR, { title = "rediff" })
		end
	end
	vim.keymap.set("n", "<leader>a", toggle, { desc = "Toggle annotation mode for this file" })
	api.nvim_create_user_command("AnnotationMode", toggle, {})
	api.nvim_create_autocmd("BufUnload", {
		callback = function(event)
			local s = views[event.buf]
			if s and s.enabled then
				if s.composer then
					require("rediff.review").release_composer(s)
				end
				disable(s)
			end
			views[event.buf] = nil
		end,
	})
	api.nvim_create_autocmd({ "BufEnter", "CursorMoved", "TextChanged", "VimResized" }, {
		callback = function()
			vim.schedule(function()
				M.active() -- Track whichever window currently displays the file.
				M.refresh()
			end)
		end,
	})
end

return M
