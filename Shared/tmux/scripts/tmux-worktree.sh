#!/usr/bin/env bash
# ── worktree picker (<leader>w) ─────────────────────────────────────────────
# Opens an fzf popup listing:
#   • worktrees with a live tmux session      → Enter switches in
#   • worktrees on disk, no session yet       → Enter switches in (bootstrap 5-window layout)
#   • branches with no worktree yet           → Enter checks out into a new worktree
#   • "+ New branch in <repo>"                → Enter prompts for a branch name
#   • "+ Clone new repository"                → Enter clones via gh (or URL paste) + worktree
# Keys:  Enter = smart default   s = switch only   c = checkout/clone only   d = delete worktree
#
# Rows are tab-separated:  type ⇥ repo ⇥ ref ⇥ label

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/worktree-lib.sh"

WORKTREE_ROOT="$(resolve_worktree_root)"
WORKTREE_ROOT="$(cd "$WORKTREE_ROOT" && pwd)"

# display-popup inherits the cwd of the pane that triggered it. If that pane's
# cwd is inside the very worktree you go on to delete, this script's own
# process keeps that folder open for its whole lifetime — on Windows that is
# enough to block `git worktree remove` even after the target session is
# killed. Move to a folder that can never itself be a delete target.
cd "$WORKTREE_ROOT"

# ── helpers ─────────────────────────────────────────────────────────────────

setup_bare() { # $1 = repo dir (absolute)   $2 = clone URL
  local repo="$1" url="$2"
  local bare="$repo/.bare"
  mkdir -p "$repo"
  git clone --bare "$url" "$bare" >/dev/null 2>&1 || return 1
  git --git-dir="$bare" config --bool core.bare false
  echo "gitdir: $bare" > "$repo/.git"
  # a bare clone only fetches the default branch and mirrors it into
  # refs/heads/*; repoint the refspec at a remote-tracking namespace and
  # fetch everything under refs/remotes/origin/*
  git --git-dir="$bare" config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
  git --git-dir="$bare" fetch origin --prune 2>/dev/null || true
  git --git-dir="$bare" remote set-head origin -a 2>/dev/null || true  # origin/HEAD
  # drop the mirrored local branches so no ref is "checked out" at the bare
  # repo (that would block `worktree add`), then park HEAD on an unborn ref
  git --git-dir="$bare" for-each-ref --format='%(refname)' refs/heads | while read -r r; do
    git --git-dir="$bare" update-ref -d "$r"
  done
  git --git-dir="$bare" symbolic-ref HEAD refs/heads/worktree-root
  git --git-dir="$bare" remote set-url --push origin "$url" 2>/dev/null || true
}

add_worktree() { # $1 = repo (abs)  $2 = branch  $3 = target dir (abs)  $4 = start-point (optional)
  local repo="$1" branch="$2" target="$3" start="${4:-}"
  if [[ -n "$start" ]]; then
    git --git-dir="$repo/.bare" worktree add -b "$branch" "$target" "$start" 2>/dev/null \
      || git --git-dir="$repo/.bare" worktree add "$target" "$branch"
  else
    git --git-dir="$repo/.bare" worktree add -b "$branch" "$target" 2>/dev/null \
      || git --git-dir="$repo/.bare" worktree add "$target" "$branch"
  fi
}

switch_or_attach() { # $1 = session name   $2 = worktree dir (abs, for create)
  local session="$1" dir="$2"
  if ! has_tmux_session "$session"; then
    tmux new-session -d -s "$session" -c "$dir" -n "neovim"
    tmux send-keys -t "$session:neovim" "nvim ." C-m
    tmux new-window -t "$session" -c "$dir" -n "lazygit"
    tmux send-keys -t "$session:lazygit" "lazygit" C-m
    tmux new-window -t "$session" -c "$dir" -n "run"
    tmux new-window -t "$session" -c "$dir" -n "lazysql"
    tmux send-keys -t "$session:lazysql" "lazysql" C-m
    tmux new-window -t "$session" -c "$dir" -n "opencode"
    tmux send-keys -t "$session:opencode" "opencode" C-m
    tmux select-window -t "$session:neovim"
  fi
  tmux switch-client -t "$session" 2>/dev/null || tmux attach-session -t "$session"
}

delete_worktree() { # $1 = repo dir  $2 = worktree path  $3 = session name
  local repo="$1" wt="$2" sess="$3" confirm others sid target sess_live=0
  echo "Delete worktree: $wt" >&2
  if has_tmux_session "$sess"; then
    sess_live=1
    echo "  (will also close tmux session '$sess')" >&2
  fi
  echo -n "Delete? [y/N] " >&2
  read -r confirm
  [[ "$confirm" == [yY] ]] || { echo "Aborted." >&2; return; }

  # A live session's panes hold the worktree folder as their cwd; on Windows
  # that pins the folder so `git worktree remove` cannot delete it. Close the
  # session BEFORE removal (moving the host client away first when this IS the
  # session we run in). git still protects the data: it refuses an unclean
  # tree, so a failure leaves the worktree + changes intact and can be retried.
  if (( sess_live )); then
    if [[ "$(tmux display-message -p -F '#{session_name}')" == "$sess" ]]; then
      # deleting the session we are running in - move the client to the
      # lowest-numbered (oldest) other session, or detach if none remain
      others="$(tmux list-sessions -F '#{session_id}' 2>/dev/null)"
      target="$(while read -r sid; do
                  [[ -n "$sid" ]] || continue
                  local_id="${sid#\$}"
                  local_name="$(tmux display-message -p -t "$sid" -F '#{session_name}')"
                  [[ -n "$local_name" ]] && [[ "$local_name" != "$sess" ]] && echo "$local_id $local_name"
                done <<< "$others" | sort -n -k1 | head -n1 | cut -d' ' -f2-)"
      if [[ -n "$target" ]]; then
        tmux switch-client -t "$target"
        echo "Moved client to session '$target'." >&2
      else
        tmux detach-client
        echo "Detached (no other session to move to)." >&2
      fi
    fi
    tmux kill-session -t "$sess" 2>/dev/null
  fi

  # Removal is attempted immediately below, in this same invocation — the
  # messages above only report the client/session move, not a deferred step.
  if ( cd "$repo" && git --git-dir="$repo/.bare" worktree remove "$wt" 2>&1 ); then
    echo "Removed: $wt" >&2
  else
    echo "Cannot remove worktree. Clean or commit its changes and retry (prefix+w, pick it, press d again)." >&2
    return 1
  fi
}

# ── build the picker list ───────────────────────────────────────────────────

LIST_TMP="$(mktemp)"
trap 'rm -f "$LIST_TMP"' EXIT

# Everything inside this group must be redirected as a whole into $LIST_TMP —
# a genuine, severe bug found here (2026-09-14, pre-dates every other change
# in this file): $LIST_TMP was created and later `cat`, but nothing ever
# wrote to it. Every `printf` below went straight to the script's own
# stdout instead, so `cat "$LIST_TMP" | fzf ...` always fed fzf an empty
# list — fzf had nothing to select from, `$RAW` was always empty, and the
# picker exited immediately via the `[[ -n "$RAW" ]] || exit 0` guard below.
# The picker has likely never shown a real row on Linux.
{
while read -r repo; do
  [[ -n "$repo" ]] || continue
  reponame="$(basename "$repo")"

  # worktrees on disk (with live-session marker where applicable)
  while read -r wt; do
    [[ -n "$wt" ]] || continue
    branch="$(basename "$wt")"
    sess="$(session_name_for "$reponame" "$branch")"
    status=""
    if has_tmux_session "$sess"; then
      status="  (live session)"
    fi
    printf 'switch\t%s\t%s\t[%s] %s%s\n' "$reponame" "$wt" "$reponame" "$branch" "$status"
  done < <(git --git-dir="$repo/.bare" worktree list --porcelain 2>/dev/null | grep '^worktree ' | cut -d' ' -f2- | grep -v "$repo/.bare")

  # branches with no worktree yet (checkout candidates)
  while read -r branch; do
    [[ -n "$branch" ]] || continue
    sanitized="$(sanitize "$branch")"
    [[ -d "$repo/$sanitized" ]] && continue
    printf 'checkout\t%s\t%s\t[%s] %s  (new worktree)\n' "$reponame" "$branch" "$reponame" "$branch"
  done < <(git --git-dir="$repo/.bare" for-each-ref --format='%(refname:short)' refs/remotes/origin 2>/dev/null | sed 's#^origin/##')

  # synthetic "+ New branch" row
  printf 'newbranch\t%s\t\t[%s] + New branch\n' "$reponame" "$reponame"
done < <(each_repo)

# pinned "+ Clone" row (always last)
printf 'clone\t\t\t+ Clone new repository\n'
} > "$LIST_TMP"

# ── fzf ─────────────────────────────────────────────────────────────────────

RAW="$(cat "$LIST_TMP" | fzf \
  --with-nth 4 \
  --delimiter '\t' \
  --prompt 'worktree> ' \
  --header 'Enter: go · s: switch · c: checkout/clone · d: delete worktree' \
  --bind 'enter:accept,s:accept,c:accept' \
  --expect d \
  --preview 'echo {3}')" || true

[[ -n "$RAW" ]] || exit 0

# fzf's `--expect` makes it print TWO lines whenever it's set, regardless of
# which key completed the selection: line 1 is the expect-key indicator
# (empty string for a plain Enter/s/c accept, "d" when d completed it), line
# 2 is the actual selected row. Verified empirically (2026-09-14): a
# previous version of this script read line 1 twice (once for KEY via
# `cut -f1`, once for CHOICE via `cut -f2-`) as if it already contained the
# tab-separated row — but line 1 has no tabs at all, so `cut -f2-` on it
# returns empty (GNU cut's default: a line with no delimiter is passed
# through unchanged by -f1, and -f2- on it is empty), silently producing an
# always-empty TYPE that matched no case below. Every selection, on every
# key, was a no-op with no error.
KEY="$(printf '%s\n' "$RAW" | sed -n '1p')"
CHOICE="$(printf '%s\n' "$RAW" | sed -n '2p')"

TYPE="$(printf '%s' "$CHOICE" | cut -f1)"
REPO="$(printf '%s' "$CHOICE" | cut -f2)"
REF="$(printf '%s' "$CHOICE" | cut -f3)"

# ── dispatch ────────────────────────────────────────────────────────────────

case "$TYPE" in
  switch)
    # NOTE: `break` is a no-op outside a loop in bash (it prints a warning to
    # stderr but does NOT exit the case arm), so this must stay an if/elif/else
    # chain rather than an early-exit `break` — a stale/missing worktree row
    # must never fall through into delete_worktree/switch_or_attach below.
    if [[ ! -d "$REF" ]]; then
      echo "Worktree no longer exists: $REF" >&2
    elif [[ "$KEY" == "d" ]]; then
      delete_worktree "$WORKTREE_ROOT/$REPO" "$REF" "$(session_name_for "$REPO" "$(basename "$REF")")"
    else
      switch_or_attach "$(session_name_for "$REPO" "$(basename "$REF")")" "$REF"
    fi
    ;;

  checkout)
    add_worktree "$WORKTREE_ROOT/$REPO" "$REF" "$WORKTREE_ROOT/$REPO/$(sanitize "$REF")" "origin/$REF"
    switch_or_attach "$(session_name_for "$REPO" "$REF")" "$WORKTREE_ROOT/$REPO/$(sanitize "$REF")"
    ;;

  newbranch)
    echo -n "New branch name (in $REPO): " >&2
    read -r name
    [[ -n "$name" ]] || exit 0
    add_worktree "$WORKTREE_ROOT/$REPO" "$name" "$WORKTREE_ROOT/$REPO/$(sanitize "$name")" "origin/HEAD"
    switch_or_attach "$(session_name_for "$REPO" "$name")" "$WORKTREE_ROOT/$REPO/$(sanitize "$name")"
    ;;

  clone)
    clone_url=""
    # Merge GitHub (gh) and GitLab (glab) repos into a single fzf list, each
    # row tab-delimited as "<clone-url>\t[Provider] <path>" so the already-
    # correct API-provided URL can be lifted straight out of the selection
    # with no manual URL construction (and no github.com/gitlab.com
    # hardcoding — glab's URL reflects whatever host `glab auth login`
    # configured, so this also works against self-hosted GitLab instances).
    candidates=()
    if command -v gh >/dev/null 2>&1; then
      # Respect the user's configured git protocol (`gh config get
      # git_protocol`, per-host, defaults to https) rather than hardcoding
      # https — an ssh-configured host would otherwise hit an interactive
      # credential prompt on `git clone` from inside the popup.
      gh_field='.clone_url'
      [[ "$(gh config get git_protocol -h github.com 2>/dev/null)" == "ssh" ]] && gh_field='.ssh_url'
      while IFS= read -r row; do
        [[ -n "$row" ]] && candidates+=("$row")
      done < <(gh api 'user/repos?affiliation=owner,collaborator,organization_member&per_page=100' --paginate \
        --jq ".[] | \"\\(${gh_field})\t[GitHub] \\(.full_name)\"" 2>/dev/null)
    fi
    # glab has no built-in --jq (unlike gh), so filtering its JSON needs an
    # external jq — treated as optional exactly like gh: if either glab or
    # jq is missing, this branch is silently skipped, same degrade-to-manual
    # behavior as today.
    if command -v glab >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
      glab_field='.http_url_to_repo'
      [[ "$(glab config get git_protocol 2>/dev/null)" == "ssh" ]] && glab_field='.ssh_url_to_repo'
      while IFS= read -r row; do
        [[ -n "$row" ]] && candidates+=("$row")
      done < <(glab api 'projects?membership=true&per_page=100' --paginate 2>/dev/null \
        | jq -r ".[] | \"\\(${glab_field})\t[GitLab] \\(.path_with_namespace)\"" 2>/dev/null)
    fi
    if (( ${#candidates[@]} > 0 )); then
      repo_row="$(printf '%s\n' "${candidates[@]}" | fzf --delimiter '\t' --with-nth 2 \
        --prompt 'repo> ' --header 'Choose a repo (Esc to paste URL manually)' || true)"
      clone_url="$(printf '%s' "$repo_row" | cut -f1)"
    fi
    if [[ -z "$clone_url" ]]; then
      echo -n "Git clone URL: " >&2
      read -r clone_url
    fi
    [[ -n "$clone_url" ]] || exit 0

    reponame="$(basename "$clone_url" .git)"
    setup_bare "$WORKTREE_ROOT/$reponame" "$clone_url" || { echo "Clone failed." >&2; exit 1; }

    default_branch="$(git --git-dir="$WORKTREE_ROOT/$reponame/.bare" rev-parse --abbrev-ref origin/HEAD 2>/dev/null | sed 's#^origin/##' || echo main)"
    add_worktree "$WORKTREE_ROOT/$reponame" "$default_branch" "$WORKTREE_ROOT/$reponame/$(sanitize "$default_branch")" "origin/$default_branch"
    switch_or_attach "$(session_name_for "$reponame" "$default_branch")" "$WORKTREE_ROOT/$reponame/$(sanitize "$default_branch")"
    ;;
esac