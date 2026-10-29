local M = {}
local git = require("rediff.git")
local review = require("rediff.review")
local stack = require("rediff.comparison_stack")
local pending

function M.discover(root)
	if pending and pending.alive() then
		pending.close()
	end
	local initial_review = review.state
	local initial_directory = vim.fn.getcwd()
	local popup = require("rediff.git_popup").open("GitHub PR stacks", "q/Esc cancel")
	pending = popup

	local function current()
		return review.state == initial_review and vim.fn.getcwd() == initial_directory
	end

	local function fail(message)
		if popup.alive() then
			popup.show(nil, tostring(message))
		else
			vim.notify(tostring(message), vim.log.levels.ERROR)
		end
	end

	local function run(argv, done)
		vim.system(
			argv,
			{ cwd = root, text = true, timeout = 60000 },
			vim.schedule_wrap(function(result)
				if not popup.alive() then
					return
				end
				if not current() then
					popup.show({ "Review changed. Run :git pr-stack again." })
					return
				end
				if result.code ~= 0 then
					local message = vim.trim(result.stderr or "")
					fail(message ~= "" and message or "Command failed or timed out")
					return
				end
				local ok, err = pcall(done, result.stdout)
				if not ok then
					fail(err)
				end
			end)
		)
	end

	local function load(repository, remote_stack)
		popup = require("rediff.git_popup").open("GitHub stack #" .. remote_stack.number, "q/Esc cancel")
		pending = popup
		local comparisons = {}

		local function next_pr(index)
			local member = remote_stack.pull_requests[index]
			if not member then
				popup.close()
				stack.set(root, comparisons)
				return
			end
			popup.show({ "Loading PR #" .. member.number .. "…" })
			local endpoint = "repos/" .. repository.nameWithOwner .. "/pulls/" .. member.number
			run({ "gh", "api", endpoint }, function(output)
				local pr = vim.json.decode(output)
				local function add_comparison()
					local comparison = git.comparison(root, pr.base.sha, pr.head.sha)
					comparison.base_ref, comparison.head_ref = pr.base.ref, pr.head.ref
					local state = pr.state
					if pr.merged_at and pr.merged_at ~= vim.NIL then
						state = "merged"
					elseif pr.draft and pr.state == "open" then
						state = "draft"
					end
					comparison.pr = {
						number = pr.number,
						title = pr.title,
						url = pr.html_url,
						state = state,
						stack = remote_stack.number,
						repository = repository.nameWithOwner,
					}
					table.insert(comparisons, comparison)
					next_pr(index + 1)
				end

				local missing = {}
				for _, sha in ipairs({ pr.base.sha, pr.head.sha }) do
					assert(sha:match("^%x+$"), "GitHub returned an invalid commit ID")
					local _, code = git.run(root, { "cat-file", "-e", sha .. "^{commit}" }, nil, true)
					if code ~= 0 then
						table.insert(missing, sha)
					end
				end
				if #missing == 0 then
					add_comparison()
					return
				end
				popup.show({ "Fetching commits for PR #" .. pr.number .. "…" })
				local fetch = {
					"git",
					"-c",
					"credential.helper=",
					"-c",
					"credential.helper=!gh auth git-credential",
					"fetch",
					"--no-tags",
					"--no-write-fetch-head",
					"--no-recurse-submodules",
					"--",
					repository.url,
				}
				vim.list_extend(fetch, missing)
				run(fetch, add_comparison)
			end)
		end
		next_pr(1)
	end

	popup.show({ "Looking up GitHub PR stacks…" })
	run({ "gh", "repo", "view", "--json", "nameWithOwner,url" }, function(output)
		local repository = vim.json.decode(output)
		local endpoint = "repos/" .. repository.nameWithOwner .. "/stacks?per_page=100"
		run({ "gh", "api", "--paginate", "--slurp", endpoint }, function(response)
			local available, rows = {}, {}
			for _, page in ipairs(vim.json.decode(response)) do
				for _, remote_stack in ipairs(page) do
					if remote_stack.open and #remote_stack.pull_requests > 0 then
						available[remote_stack.number] = remote_stack
						local branches = { remote_stack.base.ref }
						for _, pr in ipairs(remote_stack.pull_requests) do
							table.insert(branches, "#" .. pr.number .. " " .. pr.head.ref)
						end
						table.insert(rows, remote_stack.number .. " · " .. table.concat(branches, " → "))
					end
				end
			end
			if #rows == 0 then
				popup.show({
					"No open GitHub PR stacks in " .. repository.nameWithOwner .. ".",
					"Use :git stack for local refs.",
				})
				return
			end
			popup.close()
			require("fzf-lua").fzf_exec(rows, {
				prompt = "GitHub stacks> ",
				header = repository.nameWithOwner .. " · Enter review · Esc cancel",
				fzf_opts = { ["--no-sort"] = true },
				actions = {
					["default"] = function(selected)
						if not selected[1] then
							return
						end
						if not current() then
							fail("Review changed. Run :git pr-stack again.")
							return
						end
						local number = tonumber(selected[1]:match("^%d+"))
						load(repository, available[number])
					end,
				},
			})
		end)
	end)
end

return M
