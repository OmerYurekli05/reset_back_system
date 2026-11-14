# reset_back_system - WPF interface.
# Long work runs in a background runspace; a DispatcherTimer moves its log
# lines and progress into the window so the UI never freezes.

$Global:RBUI = $null
$Global:RBGui = $null

# Script that runs inside the background runspace.
$Global:RBWorkerBootstrap = {
    param($Root, $Code, $Embed, $Lang, $Sync, $WorkText, $WorkArgs, $Options, $DryRun)
    $ErrorActionPreference = 'Stop'
    $Global:RB_ROOT = $Root
    $Global:RB_EMBED = $Embed
    try {
        . ([scriptblock]::Create($Code))
        Set-RBLanguage $Lang
        $Global:RB.DryRun = $DryRun
        $Global:RB.Options = $Options
        $Global:RB.LogSink = { param($l, $m) $Sync.Queue.Enqueue(@($l, $m)) }.GetNewClosure()
        $Global:RB.ProgressSink = { param($c, $t, $s) $Sync.Progress = [int](100 * $c / [math]::Max(1, $t)); $Sync.Status = $s }.GetNewClosure()
        $work = [scriptblock]::Create($WorkText)
        $Sync.Result = & $work $WorkArgs
    } catch {
        $Sync.Error = $_.Exception.Message
    } finally {
        $Sync.Done = $true
    }
}.ToString()

function New-RBBrush { param([string]$Hex) return (New-Object Windows.Media.BrushConverter).ConvertFromString($Hex) }

function Show-RBMessage {
    param([string]$Text, [string]$Buttons = 'OK', [string]$Icon = 'Information')
    if ($Global:RBMessageHook) { return (& $Global:RBMessageHook $Text $Buttons) }
    return [Windows.MessageBox]::Show($Global:RBUI.Window, $Text, 'reset_back_system', $Buttons, $Icon)
}

function Add-RBUiLog {
    param([string]$Level, [string]$Message)
    $prefix = switch ($Level) { 'ok' { '[OK] ' } 'warn' { '[!]  ' } 'error' { '[X]  ' } 'step' { '>>   ' } default { '     ' } }
    $Global:RBUI.LogBox.AppendText($prefix + $Message + "`r`n")
    $Global:RBUI.LogBox.ScrollToEnd()
}

function Test-RBUiItemEnabled {
    param($Item)
    if ($Item.RequiresAdmin -and -not $Global:RBGui.IsAdmin) { return $false }
    if ($Global:RBGui.Mode -eq 'restore' -and -not $Item.RestoreSupported) { return $false }
    return $true
}

function Get-RBUiSelected {
    return @($Global:RBGui.Items | Where-Object { $_.Selected -and (Test-RBUiItemEnabled $_) })
}

function Update-RBUiStart {
    $ui = $Global:RBUI; $g = $Global:RBGui
    $n = @(Get-RBUiSelected).Count
    $key = if ($g.Mode -eq 'backup') { 'gui.start.backup' } else { 'gui.start.restore' }
    $ui.StartBtn.Content = T $key $n
    $ui.StartBtn.IsEnabled = ($n -gt 0 -and -not $g.Busy)
}

function Update-RBUiHeaders {
    foreach ($child in $Global:RBUI.ItemsPanel.Children) {
        if ($child -isnot [Windows.Controls.CheckBox] -or $child.Tag -isnot [string]) { continue }
        $cat = $child.Tag
        $items = @($Global:RBGui.Items | Where-Object { $_.Category -eq $cat -and (Test-RBUiItemEnabled $_) })
        $sel = @($items | Where-Object { $_.Selected }).Count
        if ($items.Count -eq 0 -or $sel -eq 0) { $child.IsChecked = $false }
        elseif ($sel -eq $items.Count) { $child.IsChecked = $true }
        else { $child.IsChecked = $null }
    }
}

function New-RBBadge {
    param([string]$Text, [string]$Fore, [string]$Back)
    $b = New-Object Windows.Controls.Border
    $b.Background = New-RBBrush $Back
    $b.CornerRadius = New-Object Windows.CornerRadius 3
    $b.Padding = New-Object Windows.Thickness 6, 1, 6, 1
    $b.Margin = New-Object Windows.Thickness 8, 0, 0, 0
    $b.VerticalAlignment = 'Center'
    $t = New-Object Windows.Controls.TextBlock
    $t.Text = $Text
    $t.FontSize = 11
    $t.Foreground = New-RBBrush $Fore
    $b.Child = $t
    return $b
}

# ---- per-program picker shown under the winget item

function Get-RBUiPackageHeader {
    param($Item)
    $all = @($Item.Data.packages)
    $ex = @($Item.Data.exclude | Where-Object { $_ })
    return (T 'gui.programs.pick' ($all.Count - @($all | Where-Object { $ex -contains $_.id }).Count) $all.Count)
}

function Set-RBUiPackage {
    param($Item, [string]$Id, [bool]$On)
    $ex = New-Object System.Collections.ArrayList
    foreach ($x in @($Item.Data.exclude | Where-Object { $_ })) { if ($x -ne $Id) { [void]$ex.Add($x) } }
    if (-not $On) { [void]$ex.Add($Id) }
    $Item.Data.exclude = $ex.ToArray()
}

function New-RBUiPackagePicker {
    param($Item, [bool]$Enabled)
    $exp = New-Object Windows.Controls.Expander
    $exp.Margin = New-Object Windows.Thickness 46, 0, 0, 8
    $exp.Header = Get-RBUiPackageHeader $Item
    $exp.Foreground = New-RBBrush '#1D4ED8'
    $exp.IsEnabled = $Enabled
    $exp.Tag = $Item.Id
    if (-not $Global:RBGui.Expanded) { $Global:RBGui.Expanded = @{} }
    $exp.IsExpanded = [bool]$Global:RBGui.Expanded[$Item.Id]
    $exp.Add_Expanded({ param($s, $e) $Global:RBGui.Expanded[$s.Tag] = $true })
    $exp.Add_Collapsed({ param($s, $e) $Global:RBGui.Expanded[$s.Tag] = $false })

    $panel = New-Object Windows.Controls.StackPanel
    $panel.Margin = New-Object Windows.Thickness 0, 6, 0, 0
    $bar = New-Object Windows.Controls.StackPanel
    $bar.Orientation = 'Horizontal'
    $bar.Margin = New-Object Windows.Thickness 0, 0, 0, 6
    $lbl = New-Object Windows.Controls.TextBlock
    $lbl.Text = T 'gui.programs.filter'
    $lbl.VerticalAlignment = 'Center'
    $lbl.Foreground = New-RBBrush '#374151'
    $lbl.Margin = New-Object Windows.Thickness 0, 0, 6, 0
    $box = New-Object Windows.Controls.TextBox
    $box.Width = 220
    $box.Padding = New-Object Windows.Thickness 4, 2, 4, 2
    $wrap = New-Object Windows.Controls.WrapPanel
    $btnAll = New-Object Windows.Controls.Button
    $btnAll.Content = T 'gui.programs.all'
    $btnAll.Margin = New-Object Windows.Thickness 8, 0, 0, 0
    $btnNone = New-Object Windows.Controls.Button
    $btnNone.Content = T 'gui.programs.none'
    [void]$bar.Children.Add($lbl); [void]$bar.Children.Add($box); [void]$bar.Children.Add($btnAll); [void]$bar.Children.Add($btnNone)

    $ex = @($Item.Data.exclude | Where-Object { $_ })
    foreach ($p in @($Item.Data.packages)) {
        $c = New-Object Windows.Controls.CheckBox
        $c.Width = 270
        $c.Margin = New-Object Windows.Thickness 0, 2, 8, 2
        $c.Content = [string]$p.name
        $c.ToolTip = '{0}  ({1})' -f $p.id, $p.source
        $c.IsChecked = ($ex -notcontains $p.id)
        $c.Foreground = New-RBBrush '#111827'
        $c.Tag = @{ Item = $Item; Id = [string]$p.id; Text = ([string]$p.name + ' ' + [string]$p.id); Exp = $exp }
        $c.Add_Click({
                param($s, $e)
                Set-RBUiPackage $s.Tag.Item $s.Tag.Id ($s.IsChecked -eq $true)
                $s.Tag.Exp.Header = Get-RBUiPackageHeader $s.Tag.Item
            })
        [void]$wrap.Children.Add($c)
    }
    $box.Tag = $wrap
    $box.Add_TextChanged({
            param($s, $e)
            $q = $s.Text.Trim()
            foreach ($c in $s.Tag.Children) {
                $show = (-not $q) -or ($c.Tag.Text.IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -ge 0)
                $c.Visibility = if ($show) { 'Visible' } else { 'Collapsed' }
            }
        })
    $handler = {
        param($s, $e)
        foreach ($c in $s.Tag.Wrap.Children) {
            if ($c.Visibility -ne 'Visible') { continue }
            $c.IsChecked = $s.Tag.On
            Set-RBUiPackage $c.Tag.Item $c.Tag.Id $s.Tag.On
        }
        $s.Tag.Exp.Header = Get-RBUiPackageHeader $s.Tag.Item
    }
    $btnAll.Tag = @{ Wrap = $wrap; Item = $Item; Exp = $exp; On = $true }
    $btnNone.Tag = @{ Wrap = $wrap; Item = $Item; Exp = $exp; On = $false }
    $btnAll.Add_Click($handler)
    $btnNone.Add_Click($handler)

    [void]$panel.Children.Add($bar)
    [void]$panel.Children.Add($wrap)
    $exp.Content = $panel
    return $exp
}

function Update-RBUiList {
    $ui = $Global:RBUI; $g = $Global:RBGui
    $ui.ItemsPanel.Children.Clear()
    $items = @($g.Items)
    $ui.EmptyText.Visibility = if ($items.Count) { 'Collapsed' } else { 'Visible' }
    foreach ($cat in $Global:RBCategories) {
        $catItems = @($items | Where-Object { $_.Category -eq $cat })
        if (-not $catItems.Count) { continue }

        $header = New-Object Windows.Controls.CheckBox
        $header.Content = '{0}  ({1})' -f (T "cat.$cat"), $catItems.Count
        $header.FontWeight = [Windows.FontWeights]::SemiBold
        $header.FontSize = 14
        $header.Foreground = New-RBBrush '#1F2937'
        $header.Margin = New-Object Windows.Thickness 0, 12, 0, 4
        $header.Tag = [string]$cat
        $header.Add_Click({
                param($s, $e)
                $on = ($s.IsChecked -eq $true)
                foreach ($it in $Global:RBGui.Items) { if ($it.Category -eq $s.Tag -and (Test-RBUiItemEnabled $it)) { $it.Selected = $on } }
                Update-RBUiList
            })
        [void]$ui.ItemsPanel.Children.Add($header)

        foreach ($it in $catItems) {
            $enabled = Test-RBUiItemEnabled $it
            $cb = New-Object Windows.Controls.CheckBox
            $cb.Margin = New-Object Windows.Thickness 24, 4, 0, 4
            $cb.IsEnabled = $enabled
            $cb.IsChecked = [bool]($it.Selected -and $enabled)
            $cb.Tag = $it
            $cb.VerticalContentAlignment = 'Top'

            $sp = New-Object Windows.Controls.StackPanel
            $row = New-Object Windows.Controls.StackPanel
            $row.Orientation = 'Horizontal'
            $name = New-Object Windows.Controls.TextBlock
            $name.Text = [string]$it.Name
            $name.FontWeight = [Windows.FontWeights]::SemiBold
            $name.Foreground = New-RBBrush '#111827'
            [void]$row.Children.Add($name)
            $sz = Format-RBSize $it.Size
            if ($sz) { [void]$row.Children.Add((New-RBBadge $sz '#374151' '#F3F4F6')) }
            if ($it.Sensitive) { [void]$row.Children.Add((New-RBBadge (T 'gui.badge.sensitive') '#92400E' '#FEF3C7')) }
            if ($it.RequiresAdmin) { [void]$row.Children.Add((New-RBBadge (T 'gui.badge.admin') '#1E40AF' '#DBEAFE')) }
            if (-not $it.RestoreSupported) { [void]$row.Children.Add((New-RBBadge (T 'gui.badge.backuponly') '#6B21A8' '#F3E8FF')) }
            [void]$sp.Children.Add($row)
            if ($it.Description) {
                $d = New-Object Windows.Controls.TextBlock
                $d.Text = [string]$it.Description
                $d.Foreground = New-RBBrush '#6B7280'
                $d.FontSize = 12
                $d.TextWrapping = 'Wrap'
                $d.Margin = New-Object Windows.Thickness 0, 1, 0, 0
                [void]$sp.Children.Add($d)
            }
            $cb.Content = $sp
            $cb.Add_Click({
                    param($s, $e)
                    $s.Tag.Selected = ($s.IsChecked -eq $true)
                    Update-RBUiHeaders
                    Update-RBUiStart
                })
            [void]$ui.ItemsPanel.Children.Add($cb)
            if ($it.Data -and $it.Data.packages -and @($it.Data.packages).Count -gt 0) {
                [void]$ui.ItemsPanel.Children.Add((New-RBUiPackagePicker $it $enabled))
            }
        }
    }
    Update-RBUiHeaders
    Update-RBUiStart
}

function Set-RBUiTexts {
    $ui = $Global:RBUI; $g = $Global:RBGui
    $backup = ($g.Mode -eq 'backup')
    $ui.Window.Title = "reset_back_system $($Global:RB.Version)"
    $ui.SubtitleText.Text = T 'gui.subtitle'
    $ui.LangBtn.Content = if ($Global:RB.Lang -eq 'tr') { 'EN' } else { 'TR' }
    $ui.LangBtn.ToolTip = T 'gui.lang.tooltip'
    $ui.ModeBackup.Content = T 'gui.mode.backup'
    $ui.ModeRestore.Content = T 'gui.mode.restore'
    if ($g.IsAdmin) { $ui.AdminText.Text = T 'gui.admin.yes'; $ui.AdminText.Foreground = New-RBBrush '#047857' }
    else { $ui.AdminText.Text = T 'gui.admin.no'; $ui.AdminText.Foreground = New-RBBrush '#B45309' }
    $ui.PathLabel.Text = if ($backup) { T 'gui.path.backup' } else { T 'gui.path.restore' }
    $ui.BrowseBtn.Content = T 'gui.browse'
    $ui.ScanBtn.Content = if ($backup) { T 'gui.scan' } else { T 'gui.load' }
    $ui.AllBtn.Content = T 'gui.all'
    $ui.NoneBtn.Content = T 'gui.none'
    $ui.SaveProfileBtn.Content = T 'gui.profile.save'
    $ui.SaveProfileBtn.ToolTip = T 'gui.profile.tip'
    $ui.LoadProfileBtn.Content = T 'gui.profile.load'
    $ui.LoadProfileBtn.ToolTip = T 'gui.profile.tip'
    $ui.DryRunChk.Content = T 'gui.dryrun'
    $ui.DryRunChk.ToolTip = T 'gui.dryrun.tip'
    $ui.OverwriteChk.Content = T 'gui.overwrite'
    $ui.OverwriteChk.ToolTip = T 'gui.overwrite.tip'
    $ui.OverwriteChk.Visibility = if ($backup) { 'Collapsed' } else { 'Visible' }
    $ui.EmptyText.Text = if ($backup) { T 'gui.empty.backup' } else { T 'gui.empty.restore' }
    if (-not $g.Busy -and -not $ui.StatusText.Text) { $ui.StatusText.Text = T 'gui.status.ready' }
    Update-RBUiStart
}

function Set-RBUiBusy {
    param([bool]$Busy)
    $ui = $Global:RBUI
    $Global:RBGui.Busy = $Busy
    foreach ($n in @('ModeBackup', 'ModeRestore', 'BrowseBtn', 'ScanBtn', 'AllBtn', 'NoneBtn', 'SaveProfileBtn', 'LoadProfileBtn', 'LangBtn', 'PathBox', 'DryRunChk', 'OverwriteChk', 'ItemsPanel')) {
        $ui[$n].IsEnabled = -not $Busy
    }
    # a running scan can be abandoned by switching mode
    if ($Busy -and $Global:RBGui.Worker -and $Global:RBGui.Worker.Kind -eq 'scan') {
        $ui.ModeBackup.IsEnabled = $true
        $ui.ModeRestore.IsEnabled = $true
    }
    $ui.Window.Cursor = if ($Busy) { [Windows.Input.Cursors]::AppStarting } else { $null }
    Update-RBUiStart
}

function Start-RBUiWorker {
    param([string]$WorkText, $WorkArgs, [scriptblock]$OnDone, [string]$Kind = 'run')
    $sync = [hashtable]::Synchronized(@{
            Queue = (New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]')
            Done = $false; Result = $null; Error = $null; Progress = 0; Status = ''
        })
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($Global:RBWorkerBootstrap)
    foreach ($a in @($Global:RB.Root, $Global:RB_CODE, $Global:RB_EMBED, $Global:RB.Lang, $sync, $WorkText, $WorkArgs, $Global:RB.Options, [bool]$Global:RB.DryRun)) {
        [void]$ps.AddArgument($a)
    }
    $Global:RBGui.Worker = @{ Sync = $sync; PS = $ps; Runspace = $rs; Handle = $ps.BeginInvoke(); OnDone = $OnDone; Kind = $Kind }
    $Global:RBUI.Progress.Value = 0
    Set-RBUiBusy $true
}

function Stop-RBUiWorker {
    $w = $Global:RBGui.Worker
    if (-not $w) { return }
    $Global:RBGui.Worker = $null
    try { $w.PS.Stop() } catch { }
    try { $w.PS.Dispose(); $w.Runspace.Close(); $w.Runspace.Dispose() } catch { }
    Add-RBUiLog 'info' (T 'gui.scan.cancelled')
    $Global:RBUI.Progress.Value = 0
    $Global:RBUI.StatusText.Text = T 'gui.status.ready'
    Set-RBUiBusy $false
}

function Invoke-RBUiTick {
    $w = $Global:RBGui.Worker
    if (-not $w) { return }
    $msg = $null
    while ($w.Sync.Queue.TryDequeue([ref]$msg)) { Add-RBUiLog $msg[0] $msg[1] }
    $Global:RBUI.Progress.Value = $w.Sync.Progress
    if ($w.Sync.Status) { $Global:RBUI.StatusText.Text = $w.Sync.Status }
    if (-not $w.Sync.Done) { return }
    try { [void]$w.PS.EndInvoke($w.Handle) } catch { }
    try { $w.PS.Dispose(); $w.Runspace.Close(); $w.Runspace.Dispose() } catch { }
    $Global:RBGui.Worker = $null
    Set-RBUiBusy $false
    try { & $w.OnDone $w.Sync } catch { Add-RBUiLog 'error' $_.Exception.Message }
}

function Start-RBUiScan {
    $ui = $Global:RBUI; $g = $Global:RBGui
    if ($g.Busy) { return }
    $g.Items = @()
    Update-RBUiList
    if ($g.Mode -eq 'backup') {
        $ui.EmptyText.Text = T 'gui.scanning'
        Add-RBUiLog 'step' (T 'gui.scanning')
        Start-RBUiWorker -Kind 'scan' 'param($a) , @(Get-RBBackupItems)' $null {
            param($s)
            $Global:RBUI.Progress.Value = 0
            $Global:RBUI.StatusText.Text = T 'gui.status.ready'
            Set-RBUiTexts
            if ($s.Error) { Add-RBUiLog 'error' $s.Error; return }
            $Global:RBGui.Items = @(@($s.Result) | Where-Object { $_ -and $_.Id })
            foreach ($it in $Global:RBGui.Items) { Update-RBItemText $it }
            Add-RBUiLog 'ok' (T 'gui.found' $Global:RBGui.Items.Count)
            Update-RBUiList
        }
    } else {
        $src = $ui.PathBox.Text.Trim()
        if (-not $src -or -not (Test-Path -LiteralPath $src)) { [void](Show-RBMessage (T 'gui.err.path') 'OK' 'Warning'); return }
        Add-RBUiLog 'step' (T 'gui.loading' $src)
        Start-RBUiWorker -Kind 'scan' 'param($a) Get-RBRestoreItems $a' $src {
            param($s)
            $Global:RBUI.Progress.Value = 0
            $Global:RBUI.StatusText.Text = T 'gui.status.ready'
            if ($s.Error) { Add-RBUiLog 'error' $s.Error; [void](Show-RBMessage $s.Error 'OK' 'Warning'); return }
            $r = @($s.Result)[-1]
            $Global:RBGui.BackupDir = $r.Dir
            $Global:RBUI.PathBox.Text = $r.Dir
            $Global:RBGui.Items = @($r.Items)
            foreach ($it in $Global:RBGui.Items) { Update-RBItemText $it }
            $created = $r.Manifest.created
            try { $created = ([datetime]$created).ToString('g') } catch { }
            Add-RBUiLog 'ok' (T 'gui.backupinfo' $created $r.Manifest.computer $Global:RBGui.Items.Count)
            Update-RBUiList
        }
    }
}

function Confirm-RBUiProcesses {
    param([object[]]$Items)
    $names = @($Items | ForEach-Object { $_.Processes } | Where-Object { $_ } | Select-Object -Unique)
    while ($true) {
        $running = @(Get-RBRunningProcesses $names)
        if (-not $running.Count) { return 'ok' }
        $r = Show-RBMessage (T 'gui.ask.closeapps' ($running -join ', ')) 'YesNoCancel' 'Warning'
        if ($r -eq 'Yes') { continue }
        if ($r -eq 'No') { return 'force' }
        return 'cancel'
    }
}

function Start-RBUiRun {
    $ui = $Global:RBUI; $g = $Global:RBGui
    if ($g.Busy) { return }
    $sel = @(Get-RBUiSelected)
    if (-not $sel.Count) { return }
    $dry = ($ui.DryRunChk.IsChecked -eq $true)
    $Global:RB.DryRun = $dry
    $Global:RB.Options = @{ Overwrite = ($ui.OverwriteChk.IsChecked -eq $true); Force = $false }

    if ($g.Mode -eq 'backup') {
        $target = $ui.PathBox.Text.Trim()
        if (-not $target) { [void](Show-RBMessage (T 'gui.err.target') 'OK' 'Warning'); return }
        if (-not (Test-Path -LiteralPath $target)) {
            if ((Show-RBMessage (T 'gui.ask.create' $target) 'YesNo' 'Question') -ne 'Yes') { return }
            try { New-Item -ItemType Directory -Force -Path $target | Out-Null } catch { [void](Show-RBMessage $_.Exception.Message 'OK' 'Error'); return }
        }
        $q = Split-Path -Qualifier $target -ErrorAction SilentlyContinue
        if ($q -and $q -eq $env:SystemDrive -and -not $dry) {
            if ((Show-RBMessage (T 'gui.warn.systemdrive') 'YesNo' 'Warning') -ne 'Yes') { return }
        }
        if (@($sel | Where-Object { $_.Sensitive }).Count -and -not $dry) {
            if ((Show-RBMessage (T 'gui.warn.sensitive') 'OKCancel' 'Warning') -ne 'OK') { return }
        }
    } else {
        if (-not $dry -and (Show-RBMessage (T 'gui.ask.restore' $sel.Count) 'YesNo' 'Question') -ne 'Yes') { return }
    }

    if (-not $dry) {
        $pc = Confirm-RBUiProcesses $sel
        if ($pc -eq 'cancel') { return }
        if ($pc -eq 'force') { $Global:RB.Options.Force = $true }
    }

    $onDone = {
        param($s)
        $Global:RBUI.Progress.Value = 100
        if ($s.Error) { Add-RBUiLog 'error' $s.Error; [void](Show-RBMessage $s.Error 'OK' 'Error'); return }
        $r = @($s.Result)[-1]
        $Global:RBUI.StatusText.Text = T 'gui.status.done' $r.Ok $r.Failed $r.Skipped
        $wl = if ($r.Warned) { T 'gui.done.warnline' $r.Warned } else { '' }
        $icon = if ($r.Failed -or $r.Warned) { 'Warning' } else { 'Information' }
        if ($Global:RBGui.Mode -eq 'backup') {
            if ($r.DryRun) { [void](Show-RBMessage ((T 'gui.done.dry' $r.Ok $r.Failed $r.Skipped) + $wl) 'OK' $icon) }
            elseif ((Show-RBMessage ((T 'gui.done.backup' $r.Ok $r.Failed $r.Skipped $r.Dir) + $wl) 'YesNo' $icon) -eq 'Yes') {
                Start-Process explorer.exe -ArgumentList ('"{0}"' -f $r.Dir)
            }
        } else {
            if ($r.DryRun) { [void](Show-RBMessage ((T 'gui.done.dry' $r.Ok $r.Failed $r.Skipped) + $wl) 'OK' $icon) }
            else { [void](Show-RBMessage ((T 'gui.done.restore' $r.Ok $r.Failed $r.Skipped $r.LogFile) + $wl) 'OK' $icon) }
        }
    }

    if ($g.Mode -eq 'backup') {
        Start-RBUiWorker 'param($a) Invoke-RBBackup -Items $a.Items -Target $a.Target' @{ Items = $sel; Target = $ui.PathBox.Text.Trim() } $onDone
    } else {
        Start-RBUiWorker 'param($a) Invoke-RBRestore -Items $a.Items -BackupDir $a.Dir' @{ Items = $sel; Dir = $g.BackupDir } $onDone
    }
}

function Set-RBUiMode {
    param([string]$Mode, [string]$Path)
    $ui = $Global:RBUI; $g = $Global:RBGui
    # switching mode cancels a scan that is still running (never a real backup/restore)
    if ($g.Worker -and $g.Worker.Kind -eq 'scan') { Stop-RBUiWorker }
    $g.Mode = $Mode
    $g.Items = @()
    $g.BackupDir = $null
    if ($Mode -eq 'backup') {
        $ui.PathBox.Text = Get-RBDefaultTarget
    } elseif ($Path) {
        $ui.PathBox.Text = $Path
    } else {
        $found = @(Find-RBBackups)
        $ui.PathBox.Text = if ($found.Count) { $found[0] } else { '' }
    }
    $want = ($Mode -eq 'restore')
    if ([bool]$ui.ModeRestore.IsChecked -ne $want) { $ui.ModeRestore.IsChecked = $want; $ui.ModeBackup.IsChecked = -not $want }
    Set-RBUiTexts
    Update-RBUiList
    if ($Mode -eq 'backup' -or $ui.PathBox.Text) { Start-RBUiScan }
}

function Save-RBUiProfile {
    $g = $Global:RBGui
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Filter = 'JSON (*.json)|*.json'
    $dlg.FileName = 'resetback-profile.json'
    if (-not $dlg.ShowDialog($Global:RBUI.Window)) { return }
    Save-RBProfile $g.Items $dlg.FileName $g.Mode
    Add-RBUiLog 'ok' (T 'gui.profile.saved' $dlg.FileName)
}

function Import-RBUiProfile {
    $g = $Global:RBGui
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = 'JSON (*.json)|*.json'
    $pd = Join-Path $Global:RB.Root 'profiles'
    if (Test-Path -LiteralPath $pd) { $dlg.InitialDirectory = $pd }
    if (-not $dlg.ShowDialog($Global:RBUI.Window)) { return }
    try {
        [void](Select-RBItems -Items $g.Items -ProfilePath $dlg.FileName)
        Update-RBUiList
        Add-RBUiLog 'ok' (T 'gui.profile.loaded' $dlg.FileName)
    } catch { [void](Show-RBMessage $_.Exception.Message 'OK' 'Error') }
}

function Show-RBGui {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
    try {
        [xml]$xaml = Get-RBResourceText 'src\MainWindow.xaml'
        $win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
        $ui = @{ Window = $win }
        foreach ($n in @('LangBtn', 'TitleText', 'SubtitleText', 'ModeBackup', 'ModeRestore', 'AdminText', 'PathLabel', 'PathBox', 'BrowseBtn',
                'ScanBtn', 'ItemsPanel', 'EmptyText', 'AllBtn', 'NoneBtn', 'SaveProfileBtn', 'LoadProfileBtn', 'DryRunChk', 'OverwriteChk',
                'StartBtn', 'Progress', 'StatusText', 'LogBox')) { $ui[$n] = $win.FindName($n) }
        $Global:RBUI = $ui
        $Global:RBGui = @{ Items = @(); Mode = 'backup'; Worker = $null; BackupDir = $null; IsAdmin = (Test-RBAdmin); Busy = $false; Expanded = @{} }
        $Global:RB.LogSink = { param($l, $m) Add-RBUiLog $l $m }

        $ui.ModeBackup.Add_Checked({ if ($Global:RBGui.Mode -ne 'backup') { Set-RBUiMode 'backup' } })
        $ui.ModeRestore.Add_Checked({ if ($Global:RBGui.Mode -ne 'restore') { Set-RBUiMode 'restore' } })
        $ui.ScanBtn.Add_Click({ Start-RBUiScan })
        $ui.StartBtn.Add_Click({ Start-RBUiRun })
        $ui.AllBtn.Add_Click({ foreach ($it in $Global:RBGui.Items) { if (Test-RBUiItemEnabled $it) { $it.Selected = $true } }; Update-RBUiList })
        $ui.NoneBtn.Add_Click({ foreach ($it in $Global:RBGui.Items) { $it.Selected = $false }; Update-RBUiList })
        $ui.SaveProfileBtn.Add_Click({ Save-RBUiProfile })
        $ui.LoadProfileBtn.Add_Click({ Import-RBUiProfile })
        $ui.BrowseBtn.Add_Click({
                $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
                $dlg.Description = T 'gui.browse.desc'
                $dlg.ShowNewFolderButton = ($Global:RBGui.Mode -eq 'backup')
                $cur = $Global:RBUI.PathBox.Text
                if ($cur -and (Test-Path -LiteralPath $cur)) { $dlg.SelectedPath = $cur }
                if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                    $Global:RBUI.PathBox.Text = $dlg.SelectedPath
                    if ($Global:RBGui.Mode -eq 'restore') { Start-RBUiScan }
                }
            })
        $ui.LangBtn.Add_Click({
                $new = if ($Global:RB.Lang -eq 'tr') { 'en' } else { 'tr' }
                Set-RBLanguage $new
                $s = Get-RBSettings; $s.lang = $new; Save-RBSettings $s
                foreach ($it in $Global:RBGui.Items) { Update-RBItemText $it }
                $Global:RBUI.StatusText.Text = ''
                Set-RBUiTexts
                Update-RBUiList
            })
        $win.Add_Closing({
                param($s, $e)
                $w = $Global:RBGui.Worker
                if (-not $w) { return }
                if ((Show-RBMessage (T 'gui.ask.quit') 'YesNo' 'Warning') -ne 'Yes') { $e.Cancel = $true; return }
                try { $w.PS.Stop() } catch { }
            })

        $timer = New-Object Windows.Threading.DispatcherTimer
        $timer.Interval = [TimeSpan]::FromMilliseconds(150)
        $timer.Add_Tick({ Invoke-RBUiTick })
        $timer.Start()

        Set-RBUiTexts
        Add-RBUiLog 'info' ("reset_back_system $($Global:RB.Version) - " + $(if ($Global:RBGui.IsAdmin) { T 'gui.admin.yes' } else { T 'gui.admin.no' }))
        $win.Add_ContentRendered({
                # After a reset the app is usually opened to restore: when a backup is found,
                # open in restore mode and read it instead of scanning the computer first.
                $start = if ($Global:RBGuiOnShown) { @{ Mode = 'backup'; Path = '' } } else { Get-RBStartupMode }
                if ($start.Mode -eq 'restore') {
                    Add-RBUiLog 'info' (T 'gui.found.backup' $start.Path)
                    Set-RBUiMode 'restore' $start.Path
                } else {
                    Set-RBUiMode 'backup'
                }
                # Hook for automated GUI smoke tests (tests\gui-smoke.ps1).
                if ($Global:RBGuiOnShown) { & $Global:RBGuiOnShown }
            })
        [void]$win.ShowDialog()
        $timer.Stop()
    } catch {
        [void][Windows.MessageBox]::Show(("reset_back_system`r`n`r`n" + $_.Exception.Message + "`r`n" + $_.InvocationInfo.PositionMessage), 'reset_back_system', 'OK', 'Error')
    }
}
