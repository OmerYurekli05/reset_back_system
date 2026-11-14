# Providers: Windows system settings.
#   system.drivers   - third-party drivers (pnputil export / add-driver)
#   system.wifi      - saved Wi-Fi profiles with passwords (netsh)
#   system.power     - active power plan (powercfg)
#   system.bitlocker - BitLocker recovery keys (backup only, for safekeeping)
#   system.hosts     - hosts file
#   system.envvars   - user environment variables (Path is merged, not replaced)

function Get-RBSys32 { param([string]$Exe) return (Join-Path $env:SystemRoot "System32\$Exe") }

# ------------------------------------------------------------------ drivers
Register-RBProvider @{
    Name     = 'system.drivers'
    Discover = {
        New-RBItem -Id 'system.drivers' -Provider 'system.drivers' -Category 'system' -NameKey 'item.drivers.name' `
            -DescKey 'item.drivers.desc' -Order 10 -RequiresAdmin $true -DefaultSelected $true
    }
    Backup   = {
        param($Item, $Dir)
        if ($Global:RB.DryRun) { Write-RBLog (T 'log.dry.drivers'); return }
        Write-RBLog (T 'log.drivers.exporting')
        $r = Invoke-RBExe (Get-RBSys32 'pnputil.exe') ('/export-driver * "{0}"' -f $Dir)
        $list = Invoke-RBExe (Get-RBSys32 'pnputil.exe') '/enum-drivers'
        [IO.File]::WriteAllText((Join-Path $Dir 'drivers-list.txt'), $list.Output, [Text.Encoding]::UTF8)
        $n = @(Get-ChildItem -LiteralPath $Dir -Recurse -Filter '*.inf' -ErrorAction SilentlyContinue).Count
        if ($n -eq 0 -and $r.Code -ne 0) { throw (T 'err.drivers' $r.Code) }
        Write-RBLog (T 'log.drivers.exported' $n) 'ok'
        return @{ drivers = $n }
    }
    Restore  = {
        param($Item, $Dir)
        $n = @(Get-ChildItem -LiteralPath $Dir -Recurse -Filter '*.inf' -ErrorAction SilentlyContinue).Count
        if ($Global:RB.DryRun) { Write-RBLog (T 'log.dry.drivers.restore' $n); return }
        Write-RBLog (T 'log.drivers.installing' $n)
        $r = Invoke-RBExe (Get-RBSys32 'pnputil.exe') ('/add-driver "{0}\*.inf" /subdirs /install' -f $Dir)
        # 0 = ok, 3010 = ok but reboot needed, 259 = nothing new to install
        if (@(0, 3010, 259) -notcontains $r.Code) { Write-RBLog (T 'log.drivers.partial' $r.Code) 'warn' }
        else { Write-RBLog (T 'log.drivers.done') 'ok' }
    }
}

# ------------------------------------------------------------------ wifi
Register-RBProvider @{
    Name     = 'system.wifi'
    Discover = {
        if (-not (Get-Service -Name 'WlanSvc' -ErrorAction SilentlyContinue)) { return }
        New-RBItem -Id 'system.wifi' -Provider 'system.wifi' -Category 'system' -NameKey 'item.wifi.name' `
            -DescKey 'item.wifi.desc' -Order 20 -Sensitive $true -RequiresAdmin $true
    }
    Backup   = {
        param($Item, $Dir)
        if ($Global:RB.DryRun) { Write-RBLog (T 'log.dry.wifi'); return }
        $r = Invoke-RBExe (Get-RBSys32 'netsh.exe') ('wlan export profile key=clear folder="{0}"' -f $Dir)
        $n = @(Get-ChildItem -LiteralPath $Dir -Filter '*.xml' -ErrorAction SilentlyContinue).Count
        if ($n -eq 0) { Write-RBLog (T 'log.wifi.none') 'warn'; return @{ profiles = 0 } }
        Write-RBLog (T 'log.wifi.exported' $n) 'ok'
        return @{ profiles = $n }
    }
    Restore  = {
        param($Item, $Dir)
        $files = @(Get-ChildItem -LiteralPath $Dir -Filter '*.xml' -ErrorAction SilentlyContinue)
        if ($Global:RB.DryRun) { Write-RBLog (T 'log.dry.wifi.restore' $files.Count); return }
        $ok = 0
        foreach ($f in $files) {
            $r = Invoke-RBExe (Get-RBSys32 'netsh.exe') ('wlan add profile filename="{0}" user=all' -f $f.FullName)
            if ($r.Code -eq 0) { $ok++; Write-RBLog ('    ' + $f.BaseName) } else { Write-RBLog ('    !! ' + $f.BaseName) 'warn' }
        }
        Write-RBLog (T 'log.wifi.restored' $ok $files.Count) 'ok'
    }
}

# ------------------------------------------------------------------ power plan
function Get-RBActivePowerGuid {
    $r = Invoke-RBExe (Get-RBSys32 'powercfg.exe') '/getactivescheme'
    return [regex]::Match($r.Output, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}').Value
}

Register-RBProvider @{
    Name     = 'system.power'
    Discover = {
        New-RBItem -Id 'system.power' -Provider 'system.power' -Category 'system' -NameKey 'item.power.name' `
            -DescKey 'item.power.desc' -Order 50 -RequiresAdmin $true
    }
    Backup   = {
        param($Item, $Dir)
        $guid = Get-RBActivePowerGuid
        if (-not $guid) { throw (T 'err.power') }
        if ($Global:RB.DryRun) { Write-RBLog (T 'log.dry.power' $guid); return }
        $file = Join-Path $Dir 'power-plan.pow'
        $r = Invoke-RBExe (Get-RBSys32 'powercfg.exe') ('/export "{0}" {1}' -f $file, $guid)
        if (-not (Test-Path -LiteralPath $file)) { throw (T 'err.power') }
        $list = Invoke-RBExe (Get-RBSys32 'powercfg.exe') '/list'
        [IO.File]::WriteAllText((Join-Path $Dir 'power-plans.txt'), $list.Output, [Text.Encoding]::UTF8)
        Write-RBLog (T 'log.power.exported' $guid) 'ok'
        return @{ guid = $guid }
    }
    Restore  = {
        param($Item, $Dir)
        $guid = [string]$Item.Data.guid
        $file = Join-Path $Dir 'power-plan.pow'
        if ($Global:RB.DryRun) { Write-RBLog (T 'log.dry.power.restore' $guid); return }
        $list = (Invoke-RBExe (Get-RBSys32 'powercfg.exe') '/list').Output
        if ($guid -and $list -notmatch [regex]::Escape($guid)) {
            [void](Invoke-RBExe (Get-RBSys32 'powercfg.exe') ('/import "{0}" {1}' -f $file, $guid))
        }
        $r = Invoke-RBExe (Get-RBSys32 'powercfg.exe') ('/setactive {0}' -f $guid)
        if ($r.Code -ne 0) { throw (T 'err.power') }
        Write-RBLog (T 'log.power.restored' $guid) 'ok'
    }
}

# ------------------------------------------------------------------ bitlocker (backup only)
Register-RBProvider @{
    Name     = 'system.bitlocker'
    Discover = {
        if (-not (Test-Path -LiteralPath (Get-RBSys32 'manage-bde.exe'))) { return }
        New-RBItem -Id 'system.bitlocker' -Provider 'system.bitlocker' -Category 'system' -NameKey 'item.bitlocker.name' `
            -DescKey 'item.bitlocker.desc' -Order 55 -Sensitive $true -RequiresAdmin $true -RestoreSupported $false
    }
    Backup   = {
        param($Item, $Dir)
        if ($Global:RB.DryRun) { Write-RBLog (T 'log.dry.bitlocker'); return }
        $mb = Get-RBSys32 'manage-bde.exe'
        [IO.File]::WriteAllText((Join-Path $Dir 'bitlocker-status.txt'), (Invoke-RBExe $mb '-status').Output, [Text.Encoding]::UTF8)
        $vols = @()
        try {
            $vols = @(Get-CimInstance -Namespace 'root\CIMV2\Security\MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -ErrorAction Stop |
                    Where-Object { $_.ProtectionStatus -ne 0 -and $_.DriveLetter } | ForEach-Object { $_.DriveLetter })
        } catch { }
        $sb = New-Object Text.StringBuilder
        foreach ($v in $vols) {
            [void]$sb.AppendLine("===== $v =====")
            [void]$sb.AppendLine((Invoke-RBExe $mb "-protectors -get $v").Output)
        }
        if (-not $vols.Count) { [void]$sb.AppendLine((T 'log.bitlocker.none')) }
        [IO.File]::WriteAllText((Join-Path $Dir 'bitlocker-recovery-keys.txt'), $sb.ToString(), [Text.Encoding]::UTF8)
        if ($vols.Count) { Write-RBLog (T 'log.bitlocker.saved' ($vols -join ', ')) 'ok' } else { Write-RBLog (T 'log.bitlocker.none') }
        return @{ volumes = $vols }
    }
    Restore  = $null
}

# ------------------------------------------------------------------ hosts
function Get-RBHostsPath { return (Join-Path $env:SystemRoot 'System32\drivers\etc\hosts') }

Register-RBProvider @{
    Name     = 'system.hosts'
    Discover = {
        $h = Get-RBHostsPath
        if (-not (Test-Path -LiteralPath $h)) { return }
        $n = @(Get-Content -LiteralPath $h -ErrorAction SilentlyContinue | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') }).Count
        New-RBItem -Id 'system.hosts' -Provider 'system.hosts' -Category 'system' -NameKey 'item.hosts.name' `
            -DescKey 'item.hosts.desc' -DescArgs @($n) -Order 56 -DefaultSelected ($n -gt 0) -Data @{ entries = $n }
    }
    Backup   = {
        param($Item, $Dir)
        if (-not (Copy-RBPath (Get-RBHostsPath) (Join-Path $Dir 'hosts'))) { throw (T 'err.copy' (Get-RBHostsPath)) }
    }
    Restore  = {
        param($Item, $Dir)
        $src = Join-Path $Dir 'hosts'
        $dst = Get-RBHostsPath
        if ((Test-Path -LiteralPath $dst) -and ([IO.File]::ReadAllText($src) -eq [IO.File]::ReadAllText($dst))) { Write-RBLog (T 'log.hosts.same'); return }
        if (-not (Test-RBAdmin)) { throw (T 'log.need.admin') }
        if ($Global:RB.DryRun) { Write-RBLog (T 'log.dry.copy' $src $dst); return }
        if (Test-Path -LiteralPath $dst) { Copy-Item -LiteralPath $dst -Destination ($dst + '.bak-' + (Get-Date -Format 'yyyyMMddHHmm')) -Force }
        Copy-Item -LiteralPath $src -Destination $dst -Force
        Write-RBLog (T 'log.hosts.restored') 'ok'
    }
}

# ------------------------------------------------------------------ user environment variables
$Global:RBEnvSkip = @('TEMP', 'TMP', 'OneDrive', 'OneDriveConsumer', 'OneDriveCommercial')

function Get-RBUserEnv {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
    $h = @{}
    if (-not $key) { return $h }
    try {
        foreach ($n in $key.GetValueNames()) {
            if (-not $n -or $Global:RBEnvSkip -contains $n) { continue }
            $h[$n] = @{
                value = [string]$key.GetValue($n, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                kind  = $key.GetValueKind($n).ToString()
            }
        }
    } finally { $key.Close() }
    return $h
}

Register-RBProvider @{
    Name     = 'system.envvars'
    Discover = {
        $n = @((Get-RBUserEnv).Keys).Count
        if (-not $n) { return }
        New-RBItem -Id 'system.envvars' -Provider 'system.envvars' -Category 'system' -NameKey 'item.envvars.name' `
            -DescKey 'item.envvars.desc' -DescArgs @($n) -Order 57
    }
    Backup   = {
        param($Item, $Dir)
        $vars = Get-RBUserEnv
        if ($Global:RB.DryRun) { Write-RBLog (T 'log.envvars.saved' $vars.Count); return }
        Write-RBJsonFile $vars (Join-Path $Dir 'user-environment.json')
        Write-RBLog (T 'log.envvars.saved' $vars.Count) 'ok'
    }
    Restore  = {
        param($Item, $Dir)
        $vars = Read-RBJsonFile (Join-Path $Dir 'user-environment.json')
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', -not $Global:RB.DryRun)
        $set = 0; $merged = 0; $kept = 0
        try {
            foreach ($name in @($vars.Keys)) {
                $v = $vars[$name]
                $kind = if ($v.kind -eq 'ExpandString' -or ([string]$v.value).Contains('%')) { [Microsoft.Win32.RegistryValueKind]::ExpandString } else { [Microsoft.Win32.RegistryValueKind]::String }
                $cur = $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                if ($name -eq 'Path') {
                    $curParts = @(([string]$cur) -split ';' | Where-Object { $_ })
                    $add = @(([string]$v.value) -split ';' | Where-Object { $_ -and ($curParts -notcontains $_) })
                    if ($add.Count) {
                        if (-not $Global:RB.DryRun) { $key.SetValue($name, (($curParts + $add) -join ';'), [Microsoft.Win32.RegistryValueKind]::ExpandString) }
                        Write-RBLog (T 'log.envvars.path' $add.Count)
                        $merged++
                    } else { $kept++ }
                    continue
                }
                if ($null -eq $cur -or (([string]$cur -ne [string]$v.value) -and $Global:RB.Options.Overwrite)) {
                    if (-not $Global:RB.DryRun) { $key.SetValue($name, [string]$v.value, $kind) }
                    Write-RBLog ('    {0}' -f $name)
                    $set++
                } else { $kept++ }
            }
        } finally { $key.Close() }
        Write-RBLog (T 'log.envvars.restored' $set $merged $kept) 'ok'
    }
}
