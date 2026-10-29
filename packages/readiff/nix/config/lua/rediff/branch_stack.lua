local M = {}
local git = require("rediff.git")
local review = require("rediff.review")

function M.branches(root)
	local output = git.run(root, {
		"for-each-ref",
		"--format=%(objectname)%09%(refname:short)%09%(symref)",
		"refs/heads",
		"refs/remotes",
	})
	local by_commit, branches = {}, {}
	for _, line in ipairs(vim.split(output, "\n", { trimempty = true })) do
		local commit, ref, symbolic = unpack(vim.split(line, "\t"))
		if symbolic == "" then
			local branch = by_commit[commit]
			if not branch then
				branch = { commit = commit, ref = ref, names = {}, parents = {}, children = {} }
				by_commit[commit] = branch
				table.insert(branches, branch)
			end
			table.insert(branch.names, ref)
		end
	end
	for _, branch in ipairs(branches) do
		local merged = git.run(root, {
			"for-each-ref",
			"--merged=" .. branch.commit,
			"--format=%(objectname)",
			"refs/heads",
			"refs/remotes",
		})
		local ancestors = {}
		for _, commit in ipairs(vim.split(merged, "\n", { trimempty = true })) do
			if commit ~= branch.commit and by_commit[commit] then
				ancestors[commit] = true
			end
		end
		if next(ancestors) then
			local args = vim.list_extend({ "merge-base", "--independent" }, vim.tbl_keys(ancestors))
			for _, commit in ipairs(vim.split(git.run(root, args), "\n", { trimempty = true })) do
				table.insert(branch.parents, by_commit[commit])
			end
			table.sort(branch.parents, function(a, b)
				return a.ref < b.ref
			end)
			if #branch.parents == 1 then
				table.insert(branch.parents[1].children, branch)
			end
		end
	end
	return branches
end

function M.discover(root, base_ref, tip_ref)
	local endpoints = git.comparison(root, base_ref, tip_ref)
	local _, code = git.run(root, { "merge-base", "--is-ancestor", endpoints.base, endpoints.head }, nil, true)
	assert(code == 0, "Base must be an ancestor of tip. Use :git diff for arbitrary endpoints")
	local output = git.run(root, {
		"for-each-ref",
		"--contains=" .. endpoints.base,
		"--merged=" .. endpoints.head,
		"--format=%(objectname)%09%(refname:short)%09%(symref)",
		"refs/heads",
		"refs/remotes",
	})
	local candidates = {}
	for _, line in ipairs(vim.split(output, "\n", { trimempty = true })) do
		local sha, ref, symbolic = unpack(vim.split(line, "\t"))
		if symbolic == "" and sha ~= endpoints.base and sha ~= endpoints.head then
			if candidates[sha] then
				table.insert(candidates[sha].names, ref)
			else
				candidates[sha] = { commit = sha, ref = ref, names = { ref } }
			end
		end
	end
	local initial_review = review.state
	local initial_directory = vim.fn.getcwd()
	local chain = { { commit = endpoints.head, ref = tip_ref } }

	local function advance()
		assert(
			review.state == initial_review and vim.fn.getcwd() == initial_directory,
			"Review changed. Run :git branch-stack again"
		)
		local current = chain[#chain]
		local ancestors = {}
		for sha in pairs(candidates) do
			local _, result = git.run(root, { "merge-base", "--is-ancestor", sha, current.commit }, nil, true)
			if result == 0 then
				table.insert(ancestors, sha)
			end
		end
		if #ancestors == 0 then
			table.insert(chain, { commit = endpoints.base, ref = base_ref })
			local comparisons = {}
			for index = #chain, 2, -1 do
				local base, head = chain[index], chain[index - 1]
				local comparison = { base = base.commit, head = head.commit, base_ref = base.ref, head_ref = head.ref }
				table.insert(comparisons, comparison)
			end
			require("rediff.comparison_stack").set(root, comparisons)
			return
		end
		local arguments = vim.list_extend({ "merge-base", "--independent" }, ancestors)
		local parents = vim.split(git.run(root, arguments), "\n", { trimempty = true })
		local function choose(sha)
			if not sha then
				return
			end
			table.insert(chain, candidates[sha])
			candidates[sha] = nil
			local ok, err = pcall(advance)
			if not ok then
				vim.notify(tostring(err), vim.log.levels.ERROR)
			end
		end
		if #parents == 1 then
			choose(parents[1])
		else
			table.sort(parents, function(a, b)
				return candidates[a].ref < candidates[b].ref
			end)
			local rows = {}
			for index, sha in ipairs(parents) do
				rows[index] = index .. " · " .. table.concat(candidates[sha].names, " / ") .. " · " .. sha:sub(1, 12)
			end
			require("fzf-lua").fzf_exec(rows, {
				prompt = "Parent branch> ",
				header = "Ambiguous ancestry for " .. current.ref .. " · Choose parent · Esc cancel",
				fzf_opts = { ["--no-sort"] = true },
				actions = {
					["default"] = function(selected)
						local index = selected[1] and tonumber(selected[1]:match("^%d+"))
						choose(index and parents[index])
					end,
				},
			})
		end
	end
	advance()
end

return M
