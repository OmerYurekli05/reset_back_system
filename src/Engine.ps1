# reset_back_system - engine: discovery, backup run, restore run, manifest.

$Global:RBManifestFormat = 1

function Get-RBOsName {
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        return '{0} ({1})' -f $os.Caption, $os.Version
    } catch { return [Environment]::OSVersion.VersionString }
}

function Get-RBBackupItems {
    $all = New-Object System.Collections.ArrayList
    foreach ($p in @($Global:RB.Providers.Values)) {
        if (-not $p.Discover) { continue }
        try {
            foreach ($i in @(& $p.Discover)) { if ($i -and $i.Id) { [void]$all.Add($i) } }
        } catch {
            Write-RBLog (T 'log.discover.fail' $p.Name $_.Exception.Message) 'error'
        }
    }
    return @($all | Sort-Object Order, Name)
}

function Select-RBItems {
    param([object[]]$Items, [string[]]$Ids, [string]$ProfilePath, [switch]$All)
    if ($ProfilePath) {
        $prof = Read-RBJsonFile $ProfilePath
        $Ids = @($prof.items)
    }
    $Ids = @($Ids | ForEach-Object { ([string]$_) -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    foreach ($it in $Items) {
        if ($All) { $it.Selected = $true }
        elseif ($Ids.Count) {
            $hit = $false
            foreach ($pattern in $Ids) { if ($it.Id -like $pattern) { $hit = $true; break } }
            $it.Selected = $hit
        }
    }
    return @($Items | Where-Object { $_.Selected })
}

function Get-RBDefaultTarget {
    $sys = $env:SystemDrive
    try {
        $d = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=2 OR DriveType=3' -ErrorAction Stop |
            Where-Object { $_.DeviceID -ne $sys -and $_.FreeSpace -gt 1GB } |
            Sort-Object FreeSpace -Descending | Select-Object -First 1
        if ($d) { return ($d.DeviceID + '\') }
    } catch { }
    return [Environment]::GetFolderPath('Desktop')
}

function Find-RBBackups {
    $roots = @()
    try { $roots += @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=2 OR DriveType=3' -ErrorAction Stop | ForEach-Object { $_.DeviceID + '\' }) } catch { }
    $roots += [Environment]::GetFolderPath('Desktop')
    $found = foreach ($r in $roots) {
        Get-ChildItem -LiteralPath $r -Directory -Filter 'ResetBack-*' -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'manifest.json') }
    }
    return @($found | Sort-Object Name -Descending | ForEach-Object { $_.FullName })
}

function Resolve-RBBackupDir {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    if (Test-Path -LiteralPath (Join-Path $Path 'manifest.json')) { return (Resolve-Path -LiteralPath $Path).Path }
    $c = Get-ChildItem -LiteralPath $Path -Directory -Filter 'ResetBack-*' -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'manifest.json') } |
        Sort-Object Name -Descending | Select-Object -First 1
    if ($c) { return $c.FullName }
    return $null
}

function Write-RBSystemInfo {
    param([string]$Path)
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add("reset_back_system $($Global:RB.Version) - $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
    [void]$lines.Add("Computer : $env:COMPUTERNAME / User: $env:USERNAME")
    [void]$lines.Add("OS       : $(Get-RBOsName)")
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        [void]$lines.Add("Model    : $($cs.Manufacturer) $($cs.Model)")
        [void]$lines.Add(('RAM      : {0:N1} GB' -f ($cs.TotalPhysicalMemory / 1GB)))
        foreach ($c in @(Get-CimInstance Win32_Processor -ErrorAction Stop)) { [void]$lines.Add("CPU      : $($c.Name.Trim())") }
        foreach ($g in @(Get-CimInstance Win32_VideoController -ErrorAction Stop)) { [void]$lines.Add("GPU      : $($g.Name) ($($g.DriverVersion))") }
        $bios = Get-CimInstance Win32_BIOS -ErrorAction Stop
        [void]$lines.Add("BIOS     : $($bios.Manufacturer) $($bios.SMBIOSBIOSVersion)")
        foreach ($d in @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop)) {
            [void]$lines.Add(('Disk {0}  : {1:N0} GB, free {2:N0} GB ({3})' -f $d.DeviceID, ($d.Size / 1GB), ($d.FreeSpace / 1GB), $d.FileSystem))
        }
    } catch { }
    [IO.File]::WriteAllLines($Path, [string[]]$lines.ToArray(), [Text.Encoding]::UTF8)
}

function New-RBManifestEntry {
    param($Item)
    return @{
        id = $Item.Id; provider = $Item.Provider; category = $Item.Category
        name = $Item.Name; nameKey = $Item.NameKey
        description = $Item.Description; descKey = $Item.DescKey; descArgs = @($Item.DescArgs)
        order = $Item.Order; sensitive = $Item.Sensitive; requiresAdmin = $Item.RequiresAdmin
        restoreSupported = $Item.RestoreSupported; processes = @($Item.Processes)
        data = $Item.Data; dir = $Item.Id; status = 'pending'; message = ''
    }
}

function Invoke-RBBackup {
    param([Parameter(Mandatory = $true)][object[]]$Items, [Parameter(Mandatory = $true)][string]$Target)
    $isAdmin = Test-RBAdmin
    $dry = [bool]$Global:RB.DryRun
    $stamp = Get-Date -Format 'yyyy-MM-dd_HHmm'
    $dir = Join-Path $Target "ResetBack-$stamp"
    $logDir = if ($dry) { Join-Path $env:TEMP 'reset_back_system' } else { $dir }
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $Global:RB.LogFile = Join-Path $logDir "backup-log-$stamp.txt"
    $Global:RB.SessionDir = $logDir

    Write-RBLog (T 'log.backup.start' $dir) 'step'
    if ($dry) { Write-RBLog (T 'log.dryrun') 'warn' }
    if (-not $isAdmin) { Write-RBLog (T 'log.not.admin') 'warn' }

    $manifest = [ordered]@{
        tool = 'reset_back_system'; formatVersion = $Global:RBManifestFormat; appVersion = $Global:RB.Version
        created = (Get-Date).ToString('o'); computer = $env:COMPUTERNAME; user = $env:USERNAME
        os = (Get-RBOsName); lang = $Global:RB.Lang; items = @()
    }
    $sorted = @($Items | Sort-Object Order, Name)
    $entries = New-Object System.Collections.ArrayList
    $ok = 0; $fail = 0; $skip = 0; $n = 0
    foreach ($it in $sorted) {
        $n++
        Set-RBProgress ($n - 1) $sorted.Count $it.Name
        Write-RBLog ('[{0}/{1}] {2}' -f $n, $sorted.Count, $it.Name) 'step'
        $entry = New-RBManifestEntry $it
        if ($it.RequiresAdmin -and -not $isAdmin) {
            $entry.status = 'skipped'; $entry.message = (T 'log.need.admin'); $skip++
            Write-RBLog (T 'log.need.admin') 'warn'
        } else {
            $itemDir = Join-Path $dir $it.Id
            try {
                if (-not $dry) { New-Item -ItemType Directory -Force -Path $itemDir | Out-Null }
                $prov = $Global:RB.Providers[$it.Provider]
                if (-not $prov) { throw (T 'err.provider' $it.Provider) }
                $res = @(& $prov.Backup $it $itemDir) | Where-Object { $_ -is [hashtable] } | Select-Object -Last 1
                if ($res) { foreach ($k in @($res.Keys)) { $entry.data[$k] = $res[$k] } }
                $entry.status = 'ok'; $ok++
                Write-RBLog (T 'log.item.ok') 'ok'
            } catch {
                $entry.status = 'failed'; $entry.message = $_.Exception.Message; $fail++
                Write-RBLog (T 'log.item.fail' $_.Exception.Message) 'error'
            }
        }
        [void]$entries.Add($entry)
        $manifest.items = $entries.ToArray()
        if (-not $dry) { Write-RBJsonFile $manifest (Join-Path $dir 'manifest.json') }
    }
    if (-not $dry) {
        try { Write-RBSystemInfo (Join-Path $dir 'system-info.txt') } catch { }
        try { [IO.File]::WriteAllText((Join-Path $dir 'README.txt'), (T 'backup.readme'), [Text.Encoding]::UTF8) } catch { }
    }
    Set-RBProgress $sorted.Count $sorted.Count (T 'status.done')
    Write-RBLog (T 'log.summary' $ok $fail $skip) 'step'
    if (-not $dry) { Write-RBLog (T 'log.backup.where' $dir) 'ok' }
    return [pscustomobject]@{ Dir = $dir; Ok = $ok; Failed = $fail; Skipped = $skip; LogFile = $Global:RB.LogFile; DryRun = $dry }
}

function Get-RBRestoreItems {
    param([Parameter(Mandatory = $true)][string]$Source)
    $dir = Resolve-RBBackupDir $Source
    if (-not $dir) { throw (T 'err.no.backup' $Source) }
    $m = Read-RBJsonFile (Join-Path $dir 'manifest.json')
    if ($m.tool -ne 'reset_back_system') { throw (T 'err.no.backup' $Source) }
    $items = New-Object System.Collections.ArrayList
    foreach ($e in @($m.items)) {
        if (-not $e -or $e.status -ne 'ok') { continue }
        if (-not $Global:RB.Providers.Contains([string]$e.provider)) { continue }
        $data = $e.data; if ($data -isnot [hashtable]) { $data = @{} }
        $it = New-RBItem -Id $e.id -Provider $e.provider -Category $e.category -Name ([string]$e.name) -NameKey ([string]$e.nameKey) `
            -Description ([string]$e.description) -DescKey ([string]$e.descKey) -DescArgs @($e.descArgs) -Order ([int]$e.order) `
            -Sensitive ([bool]$e.sensitive) -RequiresAdmin ([bool]$e.requiresAdmin) -RestoreSupported ([bool]$e.restoreSupported) `
            -Processes @($e.processes) -Data $data -DefaultSelected $true
        $it.BackupDir = Join-Path $dir ([string]$e.dir)
        $it.Size = Get-RBSize $it.BackupDir 1500
        # Sensitive items are selected on restore: the user already chose to back them up.
        $it.Selected = [bool]$e.restoreSupported
        [void]$items.Add($it)
    }
    return [pscustomobject]@{ Dir = $dir; Manifest = $m; Items = @($items | Sort-Object Order, Name) }
}

function Invoke-RBRestore {
    param([Parameter(Mandatory = $true)][object[]]$Items, [string]$BackupDir = '')
    $isAdmin = Test-RBAdmin
    $dry = [bool]$Global:RB.DryRun
    $stamp = Get-Date -Format 'yyyy-MM-dd_HHmm'
    $logDir = Join-Path $env:LOCALAPPDATA 'reset_back_system\logs'
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $Global:RB.LogFile = Join-Path $logDir "restore-log-$stamp.txt"
    $Global:RB.SessionDir = $logDir

    Write-RBLog (T 'log.restore.start' $BackupDir) 'step'
    if ($dry) { Write-RBLog (T 'log.dryrun') 'warn' }
    if (-not $isAdmin) { Write-RBLog (T 'log.not.admin') 'warn' }

    $sorted = @($Items | Sort-Object Order, Name)
    $ok = 0; $fail = 0; $skip = 0; $n = 0
    foreach ($it in $sorted) {
        $n++
        Set-RBProgress ($n - 1) $sorted.Count $it.Name
        Write-RBLog ('[{0}/{1}] {2}' -f $n, $sorted.Count, $it.Name) 'step'
        if (-not $it.RestoreSupported) { Write-RBLog (T 'log.restore.unsupported') 'warn'; $skip++; continue }
        if ($it.RequiresAdmin -and -not $isAdmin) { Write-RBLog (T 'log.need.admin') 'warn'; $skip++; continue }
        $running = @(Get-RBRunningProcesses $it.Processes)
        if ($running.Count -and -not $Global:RB.Options.Force -and -not $dry) {
            Write-RBLog (T 'log.app.running' ($running -join ', ')) 'warn'; $skip++; continue
        }
        try {
            $prov = $Global:RB.Providers[$it.Provider]
            if (-not $prov) { throw (T 'err.provider' $it.Provider) }
            if (-not $prov.Restore) { throw (T 'log.restore.unsupported') }
            if (-not (Test-Path -LiteralPath $it.BackupDir)) { throw (T 'log.missing' $it.BackupDir) }
            [void]@(& $prov.Restore $it $it.BackupDir)
            $ok++
            Write-RBLog (T 'log.item.ok') 'ok'
        } catch {
            $fail++
            Write-RBLog (T 'log.item.fail' $_.Exception.Message) 'error'
        }
    }
    Set-RBProgress $sorted.Count $sorted.Count (T 'status.done')
    Write-RBLog (T 'log.summary' $ok $fail $skip) 'step'
    if (-not $dry) { Write-RBLog (T 'log.restore.reboot') 'info' }
    Write-RBLog (T 'log.logfile' $Global:RB.LogFile) 'info'
    return [pscustomobject]@{ Dir = $BackupDir; Ok = $ok; Failed = $fail; Skipped = $skip; LogFile = $Global:RB.LogFile; DryRun = $dry }
}
