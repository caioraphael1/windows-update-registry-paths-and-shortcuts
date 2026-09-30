
param(
    [Parameter(Mandatory)] [string]$OldPath,
    [Parameter(Mandatory)] [string]$NewPath,
    [Parameter(Mandatory)] [bool]$Preview,
    [string]$BackupDir
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- normalize input
$old = $OldPath.Trim().Trim('"').TrimEnd('\', '/')
$new = $NewPath.Trim().Trim('"').TrimEnd('\', '/')
if ($old -ieq $new) { throw 'OldPath and NewPath are the same.' }

$map = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
function Add-Variant([string]$from, [string]$to) {
    if ($from -and -not $map.ContainsKey($from)) { $map[$from] = $to }
}

Add-Variant $old $new
Add-Variant $old.Replace('\', '/')  $new.Replace('\', '/')    # C:/x  and file:///C:/x
Add-Variant $old.Replace('\', '\\') $new.Replace('\', '\\')   # C:\\x (escaped)


# ---------------------------------------------------------------- build path variants

# %ENVVAR%\rest forms, for every env var whose value is a parent of OldPath
foreach ($e in [Environment]::GetEnvironmentVariables().GetEnumerator()) {
    $v = "$($e.Value)".TrimEnd('\')
    if ($v.Length -lt 2) { continue }
    if ($old.Equals($v, 'OrdinalIgnoreCase') -or $old.StartsWith($v + '\', 'OrdinalIgnoreCase')) {
        Add-Variant ('%' + $e.Key + '%' + $old.Substring($v.Length)) $new
    }
}

$sorted  = $map.Keys | Sort-Object Length -Descending
$pattern = '(?:' + (($sorted | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')(?![\w\-\.~])'
$regex   = New-Object System.Text.RegularExpressions.Regex($pattern, 'IgnoreCase')
$evaluator = [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $script:map[$m.Value] }

function Convert-Text([string]$s) { 
    $regex.Replace($s, $evaluator)
}

Write-Host "Mode: $(if ($Preview) { 'PREVIEW (no changes)' } else { 'APPLY' })" -ForegroundColor Cyan
Write-Host 'Matching these forms (case-insensitive):'
$map.GetEnumerator() | ForEach-Object { Write-Host "  $($_.Key)  ->  $($_.Value)" }
Write-Host ''

# ---------------------------------------------------------------- admin check
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).
    IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Warning 'Not running as Administrator: HKLM (and other users'' hives) can be scanned but not changed.'
}

# ---------------------------------------------------------------- roots to scan
$roots = @(
    [pscustomobject]@{ Hive = 'CurrentUser';  Sub = 'Software' }
    [pscustomobject]@{ Hive = 'CurrentUser';  Sub = 'Environment' }
    [pscustomobject]@{ Hive = 'LocalMachine'; Sub = 'Software' }
    [pscustomobject]@{ Hive = 'LocalMachine'; Sub = 'SYSTEM\CurrentControlSet\Services' }
    [pscustomobject]@{ Hive = 'LocalMachine'; Sub = 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment' }
)

$mySid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$hku = [Microsoft.Win32.RegistryKey]::OpenBaseKey('Users', 'Registry64')
foreach ($sid in $hku.GetSubKeyNames()) {
    if ($sid -eq $mySid -or $sid -eq "${mySid}_Classes") { continue }
    $roots += [pscustomobject]@{ Hive = 'Users'; Sub = $sid }
}
$hku.Close()


# ---------------------------------------------------------------- backup
if (-not $Preview -and $BackupDir) {
    New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
    $abbr = @{ CurrentUser = 'HKCU'; LocalMachine = 'HKLM'; Users = 'HKU' }
    $i = 0
    foreach ($r in $roots) {
        $target = "$($abbr[$r.Hive])\$($r.Sub)"
        $file = Join-Path $BackupDir ('{0:00}_{1}.reg' -f $i++, ($target -replace '[\\ :]', '_'))
        Write-Host "Backing up $target ..."
        & reg.exe export $target $file /y | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Backup of $target failed. Aborting before any change." }
    }
    Write-Host "Backups saved in $BackupDir" -ForegroundColor Green
    Write-Host ''
}

# ---------------------------------------------------------------- counters
$script:keysScanned = 0
$script:found       = 0
$script:changed     = 0
$script:failed      = 0
$script:skippedKeys = 0
$script:binaryHits  = 0
$script:keyNameHits = 0

# ---------------------------------------------------------------- helpers
function Show-Change([string]$tag, $key, [string]$name, $before, $after) {
    $display = if ($name -eq '') { '(Default)' } else { $name }
    $color = if ($tag -eq 'CHANGED') { 'Green' } else { 'Yellow' }
    Write-Host "${tag}: [$($key.Name)]" -ForegroundColor $color
    Write-Host "  $display"
    Write-Host "    $before"
    Write-Host " -> $after"
    Write-Host ''
}

function Test-Binary($bytes) {
    if ($bytes -isnot [byte[]] -or $bytes.Length -lt 8 -or $bytes.Length -gt 1MB) { return $false }
    if ($regex.IsMatch([Text.Encoding]::Unicode.GetString($bytes))) { return $true }
    if ($regex.IsMatch([Text.Encoding]::Unicode.GetString($bytes, 1, $bytes.Length - 1))) { return $true }
    return $regex.IsMatch([Text.Encoding]::GetEncoding(28591).GetString($bytes))
}

function Open-Sub($parent, [string]$name) {
    if (-not $Preview) {
        try { $k = $parent.OpenSubKey($name, $true); if ($k) { return $k } } catch { }
    }
    try { return $parent.OpenSubKey($name, $false) } catch { $script:skippedKeys++; return $null }
}

function Update-RegistryValues([Microsoft.Win32.RegistryKey]$key) {
    foreach ($name in $key.GetValueNames()) {
        try {
            $kind  = $key.GetValueKind($name).ToString()
            $value = $key.GetValue($name, $null, 'DoNotExpandEnvironmentNames')
        } catch {
            Write-Warning "Could not read [$($key.Name)] '$name': $($_.Exception.Message)"
            continue
        }

        # value NAME
        $newName = $name
        if ($name -ne '' -and $regex.IsMatch($name)) { $newName = Convert-Text $name }
        $nameChanged = ($newName -cne $name)

        # value DATA
        $newValue    = $value
        $dataChanged = $false
        $beforeText  = $value
        $afterText   = $null

        if ($kind -eq 'String' -or $kind -eq 'ExpandString') {
            if ($value -is [string] -and $regex.IsMatch($value)) {
                $newValue = Convert-Text $value
                $dataChanged = $true
                $afterText = $newValue
            }
        }
        elseif ($kind -eq 'MultiString') {
            if ($value -is [string[]]) {
                $items = foreach ($s in $value) {
                    if ($regex.IsMatch($s)) { $dataChanged = $true; Convert-Text $s } else { $s }
                }
                if ($dataChanged) {
                    $newValue   = [string[]]@($items)
                    $beforeText = $value -join ' | '
                    $afterText  = $newValue -join ' | '
                }
            }
        }
        elseif ($kind -eq 'Binary') {
            if (Test-Binary $value) {
                $script:binaryHits++
                Write-Host "BINARY (reported only, NOT changed): [$($key.Name)]  '$name'" -ForegroundColor Magenta
                Write-Host ''
            }
            if (-not $nameChanged) { continue }
        }

        if (-not ($dataChanged -or $nameChanged)) { continue }
        $script:found++

        $shownBefore = if ($dataChanged) { $beforeText } else { "(name) $name" }
        $shownAfter  = if ($dataChanged) { $afterText  } else { "(name) $newName" }
        if ($dataChanged -and $nameChanged) {
            $shownBefore = "(name) $name = $beforeText"
            $shownAfter  = "(name) $newName = $afterText"
        }

        if ($Preview) {
            Show-Change 'PREVIEW' $key $name $shownBefore $shownAfter
            continue
        }

        try {
            if ($nameChanged -and ($key.GetValueNames() -contains $newName)) {
                throw "A value named '$newName' already exists in this key."
            }
            $key.SetValue($newName, $newValue, $kind)
            if ($nameChanged) { $key.DeleteValue($name) }
            $script:changed++
            Show-Change 'CHANGED' $key $name $shownBefore $shownAfter
        } catch {
            $script:failed++
            Write-Warning "Could not update [$($key.Name)] '$name'"
            Write-Warning "    Reason: $($_.Exception.Message)"
        }
    }
}

function Search-RegistryKey([Microsoft.Win32.RegistryKey]$key) {
    $script:keysScanned++
    Update-RegistryValues $key

    $subNames = try { $key.GetSubKeyNames() } catch { @() }
    foreach ($sub in $subNames) {
        if ($regex.IsMatch($sub)) {
            $script:keyNameHits++
            Write-Host "KEY NAME contains path (reported only, NOT changed): [$($key.Name)\$sub]" -ForegroundColor Magenta
            Write-Host ''
        }
        $child = Open-Sub $key $sub
        if ($child) {
            try { Search-RegistryKey $child } finally { $child.Close() }
        }
    }
}

# ---------------------------------------------------------------- scan the registry
foreach ($r in $roots) {
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($r.Hive, 'Registry64')
    $rootKey = Open-Sub $base $r.Sub
    if (-not $rootKey) {
        Write-Warning "Could not open $($r.Hive)\$($r.Sub)"
        $base.Close()
        continue
    }
    Write-Host "Scanning $($rootKey.Name) ..." -ForegroundColor Cyan
    try { Search-RegistryKey $rootKey } finally { $rootKey.Close(); $base.Close() }
}

# ---------------------------------------------------------------- shortcuts (.lnk)
$lnkFound = 0; $lnkChanged = 0
Write-Host ''
Write-Host 'Scanning shortcuts ...' -ForegroundColor Cyan
$dirs = @(
    [Environment]::GetFolderPath('Desktop')
    [Environment]::GetFolderPath('CommonDesktopDirectory')
    [Environment]::GetFolderPath('StartMenu')
    [Environment]::GetFolderPath('CommonStartMenu')
    [Environment]::GetFolderPath('SendTo')
    "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch"   # includes User Pinned\TaskBar
) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique

$shell = New-Object -ComObject WScript.Shell
foreach ($dir in $dirs) {
    Get-ChildItem -LiteralPath $dir -Recurse -Filter *.lnk -Force -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $lnk = $shell.CreateShortcut($_.FullName)
            $dirty = $false
            foreach ($prop in 'TargetPath', 'Arguments', 'WorkingDirectory', 'IconLocation') {
                $cur = [string]$lnk.$prop
                if ($cur -and $regex.IsMatch($cur)) {
                    $upd = Convert-Text $cur
                    Write-Host "$(if ($Preview) {'PREVIEW'} else {'CHANGED'}): $($_.FullName)  [$prop]" -ForegroundColor Yellow
                    Write-Host "    $cur"
                    Write-Host " -> $upd"
                    Write-Host ''
                    if (-not $Preview) { $lnk.$prop = $upd; $dirty = $true }
                    $script:lnkFound++
                }
            }
            if ($dirty) { $lnk.Save(); $script:lnkChanged++ }
        } catch {
            Write-Warning "Could not process shortcut $($_.FullName): $($_.Exception.Message)"
        }
    }
}

# ---------------------------------------------------------------- refresh Explorer icons
if (-not $Preview -and ($script:changed -gt 0 -or $lnkChanged -gt 0)) {
    try {
        Add-Type -Namespace Win32 -Name ShellNotify -MemberDefinition @'
[DllImport("shell32.dll")]
public static extern void SHChangeNotify(int wEventId, uint uFlags, System.IntPtr dwItem1, System.IntPtr dwItem2);
'@
        # SHCNE_ASSOCCHANGED = 0x08000000: tells Explorer associations/icons changed
        [Win32.ShellNotify]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)
        Write-Host 'Sent "associations changed" notification to Explorer.' -ForegroundColor Green
    } catch {
        Write-Warning "Could not notify Explorer: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------- summary
Write-Host ''
Write-Host '================ SUMMARY ================' -ForegroundColor Cyan
Write-Host "Keys scanned:                 $script:keysScanned"
Write-Host "Values matching:              $script:found"
if (-not $Preview) {
    Write-Host "Values changed:               $script:changed"
    Write-Host "Values that failed:           $script:failed"
}
Write-Host "Keys not accessible (skipped):$script:skippedKeys"
Write-Host "Binary values with the path:  $script:binaryHits   (reported only)"
Write-Host "Key names with the path:      $script:keyNameHits   (reported only)"
Write-Host "Shortcut properties matching: $lnkFound"
if (-not $Preview) { Write-Host "Shortcuts changed:            $lnkChanged" }
if ($script:binaryHits -gt 0 -or $script:keyNameHits -gt 0) {
    Write-Host ''
    Write-Host 'Binary values and key names are usually MRU lists / history and are harmless to leave;' -ForegroundColor DarkGray
    Write-Host 'review the magenta entries above if anything still points to the old location.' -ForegroundColor DarkGray
}
