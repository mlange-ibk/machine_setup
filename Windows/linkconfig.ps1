#!/usr/bin/env pwsh
# Links repo config files to their user-home destinations as symlinks,
# then asks GlazeWM to reload its config.
# Usage: pwsh -ExecutionPolicy Bypass -File linkconfig.ps1

$ErrorActionPreference = 'Stop'

# Re-launch elevated if not already (required to create symlinks).
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Requesting administrator privileges..." -ForegroundColor Yellow
    Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`""
    ) | Out-Null
    exit
}

# Each entry: source relative to $PSScriptRoot, destination relative to $HOME.
$mappings = @(
    @{ source = 'config/glazewm/config.yaml'; destination = '.glzr/glazewm/config.yaml' }
    @{ source = '../Shared/tmux/tmux.conf'; destination = '.tmux.conf' }
    @{ source = '../Shared/tmux/tmux.windows.conf'; destination = '.tmux.os.conf' }
    @{ source = '../Shared/tmux/scripts'; destination = '.local/scripts/worktree' }
    @{ source = 'config/herdr/config.toml'; destination = 'AppData/Roaming/herdr/config.toml' }
)

$srcRoot = $PSScriptRoot
$homeRoot = $HOME

foreach ($mapping in $mappings) {
    $source = Join-Path $srcRoot $mapping.source
    $destination = Join-Path $homeRoot $mapping.destination

    if (-not (Test-Path -LiteralPath $source)) {
        Write-Host "Source '$source' does not exist, skipping..." -ForegroundColor Yellow
        continue
    }

    $destExists = Test-Path -LiteralPath $destination
    $isLink = $false
    $targetMatch = $false

    if ($destExists) {
        $item = Get-Item -LiteralPath $destination -Force
        $isLink = $item.LinkType -eq 'SymbolicLink'
        if ($isLink -and $item.Target -eq $source) {
            $targetMatch = $true
        }
    }

    if ($targetMatch) {
        Write-Host "Already linked: $destination -> $source" -ForegroundColor Green
        continue
    }

    if ($destExists) {
        if ($isLink) {
            Write-Host "Replacing existing symlink: $destination" -ForegroundColor Yellow
            Remove-Item -LiteralPath $destination -Force
        } else {
            $backup = "$destination.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
            Write-Host "Backing up existing file: $destination -> $backup" -ForegroundColor Yellow
            Move-Item -LiteralPath $destination -Destination $backup
        }
    }

    $destParent = Split-Path -Parent $destination
    if (-not (Test-Path -LiteralPath $destParent)) {
        New-Item -ItemType Directory -Path $destParent -Force | Out-Null
        Write-Host "Created destination directory: $destParent" -ForegroundColor Cyan
    }

    New-Item -ItemType SymbolicLink -Path $destination -Target $source | Out-Null
    Write-Host "Linked: $destination -> $source" -ForegroundColor Green
}

# Ask GlazeWM to reload its config so edits take effect immediately.
Write-Host "Reloading GlazeWM config..." -ForegroundColor Cyan
glazewm command wm-reload-config

Write-Host "Done." -ForegroundColor Green