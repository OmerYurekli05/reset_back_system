# reset_back_system - self-contained test runner (no Pester needed).
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1 [-SkipDiscovery]
param([switch]$SkipDiscovery)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$Global:RB_ROOT = $root
$parts = @('src\Core.ps1', 'src\Engine.ps1') + @(Get-ChildItem (Join-Path $root 'src\Providers') -Filter *.ps1 | Sort-Object Name | ForEach-Object { 'src\Providers\' + $_.Name })
if (Test-Path (Join-Path $root 'src\Gui.ps1')) { $parts += 'src\Gui.ps1' }
$Global:RB_CODE = ($parts | ForEach-Object { [IO.File]::ReadAllText((Join-Path $root $_), [Text.Encoding]::UTF8) }) -join "`r`n"
. ([scriptblock]::Create($Global:RB_CODE))
Set-RBLanguage 'en'

$script:pass = 0
$script:fail = 0
function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try { & $Body; $script:pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    catch { $script:fail++; Write-Host "  FAIL  $Name : $($_.Exception.Message)" -ForegroundColor Red }
}
function Assert-True { param($Cond, [string]$Msg = 'assertion failed') if (-not $Cond) { throw $Msg } }
function Assert-Equal { param($A, $B, [string]$Msg = '') if ($A -ne $B) { throw "expected '$B' but got '$A' $Msg" } }

$tmp = Join-Path $env:TEMP ('rb-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $tmp | Out-Null
$Global:RB.LogSink = { param($l, $m) }   # keep test output quiet

Write-Host 'Static checks' -ForegroundColor Cyan

Test-Case 'all .ps1 files are ASCII-only (PS 5.1 encoding safety)' {
    $bad = @(Get-ChildItem $root -Recurse -Include *.ps1, *.xaml -File | Where-Object { $_.FullName -notmatch '\\dist\\' } | Where-Object {
            $bytes = [IO.File]::ReadAllBytes($_.FullName); @($bytes | Where-Object { $_ -gt 127 }).Count -gt 0 })
    Assert-True ($bad.Count -eq 0) ("non-ASCII: " + ($bad.Name -join ', '))
}

$tr = Read-RBJsonText (Get-RBResourceText 'lang\tr.json')
$en = Read-RBJsonText (Get-RBResourceText 'lang\en.json')

Test-Case 'tr.json and en.json have the same keys' {
    $a = @($tr.Keys | Sort-Object); $b = @($en.Keys | Sort-Object)
    $onlyTr = @($a | Where-Object { $b -notcontains $_ }); $onlyEn = @($b | Where-Object { $a -notcontains $_ })
    Assert-True ($onlyTr.Count -eq 0 -and $onlyEn.Count -eq 0) ("only tr: $($onlyTr -join ',') / only en: $($onlyEn -join ',')")
}

Test-Case 'every text key used in code exists in the language files' {
    $code = $Global:RB_CODE + (Get-Content -Raw (Join-Path $root 'ResetBack.ps1'))
    $used = @([regex]::Matches($code, "'((?:item|log|err|cli|gui|cat|status|msg|backup|badge)\.[a-z0-9.]+[a-z0-9])'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    $dyn = @('item.folder.desktop', 'item.folder.documents', 'item.folder.pictures', 'item.folder.downloads', 'item.folder.videos', 'item.folder.music') + @($Global:RBCategories | ForEach-Object { "cat.$_" })
    $missing = @(($used + $dyn) | Where-Object { -not $en.ContainsKey($_) })
    Assert-True ($missing.Count -eq 0) ("missing: " + ($missing -join ', '))
}

Test-Case 'apps catalog is valid' {
    $cat = @(Get-RBAppCatalog)
    Assert-True ($cat.Count -gt 5) 'catalog too small'
    $ids = @($cat | ForEach-Object { $_.id })
    Assert-Equal (@($ids | Sort-Object -Unique).Count) $ids.Count 'duplicate ids'
    foreach ($e in $cat) {
        Assert-True ($e.id -match '^[a-z0-9\-]+$') "bad id $($e.id)"
        Assert-True ($e.name) "no name: $($e.id)"
        Assert-True (@($e.paths).Count -gt 0) "no paths: $($e.id)"
        Assert-True ($e.note.tr -and $e.note.en) "note needs tr and en: $($e.id)"
    }
}

Test-Case 'editors catalog is valid' {
    $cat = @(Get-RBEditorCatalog)
    $ids = @($cat | ForEach-Object { $_.id })
    Assert-Equal (@($ids | Sort-Object -Unique).Count) $ids.Count 'duplicate ids'
    foreach ($e in $cat) { Assert-True (@($e.cli).Count -and @($e.userDir).Count -and $e.name) "incomplete: $($e.id)" }
}

Test-Case 'bundled profiles are valid' {
    foreach ($f in @(Get-ChildItem (Join-Path $root 'profiles') -Filter *.json)) {
        $p = Read-RBJsonFile $f.FullName
        Assert-Equal $p.tool 'reset_back_system' $f.Name
        Assert-True (@($p.items).Count -gt 0) "no items: $($f.Name)"
    }
}

Test-Case 'every resource the code reads is embedded by the build' {
    $build = Get-Content -Raw (Join-Path $root 'build\build.ps1')
    $used = @([regex]::Matches($Global:RB_CODE, "Get-RBResourceText '([^'`"]+)'") | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -notmatch '\$' } | Sort-Object -Unique)
    $missing = @($used | Where-Object { $build.IndexOf("'$_'") -lt 0 })
    Assert-True ($missing.Count -eq 0) ('not embedded: ' + ($missing -join ', '))
}

Test-Case 'winget map catalog is valid' {
    $m = Read-RBJsonText (Get-RBResourceText 'catalog\winget-map.json')
    Assert-True (@($m.map).Count -gt 20) 'map too small'
    foreach ($e in @($m.map)) {
        Assert-True ($e.match -and $e.id -and @('winget', 'msstore') -contains $e.source) "bad entry: $($e.id)"
        [void][regex]::new($e.match)
    }
    Assert-True (@($m.never) -contains 'Microsoft.AppInstaller') 'App Installer must be in never'
}

Write-Host 'Core' -ForegroundColor Cyan

Test-Case 'Expand-RBPath resolves tokens and env vars' {
    Assert-Equal (Expand-RBPath '%DOCUMENTS%\x') (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'x')
    Assert-Equal (Expand-RBPath '%appdata%\y') (Join-Path $env:APPDATA 'y')
    Assert-Equal (Expand-RBPath '%desktop%') ([Environment]::GetFolderPath('Desktop'))
}

Test-Case 'T formats arguments and falls back to the key' {
    Assert-Equal (T 'log.summary' 1 2 3) 'Finished. Succeeded: 1, failed: 2, skipped: 3'
    Assert-Equal (T 'no.such.key') 'no.such.key'
}

Test-Case 'JSON round trip keeps one-element arrays and nesting' {
    $f = Join-Path $tmp 'rt.json'
    $word = 'T' + [char]0xFC + 'rk' + [char]0xE7 + 'e'
    Write-RBJsonFile @{ a = @(1); b = @{ c = @(@{ d = 'x' }) }; s = $word } $f
    $r = Read-RBJsonFile $f
    Assert-Equal @($r.a).Count 1
    Assert-Equal @($r.b.c)[0].d 'x'
    Assert-Equal $r.s $word
}

Test-Case 'Copy-RBPath copies files and folders, NoOverwrite keeps existing' {
    $s = Join-Path $tmp 'src'; New-Item -ItemType Directory -Force (Join-Path $s 'sub') | Out-Null
    Set-Content (Join-Path $s 'a.txt') 'A'; Set-Content (Join-Path $s 'sub\b.txt') 'B'
    $d = Join-Path $tmp 'dst'
    Assert-True (Copy-RBPath $s $d)
    Assert-Equal (Get-Content (Join-Path $d 'sub\b.txt')) 'B'
    Set-Content (Join-Path $d 'a.txt') 'CHANGED'
    Assert-True (Copy-RBPath (Join-Path $s 'a.txt') (Join-Path $d 'a.txt') -NoOverwrite)
    Assert-Equal (Get-Content (Join-Path $d 'a.txt')) 'CHANGED'
    Assert-True (Copy-RBPath (Join-Path $s 'a.txt') (Join-Path $d 'a.txt'))
    Assert-Equal (Get-Content (Join-Path $d 'a.txt')) 'A'
}

Test-Case 'Copy-RBPath does nothing in dry-run' {
    $Global:RB.DryRun = $true
    try { Assert-True (Copy-RBPath (Join-Path $tmp 'src') (Join-Path $tmp 'dry')); Assert-True (-not (Test-Path (Join-Path $tmp 'dry'))) }
    finally { $Global:RB.DryRun = $false }
}

Test-Case 'Get-RBSize and Format-RBSize' {
    $sz = Get-RBSize (Join-Path $tmp 'src')
    Assert-True ($sz.Bytes -gt 0)
    Assert-Equal (Format-RBSize @{ Bytes = 1536; Partial = $false }) ((1.5).ToString('N1') + ' KB')
    Assert-Equal (Format-RBSize @{ Bytes = 10; Partial = $true }) '10 B+'
}

Test-Case 'Select-RBItems supports wildcards, comma lists and -All' {
    $items = @(
        (New-RBItem -Id 'a.one' -Provider x -Category apps),
        (New-RBItem -Id 'a.two' -Provider x -Category apps),
        (New-RBItem -Id 'b.one' -Provider x -Category apps -Sensitive $true)
    )
    Assert-Equal @(Select-RBItems -Items $items -Ids 'a.*').Count 2
    Assert-Equal @(Select-RBItems -Items $items -Ids 'b.one,a.two').Count 2
    Assert-Equal @(Select-RBItems -Items $items -All).Count 3
}

Write-Host 'End to end' -ForegroundColor Cyan

Test-Case 'backup -> damage -> restore brings catalog app data back' {
    $app = Join-Path $tmp 'fakeapp'
    New-Item -ItemType Directory -Force (Join-Path $app 'profiles') | Out-Null
    Set-Content (Join-Path $app 'profiles\p1.ini') 'level=42'
    Set-Content (Join-Path $app 'config.json') '{"x":1}'
    $catFile = Join-Path $tmp 'catalog.json'
    $entry = @(@{ id = 'fake'; name = 'Fake App'; paths = @((Join-Path $app 'profiles'), (Join-Path $app 'config.json'), (Join-Path $app 'missing')); note = @{ tr = 't'; en = 'e' } })
    Write-RBJsonFile $entry $catFile
    $Global:RB.CatalogOverride = $catFile
    try {
        $items = @(& $Global:RB.Providers['userdata.app'].Discover)
        Assert-Equal $items.Count 1 'discover'
        Assert-Equal @($items[0].Data.paths).Count 2 'only existing paths'
        $target = Join-Path $tmp 'backup'
        $r = Invoke-RBBackup -Items $items -Target $target
        Assert-Equal $r.Ok 1 'backup ok'
        Assert-True (Test-Path (Join-Path $r.Dir 'manifest.json')) 'manifest'

        Remove-Item (Join-Path $app 'profiles') -Recurse -Force
        Set-Content (Join-Path $app 'config.json') 'BROKEN'

        $info = Get-RBRestoreItems $target
        Assert-Equal $info.Items.Count 1 'restore items'
        $Global:RB.Options = @{ Overwrite = $true; Force = $false }
        $rr = Invoke-RBRestore -Items $info.Items -BackupDir $info.Dir
        Assert-Equal $rr.Ok 1 'restore ok'
        Assert-Equal (Get-Content (Join-Path $app 'profiles\p1.ini')) 'level=42'
        Assert-Equal (Get-Content (Join-Path $app 'config.json')) '{"x":1}'
    } finally { $Global:RB.CatalogOverride = $null }
}

Test-Case 'user environment backup/restore in dry-run changes nothing' {
    $before = Get-RBUserEnv
    $d = Join-Path $tmp 'env'; New-Item -ItemType Directory -Force $d | Out-Null
    $p = $Global:RB.Providers['system.envvars']
    & $p.Backup $null $d | Out-Null
    $Global:RB.DryRun = $true
    try { & $p.Restore $null $d | Out-Null } finally { $Global:RB.DryRun = $false }
    $after = Get-RBUserEnv
    Assert-Equal (@($after.Keys).Count) (@($before.Keys).Count)
}

Test-Case 'program name keys ignore versions and architecture' {
    Assert-Equal (ConvertTo-RBProgramKey '7-Zip 23.01 (x64)') (ConvertTo-RBProgramKey '7-Zip 24.08 (x64 edition)')
    Assert-Equal (ConvertTo-RBProgramKey 'Notepad++ (64-bit x64)') 'notepad'
}

Test-Case 'winget subset keeps only selected packages' {
    $src = Join-Path $tmp 'wg.json'
    $j = @{ '$schema' = 'x'; Sources = @(@{ SourceDetails = @{ Name = 'winget' }; Packages = @(@{ PackageIdentifier = 'A.One' }, @{ PackageIdentifier = 'B.Two' }, @{ PackageIdentifier = 'C.Three' }) }) }
    Write-RBJsonFile $j $src
    $dst = Join-Path $tmp 'wg-sub.json'
    Write-RBWingetSubset $src $dst @('B.Two', 'C.Three')
    Assert-Equal (Get-RBWingetPackageCount $dst) 1
    $r = Read-RBJsonFile $dst
    Assert-Equal @(@($r.Sources)[0].Packages)[0].PackageIdentifier 'A.One'
    Assert-True ($r.ContainsKey('$schema')) 'schema kept'
}

Test-Case 'program include/exclude filters and profiles' {
    $it = New-RBItem -Id 'programs.winget' -Provider programs -Category programs -Data @{ packages = @(
            @{ id = 'Valve.Steam'; name = 'Steam' }, @{ id = 'Google.Chrome'; name = 'Google Chrome' }, @{ id = 'Discord.Discord'; name = 'Discord' }); exclude = @() }
    Set-RBProgramFilter -Items @($it) -Exclude '*steam*'
    Assert-Equal (@($it.Data.exclude) -join ',') 'Valve.Steam'
    Set-RBProgramFilter -Items @($it) -Include 'Google*'
    Assert-Equal @($it.Data.exclude).Count 2
    $pf = Join-Path $tmp 'prof.json'
    Save-RBProfile @($it) $pf
    $it.Data.exclude = @()
    [void](Select-RBItems -Items @($it) -ProfilePath $pf)
    Assert-Equal @($it.Data.exclude).Count 2 'profile restores program exclusions'
}

Test-Case 'winget map adds programs export missed, never installs App Installer (issues 1, 3, 4)' {
    $json = Join-Path $tmp 'exp.json'
    Write-RBJsonFile @{ Sources = @(@{ SourceDetails = @{ Name = 'winget' }; Packages = @(@{ PackageIdentifier = 'VideoLAN.VLC' }, @{ PackageIdentifier = 'Microsoft.AppInstaller' }) }) } $json
    $inv = @(
        [pscustomobject]@{ Name = 'Google Chrome'; Version = '157'; Publisher = 'Google' },
        [pscustomobject]@{ Name = 'Discord'; Version = '1'; Publisher = 'Discord' },
        [pscustomobject]@{ Name = 'iCloud'; Version = '15'; Publisher = 'Apple' },
        [pscustomobject]@{ Name = 'Python 3.11.9 (64-bit)'; Version = '3.11.9'; Publisher = 'PSF' },
        [pscustomobject]@{ Name = 'VLC media player'; Version = '3'; Publisher = 'VideoLAN' }
    )
    $pk = @(Get-RBProgramPackages -JsonPath $json -Inventory $inv)
    $ids = @($pk | ForEach-Object { $_.id })
    foreach ($want in 'Google.Chrome', 'Discord.Discord', '9PKTQ5699M62', 'Python.Python.3.11', 'VideoLAN.VLC') { Assert-True ($ids -contains $want) "missing $want" }
    Assert-True ($ids -notcontains 'Microsoft.AppInstaller') 'App Installer must never be installed'
    Assert-Equal @($ids | Where-Object { $_ -eq 'VideoLAN.VLC' }).Count 1 'no duplicates'
    Assert-Equal (@($pk | Where-Object { $_.id -eq '9PKTQ5699M62' })[0].source) 'msstore'
    $wf = Join-Path $tmp 'wg-out.json'
    Write-RBWingetFile $pk $wf
    Assert-Equal (Get-RBWingetPackageCount $wf) $pk.Count 'winget.json matches the package list (issue 5)'
}

Test-Case 'Windows bundled apps are not selected by default on restore (issue 14)' {
    $pk = @(@{ id = 'Microsoft.Teams'; name = 'Teams' }, @{ id = 'Microsoft.Teams.Free'; name = 'Teams' }, @{ id = 'Microsoft.365Copilot'; name = 'Copilot' },
        @{ id = 'Microsoft.Outlook'; name = 'Outlook' }, @{ id = 'Google.Chrome'; name = 'Chrome' })
    $off = @(Get-RBDefaultOffIds $pk)
    Assert-Equal $off.Count 4
    Assert-True ($off -notcontains 'Google.Chrome')
}

Test-Case 'manual-install list drops drivers and components, no doubled versions (issues 6, 7)' {
    foreach ($n in 'NVIDIA FrameView SDK 1.9', ('NVIDIA HD Ses S' + [char]0xFC + 'r' + [char]0xFC + 'c' + [char]0xFC + 's' + [char]0xFC), ('NVIDIA PhysX Sistem Yaz' + [char]0x131 + 'l' + [char]0x131 + 'm' + [char]0x131),
        'Canon LBP6020', 'Microsoft Windows Application Compatibility Fix Database', 'Lenovo Vantage Service', 'Xbox Service',
        'Microsoft GameInput', 'Epic Online Services', 'Rockstar Games SDK', 'Riot Vanguard') {
        Assert-True (Test-RBProgramNoise $n) "not filtered: $n"
    }
    foreach ($n in 'Steam', 'VALORANT', 'Discord', 'NVIDIA App', 'Age of Empires III', 'Rockstar Games Launcher') { Assert-True (-not (Test-RBProgramNoise $n)) "wrongly filtered: $n" }
    Assert-Equal (Format-RBProgramLine ([pscustomobject]@{ Name = 'NVIDIA App 11.0.9.565'; Version = '11.0.9.565' })) 'NVIDIA App 11.0.9.565'
    Assert-Equal (Format-RBProgramLine ([pscustomobject]@{ Name = 'Canon LBP6020 '; Version = '' })) 'Canon LBP6020'
    Assert-Equal (Format-RBProgramLine ([pscustomobject]@{ Name = 'Steam'; Version = '2.10' })) 'Steam 2.10'
}

Test-Case 'winget exit codes: already installed / reboot count as success (issue 8)' {
    Assert-Equal $Global:RBWingetOk[-1978335189] 'already'
    Assert-Equal $Global:RBWingetOk[0] 'ok'
    Assert-True (-not $Global:RBWingetOk.ContainsKey(-1978335212)) 'real failures are not ok'
}

Test-Case 'a module warning is reported as warning, not plain success (issue 11)' {
    Register-RBProvider @{ Name = 'test.warn'; Discover = $null; Backup = { param($i, $d) @{ status = 'warn'; x = 1 } }; Restore = { param($i, $d) @{ status = 'warn' } } }
    $it = New-RBItem -Id 'test.warn' -Provider 'test.warn' -Category apps -Name 'warn test'
    $r = Invoke-RBBackup -Items @($it) -Target (Join-Path $tmp 'warnbk')
    Assert-Equal $r.Warned 1
    Assert-True ((Split-Path -Leaf $r.Dir) -match '^ResetBack-\d{4}-\d{2}-\d{2}_\d{6}$') 'stamp has seconds (issue 9)'
    $info = Get-RBRestoreItems $r.Dir
    $rr = Invoke-RBRestore -Items $info.Items -BackupDir $info.Dir
    Assert-Equal $rr.Warned 1
    Assert-True ((Split-Path -Leaf $rr.LogFile) -match '_\d{6}\.txt$') 'restore log has seconds (issue 9)'
    $Global:RB.Providers.Remove('test.warn')
}

Test-Case 'restore rebuilds packages from the files in the backup (issue 5) and keeps defaults off (issue 14)' {
    $bd = Join-Path $tmp 'prep'; New-Item -ItemType Directory -Force $bd | Out-Null
    Write-RBJsonFile @{ Sources = @(@{ SourceDetails = @{ Name = 'winget' }; Packages = @(@{ PackageIdentifier = 'VideoLAN.VLC' }, @{ PackageIdentifier = 'Microsoft.Teams' }) }) } (Join-Path $bd 'winget.json')
    @([pscustomobject]@{ Name = 'Discord'; Version = '1'; Publisher = 'Discord' }) | Export-Csv (Join-Path $bd 'installed-programs.csv') -NoTypeInformation -Encoding UTF8
    $it = New-RBItem -Id 'programs.winget' -Provider programs -Category programs -DescArgs @(5, 41) -Data @{ packages = @(@{ id = 'A.B'; name = 'stale' }); wingetPackages = 41 }
    & $Global:RB.Providers['programs'].PrepareRestore $it $bd
    $ids = @($it.Data.packages | ForEach-Object { $_.id })
    Assert-Equal $ids.Count 3 'VLC + Teams from json, Discord from map'
    Assert-Equal $it.Data.wingetPackages 3
    Assert-True (@($it.Data.exclude) -contains 'Microsoft.Teams') 'Teams off by default'
}

Test-Case 'real manual-install list from another PC is mostly resolved (v1.2.1)' {
    # the 27 programs a real restore reported as "install by hand" before v1.2
    $names = @('Age of Empires III', 'Canon LBP6020', 'Copilot', 'Discord', 'Dukto R6', 'EA app', 'Epic Games Launcher', 'Epic Online Services',
        'Google Chrome', 'iCloud Outlook', 'Lenovo Now', 'Lenovo Vantage Service', 'Microsoft GameInput', 'Microsoft Windows Application Compatibility Fix Database',
        'NVIDIA App 11.0.9.565', 'NVIDIA FrameView SDK 1.9.12728.38614306', ('NVIDIA HD Ses S' + [char]0xFC + 'r' + [char]0xFC + 'c' + [char]0xFC + 's' + [char]0xFC + ' 1.4.6.6'),
        ('NVIDIA PhysX Sistem Yaz' + [char]0x131 + 'l' + [char]0x131 + 'm' + [char]0x131 + ' 9.26.0904'), 'Riot Vanguard', 'Rockstar Games Launcher', 'Rockstar Games SDK',
        'SplitWire-Turkey 1.5.3', 'Steam', ('The Sims' + [char]0x2122 + ' 4'), 'VALORANT', 'WireSock Secure Connect', 'Xbox Service')
    $inv = @($names | ForEach-Object { [pscustomobject]@{ Name = $_; Version = ''; Publisher = '' } })
    $pk = @(Get-RBProgramPackages -Inventory $inv)
    $mappedNames = @($pk | ForEach-Object { $_.name })
    $manual = @($names | Where-Object { ($mappedNames -notcontains $_) -and -not (Test-RBProgramNoise $_) })
    Assert-Equal $pk.Count 11 'programs installable through winget/msstore'
    Assert-Equal (($manual | Sort-Object) -join '|') ((@('Age of Empires III', 'Dukto R6', 'Lenovo Now', 'SplitWire-Turkey 1.5.3', ('The Sims' + [char]0x2122 + ' 4')) | Sort-Object) -join '|')
}

Test-Case 'GUI opens in restore mode when a backup exists, no scan first (issue 13)' {
    $orig = ${function:Find-RBBackups}
    try {
        ${function:Find-RBBackups} = { @('D:\ResetBack-2026-11-14_175000') }
        $s = Get-RBStartupMode
        Assert-Equal $s.Mode 'restore'; Assert-Equal $s.Path 'D:\ResetBack-2026-11-14_175000'
        ${function:Find-RBBackups} = { @() }
        Assert-Equal (Get-RBStartupMode).Mode 'backup'
    } finally { ${function:Find-RBBackups} = $orig }
}

Test-Case 'CLI accepts a single selected item (PS 5.1 scalar .Count regression)' {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'ResetBack.ps1') -Backup -Target (Join-Path $tmp 'cli') -Items 'system.envvars' -DryRun -Lang en 2>&1 | Out-String
    Assert-True ($out -notmatch 'Nothing selected') 'single item was not selected'
    Assert-True ($out -match 'Succeeded: 1') 'single item did not run'
}

if (-not $SkipDiscovery) {
    Test-Case 'discovery on this machine returns unique, well-formed items' {
        $all = @(Get-RBBackupItems)
        Assert-True ($all.Count -gt 3) 'too few items'
        $ids = @($all | ForEach-Object { $_.Id })
        Assert-Equal (@($ids | Sort-Object -Unique).Count) $ids.Count 'duplicate ids'
        foreach ($it in $all) {
            Assert-True ($it.Name) "no name: $($it.Id)"
            Assert-True ($Global:RBCategories -contains $it.Category) "bad category: $($it.Id)"
            Assert-True ($Global:RB.Providers.Contains($it.Provider)) "bad provider: $($it.Id)"
        }
    }
}

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host ("{0} passed, {1} failed" -f $script:pass, $script:fail) -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
if ($script:fail) { exit 1 }
