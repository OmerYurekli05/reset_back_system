<#
.SYNOPSIS
    reset_back_system - selectable backup before a Windows reset, and restore after it.

.DESCRIPTION
    Without parameters the graphical interface opens (and asks for admin rights).
    With -Backup / -Restore / -List it works from the command line.

.EXAMPLE
    .\ResetBack.ps1
    .\ResetBack.ps1 -List
    .\ResetBack.ps1 -Backup -Target D:\ -Items 'programs.*','editors.*','system.wifi'
    .\ResetBack.ps1 -Backup -Target D:\ -All -DryRun
    .\ResetBack.ps1 -Restore -Source D:\ResetBack-2026-11-14_1530
    .\ResetBack.ps1 -Restore -Source D:\ -List
#>
[CmdletBinding()]
param(
    [switch]$Backup,
    [switch]$Restore,
    [switch]$List,
    [string]$Target,
    [string]$Source,
    [string[]]$Items,
    [string]$ProfilePath,
    [switch]$All,
    [switch]$DryRun,
    [switch]$NoOverwrite,
    [switch]$Force,
    [ValidateSet('tr', 'en')][string]$Lang,
    [switch]$NoElevate,
    [switch]$Version
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

# ------------------------------------------------------------------ load code
# A built single-file version defines RB_CODE / RB_EMBED before this point.
if (-not $Global:RB_CODE) {
    $root = $PSScriptRoot
    $Global:RB_ROOT = $root
    $parts = @('src\Core.ps1', 'src\Engine.ps1')
    $parts += @(Get-ChildItem -LiteralPath (Join-Path $root 'src\Providers') -Filter '*.ps1' | Sort-Object Name | ForEach-Object { 'src\Providers\' + $_.Name })
    if (Test-Path -LiteralPath (Join-Path $root 'src\Gui.ps1')) { $parts += 'src\Gui.ps1' }
    $Global:RB_CODE = ($parts | ForEach-Object { [IO.File]::ReadAllText((Join-Path $root $_), [Text.Encoding]::UTF8) }) -join "`r`n"
}
. ([scriptblock]::Create($Global:RB_CODE))

if ($Lang) { Set-RBLanguage $Lang } else { Set-RBLanguage (Get-RBDefaultLanguage) }
$Global:RB.DryRun = [bool]$DryRun
$Global:RB.Options = @{ Overwrite = (-not $NoOverwrite); Force = [bool]$Force }

if ($Version) { Write-Output "reset_back_system $($Global:RB.Version)"; return }

function Write-RBItemTable {
    param([object[]]$List)
    foreach ($cat in $Global:RBCategories) {
        $group = @($List | Where-Object { $_.Category -eq $cat })
        if (-not $group.Count) { continue }
        Write-Host ''
        Write-Host ('== ' + (T "cat.$cat") + ' ==') -ForegroundColor Cyan
        foreach ($it in $group) {
            $flags = ''
            if ($it.Selected) { $flags += '*' } else { $flags += ' ' }
            if ($it.Sensitive) { $flags += 'S' } else { $flags += ' ' }
            if ($it.RequiresAdmin) { $flags += 'A' } else { $flags += ' ' }
            if (-not $it.RestoreSupported) { $flags += 'B' } else { $flags += ' ' }
            Write-Host ('  [{0}] {1,-24} {2,9}  {3}' -f $flags, $it.Id, (Format-RBSize $it.Size), $it.Name) -ForegroundColor White
            if ($it.Description) { Write-Host ('         ' + $it.Description) -ForegroundColor DarkGray }
        }
    }
    Write-Host ''
    Write-Host (T 'cli.flags')
}

# ------------------------------------------------------------------ GUI mode
if (-not ($Backup -or $Restore -or $List)) {
    if (-not (Get-Command Show-RBGui -ErrorAction SilentlyContinue)) {
        Get-Help $PSCommandPath -Detailed
        return
    }
    if (-not (Test-RBAdmin) -and -not $NoElevate) {
        try {
            if ($PSCommandPath) {
                $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"{0}"' -f $PSCommandPath))
                if ($Lang) { $a += @('-Lang', $Lang) }
                Start-Process -FilePath ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) -ArgumentList $a -Verb RunAs | Out-Null
            } else {
                Start-Process -FilePath ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) -Verb RunAs | Out-Null
            }
            return
        } catch {
            # UAC was declined: continue without admin rights, admin-only items are disabled.
        }
    }
    Show-RBGui
    return
}

# ------------------------------------------------------------------ command line
if (-not (Test-RBAdmin)) { Write-RBLog (T 'cli.not.admin') 'warn' }

if ($Restore) {
    if (-not $Source) { $Source = @(Find-RBBackups) | Select-Object -First 1 }
    if (-not $Source) { Write-RBLog (T 'cli.need.source') 'error'; exit 2 }
    $info = Get-RBRestoreItems $Source
    Write-RBLog (T 'cli.backup.info' $info.Dir $info.Manifest.created $info.Manifest.computer) 'step'
    $sel = Select-RBItems -Items $info.Items -Ids $Items -ProfilePath $ProfilePath -All:$All
    if ($List) { Write-RBItemTable $info.Items; return }
    if (-not $sel.Count) { Write-RBLog (T 'cli.nothing') 'warn'; exit 0 }
    $r = Invoke-RBRestore -Items $sel -BackupDir $info.Dir
    if ($r.Failed -gt 0) { exit 1 }
    exit 0
}

$found = @(Get-RBBackupItems)
$sel = Select-RBItems -Items $found -Ids $Items -ProfilePath $ProfilePath -All:$All
if ($List -and -not $Backup) { Write-RBItemTable $found; return }
if (-not $Target) { Write-RBLog (T 'cli.need.target') 'error'; exit 2 }
if (-not (Test-Path -LiteralPath $Target)) { New-Item -ItemType Directory -Force -Path $Target | Out-Null }
if (-not $sel.Count) { Write-RBLog (T 'cli.nothing') 'warn'; exit 0 }
$r = Invoke-RBBackup -Items $sel -Target $Target
if ($r.Failed -gt 0) { exit 1 }
exit 0
