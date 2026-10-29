local M = {}
local api = vim.api
local history = require("rediff.history")
local git = require("rediff.git")
local review = require("rediff.review")

local function compare(args)
	local action = args[1]
	assert(
		(action == "diff" and #args == 3) or (action == "base" and #args == 2),
		"Usage: git diff BASE TARGET | git base BASE (commit SHAs, branches, or tags)"
	)
	local state = review.state
	local root = state and state.root or git.root()
	local head = args[3]
	if action == "base" then
		head = state and state.comparison and state.comparison.head or "HEAD"
	end
	review.open(root, git.comparison(root, args[2], head))
end

local actions = {
	base = compare,
	diff = compare,
	blame = history.blame,
	["blame-line"] = function()
		history.blame_line(false)
	end,
	["blame-toggle"] = history.toggle_inline,
	toggle = history.toggle_inline,
	["copy-link"] = history.copy_link,
	pr = function()
		history.blame_line(true)
	end,
}

function actions.help()
	local lines = {
		"Commands · :git · Tab completes actions · scripts use :Git",
		"  diff BASE TARGET       Compare two commits, branches, or tags",
		"  base BASE              Change the comparison base, retaining its target",
		"  blame-line             Show this line's author, date and commit",
		"  blame                  Browse blame for every source line",
		"  toggle / blame-toggle  Toggle inline blame (on by default)",
		"  pr                     Show this line's associated GitHub PR links",
		"  copy-link              Copy a permalink to this line",
		"  help / (no action)     Show this reference",
		"  :gd BASE TARGET        Typed shortcut for :git diff BASE TARGET",
		"",
		"Configured shortcuts · Normal mode",
	}
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

local function execute(args)
	local name = args[1] or "help"
	local action = assert(actions[name], "Unknown Git action. Use :git help or Tab to complete")
	if name == "diff" or name == "base" then
		return action(args)
	end
	assert(#args <= 1, "Usage: git " .. name)
	action()
end

function M.setup()
	api.nvim_create_user_command("Git", function(opts)
		local ok, err = pcall(execute, opts.fargs)
		if not ok then
			vim.notify(tostring(err), vim.log.levels.ERROR)
		end
	end, {
		nargs = "*",
		desc = "Git comparisons, blame, and GitHub links",
		complete = function(lead, line, position)
			if line:sub(1, position):match("^%s*Git%s+%S*$") then
				return vim.tbl_filter(function(action)
					return vim.startswith(action, lead)
				end, vim.fn.sort(vim.tbl_keys(actions)))
			end
			return {}
		end,
	})
	vim.cmd([[cnoreabbrev <expr> git getcmdtype() == ':' && getcmdline() == 'git' && getcmdpos() == 4 ? 'Git' : 'git']])
	vim.cmd([[cnoreabbrev <expr> gd getcmdtype() == ':' && getcmdline() == 'gd' && getcmdpos() == 3 ? 'Git diff' : 'gd']])
	for key, action in pairs({ gb = "blame-line", gB = "blame", gi = "toggle", gp = "pr" }) do
		vim.keymap.set("n", "<leader>" .. key, "<Cmd>Git " .. action .. "<CR>", { desc = "Git " .. action })
	end
end

return M
