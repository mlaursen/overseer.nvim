local files = require("overseer.files")
local overseer = require("overseer")
local util = require("overseer.util")

---@type table<string, string[]>
local mgr_lockfiles = {
  npm = { "package-lock.json" },
  pnpm = { "pnpm-lock.yaml" },
  yarn = { "yarn.lock" },
  bun = { "bun.lockb", "bun.lock" },
}

---@type overseer.TemplateFileDefinition
local tmpl = {
  priority = 60,
  params = {
    args = { optional = true, type = "list", delimiter = " " },
    cwd = { optional = true },
    bin = { optional = true, type = "string" },
  },
  builder = function(params)
    return {
      cmd = { params.bin },
      args = params.args,
      cwd = params.cwd,
    }
  end,
}

---@param opts overseer.SearchParams
local function get_candidate_package_files(opts)
  -- Some projects have package.json files in subfolders, which are not the main project package.json file,
  -- but rather some submodule marker. This seems prevalent in react-native projects. See this for instance:
  -- https://stackoverflow.com/questions/51701191/react-native-has-something-to-use-local-folders-as-package-name-what-is-it-ca
  -- To cover that case, we search for package.json files starting from the current file folder, up to the
  -- working directory
  local matches = vim.fs.find("package.json", {
    upward = true,
    type = "file",
    path = opts.dir,
    stop = vim.fn.getcwd() .. "/..",
    limit = math.huge,
  })
  if #matches > 0 then
    return matches
  end
  -- we couldn't find any match up to the working directory.
  -- let's now search for any possible single match without
  -- limiting ourselves to the working directory.
  return vim.fs.find("package.json", {
    upward = true,
    type = "file",
    path = vim.fn.getcwd(),
  })
end

---@param candidate_packages string[]
---@return string|nil, number|nil
local function get_package_file_from_candidates(candidate_packages)
  -- go through candidate package files from closest to the file to least close
  for i, package in ipairs(candidate_packages) do
    local data = files.load_json_file(package)
    if data.scripts or data.workspaces then
      return package, i
    end
  end
  return nil, nil
end

---@param opts overseer.SearchParams
---@return string|nil
local function get_package_file(opts)
  local candidate_packages = get_candidate_package_files(opts)
  return get_package_file_from_candidates(candidate_packages)
end

---@param package_file string
---@return string|nil
local function pick_package_manager(package_file)
  local package_dir = vim.fs.dirname(package_file)
  for mgr, lockfiles in pairs(mgr_lockfiles) do
    if
      util.list_any(lockfiles, function(lockfile)
        return files.exists(files.join(package_dir, lockfile))
      end)
    then
      return mgr
    end
  end
  return nil
end

---@param candidate_packages string[]
---@return string
local function pick_package_manager_from_candidates(candidate_packages)
  for _, package in ipairs(candidate_packages) do
    local package_manager = pick_package_manager(package)
    if package_manager then
      return package_manager
    end
  end

  return "npm"
end

---@param opts overseer.SearchParams
---@return string|nil, string
local function get_package_and_manager(opts)
  local candidate_packages = get_candidate_package_files(opts)
  local package_file, i = get_package_file_from_candidates(candidate_packages)
  local package_manager = "npm"
  if package_file and i then
    -- move the package_file to the start of the list so it will be checked
    -- first and fallback to a candidate if it couldn't be found
    table.remove(candidate_packages, i)
    table.insert(candidate_packages, 1, package_file)
    package_manager = pick_package_manager_from_candidates(candidate_packages)
  end

  return package_file, package_manager
end

return {
  cache_key = function(opts)
    return get_package_file(opts)
  end,
  condition = {
    callback = function(opts)
      local package_file, package_manager = get_package_and_manager(opts)
      if not package_file then
        return false, "No package.json file found"
      end
      if vim.fn.executable(package_manager) == 0 then
        return false, string.format("Could not find command '%s'", package_manager)
      end
      return true
    end,
  },
  generator = function(opts, cb)
    local package, bin = get_package_and_manager(opts)
    if not package then
      cb({})
      return
    end
    local data = files.load_json_file(package)
    local ret = {}
    if data.scripts then
      for k in pairs(data.scripts) do
        table.insert(
          ret,
          overseer.wrap_template(
            tmpl,
            { name = string.format("%s %s", bin, k) },
            { args = { "run", k }, bin = bin, cwd = vim.fs.dirname(package) }
          )
        )
      end
    end

    -- Load tasks from workspaces
    if data.workspaces then
      for _, workspace in ipairs(data.workspaces) do
        local workspace_path = files.join(vim.fs.dirname(package), workspace)
        local workspace_package_file = files.join(workspace_path, "package.json")
        local workspace_data = files.load_json_file(workspace_package_file)
        if workspace_data and workspace_data.scripts then
          for k in pairs(workspace_data.scripts) do
            table.insert(
              ret,
              overseer.wrap_template(
                tmpl,
                { name = string.format("%s[%s] %s", bin, workspace, k) },
                { args = { "run", k }, bin = bin, cwd = workspace_path }
              )
            )
          end
        end
      end
    end
    table.insert(ret, overseer.wrap_template(tmpl, { name = bin }, { bin = bin }))
    cb(ret)
  end,
}