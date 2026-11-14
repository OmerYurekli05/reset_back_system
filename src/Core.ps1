# reset_back_system - core helpers: state, i18n, logging, json, paths, copy.
# NOTE: keep every .ps1 file ASCII-only. Windows PowerShell 5.1 reads BOM-less
# files as ANSI, so all user-facing (Turkish) text lives in lang\*.json.

if (-not $Global:RB_ROOT) { $Global:RB_ROOT = (Get-Location).Path }

$Global:RB = @{
    Version      = '0.1.0'
    Root         = $Global:RB_ROOT
    Lang         = 'en'
    Strings      = @{}
    Providers    = [ordered]@{}
    LogFile      = $null
    LogSink      = $null
    ProgressSink = $null
    SessionDir   = $null
    DryRun       = $false
    Options      = @{ Overwrite = $true; Force = $false }
    CatalogOverride = $null
}

$Global:RBCategories = @('programs', 'editors', 'system', 'userdata', 'apps')

# ---------------------------------------------------------------- json / resources

function ConvertTo-RBHashtable {
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $h = @{}
        foreach ($k in $InputObject.Keys) { $h[[string]$k] = ConvertTo-RBHashtable $InputObject[$k] }
        return $h
    }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = ConvertTo-RBHashtable $p.Value }
        return $h
    }
    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        $list = New-Object System.Collections.ArrayList
        foreach ($x in $InputObject) { [void]$list.Add((ConvertTo-RBHashtable $x)) }
        return , $list.ToArray()
    }
    return $InputObject
}

function Read-RBJsonText {
    param([string]$Text)
    if ($Text.Length -gt 0 -and $Text[0] -eq [char]0xFEFF) { $Text = $Text.Substring(1) }
    return ConvertTo-RBHashtable (ConvertFrom-Json -InputObject $Text)
}

# Emits the elements of a JSON array one by one (avoids nested-array surprises in PS 5.1).
function Read-RBJsonList {
    param([string]$Text)
    $c = Read-RBJsonText $Text
    foreach ($x in $c) { if ($null -ne $x) { $x } }
}

function Read-RBJsonFile {
    param([string]$Path)
    return Read-RBJsonText ([IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8))
}

function Write-RBJsonFile {
    param($Object, [string]$Path)
    $json = ConvertTo-Json -InputObject $Object -Depth 12
    [IO.File]::WriteAllText($Path, $json, (New-Object Text.UTF8Encoding $false))
}

function Get-RBResourceText {
    param([string]$RelPath)
    $p = Join-Path $Global:RB.Root $RelPath
    if (Test-Path -LiteralPath $p) { return [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8) }
    if ($Global:RB_EMBED -and $Global:RB_EMBED.ContainsKey($RelPath)) {
        return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Global:RB_EMBED[$RelPath]))
    }
    throw "Resource not found: $RelPath"
}

# ---------------------------------------------------------------- settings / i18n

function Get-RBSettingsPath { Join-Path $env:APPDATA 'reset_back_system\settings.json' }

function Get-RBSettings {
    $p = Get-RBSettingsPath
    if (Test-Path -LiteralPath $p) {
        try { $s = Read-RBJsonFile $p; if ($s -is [hashtable]) { return $s } } catch { }
    }
    return @{}
}

function Save-RBSettings {
    param([hashtable]$Settings)
    $p = Get-RBSettingsPath
    try {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $p) | Out-Null
        Write-RBJsonFile $Settings $p
    } catch { }
}

function Get-RBDefaultLanguage {
    $s = Get-RBSettings
    if ($s.lang -in @('tr', 'en')) { return $s.lang }
    if ((Get-UICulture).TwoLetterISOLanguageName -eq 'tr' -or (Get-Culture).TwoLetterISOLanguageName -eq 'tr') { return 'tr' }
    return 'en'
}

function Set-RBLanguage {
    param([string]$Lang)
    if ($Lang -notin @('tr', 'en')) { $Lang = 'en' }
    $Global:RB.Lang = $Lang
    $Global:RB.Strings = Read-RBJsonText (Get-RBResourceText "lang\$Lang.json")
}

# Translate a key; extra arguments are used with -f formatting.
function T {
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$Key,
        [Parameter(ValueFromRemainingArguments = $true)][object[]]$FormatArgs
    )
    $s = $Key
    if ($Global:RB.Strings -and $Global:RB.Strings.ContainsKey($Key)) { $s = $Global:RB.Strings[$Key] }
    if ($FormatArgs -and $FormatArgs.Count -gt 0) {
        try { $s = $s -f $FormatArgs } catch { }
    }
    return $s
}

# ---------------------------------------------------------------- logging / progress

function Write-RBLog {
    param([string]$Message, [ValidateSet('info', 'ok', 'warn', 'error', 'step')][string]$Level = 'info')
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message
    if ($Global:RB.LogFile) {
        try { [IO.File]::AppendAllText($Global:RB.LogFile, ('{0,-5} {1}' -f $Level.ToUpper(), $line) + "`r`n", [Text.Encoding]::UTF8) } catch { }
    }
    if ($Global:RB.LogSink) { & $Global:RB.LogSink $Level $line; return }
    $color = switch ($Level) { 'ok' { 'Green' } 'warn' { 'Yellow' } 'error' { 'Red' } 'step' { 'Cyan' } default { 'Gray' } }
    Write-Host $line -ForegroundColor $color
}

function Set-RBProgress {
    param([int]$Current, [int]$Total, [string]$Text)
    if ($Global:RB.ProgressSink) { & $Global:RB.ProgressSink $Current $Total $Text; return }
    $pct = [int][math]::Min(100, 100 * $Current / [math]::Max(1, $Total))
    if ($Current -ge $Total) { Write-Progress -Activity 'reset_back_system' -Completed }
    else { Write-Progress -Activity 'reset_back_system' -Status $Text -PercentComplete $pct }
}

# ---------------------------------------------------------------- system helpers

function Test-RBAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-RBKnownFolder {
    param([string]$Name)
    switch ($Name) {
        'DOCUMENTS' { return [Environment]::GetFolderPath('MyDocuments') }
        'DESKTOP'   { return [Environment]::GetFolderPath('Desktop') }
        'PICTURES'  { return [Environment]::GetFolderPath('MyPictures') }
        'VIDEOS'    { return [Environment]::GetFolderPath('MyVideos') }
        'MUSIC'     { return [Environment]::GetFolderPath('MyMusic') }
        'DOWNLOADS' {
            try {
                $v = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -ErrorAction Stop).'{374DE290-123F-4565-9164-39C4925E467B}'
                if ($v) { return [Environment]::ExpandEnvironmentVariables($v) }
            } catch { }
            return (Join-Path $env:USERPROFILE 'Downloads')
        }
    }
    return $null
}

# Expands %DOCUMENTS%-style known-folder tokens and normal environment variables.
function Expand-RBPath {
    param([string]$Path)
    if (-not $Path) { return $Path }
    foreach ($k in @('DOCUMENTS', 'DESKTOP', 'PICTURES', 'VIDEOS', 'MUSIC', 'DOWNLOADS')) {
        $tok = "%$k%"
        $idx = $Path.IndexOf($tok, [StringComparison]::OrdinalIgnoreCase)
        while ($idx -ge 0) {
            $Path = $Path.Substring(0, $idx) + (Get-RBKnownFolder $k) + $Path.Substring($idx + $tok.Length)
            $idx = $Path.IndexOf($tok, [StringComparison]::OrdinalIgnoreCase)
        }
    }
    return [Environment]::ExpandEnvironmentVariables($Path)
}

function Get-RBRunningProcesses {
    param([string[]]$Names)
    $Names = @($Names | Where-Object { $_ })
    if (-not $Names.Count) { return @() }
    return @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $Names -contains $_.ProcessName } | Select-Object -ExpandProperty ProcessName -Unique)
}

# Runs an executable with an exact argument string (needed for netsh/powercfg quoting).
function Invoke-RBExe {
    param([string]$File, [string]$Arguments = '')
    $psi = New-Object Diagnostics.ProcessStartInfo $File, $Arguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    try {
        $enc = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
        $psi.StandardOutputEncoding = $enc
        $psi.StandardErrorEncoding = $enc
    } catch { }
    $p = [Diagnostics.Process]::Start($psi)
    $errTask = $p.StandardError.ReadToEndAsync()
    $out = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit()
    return [pscustomobject]@{ Code = $p.ExitCode; Output = ($out + $errTask.Result) }
}

function Get-RBSize {
    param([string]$Path, [int]$TimeoutMs = 2500)
    $r = @{ Bytes = [int64]0; Partial = $false }
    if (-not $Path) { return $r }
    if ([IO.File]::Exists($Path)) { $r.Bytes = (New-Object IO.FileInfo $Path).Length; return $r }
    if (-not [IO.Directory]::Exists($Path)) { return $r }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $stack = New-Object System.Collections.Stack
    $stack.Push($Path)
    while ($stack.Count -gt 0) {
        if ($sw.ElapsedMilliseconds -gt $TimeoutMs) { $r.Partial = $true; break }
        $d = New-Object IO.DirectoryInfo ([string]$stack.Pop())
        try {
            foreach ($f in $d.EnumerateFiles()) { $r.Bytes += $f.Length }
            foreach ($s in $d.EnumerateDirectories()) {
                if (-not ($s.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $stack.Push($s.FullName) }
            }
        } catch { }
    }
    return $r
}

function Format-RBSize {
    param($Size)
    if ($null -eq $Size) { return '' }
    $b = [double]$Size.Bytes
    $units = @('B', 'KB', 'MB', 'GB', 'TB')
    $i = 0
    while ($b -ge 1024 -and $i -lt $units.Count - 1) { $b /= 1024; $i++ }
    $txt = if ($i -eq 0) { '{0} {1}' -f [int]$b, $units[$i] } else { '{0:N1} {1}' -f $b, $units[$i] }
    if ($Size.Partial) { $txt += '+' }
    return $txt
}

# Copies a file or a folder. Folders use robocopy. Honors dry-run.
function Copy-RBPath {
    param(
        [string]$Source,
        [string]$Destination,
        [string[]]$ExcludeDirs = @(),
        [string[]]$ExcludeFiles = @(),
        [switch]$NoOverwrite
    )
    $ErrorActionPreference = 'Continue'
    if (-not (Test-Path -LiteralPath $Source)) { Write-RBLog (T 'log.missing' $Source) 'warn'; return $false }
    if ($Global:RB.DryRun) { Write-RBLog (T 'log.dry.copy' $Source $Destination); return $true }
    try {
        $item = Get-Item -LiteralPath $Source -Force
        if (-not $item.PSIsContainer) {
            if ($NoOverwrite -and (Test-Path -LiteralPath $Destination)) { Write-RBLog (T 'log.skip.exists' $Destination); return $true }
            $parent = Split-Path -Parent $Destination
            if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
            Copy-Item -LiteralPath $Source -Destination $Destination -Force -ErrorAction Stop
            return $true
        }
        New-Item -ItemType Directory -Force -Path $Destination | Out-Null
        $src = $Source.TrimEnd('\'); if ($src.EndsWith(':')) { $src += '\.' }
        $dst = $Destination.TrimEnd('\'); if ($dst.EndsWith(':')) { $dst += '\.' }
        $rc = @($src, $dst, '/E', '/R:1', '/W:1', '/XJ', '/MT:8', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
        $ExcludeDirs = @($ExcludeDirs | Where-Object { $_ })
        $ExcludeFiles = @($ExcludeFiles | Where-Object { $_ })
        if ($ExcludeDirs.Count) { $rc += '/XD'; $rc += $ExcludeDirs }
        if ($ExcludeFiles.Count) { $rc += '/XF'; $rc += $ExcludeFiles }
        if ($NoOverwrite) { $rc += @('/XC', '/XN', '/XO') }
        $out = & robocopy.exe @rc 2>&1
        $code = $LASTEXITCODE
        if ($code -ge 8) {
            Write-RBLog (T 'log.copy.fail' $Source $code) 'error'
            @($out) | Select-Object -Last 5 | ForEach-Object { Write-RBLog ('    ' + $_) 'warn' }
            return $false
        }
        return $true
    } catch {
        Write-RBLog (T 'log.copy.fail' $Source $_.Exception.Message) 'error'
        return $false
    }
}

# ---------------------------------------------------------------- items / providers

function Register-RBProvider {
    param([hashtable]$Provider)
    $Global:RB.Providers[$Provider.Name] = $Provider
}

function Update-RBItemText {
    param($Item)
    if ($Item.NameKey) { $Item.Name = T $Item.NameKey }
    if ($Item.DescKey) {
        $s = T $Item.DescKey
        $a = @($Item.DescArgs)
        if ($a.Count) { try { $s = $s -f $a } catch { } }
        $Item.Description = $s
    } elseif ($Item.Data -and $Item.Data.note) {
        $n = $Item.Data.note
        if ($n[$Global:RB.Lang]) { $Item.Description = $n[$Global:RB.Lang] } else { $Item.Description = $n['en'] }
    }
}

function New-RBItem {
    param(
        [string]$Id, [string]$Provider, [string]$Category,
        [string]$Name = '', [string]$NameKey = '',
        [string]$Description = '', [string]$DescKey = '', [object[]]$DescArgs = @(),
        [int]$Order = 50, [bool]$Sensitive = $false, [bool]$RequiresAdmin = $false,
        [bool]$RestoreSupported = $true, $Size = $null, [string[]]$Processes = @(),
        [hashtable]$Data = @{}, [bool]$DefaultSelected = $true
    )
    if ($null -eq $Data) { $Data = @{} }
    $it = [pscustomobject]@{
        Id = $Id; Provider = $Provider; Category = $Category
        Name = $Name; NameKey = $NameKey; Description = $Description; DescKey = $DescKey; DescArgs = @($DescArgs)
        Order = $Order; Sensitive = $Sensitive; RequiresAdmin = $RequiresAdmin; RestoreSupported = $RestoreSupported
        Size = $Size; Processes = @($Processes | Where-Object { $_ }); Data = $Data
        Selected = ($DefaultSelected -and -not $Sensitive); BackupDir = $null
    }
    Update-RBItemText $it
    return $it
}
