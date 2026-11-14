# Provider: code editors based on VS Code (VS Code, Cursor, Windsurf, Antigravity, VSCodium ...).
# Backup : extension list + User settings folder (+ extra files listed in the catalog).
# Restore: settings copied back, extensions reinstalled (latest versions).
# Editors are defined in catalog\editors.json, so new ones need no code change.

$Global:RBEditorExcludeDirs = @('workspaceStorage', 'globalStorage', 'History', 'logs', 'CachedData', 'Cache', 'GPUCache')

function Get-RBEditorCatalog {
    return @(Read-RBJsonList (Get-RBResourceText 'catalog\editors.json'))
}

function Get-RBEditorById {
    param([string]$Id)
    return (Get-RBEditorCatalog | Where-Object { $_.id -eq $Id } | Select-Object -First 1)
}

function Resolve-RBEditorCli {
    param($Editor)
    foreach ($c in @($Editor.cli)) {
        $p = Expand-RBPath $c
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    }
    return $null
}

function Resolve-RBEditorUserDir {
    param($Editor, [switch]$ForRestore)
    foreach ($u in @($Editor.userDir)) {
        $p = Expand-RBPath $u
        if (Test-Path -LiteralPath $p) { return $p }
    }
    if ($ForRestore) { return (Expand-RBPath (@($Editor.userDir)[0])) }
    return $null
}

function Get-RBEditorExtensions {
    param([string]$Cli, [switch]$WithVersions)
    $ErrorActionPreference = 'Continue'
    if (-not $Cli) { return @() }
    $a = @('--list-extensions')
    if ($WithVersions) { $a += '--show-versions' }
    try {
        return @(& $Cli @a 2>$null | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -match '^[\w\-]+\.[\w\-.]+(@[\w\-.]+)?$' })
    } catch { return @() }
}

Register-RBProvider @{
    Name     = 'editors'
    Discover = {
        foreach ($ed in Get-RBEditorCatalog) {
            try {
                $cli = Resolve-RBEditorCli $ed
                $ud = Resolve-RBEditorUserDir $ed
                if (-not $cli -and -not $ud) { continue }
                $count = @(Get-RBEditorExtensions $cli).Count
                New-RBItem -Id ('editors.' + $ed.id) -Provider 'editors' -Category 'editors' -Name $ed.name `
                    -DescKey 'item.editor.desc' -DescArgs @($count) -Order 40 -Processes @($ed.process) `
                    -Size (Get-RBSize $ud 1500) -Data @{ editor = $ed.id }
            } catch {
                Write-RBLog (T 'log.discover.fail' $ed.name $_.Exception.Message) 'warn'
            }
        }
    }
    Backup   = {
        param($Item, $Dir)
        $ed = Get-RBEditorById $Item.Data.editor
        if (-not $ed) { throw (T 'err.editor.unknown' $Item.Data.editor) }
        $cli = Resolve-RBEditorCli $ed
        $exts = @(Get-RBEditorExtensions $cli -WithVersions)
        if ($Global:RB.DryRun) { Write-RBLog (T 'log.editor.exts' $exts.Count) }
        else {
            [IO.File]::WriteAllLines((Join-Path $Dir 'extensions.txt'), [string[]]$exts, [Text.Encoding]::UTF8)
            Write-RBLog (T 'log.editor.exts' $exts.Count) 'ok'
        }
        $ud = Resolve-RBEditorUserDir $ed
        if ($ud) {
            if (-not (Copy-RBPath $ud (Join-Path $Dir 'User') -ExcludeDirs $Global:RBEditorExcludeDirs)) { throw (T 'err.copy' $ud) }
        }
        $i = 0
        foreach ($x in @($ed.extra | Where-Object { $_ })) {
            $p = Expand-RBPath $x
            if ($p -and (Test-Path -LiteralPath $p)) { [void](Copy-RBPath $p (Join-Path $Dir ("extra$i\" + (Split-Path -Leaf $p)))) }
            $i++
        }
        return @{ extensions = $exts.Count }
    }
    Restore  = {
        param($Item, $Dir)
        $ed = Get-RBEditorById $Item.Data.editor
        if (-not $ed) { throw (T 'err.editor.unknown' $Item.Data.editor) }
        $src = Join-Path $Dir 'User'
        if (Test-Path -LiteralPath $src) {
            $dst = Resolve-RBEditorUserDir $ed -ForRestore
            if (-not (Copy-RBPath $src $dst -NoOverwrite:(-not $Global:RB.Options.Overwrite))) { throw (T 'err.copy' $src) }
            Write-RBLog (T 'log.editor.settings' $dst) 'ok'
        }
        $i = 0
        foreach ($x in @($ed.extra | Where-Object { $_ })) {
            $target = Expand-RBPath $x
            $f = Join-Path $Dir ("extra$i\" + (Split-Path -Leaf $target))
            if (Test-Path -LiteralPath $f) { [void](Copy-RBPath $f $target -NoOverwrite:(-not $Global:RB.Options.Overwrite)) }
            $i++
        }
        $extFile = Join-Path $Dir 'extensions.txt'
        if (-not (Test-Path -LiteralPath $extFile)) { return }
        $ids = @([IO.File]::ReadAllLines($extFile) | ForEach-Object { ($_ -split '@')[0].Trim() } | Where-Object { $_ })
        if (-not $ids.Count) { return }
        $cli = Resolve-RBEditorCli $ed
        if (-not $cli) { Write-RBLog (T 'log.editor.nocli' $ed.name) 'warn'; return }
        if ($Global:RB.DryRun) { Write-RBLog (T 'log.dry.extensions' $ids.Count $ed.name); return }
        $ErrorActionPreference = 'Continue'
        $installed = @(Get-RBEditorExtensions $cli)
        $failed = @()
        $done = 0
        foreach ($x in $ids) {
            if ($installed -contains $x) { $done++; continue }
            & $cli --install-extension $x --force *> $null
            if ($LASTEXITCODE -eq 0) { $done++; Write-RBLog ('    OK  ' + $x) } else { $failed += $x; Write-RBLog ('    !!  ' + $x) 'warn' }
        }
        Write-RBLog (T 'log.editor.installed' $done $ids.Count) 'ok'
        if ($failed.Count) { Write-RBLog (T 'log.editor.failed' ($failed -join ', ')) 'warn' }
    }
}
