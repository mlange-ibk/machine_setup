# Drop-in source definition: Microsoft Outlook (classic, Win32/Click-to-Run).
# Outlook's keyboard shortcuts are fixed by the application and not stored in
# any user-editable config file, so this source ships a bundled, curated CSV
# of the classic Outlook shortcut set instead of parsing a live config path.
#
# Contract (returned hashtable): see sources/glazewm.ps1 header.
# Bundled data: sources/outlook/keybindings.csv with columns
#   Mode, Keys, Action, Description

function ConvertFrom-OutlookKeybindings {
  param(
    [Parameter(Mandatory)]
    [string]$Path
  )

  Import-Csv -LiteralPath $Path | ForEach-Object {
    [pscustomobject]@{
      Mode        = $_.Mode
      Keys        = $_.Keys
      Action      = $_.Action
      Description = $_.Description
    }
  }
}

function Get-OutlookSource {
  @{
    Name  = 'Outlook'
    Color = '#0078D4'
    Paths = @(
      (Join-Path $PSScriptRoot 'outlook/keybindings.csv')
    )
    Parse = {
      param([string]$FilePath)
      ConvertFrom-OutlookKeybindings -Path $FilePath
    }
  }
}

Get-OutlookSource
