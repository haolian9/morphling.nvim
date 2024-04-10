--design choices
--* no stdio with external formatting programs
--* run formatting programs by order, crashes should not make the original buffer dirty
--* assume all formatting programs format in-place
--* it should blocks user input during formatting
--* it should not block the nvim processes

local M = {}

local cthulhu = require("cthulhu")
local ctx = require("infra.ctx")
local dictlib = require("infra.dictlib")
local ex = require("infra.ex")
local fn = require("infra.fn")
local fs = require("infra.fs")
local jelly = require("infra.jellyfish")("morphling")
local listlib = require("infra.listlib")
local prefer = require("infra.prefer")
local project = require("infra.project")
local Regulator = require("infra.Regulator")
local subprocess = require("infra.subprocess")

local api = vim.api
local uv = vim.loop

local resolve_stylua_config
do
  local function find(root)
    if root == nil then return end
    for _, basename in ipairs({ "stylua.toml", ".stylua.toml" }) do
      local fpath = fs.joinpath(root, basename)
      if fs.file_exists(fpath) then return fpath end
    end
  end

  local function resolve() return find(project.git_root()) or find(project.working_root()) or find(vim.fn.stdpath("config")) end

  local found
  ---@return string?
  function resolve_stylua_config()
    if found == nil then found = resolve() end
    return found
  end
end

---@alias morphling.Program fun(fpath: string): boolean

-- all formatting programs should modify the file inplace
---@type {[string]: morphling.Program}
local programs = {
  zig = function(fpath)
    local cp = subprocess.run("zig", { args = { "fmt", "--ast-check", fpath } })
    return cp.exit_code == 0
  end,
  stylua = function(fpath)
    local conf = resolve_stylua_config()
    if conf == nil then return false end
    local cp = subprocess.run("stylua", { args = { "--config-path", conf, fpath } })
    return cp.exit_code == 0
  end,
  isort = function(fpath)
    local cp = subprocess.run("isort", { args = { "--quiet", "--profile", "black", fpath } })
    return cp.exit_code == 0
  end,
  black = function(fpath)
    local cp = subprocess.run("black", { args = { "--quiet", "--target-version", "py310", "--line-length", "256", fpath } })
    return cp.exit_code == 0
  end,
  go = function(fpath)
    local cp = subprocess.run("gofmt", { args = { "-w", fpath } })
    return cp.exit_code == 0
  end,
  ["clang-format"] = function(fpath)
    local cp = subprocess.run("clang-format", { args = { "-i", fpath } })
    return cp.exit_code == 0
  end,
  gomodifytags = function(fpath)
    local cp = subprocess.run("gomodifytags", { args = { "-all", "-add-tags", "json", "-w", "-file", fpath } })
    return cp.exit_code == 0
  end,
  ["fish-indent"] = function(fpath)
    local cp = subprocess.run("fish_indent", { args = { "-w", fpath } })
    return cp.exit_code == 0
  end,
}

--{ft: {profile: [(program-name, program-handler)]}}
---@type {[string]: {[string]: {[1]: string, [2]: morphling.Program}[]}}
local profiles = {}
do
  local defines = {
    { "lua", "default", { "stylua" } },
    { "zig", "default", { "zig" } },
    { "python", "default", { "isort", "black" } },
    { "go", "default", { "go" } },
    { "go", "jsontags", { "gomodifytags" } },
    { "c", "default", { "clang-format" } },
    { "fish", "default", { "fish-indent" } },
  }
  for ft, profile_name, prog_names in listlib.iter_unpacked(defines) do
    if profiles[ft] == nil then profiles[ft] = {} end
    if profiles[ft][profile_name] ~= nil then error("duplicate definitions for profile " .. profile_name) end
    profiles[ft][profile_name] = fn.tolist(fn.map(function(name) return { name, assert(programs[name]) } end, prog_names))
  end
end

local diffpatch
do
  ---ref: https://www.gnu.org/software/diffutils/manual/html_node/Detailed-Unified.html

  ---@alias morphling.DiffHunk {[1]: integer, [2]: integer, [3]: integer, [4]: integer}

  ---@param bufnr integer
  ---@param formatted string[]
  ---@param hunks morphling.DiffHunk[]
  local function patch(bufnr, formatted, hunks)
    local offset = 0
    for start_a, count_a, start_b, count_b in listlib.iter_unpacked(hunks) do
      assert(not (count_a == 0 and count_b == 0))

      local lines
      if count_b == 0 then
        lines = {}
      else
        local start = start_b
        lines = fn.tolist(fn.slice(formatted, start, start + count_b))
      end

      do
        local start, stop
        if count_a == 0 then -- append
          start = start_a - 1 + offset + 1
          stop = start
        elseif count_b == 0 then -- delete
          start = start_a - 1 + offset
          stop = start + count_a
        else
          start = start_a - 1 + offset
          stop = start + count_a
        end
        api.nvim_buf_set_lines(bufnr, start, stop, false, lines)
      end

      offset = offset + (count_b - count_a)
    end
  end

  ---@param bufnr integer
  ---@param formatted string[]
  function diffpatch(bufnr, formatted)
    local hunks
    do
      local a = table.concat(api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
      local b = table.concat(formatted, "\n")
      hunks = vim.diff(a, b, { result_type = "indices" })
      if #hunks == 0 then return jelly.debug("no need to patch") end
    end

    ctx.bufviews(bufnr, function()
      ctx.undoblock(bufnr, function() patch(bufnr, formatted, hunks) end)
    end)
  end
end

local regulator = Regulator(1024)

---@param bufnr? integer
---@param ft? string
---@param profile? string
function M.morph(bufnr, ft, profile)
  bufnr = bufnr or api.nvim_get_current_buf()
  if regulator:throttled(bufnr) then return jelly.debug("no change") end

  ft = ft or prefer.bo(bufnr, "filetype")
  profile = profile or "default"

  local progs = dictlib.get(profiles, ft, profile) or {}
  if #progs == 0 then return jelly.info("no available formatting programs") end

  jelly.info("using ft=%s, profile=%s, bufnr=%d, progs=%d", ft, profile, bufnr, #progs)

  local tmpfpath
  do -- prepare tmpfile
    tmpfpath = os.tmpname()
    if not cthulhu.nvim.dump_buffer(bufnr, tmpfpath) then return jelly.err("failed to dump buf#%d", bufnr) end
  end

  --progs pipeline against tmpfile
  for name, prog in listlib.iter_unpacked(progs) do
    if not prog(tmpfpath) then
      jelly.warn("failed to run %s", name)
      subprocess.tail_logs()
      return
    end
  end

  do -- sync back & save
    local formatted = {}
    for line in io.lines(tmpfpath) do
      table.insert(formatted, line)
    end
    diffpatch(bufnr, formatted)
    api.nvim_buf_call(bufnr, function() ex.eval("silent write") end)
    regulator:update(bufnr)
  end

  -- cleanup
  uv.fs_unlink(tmpfpath)
end

M.comp = {
  ---@param ft string @filetype
  ---@return string[]
  available_profiles = function(ft)
    local avails = profiles[ft]
    if avails == nil then return {} end
    return dictlib.keys(avails)
  end,
}

return M
