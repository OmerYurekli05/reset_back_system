# Builds the distributable files into dist\:
#   dist\ResetBack.ps1                 single file: all code, languages, catalogs and XAML embedded
#   dist\ResetBack.cmd                 double-click launcher
#   dist\reset_back_system-<ver>.zip   release archive (+ README, LICENSE, profiles)
#   dist\ResetBack.exe                 only when the ps2exe module is installed (-Exe)
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File build\build.ps1 [-Exe]
param([switch]$Exe)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$dist = Join-Path $root 'dist'
if (Test-Path $dist) { Remove-Item $dist -Recurse -Force }
New-Item -ItemType Directory -Force $dist | Out-Null

function Get-B64([string]$Path) { [Convert]::ToBase64String([IO.File]::ReadAllBytes($Path)) }

# code bundle, in the same order ResetBack.ps1 uses in development
$parts = @('src\Core.ps1', 'src\Engine.ps1') +
    @(Get-ChildItem (Join-Path $root 'src\Providers') -Filter *.ps1 | Sort-Object Name | ForEach-Object { 'src\Providers\' + $_.Name }) +
    @('src\Gui.ps1')
$code = ($parts | ForEach-Object { [IO.File]::ReadAllText((Join-Path $root $_), [Text.Encoding]::UTF8) }) -join "`r`n"
$version = [regex]::Match($code, "Version\s*=\s*'([^']+)'").Groups[1].Value

$resources = @('lang\tr.json', 'lang\en.json', 'catalog\apps.json', 'catalog\editors.json', 'src\MainWindow.xaml')
$sb = New-Object Text.StringBuilder
[void]$sb.AppendLine("# ---- embedded by build\build.ps1 (reset_back_system $version) ----")
[void]$sb.AppendLine('$Global:RB_ROOT = if ($PSScriptRoot) { $PSScriptRoot } else { [AppDomain]::CurrentDomain.BaseDirectory.TrimEnd(''\'') }')
[void]$sb.AppendLine('$Global:RB_EMBED = @{')
foreach ($r in $resources) { [void]$sb.AppendLine(("    '{0}' = '{1}'" -f $r, (Get-B64 (Join-Path $root $r)))) }
[void]$sb.AppendLine('}')
[void]$sb.AppendLine(('$Global:RB_CODE = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(''{0}''))' -f [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($code))))
[void]$sb.Append('# ---- end of embedded block ----')

$main = [IO.File]::ReadAllText((Join-Path $root 'ResetBack.ps1'), [Text.Encoding]::UTF8)
if ($main -notmatch '#@@RB_EMBED@@') { throw 'marker #@@RB_EMBED@@ not found in ResetBack.ps1' }
$single = $main.Replace('#@@RB_EMBED@@', $sb.ToString())
$out = Join-Path $dist 'ResetBack.ps1'
[IO.File]::WriteAllText($out, $single, (New-Object Text.UTF8Encoding $true))
Copy-Item (Join-Path $root 'ResetBack.cmd') $dist
Write-Host "built $out ($([math]::Round((Get-Item $out).Length / 1KB)) KB, v$version)" -ForegroundColor Green

if ($Exe) {
    if (-not (Get-Command Invoke-ps2exe -ErrorAction SilentlyContinue)) { Import-Module ps2exe -ErrorAction SilentlyContinue }
    if (Get-Command Invoke-ps2exe -ErrorAction SilentlyContinue) {
        Invoke-ps2exe -inputFile $out -outputFile (Join-Path $dist 'ResetBack.exe') -noConsole -requireAdmin -STA `
            -title 'reset_back_system' -version $version -product 'reset_back_system'
    } else {
        Write-Host 'ps2exe is not installed (Install-Module ps2exe -Scope CurrentUser); skipping the .exe' -ForegroundColor Yellow
    }
}

# release archive
$stage = Join-Path $dist "reset_back_system-$version"
New-Item -ItemType Directory -Force $stage | Out-Null
Copy-Item $out, (Join-Path $dist 'ResetBack.cmd'), (Join-Path $root 'README.md'), (Join-Path $root 'LICENSE') $stage
Copy-Item (Join-Path $root 'profiles') $stage -Recurse
if (Test-Path (Join-Path $dist 'ResetBack.exe')) { Copy-Item (Join-Path $dist 'ResetBack.exe') $stage }
$zip = Join-Path $dist "reset_back_system-$version.zip"
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -Force
Remove-Item $stage -Recurse -Force
Write-Host "built $zip" -ForegroundColor Green
