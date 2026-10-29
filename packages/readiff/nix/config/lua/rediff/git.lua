local M = {}

function M.run(root, args, input, allow_failure)
	local argv = { "git", "--literal-pathspecs", "-C", root }
	vim.list_extend(argv, args)
	local result = vim.system(argv, { stdin = input, text = false }):wait(10000)
	if not allow_failure and result.code ~= 0 then
		error(vim.trim(result.stderr or "Git failed"))
	end
	return result.stdout or "", result.code
end

function M.root()
	return vim.trim(M.run(vim.fn.getcwd(), { "rev-parse", "--show-toplevel" }))
end

function M.reference(root)
	local branch, code = M.run(root, { "symbolic-ref", "--quiet", "--short", "HEAD" }, nil, true)
	if code == 0 then
		return vim.trim(branch)
	end
	return "@" .. vim.trim(M.run(root, { "rev-parse", "--short", "HEAD" }))
end

local function paths(root, args)
	return vim.split(M.run(root, args), "\0", { plain = true, trimempty = true })
end

local function blob(root, revision, path)
	local text, code = M.run(root, { "show", revision .. ":" .. path }, nil, true)
	if code ~= 0 then
		return ""
	end
	return text
end

function M.comparison(root, base, head)
	local function resolve(ref)
		return vim.trim(M.run(root, { "rev-parse", "--verify", "--end-of-options", ref .. "^{commit}" }))
	end
	return { base = resolve(base), head = head and resolve(head) }
end

function M.entries(root, comparison)
	if not comparison or not comparison.head then
		assert(
			#paths(root, { "diff", "--name-only", "--diff-filter=U", "-z" }) == 0,
			"Resolve merge conflicts before entering Review"
		)
	end
	if comparison then
		local args = { "diff", "--name-status", "--no-renames", "-z", comparison.base }
		if comparison.head then
			table.insert(args, comparison.head)
		end
		table.insert(args, "--")
		local fields = paths(root, args)
		local result, seen = {}, {}
		for i = 1, #fields, 2 do
			local entry = {
				path = fields[i + 1],
				group = comparison.head and "branch" or "worktree",
				status = fields[i],
				base = comparison.base,
				head = comparison.head,
			}
			table.insert(result, entry)
			seen[entry.path] = entry
		end
		if not comparison.head then
			for _, path in ipairs(paths(root, { "ls-files", "--others", "--exclude-standard", "-z" })) do
				if seen[path] then
					seen[path].group, seen[path].status = "untracked", "U"
				else
					table.insert(result, { path = path, group = "untracked", status = "U", base = comparison.base })
				end
			end
		end
		return result
	end
	local result = {}
	for _, group in ipairs({ "staged", "unstaged", "untracked" }) do
		local args = { "diff", "--name-status", "--find-renames", "-z" }
		if group == "staged" then
			table.insert(args, "--cached")
		elseif group == "untracked" then
			args = { "ls-files", "--others", "--exclude-standard", "-z" }
		end
		local fields = paths(root, args)
		local i = 1
		while i <= #fields do
			if group == "untracked" then
				table.insert(result, { path = fields[i], group = group, status = "U" })
				i = i + 1
			else
				local status = fields[i]:sub(1, 1)
				table.insert(result, { path = fields[i + 1], group = group, status = status })
				i = i + 2
				if status == "R" then
					-- Keep per-path snapshots/staging for the two sides of a rename.
					table.insert(result, { path = fields[i], group = group, status = status })
					i = i + 1
				end
			end
		end
	end
	return result
end

function M.line_totals(root, entries, comparison)
	local totals = { added = 0, deleted = 0 }
	local untracked = {}
	for _, entry in ipairs(entries) do
		if entry.group == "untracked" then
			untracked[entry.path] = true
		end
	end
	local function add_diff(revisions, untracked_path, old_text)
		local args = { "diff", "--no-ext-diff", "--no-textconv", "--no-renames", "--numstat", "-z" }
		local old_file
		if untracked_path then
			if old_text and old_text ~= "" then
				old_file = vim.fn.tempname()
				local fd = assert(vim.uv.fs_open(old_file, "w", 384))
				assert(vim.uv.fs_write(fd, old_text, 0))
				assert(vim.uv.fs_close(fd))
			end
			vim.list_extend(args, { "--no-index", "--", old_file or "/dev/null", root .. "/" .. untracked_path })
		else
			vim.list_extend(args, revisions)
			table.insert(args, "--")
		end
		local output, code = M.run(root, args, nil, untracked_path ~= nil)
		if old_file then
			assert(vim.uv.fs_unlink(old_file))
		end
		assert(code == 0 or code == 1, "Cannot count changed lines: " .. (untracked_path or root))
		local records = vim.split(output, "\0", { plain = true })
		local index = 1
		while index <= #records do
			local added, deleted, path = records[index]:match("^(%S+)\t(%S+)\t(.*)$")
			-- A path removed from the index can still exist as an untracked file.
			local counted_separately = comparison and untracked[path] and not untracked_path
			if tonumber(added) and not counted_separately then
				totals.added = totals.added + tonumber(added)
				totals.deleted = totals.deleted + tonumber(deleted)
			end
			-- No-index records with different paths have two extra NUL-delimited fields.
			index = index + (path == "" and 3 or 1)
		end
	end

	if comparison then
		add_diff({ comparison.base, comparison.head })
	else
		add_diff({ "--cached" })
		add_diff({})
	end
	for _, entry in ipairs(entries) do
		if entry.group == "untracked" then
			local old_text = entry.base and blob(root, entry.base, entry.path)
			add_diff({}, entry.path, old_text)
		end
	end
	return totals
end

local function worktree(root, path)
	local file = root .. "/" .. path
	local stat = vim.uv.fs_lstat(file)
	if not stat then
		return ""
	end
	assert(stat.type == "file", "Review currently supports regular files only: " .. path)
	assert(stat.size <= 2 * 1024 * 1024, "File exceeds the 2 MiB review limit: " .. path)
	local fd = assert(vim.uv.fs_open(file, "r", 0))
	local data = assert(vim.uv.fs_read(fd, stat.size, 0))
	assert(vim.uv.fs_close(fd))
	return data
end

function M.lines(text)
	local lines = vim.split(text, "\n", { plain = true })
	if lines[#lines] == "" then
		table.remove(lines)
	end
	return lines
end

function M.snapshot(root, entry, buffer_text)
	local old, new, patch
	if entry.group == "buffer" then
		-- Full editor text, not a claim that the whole file is a Git addition.
		new = buffer_text or worktree(root, entry.path):gsub("\r\n", "\n")
		old, patch = new, ""
	elseif entry.group == "untracked" then
		old = entry.base and blob(root, entry.base, entry.path) or ""
		new = worktree(root, entry.path)
		patch = vim.diff(old, new, { result_type = "unified", ctxlen = 3 })
	else
		if entry.group == "branch" then
			old, new = blob(root, entry.base, entry.path), blob(root, entry.head, entry.path)
		elseif entry.group == "worktree" then
			old, new = blob(root, entry.base, entry.path), worktree(root, entry.path)
		else
			old = blob(root, entry.group == "staged" and "HEAD" or "", entry.path)
			new = entry.group == "staged" and blob(root, "", entry.path) or worktree(root, entry.path)
		end
		local args =
			{ "diff", "--no-ext-diff", "--no-textconv", "--no-renames", "--no-color", "--binary", "--unified=3" }
		if entry.group == "branch" then
			vim.list_extend(args, { entry.base, entry.head })
		elseif entry.group == "worktree" then
			table.insert(args, entry.base)
		elseif entry.group == "staged" then
			table.insert(args, "--cached")
		end
		vim.list_extend(args, { "--", entry.path })
		patch = M.run(root, args)
	end
	assert(not old:find("\0", 1, true) and not new:find("\0", 1, true), "Binary files cannot be annotated")
	assert(#old <= 2 * 1024 * 1024 and #new <= 2 * 1024 * 1024, "File exceeds the 2 MiB review limit")
	local head = entry.group == "branch" and entry.head
		or vim.trim(M.run(root, { "rev-parse", "--verify", "HEAD" }, nil, true))
	local identity = { root, entry.group, entry.path, head, vim.fn.sha256(old), vim.fn.sha256(new), patch }
	if entry.base then
		table.insert(identity, entry.base)
	end
	local id = vim.fn.sha256(table.concat(identity, "\0"))
	return {
		id = id,
		path = entry.path,
		group = entry.group,
		base = entry.base,
		head = head,
		old = old,
		new = new,
		patch = patch,
	}
end

function M.buffer_snapshot(root, path, buf)
	local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
	if vim.bo[buf].endofline then
		text = text .. "\n"
	end
	return M.snapshot(root, { group = "buffer", path = path }, text)
end

function M.validate(root, snapshot)
	assert(
		M.snapshot(root, snapshot).id == snapshot.id,
		"Reviewed content changed: " .. snapshot.path .. ". Refresh and review again; drafts are preserved."
	)
end

-- Use Git's own patch, preserving path quoting, context and missing-newline markers.
function M.hunks(patch)
	local header, hunks = {}, {}
	for line in (patch .. "\n"):gmatch("(.-)\n") do
		local a, ac, b, bc = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
		if a then
			table.insert(hunks, {
				old_start = tonumber(a),
				old_count = tonumber(ac) or 1,
				new_start = tonumber(b),
				new_count = tonumber(bc) or 1,
				lines = { line },
			})
		elseif #hunks > 0 then
			if line ~= "" then
				table.insert(hunks[#hunks].lines, line)
			end
		else
			table.insert(header, line)
		end
	end
	return header, hunks
end

function M.stage(root, snapshot, side, line, whole_file)
	assert(not snapshot.base, "Staging is unavailable in base/commit comparisons; use :Review for staging")
	M.validate(root, snapshot)
	if snapshot.group == "untracked" then
		local _, hunks = M.hunks(snapshot.patch)
		assert(whole_file or hunks[1], "Empty new files must be staged with S")
		M.run(root, { "add", "--", snapshot.path })
		return not whole_file and hunks[1] or nil
	end
	local patch = snapshot.patch
	local chosen
	if not whole_file then
		assert(not patch:find("\ndeleted file mode ", 1, true), "Deleted files must be staged or unstaged with S")
		local header, hunks = M.hunks(patch)
		for _, hunk in ipairs(hunks) do
			local start = hunk[side .. "_start"]
			local count = hunk[side .. "_count"]
			if line >= math.max(start, 1) and line < math.max(start, 1) + math.max(count, 1) then
				chosen = hunk
				break
			end
		end
		assert(chosen, "Move the cursor into a Git hunk to stage it")
		patch = table.concat(header, "\n") .. "\n" .. table.concat(chosen.lines, "\n") .. "\n"
	end
	assert(patch ~= "", "No patch to stage")
	local args = { "apply", "--cached", "--whitespace=nowarn" }
	if snapshot.group == "staged" then
		table.insert(args, "--reverse")
	end
	M.run(root, args, patch)
	return chosen
end

-- Reverse only the selected Git hunks, never replace a whole-file snapshot.
function M.revert(root, snapshot, side, first, last)
	assert(not snapshot.base, "Reverting is unavailable in base/commit comparisons; use :Review for reverting")
	assert(snapshot.group ~= "buffer", "Refresh to current Git changes before reverting")
	M.validate(root, snapshot)
	local patch = snapshot.patch
	if snapshot.group == "untracked" then
		-- Git supplies correctly quoted paths and new-file metadata (including mode).
		local code
		patch, code = M.run(root, {
			"diff",
			"--no-ext-diff",
			"--no-textconv",
			"--no-color",
			"--binary",
			"--unified=3",
			"--no-index",
			"--",
			"/dev/null",
			snapshot.path,
		}, nil, true)
		assert(code == 1, "No text hunk to revert")
		-- The patch was read from disk, unlike tracked snapshots' saved patches.
		M.validate(root, snapshot)
	end
	local header, hunks = M.hunks(patch)
	-- A text-hunk action must not discard a separate executable-bit change.
	header = vim.tbl_filter(function(line)
		return not line:match("^old mode ") and not line:match("^new mode ")
	end, header)
	local chosen, parts = {}, { table.concat(header, "\n") }
	for _, hunk in ipairs(hunks) do
		local start = math.max(1, hunk[side .. "_start"])
		local finish = start + math.max(1, hunk[side .. "_count"]) - 1
		if first <= finish and (last or first) >= start then
			table.insert(chosen, hunk)
			table.insert(parts, table.concat(hunk.lines, "\n"))
		end
	end
	assert(#chosen > 0, "Move the cursor into a Git hunk to revert it")
	patch = table.concat(parts, "\n") .. "\n"
	local args = { "apply", "--reverse", "--whitespace=nowarn" }
	if snapshot.group == "staged" then
		assert(
			worktree(root, snapshot.path) == snapshot.new,
			"File has unstaged edits; unstage the hunk before reverting it"
		)
		-- Git's --index check also requires current cached file metadata.
		if not patch:find("\ndeleted file mode ", 1, true) then
			M.run(root, { "add", "--refresh", "--", snapshot.path })
		end
		table.insert(args, "--index")
	end
	M.run(root, args, patch)
	return chosen
end

return M
