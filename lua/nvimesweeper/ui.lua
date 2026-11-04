local api, fn, uv = vim.api, vim.fn, vim.uv

local config_mod = require "nvimesweeper.config"
local board_mod = require "nvimesweeper.board"
local game_state = require "nvimesweeper.game_state"

local util = require "nvimesweeper.util"
local error = util.error

local M = {
  uis = {},
}

local ns = api.nvim_create_namespace "nvimesweeper"
local Ui = {}

-- terminal cells are about three times taller than wide, so a square spans
-- CELL_WIDTH columns to look square
local CELL_WIDTH = 3

-- one square as CELL_WIDTH columns, with the symbol centred
local function square_text(char)
  local pad = math.max(0, CELL_WIDTH - #char)
  local left = math.floor(pad / 2)
  return string.rep(" ", left) .. char .. string.rep(" ", pad - left)
end

-- shown under the board; keep each short enough for the narrowest float
local HINTS = {
  "<CR> reveal  <Space> flag/mark",
  "q close  Q kill  F1 help",
}

-- while a game window is focused, mappings resolve faster so that <Space> alone
-- does not have to wait out the configured chord window
local GAME_TIMEOUTLEN = 100

local function scope_timeout(ui, to_game)
  if to_game then
    ui.saved_timeoutlen = ui.saved_timeoutlen or vim.o.timeoutlen
    vim.o.timeoutlen = GAME_TIMEOUTLEN
  elseif ui.saved_timeoutlen and vim.o.timeoutlen == GAME_TIMEOUTLEN then
    vim.o.timeoutlen = ui.saved_timeoutlen
    ui.saved_timeoutlen = nil
  else
    -- changed by hand meanwhile: leave it alone
    ui.saved_timeoutlen = nil
  end
end

function Ui:enable_modification(enable)
  vim.bo[self.buf].modifiable = enable
end

local function centering_left_pad(ui, len)
  if not ui.centered then
    return 0
  end
  local pad = (api.nvim_win_get_width(0) - len) / 2
  return math.floor(math.max(0, pad))
end

function Ui:redraw_status()
  local function time_string(show_ms)
    local nanoseconds = uv.hrtime() - self.game.start_time
    local seconds = math.floor(nanoseconds / 1000000000)
    local minutes = math.floor(seconds / 60)

    local time = string.format("Time: %02d:%02d", minutes, seconds % 60)
    if show_ms then
      local milliseconds = math.floor(nanoseconds / 1000000)
      time = string.format("%s.%03d", time, milliseconds % 1000)
    end
    return time
  end

  local state = self.game.state
  local hl_col1, hl_col2, hl_group
  local status = { "", "" }
  if state == game_state.GAME_NOT_STARTED then
    status[1] = "Reveal a square or press F1 for help."
  elseif state == game_state.GAME_STARTED then
    local board = self.game.board
    status[1] = "Flagged: " .. board.flag_count .. "/" .. board.mine_count
    local hl_len = #status[1]
    status[1] = time_string() .. "    " .. status[1]
    if board.flag_count > board.mine_count then
      hl_col1 = #status[1] - hl_len
      hl_col2, hl_group = hl_col1 + hl_len, "NvimesweeperTooManyFlags"
    end
  elseif game_state.is_game_over(state) then
    if state == game_state.GAME_WON then
      status[1] = "Congratulations, you win!"
      hl_group = "NvimesweeperWin"
    elseif state == game_state.GAME_LOST then
      status[1] = "KA-BOOM! You explode..."
      hl_group = "NvimesweeperLose"
    end
    hl_col1, hl_col2 = 0, #status[1]
    status[1] = status[1] .. " " .. time_string(true)
    status[2] = "Seed: " .. self.game.seed
  end

  local left_pads = {}
  for i, s in ipairs(status) do
    left_pads[i] = centering_left_pad(self, #s)
    status[i] = string.rep(" ", left_pads[i]) .. s
  end

  self:enable_modification(true)
  api.nvim_buf_set_lines(self.buf, 0, 2, false, status)
  self:enable_modification(false)

  if hl_col1 then
    self.status_hl_extmark =
      api.nvim_buf_set_extmark(self.buf, ns, 0, hl_col1 + left_pads[1], {
        id = self.status_hl_extmark,
        end_col = hl_col2 + left_pads[1],
        hl_group = hl_group,
      })
  elseif self.status_hl_extmark then
    api.nvim_buf_del_extmark(self.buf, ns, self.status_hl_extmark)
    self.status_hl_extmark = nil
  end
end

function Ui:board_square_char(i)
  local board_chars = config_mod.config.board_chars
  local board = self.game.board
  local game_over = game_state.is_game_over(self.game.state)
  local state = board:state(i)
  local mine = board:mine(i)
  local char = board_chars.unrevealed

  if
    mine
    and (
      state == board_mod.SQUARE_REVEALED
      or (game_over and state ~= board_mod.SQUARE_FLAGGED)
    )
  then
    char = board_chars.mine
  elseif state == board_mod.SQUARE_FLAGGED then
    local flag_wrong = game_over and not mine
    char = flag_wrong and board_chars.flag_wrong or board_chars.flag
  elseif state == board_mod.SQUARE_MAYBE then
    char = board_chars.maybe
  elseif state == board_mod.SQUARE_REVEALED then
    local danger = board:danger(i)
    char = danger > 0 and tostring(danger) or board_chars.revealed
  end

  return char
end

function Ui:board_square_hl_group(i)
  local board = self.game.board
  local game_over = game_state.is_game_over(self.game.state)
  local state = board:state(i)
  local hl_group = "NvimesweeperUnrevealed"

  if game_over and board:mine(i) then
    if state == board_mod.SQUARE_REVEALED then
      hl_group = "NvimesweeperTriggeredMine"
    elseif state == board_mod.SQUARE_FLAGGED then
      hl_group = "NvimesweeperFlag"
    else
      hl_group = "NvimesweeperMine"
    end
  elseif state == board_mod.SQUARE_FLAGGED then
    hl_group = game_over and "NvimesweeperFlagWrong" or "NvimesweeperFlag"
  elseif state == board_mod.SQUARE_MAYBE then
    hl_group = "NvimesweeperMaybe"
  elseif state == board_mod.SQUARE_REVEALED then
    local danger = board:danger(i)
    hl_group = danger > 0 and ("NvimesweeperDanger" .. danger)
      or "NvimesweeperRevealed"
  else
    -- checkerboard the hidden squares so runs of them stay countable
    local x = (i - 1) % board.width
    local y = math.floor((i - 1) / board.width)
    if (x + y) % 2 == 1 then
      hl_group = "NvimesweeperUnrevealedAlt"
    end
  end

  return hl_group
end

function Ui:redraw_board(x1, y1, x2, y2)
  x1, y1 = x1 or 0, y1 or 0
  x2, y2 = x2 or self.game.board.width - 1, y2 or self.game.board.height - 1

  local top_left_i = self.game.board:index(x1, y1)
  local top_left_pos = self:board_square_pos(top_left_i)

  -- modify the changed part of each row
  self:enable_modification(true)
  local row = {}
  for y = y1, y2 do
    local i = self.game.board:index(x1, y)
    for x = x1, x2 do
      row[x - x1 + 1] = square_text(self:board_square_char(i))
      i = i + 1
    end

    local oy = y - y1
    api.nvim_buf_set_text(
      self.buf,
      top_left_pos[1] + oy,
      top_left_pos[2],
      top_left_pos[1] + oy,
      top_left_pos[2] + #row * CELL_WIDTH,
      { table.concat(row) }
    )
  end
  self:enable_modification(false)

  -- update extended marks
  for y = y1, y2 do
    local i = self.game.board:index(x1, y)
    local mark_y = top_left_pos[1] + y - y1
    for x = x1, x2 do
      local mark_x = top_left_pos[2] + (x - x1) * CELL_WIDTH
      self.board_extmarks[i] =
        api.nvim_buf_set_extmark(self.buf, ns, mark_y, mark_x, {
          id = self.board_extmarks[i],
          end_col = mark_x + CELL_WIDTH,
          hl_group = self:board_square_hl_group(i),
        })
      i = i + 1
    end
  end
end

function Ui:full_redraw()
  self.centered = api.nvim_win_get_config(0).relative ~= ""
  self:redraw_status()

  -- usually, only the changed area of the board is updated, which requires the
  -- lines to already exist, so create filler lines to fit the entire board
  local board_width = self.game.board.width * CELL_WIDTH
  local left_pad = centering_left_pad(self, board_width)
  local line = string.rep(" ", left_pad + board_width)
  local lines = {}
  for i = 1, self.game.board.height do
    lines[i] = line
  end

  -- keybind hints, centred like the board
  lines[#lines + 1] = ""
  for _, hint in ipairs(HINTS) do
    lines[#lines + 1] = string.rep(" ", centering_left_pad(self, #hint)) .. hint
  end

  -- extmarks below the status rows are recreated on every repaint
  self.board_extmarks = {}

  self:enable_modification(true)
  -- rows 0-1 hold the status; replacing everything below keeps repaints of an
  -- existing buffer idempotent
  api.nvim_buf_set_lines(self.buf, 2, -1, false, lines)
  self:enable_modification(false)

  -- place an extmark for the board's top-left corner so it knows where to draw
  self.board_extmarks[1] = api.nvim_buf_set_extmark(self.buf, ns, 2, left_pad, {
    id = self.board_extmarks[1],
  })
  self:redraw_board()
end

function Ui:start_status_redraw()
  self.redraw_status_timer:start(
    0,
    1000,
    vim.schedule_wrap(function()
      -- a hidden game must not centre its status against another window
      if
        api.nvim_buf_is_loaded(self.buf)
        and api.nvim_get_current_buf() == self.buf
      then
        self:redraw_status()
      end
    end)
  )
end

function Ui:stop_status_redraw()
  self.redraw_status_timer:stop()
end

function Ui:cleanup()
  self:stop_status_redraw()
  scope_timeout(self, false)
  self.game.board:free()
  M.uis[self.buf] = nil
end

function Ui:board_square_pos(i)
  local pos =
    api.nvim_buf_get_extmark_by_id(self.buf, ns, self.board_extmarks[i], {})
  return pos
end

-- uses current window cursor position if wx is nil
function Ui:win_to_board_pos(wx, wy)
  local board_pos = self:board_square_pos(1)
  if not wx then
    local cursor_pos = api.nvim_win_get_cursor(0)
    -- nvim_win_get_cursor gives 1-indexed rows
    wx, wy = cursor_pos[2], cursor_pos[1] - 1
  end
  return math.floor((wx - board_pos[2]) / CELL_WIDTH), wy - board_pos[1]
end

-- square under the cursor, clamped into the board
function Ui:cursor_tile()
  local x, y = self:win_to_board_pos()
  return math.max(0, math.min(self.game.board.width - 1, x)),
    math.max(0, math.min(self.game.board.height - 1, y))
end

-- move the cursor to a square centre, clamping at the board edges
function Ui:put_cursor_on_tile(x, y)
  x = math.max(0, math.min(self.game.board.width - 1, x))
  y = math.max(0, math.min(self.game.board.height - 1, y))
  local origin = self:board_square_pos(1)
  api.nvim_win_set_cursor(0, {
    origin[1] + y + 1,
    origin[2] + x * CELL_WIDTH + math.floor(CELL_WIDTH / 2),
  })
end

-- keep the cursor on a square centre, and inside the board
function Ui:snap_cursor()
  if api.nvim_get_current_buf() ~= self.buf or not self.board_extmarks[1] then
    return
  end
  local x, y = self:cursor_tile()
  local origin = self:board_square_pos(1)
  local want = {
    origin[1] + y + 1,
    origin[2] + x * CELL_WIDTH + math.floor(CELL_WIDTH / 2),
  }
  if not vim.deep_equal(api.nvim_win_get_cursor(0), want) then
    api.nvim_win_set_cursor(0, want)
  end
end

-- close the window but keep the game, so it can be reopened
function Ui:close_pane()
  if not pcall(vim.cmd, "close") then
    vim.cmd "enew"
  end
end

local function create_window(ui, float_opts)
  local win
  if float_opts then
    win = api.nvim_open_win(ui.buf, true, {
      relative = "editor",
      width = float_opts.width,
      height = float_opts.height,
      row = math.max(0, math.floor((vim.o.lines - float_opts.height) / 2) - 1),
      col = math.floor((vim.o.columns - float_opts.width) / 2),
      style = "minimal",
      border = "single",
    })
    win = win ~= 0 and win or nil
  else
    local ok, _ = pcall(vim.cmd, "tab sbuffer " .. ui.buf)
    if ok then
      win = api.nvim_get_current_win()
    end
  end

  if not win then
    return false
  end

  if float_opts then
    -- the game outlives its window: `q` hides it, `Q` deletes it
    vim.bo[ui.buf].bufhidden = "hide"
  else
    -- float "minimal" style already sets these
    vim.wo[win].list = false
    vim.wo[win].spell = false
  end

  vim.wo[win].wrap = false
  return true
end

local function move_cursor_to_click()
  fn.getchar()
  if api.nvim_get_vvar "mouse_winid" == api.nvim_get_current_win() then
    api.nvim_win_set_cursor(
      0,
      { api.nvim_get_vvar "mouse_lnum", api.nvim_get_vvar "mouse_col" - 1 }
    )
  end
end

function M.new_ui(game, open_tab)
  -- listed so a hidden game can be found again with `:b [nvimesweeper`
  local buf = api.nvim_create_buf(true, true)
  if buf == 0 then
    error "failed to create game buffer!"
  end

  local ui = setmetatable({
    buf = buf,
    game = game,
    board_extmarks = {},
    redraw_status_timer = uv.new_timer(),
  }, {
    __index = Ui,
  })

  if
    not create_window(ui, not open_tab and {
      width = math.max(42, game.board.width * CELL_WIDTH),
      height = game.board.height + 5,
    } or nil)
  then
    api.nvim_buf_delete(buf, { force = true })
    error "failed to open game window!"
  end

  api.nvim_buf_set_name(
    buf,
    string.format(
      "[nvimesweeper %dx%d %d mines (%d)]",
      game.board.width,
      game.board.height,
      game.board.mine_count,
      buf
    )
  )

  util.nnoremap(buf, "<F1>", "<Cmd>help nvimesweeper-maps<CR>")

  local game_mod = require "nvimesweeper.game"
  util.nnoremap(buf, "<LeftMouse>", function()
    move_cursor_to_click()
    game_mod.reveal()
  end, "Reveal square using the mouse")
  util.nnoremap(buf, "<RightMouse>", function()
    move_cursor_to_click()
    game_mod.place_marker()
  end, "Cycle square marker using the mouse")

  util.nnoremap(buf, { "<CR>", "x" }, game_mod.reveal, "Reveal square")
  -- <Space> stays a leader prefix: no nowait, so chords can still match
  util.nnoremap(
    buf,
    "<Space>",
    game_mod.place_marker,
    "Cycle square marker",
    false
  )

  util.nnoremap(buf, "!", function()
    game_mod.place_marker(board_mod.SQUARE_FLAGGED)
  end, "Flag square")
  util.nnoremap(buf, "?", function()
    game_mod.place_marker(board_mod.SQUARE_MAYBE)
  end, "Mark square")

  util.nnoremap(buf, "q", function()
    ui:close_pane()
  end, "Close the game window")
  util.nnoremap(buf, "Q", function()
    api.nvim_buf_delete(buf, { force = true })
  end, "Kill the game")

  local function move(dx, dy)
    return function()
      local x, y = ui:cursor_tile()
      ui:put_cursor_on_tile(x + dx, y + dy)
    end
  end
  util.nnoremap(buf, { "l", "<Right>" }, move(1, 0), "Move right")
  util.nnoremap(buf, { "h", "<Left>" }, move(-1, 0), "Move left")
  util.nnoremap(buf, { "j", "<Down>" }, move(0, 1), "Move down")
  util.nnoremap(buf, { "k", "<Up>" }, move(0, -1), "Move up")

  -- BufDelete is not emitted for every way a buffer can go away, so BufWipeout
  -- is needed as well to free the engine board
  api.nvim_create_autocmd({ "BufDelete", "BufWipeout", "VimLeavePre" }, {
    buffer = buf,
    once = true,
    callback = function()
      if M.uis[buf] then
        M.uis[buf]:cleanup()
      end
    end,
  })

  ui:full_redraw()
  local board_pos = ui:board_square_pos(1)
  board_pos[1] = board_pos[1] + 1 -- nvim_win_set_cursor takes a 1-indexed row
  board_pos[2] = board_pos[2] + math.floor(CELL_WIDTH / 2)
  api.nvim_win_set_cursor(0, board_pos)

  -- keep the cursor on a square centre, inside the board
  for _, event in ipairs { "CursorMoved", "WinEnter" } do
    api.nvim_create_autocmd(event, {
      buffer = buf,
      callback = function()
        ui:snap_cursor()
      end,
    })
  end

  -- shrink the mapping timeout while the game is on screen, restore on leave
  for _, event in ipairs { "BufEnter", "WinEnter" } do
    api.nvim_create_autocmd(event, {
      buffer = buf,
      callback = function()
        scope_timeout(ui, true)
      end,
    })
  end
  for _, event in ipairs { "BufLeave", "WinLeave" } do
    api.nvim_create_autocmd(event, {
      buffer = buf,
      callback = function()
        scope_timeout(ui, false)
      end,
    })
  end
  scope_timeout(ui, true)

  -- hidden games stop ticking; showing them again repaints and resumes
  api.nvim_create_autocmd("BufHidden", {
    buffer = buf,
    callback = function()
      ui:stop_status_redraw()
    end,
  })
  api.nvim_create_autocmd("BufWinEnter", {
    buffer = buf,
    callback = function()
      ui:full_redraw()
      ui:snap_cursor()
      if
        ui.game.state ~= game_state.GAME_NOT_STARTED
        and not game_state.is_game_over(ui.game.state)
      then
        ui:start_status_redraw()
      end
    end,
  })

  M.uis[buf] = ui
  return ui
end

return M
