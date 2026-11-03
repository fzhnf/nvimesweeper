if vim.fn.has "nvim-0.12" == 0 then
  vim.notify(
    "[nvimesweeper] Neovim version 0.12 or above is required!",
    vim.log.levels.ERROR
  )
  return
end

if vim.g.loaded_nvimesweeper then
  return
end
vim.g.loaded_nvimesweeper = 1

vim.api.nvim_create_user_command("Nvimesweeper", function(opts)
  require("nvimesweeper").play_cmd(opts.args)
end, {
  nargs = "*",
  bar = true,
  desc = "Start a new game of Nvimesweeper",
})

local highlights = {
  NvimesweeperWin = { link = "DiffAdd" },
  NvimesweeperLose = { link = "ErrorMsg" },
  NvimesweeperTooManyFlags = { link = "WarningMsg" },
  NvimesweeperUnrevealed = { ctermbg = "Grey", bg = "#c0c0c0" },
  NvimesweeperMaybe = {
    ctermfg = "Black",
    ctermbg = "Grey",
    fg = "#000000",
    bg = "#c0c0c0",
  },
  NvimesweeperFlag = {
    ctermfg = "Red",
    ctermbg = "Grey",
    fg = "#fe0000",
    bg = "#c0c0c0",
  },
  NvimesweeperRevealed = { ctermbg = "DarkGrey", bg = "#808080" },
  NvimesweeperTriggeredMine = {
    ctermfg = "Black",
    ctermbg = "Red",
    fg = "#000000",
    bg = "#fe0000",
  },
  NvimesweeperMine = {
    ctermfg = "Black",
    ctermbg = "DarkGrey",
    fg = "#000000",
    bg = "#808080",
  },
  NvimesweeperFlagWrong = {
    ctermfg = "Red",
    ctermbg = "DarkGrey",
    fg = "#fe0000",
    bg = "#808080",
  },
  NvimesweeperDanger1 = {
    ctermfg = "DarkBlue",
    ctermbg = "DarkGrey",
    fg = "#0100fe",
    bg = "#808080",
  },
  NvimesweeperDanger2 = {
    ctermfg = "Green",
    ctermbg = "DarkGrey",
    fg = "#02c902",
    bg = "#808080",
  },
  NvimesweeperDanger3 = {
    ctermfg = "Red",
    ctermbg = "DarkGrey",
    fg = "#fe0000",
    bg = "#808080",
  },
  NvimesweeperDanger4 = {
    ctermfg = "DarkMagenta",
    ctermbg = "DarkGrey",
    fg = "#00007f",
    bg = "#808080",
  },
  NvimesweeperDanger5 = {
    ctermfg = "DarkRed",
    ctermbg = "DarkGrey",
    fg = "#800000",
    bg = "#808080",
  },
  NvimesweeperDanger6 = {
    ctermfg = "DarkCyan",
    ctermbg = "DarkGrey",
    fg = "#00d4d4",
    bg = "#808080",
  },
  NvimesweeperDanger7 = {
    ctermfg = "Black",
    ctermbg = "DarkGrey",
    fg = "#000000",
    bg = "#808080",
  },
  NvimesweeperDanger8 = {
    ctermfg = "White",
    ctermbg = "DarkGrey",
    fg = "#ffffff",
    bg = "#808080",
  },
}

local function define_highlights()
  for name, hl in pairs(highlights) do
    hl.default = true
    vim.api.nvim_set_hl(0, name, hl)
  end
end

vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("nvimesweeper_highlights", {
    clear = true,
  }),
  callback = define_highlights,
})

define_highlights()
