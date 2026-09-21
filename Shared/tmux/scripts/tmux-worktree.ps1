#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Windows/psmux worktree picker (<prefix>w). PowerShell port of
    tmux-worktree.sh (which stays authoritative for Linux).

.DESCRIPTION
    Opens an fzf popup listing:
      - worktrees with a live tmux session        -> Enter switches in
      - worktrees on disk, no session yet         -> Enter boots the 5-window layout
      - branches with no worktree yet             -> Enter checks out into a new worktree
      - "+ New branch in <repo>"                  -> Enter prompts for a branch name
      - "+ Clone new repository"                  -> Enter clones via gh (or URL paste)

    Keys: Enter = smart default   s = switch only   c = checkout/clone only   d = delete worktree.
    Rows are tab-separated:  type <TAB> repo <TAB> ref <TAB> label

    Why PowerShell and not bash: psmux executes display-popup commands through
    PowerShell, where a bare `bash` resolves to WSL's bash.exe (cannot read
    C:/... paths). Invoking pwsh directly keeps the picker inside PowerShell.
#>

$ErrorActionPreference = 'Stop'

# Under psmux, popup processes do NOT get TMUX/TMUX_PANE, but they DO inherit
# PSMUX_SESSION holding the host session name. Capture it BEFORE removing the
# var below, so Remove-Worktree can tell when it is about to kill the very
# session it runs in (and move the client somewhere safe first). On real tmux
# (TMUX set) fall back to display-message.
$script:HostSession = $env:PSMUX_SESSION
if (-not $script:HostSession) {
    $script:HostSession = (& tmux display-message -p -F '#{session_name}' 2>$null | Out-String).Trim()
}

# psmux inherits PSMUX_SESSION/TMUX from the parent session into this popup's
# process, and treats any `tmux new-session` run in that context as a nested
# session attempt -- it warns ("sessions should be nested with care, unset
# PSMUX_SESSION to force") and silently refuses to create it (new-session
# still reports exit 0, but the session never actually persists). Unset both
# before any tmux session-management call so springboard sessions actually
# get created. Real tmux does not have this restriction for -d (detached)
# session creation, so the Linux picker does not need this.
Remove-Item Env:\PSMUX_SESSION -ErrorAction SilentlyContinue
Remove-Item Env:\TMUX -ErrorAction SilentlyContinue

# ── shared helpers (mirrors lib/worktree-lib.sh) ───────────────────────────

function Resolve-WorktreeRoot {
    $root = $env:WORKTREE_ROOT
    if (-not $root) { $root = 'C:/Entwicklung/Worktrees' }
    # psmux's set-environment stores the raw string including surrounding
    # quotes ("G:/..."), unlike real tmux which strips them as syntax.
    $root = $root.Trim().Trim('"').Trim("'").Trim()
    # tmux set-environment stores a literal $HOME token for Linux confs
    # ($HOME/Repository/Worktrees); expand it here when present.
    if ($root.Contains('$HOME')) { $root = $root.Replace('$HOME', $HOME) }
    if ($root -like '~*') { $root = $HOME + $root.Substring(1) }
    return $root
}

function ConvertTo-Sanitized {
    param([string]$Name)
    return ($Name -replace '[/\.]', '-' -replace ' ', '_' -replace '^-', '' -replace '-$', '')
}

function ConvertTo-SessionName {
    <#
    Mirrors session_name_for in lib/worktree-lib.sh. The repo name qualifies
    the session so two repos on the same branch (master/dev/main) do not
    clash:  pojSDG dev -> pojSDG-dev.
    #>
    param([string]$Repo, [string]$Branch)
    return "$(ConvertTo-Sanitized $Repo)-$(ConvertTo-Sanitized $Branch)"
}

function Test-TmuxSession {
    param([string]$Name)
    & tmux has-session -t $Name 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Get-BareRepos {
    param([string]$Root)
    if (-not (Test-Path -LiteralPath $Root)) { return }
    Get-ChildItem -Path $Root -Recurse -Depth 1 -Directory -Filter '.bare' -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Parent.FullName }
}

function Get-WorktreePaths {
    param([string]$BareDir)
    # git's own `worktree list` output always uses forward slashes, but
    # $BareDir comes from .NET's FullName (backslashes) — a literal string
    # comparison between them never matches, so without normalizing, the
    # bare repo's own entry (which `git worktree list` always includes first)
    # leaks through as a fake worktree row instead of being excluded.
    # Verified empirically (2026-09-14): produced a bogus "[repo] bare"
    # switch row that booted a nonsense session when selected.
    $bareNormalized = $BareDir.Replace('\', '/')
    & git --git-dir $BareDir worktree list --porcelain 2>$null |
        Where-Object { $_ -like 'worktree *' } |
        ForEach-Object { $_.Substring('worktree '.Length).Trim() } |
        Where-Object { $_.Replace('\', '/') -ne $bareNormalized }
}

function Get-RemoteBranches {
    param([string]$BareDir)
    & git --git-dir $BareDir for-each-ref --format='%(refname:short)' refs/remotes/origin 2>$null |
        ForEach-Object { $_.Replace('origin/', '') }
}

function Send-KeySpringboard {
    <#
    Mirrors the bash switch_or_attach: create-or-switch into a 5-window
    tmux session for a worktree folder.
    #>
    param([string]$Session, [string]$Dir)

    if (-not (Test-TmuxSession $Session)) {
        & tmux new-session -d -s $Session -c $Dir -n 'neovim' | Out-Null
        & tmux send-keys -t "${Session}:neovim" 'nvim .' Enter | Out-Null
        & tmux new-window -t $Session -c $Dir -n 'lazygit' | Out-Null
        & tmux send-keys -t "${Session}:lazygit" 'lazygit' Enter | Out-Null
        & tmux new-window -t $Session -c $Dir -n 'run' | Out-Null
        & tmux new-window -t $Session -c $Dir -n 'lazysql' | Out-Null
        & tmux send-keys -t "${Session}:lazysql" 'lazysql' Enter | Out-Null
        & tmux new-window -t $Session -c $Dir -n 'opencode' | Out-Null
        & tmux send-keys -t "${Session}:opencode" 'opencode' Enter | Out-Null
        & tmux select-window -t "${Session}:neovim" | Out-Null
    }
    & tmux switch-client -t $Session 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { & tmux attach-session -t $Session }
}

function Remove-Worktree {
    param([string]$RepoDir, [string]$Worktree, [string]$Session)

    Write-Host "Delete worktree: $Worktree"
    $sessLive = ($Session -and (Test-TmuxSession $Session))
    if ($sessLive) {
        Write-Host "  (will also close tmux session '$Session')"
    }
    $confirm = Read-Host 'Delete? [y/N]'
    if ($confirm -notin @('y', 'Y')) {
        Write-Host 'Aborted.'
        return
    }

    # A live tmux session's panes hold the worktree folder as their cwd, and on
    # Windows that pins the folder so `git worktree remove` cannot delete it
    # ("Permission denied"). Close the session BEFORE removal (moving the host
    # client away first when this IS the session we run in). git still protects
    # the data: it refuses an unclean tree, so a failure here leaves the
    # worktree + changes intact and can simply be retried.
    if ($sessLive) {
        if ($script:HostSession -eq $Session) {
            $target = & tmux list-sessions -F '#{session_id} #{session_name}' 2>$null |
                ForEach-Object {
                    $parts = $_ -split ' ', 2
                    $id = [int]($parts[0].TrimStart('$'))
                    if ($parts[1] -ne $Session) { [pscustomobject]@{ Id = $id; Name = $parts[1] } }
                } |
                Sort-Object Id |
                Select-Object -First 1
            if ($target) {
                & tmux switch-client -t $target.Name 2>$null | Out-Null
                Write-Host "Moved client to session '$($target.Name)'."
            }
            else {
                & tmux detach-client 2>$null | Out-Null
                Write-Host 'Detached (no other session to move to).'
            }
        }
        & tmux kill-session -t $Session 2>$null | Out-Null
    }

    # Removal is attempted immediately below, in this same invocation — the
    # messages above only report the client/session move, not a deferred step.
    Push-Location $RepoDir
    try {
        & git --git-dir "$RepoDir\.bare" worktree remove $Worktree 2>&1 | ForEach-Object { Write-Host $_ }
        $gitExit = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }
    if ($gitExit -ne 0) {
        Write-Host 'Cannot remove worktree. Clean or commit its changes and retry (prefix+w, pick it, press d again).'
        return
    }
    Write-Host "Removed: $Worktree"
}

function Add-GitWorktree {
    param([string]$Repo, [string]$Branch, [string]$Target, [string]$StartPoint)
    if ($StartPoint) {
        & git --git-dir "$Repo/.bare" worktree add -b $Branch $Target $StartPoint 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { & git --git-dir "$Repo/.bare" worktree add $Target $Branch 2>$null | Out-Null }
    }
    else {
        & git --git-dir "$Repo/.bare" worktree add -b $Branch $Target 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { & git --git-dir "$Repo/.bare" worktree add $Target $Branch 2>$null | Out-Null }
    }
}

function Initialize-BareRepo {
    param([string]$Repo, [string]$Url)
    New-Item -ItemType Directory -Path $Repo -Force | Out-Null
    & git clone --bare $Url "$Repo/.bare" 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "git clone --bare failed for $Url" }
    & git --git-dir "$Repo/.bare" config --bool core.bare false
    Set-Content -Path "$Repo/.git" -Value "gitdir: $Repo/.bare" -NoNewline -Encoding ascii
    & git --git-dir "$Repo/.bare" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
    & git --git-dir "$Repo/.bare" fetch origin --prune 2>$null | Out-Null
    & git --git-dir "$Repo/.bare" remote set-head origin -a 2>$null | Out-Null
    $refs = & git --git-dir "$Repo/.bare" for-each-ref --format='%(refname)' refs/heads 2>$null
    foreach ($ref in $refs) { & git --git-dir "$Repo/.bare" update-ref -d $ref }
    & git --git-dir "$Repo/.bare" symbolic-ref HEAD refs/heads/worktree-root | Out-Null
    & git --git-dir "$Repo/.bare" remote set-url --push origin $Url 2>$null | Out-Null
}

# ── resolve root (create if missing, mirroring mkdir -p + pwd) ─────────────

try {
$Root = Resolve-WorktreeRoot
New-Item -ItemType Directory -Path $Root -Force | Out-Null
$Root = (Get-Item -LiteralPath $Root).FullName

# display-popup inherits the cwd of the pane that triggered it. If that pane's
# cwd is inside the very worktree you go on to delete, this script's own
# process keeps that folder open (Windows current-directory handle) for as
# long as it stays there — enough to block `git worktree remove` even after
# the target session is killed. Move to a folder that can never itself be a
# delete target before doing anything else. (Remove-Worktree additionally
# Push-Location's to the repo dir right before its own git call, so this is
# belt-and-suspenders for every other code path too.)
Set-Location -LiteralPath $Root

# ── build the fzf list ─────────────────────────────────────────────────────

$rows = [System.Collections.Generic.List[string]]::new()

foreach ($repo in @(Get-BareRepos $Root)) {
    $repoName = Split-Path -Leaf $repo

    foreach ($wt in @(Get-WorktreePaths "$repo\.bare")) {
        $branch = Split-Path -Leaf $wt
        $status = if (Test-TmuxSession (ConvertTo-SessionName $repoName $branch)) { '  (live session)' } else { '' }
        $rows.Add("switch`t$repoName`t$wt`t[$repoName] $branch$status")
    }

    foreach ($branch in @(Get-RemoteBranches "$repo\.bare")) {
        $sanitized = ConvertTo-Sanitized $branch
        if (Test-Path -LiteralPath (Join-Path $repo $sanitized)) { continue }
        $rows.Add("checkout`t$repoName`t$branch`t[$repoName] $branch  (new worktree)")
    }

    $rows.Add("newbranch`t$repoName`t`t[$repoName] + New branch")
}

$rows.Add('clone' + "`t" + '' + "`t" + '' + "`t+ Clone new repository")

$listFile = New-TemporaryFile
try {
    Set-Content -Path $listFile -Value $rows -Encoding utf8

    $fzfArgs = @(
        '--with-nth', '4',
        '--delimiter', "`t",
        '--prompt', 'worktree> ',
        '--header', 'Enter: go · s: switch · c: checkout/clone · d: delete worktree',
        '--bind', 'enter:accept,s:accept,c:accept',
        '--expect', 'd'
    )
    $raw = Get-Content $listFile | & fzf @fzfArgs 2>$null
}
finally {
    Remove-Item -LiteralPath $listFile -Force -ErrorAction SilentlyContinue
}

if (-not $raw) { exit 0 }
# fzf's `--expect` makes it print TWO lines whenever it's set, regardless of
# which key completed the selection: line 1 is the expect-key indicator
# (empty string for a plain Enter/s/c accept, "d" when d completed it), line
# 2 is the actual selected row. Verified empirically against the installed
# fzf build (2026-09-14): `$raw[0]` is genuinely just the key, never the row
# — a previous version of this script read `$raw[0]` as if it already
# contained the tab-separated row, which silently produced an always-empty
# `$type` (matching no switch case) so every selection, on every key, was a
# no-op with no error. `@()` guards the well-known PowerShell single-item
# array unwrapping (a lone line from an external command is not wrapped in
# an array), which would otherwise make `$raw[1]` fail when there's only one
# line of output.
$raw = @($raw)
if ($raw.Count -lt 2) { exit 0 }
$key = $raw[0]
$choice = $raw[1]
$fields = $choice -split "`t"
$type = $fields[0]
$repo = $fields[1]
$ref = $fields[2]

switch ($type) {
    'switch' {
        if (-not (Test-Path -LiteralPath $ref)) {
            Write-Error "Worktree no longer exists: $ref"
            break
        }
        $sessionName = ConvertTo-SessionName $repo (Split-Path -Leaf $ref)
        if ($key -eq 'd') {
            Remove-Worktree (Join-Path $Root $repo) $ref $sessionName
        }
        else {
            Send-KeySpringboard $sessionName $ref
        }
    }
    'checkout' {
        $target = Join-Path $Root "$repo\$(ConvertTo-Sanitized $ref)"
        Add-GitWorktree (Join-Path $Root $repo) $ref $target "origin/$ref"
        Send-KeySpringboard (ConvertTo-SessionName $repo $ref) $target
    }
    'newbranch' {
        $name = Read-Host "New branch name (in $repo)"
        if (-not $name) { exit 0 }
        $target = Join-Path $Root "$repo\$(ConvertTo-Sanitized $name)"
        Add-GitWorktree (Join-Path $Root $repo) $name $target 'origin/HEAD'
        Send-KeySpringboard (ConvertTo-SessionName $repo $name) $target
    }
    'clone' {
        $cloneUrl = ''
        # Merge GitHub (gh) and GitLab (glab) repos into a single fzf list, each
        # row tab-delimited as "<clone-url>`t[Provider] <path>" so the
        # already-correct API-provided URL can be lifted straight out of the
        # selection with no manual URL construction (and no
        # github.com/gitlab.com hardcoding — glab's URL reflects whatever host
        # `glab auth login` configured, so this also works against
        # self-hosted GitLab instances). Both branches parse JSON natively via
        # ConvertFrom-Json, so no extra dependency (jq) is needed on Windows,
        # unlike the bash port.
        $candidates = [System.Collections.Generic.List[string]]::new()
        if (Get-Command gh -ErrorAction SilentlyContinue) {
            # Respect the user's configured git protocol (`gh config get
            # git_protocol`, per-host, defaults to https) rather than
            # hardcoding https — an ssh-configured host would otherwise hit
            # an interactive credential prompt on `git clone` from inside
            # the popup.
            $ghProtocol = (& gh config get git_protocol -h github.com 2>$null | Out-String).Trim()
            $ghJson = & gh api 'user/repos?affiliation=owner,collaborator,organization_member&per_page=100' --paginate 2>$null
            if ($ghJson) {
                try {
                    @($ghJson | ConvertFrom-Json) | ForEach-Object {
                        $url = if ($ghProtocol -eq 'ssh') { $_.ssh_url } else { $_.clone_url }
                        $candidates.Add("$url`t[GitHub] $($_.full_name)")
                    }
                }
                catch { }
            }
        }
        if (Get-Command glab -ErrorAction SilentlyContinue) {
            $glabProtocol = (& glab config get git_protocol 2>$null | Out-String).Trim()
            $glabJson = & glab api 'projects?membership=true&per_page=100' --paginate 2>$null
            if ($glabJson) {
                try {
                    @($glabJson | ConvertFrom-Json) | ForEach-Object {
                        $url = if ($glabProtocol -eq 'ssh') { $_.ssh_url_to_repo } else { $_.http_url_to_repo }
                        $candidates.Add("$url`t[GitLab] $($_.path_with_namespace)")
                    }
                }
                catch { }
            }
        }
        if ($candidates.Count -gt 0) {
            $repoChoice = $candidates | & fzf --delimiter "`t" --with-nth 2 --prompt 'repo> ' --header 'Choose a repo (Esc to paste URL manually)' 2>$null
            $repoChoice = @($repoChoice) | Select-Object -First 1
            if ($repoChoice) { $cloneUrl = ($repoChoice -split "`t")[0] }
        }
        if (-not $cloneUrl) { $cloneUrl = Read-Host 'Git clone URL' }
        if (-not $cloneUrl) { exit 0 }

        $repoName = (Split-Path -Leaf $cloneUrl).Replace('.git', '')
        $targetRepo = Join-Path $Root $repoName
        Initialize-BareRepo $targetRepo $cloneUrl

        $default = & git --git-dir "$targetRepo\.bare" rev-parse --abbrev-ref origin/HEAD 2>$null
        if (-not $default) { $default = 'main' }
        $default = $default.Replace('origin/', '')
        $target = Join-Path $Root "$repoName\$(ConvertTo-Sanitized $default)"
        Add-GitWorktree $targetRepo $default $target "origin/$default"
        Send-KeySpringboard (ConvertTo-SessionName $repoName $default) $target
    }
}
} catch {
    $log = Join-Path $env:TEMP 'tmux-worktree-error.log'
    $context = ('PWD=' + $PWD.Path + ' | HOME=' + $HOME + ' | WORKTREE_ROOT=' + $env:WORKTREE_ROOT +
                ' | G-drive-exists=' + [System.IO.Directory]::Exists('G:\'))
    $entry = ('[{0}] {1}{2}context: {3}' -f (Get-Date -Format o), $_.Exception.ToString(), [Environment]::NewLine, $context)
    try { [System.IO.File]::AppendAllText($log, $entry + [Environment]::NewLine) } catch { }
    Write-Error $_ -ErrorAction Continue
    if (-not [Console]::IsOutputRedirected) {
        Read-Host "Error logged. Press Enter to close (see $log)"
    }
    exit 1
}
