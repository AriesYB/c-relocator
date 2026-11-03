# =====================================================================
# Move-Reloc.ps1 - c-relocator migration core.
# The ONLY entrypoint allowed to move data and create links.
# Safety model (see DESIGN.md):
#   precheck -> robocopy copy (/XJ) -> rename original to *.reloc-bak
#   -> mklink /J -> sentinel verification -> manifest(backup-pending)
#   Any failure rolls back cleanly; deleting the backup is a separate
#   explicit step in Undo-Reloc.ps1 -Action confirm.
# Compatible with Windows PowerShell 5.1+. ASCII-only output.
# Exit codes: 0 ok | 10 precheck | 11 copy | 12 post steps
# =====================================================================
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Id,
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Target,
    [Parameter(Mandatory = $true)][string]$Manifest,
    [ValidateSet('junction', 'copy')][string]$Mode = 'junction',
    [string[]]$BlockProcesses = @(),
    [switch]$KeepLinks
)

$ErrorActionPreference = 'Stop'
$EC_OK = 0
$EC_PRECHECK = 10
$EC_COPY = 11
$EC_POST = 12

function Fail([int]$code, [string]$message) {
    [Console]::Error.WriteLine('[FAIL] ' + $message)
    exit $code
}

function Test-ReparsePoint([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    $attr = (Get-Item -LiteralPath $path -Force).Attributes
    return (($attr -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Test-TreeContainsReparse([string]$path) {
    $dirs = Get-ChildItem -LiteralPath $path -Recurse -Directory -Force -ErrorAction SilentlyContinue
    foreach ($d in $dirs) {
        if (($d.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $true }
    }
    return $false
}

function Get-DirBytes([string]$path) {
    $sum = (Get-ChildItem -LiteralPath $path -Recurse -File -Force -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum).Sum
    if ($null -eq $sum) { return [long]0 }
    return [long]$sum
}

function Format-Bytes([long]$b) {
    if ($b -ge 1GB) { return ('{0:N2} GB' -f ($b / 1GB)) }
    if ($b -ge 1MB) { return ('{0:N2} MB' -f ($b / 1MB)) }
    return ('{0} bytes' -f $b)
}

function Test-Sentinel([string]$linkPath, [string]$realPath) {
    # Write a sentinel into the real dir, read it back through the link path,
    # then compare the largest real file's size through the link as well.
    $name = '.creloc-sentinel-' + [System.Guid]::NewGuid().ToString('N')
    $content = [System.Guid]::NewGuid().ToString('N')
    $realFile = Join-Path $realPath $name
    Set-Content -LiteralPath $realFile -Value $content -Encoding Ascii
    try {
        $back = Get-Content -LiteralPath (Join-Path $linkPath $name) -Raw -ErrorAction Stop
        if ($back.Trim() -ne $content) { throw 'sentinel content mismatch through link' }
    }
    finally {
        Remove-Item -LiteralPath $realFile -Force -ErrorAction SilentlyContinue
    }
    $biggest = Get-ChildItem -LiteralPath $realPath -Recurse -File -Force -ErrorAction SilentlyContinue |
        Sort-Object Length -Descending | Select-Object -First 1
    if ($null -ne $biggest) {
        $rel = $biggest.FullName.Substring($realPath.Length).TrimStart('\')
        $viaLink = Get-Item -LiteralPath (Join-Path $linkPath $rel) -ErrorAction Stop
        if ($viaLink.Length -ne $biggest.Length) { throw 'largest-file size mismatch through link' }
    }
}

# Deny list (hardcoded second line of defense; rules.json declares the same paths).
$denyList = @(
    $env:SystemRoot,
    'C:\Program Files\WindowsApps',
    "$env:ProgramData\Microsoft",
    "$env:LOCALAPPDATA\Microsoft",
    "$env:APPDATA\Microsoft",
    "$env:LOCALAPPDATA\Packages",
    'C:\Program Files\Microsoft Office',
    'C:\Program Files\Common Files\microsoft shared\ClickToRun',
    "$env:ProgramData\Package Cache"
) | ForEach-Object { $_.TrimEnd('\').ToLowerInvariant() }

function Assert-NotDenied([string]$path) {
    $norm = $path.TrimEnd('\').ToLowerInvariant()
    foreach ($d in $denyList) {
        if ($norm -eq $d -or $norm.StartsWith($d + '\')) {
            Fail $EC_PRECHECK ("deny list violation: '{0}' is under protected path '{1}'" -f $path, $d)
        }
    }
}

function Read-Manifest([string]$path) {
    if (Test-Path -LiteralPath $path) {
        return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    return $null
}

function Save-Manifest([object]$m, [string]$path) {
    $dir = Split-Path -Parent $path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    Set-Content -LiteralPath $path -Value ($m | ConvertTo-Json -Depth 8) -Encoding UTF8
}

function Update-Manifest([string]$path, [string]$entryId, [string]$src, [hashtable]$fields) {
    $m = Read-Manifest $path
    if ($null -eq $m) {
        $m = New-Object PSObject -Property @{ version = 1; updatedAt = $null; entries = @() }
    }
    $entries = @()
    if ($null -ne $m.entries) { $entries = @($m.entries | Where-Object { $null -ne $_ }) }
    $idx = -1
    for ($i = 0; $i -lt $entries.Count; $i++) {
        if ($entries[$i].id -eq $entryId -and $entries[$i].source -eq $src) { $idx = $i; break }
    }
    if ($idx -ge 0) {
        $e = $entries[$idx]
        foreach ($k in $fields.Keys) {
            $e | Add-Member -MemberType NoteProperty -Name $k -Value $fields[$k] -Force
        }
        $entries[$idx] = $e
    }
    else {
        $e = New-Object PSObject -Property @{ id = $entryId; source = $src }
        foreach ($k in $fields.Keys) {
            $e | Add-Member -MemberType NoteProperty -Name $k -Value $fields[$k] -Force
        }
        $entries = @($entries) + @($e)
    }
    $m | Add-Member -MemberType NoteProperty -Name entries -Value $entries -Force
    $m | Add-Member -MemberType NoteProperty -Name updatedAt -Value (Get-Date).ToString('o') -Force
    Save-Manifest $m $path
}

# ---------------------------------------------------------------------
# resolve & normalize
# ---------------------------------------------------------------------
$srcItem = Get-Item -LiteralPath $Source -Force -ErrorAction SilentlyContinue
if ($null -eq $srcItem -or -not $srcItem.PSIsContainer) {
    Fail $EC_PRECHECK ("source does not exist or is not a directory: '{0}'" -f $Source)
}
$Source = $srcItem.FullName
$Target = $Target.TrimEnd('\')

if ([System.IO.Path]::GetPathRoot($Source).TrimEnd('\') -eq $Source.TrimEnd('\')) {
    Fail $EC_PRECHECK 'source must not be a drive root'
}
if ([System.IO.Path]::GetPathRoot($Target).TrimEnd('\') -eq $Target.TrimEnd('\')) {
    Fail $EC_PRECHECK 'target must not be a drive root'
}

Assert-NotDenied $Source
Assert-NotDenied $Target

$srcRoot = [System.IO.Path]::GetPathRoot($Source)
$tgtRoot = [System.IO.Path]::GetPathRoot($Target)
if ($srcRoot.TrimEnd('\').ToLowerInvariant() -eq $tgtRoot.TrimEnd('\').ToLowerInvariant()) {
    Fail $EC_PRECHECK 'source and target must be on different volumes (the point is to free the source drive)'
}
$di = New-Object System.IO.DriveInfo($tgtRoot)
if (-not $di.IsReady) { Fail $EC_PRECHECK ('target drive not ready: ' + $tgtRoot) }
if ($di.DriveType -ne [System.IO.DriveType]::Fixed) { Fail $EC_PRECHECK ('target drive is not a fixed local disk: ' + $tgtRoot) }
if ($di.DriveFormat -ne 'NTFS') { Fail $EC_PRECHECK ('target drive is not NTFS (junction requires NTFS): ' + $tgtRoot) }

if (Test-ReparsePoint $Source) { Fail $EC_PRECHECK ('source is already a link/reparse point: ' + $Source) }
if (-not $KeepLinks) {
    if (Test-TreeContainsReparse $Source) {
        Fail $EC_PRECHECK ('source tree contains nested reparse points; rerun with -KeepLinks to recreate them on the target side: ' + $Source)
    }
}
if (Test-Path -LiteralPath $Target) {
    $existing = @(Get-ChildItem -LiteralPath $Target -Force -ErrorAction SilentlyContinue)
    if ($existing.Count -gt 0) { Fail $EC_PRECHECK ('target exists and is not empty: ' + $Target) }
}

$srcN = $Source.TrimEnd('\').ToLowerInvariant()
$tgtN = $Target.TrimEnd('\').ToLowerInvariant()
if ($srcN -eq $tgtN -or $tgtN.StartsWith($srcN + '\') -or $srcN.StartsWith($tgtN + '\')) {
    Fail $EC_PRECHECK 'source and target paths overlap'
}

if ($BlockProcesses.Count -gt 0) {
    $running = @(Get-Process -Name $BlockProcesses -ErrorAction SilentlyContinue)
    if ($running.Count -gt 0) {
        $names = ($running | Select-Object -ExpandProperty ProcessName -Unique | Sort-Object) -join ', '
        Fail $EC_PRECHECK ('blocking processes are running: ' + $names + ' - close them and retry')
    }
}

$srcBytes = Get-DirBytes $Source
$needed = [long]($srcBytes * 1.1) + 256MB
if ($di.AvailableFreeSpace -lt $needed) {
    Fail $EC_PRECHECK ('not enough space on {0}: need ~{1}, free {2}' -f $tgtRoot, (Format-Bytes $needed), (Format-Bytes $di.AvailableFreeSpace))
}

Write-Host ('[precheck] ok. source={0} ({1})  target={2}  mode={3}' -f $Source, (Format-Bytes $srcBytes), $Target, $Mode)

# ---------------------------------------------------------------------
# copy
# ---------------------------------------------------------------------
$roboArgs = @($Source, $Target, '/E', '/COPY:DAT', '/DCOPY:DAT', '/XJ', '/R:1', '/W:1', '/MT:16', '/NP', '/NFL', '/NDL')
robocopy @roboArgs | Out-Null
$rc = $LASTEXITCODE
if ($rc -ge 8) {
    Remove-Item -LiteralPath $Target -Recurse -Force -ErrorAction SilentlyContinue
    Fail $EC_COPY ('robocopy failed with exit code {0}. Source left untouched, partial target removed.' -f $rc)
}
Write-Host ('[copy] robocopy finished, exit code {0}.' -f $rc)

# ---------------------------------------------------------------------
# -KeepLinks: robocopy /XJ skipped nested links during the copy; recreate
# each one on the target side. Junction/symlink targets that point INTO
# the source get rewritten to the new target path, so the migrated tree
# is self-contained and the original can be deleted. External targets are
# kept as-is with a warning. File symlinks need admin/dev mode to create.
# ---------------------------------------------------------------------
if ($KeepLinks) {
    $links = @(Get-ChildItem -LiteralPath $Source -Recurse -Force -Attributes ReparsePoint -ErrorAction SilentlyContinue)
    $createdCount = 0
    $warnCount = 0
    $srcPrefix = $Source.TrimEnd('\')
    $tgtPrefix = $Target.TrimEnd('\')
    foreach ($l in $links) {
        $rel = $l.FullName.Substring($Source.Length).TrimStart('\')
        $dst = Join-Path $Target $rel
        $t = $l.Target
        if ($t -is [array]) { $t = [string]$t[0] }
        $newTarget = $t
        if ($t -and $t.TrimEnd('\').ToLowerInvariant().StartsWith($srcPrefix.ToLowerInvariant() + '\')) {
            $newTarget = $tgtPrefix + $t.Substring($srcPrefix.Length)
        }
        elseif ($t) {
            Write-Host ('[links] WARN target outside source, kept as-is: ' + $l.FullName)
        }
        $parent = Split-Path -Parent $dst
        if (-not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        if ($l.LinkType -eq 'Junction') {
            try {
                New-Item -ItemType Junction -Path $dst -Value $newTarget -ErrorAction Stop | Out-Null
                $createdCount++
            }
            catch {
                Fail $EC_COPY ('failed to recreate junction: ' + $dst + ' (' + $_.Exception.Message + ')')
            }
        }
        elseif ($l.LinkType -eq 'SymbolicLink') {
            try {
                if ($l.PSIsContainer) {
                    cmd /c mklink /D "$dst" "$newTarget" | Out-Null
                }
                else {
                    cmd /c mklink "$dst" "$newTarget" | Out-Null
                }
                if ($LASTEXITCODE -ne 0) { throw ('mklink exit ' + $LASTEXITCODE) }
                $createdCount++
            }
            catch {
                $warnCount++
                Write-Host ('[links] WARN symlink recreate failed (needs admin/dev mode): ' + $dst)
            }
        }
        else {
            $warnCount++
            Write-Host ('[links] WARN unknown link type "' + $l.LinkType + '": ' + $l.FullName)
        }
    }
    Write-Host ('[links] recreated {0} link(s), {1} warning(s).' -f $createdCount, $warnCount)
}

# ---------------------------------------------------------------------
# post steps
# ---------------------------------------------------------------------
if ($Mode -eq 'junction') {
    $parent = Split-Path -Parent $Source
    $leaf = Split-Path -Leaf $Source
    $bakPath = Join-Path $parent ($leaf + '.reloc-bak')
    if (Test-Path -LiteralPath $bakPath) {
        Fail $EC_PRECHECK ('backup path already exists: ' + $bakPath)
    }
    Rename-Item -LiteralPath $Source -NewName ($leaf + '.reloc-bak')
    cmd /c mklink /J "$Source" "$Target" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        if (Test-Path -LiteralPath $Source) { cmd /c rmdir "$Source" 2>$null | Out-Null }
        Rename-Item -LiteralPath $bakPath -NewName $leaf
        Fail $EC_POST ('junction creation failed (mklink exit {0}). Rolled back to original directory.' -f $LASTEXITCODE)
    }
    try {
        Test-Sentinel -linkPath $Source -realPath $Target
    }
    catch {
        cmd /c rmdir "$Source" | Out-Null
        Rename-Item -LiteralPath $bakPath -NewName $leaf
        Remove-Item -LiteralPath $Target -Recurse -Force -ErrorAction SilentlyContinue
        Fail $EC_POST ('sentinel verification failed ({0}). Rolled back: link removed, original dir restored, target data removed.' -f $_.Exception.Message)
    }
    Update-Manifest -path $Manifest -entryId $Id -src $Source -fields @{
        mechanism = 'junction'
        target    = $Target
        bytes     = $srcBytes
        movedAt   = (Get-Date).ToString('o')
        backup    = $bakPath
        status    = 'backup-pending'
    }
    Write-Host ('[done] junction active: {0} -> {1}' -f $Source, $Target)
    Write-Host ('[next] backup kept at: {0}' -f $bakPath)
    Write-Host ('[next] after verifying the app works: Undo-Reloc.ps1 -Action confirm -Id {0} -Manifest "{1}"' -f $Id, $Manifest)
    exit $EC_OK
}
else {
    Update-Manifest -path $Manifest -entryId $Id -src $Source -fields @{
        mechanism = 'copy'
        target    = $Target
        bytes     = $srcBytes
        movedAt   = (Get-Date).ToString('o')
        backup    = $Source
        status    = 'copy-done'
    }
    Write-Host ('[done] data copied: {0} -> {1}' -f $Source, $Target)
    Write-Host ('[next] apply config steps, run verify commands, then: Undo-Reloc.ps1 -Action confirm -Id {0} -Manifest "{1}"' -f $Id, $Manifest)
    exit $EC_OK
}
