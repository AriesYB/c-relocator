# =====================================================================
# Scan-Reloc.ps1 - c-relocator read-only scanner.
# Sizes rules.json entries against the manifest and (optionally) lists
# the biggest sub-directories under user roots to find new offenders.
# Performs NO write operations. Compatible with PowerShell 5.1+.
# =====================================================================
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Rules,
    [string]$Manifest,
    [switch]$TopDirs,
    [string[]]$TopRoots = @(),
    [int]$Top = 20,
    [switch]$SkipSizes,
    [string[]]$Ids = @()
)

$ErrorActionPreference = 'Continue'

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

if (-not (Test-Path -LiteralPath $Rules)) {
    [Console]::Error.WriteLine('rules file not found: ' + $Rules)
    exit 2
}

$rulesDoc = Get-Content -LiteralPath $Rules -Raw -Encoding UTF8 | ConvertFrom-Json
$ruleList = @($rulesDoc.rules)
if ($Ids.Count -gt 0) { $ruleList = @($ruleList | Where-Object { $Ids -contains $_.id }) }

$bySource = @{}
if ($Manifest -and (Test-Path -LiteralPath $Manifest)) {
    $m = Get-Content -LiteralPath $Manifest -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($m -and $m.entries) {
        foreach ($e in @($m.entries)) {
            if ($null -ne $e -and $e.source) { $bySource[$e.source.ToLowerInvariant()] = [string]$e.status }
        }
    }
}

Write-Host '=== rules scan ==='
foreach ($r in $ruleList) {
    if ([string]$r.mechanism -eq 'deny') {
        Write-Host ('[deny  ] {0}  ({1})' -f $r.name, $r.id)
        foreach ($p in @($r.detect.paths)) {
            Write-Host ('         ' + [Environment]::ExpandEnvironmentVariables($p))
        }
        continue
    }
    Write-Host ('')
    Write-Host ('[{0}] {1}' -f $r.id, $r.name)
    Write-Host ('  mechanism={0} risk={1}' -f $r.mechanism, $r.risk)
    foreach ($p in @($r.detect.paths)) {
        $x = [Environment]::ExpandEnvironmentVariables($p)
        if (-not (Test-Path -LiteralPath $x)) {
            Write-Host ('  {0,-10} {1,12}  {2}' -f 'missing', '-', $x)
            continue
        }
        $attr = (Get-Item -LiteralPath $x -Force).Attributes
        if (($attr -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            Write-Host ('  {0,-10} {1,12}  {2}' -f 'LINKED', '-', $x)
            continue
        }
        $st = $bySource[$x.ToLowerInvariant()]
        if ($st -eq 'active' -or $st -eq 'copy-done' -or $st -eq 'backup-pending') {
            Write-Host ('  {0,-10} {1,12}  {2}' -f 'migrated', '-', $x)
            continue
        }
        if ($SkipSizes) {
            Write-Host ('  {0,-10} {1,12}  {2}' -f 'candidate', '?', $x)
        }
        else {
            $b = Get-DirBytes $x
            Write-Host ('  {0,-10} {1,12}  {2}' -f 'candidate', (Format-Bytes $b), $x)
        }
    }
}

if ($TopDirs) {
    $roots = $TopRoots
    if ($roots.Count -eq 0) { $roots = @($env:LOCALAPPDATA, $env:APPDATA, $env:USERPROFILE) }
    foreach ($root in $roots) {
        if (-not $root -or -not (Test-Path -LiteralPath $root)) { continue }
        Write-Host ('')
        Write-Host ('=== top {0} sub-directories under {1} ===' -f $Top, $root)
        $kids = @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0 })
        $rows = @()
        foreach ($k in $kids) {
            if ($SkipSizes) {
                $rows += ,@($k.Name, [long]-1)
            }
            else {
                $rows += ,@($k.Name, (Get-DirBytes $k.FullName))
            }
        }
        if (-not $SkipSizes) {
            $rows = @($rows | Sort-Object { [long]$_[1] } -Descending)
        }
        $shown = 0
        foreach ($row in $rows) {
            if ($shown -ge $Top) { break }
            $size = '?'
            if ($SkipSizes -eq $false -and [long]$row[1] -ge 0) { $size = Format-Bytes ([long]$row[1]) }
            Write-Host ('  {0,12}  {1}' -f $size, $row[0])
            $shown++
        }
    }
}

Write-Host ''
Write-Host '=== scan finished (read-only, nothing was written) ==='
exit 0
