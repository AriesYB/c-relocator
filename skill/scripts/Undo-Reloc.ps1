# =====================================================================
# Undo-Reloc.ps1 - c-relocator undo / rebuild / confirm-delete.
#   undo    : restore data/links + recorded env vars, PATH, config files
#   rebuild : recreate lost junctions after a Windows reinstall
#   confirm : re-verify, then delete the backup (the ONLY irreversible step)
# Reads the manifest produced by Move-Reloc.ps1. PowerShell 5.1+.
# Exit codes: 0 ok | 20 failure
# =====================================================================
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('undo', 'rebuild', 'confirm')][string]$Action,
    [Parameter(Mandatory = $true)][string]$Manifest,
    [string]$Id
)

$ErrorActionPreference = 'Stop'
$EC_OK = 0
$EC_FAIL = 20

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

function Test-Sentinel([string]$linkPath, [string]$realPath) {
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

function Set-EntryFields([string]$path, [object]$m, [object]$entry, [hashtable]$fields) {
    foreach ($k in $fields.Keys) {
        $entry | Add-Member -MemberType NoteProperty -Name $k -Value $fields[$k] -Force
    }
    $m | Add-Member -MemberType NoteProperty -Name updatedAt -Value (Get-Date).ToString('o') -Force
    Save-Manifest $m $path
}

function Restore-ConfigUndo([object]$entry) {
    if ($null -eq $entry.configUndo) { return }
    foreach ($u in @($entry.configUndo)) {
        try {
            if ($u.type -eq 'env') {
                [Environment]::SetEnvironmentVariable($u.name, $u.previousValue, 'User')
                if ($null -eq $u.previousValue) {
                    Write-Host ('[cfgundo] env removed: ' + $u.name)
                }
                else {
                    Write-Host ('[cfgundo] env restored: ' + $u.name)
                }
            }
            elseif ($u.type -eq 'path') {
                [Environment]::SetEnvironmentVariable('Path', $u.previousValue, 'User')
                Write-Host '[cfgundo] user PATH restored'
            }
            elseif ($u.type -eq 'file') {
                if (Test-Path -LiteralPath $u.backup) {
                    $dir = Split-Path -Parent $u.original
                    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
                        New-Item -ItemType Directory -Path $dir -Force | Out-Null
                    }
                    Copy-Item -LiteralPath $u.backup -Destination $u.original -Force
                    Write-Host ('[cfgundo] file restored: ' + $u.original)
                }
            }
        }
        catch {
            Write-Host ('[cfgundo] WARN restore failed for {0}: {1}' -f $u.type, $_.Exception.Message)
        }
    }
}

function Move-Back([string]$fromDir, [string]$toDir) {
    robocopy $fromDir $toDir '/E' '/MOVE' '/COPY:DAT' '/DCOPY:DAT' '/R:1' '/W:1' '/NP' '/NFL' '/NDL' | Out-Null
    if ($LASTEXITCODE -ge 8) { throw ('robocopy move-back failed, exit ' + $LASTEXITCODE) }
    Remove-Item -LiteralPath $fromDir -Recurse -Force -ErrorAction SilentlyContinue
}

function Invoke-Undo([object]$e) {
    if ($e.mechanism -eq 'junction') {
        $bak = [string]$e.backup
        if ($bak -and (Test-Path -LiteralPath $bak)) {
            if (Test-ReparsePoint $e.source) {
                cmd /c rmdir "$($e.source)" | Out-Null
                if (Test-Path -LiteralPath $e.source) { throw 'failed to remove junction' }
            }
            elseif (Test-Path -LiteralPath $e.source) {
                throw ('source exists as a real directory, conflict: ' + $e.source)
            }
            Rename-Item -LiteralPath $bak -NewName (Split-Path -Leaf $e.source)
            Restore-ConfigUndo $e
            Set-EntryFields $Manifest $script:m $e @{ status = 'undone'; backup = $null }
            Write-Host ('[undo] ok (backup restored): ' + $e.source)
        }
        else {
            # backup already deleted (confirmed earlier): move data back from target
            if (-not (Test-ReparsePoint $e.source)) { throw 'source is not a junction; nothing to undo' }
            if (-not (Test-Path -LiteralPath $e.target)) { throw 'target data missing; cannot move back' }
            cmd /c rmdir "$($e.source)" | Out-Null
            Move-Back $e.target $e.source
            Restore-ConfigUndo $e
            Set-EntryFields $Manifest $script:m $e @{ status = 'undone'; backup = $null }
            Write-Host ('[undo] ok (data moved back): ' + $e.source)
        }
    }
    elseif ($e.mechanism -eq 'copy') {
        if (Test-ReparsePoint $e.source) { throw ('source unexpectedly a reparse point, manual review: ' + $e.source) }
        if (Test-Path -LiteralPath $e.source) {
            # original still in place: just drop the copy on the target drive
            if (Test-Path -LiteralPath $e.target) {
                if (Test-TreeContainsReparse $e.target) { throw ('target tree contains reparse points, manual review: ' + $e.target) }
                Remove-Item -LiteralPath $e.target -Recurse -Force
            }
        }
        else {
            # confirmed earlier: data lives only at target -> move back
            if (-not (Test-Path -LiteralPath $e.target)) { throw 'both source and target missing' }
            Move-Back $e.target $e.source
        }
        Restore-ConfigUndo $e
        Set-EntryFields $Manifest $script:m $e @{ status = 'undone'; backup = $null }
        Write-Host ('[undo] ok: ' + $e.source)
    }
    else {
        Write-Host ('[skip] unknown mechanism: ' + $e.mechanism)
    }
}

# ---------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $Manifest)) { Fail $EC_FAIL ('manifest not found: ' + $Manifest) }
$script:m = Read-Manifest $Manifest
$all = @()
if ($null -ne $script:m.entries) { $all = @($script:m.entries | Where-Object { $null -ne $_ }) }
$targets = $all
if ($Id) {
    $targets = @($all | Where-Object { $_.id -eq $Id })
    if ($targets.Count -eq 0) { Fail $EC_FAIL ('no manifest entries for id: ' + $Id) }
}

switch ($Action) {

    'undo' {
        foreach ($e in $targets) {
            try { Invoke-Undo $e }
            catch { Write-Host ('[fail] {0}: {1}' -f $e.id, $_.Exception.Message) }
        }
    }

    'rebuild' {
        $okCount = 0; $skipCount = 0; $badCount = 0
        $junctions = @($targets | Where-Object { $_.mechanism -eq 'junction' })
        foreach ($e in $junctions) {
            if (-not (Test-Path -LiteralPath $e.target)) {
                Write-Host ('[fail] target data missing: ' + $e.target); $badCount++; continue
            }
            if (Test-ReparsePoint $e.source) {
                Write-Host ('[ok]   link already present: ' + $e.source); $skipCount++; continue
            }
            $parent = Split-Path -Parent $e.source
            if (-not (Test-Path -LiteralPath $parent)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }
            if (Test-Path -LiteralPath $e.source) {
                $count = @(Get-ChildItem -LiteralPath $e.source -Force -ErrorAction SilentlyContinue).Count
                if ($count -gt 0) {
                    Write-Host ('[fail] source exists as non-empty real dir, conflict: ' + $e.source); $badCount++; continue
                }
                Remove-Item -LiteralPath $e.source -Force
            }
            cmd /c mklink /J "$($e.source)" "$($e.target)" | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Host ('[fail] mklink failed: ' + $e.source); $badCount++; continue
            }
            Set-EntryFields $Manifest $script:m $e @{ status = 'active'; backup = $null }
            $okCount++
            Write-Host ('[ok]   rebuilt: ' + $e.source)
        }
        Write-Host ('[rebuild] done: rebuilt={0} already-ok={1} failed={2}' -f $okCount, $skipCount, $badCount)
    }

    'confirm' {
        foreach ($e in $targets) {
            if ($e.mechanism -eq 'junction') {
                if (-not (Test-ReparsePoint $e.source)) {
                    Write-Host ('[fail] not a junction: ' + $e.source); continue
                }
                try { Test-Sentinel -linkPath $e.source -realPath $e.target }
                catch {
                    Write-Host ('[fail] sentinel verification failed, backup NOT deleted: ' + $_.Exception.Message); continue
                }
                $bak = [string]$e.backup
                if ($bak -and (Test-Path -LiteralPath $bak)) {
                    if (Test-ReparsePoint $bak) {
                        Write-Host ('[fail] backup unexpectedly a reparse point, manual review: ' + $bak); continue
                    }
                    if (Test-TreeContainsReparse $bak) {
                        Write-Host ('[fail] backup tree contains reparse points, manual review: ' + $bak); continue
                    }
                    Remove-Item -LiteralPath $bak -Recurse -Force
                    Write-Host ('[confirm] backup deleted: ' + $bak)
                }
                else {
                    Write-Host '[confirm] backup already absent'
                }
                Set-EntryFields $Manifest $script:m $e @{ status = 'active'; backup = $null }
            }
            elseif ($e.mechanism -eq 'copy') {
                if (Test-ReparsePoint $e.source) {
                    Write-Host ('[fail] source is a reparse point, manual review: ' + $e.source); continue
                }
                if (Test-Path -LiteralPath $e.source) {
                    if (Test-TreeContainsReparse $e.source) {
                        Write-Host ('[fail] source tree contains reparse points, manual review: ' + $e.source); continue
                    }
                    Remove-Item -LiteralPath $e.source -Recurse -Force
                    Write-Host ('[confirm] stale source deleted: ' + $e.source)
                }
                else {
                    Write-Host '[confirm] source already absent'
                }
                Set-EntryFields $Manifest $script:m $e @{ status = 'active'; backup = $null }
            }
        }
    }
}

exit $EC_OK
