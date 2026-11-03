local api = vim.api

local util = require "nvimesweeper.util"
local error = util.error

local ABI_VERSION = 1

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

local M = {}

local lib
local bounds = nil
local cdef_done = false

local function locate()
  local os_dir = jit and os_dirs[jit.os] or nil
  local arch_dir = jit and arch_dirs[jit.arch] or nil
  if not os_dir or not arch_dir then
    error(
      ("no prebuilt engine for %s/%s"):format(
        tostring(jit and jit.os),
        tostring(jit and jit.arch)
      )
    )
  end

  local rel = ("lib/%s-%s/%s"):format(os_dir, arch_dir, lib_names[os_dir])
  local found = api.nvim_get_runtime_file(rel, false)[1]
  if not found then
    error(
      (
        "engine library is missing; build it from the plugin directory with:"
        .. "\n  odin build odin -build-mode:shared -out:%s"
      ):format(rel)
    )
  end
  return found
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
