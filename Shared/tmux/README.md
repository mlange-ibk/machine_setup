# tmux worktree workflow — technical documentation

A cross-platform (Linux/WSL + Windows/psmux) tmux setup that makes **one git
worktree = one tmux session**, launched from a single fzf popup.

```
<prefix>w  →  fzf picker (switch / checkout / clone / delete)
```

- [Directory convention](#1-directory-convention)
- [The 5-window session contract](#2-the-5-window-session-contract)
- [The picker: data model, actions, keys](#3-the-picker)
- [Clone flow](#4-clone-flow)
- [Migration: converting old clones](#5-migration-of-existing-clones)
- [Cross-platform mechanics](#6-cross-platform-mechanics)
- [Deployment map](#7-deployment-map)
- [Extension points](#8-extension-points)
- [Known caveats](#9-known-caveats)

---

## 1. Directory convention

```
G:\Repository\Worktrees\          (or ~/Repository/Worktrees on Linux)
  <repo>/
    .bare/                        bare repo — all objects and refs
    .git                          text file:  gitdir: ./<repo>/.bare
    <branch>/                     worktree per branch (sanitized), siblings
    <other-branch>/               worktree #2, ...
```

Every worktree is a **symmetric sibling** of every other — there is no
"special" primary checkout, so any worktree can be removed with
`git worktree remove` without special-casing.

Three rules hold the workspace together:

1. **Worktree folder** = `$WORKTREE_ROOT/<repo>/<sanitized-branch>` — the
   branch name, already nested under the repo's folder. Sanitization maps `/`
   and `.` to `-` (`feature/x` → `feature-x`).
2. **tmux session name** = `<repo>-<sanitized-branch>` (`pojSDG-dev`,
   `Machine_Setups-dev`): the repo name qualifies the branch so two repos on
   the same branch (`master`/`dev`/`main`) never collide. One worktree ⇢ one
   session, 1:1.
3. **`$WORKTREE_ROOT`** is a single environment variable every script reads
   (with a filesystem fallback), so the layout can live anywhere.

Branch/folder names that collide (e.g. `feature/x` and `feature-x`) are
considered the same worktree — a known, accepted limitation of the naming
scheme (see [caveats](#9-known-caveats)).

## 2. The 5-window session contract

Every session created for a worktree boots exactly these five windows:

| # | Window    | Runs            | Purpose                    |
|---|-----------|-----------------|----------------------------|
| 1 | `neovim`  | `nvim .`        | editor                     |
| 2 | `lazygit` | `lazygit`       | git UI                     |
| 3 | `run`     | *(bare shell)*  | dev server / ad hoc cmds   |
| 4 | `lazysql` | `lazysql`       | sql database client        |
| 5 | `opencode`| `opencode`      | ai coding agent            |

The `run` window starts as a plain shell because the dev server command is
project-specific and changes by the minute; the other four are static.

Sessions are **idempotent**: the bootstrap (`tmux-worktree-session.sh`) skips
creation and attach/switch if the session already exists, so it is safe to
call from the picker, from a shell alias, or by hand.

## 3. The picker

`tmux-worktree.sh` (Linux) and `tmux-worktree.ps1` (Windows) are bound to
`<prefix>w` via tmux `display-popup`. The binding lives in the **per-OS
override conf**, not the shared file, because how the picker has to be
invoked differs per platform:

```
# tmux.linux.conf — real tmux expands `~` to a forward-slash path:
bind-key w display-popup -E -w 90% -h 90% "bash ~/.local/scripts/worktree/tmux-worktree.sh"

# tmux.windows.conf — psmux executes popup commands through pwsh, where a
# bare `bash C:/...` resolves to WSL's bash.exe (can't read drive paths) and
# `~`/`$HOME` get pre-mangled. PowerShell-native with a literal forward-slash
# path (machine-specific, like default-shell):
bind-key w display-popup -E -w 90% -h 90% "pwsh -NoProfile -File C:/Users/lasamat/.local/scripts/worktree/tmux-worktree.ps1"
```

### Data model

The script enumerates four kinds of fzf rows, each emitted as a
tab-separated record `type ⇥ repo ⇥ ref ⇥ label`. fzf's `--with-nth 4`
plus `--delimiter '\t'` keeps only the human-readable label visible while
the script still has structured fields to dispatch on.

| `type`      | `repo`        | `ref`               | semantics                                          |
|-------------|---------------|---------------------|----------------------------------------------------|
| `switch`    | repo name     | absolute path       | worktree on disk; live session shown in the label |
| `checkout`  | repo name     | remote branch name  | branch with no worktree yet                        |
| `newbranch` | repo name     | *(empty)*           | synthetic "+ New branch in <repo>" row             |
| `clone`     | *(empty)*     | *(empty)*           | pinned "+ Clone new repository" row                |

Row enumeration per repo:

```
bare repos        ← find $WORKTREE_ROOT -maxdepth 2 -name .bare -type d
worktrees         ← git --git-dir=<repo>/.bare worktree list --porcelain
                   (excludes <repo>/.bare itself)
un-worktree'd origin branches
                  ← git for-each-ref refs/remotes/origin, minus worktrees
                   whose sanitized name already exists on disk
```

### Actions

| Row type | `Enter` (smart)                                  | `s` (switch)         | `c` (checkout/clone)  | `d` (delete)                       |
|----------|--------------------------------------------------|----------------------|-----------------------|------------------------------------|
| `switch` | switch into session (create if missing)          | switch               | *(ignored)*           | delete worktree + its session      |
| `checkout`| create worktree + boot 5-window session          | *(ignored)*          | create worktree + boot| *(ignored)*                        |
| `newbranch`| prompt for branch name → worktree + session     | *(ignored)*          | same as Enter         | *(ignored)*                        |
| `clone`  | gh-picker / URL → bare clone → worktree → session| *(ignored)*          | same as Enter         | *(ignored)*                        |

`Enter`, `s` and `c` resolve to the same `Enter` accept
(`enter:accept,s:accept,c:accept`), so those three keys perform the same
action, determined purely by the row's `type` field. `d` is the exception:
`--expect d` makes fzf report the key that was pressed, and `d` only has
meaning on `switch` rows — it deletes the worktree instead of switching in
(see [Removing a worktree](#removing-a-worktree)).

`switch_or_attach` prefers `tmux switch-client` (we are inside tmux — the
picker runs in a popup) and falls back to `attach-session`.

### Removing a worktree

Pick a `switch` row and press `d` instead of `Enter`. The picker then:

1. Confirms with a `y/N` prompt, printing the worktree path and whether it
   will also close a live tmux session.
2. Runs `git worktree remove` first (no `--force`). If the tree is dirty,
   git's own error is shown and nothing is deleted — clean/commit/stash and
   retry. The `y/N` prompt is the only guard; `git worktree remove` itself
   refuses dirty or in-use trees.
3. Only on success, kills the worktree's tmux session (if any). If that
   session is the one you are running the picker from, the client is first
   moved to the oldest other tmux session, or detached if none remain.

The local branch is deliberately left alone — deleting a merged branch stays
a separate `git`/`lazygit` decision.

## 4. Clone flow

Step 1 is a single fzf picker fed by **both** GitHub (`gh`) and GitLab
(`glab`) REST APIs, whichever are installed/authenticated. Rows from both
providers are merged into one list, tagged `[GitHub]`/`[GitLab]`:

```
gh api   'user/repos?affiliation=owner,collaborator,organization_member&per_page=100' --paginate --jq '.[] | "\(.clone_url)\t[GitHub] \(.full_name)"'
glab api 'projects?membership=true&per_page=100' --paginate | jq -r '.[] | "\(.http_url_to_repo)\t[GitLab] \(.path_with_namespace)"'
```

Each row is tab-delimited as `<clone-url>\t<label>` (mirroring the outer
picker's own row convention) — fzf only displays the label (`--with-nth 2`),
and the already-correct, API-provided clone URL is lifted straight out of
the selection with `cut -f1`. No URL is ever hand-assembled from a hostname
constant, so this works unmodified against self-hosted GitLab instances
(whatever host `glab auth login` configured) and GitHub Enterprise.

The endpoint choices are deliberate:
- `gh`: the plain `gh repo list` only returns repos you *own*, which would
  hide private repos you are invited to and org repos. The
  `affiliation=owner,collaborator,organization_member` trio returns
  everything your account can see.
- `glab`: `membership=true` is GitLab's closest equivalent — projects you're
  a direct member of *or* that belong to a group you're a member of
  (covering the owner/invited/org-member cases GitHub's trio covers).

**Git protocol (ssh vs https)**: the clone URL field is chosen per-provider
to match each CLI's own configured protocol
(`gh config get git_protocol -h github.com` /
`glab config get git_protocol`, both default to `https`) — using `.ssh_url`
/ `.ssh_url_to_repo` when configured for ssh. This avoids a `git clone`
inside the popup hanging on an interactive credential prompt when a host is
ssh-configured but has no cached https credentials.

`glab api` has no built-in `--jq` filter (unlike `gh`, which bundles one), so
the GitLab branch on the **bash/Linux** script pipes through an external
`jq` binary — treated as an *additional optional* dependency exactly like
`gh`/`glab` themselves: if `glab` or `jq` is missing, that branch is simply
skipped. The **PowerShell/Windows** script needs no extra dependency for
either provider — it parses both APIs' JSON natively via `ConvertFrom-Json`.

If neither `gh` nor `glab` produces any rows (missing/unauthenticated), or
the picker is Escaped, the flow degrades to a manual URL paste — unchanged
from before.

The clone creates a bare repo and normalizes it in four steps so the
worktree flow works identically for every branch:

1. The fetch refspec is repointed to a remote-tracking namespace
   (`+refs/heads/*:refs/remotes/origin/*`) and re-fetched — a bare clone only
   fetches the default branch and mirrors it into `refs/heads/*`;
2. `origin/HEAD` is resolved via `remote set-head origin -a`;
3. the mirrored `refs/heads/*` are dropped and the bare HEAD is parked on an
   unborn ref (`refs/heads/worktree-root`), because a bare HEAD pointing at a
   real branch makes git treat that branch as "checked out at `.bare`" and
   refuse `worktree add` on it;
4. the default branch is detected from `origin/HEAD` and immediately given
   its own worktree + session.

New worktrees branch off the tracked remote branch (`origin/<branch>`), and
new branches branch off `origin/HEAD` (the default branch).

## 5. Migration of existing clones

`tmux-worktree-migrate.sh <path>...` converts existing plain clones in place
**without touching them**:

1. Abort if the source repo has uncommitted changes (`status --porcelain`).
2. Re-clone bare **from the source's own `origin` remote** into
   `$WORKTREE_ROOT/<repo>/.bare` (never copies `.git` internals manually).
3. Create a worktree for the branch that was checked out.
4. The old directory is left untouched — cleanup is a manual, post-inspection
   step.

Use it for `Machine_Setups`, `Elixir/event-sourcing/lunar_frontiers_1`, etc.

## 6. Cross-platform mechanics

One config file, two OSes: psmux (the native Windows tmux) reads
`~/.tmux.conf` as a fallback config path, so the same file in `$HOME` is
picked up by both real tmux and psmux.

`tmux.conf` does **no runtime OS detection** — the OS is known at deploy time,
because different linkers run on each machine. The config sources one
indirection file:

```
source-file ~/.tmux.os.conf
```

`~/.tmux.os.conf` is a symlink chosen by the linker on each machine:
`linkconfig.ps1` → `tmux.windows.conf`, `linkconfig.sh` → `tmux.linux.conf`.
This replaces an earlier `%if`/`if-shell` runtime fork, which **psmux silently
does not support** (it swallows a `%if` block without warning, breaking every
binding defined after it). Deploy-time selection is simpler, more debuggable,
and needs no tmux version feature-gating.

- **`tmux.windows.conf`** sets `default-shell`/`default-command` to `pwsh`
  (PowerShell 7 — see below for why this isn't Git Bash) and defines
  `WORKTREE_ROOT` via `set-environment -g`.
- **`tmux.linux.conf`** defines the Unix `WORKTREE_ROOT` and the `xclip`
  clipboard binding (xclip is Linux-only).

> **psmux compatibility notes** (verified against psmux 3.3.6): tmux
> user-variables (`catppuccin_mocha_sapphire=...`) and the `visual-silence`
> option are **not supported** at all. The `bind-key -r` repeat flag *is*
> supported by real tmux but psmux silently drops it (a `-r` binding never
> appears in `list-keys`, no error) — this is why the sessionizer bindings
> (`f`/`i`/`g`/`M`) live in the per-OS conf files rather than the shared one:
> `tmux.linux.conf` keeps `-r`, `tmux.windows.conf` omits it.

> **psmux `new-window`/`split-window` trailing shell-command is unreliable**
> (verified against psmux 3.3.6): both commands accept a trailing
> shell-command argument for "create this window/pane running X" (documented
> in psmux's own `docs/multi-shell.md`), but from this config it does not
> reliably create a distinct window/pane — sometimes it does, sometimes it
> silently types the command into the *current* pane instead, with no error
> either way. `\;` command-chaining on a single `bind-key` line was equally
> unreliable. The combination verified reliable every time: create a *plain*
> window/pane (no trailing command — bare `new-window`/`split-window` is
> solid), capture its pane-id with `-P -F '#{pane_id}'`, then a *separate*
> `send-keys` targeted at that exact pane-id types the real command. See the
> Git Bash on-demand bindings (`B`/`b`) in `tmux.windows.conf` for the
> working pattern. `#{pane_id}` must be written doubled (`##{pane_id}`)
> inside a `bind-key`-bound `run-shell` command specifically: bind-key
> commands go through one round of tmux's own format-expansion at key-press
> time before `run-shell` hands the text to the shell, so the doubled form
> is what survives that pass and reaches the nested `new-window`/
> `split-window -P -F` call as a literal `#{pane_id}` for it to expand
> against the pane it just created.

> **`#{pane_current_command}` is unreliable for a pane launched via the
> pattern above**: it kept reporting `pwsh` (the pane's original/default
> process) even once Git Bash was genuinely running interactively inside it
> (confirmed by `capture-pane` showing a real MINGW64 prompt and executing
> real commands correctly). Don't trust this format variable to check what's
> "really" running in a pane created this way — check the actual pane
> content instead.

> **Why `default-shell` is `pwsh`, not Git Bash** (changed 2026-09-14): the
> original design used Git Bash as the default shell so every pane matched
> the Linux side. That default-shell also governs psmux's warm-pool spares
> (see the `warm off` note below) and every pane a user opens by hand, not
> just the worktree bootstrap. Once WSL2/real Linux became the primary
> coding environment (real tmux, none of psmux's Windows-only gotchas),
> psmux was reframed as being for Windows-native work specifically — and for
> that, PowerShell's own profile (aliases, functions, PSReadLine, tab
> completion) matters more than bash's POSIX toolbelt. This costs no TUI
> compatibility: `nvim`/`lazygit`/`lazysql`/`opencode` all talk to psmux's
> ConPTY directly, so rendering/mouse/raw-mode/`isTTY` behavior is identical
> regardless of which shell spawned them — none of that is shell-dependent.
> Git Bash is still one keypress away (`B`/`b`), and the worktree bootstrap
> picks up whichever shell is configured here automatically, since it only
> ever passes `-c <dir>` and never a shell — this was a config-only change.

`WORKTREE_ROOT` is a tmux global-environment variable (`set-environment -g`),
so every pane, `run-shell` and `display-popup` process inherits it — no
per-shell `export` needed.

> **psmux set-environment quirk**: unlike real tmux, psmux stores the value
> **including the surrounding quote characters** (`set-environment -g
> WORKTREE_ROOT "G:/Repository/Worktrees"` yields a process env of
> `WORKTREE_ROOT="G:/Repository/Worktrees"` with literal `"`). To a POSIX
> consumer this is harmless noise, but PowerShell reads it as a drive literal,
> producing `Cannot find drive. A drive with the name '"G' does not exist.`
> Both pickers therefore trim surrounding quotes before use
> (`root.Trim().Trim('"')` in the ps1, `${root#\"}/${root%\"}` in the lib), so
> the value is safe to quote in the confs and the fix works even on a running
> server that already has the quoted value cached.

On Windows the picker is **PowerShell-native** (`tmux-worktree.ps1`): psmux
executes `display-popup` commands through pwsh, where a bare `bash C:/...`
resolves to WSL's bash.exe (which cannot read Windows drive-letter paths) and
a bash script would need bash under pwsh with fragile quoting. The Linux
picker/bootstrap remain bash; the two pickers share identical logic — the
`.ps1` is a line-for-line port so behaviour stays in parity.

## 7. Deployment map

| Source (repo)                                          | Dest (live machine)        | OS      | Mechanism     |
|--------------------------------------------------------|----------------------------|---------|---------------|
| `Shared/tmux/tmux.conf`                                | `~/.tmux.conf`             | both    | symlink       |
| `Shared/tmux/tmux.windows.conf`                        | `~/.tmux.os.conf`          | Windows | symlink       |
| `Shared/tmux/tmux.linux.conf`                          | `~/.tmux.os.conf`          | Linux   | symlink       |
| `Shared/tmux/scripts/**`                               | `~/.local/scripts/worktree`| both    | symlink (dir) |
| `Windows/config/glazewm/config.yaml`                   | `.glzr/glazewm/config.yaml`| Windows | `linkconfig.ps1` |
| everything above (`.zshrc`, `.config/nvim`, scripts…)  | `$HOME` / `~/.local/scripts`| Linux   | `linkconfig.sh` |

Windows: `pwsh linkconfig.ps1` (self-elevates for symlink creation).
Linux: `./linkconfig.sh` (symlinks need no elevation).

## 8. Extension points

- **Add a 6th window** — edit the two `switch_or_attach` bootstraps
  (`tmux-worktree.sh`, `tmux-worktree-session.sh`); they are intentionally
  kept in sync.
- **Move `$WORKTREE_ROOT`** — it is *not* hardcoded: each OS override conf
  defines its own value via `set-environment -g WORKTREE_ROOT`
  (`tmux.windows.conf` → `G:/Repository/Worktrees`, `tmux.linux.conf` →
  `$HOME/Repository/Worktrees`). Change it there whenever the folder layouts
  diverge; the scripts fall back to their own default only if the env var is
  unset.
- **Change sanitization** — edit `sanitize()` in `lib/worktree-lib.sh`.
- **Add a new row type** — emit a new tag in the list builder, add a case in
  the dispatcher.

## 9. Known caveats

- **Name collisions**: session names are repo-qualified (`<repo>-<branch>`),
  so two repos on the same branch (`master`/`dev`/`main`) cannot collide. The
  surviving conflict is intra-repo: branches that sanitize to the same string
  (e.g. `feature/x` and `feature-x`) still resolve to the same worktree
  folder.
- **Pre-qualified sessions**: sessions created by earlier versions of this
  workflow are named after the branch alone (`dev`, `main`, `test`). The
  picker now looks for repo-qualified names and will recreate them under the
  new scheme; retire the old ones by hand (`tmux kill-session -t dev`).
- **`source-file ~/.tmux.os.conf` resolves at server start** — the symlink is
  read once when tmux/psmux boots. Re-run the linker after changing which OS
  conf should win; edits to the *contents* just need `tmux source-file
  ~/.tmux.conf`.
- **`display-popup -E`** closes the popup when the command ends — on psmux
  the second `fzf` (the gh clone picker) runs inside the first popup.
  Seamless in practice, but the popup won't "persist".
- **`Worktree no longer exists`**: `git worktree prune` in an on-disk worktree
  that was removed externally leaves stale rows; the picker guards the
  `switch` path against missing dirs.
- **LazyGit/LazySQL/opencode are assumed installed** — the bootstrappers
  `send-keys` their commands without checking availability.
- **Migration is conservative by design** — dirty trees abort so nothing is
  ever lost or auto-committed.
- **psmux's warm pool blocks worktree deletion on Windows** (fixed by `set
  -option -g warm off` in `tmux.windows.conf`, but the mechanism is worth
  understanding if it resurfaces): psmux pre-spawns idle standby shells (the
  "warm pool") so `new-session`/`new-window`/`split-window` feel instant. Its
  Windows `default-shell` is Git Bash, so each spare is a real `bash.exe`
  holding whatever directory it was created in as its Windows
  current-directory — an open handle. The 5-window bootstrap is exactly the
  kind of rapid-fire `new-window` burst that makes psmux over-provision this
  pool (its own docs call this "surge"), and those spares are internal server
  bookkeeping, invisible to `list-sessions`/`list-panes`, so `kill-session` on
  the session that used them never reaches them — they keep running, still
  holding the worktree folder open, indefinitely (an unclaimed spare "may sit
  around for days" per psmux's own docs). `git worktree remove` then fails
  with `Permission denied`, and can even partially succeed (dropping git's own
  `.bare/worktrees/<name>` tracking entry while leaving the physical folder
  behind, orphaned from `git worktree list`). Verified empirically (psmux
  3.3.6): a **runtime** `set -g warm off`/`on` around the bootstrap does
  **not** prevent this — the pool already exists by the time the option is
  set. Only disabling warm at server **boot** (a config-file line, sourced
  once when the server starts) works. `warm-pool-size 0` would be the more
  surgical fix (`warm off` also disables the `__warm__` standby that makes
  brand-new session creation fast, not just the per-session window pool) but
  is not implemented in 3.3.6 — it logs `unknown option 'warm-pool-size'` and
  is silently a no-op. Revisit if/when the installed psmux version implements
  it (3.3.8 was available over winget at time of writing, vs. the 3.3.6
  tested here — unverified whether it changes this).
- **The picker did nothing on Enter/`s`/`c`/`d`, on both platforms, for
  every selection** (found and fixed 2026-09-15): `fzf --expect` makes fzf
  print **two lines** whenever it's set, regardless of which key completed
  the selection — line 1 is the expect-key indicator (empty string for a
  plain Enter/`s`/`c` accept, `d` when `d` completed it), line 2 is the
  actual selected row. Verified empirically against the installed fzf build.
  Both `tmux-worktree.ps1` (`Select-Object -First 1` on the raw output) and
  `tmux-worktree.sh` (`head -n1` before splitting into key/choice) only ever
  read line 1, so `$type`/`$TYPE` was **always empty** and matched no
  dispatch case — every selection, on every key, silently did nothing, with
  no error. This bug pre-dates every other change in this file; it was
  never noticed because no earlier testing session actually drove the real
  interactive fzf dispatch end-to-end (functions and tmux primitives were
  tested directly instead). Fixed by reading line 1 as the key and line 2 as
  the row explicitly in both scripts.
- **`tmux-worktree.sh`'s picker list was never actually reaching fzf**
  (found and fixed alongside the bug above, Linux-only, pre-dates every
  other change in this file): `$LIST_TMP` was created via `mktemp` and later
  `cat`, but every row-building `printf` in between wrote straight to the
  script's own stdout — nothing ever redirected that output into
  `$LIST_TMP`. `cat "$LIST_TMP" | fzf ...` therefore always fed fzf an empty
  list, so fzf had nothing to select from and `$RAW` was always empty,
  before the fix above even had a chance to matter. The picker has likely
  never shown a real row on Linux. Fixed by wrapping the whole row-building
  block in `{ ...; } > "$LIST_TMP"`. (`tmux-worktree.ps1` never had this bug
  — it accumulates rows into an in-memory list and writes them with
  `Set-Content` in one shot.)
- **`.bare` can leak into the picker as a fake worktree row**: `git worktree
  list --porcelain` always includes the bare repo's own entry first, and
  both scripts filter it out by comparing paths as plain strings against
  `$BareDir`. On Windows, `tmux-worktree.ps1`'s `$BareDir` comes from .NET's
  `FullName` (backslashes: `C:\...\repo\.bare`) while git's own output is
  always forward-slash (`C:/.../repo/.bare`) — the two never string-match,
  so `.bare` always leaked through as a selectable `[repo] bare` row that
  booted a nonsense session if picked. Fixed by normalizing both sides to
  forward slashes before comparing. Verified this specific mismatch cannot
  occur in `tmux-worktree.sh` on real Linux (both sides are the same plain
  POSIX path there, no drive-letter/backslash duality is possible) — but it
  *can* resurface if that script is ever run under Git Bash/MSYS2 on
  Windows, where `git.exe` reports native Windows paths while bash's own
  `find`/`pwd` report MSYS2 POSIX paths (`/c/...`) for the same location.
  Not fixed there since the real Windows picker is `tmux-worktree.ps1`, not
  this script, and the MSYS2 case doesn't occur on the actual Linux
  deployment target.