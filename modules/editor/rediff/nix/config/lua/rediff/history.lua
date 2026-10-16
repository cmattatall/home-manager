local M = {}

function M.setup()
	require("gitgud").setup({
		context = function()
			local s = require("rediff.review").active()
			if not s then
				return
			end
			local buf = vim.api.nvim_get_current_buf()
			if buf ~= s.old_buf and buf ~= s.new_buf then
				return
			end
			local snapshot = assert(s.current, "Select a file in Review first")
			local side = buf == s.old_buf and "old" or "new"
			return { root = s.root, path = snapshot.path, head = snapshot.head, text = snapshot[side], side = side }
		end,
	})
	for key, action in pairs({ gb = "blame-line", gB = "blame", gi = "blame-toggle", gp = "pr" }) do
		vim.keymap.set("n", "<leader>" .. key, "<Cmd>GitGud " .. action .. "<CR>", { desc = "GitGud " .. action })
	end
end

return M
