local M = {}
local api = vim.api
local history = require("rediff.history")
local git = require("rediff.git")
local review = require("rediff.review")
local stack = require("rediff.comparison_stack")

local function root()
	return review.state and review.state.root or git.root()
end

local function guarded(fn)
	local ok, err = pcall(fn)
	if not ok then
		vim.notify(tostring(err), vim.log.levels.ERROR)
	end
end

local function compare(args)
	local action = args[1]
	local directory = root()
	local function open(base, head)
		guarded(function()
			assert(root() == directory, "Worktree changed. Choose the comparison again")
			if action == "branch-stack" then
				require("rediff.branch_stack").discover(directory, base, head or "HEAD")
			else
				stack.set(directory, { git.comparison(directory, base, head) })
			end
		end)
	end
	if #args == 1 then
		vim.ui.input({ prompt = "Base ref (OLD): ", completion = "customlist,v:lua.RediffGitRefs" }, function(base)
			if not base or base == "" then
				return
			end
			if action == "base" then
				open(base)
			else
				vim.ui.input({
					prompt = "Target ref (NEW): ",
					completion = "customlist,v:lua.RediffGitRefs",
					default = action == "branch-stack" and "HEAD" or nil,
				}, function(head)
					if head and head ~= "" then
						open(base, head)
					end
				end)
			end
		end)
		return
	end
	assert(
		(action == "diff" and #args == 3)
			or (action == "base" and #args == 2)
			or (action == "branch-stack" and (#args == 2 or #args == 3)),
		"Usage: git diff BASE TARGET | git base BASE|reset | git branch-stack BASE [TIP]"
	)
	if action == "base" and args[2] == "reset" then
		review.open(directory)
		return
	end
	open(args[2], args[3])
end

local function scope()
	local directory = root()
	local choices = { "Local changes", "Compare with working files", "Compare two commits" }
	require("fzf-lua").fzf_exec(choices, {
		prompt = "Review scope> ",
		winopts = { width = 0.55, height = 0.3 },
		fzf_opts = { ["--no-sort"] = true, ["--no-multi"] = true },
		actions = {
			["default"] = function(selected)
				local choice = selected[1]
				if not choice then
					return
				end
				guarded(function()
					assert(root() == directory, "Worktree changed. Choose the scope again")
					if choice == choices[1] then
						review.open(directory)
					else
						compare({ choice == choices[2] and "base" or "diff" })
					end
				end)
			end,
		},
	})
end

local function commits()
	local directory = root()
	local previous = review.state and review.state.comparison
	local function select_endpoint(selected, endpoint)
		if not selected[1] then
			return
		end
		guarded(function()
			assert(root() == directory, "Worktree changed. Choose the commit again")
			local ref = selected[1]:match("^%x+")
			local commit = git.comparison(directory, ref).base
			local current = previous or git.comparison(directory, "HEAD")
			local comparison = {
				base = current.base,
				base_ref = current.base_ref,
				head = current.head,
				head_ref = current.head_ref,
			}
			if endpoint == "base" then
				comparison.base, comparison.base_ref = commit, ref
			else
				comparison.head, comparison.head_ref = commit, ref
			end
			stack.set(directory, { comparison })
		end)
	end
	require("fzf-lua").git_commits({
		cwd = directory,
		cmd = "git log --all --date-order --decorate=short --color=never --format='%h %s %d'",
		prompt = "History> ",
		header = "Enter: base · Ctrl-t: target · Esc: cancel",
		winopts = { preview = { hidden = false, layout = "vertical", vertical = "down:60%" } },
		fzf_opts = { ["--no-sort"] = true },
		actions = {
			["enter"] = function(selected)
				select_endpoint(selected, "base")
			end,
			["ctrl-t"] = function(selected)
				select_endpoint(selected, "target")
			end,
			["ctrl-d"] = false,
		},
	})
end

local function comparisons(args)
	local directory = root()
	if #args == 1 then
		if stack.choose(directory) then
			return
		end
		vim.ui.input({ prompt = "Stack refs (base to tip, space-separated): " }, function(input)
			if not input or vim.trim(input) == "" then
				return
			end
			guarded(function()
				assert(root() == directory, "Worktree changed. Choose the comparison again")
				local refs = vim.split(input, "%s+", { trimempty = true })
				local arguments = vim.list_extend({ "stack" }, refs)
				comparisons(arguments)
			end)
		end)
		return
	end
	assert(#args >= 3, "Usage: git stack REF REF ... (at least two refs)")
	local items = {}
	for index = 2, #args - 1 do
		table.insert(items, git.comparison(directory, args[index], args[index + 1]))
	end
	stack.set(directory, items)
end

local function details()
	local s = review.state
	assert(s and s.comparison, "Open a comparison with :git diff or :git base first")
	local comparison = s.comparison
	local index, count = stack.position(s.root, comparison)
	local lines = {
		git.comparison_label(comparison),
		index and string.format("Comparison %d of %d", index, count) or "Comparison",
		"",
		"OLD  " .. comparison.base,
		"NEW  " .. (comparison.head or "WORKTREE (saved staged, unstaged, and untracked files)"),
		"",
		"Checkout: " .. git.reference(s.root),
		"Worktree: " .. s.root,
		require("rediff.harness").statusline(s.root),
		"",
		comparison.pr and ":git pr-stack reloads comparisons from GitHub."
			or ":git refresh-refs resolves the input refs again.",
		"Notes and feedback remain shared within this worktree.",
	}
	if comparison.pr then
		local pr = comparison.pr
		vim.list_extend(lines, {
			"",
			pr.repository .. " · Stack #" .. pr.stack .. " · " .. pr.state,
			"PR #" .. pr.number .. " · " .. pr.title,
			pr.url,
		})
	end
	require("rediff.git_popup")
		.open("Comparison · OLD → NEW", "q/Esc close · Space gu up · Space gd down")
		.show(lines)
end

local actions = {
	base = {
		run = compare,
		arguments = true,
		usage = "base [BASE|reset]",
		description = "Compare a ref to working files, or reset to local Review",
	},
	diff = {
		run = compare,
		arguments = true,
		usage = "diff BASE TARGET (or prompt)",
		description = "Compare two Git refs",
		key = "gD",
	},
	stack = {
		run = comparisons,
		arguments = true,
		usage = "stack [REF REF ...]",
		description = "Choose or define a comparison stack",
	},
	scope = {
		run = scope,
		description = "Choose Local changes or an explicit comparison",
		key = "gs",
	},
	history = { run = commits, description = "Browse commits and choose a comparison endpoint", key = "gh" },
	["pr-stack"] = {
		run = function()
			require("rediff.pr_stack").discover(root())
		end,
		description = "Discover GitHub PR stacks",
		key = "gS",
	},
	["branch-stack"] = {
		run = compare,
		arguments = true,
		usage = "branch-stack [BASE [TIP]]",
		description = "Discover stacked branches using Git ancestry",
	},
	up = {
		run = function()
			stack.move(root(), 1)
		end,
		description = "Next comparison toward the tip",
		key = "gu",
	},
	down = {
		run = function()
			stack.move(root(), -1)
		end,
		description = "Previous comparison toward the base",
		key = "gd",
	},
	comparison = { run = details, description = "Show comparison refs, commits, and checkout", key = "gc" },
	["refresh-refs"] = {
		run = function()
			stack.refresh(root())
		end,
		description = "Resolve current comparison refs again",
	},
	blame = { run = history.blame, description = "Browse blame for every source line", key = "gB" },
	["blame-line"] = {
		run = function()
			history.blame_line(false)
		end,
		description = "Show this line's author, date and commit",
		key = "gb",
	},
	["blame-toggle"] = { run = history.toggle_inline, description = "Toggle inline blame" },
	toggle = { run = history.toggle_inline, description = "Toggle inline blame", key = "gi" },
	["copy-link"] = { run = history.copy_link, description = "Copy a permalink to this line" },
	pr = {
		run = function()
			history.blame_line(true)
		end,
		description = "Show this line's associated GitHub PR links",
		key = "gp",
	},
}

local function help()
	local lines = {
		"Commands · :git · Tab completes actions · scripts use :Git",
	}
	for _, name in ipairs(vim.fn.sort(vim.tbl_keys(actions))) do
		local action = actions[name]
		table.insert(lines, "  " .. (action.usage or name) .. "  · " .. action.description)
	end
	vim.list_extend(lines, {
		"  :gd BASE TARGET        Typed shortcut for :git diff BASE TARGET",
		"",
		"Configured shortcuts · Normal mode",
	})
	local shortcuts = {}
	for _, mapping in ipairs(api.nvim_get_keymap("n")) do
		local action = (mapping.rhs or ""):match("^<Cmd>Git (.-)<CR>$")
		if actions[action] then
			shortcuts[#shortcuts + 1] = "  " .. mapping.lhs:gsub(" ", "<Space>") .. "  →  " .. action
		end
	end
	table.sort(shortcuts)
	vim.list_extend(lines, #shortcuts > 0 and shortcuts or { "  No shortcuts configured" })
	vim.list_extend(lines, {
		"",
		"Right-click menu · source lines",
		"  Copy Permalink  Copy the clicked line's commit-pinned URL",
		"  Git: open pr    Show the clicked line's PR links",
		"  Git: blame      Show the clicked line's author, date and commit",
		"",
		"Shortcuts inside Git windows",
		"  p               Show PR links in line/full-file blame",
		"  Enter           Return to the selected source line in full-file blame",
		"  y               Yank the current line's URL to the unnamed register",
		"  Modifier-click  Open a link locally (usually Cmd-click on macOS)",
		"  q / Esc         Close the focused popup",
		"  j / k, Ctrl-f / Ctrl-b, /   Scroll, page and search",
		"",
		"Blame uses unsaved file contents or the focused Review snapshot.",
		"PR lookups require gh auth login on the machine running Neovim.",
	})
	require("rediff.git_popup").open("Git · help · Ctrl-f/Ctrl-b page · q/Esc close", "/ search").show(lines)
end

actions.help = { run = help, description = "Git commands and shortcuts" }

local function execute(args)
	local name = args[1] or "help"
	local action = assert(actions[name], "Unknown Git action. Use :git help or Tab to complete")
	if action.arguments then
		return action.run(args)
	end
	assert(#args <= 1, "Usage: git " .. name)
	action.run()
end

function M.palette()
	local s = review.active()
	local header = s and s.comparison and ("Comparing " .. git.comparison_label(s.comparison)) or "Commands"
	require("fzf-lua").commands({
		header = header,
		flatten = {
			Git = function()
				local rows = {}
				for _, name in ipairs(vim.fn.sort(vim.tbl_keys(actions))) do
					local action = actions[name]
					local key = action.key and (" [Space " .. action.key .. "]") or ""
					table.insert(rows, name .. "  · " .. action.description .. key)
				end
				return rows
			end,
		},
		actions = {
			["enter"] = function(selected, opts)
				local action = selected[1] and selected[1]:match("^Git (%S+)")
				if action and actions[action] then
					guarded(function()
						execute({ action })
					end)
				else
					require("fzf-lua.actions").ex_run(selected, opts)
				end
			end,
		},
	})
end

function M.setup()
	_G.RediffGitRefs = function(lead)
		local ok, refs = pcall(function()
			return git.refs(root(), lead)
		end)
		return ok and refs or {}
	end
	api.nvim_create_user_command("Git", function(opts)
		guarded(function()
			execute(opts.fargs)
		end)
	end, {
		nargs = "*",
		desc = "Git comparisons, blame, and GitHub links",
		complete = function(lead, line, position)
			if line:sub(1, position):match("^%s*Git%s+%S*$") then
				return vim.tbl_filter(function(action)
					return vim.startswith(action, lead)
				end, vim.fn.sort(vim.tbl_keys(actions)))
			end
			local action = line:match("^%s*Git%s+(%S+)%s")
			if action == "diff" or action == "base" or action == "stack" or action == "branch-stack" then
				local refs = _G.RediffGitRefs(lead)
				if action == "base" and vim.startswith("reset", lead) and not vim.tbl_contains(refs, "reset") then
					table.insert(refs, 1, "reset")
				end
				return refs
			end
			return {}
		end,
	})
	vim.cmd([[cnoreabbrev <expr> git getcmdtype() == ':' && getcmdline() == 'git' && getcmdpos() == 4 ? 'Git' : 'git']])
	vim.cmd(
		[[cnoreabbrev <expr> gd getcmdtype() == ':' && getcmdline() == 'gd' && getcmdpos() == 3 ? 'Git diff' : 'gd']]
	)
	for name, action in pairs(actions) do
		if action.key then
			vim.keymap.set("n", "<leader>" .. action.key, "<Cmd>Git " .. name .. "<CR>", { desc = action.description })
		end
	end
end

return M
