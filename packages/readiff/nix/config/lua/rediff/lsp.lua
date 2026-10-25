local M = {}
local fetching = {}
local spinner = { "|", "/", "-", "\\" }
local frame = 1
local animating = false

local function tick()
	-- A server may exit without sending the final progress notification.
	for id in pairs(fetching) do
		local client = vim.lsp.get_client_by_id(id)
		if not client or client:is_stopped() then
			fetching[id] = nil
		end
	end
	animating = next(fetching) ~= nil
	vim.cmd.redrawstatus()
	if animating then
		frame = frame % #spinner + 1
		vim.defer_fn(tick, 120)
	end
end

function M.statusline()
	return next(fetching) and (" · " .. spinner[frame] .. " Fetching flake inputs ") or ""
end

function M.setup()
	vim.api.nvim_create_autocmd("LspProgress", {
		callback = function(event)
			local data = event.data
			if data.params.token ~= "nil/flakeArchiveProgress" then
				return
			end
			if data.params.value.kind == "begin" then
				fetching[data.client_id] = true
			elseif data.params.value.kind == "end" then
				fetching[data.client_id] = nil
			end
			if not animating and next(fetching) then
				tick()
			else
				vim.cmd.redrawstatus()
			end
		end,
	})
	vim.lsp.config("nil_ls", { settings = { ["nil"] = { nix = { flake = { autoArchive = true } } } } })
	vim.lsp.config("lua_ls", { settings = { Lua = { workspace = { checkThirdParty = false } } } })
	vim.lsp.config("gopls", { settings = { gopls = { semanticTokens = true } } })
	vim.lsp.enable({ "lua_ls", "nil_ls", "pyright", "ts_ls", "gopls", "rust_analyzer" })
end

return M
