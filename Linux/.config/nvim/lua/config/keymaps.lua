-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here

-- moves selected lines up and down by 1 and re-selects the lines(gv)
vim.keymap.set("v", "J", ":m '>+1<CR>gv=gv")
vim.keymap.set("v", "K", ":m '<-2<CR>gv=gv")

-- Joins current line with next while keeping cursor position
vim.keymap.set("n", "J", "mzJ`z")
-- zz centeres cursor in the middle of the screen
vim.keymap.set("n", "j", "jzz")
vim.keymap.set("n", "k", "kzz")
vim.keymap.set("n", "<C-d>", "<C-d>zz")
vim.keymap.set("n", "<C-u>", "<C-u>zz")
vim.keymap.set("n", "<C-f>", "<C-f>zz")
vim.keymap.set("n", "<C-b>", "<C-b>zz")
vim.keymap.set("n", "n", "nzzzv")
vim.keymap.set("n", "N", "Nzzzv")
-- Formats a paragraph(=ap) and keeps current position
vim.keymap.set("n", "=ap", "ma=ap'a")

-- pastes and deletes the current line without affecting the clipboard
vim.keymap.set("x", "<leader>p", [["_dP]])
-- deletes into blach hole register
vim.keymap.set({ "n", "v" }, "<leader>d", '"_d')

-- yank to the system clipboard
vim.keymap.set({ "n", "v" }, "<leader>y", [["+y]])
vim.keymap.set("n", "<leader>Y", [["+Y]])

-- Quickfix navigation with centering
vim.keymap.set("n", "<C-k>", "<cmd>cnext<CR>zz")
vim.keymap.set("n", "<C-j>", "<cmd>cprev<CR>zz")
vim.keymap.set("n", "<leader>k", "<cmd>lnext<CR>zz")
vim.keymap.set("n", "<leader>j", "<cmd>lprev<CR>zz")

-- Search and Replace Current Word
-- \<<C-r><C-w>\> retrieves the word under the cursor for the search pattern.
-- /<C-r><C-w>/gI<Left><Left><Left>
vim.keymap.set("n", "<leader>r", [[:%s/\<<C-r><C-w>\>/<C-r><C-w>/gI<Left><Left><Left>]])

-- Universelle Alt-hjkl-Navigation:
-- Zuerst nvim-Fenster nutzen, damit sich Navigation innerhalb von nvim natürlich anfühlt.
-- Falls nvim in die gewünschte Richtung kein Fenster hat, übernehmen wir tmux,
-- damit man ohne Modifier-Wechsel auch zwischen nvim und tmux-Panes wechseln kann.
local function alt_nav(dir)
  local win = vim.api.nvim_get_current_win()

  vim.cmd("silent! wincmd " .. dir)

  if vim.api.nvim_get_current_win() == win then
    if vim.env.TMUX then
      local flags = { h = "-L", j = "-D", k = "-U", l = "-R" }
      vim.fn.system({ "tmux", "select-pane", flags[dir] })
    end
  end
end

-- Nur Normalmodus belegen:
-- Insert-, Terminal- und buffer-lokale Mappings sollen weiter funktionieren,
-- z. B. Alt+h im Snacks Picker für Hidden Files.
for _, dir in ipairs({ "h", "j", "k", "l" }) do
  vim.keymap.set("n", "<a-" .. dir .. ">", function()
    alt_nav(dir)
  end, { desc = "Navigate nvim/tmux: " .. dir })
end
