return function(equal)
	local priority = require("rediff.review_priority")
	local function expect(path, old, new, rank, reason)
		equal({ rank = rank, reason = reason }, priority.classify(path, old, new), path .. ": " .. reason)
	end

	local lua = "local M = {}\nfunction M.read(id) return id + 1 end\nreturn M\n"
	expect("api.lua", lua, lua:gsub("id %+ 1", "id + 2"), 2, "Body")
	expect("api.lua", lua, lua:gsub("read%(id%)", "read(id, fallback)"), 1, "Signature")
	expect("api.lua", lua, "-- Read a value\n" .. lua, 4, "Docs")
	local assigned = "local read = function(id) return id end\n"
	expect("api.lua", assigned, assigned:gsub("read =", "fetch ="), 1, "Signature")
	expect("api.lua", assigned, assigned:gsub("function%(id%)", "function(id, ...)"), 1, "Signature")
	local record = "return { name = 'Ada', nested = { id = 1 } }\n"
	expect("api.lua", record, record:gsub("Ada", "Grace"), 2, "Body")
	expect("api.lua", record, record:gsub("id =", "key ="), 1, "Type")
	expect("api.lua", "", lua, 1, "Type")

	local nix = "{ lib, count ? 1, ... }: { value = count + 1; }\n"
	expect("module.nix", nix, nix:gsub("count %+ 1", "count + 2"), 2, "Body")
	expect("module.nix", nix, nix:gsub("count %? 1", "count ? 2"), 1, "Signature")
	expect("module.nix", nix, nix:gsub("value =", "result ="), 1, "Type")
	expect("module.nix", nix, "# Module options\n" .. nix, 4, "Docs")
	local inherited = "{ pkgs }: { inherit (pkgs) git; }\n"
	expect("module.nix", inherited, inherited:gsub("git;", "git jq;"), 1, "Type")
	local default = "{ config ? { count = 1; } }: config\n"
	expect("module.nix", default, default:gsub("count = 1", "count = 2"), 1, "Signature")
	local bound = "let read = id: id; in read\n"
	expect("module.nix", bound, bound:gsub("read", "fetch"), 1, "Signature")
	expect("module.nix", "left: right: left - right", "right: left: left - right", 1, "Signature")

	local go = "package api\nfunc Read(id int) string { return lookup(id) }\n"
	expect("api.go", go, go:gsub("lookup%(id%)", '"cached"'), 2, "Body")
	expect("api.go", go, go:gsub("id int", "id int64"), 1, "Signature")
	expect("api.go", go, go:gsub("return lookup%(id%)", "// cached value\n return lookup(id)"), 4, "Docs")
	expect("api.go", go, go:gsub("id int", "id  int"), 4, "Docs")
	expect("api.go", "//go:build linux\n\n" .. go, "//go:build darwin\n\n" .. go, 2, "Body")
	expect("api.go", go, "package api\n", 1, "Signature")
	expect("api.go", "", go, 1, "Signature")
	expect("api.go", go, go:gsub("id int", "id ["), 3, "Unknown")
	local interface = "package api\ntype Reader interface { Read(id int) string }\n"
	expect("api.go", interface, interface:gsub("string", "error"), 1, "Interface")
	local structure = 'package api\ntype User struct { Name string `json:"name"` }\n'
	expect("api.go", structure, structure:gsub('json:"name"', 'json:"display_name"'), 1, "Type")

	local rust = "impl Store { pub fn read(&self, id: u32) -> bool { id > 0 } }\n"
	expect("store.rs", rust, rust:gsub("id > 0", "id > 3"), 2, "Body")
	expect("store.rs", rust, rust:gsub("u32", "u64"), 1, "Signature")
	expect("store.rs", rust, rust:gsub("pub fn", "fn"), 1, "Signature")
	expect("store.rs", rust, rust:gsub("impl Store", "impl Cache"), 1, "Type")
	local trait = "trait Reader { fn read(&self) -> bool { true } }\n"
	expect("store.rs", trait, trait:gsub("true", "false"), 2, "Body")
	expect("store.rs", trait, trait:gsub("bool", "u8"), 1, "Interface")
	local enum = "enum Status { Ready, Waiting(u32) }\n"
	expect("store.rs", enum, enum:gsub("u32", "u64"), 1, "Type")
	local generic = "fn read<T: Copy>(value: T) -> T { value }\n"
	expect("store.rs", generic, generic:gsub("Copy", "Clone"), 1, "Signature")
	local attributed = '#[route("/read")]\nfn read() -> bool { true }\n'
	expect("store.rs", attributed, attributed:gsub("/read", "/fetch"), 1, "Signature")

	local python = [[class User:
    name: str
    def read(self, count: int = 1) -> str:
        """Read a name."""
        return self.name
]]
	expect("user.py", python, python:gsub("return self.name", 'return "anonymous"'), 2, "Body")
	expect("user.py", python, python:gsub("count: int = 1", "count: int = 2"), 1, "Signature")
	expect("user.py", python, python:gsub("name: str", "name: bytes"), 1, "Type")
	expect("user.py", python, python:gsub("Read a name.", "Fetch the user's name."), 4, "Docs")
	local decorated = '@app.get("/users")\ndef users() -> list:\n    return []\n'
	expect("user.py", decorated, decorated:gsub("/users", "/people"), 1, "Signature")
	local alias = "type Names = list[str]\n"
	expect("user.py", alias, alias:gsub("str", "bytes"), 1, "Type")
	local stub = "def user(id: int) -> str: ...\n"
	expect("user.pyi", stub, stub:gsub("str", "bytes"), 1, "Signature")
	local text = 'def name():\n    return "Ada Lovelace"\n'
	expect("user.py", text, text:gsub("Ada Lovelace", "AdaLovelace"), 2, "Body")
	expect("user.py", "", "# User functions\n", 4, "Docs")
	local large = "# " .. string.rep("documentation ", 40000) .. "\n" .. text
	expect("large_test.py", large, large:gsub("name%(%)", "name(id)"), 1, "Signature")
	expect("large_test.py", large, large:gsub("Ada Lovelace", "Grace Hopper"), 2, "Body")

	local proto = [[syntax = "proto3";
message Request { string name = 1; }
service Users { rpc Read(Request) returns (Request); }
]]
	expect("users.proto", proto, proto:gsub("rpc Read%(Request%)", "rpc Read(stream Request)"), 1, "RPC")
	expect("users.proto", proto, proto:gsub("name = 1", "name = 2"), 1, "Type")
	expect("users.proto", proto, "// User protocol\n" .. proto, 4, "Docs")
	expect("users.proto", proto, proto:gsub("service Users {.-}\n", ""), 1, "RPC")
	expect("README.md", "# Old\n", "# New\n", 4, "Docs")
	expect("README", "Old\n", "New\n", 4, "Docs")
	expect("config/doc/rediff.txt", "Old help\n", "New help\n", 4, "Docs")
	expect("settings.txt", "old", "new", 3, "Unknown")
	expect("settings.json", "{}", '{"enabled": true}', 3, "Unknown")
	expect("README.md", "", "\0binary", 3, "Unknown")
	expect("api.go", go, go .. string.rep(" ", 2 * 1024 * 1024 - #go), 4, "Docs")
	expect("api.go", go, go .. string.rep(" ", 2 * 1024 * 1024 - #go + 1), 3, "Unknown")
end
