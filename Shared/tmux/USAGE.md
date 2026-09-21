# tmux worktree workflow — the short version

One session per git worktree. One keybind to get anywhere.

```
<prefix>w   (prefix is C-a)
```

## What you see

An fzf popup listing every worktree and branch. Filter with typing, pick with
`Enter`.

```
worktree>
  1/2 → machine-setups                      (live session)
  [repo] some-branch          (new worktree)
  [repo] feature/x            (new worktree)
  [repo] + New branch
  + Clone new repository
```

`Enter` always does the sensible thing:

| You pick…                       | …it does                                  |
|---------------------------------|-------------------------------------------|
| a worktree (live or not)        | open its 5-window session                 |
| a branch with no worktree       | create worktree + open session            |
| "+ New branch"                  | ask for a name, worktree + open session   |
| "+ Clone new repository"        | pick from your GitHub/GitLab (or paste URL), clone + open session |

Keys: `s` = switch only, `c` = checkout/clone.

## The 5 windows of every session

| #  | window     | runs       |
|----|------------|------------|
| 1  | `neovim`   | nvim       |
| 2  | `lazygit`  | lazygit    |
| 3  | `run`      | plain shell — start your dev server |
| 4  | `lazysql`  | lazysql    |
| 5  | `opencode` | opencode   |

## Common tasks

**Start working on a repo you already have**
`<prefix>w` → pick the worktree → `Enter`.

**Create a new branch in a repo you have**
`<prefix>w` → pick `+ New branch` in that repo → type the name → `Enter`.

**Checkout someone else's existing branch**
`<prefix>w` → pick the branch under `(new worktree)` → `Enter`.

**Clone a new repo**
`<prefix>w` → pick `+ Clone new repository` → choose from the fzf list (your
own + invited + org repos, from both GitHub and GitLab if both are set up).
Neither `gh` nor `glab`? Paste `https://…git` manually.

## Folders

Everything lives under `G:\Repository\Worktrees` (Linux: `~/Repository/Worktrees`):

```
Worktrees/<repo>/            ← bare repo lives here (.bare + .git pointer)
Worktrees/<repo>/<repo>-<branch>   ← one folder per worktree
```

## Migrate an old-style clone

```bash
tmux-worktree-migrate.sh /path/to/old/clone
```

Refuses if the tree is dirty. The old folder is left alone — delete it when
you've confirmed the worktree looks right.

## Something broken?

Dependencies needed: `fzf`, `git`, `neovim`, `lazygit`, `lazysql`, `opencode`,
`gh` (optional, for GitHub in the clone picker), `glab` (optional, for
GitLab in the clone picker — on Linux also needs `jq`; Windows needs
nothing extra). See `README.md` for the technical details on the picker,
config fork, and the migration algorithm.