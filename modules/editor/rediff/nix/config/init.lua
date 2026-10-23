vim.opt.runtimepath:prepend(assert(vim.env.REDIFF_RUNTIME, "Use the rediff launcher"))
for path in (vim.env.REDIFF_PLUGINS or ""):gmatch("[^,]+") do
	vim.opt.runtimepath:append(path)
end

vim.g.mapleader = " "
vim.g.maplocalleader = " "
-- Use review.nvim's renderers without its file-buffer lifecycle or commands.
vim.g.loaded_review = true
vim.opt.number = true
vim.opt.termguicolors = true
vim.opt.signcolumn = "yes"
vim.opt.splitright = true
vim.opt.splitbelow = true
vim.opt.ignorecase = true
vim.opt.smartcase = true
vim.opt.updatetime = 250
vim.opt.completeopt = { "menuone", "noselect" }
vim.opt.expandtab = true
vim.opt.shiftwidth = 4
vim.opt.tabstop = 4
vim.opt.autowrite = false
vim.opt.autowriteall = false
-- Filetype plugins (including Pkl) define folds; don't hide source by default.
vim.opt.foldenable = false
require("rose-pine").setup({
	variant = "main",
	dark_variant = "main",
	-- Dark teal keywords/paths and muted comments disappear on diff backgrounds.
	palette = { main = { pine = "#8fc3ce" } },
	highlight_groups = {
		Comment = { fg = "#b9b6cd" },
		GitSignsAdd = { fg = "#a6e3a1" },
		GitSignsChange = { fg = "#f9e2af" },
		GitSignsDelete = { fg = "#f38ba8" },
	},
})
vim.cmd.colorscheme("rose-pine")
vim.fn.mkdir(vim.fn.stdpath("data"), "p")

vim.api.nvim_create_autocmd("FileType", {
	callback = function(event)
		-- Review reuses its snapshot buffers when switching between languages.
		vim.treesitter.stop(event.buf)
		if vim.tbl_contains({ "go", "rust", "python" }, event.match) then
			vim.treesitter.start(event.buf, event.match)
		end
	end,
})

require("gitsigns").setup({
	attach_to_untracked = true,
	signs_staged_enable = false,
	current_line_blame = false,
	on_attach = function(buf)
		if vim.bo[buf].buftype ~= "" or vim.startswith(vim.api.nvim_buf_get_name(buf), "review://") then
			return false
		end
	end,
})

vim.keymap.set("n", "<D-w>", "<C-w>", { desc = "Window command prefix (Cmd-w)" })
vim.keymap.set({ "i", "x" }, "<D-w>", "<Esc><C-w>", { desc = "Leave editing/selection for window command" })
vim.keymap.set({ "n", "x" }, "<C-w>", "<Nop>", { desc = "Use Cmd-w for window commands" })
vim.keymap.set("x", "<D-c>", '"+y', { desc = "Copy selection to system clipboard" })
vim.keymap.set("i", "<C-a>", "<Home>", { desc = "Start of line" })
vim.keymap.set("i", "<C-e>", "<End>", { desc = "End of line" })
vim.keymap.set("c", "<C-a>", "<C-b>", { desc = "Start of command line" })
for _, key in ipairs({ "<M-Left>", "<M-Up>", "<M-h>", "<M-k>", "<M-b>" }) do
	vim.keymap.set({ "n", "x", "i", "c" }, key, "<C-Left>", { desc = "Previous word" })
end
for _, key in ipairs({ "<M-Right>", "<M-Down>", "<M-l>", "<M-j>", "<M-f>" }) do
	vim.keymap.set({ "n", "x", "i", "c" }, key, "<C-Right>", { desc = "Next word" })
end

local palette = require("rose-pine.palette")
vim.api.nvim_set_hl(0, "RediffHelpBorder", { fg = palette.iris, bg = palette.surface })
vim.api.nvim_create_autocmd({ "FileType", "BufWinEnter" }, {
	callback = function(event)
		if vim.bo[event.buf].filetype ~= "help" or vim.api.nvim_get_current_buf() ~= event.buf then
			return
		end
		local width = math.max(1, math.min(90, vim.o.columns - 4))
		local height = math.max(1, math.min(32, vim.o.lines - 6))
		vim.api.nvim_win_set_config(0, {
			relative = "editor",
			row = math.max(0, math.floor((vim.o.lines - height - 2) / 2)),
			col = math.max(0, math.floor((vim.o.columns - width - 2) / 2)),
			width = width,
			height = height,
			style = "minimal",
			border = "single",
			title = " Help · Space/b page · / search · q close ",
			title_pos = "center",
		})
		vim.wo.winhighlight = "FloatBorder:RediffHelpBorder"
		vim.wo.wrap = true
		vim.wo.linebreak = true
		-- Help is a pager, not a leader-key workspace. Consume Space immediately.
		for key, command in pairs({
			["<Space>"] = "<C-f>",
			f = "<C-f>",
			b = "<C-b>",
			d = "<C-d>",
			u = "<C-u>",
			g = "gg",
		}) do
			vim.keymap.set("n", key, command, { buffer = event.buf, nowait = true, desc = "Page through help" })
		end
		for _, key in ipairs({ "?", "q", "<Esc>" }) do
			vim.keymap.set("n", key, "<Cmd>close<CR>", { buffer = event.buf, desc = "Close help overlay" })
		end
	end,
})
vim.keymap.set("n", "?", "<Cmd>help rediff<CR>", { desc = "Editor help overlay" })

require("codediff").setup({
	-- Blank filler rows preserve alignment without rendering wide patterns per line.
	diff = { compute_moves = false, highlight_priority = 150, filler_text = "" },
	highlights = {
		line_insert = "#23412b",
		line_delete = "#50272c",
		char_insert = "#2e5037",
		char_delete = "#70343c",
	},
})
require("review.config").setup({ export = { clipboard = false, clear_on_close = false } })
require("review.highlights").setup()
require("neo-tree").setup({
	default_component_configs = {
		name = { use_git_status_colors = false },
		icon = { use_git_status_colors = false },
		git_status = {
			symbols = {
				added = "A",
				modified = "M",
				untracked = "U",
				deleted = "",
				renamed = "",
				ignored = "",
				unstaged = "",
				staged = "",
				conflict = "",
			},
		},
	},
	filesystem = {
		hijack_netrw_behavior = "open_current",
		use_libuv_file_watcher = true,
		renderers = {
			directory = {
				{ "indent" },
				{ "icon" },
				{ "current_filter" },
				{ "name" },
				{ "git_status", hide_when_expanded = false },
			},
		},
	},
	window = {
		width = 28,
		mappings = {
			["?"] = function()
				vim.cmd("help rediff")
			end,
			["<D-c>"] = function()
				require("rediff.navigation").copy_path(false)
			end,
			["<C-S-c>"] = function()
				require("rediff.navigation").copy_path(true)
			end,
		},
	},
})
-- Git ref/index changes need not produce a watched worktree file event.
-- Reconcile cached markers when returning from Review, another terminal, or
-- an editor pane; Neo-tree refreshes in place and marks hidden trees dirty.
vim.api.nvim_create_autocmd({ "FocusGained", "TabEnter", "BufEnter" }, {
	callback = function(event)
		if event.event == "BufEnter" and vim.bo[event.buf].filetype ~= "neo-tree" then
			return
		end
		-- Let tab/window transitions finish before refreshing a visible explorer.
		vim.schedule(function()
			for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
				if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "neo-tree" then
					local events = require("neo-tree.events")
					events.fire_event(events.GIT_EVENT)
					break
				end
			end
		end)
	end,
})
local function explorer_highlights()
	vim.api.nvim_set_hl(0, "NeoTreeGitAdded", { fg = "#4ade80", bold = true })
	vim.api.nvim_set_hl(0, "NeoTreeGitUntracked", { fg = "#4ade80", bold = true })
	vim.api.nvim_set_hl(0, "NeoTreeGitModified", { fg = "#facc15", bold = true })
end
explorer_highlights()
vim.api.nvim_create_autocmd("ColorScheme", { callback = explorer_highlights })
vim.api.nvim_create_autocmd("VimEnter", {
	once = true,
	callback = vim.schedule_wrap(function()
		if
			#vim.api.nvim_list_uis() == 0
			or vim.fn.argc() > 0
			or require("rediff.review").state
			or not pcall(require("rediff.git").root)
		then
			return
		end
		require("neo-tree.command").execute({
			action = "focus",
			source = "filesystem",
			position = "left",
			dir = vim.fn.getcwd(),
		})
		local ok, err = pcall(require("rediff.review").open)
		if ok then
			local review = require("rediff.review").active()
			local harness = require("rediff.harness")
			local session = harness.get(review.root)
			local win = vim.api.nvim_get_current_win()
			local function open_harness()
				-- Do not steal focus if the user has already left the startup view.
				if require("rediff.review").active() ~= review or vim.api.nvim_get_current_win() ~= win then
					return
				end
				if session.restoring then
					vim.defer_fn(open_harness, 50)
					return
				end
				if session.provider ~= "amp" and session.provider ~= "omp" and session.provider ~= "claude" then
					return
				end
				local opened, failure = pcall(harness.open, review.root, true)
				if not opened then
					vim.notify("Could not open harness: " .. tostring(failure), vim.log.levels.WARN)
				end
			end
			open_harness()
			return
		end
		vim.notify("Could not open Review: " .. tostring(err), vim.log.levels.WARN)
		require("neo-tree.command").execute({ action = "show", source = "filesystem", position = "left" })
	end),
})

local review = require("rediff.review")
require("rediff.lsp").setup()
review.setup()
require("rediff.annotations").setup()
require("rediff.harness").setup()
require("rediff.worktree").setup()
require("rediff.cmdline").setup()
require("rediff.history").setup()
require("fzf-lua").setup({
	winopts = { width = 0.85, height = 0.8, preview = { hidden = true } },
	keymap = { fzf = { ["esc"] = "abort" } },
	files = { file_icons = false, git_icons = false },
	grep = { file_icons = false, git_icons = false },
})
require("telescope").setup({
	defaults = { mappings = { i = { ["<Esc>"] = require("telescope.actions").close } } },
})
local navigation = require("rediff.navigation")
vim.api.nvim_create_autocmd("MenuPopup", { callback = navigation.tree_menu })
for _, binding in ipairs({
	{ "<leader>e", "Explorer", navigation.explorer, "Focus explorer" },
	{ "<leader>d", "FocusDiff", navigation.diff, "Focus diff/editor" },
	{ "<leader>f", "Files", navigation.files, "Fuzzy find files" },
	{ "<leader>/", "Search", navigation.text, "Fuzzy find text" },
	{ "<leader>s", "Symbols", require("telescope.builtin").lsp_document_symbols, "Find file symbols" },
	{
		"<leader>S",
		"WorkspaceSymbols",
		require("telescope.builtin").lsp_dynamic_workspace_symbols,
		"Find workspace symbols",
	},
	{
		"<leader>p",
		"Commands",
		function()
			if vim.bo.filetype == "help" and vim.api.nvim_win_get_config(0).relative ~= "" then
				vim.cmd.close()
			end
			require("fzf-lua").commands()
		end,
		"Find commands",
	},
}) do
	vim.keymap.set("n", binding[1], binding[3], { desc = binding[4] })
	vim.api.nvim_create_user_command(binding[2], binding[3], {})
end
vim.cmd("cnoreabbrev <expr> ft getcmdtype() == ':' && getcmdline() == 'ft' && getcmdpos() == 3 ? 'Explorer' : 'ft'")
vim.keymap.set("n", "<leader>r", function()
	if review.active() then
		review.leave()
	else
		review.open()
	end
end, { desc = "Toggle Review workspace" })
vim.keymap.set("n", "<leader>E", function()
	if review.active() then
		navigation.explorer()
	else
		vim.cmd("Neotree toggle filesystem")
	end
end, { desc = "Toggle file tree (focus in Review)" })
vim.opt.laststatus = 3
vim.opt.statusline = "%{%v:lua.require('rediff.review').statusline()%}%{%v:lua.require('rediff.lsp').statusline()%}"
function _G.RediffCloseBuffer(_, _, button)
	if button == "l" then
		vim.api.nvim_win_call(vim.fn.getmousepos().winid, function()
			vim.cmd("confirm bdelete")
		end)
	end
end
local file_winbar = " %<%f%( %m%)%@v:lua.RediffCloseBuffer@ × %X"
vim.api.nvim_create_autocmd("BufWinEnter", {
	callback = function()
		if vim.bo.buftype == "" and vim.api.nvim_win_get_config(0).relative == "" then
			vim.wo.winbar = file_winbar
		elseif vim.wo.winbar == file_winbar then
			vim.wo.winbar = ""
		end
	end,
})
