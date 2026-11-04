-- Engine/FFI smoke test:
--   nvim --clean --headless -u NONE -l tests/native.lua
vim.opt.rtp:prepend(vim.fn.getcwd())

local board_mod = require "nvimesweeper.board"

local function check(ok, what)
  if not ok then
    error("nvimesweeper: " .. what, 0)
  end
end

local w, h, mines = 16, 16, 40
local board = board_mod.new_board(w, h, mines)

check(board.width == w and board.height == h, "board dimensions")
check(board.mine_count == mines, "mine count")
check(board.unrevealed_count == w * h, "unrevealed count")

-- markers placed before the first reveal must survive it
-- engine level only: the game blocks marking until the first reveal
check(board:flag_unrevealed(100, board_mod.SQUARE_FLAGGED), "flag before start")
check(board.flag_count == 1, "flag count before start")

board:place_mines(1, 42)
check(board.flag_count == 1, "flag survived mine placement")
check(board:state(100) == board_mod.SQUARE_FLAGGED, "flag survived placement")

local placed = 0
for i = 1, w * h do
  if board:mine(i) then
    placed = placed + 1
  end
end
check(placed == mines, "placed mine count")

-- the start square and its neighbours are always clear
check(board:danger(1) == 0, "start square danger")

local n, x1, y1, x2, y2 = board:reveal_at(1)
check(n > 0, "reveal reported changes")
check(board.unrevealed_count == w * h - n, "unrevealed after reveal")
check(board:state(1) == board_mod.SQUARE_REVEALED, "start square revealed")

local min_x, min_y, max_x, max_y = w, h, -1, -1
for i = 1, w * h do
  if board:state(i) == board_mod.SQUARE_REVEALED then
    local x = (i - 1) % w
    local y = math.floor((i - 1) / w)
    min_x, max_x = math.min(min_x, x), math.max(max_x, x)
    min_y, max_y = math.min(min_y, y), math.max(max_y, y)
  end
end
check(x1 == min_x and y1 == min_y, "bounds origin")
check(x2 == max_x and y2 == max_y, "bounds extent")

check(board:reveal_at(1) == 0, "re-reveal is a no-op")
check(not board:flag_unrevealed(1, board_mod.SQUARE_FLAGGED), "revealed square")

local hidden
for i = 1, w * h do
  if board:state(i) == board_mod.SQUARE_NONE then
    hidden = i
    break
  end
end
check(hidden ~= nil, "a square is still hidden")
check(board:flag_unrevealed(hidden, board_mod.SQUARE_MAYBE), "mark square")
check(board:state(hidden) == board_mod.SQUARE_MAYBE, "mark state")
check(board.flag_count == 1, "mark does not count as a flag")

board:free()
check(board.handle == nil, "board freed")

check(not pcall(board_mod.new_board, 0, 0, 0), "rejects empty boards")

print "native ok"
