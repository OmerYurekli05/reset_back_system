# Provider: installed programs.
# Backup : full inventory from the registry + "winget export" list.
# Restore: "winget import" (latest versions), then reports programs that are
#          still missing so the user can install them by hand.

$Global:RBProgramNoise = @(
    '^Microsoft Visual C\+\+', '^Microsoft \.NET', '^Microsoft ASP\.NET', '^Windows Software Development Kit',
    '^Microsoft Edge', '^Microsoft Update Health', '^Windows PC Health', '^Microsoft Windows Desktop Runtime',
    '^Windows SDK', '^vs_', '^Microsoft OneDrive$', '^Update for '
)

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
            [void]$list.Add([pscustomobject]@{ Name = $name; Version = [string]$e.DisplayVersion; Publisher = [string]$e.Publisher })
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

function Get-RBWinget {
    $c = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $p = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (Test-Path -LiteralPath $p) { return $p }
    return $null
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

# Reads the package ids from a winget export file (or makes a temporary export)
# and takes the display names from "winget list" by locating each id in its lines,
# which works whatever the system language is.
function Get-RBWingetPackages {
    param([string]$JsonPath)
    $ErrorActionPreference = 'Continue'
    $wg = Get-RBWinget
    if (-not $wg) { return @() }
    $tmp = $null
    if (-not $JsonPath) {
        $tmp = Join-Path $env:TEMP ('rb-wg-' + [guid]::NewGuid().ToString('N') + '.json')
        & $wg export -o $tmp --accept-source-agreements --disable-interactivity 2>&1 | Out-Null
        $JsonPath = $tmp
    }
    if (-not (Test-Path -LiteralPath $JsonPath)) { return @() }
    $list = New-Object System.Collections.ArrayList
    try {
        $j = Read-RBJsonFile $JsonPath
        foreach ($s in @($j.Sources)) {
            $src = [string]$s.SourceDetails.Name
            foreach ($p in @($s.Packages)) {
                if ($p.PackageIdentifier) { [void]$list.Add(@{ id = [string]$p.PackageIdentifier; name = [string]$p.PackageIdentifier; source = $src }) }
            }
        }
    } finally { if ($tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } }
    try {
        $lines = @(& $wg list --accept-source-agreements --disable-interactivity 2>&1 | ForEach-Object { [string]$_ })
        foreach ($p in $list) {
            $rx = '^\s*(?<name>\S.*?)\s+' + [regex]::Escape($p.id) + '(\s|$)'
            foreach ($l in $lines) {
                $m = [regex]::Match($l, $rx)
                if ($m.Success) { $p.name = $m.Groups['name'].Value.Trim(); break }
            }
        }
    } catch { }
    return @($list | Sort-Object { $_.name })
}

# Copies a winget export file keeping only the packages that are not excluded.
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

# Applies include/exclude patterns (wildcards, matched against id and name) to
# the package list of the programs item.
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

Register-RBProvider @{
    Name     = 'programs'
    Discover = {
        $count = @(Get-RBInstalledPrograms).Count
        $wg = Get-RBWinget
        $descKey = if ($wg) { 'item.programs.desc' } else { 'item.programs.desc.nowinget' }
        $pk = @()
        if ($wg) { Write-RBLog (T 'log.winget.reading'); $pk = @(Get-RBWingetPackages) }
        New-RBItem -Id 'programs.winget' -Provider 'programs' -Category 'programs' -NameKey 'item.programs.name' `
            -DescKey $descKey -DescArgs @($count, $pk.Count) -Order 30 -Data @{ count = $count; packages = $pk; exclude = @() }
    }
    Backup   = {
        param($Item, $Dir)
        $ErrorActionPreference = 'Continue'
        $inv = @(Get-RBInstalledPrograms)
        $wg = Get-RBWinget
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
        if (-not $wg) {
            Write-RBLog (T 'log.winget.missing') 'warn'
            return @{ winget = $false; packages = @(); exclude = @() }
        }
        $json = Join-Path $Dir 'winget.json'
        Write-RBLog (T 'log.winget.exporting')
        $out = & $wg export -o $json --accept-source-agreements --disable-interactivity 2>&1
        [IO.File]::WriteAllText((Join-Path $Dir 'winget-export-output.txt'), ($out | Out-String), [Text.Encoding]::UTF8)
        if (-not (Test-Path -LiteralPath $json)) { throw (T 'err.winget.export') }

        # names: reuse the ones found while scanning, fall back to the id
        $names = @{}
        foreach ($p in @($Item.Data.packages)) { if ($p.id) { $names[$p.id] = $p.name } }
        $all = New-Object System.Collections.ArrayList
        $j = Read-RBJsonFile $json
        foreach ($s in @($j.Sources)) {
            foreach ($p in @($s.Packages)) {
                $id = [string]$p.PackageIdentifier
                $nm = if ($names.ContainsKey($id)) { $names[$id] } else { $id }
                [void]$all.Add(@{ id = $id; name = $nm; source = [string]$s.SourceDetails.Name })
            }
        }
        $kept = @($all | Where-Object { $ex -notcontains $_.id })
        $dropped = @($all | Where-Object { $ex -contains $_.id })
        if ($dropped.Count) {
            Write-RBWingetSubset $json $json $ex
            Write-RBLog (T 'log.winget.excluded' $dropped.Count)
        }
        Write-RBLog (T 'log.winget.exported' $kept.Count) 'ok'
        return @{ winget = $true; wingetPackages = $kept.Count; packages = $kept; exclude = @(); excludedNames = @($dropped | ForEach-Object { $_.name }) }
    }
    Restore  = {
        param($Item, $Dir)
        $ErrorActionPreference = 'Continue'
        $json = Join-Path $Dir 'winget.json'
        $ex = @($Item.Data.exclude | Where-Object { $_ })
        $skipNames = @($Item.Data.excludedNames) + @(@($Item.Data.packages) | Where-Object { $ex -contains $_.id } | ForEach-Object { $_.name })
        if (Test-Path -LiteralPath $json) {
            $wg = Get-RBWinget
            if (-not $wg) { throw (T 'err.winget.missing') }
            $total = Get-RBWingetPackageCount $json
            if ($ex.Count) {
                $dir = if ($Global:RB.SessionDir) { $Global:RB.SessionDir } else { $env:TEMP }
                $sub = Join-Path $dir 'winget-selected.json'
                Write-RBWingetSubset $json $sub $ex
                $json = $sub
            }
            $n = Get-RBWingetPackageCount $json
            if ($ex.Count) { Write-RBLog (T 'log.winget.selected' $n $total) }
            if ($n -eq 0) {
                Write-RBLog (T 'log.winget.none')
            } elseif ($Global:RB.DryRun) {
                Write-RBLog (T 'log.dry.winget' $n)
            } else {
                Write-RBLog (T 'log.winget.importing' $n) 'step'
                & $wg source update --disable-interactivity 2>&1 | Out-Null
                & $wg import -i $json --accept-package-agreements --accept-source-agreements --ignore-unavailable --disable-interactivity 2>&1 | ForEach-Object {
                    $line = ([string]$_).Trim()
                    if ($line.Length -gt 2 -and $line -notmatch ('[' + [char]0x2580 + '-' + [char]0x259F + ']') -and $line -notmatch '^[\-\\|/ ]+$') { Write-RBLog ('    ' + $line) }
                }
            }
        }
        $csv = Join-Path $Dir 'installed-programs.csv'
        if (Test-Path -LiteralPath $csv) {
            $old = @(Import-Csv -LiteralPath $csv -Encoding UTF8)
            $now = @{}
            foreach ($p in Get-RBInstalledPrograms) { $now[(ConvertTo-RBProgramKey $p.Name)] = $true }
            $skip = @(Get-RBProgramSkipKeys $skipNames)
            $missing = @($old | Where-Object {
                    $nm = $_.Name
                    $key = ConvertTo-RBProgramKey $nm
                    $noise = $false
                    foreach ($rx in $Global:RBProgramNoise) { if ($nm -match $rx) { $noise = $true; break } }
                    if ($key) {
                        foreach ($sk in $skip) { if ($key -eq $sk -or $key.StartsWith($sk) -or $sk.StartsWith($key)) { $noise = $true; break } }
                    }
                    (-not $noise) -and (-not $now.ContainsKey($key))
                })
            if ($missing.Count) {
                Write-RBLog (T 'log.programs.manual' $missing.Count) 'warn'
                foreach ($m in $missing) { Write-RBLog ('    - {0} {1}' -f $m.Name, $m.Version) 'warn' }
                if ($Global:RB.SessionDir) {
                    $f = Join-Path $Global:RB.SessionDir 'missing-programs.txt'
                    [IO.File]::WriteAllLines($f, [string[]]@($missing | ForEach-Object { '{0} | {1} | {2}' -f $_.Name, $_.Version, $_.Publisher }), [Text.Encoding]::UTF8)
                    Write-RBLog (T 'log.programs.manual.file' $f)
                }
            } else {
                Write-RBLog (T 'log.programs.allok') 'ok'
            }
        }
    }
}
