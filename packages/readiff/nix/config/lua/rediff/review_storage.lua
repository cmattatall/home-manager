local M = {}
local api = vim.api
local feedback = require("rediff.feedback")

local function contents(notes)
	local result = { comments = vim.deepcopy(notes.comments), drafts = {}, snapshots = {} }
	for _, draft in ipairs(notes.drafts) do
		local unchanged = false
		for _, comment in ipairs(notes.comments) do
			if comment.id == draft.comment_id and comment.text == draft.text then
				unchanged = true
				break
			end
		end
		if not unchanged and (draft.comment_id or vim.trim(draft.text or "") ~= "") then
			table.insert(result.drafts, vim.deepcopy(draft))
		end
	end
	for _, comment in ipairs(result.comments) do
		result.snapshots[comment.snapshot_id] = notes.snapshots[comment.snapshot_id]
	end
	for _, draft in ipairs(result.drafts) do
		local id = draft.anchor.snapshot_id
		result.snapshots[id] = notes.snapshots[id]
	end
	return result
end

function M.changed(notes)
	local storage = notes.storage
	vim.bo[storage.buf].modified = not vim.deep_equal(contents(notes), storage.saved)
end

function M.save(notes)
	local saved = contents(notes)
	feedback.write(notes.storage.path, saved)
	notes.storage.saved = vim.deepcopy(saved)
	vim.bo[notes.storage.buf].modified = false
end

function M.load(notes)
	local path = notes.directory .. "/notes.json"
	local saved = feedback.read(path) or { comments = {}, drafts = {}, snapshots = {} }
	notes.comments, notes.drafts, notes.snapshots = saved.comments, saved.drafts, saved.snapshots
	local buf = api.nvim_create_buf(true, false)
	api.nvim_buf_set_name(buf, "review-notes://" .. notes.root)
	vim.bo[buf].buftype = "acwrite"
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].swapfile = false
	vim.bo[buf].undofile = false
	vim.bo[buf].modifiable = false
	notes.storage = { buf = buf, path = path, saved = vim.deepcopy(saved) }
	-- A hidden modified buffer gives every visited review Vim's native exit checks.
	api.nvim_create_autocmd("BufWriteCmd", {
		buffer = buf,
		callback = function(event)
			assert(event.match == api.nvim_buf_get_name(buf), "Use :ReviewSave to save review notes")
			M.save(notes)
		end,
	})
end

function M.clear_sent(notes, sent)
	local saved = vim.deepcopy(notes.storage.saved)
	for index = #saved.comments, 1, -1 do
		local comment = saved.comments[index]
		if vim.deep_equal(comment, sent[comment.id]) then
			table.remove(saved.comments, index)
			for _, draft in ipairs(saved.drafts) do
				if draft.comment_id == comment.id then
					draft.comment_id = nil
				end
			end
		end
	end
	local remaining = contents(saved)
	feedback.write(notes.storage.path, remaining)
	notes.storage.saved = vim.deepcopy(remaining)
end

return M
