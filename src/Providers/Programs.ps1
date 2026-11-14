# Provider: installed programs.
# Backup : full inventory from the registry + package list from "winget export",
#          completed with catalog\winget-map.json for programs export could not
#          match (per-user installs, Store apps when the msstore source is off).
# Restore: installs the chosen packages ONE BY ONE with "winget install", checks
#          every exit code, never touches App Installer itself, then reports the
#          programs that are still missing so the user can install them by hand.

# Entries of the "manual install" list that are drivers, runtimes or components
# installed by other programs; they only add noise.
$Global:RBProgramNoise = @(
    '^Microsoft Visual C\+\+', '^Microsoft \.NET', '^Microsoft ASP\.NET', '^Microsoft Windows Desktop Runtime', 'Runtime\b',
    '^Windows Software Development Kit', '^Windows SDK', '\bSDK\b', '^vs_', '^Update for ', 'Redistributable',
    '^Microsoft Edge', '^Microsoft Update Health', '^Windows PC Health', '^Microsoft OneDrive$', '^Microsoft GameInput',
    'Application Compatibility', '\bDriver\b', 'S.r.c.s.', 'Treiber', '\bPhysX\b', 'FrameView', 'Online Services$',
    '\bService$', 'Vanguard$', '^NVIDIA (HD Audio|Graphics|USBC|Control Panel)', '^Realtek ', '^Intel\(R\) ', '^AMD (Software|Chipset)',
    '^(Canon|HP|Epson|EPSON|Brother|Samsung|Xerox|Kyocera|Ricoh|Lexmark) .*(LBP|MF\d|i-SENSYS|PIXMA|LaserJet|DeskJet|OfficeJet|ENVY|Smart Tank|L\d{3,}|DCP|MFC|HL-|ML-|SCX|WorkCentre|ECOSYS)',
    '^Microsoft (Teams Meeting Add-in|Office Click-to-Run|Update Health)'
)

# winget exit codes that mean "fine"
$Global:RBWingetOk = @{
    0             = 'ok'
    -1978335189   = 'already'   # 0x8A15002B no applicable upgrade (already installed)
    -1978335135   = 'already'   # 0x8A150061 package already installed
    -1978334967   = 'reboot'    # 0x8A150109 installed, reboot required
    -1978334966   = 'reboot'    # 0x8A15010A installed, reboot required to finish
    3010          = 'reboot'
}

function Get-RBInstalledPrograms {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $seen = @{}
    $list = New-Object System.Collections.ArrayList
    foreach ($k in $keys) {
        foreach ($e in @(Get-ItemProperty -Path $k -ErrorAction SilentlyContinue)) {
            if (-not $e.DisplayName) { continue }
            if ($e.SystemComponent -eq 1) { continue }
            if ($e.ParentKeyName) { continue }
            if (@('Update', 'Hotfix', 'Security Update') -contains $e.ReleaseType) { continue }
            $name = ([string]$e.DisplayName).Trim()
            if ($seen.ContainsKey($name)) { continue }
            $seen[$name] = $true
            [void]$list.Add([pscustomobject]@{ Name = $name; Version = ([string]$e.DisplayVersion).Trim(); Publisher = ([string]$e.Publisher).Trim() })
        }
    }
    return @($list | Sort-Object Name)
}

function ConvertTo-RBProgramKey {
    param([string]$Name)
    $n = $Name.ToLowerInvariant()
    $n = [regex]::Replace($n, '\(.*?\)', ' ')
    $n = [regex]::Replace($n, '\bv?\d+([.\-_]\d+)+\b', ' ')
    $n = [regex]::Replace($n, '\b(x64|x86|64-bit|32-bit|amd64|arm64)\b', ' ')
    $n = [regex]::Replace($n, '[^\p{L}\p{Nd}]+', ' ')
    return ($n.Trim() -replace '\s+', ' ')
}

function Test-RBProgramNoise {
    param([string]$Name)
    foreach ($rx in $Global:RBProgramNoise) { if ($Name -match $rx) { return $true } }
    return $false
}

# "Name Version" without repeating the version when the name already has it.
function Format-RBProgramLine {
    param($Program)
    $n = ([string]$Program.Name).Trim()
    $v = ([string]$Program.Version).Trim()
    if ($v -and $n.IndexOf($v, [StringComparison]::OrdinalIgnoreCase) -lt 0) { return "$n $v" }
    return $n
}

function Get-RBWinget {
    $c = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $p = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (Test-Path -LiteralPath $p) { return $p }
    return $null
}

# On a fresh Windows, winget appears only after App Installer is registered for the user.
function Initialize-RBWinget {
    $wg = Get-RBWinget
    if ($wg) { return $wg }
    Write-RBLog (T 'log.winget.register')
    try { Add-AppxPackage -RegisterByFamilyName -MainPackage 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe' -ErrorAction Stop } catch { }
    for ($i = 0; $i -lt 10 -and -not $wg; $i++) { Start-Sleep -Seconds 2; $wg = Get-RBWinget }
    return $wg
}

function Get-RBWingetMap {
    try { return (Read-RBJsonText (Get-RBResourceText 'catalog\winget-map.json')) } catch { return @{ map = @(); never = @(); defaultOff = @() } }
}

function Test-RBLike {
    param([string]$Value, [object[]]$Patterns)
    foreach ($w in @($Patterns)) { if ($w -and $Value -like $w) { return $true } }
    return $false
}

function Get-RBWingetPackageCount {
    param([string]$JsonPath)
    try {
        $j = Read-RBJsonFile $JsonPath
        $n = 0
        foreach ($s in @($j.Sources)) { $n += @($s.Packages).Count }
        return $n
    } catch { return 0 }
}

# Installed package ids according to "winget list" (an id is installed when it appears in a line).
function Get-RBWingetListLines {
    $wg = Get-RBWinget
    if (-not $wg) { return @() }
    $r = Invoke-RBExe $wg 'list --accept-source-agreements --disable-interactivity' -TimeoutSec 300 -Utf8
    return @($r.Output -split "`r?`n")
}

function Find-RBNameInList {
    param([string[]]$Lines, [string]$Id)
    $rx = '^\s*(?<name>\S.*?)\s+' + [regex]::Escape($Id) + '(\s|$)'
    foreach ($l in $Lines) {
        $m = [regex]::Match($l, $rx)
        if ($m.Success) { return $m.Groups['name'].Value.Trim() }
    }
    return $null
}

function Test-RBMsStoreSource {
    $wg = Get-RBWinget
    if (-not $wg) { return $false }
    $r = Invoke-RBExe $wg 'source list --disable-interactivity' -TimeoutSec 60 -Utf8
    return ($r.Output -match '(?m)^\s*msstore\s')
}

function Enable-RBMsStoreSource {
    if (Test-RBMsStoreSource) { return $true }
    $wg = Get-RBWinget
    Write-RBLog (T 'log.msstore.adding')
    [void](Invoke-RBExe $wg 'source add --name msstore --arg https://storeedgefd.dsx.mp.microsoft.com/v9.0 --type Microsoft.Rest --accept-source-agreements --disable-interactivity' -TimeoutSec 120 -Utf8)
    return (Test-RBMsStoreSource)
}

# Builds the package list: winget export ids + catalog map matches from the
# inventory, without App Installer and other components that must never be installed.
function Get-RBProgramPackages {
    param([string]$JsonPath, [object[]]$Inventory, [string[]]$ListLines, [hashtable]$KnownNames = @{})
    $map = Get-RBWingetMap
    $byId = @{}
    $list = New-Object System.Collections.ArrayList
    if ($JsonPath -and (Test-Path -LiteralPath $JsonPath)) {
        $j = Read-RBJsonFile $JsonPath
        foreach ($s in @($j.Sources)) {
            $src = [string]$s.SourceDetails.Name
            if (-not $src) { $src = 'winget' }
            foreach ($p in @($s.Packages)) {
                $id = [string]$p.PackageIdentifier
                if (-not $id -or $byId.ContainsKey($id) -or (Test-RBLike $id $map.never)) { continue }
                $pk = @{ id = $id; name = $id; source = $src; mapped = $false }
                $byId[$id] = $pk; [void]$list.Add($pk)
            }
        }
    }
    foreach ($prog in @($Inventory)) {
        foreach ($m in @($map.map)) {
            $mm = [regex]::Match([string]$prog.Name, [string]$m.match)
            if (-not $mm.Success) { continue }
            $id = [string]$m.id
            if ($mm.Groups.Count -gt 1) { $id = $id.Replace('$1', $mm.Groups[1].Value) }
            if (-not $byId.ContainsKey($id)) {
                $pk = @{ id = $id; name = [string]$prog.Name; source = [string]$m.source; mapped = $true }
                $byId[$id] = $pk; [void]$list.Add($pk)
            }
            break
        }
    }
    foreach ($pk in $list) {
        if ($KnownNames.ContainsKey($pk.id) -and $KnownNames[$pk.id] -and $KnownNames[$pk.id] -ne $pk.id) { $pk.name = $KnownNames[$pk.id]; continue }
        if ($pk.name -eq $pk.id -and $ListLines) {
            $n = Find-RBNameInList $ListLines $pk.id
            if ($n) { $pk.name = $n }
        }
    }
    return @($list | Sort-Object { $_.name })
}

function Get-RBDefaultOffIds {
    param([object[]]$Packages)
    $map = Get-RBWingetMap
    return @(@($Packages) | Where-Object { Test-RBLike $_.id $map.defaultOff } | ForEach-Object { $_.id })
}

# Writes a winget import file for the given packages (kept for compatibility / manual use).
function Write-RBWingetFile {
    param([object[]]$Packages, [string]$Path)
    $sources = @()
    foreach ($src in @('winget', 'msstore')) {
        $pk = @(@($Packages) | Where-Object { $_.source -eq $src })
        if (-not $pk.Count) { continue }
        $det = if ($src -eq 'msstore') {
            @{ Name = 'msstore'; Identifier = 'StoreEdgeFD'; Argument = 'https://storeedgefd.dsx.mp.microsoft.com/v9.0'; Type = 'Microsoft.Rest' }
        } else {
            @{ Name = 'winget'; Identifier = 'Microsoft.Winget.Source_8wekyb3d8bbwe'; Argument = 'https://cdn.winget.microsoft.com/cache'; Type = 'Microsoft.PreIndexed.Package' }
        }
        $sources += @{ SourceDetails = $det; Packages = @($pk | ForEach-Object { @{ PackageIdentifier = $_.id } }) }
    }
    Write-RBJsonFile ([ordered]@{ '$schema' = 'https://aka.ms/winget-packages.schema.2.0.json'; CreationDate = (Get-Date).ToString('o'); Sources = $sources; WinGetVersion = '' }) $Path
}

# Kept for older callers/tests: copy a winget export keeping only non-excluded packages.
function Write-RBWingetSubset {
    param([string]$Source, [string]$Destination, [string[]]$Exclude)
    $j = Read-RBJsonFile $Source
    foreach ($s in @($j.Sources)) {
        $s.Packages = @(@($s.Packages) | Where-Object { $Exclude -notcontains $_.PackageIdentifier })
    }
    Write-RBJsonFile $j $Destination
}

function Get-RBProgramSkipKeys {
    param([string[]]$Names)
    return @($Names | Where-Object { $_ } | ForEach-Object { ConvertTo-RBProgramKey ($_ -replace [char]0x2026, '') } | Where-Object { $_.Length -ge 3 })
}

# Applies include/exclude patterns (wildcards, matched against id and name).
function Set-RBProgramFilter {
    param([object[]]$Items, [string[]]$Include, [string[]]$Exclude)
    $Include = @($Include | ForEach-Object { ([string]$_) -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $Exclude = @($Exclude | ForEach-Object { ([string]$_) -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if (-not $Include.Count -and -not $Exclude.Count) { return }
    foreach ($it in @($Items | Where-Object { $_.Data -and $_.Data.packages })) {
        $ex = New-Object System.Collections.ArrayList
        foreach ($p in @($it.Data.packages)) {
            $inc = $true
            if ($Include.Count) { $inc = $false; foreach ($w in $Include) { if ($p.id -like $w -or $p.name -like $w) { $inc = $true; break } } }
            foreach ($w in $Exclude) { if ($p.id -like $w -or $p.name -like $w) { $inc = $false; break } }
            if (-not $inc) { [void]$ex.Add($p.id) }
        }
        $it.Data.exclude = $ex.ToArray()
    }
}

# Compares the old inventory with what is installed now; returns the missing ones.
function Get-RBMissingPrograms {
    param([string]$CsvPath, [string[]]$SkipNames)
    if (-not (Test-Path -LiteralPath $CsvPath)) { return @() }
    $old = @(Import-Csv -LiteralPath $CsvPath -Encoding UTF8)
    $now = @{}
    foreach ($p in Get-RBInstalledPrograms) { $now[(ConvertTo-RBProgramKey $p.Name)] = $true }
    $skip = @(Get-RBProgramSkipKeys $SkipNames)
    return @($old | Where-Object {
            $nm = [string]$_.Name
            $key = ConvertTo-RBProgramKey $nm
            $drop = (Test-RBProgramNoise $nm) -or (-not $key) -or $now.ContainsKey($key)
            if (-not $drop) {
                foreach ($sk in $skip) { if ($key -eq $sk -or $key.StartsWith($sk) -or $sk.StartsWith($key)) { $drop = $true; break } }
            }
            -not $drop
        })
}

Register-RBProvider @{
    Name           = 'programs'
    Discover       = {
        $inv = @(Get-RBInstalledPrograms)
        $wg = Get-RBWinget
        $descKey = if ($wg) { 'item.programs.desc' } else { 'item.programs.desc.nowinget' }
        $pk = @()
        if ($wg) {
            Write-RBLog (T 'log.winget.reading')
            $tmp = Join-Path $env:TEMP ('rb-wg-' + [guid]::NewGuid().ToString('N') + '.json')
            [void](Invoke-RBExe $wg ('export -o "{0}" --accept-source-agreements --disable-interactivity' -f $tmp) -TimeoutSec 300 -Utf8)
            $pk = @(Get-RBProgramPackages -JsonPath $tmp -Inventory $inv -ListLines (Get-RBWingetListLines))
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        } else {
            $pk = @(Get-RBProgramPackages -Inventory $inv)
        }
        New-RBItem -Id 'programs.winget' -Provider 'programs' -Category 'programs' -NameKey 'item.programs.name' `
            -DescKey $descKey -DescArgs @($inv.Count, $pk.Count) -Order 30 -Data @{ count = $inv.Count; packages = $pk; exclude = @() }
    }
    Backup         = {
        param($Item, $Dir)
        $ErrorActionPreference = 'Continue'
        $inv = @(Get-RBInstalledPrograms)
        $ex = @($Item.Data.exclude | Where-Object { $_ })
        if ($Global:RB.DryRun) {
            Write-RBLog (T 'log.programs.dry' $inv.Count)
            if ($ex.Count) { Write-RBLog (T 'log.winget.excluded' $ex.Count) }
            return
        }
        $inv | Export-Csv -LiteralPath (Join-Path $Dir 'installed-programs.csv') -NoTypeInformation -Encoding UTF8
        [IO.File]::WriteAllLines((Join-Path $Dir 'installed-programs.txt'),
            [string[]]@($inv | ForEach-Object { '{0} | {1} | {2}' -f $_.Name, $_.Version, $_.Publisher }), [Text.Encoding]::UTF8)
        Write-RBLog (T 'log.programs.inventory' $inv.Count) 'ok'

        $wg = Get-RBWinget
        $raw = Join-Path $Dir 'winget-export-raw.json'
        if ($wg) {
            if (-not (Test-RBMsStoreSource)) { [void](Enable-RBMsStoreSource) }
            Write-RBLog (T 'log.winget.exporting')
            $r = Invoke-RBExe $wg ('export -o "{0}" --accept-source-agreements --disable-interactivity' -f $raw) -TimeoutSec 600 -Utf8
            [IO.File]::WriteAllText((Join-Path $Dir 'winget-export-output.txt'), $r.Output, [Text.Encoding]::UTF8)
        } else {
            Write-RBLog (T 'log.winget.missing') 'warn'
        }
        $names = @{}
        foreach ($p in @($Item.Data.packages)) { if ($p.id) { $names[$p.id] = $p.name } }
        $all = @(Get-RBProgramPackages -JsonPath $raw -Inventory $inv -KnownNames $names -ListLines $(if ($wg) { Get-RBWingetListLines } else { @() }))
        $kept = @($all | Where-Object { $ex -notcontains $_.id })
        $dropped = @($all | Where-Object { $ex -contains $_.id })
        Write-RBWingetFile $kept (Join-Path $Dir 'winget.json')
        if ($dropped.Count) { Write-RBLog (T 'log.winget.excluded' $dropped.Count) }
        $mapped = @($kept | Where-Object { $_.mapped }).Count
        if ($mapped) { Write-RBLog (T 'log.winget.mapped' $mapped) }
        Write-RBLog (T 'log.winget.exported' $kept.Count) 'ok'
        $res = @{ winget = [bool]$wg; wingetPackages = $kept.Count; packages = $kept; exclude = @(); excludedNames = @($dropped | ForEach-Object { $_.name }) }
        if (-not $wg) { $res.status = 'warn' }
        return $res
    }
    # Called when a backup is opened: rebuilds the package list from the files that
    # are really in the backup (winget.json may have been edited by hand) and from
    # the inventory through the catalog map (helps older backups too).
    PrepareRestore = {
        param($Item, $Dir)
        $names = @{}
        foreach ($p in @($Item.Data.packages)) { if ($p.id) { $names[$p.id] = $p.name } }
        $inv = @()
        $csv = Join-Path $Dir 'installed-programs.csv'
        if (Test-Path -LiteralPath $csv) { $inv = @(Import-Csv -LiteralPath $csv -Encoding UTF8) }
        $pk = @(Get-RBProgramPackages -JsonPath (Join-Path $Dir 'winget.json') -Inventory $inv -KnownNames $names)
        # packages left out at backup time stay out even if the map would find them again
        $left = @($Item.Data.excludedNames | Where-Object { $_ })
        if ($left.Count) { $pk = @($pk | Where-Object { -not ($_.mapped -and ($left -contains $_.name)) }) }
        $Item.Data.packages = $pk
        $Item.Data.wingetPackages = $pk.Count
        $Item.Data.exclude = @(Get-RBDefaultOffIds $pk)
        if (@($Item.DescArgs).Count -ge 2) { $Item.DescArgs = @(@($Item.DescArgs)[0], $pk.Count) }
    }
    Restore        = {
        param($Item, $Dir)
        $ErrorActionPreference = 'Continue'
        $warn = $false
        $ex = @($Item.Data.exclude | Where-Object { $_ })
        $map = Get-RBWingetMap
        $pk = @(@($Item.Data.packages) | Where-Object { $_ -and $_.id -and ($ex -notcontains $_.id) -and -not (Test-RBLike $_.id $map.never) })
        $skipNames = @($Item.Data.excludedNames) + @(@($Item.Data.packages) | Where-Object { $ex -contains $_.id } | ForEach-Object { $_.name })
        $failed = New-Object System.Collections.ArrayList

        if ($pk.Count) {
            Write-RBLog (T 'log.winget.selected' $pk.Count @($Item.Data.packages).Count)
            $wg = if ($Global:RB.DryRun) { Get-RBWinget } else { Initialize-RBWinget }
            if (-not $wg) {
                Write-RBLog (T 'err.winget.missing') 'warn'
                $warn = $true
            } elseif ($Global:RB.DryRun) {
                foreach ($p in $pk) { Write-RBLog ('    [{0}] {1}  ({2})' -f $p.source, $p.name, $p.id) }
                Write-RBLog (T 'log.dry.winget' $pk.Count)
            } else {
                if (@($pk | Where-Object { $_.source -eq 'msstore' }).Count -and -not (Enable-RBMsStoreSource)) { Write-RBLog (T 'log.msstore.off') 'warn' }
                [void](Invoke-RBExe $wg 'source update --disable-interactivity' -TimeoutSec 300 -Utf8)
                $lines = @(Get-RBWingetListLines)
                $okN = 0; $already = 0; $reboot = $false; $i = 0
                foreach ($p in $pk) {
                    $i++
                    if (Find-RBNameInList $lines $p.id) {
                        $already++
                        Write-RBLog ('    ({0}/{1}) = {2}' -f $i, $pk.Count, (T 'log.winget.already' $p.name))
                        continue
                    }
                    Write-RBLog ('    ({0}/{1}) {2}' -f $i, $pk.Count, (T 'log.winget.installing' $p.name))
                    $wargs = 'install --id "{0}" --exact --source {1} --accept-package-agreements --accept-source-agreements --disable-interactivity --silent' -f $p.id, $p.source
                    $r = Invoke-RBExe $wg $wargs -TimeoutSec 1800 -Utf8
                    $kind = $Global:RBWingetOk[[int]$r.Code]
                    if ($kind -eq 'already') { $already++; Write-RBLog ('          ' + (T 'log.winget.already' $p.name)) }
                    elseif ($kind) {
                        $okN++
                        if ($kind -eq 'reboot') { $reboot = $true }
                        Write-RBLog ('          ' + (T 'log.winget.installed' $p.name)) 'ok'
                    } else {
                        $why = if ($r.TimedOut) { T 'log.winget.timeout' } else {
                            $l = @(($r.Output -split "`r?`n") | ForEach-Object { $_.Trim() } | Where-Object { $_.Length -gt 3 -and $_ -notmatch ('[' + [char]0x2580 + '-' + [char]0x259F + ']') -and $_ -notmatch '^[\-\\|/ ]+$' })
                            if ($l.Count) { $l[-1] } else { '' }
                        }
                        [void]$failed.Add($p)
                        Write-RBLog ('          ' + (T 'log.winget.failed' $p.name ('0x{0:X8}' -f [int]$r.Code) $why)) 'warn'
                    }
                }
                Write-RBLog (T 'log.winget.summary' $okN $already $failed.Count) $(if ($failed.Count) { 'warn' } else { 'ok' })
                if ($reboot) { Write-RBLog (T 'log.winget.reboot') }
                if ($failed.Count) { $warn = $true }
            }
        } else {
            Write-RBLog (T 'log.winget.none')
        }

        $missing = @(Get-RBMissingPrograms (Join-Path $Dir 'installed-programs.csv') $skipNames)
        if ($missing.Count) {
            Write-RBLog (T 'log.programs.manual' $missing.Count) 'warn'
            foreach ($m in $missing) { Write-RBLog ('    - ' + (Format-RBProgramLine $m)) 'warn' }
            if ($Global:RB.SessionDir) {
                $stamp = if ($Global:RB.SessionStamp) { $Global:RB.SessionStamp } else { Get-Date -Format 'yyyy-MM-dd_HHmmss' }
                $f = Join-Path $Global:RB.SessionDir "missing-programs-$stamp.txt"
                [IO.File]::WriteAllLines($f, [string[]]@($missing | ForEach-Object { '{0} | {1}' -f (Format-RBProgramLine $_), $_.Publisher }), [Text.Encoding]::UTF8)
                Write-RBLog (T 'log.programs.manual.file' $f)
            }
            $warn = $true
        } elseif (Test-Path -LiteralPath (Join-Path $Dir 'installed-programs.csv')) {
            Write-RBLog (T 'log.programs.allok') 'ok'
        }
        if ($warn) { return @{ status = 'warn' } }
    }
}
