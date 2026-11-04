local api, uv = vim.api, vim.uv

local util = require "nvimesweeper.util"
local error = util.error

local ABI_VERSION = 1

-- Bump both of these when releasing: the engine is downloaded from the
-- `v<ENGINE_VERSION>` release and must match ENGINE_SHA256.
local ENGINE_VERSION = "0.3.1"
local ENGINE_SHA256 =
  "ab76b100a142dba16e728b2dc7bbf2c038e13e94d261752f6a37c85fe7e73520"
local RELEASE_URL = "https://github.com/fzhnf/nvimesweeper/releases/download"

local cdef = [[
int32_t ms_abi_version(void);
int32_t ms_new(int32_t width, int32_t height, int32_t mines);
void ms_free(int32_t h);
int32_t ms_place_mines(int32_t h, int32_t safe_i, int64_t seed);
int32_t ms_reveal(int32_t h, int32_t i, int32_t *x1, int32_t *y1, int32_t *x2, int32_t *y2);
int32_t ms_flag(int32_t h, int32_t i, int32_t new_state);
uint8_t *ms_state(int32_t h);
uint8_t *ms_mines(int32_t h);
uint8_t *ms_danger(int32_t h);
int32_t ms_mine_count(int32_t h);
int32_t ms_flag_count(int32_t h);
int32_t ms_unrevealed_count(int32_t h);
]]

local os_dirs = { Linux = "linux", OSX = "macos", Windows = "windows" }
local arch_dirs = { x64 = "amd64", arm64 = "arm64" }
local lib_names = {
  linux = "libnvimesweeper.so",
  macos = "libnvimesweeper.dylib",
  windows = "nvimesweeper.dll",
}
local assets = {
  ["linux-amd64"] = "libnvimesweeper-linux-amd64.so",
  ["macos-arm64"] = "libnvimesweeper-macos-arm64.dylib",
  ["windows-amd64"] = "nvimesweeper-windows-amd64.dll",
}

local M = {}

local lib
local bounds = nil
local cdef_done = false

local function platform()
  local os_dir = jit and os_dirs[jit.os] or nil
  local arch_dir = jit and arch_dirs[jit.arch] or nil
  local name = ("%s/%s"):format(
    tostring(jit and jit.os),
    tostring(jit and jit.arch)
  )
  if not os_dir or not arch_dir then
    error("unsupported platform " .. name)
  end

  local dir = os_dir .. "-" .. arch_dir
  return {
    name = name,
    dir = dir,
    file = lib_names[os_dir],
    asset = assets[dir],
  }
end

local function build_hint(p)
  return (
    "build it from the plugin directory with:"
    .. "\n  odin build odin -build-mode=shared -out:lib/%s/%s"
  ):format(p.dir, p.file)
end

local function sha256(path)
  local ok, blob = pcall(vim.fn.readblob, path)
  return ok and vim.fn.sha256(blob) or nil
end

local function cache_path(asset)
  return vim.fs.joinpath(
    vim.fn.stdpath "cache",
    "nvimesweeper",
    ENGINE_VERSION,
    asset
  )
end

local function download(p)
  if not p.asset then
    error(("no prebuilt engine for %s; %s"):format(p.name, build_hint(p)))
  end
  if ENGINE_SHA256 == "" then
    error(
      ("no engine release pinned for v%s yet; %s"):format(
        ENGINE_VERSION,
        build_hint(p)
      )
    )
  end

  local url = ("%s/v%s/%s"):format(RELEASE_URL, ENGINE_VERSION, p.asset)
  local dest = cache_path(p.asset)
  local tmp = dest .. ".part"
  vim.fn.mkdir(vim.fs.dirname(dest), "p")

  vim.notify(
    "nvimesweeper: downloading the game engine...",
    vim.log.levels.INFO
  )
  local res =
    vim.system({ "curl", "-fsSL", "--retry", "2", "-o", tmp, url }):wait()
  if res.code ~= 0 then
    os.remove(tmp)
    error(
      ("failed to download %s\n%s%s"):format(
        url,
        res.stderr or "",
        build_hint(p)
      )
    )
  end

  local hash = sha256(tmp)
  if hash ~= ENGINE_SHA256 then
    os.remove(tmp)
    error(
      ("engine checksum mismatch (%s, want %s); %s"):format(
        hash,
        ENGINE_SHA256,
        build_hint(p)
      )
    )
  end

  uv.fs_unlink(dest)
  uv.fs_rename(tmp, dest)
  return dest
end

local function locate()
  local p = platform()

  -- a locally built engine always wins, so checkouts need no release
  local found =
    api.nvim_get_runtime_file(("lib/%s/%s"):format(p.dir, p.file), false)[1]
  if found then
    return found
  end

  if p.asset and ENGINE_SHA256 ~= "" then
    local cached = cache_path(p.asset)
    if sha256(cached) == ENGINE_SHA256 then
      return cached
    end
  end

  return download(p)
end

local function get_lib()
  if lib then
    return lib
  end

  local ok, ffi = pcall(require, "ffi")
  if not ok then
    error "this Neovim build has no LuaJIT FFI"
  end

  if not cdef_done then
    ffi.cdef(cdef)
    cdef_done = true
    bounds = ffi.new "int32_t[4]"
  end

  local loaded, loaded_lib = pcall(ffi.load, locate())
  if not loaded then
    error("failed to load the engine library: " .. tostring(loaded_lib))
  end

  local abi_ok, abi = pcall(loaded_lib.ms_abi_version)
  if not abi_ok or abi ~= ABI_VERSION then
    error(
      ("engine library has an incompatible ABI (%s, want %d); rebuild it"):format(
        tostring(abi_ok and abi or "missing ms_abi_version"),
        ABI_VERSION
      )
    )
  end

  lib = loaded_lib
  return lib
end

-- Provisions the engine ahead of the first game; never throws, so install hooks
-- can call it. Returns the library path, or nil when the engine is unavailable.
function M.prefetch()
  local ok, path = pcall(locate)
  if not ok then
    vim.notify(
      "nvimesweeper: engine prefetch failed\n" .. tostring(path),
      vim.log.levels.WARN
    )
    return nil
  end
  return path
end

function M.new(width, height, mines)
  return get_lib().ms_new(width, height, mines)
end

function M.free(h)
  get_lib().ms_free(h)
end

function M.place_mines(h, safe_i, seed)
  -- the seed is passed as i64, so keep it in integer range
  return get_lib().ms_place_mines(h, safe_i, math.floor(seed))
end

-- bounds are only returned when squares were revealed
function M.reveal(h, i)
  local n =
    get_lib().ms_reveal(h, i, bounds, bounds + 1, bounds + 2, bounds + 3)
  if n == 0 then
    return 0
  end
  return n, bounds[0], bounds[1], bounds[2], bounds[3]
end

function M.flag(h, i, new_state)
  return get_lib().ms_flag(h, i, new_state)
end

function M.state(h)
  return get_lib().ms_state(h)
end

function M.mines(h)
  return get_lib().ms_mines(h)
end

function M.danger(h)
  return get_lib().ms_danger(h)
end

function M.mine_count(h)
  return get_lib().ms_mine_count(h)
end

function M.flag_count(h)
  return get_lib().ms_flag_count(h)
end

function M.unrevealed_count(h)
  return get_lib().ms_unrevealed_count(h)
end

return M
