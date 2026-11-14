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

Register-RBProvider @{
    Name     = 'programs'
    Discover = {
        $count = @(Get-RBInstalledPrograms).Count
        $descKey = if (Get-RBWinget) { 'item.programs.desc' } else { 'item.programs.desc.nowinget' }
        New-RBItem -Id 'programs.winget' -Provider 'programs' -Category 'programs' -NameKey 'item.programs.name' `
            -DescKey $descKey -DescArgs @($count) -Order 30 -Data @{ count = $count }
    }
    Backup   = {
        param($Item, $Dir)
        $ErrorActionPreference = 'Continue'
        $inv = @(Get-RBInstalledPrograms)
        $wg = Get-RBWinget
        if ($Global:RB.DryRun) {
            Write-RBLog (T 'log.programs.dry' $inv.Count)
            return
        }
        $inv | Export-Csv -LiteralPath (Join-Path $Dir 'installed-programs.csv') -NoTypeInformation -Encoding UTF8
        [IO.File]::WriteAllLines((Join-Path $Dir 'installed-programs.txt'),
            [string[]]@($inv | ForEach-Object { '{0} | {1} | {2}' -f $_.Name, $_.Version, $_.Publisher }), [Text.Encoding]::UTF8)
        Write-RBLog (T 'log.programs.inventory' $inv.Count) 'ok'
        if (-not $wg) {
            Write-RBLog (T 'log.winget.missing') 'warn'
            return @{ winget = $false }
        }
        $json = Join-Path $Dir 'winget.json'
        Write-RBLog (T 'log.winget.exporting')
        $out = & $wg export -o $json --accept-source-agreements --disable-interactivity 2>&1
        [IO.File]::WriteAllText((Join-Path $Dir 'winget-export-output.txt'), ($out | Out-String), [Text.Encoding]::UTF8)
        if (-not (Test-Path -LiteralPath $json)) { throw (T 'err.winget.export') }
        $n = Get-RBWingetPackageCount $json
        Write-RBLog (T 'log.winget.exported' $n) 'ok'
        return @{ winget = $true; wingetPackages = $n }
    }
    Restore  = {
        param($Item, $Dir)
        $ErrorActionPreference = 'Continue'
        $json = Join-Path $Dir 'winget.json'
        if (Test-Path -LiteralPath $json) {
            $wg = Get-RBWinget
            if (-not $wg) { throw (T 'err.winget.missing') }
            $n = Get-RBWingetPackageCount $json
            if ($Global:RB.DryRun) {
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
            $missing = @($old | Where-Object {
                    $nm = $_.Name
                    $noise = $false
                    foreach ($rx in $Global:RBProgramNoise) { if ($nm -match $rx) { $noise = $true; break } }
                    (-not $noise) -and (-not $now.ContainsKey((ConvertTo-RBProgramKey $nm)))
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
