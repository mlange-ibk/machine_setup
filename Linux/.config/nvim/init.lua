-- tree-sitter parser builds: use MSYS2 UCRT64 gcc on Windows.
-- The w64devkit GCC linker (and the broken VS 18.1 MSVC) cannot open the
-- `\\?\`-prefixed output paths that the tree-sitter CLI passes to the
-- compiler, so MSYS2's binutils 2.47 linker is used instead.
if vim.fn.has("win32") == 1 then
  local msys_bin = "C:/msys64/ucrt64/bin"
  vim.env.CC = msys_bin .. "/gcc.exe"
  if vim.env.PATH and not vim.env.PATH:find(msys_bin, 1, true) then
    vim.env.PATH = msys_bin .. ";" .. vim.env.PATH
  end
end

-- bootstrap lazy.nvim, LazyVim and your plugins
require("config.lazy")
