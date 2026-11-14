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
