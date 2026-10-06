#!/bin/bash
# Links repo config files to their user-home destinations as symlinks.
# Bash mirror of Windows/linkconfig.ps1 (no elevation needed on Linux).
# Usage: ./linkconfig.sh   (run from the Linux/ directory)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Each entry: "source|destination", source relative to $SCRIPT_DIR,
# destination relative to $HOME.
# Directories are symlinked as a whole (e.g. .config/nvim, worktree scripts).
MAPPINGS=(
  ".zshrc|.zshrc"
  ".config/nvim|.config/nvim"
  ".config/workmux|.config/workmux"
  "../Shared/tmux/tmux.conf|.config/tmux/tmux.conf"
  "../Shared/tmux/tmux.linux.conf|.config/tmux/tmux.os.conf"
  "scripts/tmux-cht.sh|.local/scripts/tmux-cht.sh"
  "scripts/gitmoji_selector.sh|.local/scripts/gitmoji_selector.sh"
  "scripts/gitmojis.json|.local/scripts/gitmojis.json"
  "scripts/tmux-sessionizer|.local/scripts/tmux-sessionizer"
  "../Shared/tmux/scripts|.local/scripts/worktree"
)

link_one() {
  local source="$1" dest="$2"
  local src="$SCRIPT_DIR/$source"
  local dst="$HOME/$dest"

  if [[ ! -e "$src" ]] && [[ ! -L "$src" ]]; then
    echo "  [skip]  source does not exist: $src"
    return
  fi

  if [[ -L "$dst" ]]; then
    local current
    current="$(readlink "$dst" || true)"
    if [[ "$current" == "$src" ]]; then
      echo "  [ok]    already linked: $dest -> $source"
      return
    fi
    echo "  [repl]  replacing stale symlink: $dest"
    rm -f "$dst"
  elif [[ -e "$dst" ]]; then
    local backup="$dst.bak-$(date +%Y%m%d-%H%M%S)"
    echo "  [backup] moving existing: $dest -> $backup"
    mv "$dst" "$backup"
  fi

  mkdir -p "$(dirname "$dst")"
  ln -s "$src" "$dst"
  echo "  [link]  $dest -> $source"
}

echo "Linking repo configs into \$HOME..."
for entry in "${MAPPINGS[@]}"; do
  link_one "${entry%%|*}" "${entry##*|}"
done
echo "Done."
