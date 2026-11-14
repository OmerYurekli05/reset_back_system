# Providers: user data.
#   userdata.folder - personal folders (Desktop, Documents, Pictures, ...)
#   userdata.app    - application settings / saves from catalog\apps.json
# Paths are stored with tokens (%APPDATA%, %DOCUMENTS%, ...) so they are
# resolved again on the new system, even if the user name changed.

$Global:RBKnownFolders = @(
    @{ id = 'desktop';   token = '%DESKTOP%';   default = $true },
    @{ id = 'documents'; token = '%DOCUMENTS%'; default = $true },
    @{ id = 'pictures';  token = '%PICTURES%';  default = $true },
    @{ id = 'downloads'; token = '%DOWNLOADS%'; default = $false },
    @{ id = 'videos';    token = '%VIDEOS%';    default = $false },
    @{ id = 'music';     token = '%MUSIC%';     default = $false }
)

function Test-RBUnderOneDrive {
    param([string]$Path)
    foreach ($od in @($env:OneDrive, $env:OneDriveConsumer, $env:OneDriveCommercial)) {
        if ($od -and $Path.StartsWith($od, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

Register-RBProvider @{
    Name     = 'userdata.folder'
    Discover = {
        $idx = 0
        foreach ($kf in $Global:RBKnownFolders) {
            $idx++
            $p = Expand-RBPath $kf.token
            if (-not $p -or -not (Test-Path -LiteralPath $p)) { continue }
            $od = Test-RBUnderOneDrive $p
            $descKey = if ($od) { 'item.folder.desc.onedrive' } else { 'item.folder.desc' }
            New-RBItem -Id ('userdata.' + $kf.id) -Provider 'userdata.folder' -Category 'userdata' -NameKey ('item.folder.' + $kf.id) `
                -DescKey $descKey -DescArgs @($p) -Order (60 + $idx) -Size (Get-RBSize $p) `
                -DefaultSelected ($kf.default -and -not $od) -Data @{ token = $kf.token }
        }
    }
    Backup   = {
        param($Item, $Dir)
        $src = Expand-RBPath $Item.Data.token
        if (-not (Copy-RBPath $src (Join-Path $Dir 'files') -ExcludeFiles @('desktop.ini'))) { throw (T 'err.copy' $src) }
    }
    Restore  = {
        param($Item, $Dir)
        $dst = Expand-RBPath $Item.Data.token
        if (-not (Copy-RBPath (Join-Path $Dir 'files') $dst -NoOverwrite:(-not $Global:RB.Options.Overwrite))) { throw (T 'err.copy' $dst) }
        Write-RBLog (T 'log.restored.to' $dst) 'ok'
    }
}

# ------------------------------------------------------------------ app catalog

function Get-RBAppCatalog {
    if ($Global:RB.CatalogOverride) { return @(Read-RBJsonList ([IO.File]::ReadAllText($Global:RB.CatalogOverride, [Text.Encoding]::UTF8))) }
    return @(Read-RBJsonList (Get-RBResourceText 'catalog\apps.json'))
}

# Builds an item from one catalog entry, or nothing when none of its paths exist.
function New-RBCatalogItem {
    param($Entry)
    $paths = New-Object System.Collections.ArrayList
    $size = @{ Bytes = [int64]0; Partial = $false }
    $i = 0
    foreach ($tp in @($Entry.paths)) {
        $p = Expand-RBPath $tp
        if ($p -and (Test-Path -LiteralPath $p)) {
            [void]$paths.Add(@{ i = $i; path = $tp; file = [IO.File]::Exists($p) })
            $s = Get-RBSize $p 1000
            $size.Bytes += $s.Bytes
            if ($s.Partial) { $size.Partial = $true }
        }
        $i++
    }
    if (-not $paths.Count) { return }
    $default = if ($null -eq $Entry.default) { $true } else { [bool]$Entry.default }
    New-RBItem -Id ('app.' + $Entry.id) -Provider 'userdata.app' -Category 'apps' -Name $Entry.name -Order 70 `
        -Sensitive ([bool]$Entry.sensitive) -RequiresAdmin ([bool]$Entry.admin) -Processes @($Entry.processes) -Size $size `
        -DefaultSelected $default -Data @{ app = $Entry.id; note = $Entry.note; paths = $paths.ToArray(); exclude = @($Entry.exclude) }
}

Register-RBProvider @{
    Name     = 'userdata.app'
    Discover = {
        foreach ($e in Get-RBAppCatalog) {
            if (-not $e.id -or -not $e.paths) { continue }
            New-RBCatalogItem $e
        }
    }
    Backup   = {
        param($Item, $Dir)
        $ok = 0
        $paths = @($Item.Data.paths)
        foreach ($p in $paths) {
            $src = Expand-RBPath $p.path
            if (-not (Test-Path -LiteralPath $src)) { Write-RBLog (T 'log.missing' $src) 'warn'; continue }
            $isFile = [IO.File]::Exists($src)
            $p.file = $isFile
            $dst = Join-Path $Dir ('p' + $p.i)
            if ($isFile) { $dst = Join-Path $dst (Split-Path -Leaf $src) }
            if (Copy-RBPath $src $dst -ExcludeDirs @($Item.Data.exclude)) { $ok++ }
        }
        if ($ok -eq 0) { throw (T 'err.copy' $Item.Name) }
        Write-RBLog (T 'log.app.copied' $ok $paths.Count) 'ok'
        return @{ paths = $paths }
    }
    Restore  = {
        param($Item, $Dir)
        $ok = 0
        $paths = @($Item.Data.paths)
        foreach ($p in $paths) {
            $dst = Expand-RBPath $p.path
            $src = Join-Path $Dir ('p' + $p.i)
            if ($p.file) { $src = Join-Path $src (Split-Path -Leaf $dst) }
            if (-not (Test-Path -LiteralPath $src)) { continue }
            if (Copy-RBPath $src $dst -NoOverwrite:(-not $Global:RB.Options.Overwrite)) { $ok++; Write-RBLog ('    -> ' + $dst) }
        }
        if ($ok -eq 0) { throw (T 'err.copy' $Item.Name) }
        Write-RBLog (T 'log.app.copied' $ok $paths.Count) 'ok'
    }
}
