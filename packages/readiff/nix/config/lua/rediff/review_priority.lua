local M = {}

local languages = { go = "go", rs = "rust", py = "python", pyi = "python", proto = "proto", lua = "lua", nix = "nix" }
local declarations = {
	lua = {
		function_declaration = "Signature",
		function_definition = "Signature",
		table_constructor = "Type",
	},
	nix = {
		function_expression = "Signature",
		attrset_expression = "Type",
		rec_attrset_expression = "Type",
	},
	go = {
		type_spec = "Type",
		type_alias = "Type",
		function_declaration = "Signature",
		method_declaration = "Signature",
	},
	rust = {
		struct_item = "Type",
		enum_item = "Type",
		union_item = "Type",
		type_item = "Type",
		associated_type = "Type",
		trait_item = "Interface",
		impl_item = "Type",
		function_item = "Signature",
		function_signature_item = "Signature",
	},
	python = {
		class_definition = "Type",
		function_definition = "Signature",
		type_alias_statement = "Type",
	},
	proto = {
		service = "RPC",
		message = "Type",
		enum = "Type",
	},
}
local comments = { comment = true, line_comment = true, block_comment = true }
local reasons = { "RPC", "Interface", "Type", "Signature" }

local function is_docstring(node, source, language)
	if language ~= "python" or node:type() ~= "expression_statement" or node:named_child_count() ~= 1 then
		return false
	end
	local value = node:named_child(0)
	if value:type() ~= "string" or not vim.treesitter.get_node_text(value, source):match("^[rRuU]*['\"]") then
		return false
	end
	local parent = node:parent()
	if parent:type() == "block" then
		local owner = parent:parent():type()
		if owner ~= "function_definition" and owner ~= "class_definition" then
			return false
		end
	elseif parent:type() ~= "module" then
		return false
	end
	for child in parent:iter_children() do
		if child:named() and not comments[child:type()] then
			return child == node
		end
	end
	return false
end

local function tokens(node, source, language, contract, output)
	local kind = node:type()
	if comments[kind] then
		local text = vim.treesitter.get_node_text(node, source)
		if language == "go" and (text:match("^//go:") or text:match("^//%s*%+build")) then
			table.insert(output, text)
		end
		return
	end
	if is_docstring(node, source, language) then
		return
	end
	if node:child_count() == 0 then
		local text = vim.treesitter.get_node_text(node, source)
		if text ~= "" then
			table.insert(output, kind .. ":" .. text)
		end
		return
	end
	for child, field in node:iter_children() do
		local omit_body = contract
			and field == "body"
			and declarations[language][kind] == "Signature"
			and not (language == "nix" and child:type() == "function_expression")
		local omit_members = contract and kind == "impl_item" and field == "body"
		local omit_method = contract
			and language == "python"
			and (child:type() == "function_definition" or child:type() == "decorated_definition")
		local omit_value = contract == "shape"
			and (
				(language == "lua" and kind == "field" and field == "value")
				or (language == "nix" and (kind == "binding" or kind == "inherit_from") and field == "expression")
			)
		if not omit_body and not omit_members and not omit_method and not omit_value then
			tokens(child, source, language, contract, output)
		end
	end
end

local function fingerprint(node, source, language, contract)
	if contract and (language == "lua" or language == "nix") and declarations[language][node:type()] == "Type" then
		contract = "shape"
	end
	local output = {}
	tokens(node, source, language, contract, output)
	return table.concat(output, "\0")
end

local function collect(node, source, language, scope, contracts)
	local kind = node:type()
	local binding
	if language == "lua" and kind == "assignment_statement" then
		binding = node:named_child(0)
	elseif language == "lua" and kind == "field" then
		binding = node:field("name")[1]
	elseif language == "nix" and kind == "binding" then
		binding = node:field("attrpath")[1]
	end
	if binding then
		scope = scope .. "/" .. fingerprint(binding, source, language, false)
	end
	local reason = declarations[language][kind]
	if reason then
		local declared_type = node:field("type")[1]
		if language == "go" and declared_type and declared_type:type() == "interface_type" then
			reason = "Interface"
		end
		local signature = fingerprint(node, source, language, true)
		local parent = node:parent()
		if parent and parent:type() == "decorated_definition" then
			for child in parent:iter_children() do
				if child:type() == "decorator" then
					signature = fingerprint(child, source, language, false) .. "\0" .. signature
				end
			end
		end
		if language == "rust" then
			local previous = node:prev_named_sibling()
			while previous and (previous:type() == "attribute_item" or comments[previous:type()]) do
				if previous:type() == "attribute_item" then
					signature = fingerprint(previous, source, language, false) .. "\0" .. signature
				end
				previous = previous:prev_named_sibling()
			end
		end
		table.insert(contracts[reason], scope .. "\0" .. signature)
		local name = node:field("name")[1]
		if name then
			scope = scope .. "/" .. vim.treesitter.get_node_text(name, source)
		elseif kind == "impl_item" then
			scope = scope .. "/" .. signature
		end
	end
	for child in node:iter_children() do
		if child:named() then
			collect(child, source, language, scope, contracts)
		end
	end
end

local function describe(source, language)
	local ok, trees = pcall(function()
		local parser = vim.treesitter.get_string_parser(source, language, { injections = {} })
		return parser:parse()
	end)
	if not ok then
		return nil
	end
	local root = trees[1]:root()
	if root:has_error() then
		return nil
	end
	local contracts = { RPC = {}, Interface = {}, Type = {}, Signature = {} }
	collect(root, source, language, "", contracts)
	for _, signatures in pairs(contracts) do
		table.sort(signatures)
	end
	return { contracts = contracts, code = fingerprint(root, source, language, false) }
end

function M.classify(path, old, new)
	if old:find("\0", 1, true) or new:find("\0", 1, true) then
		return { rank = 3, reason = "Unknown" }
	end
	local extension = path:match("%.([^./]+)$")
	local name = vim.fn.fnamemodify(path, ":t"):lower()
	local help_file = extension == "txt" and ("/" .. path):find("/doc/", 1, true)
	if extension == "md" or extension == "rst" or name:match("^readme%f[%W]") or name == "readme" or help_file then
		return { rank = 4, reason = "Docs" }
	end
	local language = languages[extension]
	-- Match the snapshot size limit so reviewable source files receive analysis.
	if not language or math.max(#old, #new) > 2 * 1024 * 1024 then
		return { rank = 3, reason = "Unknown" }
	end
	local before = describe(old, language)
	local after = describe(new, language)
	if not before or not after then
		return { rank = 3, reason = "Unknown" }
	end
	for _, reason in ipairs(reasons) do
		if not vim.deep_equal(before.contracts[reason], after.contracts[reason]) then
			return { rank = 1, reason = reason }
		end
	end
	if before.code == after.code then
		return { rank = 4, reason = "Docs" }
	end
	return { rank = 2, reason = "Body" }
end

return M
