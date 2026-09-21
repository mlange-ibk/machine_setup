#!/usr/bin/env bash
# ── shared helpers for the git-worktree tmux workflow ──────────────────────
# Sourced by tmux-worktree.sh, tmux-worktree-session.sh, tmux-worktree-migrate.sh

set -euo pipefail

# ── resolve WORKTREE_ROOT (exported by tmux OS override conf) ──────────────
resolve_worktree_root() {
  local root="${WORKTREE_ROOT:-}"
  if [[ -z "$root" ]]; then
    if [[ -d "/mnt/c" ]]; then
      root="C:/Entwicklung/Worktrees"
    else
      root="$HOME/Repository/Worktrees"
    fi
  fi
  # tmux set-environment does not shell-expand $HOME, so the value stored
  # by e.g. set-environment -g WORKTREE_ROOT "$HOME/Repository/Worktrees"
  # arrives as the literal string "$HOME/..."; expand it here.
  # (psmux additionally keeps the surrounding quotes as literal chars —
  #  strip them defensively; on real tmux they are already removed.)
  root="${root%\"}"
  root="${root#\"}"
  root="${root%\'}"
  root="${root#\'}"
  root="${root/\$HOME/$HOME}"
  echo "$root"
}

# ── sanitize branch name for folder / tmux session name ────────────────────
sanitize() {
  echo "$1" | sed 's/[\/\.]/-/g; s/ /_/g; s/^-//; s/-$//'
}

# ── tmux session name for a repo/branch pair ───────────────────────────────
# One worktree = one session. Session names must NOT collide across repos
# that share branch names (master/dev/main), so the session name is the
# sanitized "<repo>-<branch>":  pojSDG dev → pojSDG-dev.
session_name_for() { # $1 = repo name  $2 = branch
  echo "$(sanitize "$1")-$(sanitize "$2")"
}

# ── derive repo name from a path to any folder inside it ───────────────────
#    Walks up to the folder that contains <repo>/.bare (the repo root). A
#    worktree folder itself has its own .git file, so only .bare is a marker.
repo_name_from_path() {
  local dir="$1"
  local root
  root="$(resolve_worktree_root)"
  while [[ "$dir" != "$root" && "$dir" != "/" ]]; do
    if [[ -d "$dir/.bare" ]]; then
      basename "$dir"
      return
    fi
    dir="$(dirname "$dir")"
  done
  basename "$dir"
}

# ── enumerate all bare repos under $WORKTREE_ROOT ──────────────────────────
each_repo() {
  local root
  root="$(resolve_worktree_root)"
  [[ -d "$root" ]] || return 0
  find "$root" -maxdepth 2 -name ".bare" -type d 2>/dev/null | while read bare; do
    echo "$(dirname "$bare")"
  done
}

# ── list tmux sessions whose name contains a given substring ───────────────
has_tmux_session() {
  tmux has-session -t "$1" 2>/dev/null
}
