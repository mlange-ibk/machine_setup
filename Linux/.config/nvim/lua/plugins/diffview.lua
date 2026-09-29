return {
  "sindrets/diffview.nvim",
  cmd = { "DiffviewOpen", "DiffviewClose", "DiffviewFileHistory" },
  keys = {
    { "<leader>gd", "<cmd>DiffviewOpen<cr>", desc = "Diffview: Open (merge/diff)" },
    { "<leader>gD", "<cmd>DiffviewClose<cr>", desc = "Diffview: Close" },
    { "<leader>gh", "<cmd>DiffviewFileHistory %<cr>", desc = "Diffview: File History (current file)" },
  },
  opts = {},
}
