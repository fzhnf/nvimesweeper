local native = require "nvimesweeper.native"

local util = require "nvimesweeper.util"
local error = util.error

local M = {
  SQUARE_NONE = 0,
  SQUARE_FLAGGED = 1,
  SQUARE_MAYBE = 2,
  SQUARE_REVEALED = 3,
}

function M.is_revealable(state)
  return state == M.SQUARE_NONE or state == M.SQUARE_MAYBE
end

local Board = {}

-- counters are owned by the engine; read them on demand so they cannot drift
local counters = {
  mine_count = native.mine_count,
  flag_count = native.flag_count,
  unrevealed_count = native.unrevealed_count,
}

local function board_index(self, key)
  local counter = counters[key]
  if counter then
    return counter(self.handle)
  end
  return Board[key]
end

function Board:is_valid(x, y)
  return x >= 0 and y >= 0 and x < self.width and y < self.height
end

function Board:index(x, y)
  return self:is_valid(x, y) and self.width * y + x + 1 or nil
end

function Board:state(i)
  return self.state_ptr[i - 1]
end

function Board:mine(i)
  return self.mines_ptr[i - 1] ~= 0
end

function Board:danger(i)
  return self.danger_ptr[i - 1]
end

function Board:place_mines(i, seed)
  if native.place_mines(self.handle, i, seed) == 0 then
    error "failed to place mines!"
  end
end

-- returns the number of squares revealed, plus the 0-based bounding box of
-- those squares (only returned when squares were revealed)
function Board:reveal_at(i)
  return native.reveal(self.handle, i)
end

function Board:flag_unrevealed(i, new_state)
  return native.flag(self.handle, i, new_state) ~= 0
end

function Board:free()
  if self.handle then
    native.free(self.handle)
    self.handle = nil
    self.state_ptr, self.mines_ptr, self.danger_ptr = nil, nil, nil
  end
end

function M.new_board(width, height, mine_count)
  local handle = native.new(width, height, mine_count)
  if handle == 0 then
    error(
      ("cannot create a %dx%d board with %d mines!"):format(
        width,
        height,
        mine_count
      )
    )
  end

  return setmetatable({
    handle = handle,
    width = width,
    height = height,
    state_ptr = native.state(handle),
    mines_ptr = native.mines(handle),
    danger_ptr = native.danger(handle),
  }, {
    __index = board_index,
  })
end

return M
