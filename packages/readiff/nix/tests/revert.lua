local tests = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")

return function(equal, fails)
	local git = require("rediff.git")
	local root, baseline, changed, run = dofile(tests .. "/fixture.lua").create()
	local function snapshot(path, group)
		return git.snapshot(root, { path = path or "auth.lua", group = group or "unstaged" })
	end
	local function read()
		return vim.fn.readfile(root .. "/auth.lua")
	end
	local ok, err = xpcall(function()
		local original = snapshot()
		local index = run({ "write-tree" })
		git.revert(root, original, "old", 17)
		local partial = vim.deepcopy(baseline)
		partial[5] = changed[5]
		equal(partial, read(), "Revert keeps the unselected hunk")
		equal(index, run({ "write-tree" }), "Unstaged revert leaves index unchanged")
		fails(function()
			git.revert(root, original, "new", 5)
		end, "Reviewed content changed")
		equal(partial, read(), "Stale revert preserves current contents")
		fails(function()
			git.revert(root, snapshot(), "new", 12)
		end, "Move the cursor into a Git hunk")
		vim.fn.writefile(changed, root .. "/auth.lua")
		git.revert(root, snapshot(), "new", 5, 17)
		equal(baseline, read(), "Range reverts both intersecting hunks")

		git.revert(root, snapshot("removed.lua"), "new", 1)
		equal(
			{ "local obsolete = true", "return obsolete" },
			vim.fn.readfile(root .. "/removed.lua"),
			"Restore deleted file"
		)
		local name = 'new "quoted" ü.txt'
		vim.fn.writefile({ "no trailing newline" }, root .. "/" .. name, "b")
		git.revert(root, snapshot(name, "untracked"), "old", 1)
		equal(0, vim.fn.filereadable(root .. "/" .. name), "Discard new file with quoted path and no final newline")

		vim.fn.writefile(changed, root .. "/auth.lua")
		run({ "add", "auth.lua" })
		local staged = snapshot(nil, "staged")
		vim.fn.writefile({ "new agent edit" }, root .. "/auth.lua")
		fails(function()
			git.revert(root, staged, "new", 5)
		end, "unstaged edits")
		equal({ "new agent edit" }, read(), "Staged revert cannot overwrite unstaged work")
		equal(changed, git.lines(run({ "show", ":auth.lua" })), "Rejected staged revert preserves index")
		vim.fn.writefile(changed, root .. "/auth.lua")
		local restored_stat = assert(vim.uv.fs_stat(root .. "/auth.lua"))
		assert(vim.uv.fs_utime(root .. "/auth.lua", restored_stat.atime.sec, restored_stat.mtime.sec + 2))
		git.revert(root, staged, "new", 17)
		equal(partial, read(), "Staged revert updates worktree")
		equal(partial, git.lines(run({ "show", ":auth.lua" })), "Staged revert updates only selected index hunk")

		run({ "rm", "removed.lua" })
		git.revert(root, snapshot("removed.lua", "staged"), "old", 1)
		local restored = { "local obsolete = true", "return obsolete" }
		equal(restored, vim.fn.readfile(root .. "/removed.lua"), "Staged deletion revert restores the file")
		equal(restored, git.lines(run({ "show", ":removed.lua" })), "Staged deletion revert restores the index entry")

		-- Unequal insertion/deletion sizes expose old/new coordinate confusion.
		local lines = {}
		for i = 1, 50 do
			lines[i] = "line " .. i
		end
		vim.fn.writefile(lines, root .. "/auth.lua", "b")
		run({ "add", "auth.lua" })
		run({ "commit", "-qm", "Asymmetric fixture" })
		local edits = vim.deepcopy(lines)
		table.remove(edits, 40)
		table.insert(edits, 4, "inserted A")
		table.insert(edits, 5, "inserted B")
		vim.fn.writefile(edits, root .. "/auth.lua", "b")
		assert(vim.uv.fs_chmod(root .. "/auth.lua", 493))
		git.revert(root, snapshot(), "old", 40)
		local expected = vim.deepcopy(lines)
		table.insert(expected, 4, "inserted A")
		table.insert(expected, 5, "inserted B")
		equal(expected, read(), "Deletion uses old coordinates despite preceding insertion")
		git.revert(root, snapshot(), "new", 4)
		equal(lines, read(), "Insertion reversal preserves missing final newline")
		equal(
			true,
			run({ "diff", "--summary" }):find("100644 => 100755", 1, true) ~= nil,
			"Text revert preserves mode-only change"
		)
	end, debug.traceback)
	vim.fn.delete(root, "rf")
	assert(ok, err)
end
