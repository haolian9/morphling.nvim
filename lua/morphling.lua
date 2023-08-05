--
-- design choices
-- * only for files of source code
-- * no communicate with external formatting program
-- * run runners by order, crashing wont make original buffer dirty
-- * suppose all external formatting program do inplace
--

local M = {}

local cthulhu = require("cthulhu")
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

local mktempfile = os.tmpname

local resolve_stylua_config
do
  local function find(root)
    if root == nil then return end
    for _, basename in ipairs({ "stylua.toml", ".stylua.toml" }) do
      local path = fs.joinpath(root, basename)
      if fs.exists(path) then return path end
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

-- all runners should modify the file inplace
---@type { [string]: fun(fpath: string): boolean}
local runners = {
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
  fnlfmt = function(fpath)
    local cp = subprocess.run("fnlfmt", { args = { "--fix", fpath } })
    return cp.exit_code == 0
  end,
  rustfmt = function(fpath)
    local cp = subprocess.run("rustfmt", { args = { fpath } })
    return cp.exit_code == 0
  end,
}

-- {ft: {profile: [(runner-name, runner)]}}
local profiles = {}
do
  local defines = {
    { "lua", "default", { "stylua" } },
    { "zig", "default", { "zig" } },
    { "python", "default", { "isort", "black" } },
    { "go", "default", { "go" } },
    { "c", "default", { "clang-format" } },
    { "fennel", "default", { "fnlfmt" } },
    { "rust", "default", { "rustfmt" } },
  }
  for _, def in ipairs(defines) do
    local ft, pro, runs = unpack(def)
    if profiles[ft] == nil then profiles[ft] = {} end
    if profiles[ft][pro] ~= nil then error("duplicate definitions for profile " .. pro) end
    profiles[ft][pro] = fn.tolist(fn.map(function(name)
      local r = runners[name]
      assert(r, "no such runner " .. name)
      return { name, r }
    end, runs))
  end
end

---@param bufnr number
---@param callback fun()
local function keep_view(bufnr, callback)
  assert(bufnr)

  -- [(winid, view)]
  local state = {}

  local bufinfo = vim.fn.getbufinfo(bufnr)[1]
  assert(bufinfo)

  for winid in listlib.iter(bufinfo.windows) do
    api.nvim_win_call(winid, function() table.insert(state, { winid, vim.fn.winsaveview() }) end)
  end

  callback()

  for winid, view in listlib.iter_unpacked(state) do
    api.nvim_win_call(winid, function() vim.fn.winrestview(view) end)
  end
end

local diffpatch
do
  ---ref: https://www.gnu.org/software/diffutils/manual/html_node/Detailed-Unified.html

  ---@class morphling.Patcher
  ---@field private bufnr integer
  ---@field private formatted string[]
  ---@field private offset integer
  local Patcher = {}

  Patcher.__index = Patcher

  function Patcher:__call(start_a, count_a, start_b, count_b)
    assert(not (count_a == 0 and count_b == 0))

    local lines
    do
      local s = start_b
      if count_b == 0 then
        lines = {}
      else
        lines = fn.tolist(fn.slice(self.formatted, s, s + count_b))
      end
    end

    do
      local start, stop
      if count_a == 0 then -- append
        start = start_a - 1 + self.offset + 1
        stop = start
      elseif count_b == 0 then -- delete
        start = start_a - 1 + self.offset
        stop = start + count_a
      else
        start = start_a - 1 + self.offset
        stop = start + count_a
      end
      api.nvim_buf_set_lines(self.bufnr, start, stop, false, lines)
    end

    self.offset = self.offset + (count_b - count_a)
  end

  ---@param bufnr integer
  ---@param formatted string[]
  function diffpatch(bufnr, formatted)
    local patcher = setmetatable({ bufnr = bufnr, formatted = formatted, offset = 0 }, Patcher)

    ---todo: Vim:E790: undojoin is not all owed after undo
    -- local bo = prefer.buf(self.bufnr)
    -- local undolevels = bo.undolevels
    -- bo.undolevels = undolevels
    -- vim.cmd.undojoin()
    -- bo.undolevels = undolevels

    local a = table.concat(api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
    local b = table.concat(formatted, "\n")
    vim.diff(a, b, { on_hunk = function(...) patcher(...) end })
  end
end

local regulator = Regulator(1024)

---@param bufnr? integer
---@param ft? string
---@param profile? string
function M.run(bufnr, ft, profile)
  bufnr = bufnr or api.nvim_get_current_buf()
  if regulator:throttled(bufnr) then return jelly.debug("no change") end

  ft = ft or prefer.bo(bufnr, "filetype")
  profile = profile or "default"

  local runs = dictlib.get(profiles, ft, profile) or {}

  if #runs == 0 then return jelly.info("no available formatting runners") end

  local tmpfpath = mktempfile()

  jelly.info("using ft=%s, profile=%s, bufnr=%d, runners=%d", ft, profile, bufnr, #runs)

  -- prepare tmpfile
  if not cthulhu.nvim.dump_buffer(bufnr, tmpfpath) then return jelly.err("failed to dump buffer") end

  -- runner pipeline against tmpfile
  for name, run in listlib.iter_unpacked(runs) do
    if not run(tmpfpath) then
      jelly.warn("failed to run %s", name)
      subprocess.tail_logs()
      return
    end
  end

  -- sync back & save
  do
    local formatted = {}
    for line in io.lines(tmpfpath) do
      table.insert(formatted, line)
    end
    keep_view(bufnr, function()
      diffpatch(bufnr, formatted)
      -- the reported errors are insane!
      -- pcall(api.nvim_buf_set_lines, bufnr, 0, -1, false, lines)
    end)
    api.nvim_buf_call(bufnr, function() ex("silent write") end)
    regulator:update(bufnr)
  end

  -- cleanup
  uv.fs_unlink(tmpfpath)
end

return M
