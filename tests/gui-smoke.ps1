# GUI smoke test: opens the window, waits for the scan, saves screenshots,
# switches to restore mode with a given backup, saves another screenshot, closes.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tests\gui-smoke.ps1 -OutDir <dir> [-BackupPath <dir>] [-Lang tr]
param([Parameter(Mandatory = $true)][string]$OutDir, [string]$BackupPath, [string]$Lang = 'tr', [string]$SingleFile)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if ($SingleFile) {
    # use the embedded code/resources of a built dist\ResetBack.ps1
    $txt = [IO.File]::ReadAllText($SingleFile, [Text.Encoding]::UTF8)
    $m = [regex]::Match($txt, '(?s)# ---- embedded by build.*?# ---- end of embedded block ----')
    if (-not $m.Success) { throw 'embedded block not found' }
    Invoke-Expression $m.Value
    $Global:RB_ROOT = Split-Path -Parent $SingleFile
} else {
    $Global:RB_ROOT = $root
    $parts = @('src\Core.ps1', 'src\Engine.ps1') + @(Get-ChildItem (Join-Path $root 'src\Providers') -Filter *.ps1 | Sort-Object Name | ForEach-Object { 'src\Providers\' + $_.Name }) + @('src\Gui.ps1')
    $Global:RB_CODE = ($parts | ForEach-Object { [IO.File]::ReadAllText((Join-Path $root $_), [Text.Encoding]::UTF8) }) -join "`r`n"
}
. ([scriptblock]::Create($Global:RB_CODE))
Set-RBLanguage $Lang
New-Item -ItemType Directory -Force $OutDir | Out-Null
$Global:SmokeOut = $OutDir
$Global:SmokeBackup = $BackupPath
$Global:SmokeStage = 0
$Global:SmokeResult = @{ BackupItems = 0; RestoreItems = 0; Errors = @() }

function Save-SmokeShot([string]$Name) {
    $w = $Global:RBUI.Window
    $w.UpdateLayout()
    $bmp = New-Object Windows.Media.Imaging.RenderTargetBitmap ([int]$w.ActualWidth), ([int]$w.ActualHeight), 96, 96, ([Windows.Media.PixelFormats]::Pbgra32)
    $bmp.Render($w)
    $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bmp))
    $fs = [IO.File]::Create((Join-Path $Global:SmokeOut $Name))
    try { $enc.Save($fs) } finally { $fs.Close() }
}

$Global:SmokeMessages = New-Object System.Collections.ArrayList
$Global:RBMessageHook = {
    param($text, $buttons)
    [void]$Global:SmokeMessages.Add($text)
    if ($buttons -eq 'YesNo') { return 'Yes' }
    if ($buttons -eq 'OKCancel') { return 'OK' }
    if ($buttons -eq 'YesNoCancel') { return 'No' }
    return 'OK'
}

$Global:RBGuiOnShown = {
    $t = New-Object Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds(500)
    $Global:SmokeTicks = 0
    $t.Add_Tick({
            $Global:SmokeTicks++
            $g = $Global:RBGui
            if ($Global:SmokeTicks -gt 240) { $Global:SmokeResult.Errors += 'timeout'; $Global:RBUI.Window.Close(); return }
            if ($g.Busy) { return }
            switch ($Global:SmokeStage) {
                0 {
                    if (-not $g.Items.Count) { return }
                    $Global:SmokeResult.BackupItems = $g.Items.Count
                    Save-SmokeShot 'gui-backup.png'
                    # dry-run backup through the GUI (exercises the background runspace)
                    $Global:RBUI.PathBox.Text = (Join-Path $Global:SmokeOut 'target')
                    $Global:RBUI.DryRunChk.IsChecked = $true
                    $Global:SmokeStage = 1
                    Start-RBUiRun
                }
                1 {
                    if ($Global:RBUI.LogBox.Text -notmatch 'ResetBack-') { $Global:SmokeResult.Errors += 'dry backup log missing' }
                    Save-SmokeShot 'gui-dryrun.png'
                    $Global:SmokeStage = 2
                    if ($Global:SmokeBackup) {
                        $Global:RBUI.ModeRestore.IsChecked = $true
                        $Global:RBUI.PathBox.Text = $Global:SmokeBackup
                        Start-RBUiScan
                    } else { $Global:RBUI.Window.Close() }
                }
                2 {
                    if (-not $g.Items.Count) { return }
                    $Global:SmokeResult.RestoreItems = $g.Items.Count
                    Save-SmokeShot 'gui-restore.png'
                    $Global:RBUI.DryRunChk.IsChecked = $true
                    $Global:SmokeStage = 3
                    Start-RBUiRun
                }
                3 {
                    Save-SmokeShot 'gui-restore-dry.png'
                    $Global:SmokeStage = 4
                    $Global:RBUI.Window.Close()
                }
            }
        })
    $t.Start()
}

Show-RBGui
"backupItems=$($Global:SmokeResult.BackupItems) restoreItems=$($Global:SmokeResult.RestoreItems) errors=$($Global:SmokeResult.Errors -join ',')"
"messages:"; $Global:SmokeMessages | ForEach-Object { '  - ' + ($_ -replace "`r`n", ' | ') }
[IO.File]::WriteAllText((Join-Path $OutDir 'log.txt'), $Global:RBUI.LogBox.Text, [Text.Encoding]::UTF8)
if ($Global:SmokeResult.Errors.Count -or -not $Global:SmokeResult.BackupItems) { exit 1 }
