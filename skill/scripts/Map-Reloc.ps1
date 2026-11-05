# =====================================================================
# Map-Reloc.ps1 - c-relocator disk-usage mapper.
#
# Two modes:
#   1) Static export: walk + write a self-contained HTML treemap.
#        Map-Reloc.ps1 -Root C:\ -Depth 4 -MinMB 50 -Out map.html
#   2) Live server (-Serve): localhost HTTP server with a SpaceSniffer-style
#      live viewer - blocks grow in real time while scanning, click any
#      directory to lazily scan/drill into it. Stop with Ctrl+C.
#        Map-Reloc.ps1 -Serve -Root C:\ -Port 8734
# Read-only, links never followed, deny-list pruning by default
# (-NoPruneDeny disables). PowerShell 5.1+. ASCII-only script text.
# =====================================================================
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Root,
    [int]$Depth = 4,
    [double]$MinMB = 50,
    [string]$Out = '',
    [switch]$NoPruneDeny,
    [string]$Rules = '',
    [switch]$Serve,
    [int]$Port = 8734,
    [int]$ServeDepth = 2
)

$ErrorActionPreference = 'Continue'

# NOTE: functions must be defined before first use (script runs top-down).
function NormPath([string]$p) {
    # 'C:\' must stay 'C:\' - trimming the backslash turns it into 'C:',
    # which .NET resolves to the process current directory ON that drive.
    $p = $p.TrimEnd('\')
    if ($p -match '^[A-Za-z]:$') { $p += '\' }
    return $p
}
function NodeName([string]$p) {
    if ($p.EndsWith(':\')) { return $p }
    return Split-Path -Leaf $p
}

if (-not (Test-Path -LiteralPath $Root)) {
    [Console]::Error.WriteLine('root not found: ' + $Root)
    exit 2
}
$rootItem = Get-Item -LiteralPath $Root -Force
if (-not $rootItem.PSIsContainer) {
    [Console]::Error.WriteLine('root is not a directory: ' + $Root)
    exit 2
}
$Root = NormPath $rootItem.FullName
$minBytes = [long]($MinMB * 1MB)

# Deny prefixes from rules.json (same pruning contract as Scan-Reloc).
$denyPrefixes = @()
if (-not $NoPruneDeny -and $Rules -and (Test-Path -LiteralPath $Rules)) {
    try {
        $rulesDoc = Get-Content -LiteralPath $Rules -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($rD in @($rulesDoc.rules)) {
            if ([string]$rD.mechanism -ne 'deny') { continue }
            foreach ($pD in @($rD.detect.paths)) {
                $denyPrefixes += ,([Environment]::ExpandEnvironmentVariables($pD).TrimEnd('\').ToLowerInvariant())
            }
        }
    } catch { }
}
function Test-UnderDenyPrefix([string]$path) {
    if ($denyPrefixes.Count -eq 0) { return $false }
    $n = $path.TrimEnd('\').ToLowerInvariant()
    foreach ($d in $denyPrefixes) {
        if ($n -eq $d -or $n.StartsWith($d + '\')) { return $true }
    }
    return $false
}

function New-Node([string]$name) {
    return @{ n = $name; s = [long]0; c = @( ) }
}

function Get-Tree([string]$path, [int]$depthLeft) {
    $node = New-Node (NodeName $path)
    $children = @(Get-ChildItem -LiteralPath $path -Force -ErrorAction SilentlyContinue)
    foreach ($item in $children) {
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
        if ($item.PSIsContainer) {
            if (Test-UnderDenyPrefix $item.FullName) { continue }
            if ($depthLeft -gt 0) {
                $child = Get-Tree $item.FullName ($depthLeft - 1)
                $node.s += $child.s
                $node.c += ,$child
            }
            else {
                $sum = (Get-ChildItem -LiteralPath $item.FullName -Recurse -File -Force -ErrorAction SilentlyContinue |
                    Measure-Object -Property Length -Sum).Sum
                if ($null -eq $sum) { $sum = 0 }
                $node.s += [long]$sum
                if ([long]$sum -ge $minBytes) {
                    $leaf = New-Node $item.Name
                    $leaf.s = [long]$sum
                    $node.c += ,$leaf
                }
            }
        }
        else {
            $node.s += [long]$item.Length
            if ([long]$item.Length -ge $minBytes -and $node.c.Count -lt 400) {
                $leaf = New-Node $item.Name
                $leaf.s = [long]$item.Length
                $node.c += ,$leaf
            }
        }
    }
    return $node
}

function Prune-Tree($node) {
    if ($node.c.Count -eq 0) { return }
    $kept = @()
    foreach ($k in $node.c) {
        Prune-Tree $k
        if ([long]$k.s -ge $minBytes) { $kept += ,$k }
    }
    $node.c = @($kept | Sort-Object { [long]$_.s } -Descending)
}

# =====================================================================
# Live server mode
# =====================================================================
if ($Serve) {

    $state = [hashtable]::Synchronized(@{})
    $state.lock = New-Object object
    $state.trees = @{}                                    # lower(path) -> shared node
    $state.queue = New-Object System.Collections.Queue    # scan jobs
    $state.errs = (New-Object System.Collections.ArrayList)
    $state.deny = $denyPrefixes
    $state.minBytes = $minBytes
    $state.depth = $ServeDepth
    $state.rootPath = $Root
    $state.version = [long]0                              # 每次增量 flush +1，SSE 靠它判断是否有新数据

    # Worker: GCI-based enumeration (proven reliable in this context).
    # Attaches a placeholder node per child as soon as it is discovered so
    # the viewer shows blocks growing live instead of waiting for the scan.
    $workerScript = {
        param($state)
        function NormPath([string]$p) {
            $p = $p.TrimEnd('\')
            if ($p -match '^[A-Za-z]:$') { $p += '\' }
            return $p
        }
        function UnderDeny([string]$p) {
            if ($state.deny.Count -eq 0) { return $false }
            $n = $p.TrimEnd('\').ToLowerInvariant()
            foreach ($d in $state.deny) { if ($n -eq $d -or $n.StartsWith($d + '\')) { return $true } }
            return $false
        }
        function SumTree([string]$path) {
            $s = (Get-ChildItem -LiteralPath $path -Recurse -File -Force -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
            if ($null -eq $s) { $s = 0 }
            return [long]$s
        }
        function ScanInto($node, $path, $depthLeft) {
            # $pending = 尚未刷入 $node.s 的字节数；周期性加锁刷新（16MB/400项/250ms 任一触发）
            $pending = [long]0
            $nItems = 0
            $lastFlush = [DateTime]::UtcNow
            $bigFiles = New-Object System.Collections.ArrayList
            $children = @(Get-ChildItem -LiteralPath $path -Force -ErrorAction SilentlyContinue)
            foreach ($it in $children) {
                $nItems++
                if (($it.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                if ($it.PSIsContainer) {
                    if (UnderDeny $it.FullName) { continue }
                    if ($depthLeft -gt 0) {
                        $cn = @{ n = $it.Name; s = [long]0; done = $false; c = (New-Object System.Collections.ArrayList); path = $it.FullName.TrimEnd('\') }
                        [System.Threading.Monitor]::Enter($state.lock)
                        try { $null = $node.c.Add($cn) } finally { [System.Threading.Monitor]::Exit($state.lock) }
                        ScanInto $cn $it.FullName ($depthLeft - 1)
                        $pending += [long]$cn.s
                    }
                    else {
                        $sum = SumTree $it.FullName
                        if ($sum -ge $state.minBytes) {
                            $ln = @{ n = $it.Name; s = $sum; done = $true; c = (New-Object System.Collections.ArrayList); path = $it.FullName }
                            [System.Threading.Monitor]::Enter($state.lock)
                            try { $null = $node.c.Add($ln) } finally { [System.Threading.Monitor]::Exit($state.lock) }
                        }
                        $pending += $sum
                    }
                }
                else {
                    $pending += [long]$it.Length
                    if ([long]$it.Length -ge $state.minBytes -and $bigFiles.Count -lt 200) {
                        $ln = @{ n = $it.Name; s = [long]$it.Length; done = $true; f = $true; c = (New-Object System.Collections.ArrayList) }
                        [System.Threading.Monitor]::Enter($state.lock)
                        try { $null = $bigFiles.Add($ln) } finally { [System.Threading.Monitor]::Exit($state.lock) }
                    }
                }
                if ($pending -ge 16MB -or ($nItems % 400) -eq 0 -or ([DateTime]::UtcNow - $lastFlush).TotalMilliseconds -ge 250) {
                    [System.Threading.Monitor]::Enter($state.lock)
                    try { $node.s += $pending; $state.version = [long]$state.version + 1 } finally { [System.Threading.Monitor]::Exit($state.lock) }
                    $pending = [long]0
                    $lastFlush = [DateTime]::UtcNow
                }
            }
            [System.Threading.Monitor]::Enter($state.lock)
            try {
                $node.s += $pending
                foreach ($b in $bigFiles) { $null = $node.c.Add($b); $node.s += [long]$b.s }
                $state.version = [long]$state.version + 1
                $sorted = New-Object System.Collections.ArrayList
                foreach ($x in ($node.c | Sort-Object { [long]$_.s } -Descending)) { $null = $sorted.Add($x) }
                $node.c = $sorted
            } finally { [System.Threading.Monitor]::Exit($state.lock) }
        }
        while ($true) {
            $job = $null
            [System.Threading.Monitor]::Enter($state.queue.SyncRoot)
            try { if ($state.queue.Count -gt 0) { $job = $state.queue.Dequeue() } } finally { [System.Threading.Monitor]::Exit($state.queue.SyncRoot) }
            if ($null -eq $job) { Start-Sleep -Milliseconds 250; continue }
            $key = (NormPath $job.path).ToLowerInvariant()
            [System.Threading.Monitor]::Enter($state.lock)
            try {
                $node = $state.trees[$key]
                if ($null -eq $node -or $node.done) { continue }
                $node.s = [long]0
                $node.c = (New-Object System.Collections.ArrayList)
            } finally { [System.Threading.Monitor]::Exit($state.lock) }
            try {
                ScanInto $node $job.path $job.depth
            }
            catch {
                [System.Threading.Monitor]::Enter($state.lock)
                try { $null = $state.errs.Add(('SCAN ' + $job.path + ' :: ' + $_.Exception.ToString())) } finally { [System.Threading.Monitor]::Exit($state.lock) }
            }
            [System.Threading.Monitor]::Enter($state.lock)
            try { $node.done = $true; $state.version = [long]$state.version + 1 } finally { [System.Threading.Monitor]::Exit($state.lock) }
        }
    }
    for ($wi = 0; $wi -lt 4; $wi++) {
        $w = [powershell]::Create()
        $w.AddScript($workerScript) | Out-Null
        $w.AddArgument($state) | Out-Null
        $w.BeginInvoke() | Out-Null
    }

    # SSE 推流 runspace：每 350ms 把订阅路径的子树快照推给浏览器（替代轮询，延迟更低）
    $sseScript = {
        param($state, $client, $rootPath, $subPaths, $enc)
        function NormPath([string]$p) { $p = $p.TrimEnd('\'); if ($p -match '^[A-Za-z]:$') { $p += '\' }; return $p }
        function EscJson([string]$s) {
            $s = $s.Replace('\', '\\').Replace('"', '\"')
            $s = $s.Replace("`r", '\r').Replace("`n", '\n').Replace("`t", '\t')
            return $s
        }
        function EmitNode($node) {
            $sb = '{"n":"' + (EscJson $node.n) + '","s":' + [long]$node.s + ',"done":'
            if ($node.done) { $sb += 'true' } else { $sb += 'false' }
            if ($node.path) { $sb += ',"p":"' + (EscJson $node.path) + '"' }
            if ($node.f) { $sb += ',"f":1' }
            $sb += ',"c":['
            $first = $true
            foreach ($ch in $node.c) { if (-not $first) { $sb += ',' }; $sb += EmitNode $ch; $first = $false }
            $sb += ']}'
            return $sb
        }
        try {
            $stream = $client.GetStream()
            $stream.WriteTimeout = 15000
            $head = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: text/event-stream; charset=utf-8`r`nCache-Control: no-store`r`nConnection: keep-alive`r`n`r`n")
            $stream.Write($head, 0, $head.Length)
            $retry = [System.Text.Encoding]::ASCII.GetBytes("retry: 1000`n`n")
            $stream.Write($retry, 0, $retry.Length); $stream.Flush()
            $subs = @($subPaths | ForEach-Object { NormPath $_ } | Select-Object -Unique)
            # 去冗余：被另一订阅路径包含的子路径跳过（root 序列化已覆盖其子树）
            $subs = @($subs | Where-Object {
                $p = $_
                -not ($subs | Where-Object { $_ -ne $p -and $p.StartsWith($_.TrimEnd('\') + '\') })
            })
            $idle = 0
            $lastVer = [long]-1
            $lastPush = [DateTime]::MinValue
            while ($true) {
                $alive = $false
                foreach ($p in $subs) {
                    [System.Threading.Monitor]::Enter($state.lock)
                    try { if ($null -ne $state.trees[$p.ToLowerInvariant()]) { $alive = $true } } finally { [System.Threading.Monitor]::Exit($state.lock) }
                }
                if (-not $alive) { $idle++; if ($idle -gt 30) { break } } else { $idle = 0 }
                $ver = [long]$state.version
                if ($ver -eq $lastVer) { Start-Sleep -Milliseconds 300; continue }
                $sinceMs = ([DateTime]::UtcNow - $lastPush).TotalMilliseconds
                if ($sinceMs -lt 800) { Start-Sleep -Milliseconds 200; continue }
                $payload = '{"paths":{'
                $first = $true
                foreach ($p in $subs) {
                    $key = $p.ToLowerInvariant()
                    $node = $null
                    [System.Threading.Monitor]::Enter($state.lock)
                    try { $node = $state.trees[$key] } finally { [System.Threading.Monitor]::Exit($state.lock) }
                    if ($null -ne $node) {
                        if (-not $first) { $payload += ',' }
                        $payload += '"' + (EscJson $p) + '":' + (EmitNode $node)
                        $first = $false
                    }
                }
                $payload += '}}'
                $data = [System.Text.Encoding]::UTF8.GetBytes('data: ' + $payload + "`n`n")
                $stream.Write($data, 0, $data.Length); $stream.Flush()
                $lastVer = $ver
                $lastPush = [DateTime]::UtcNow
            }
        } catch { }
        finally { try { $client.Close() } catch { } }
    }

    function EscJson([string]$s) {
        $s = $s.Replace('\', '\\').Replace('"', '\"')
        $s = $s.Replace("`r", '\r').Replace("`n", '\n').Replace("`t", '\t')
        return $s
    }
    function EmitNode($node) {
        $sb = '{"n":"' + (EscJson $node.n) + '","s":' + [long]$node.s + ',"done":'
        if ($node.done) { $sb += 'true' } else { $sb += 'false' }
        if ($node.path) { $sb += ',"p":"' + (EscJson $node.path) + '"' }
        if ($node.f) { $sb += ',"f":1' }
        $sb += ',"c":['
        $first = $true
        foreach ($ch in $node.c) {
            if (-not $first) { $sb += ',' }
            $sb += EmitNode $ch
            $first = $false
        }
        $sb += ']}'
        return $sb
    }
    function GetOrStart([string]$path) {
        $path = NormPath $path
        $key = $path.ToLowerInvariant()
        [System.Threading.Monitor]::Enter($state.lock)
        try {
            $node = $state.trees[$key]
            if ($null -eq $node) {
                $node = @{ n = (NodeName $path); s = [long]0; done = $false; c = (New-Object System.Collections.ArrayList) }
                $state.trees[$key] = $node
                $state.queue.Enqueue(@{ path = $path; depth = $state.depth })
            }
        } finally { [System.Threading.Monitor]::Exit($state.lock) }
        return $node
    }

    $viewerHtml = @'
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>c-reloc live map</title>
<style>
  html,body{margin:0;height:100%;font:13px/1.4 "Segoe UI",system-ui,sans-serif;background:#141414;color:#ddd;overflow:hidden}
  #bar{position:absolute;top:0;left:0;right:0;height:30px;background:#1d1d1d;border-bottom:1px solid #333;
       line-height:30px;padding:0 10px;white-space:nowrap;overflow-x:auto;overflow-y:hidden}
  #bar .crumb{color:#7fc7ff;cursor:pointer}
  #bar .crumb:hover{text-decoration:underline}
  #bar b{color:#fff}
  #map{position:absolute;top:30px;left:0;right:0;bottom:30px}
  .cell{position:absolute;box-sizing:border-box;border:1px solid #141414;cursor:pointer;
        transition:left .35s cubic-bezier(.2,.7,.3,1),top .35s cubic-bezier(.2,.7,.3,1),
                   width .35s cubic-bezier(.2,.7,.3,1),height .35s cubic-bezier(.2,.7,.3,1),opacity .4s}
  .cell.new{opacity:0}
  .cell.expd{border:1px solid #ffd479}
  .cell.counting>.lbl{color:#ffd479}
  .cell.counting::after{content:'';position:absolute;left:0;top:0;right:0;bottom:0;pointer-events:none;
    animation:cpulse 2.8s ease-in-out infinite}
  @keyframes cpulse{0%,100%{filter:brightness(1)}50%{filter:brightness(1.22)}}
  .cell.counting .badge{width:11px;height:11px;border:2px solid rgba(255,212,121,.25);border-top-color:#ffd479;
    border-radius:50%;animation:spin .8s linear infinite;top:5px;right:5px}
  .cell.expd>.lbl{left:0;top:0;right:0;height:15px;line-height:15px;padding:0 4px;
                  background:rgba(10,10,10,.72);border-bottom:1px solid #b8860b;overflow:hidden}
  .cell .lbl{position:absolute;left:4px;top:2px;right:4px;pointer-events:none;
             text-shadow:0 1px 3px #000;overflow:hidden;white-space:nowrap;text-overflow:ellipsis}
  .cell.big .lbl{font-size:15px;font-weight:600}
  .cell .badge{position:absolute;right:4px;top:2px;color:#ffd479;font-size:10px;pointer-events:none}
  #tip{position:fixed;display:none;background:#000d;border:1px solid #555;border-radius:4px;
       padding:5px 9px;pointer-events:none;z-index:9;max-width:520px;font-size:12px}
  #wait{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;
        color:#8a8a8a;font-size:15px;z-index:2}
  .spin{width:34px;height:34px;margin:0 auto;border:3px solid #333;border-top-color:#7fc7ff;
        border-radius:50%;animation:spin 0.9s linear infinite}
  @keyframes spin{to{transform:rotate(360deg)}}
  #foot{position:absolute;bottom:0;left:0;right:0;height:30px;line-height:30px;background:#1d1d1d;
        border-top:1px solid #333;padding:0 10px;color:#999;font-size:12px;white-space:nowrap;overflow:hidden}
  #foot b{color:#ffd479}
  #ctx{position:fixed;display:none;background:#252528;border:1px solid #43434a;border-radius:6px;
       padding:4px;z-index:20;min-width:236px;max-width:440px;box-shadow:0 8px 28px #000e;font-size:12px}
  #ctxpath{padding:7px 10px;color:#9a9aa2;font-size:11px;border-bottom:1px solid #3d3d42;
           word-break:break-all;max-height:52px;overflow:hidden;margin-bottom:4px;cursor:default;
           background:#1d1d21;border-radius:4px 4px 0 0}
  .mi{display:flex;align-items:center;gap:9px;padding:6px 10px;border-radius:4px;cursor:pointer;color:#d6d6da}
  .mi:hover{background:#2f4d6e;color:#fff}
  .mi .ic{width:16px;text-align:center;flex:none}
  #ctx .sep{height:1px;background:#3d3d42;margin:4px 6px}
</style>
</head>
<body>
<div id="bar"></div>
<div id="map"></div>
<div id="tip"></div>
<div id="ctx">
  <div id="ctxpath"></div>
  <div class="mi" id="mi-open"><span class="ic">📂</span><span id="mi-open-t">在资源管理器中打开</span></div>
  <div class="mi" id="mi-copy"><span class="ic">📋</span><span id="mi-copy-t">复制完整路径</span></div>
  <div class="sep"></div>
  <div class="mi" id="mi-enter"><span class="ic">↯</span><span>进入此目录</span></div>
  <div class="mi" id="mi-expand"><span class="ic">⊞</span><span id="mi-expand-t">展开</span></div>
</div>
<div id="wait"><div><div class="spin"></div><div style="margin-top:12px">counting directories... blocks appear as each finishes</div></div></div>
<div id="foot">scanning <b id="cur"></b> ... <span id="stat"></span> · 单击展开/收起 · 双击进入 · Backspace/⬅ 返回 · Esc 收起 · 右键打开文件夹</div>
<script>
var ROOT = '__ROOT__';
var curPath = ROOT, stack = [], cache = {}, divs = {}, busy = false;
var menuPath = '', menuSel = false, expanded = {}, orderState = {};
var map = document.getElementById('map');

function fmt(b){ if(b>=1073741824) return (b/1073741824).toFixed(2)+' GB';
  if(b>=1048576) return (b/1048576).toFixed(1)+' MB';
  if(b>=1024) return (b/1024).toFixed(0)+' KB'; return b+' B'; }
function esc(s){ return s.replace(/&/g,'&amp;').replace(/</g,'&lt;'); }
function colors(d){ var b=[[52,110,166],[64,138,116],[140,108,150],[164,124,68],[68,124,164],[128,150,66],[150,90,96]];
  var c=b[d%b.length]; return 'rgb('+c[0]+','+c[1]+','+c[2]+')'; }
function worst(row,len){ if(!row.length) return Infinity;
  var s=0,mx=0,mn=Infinity;
  for(var i=0;i<row.length;i++){s+=row[i].s; if(row[i].s>mx)mx=row[i].s; if(row[i].s<mn)mn=row[i].s;}
  if(mn<=0||s<=0) return Infinity;
  var l=len*len, s2=s*s;
  return Math.max(l*mx/s2, s2/(l*mn)); }
function layoutRow(row,x,y,w,h,out){
  var s=0; for(var i=0;i<row.length;i++) s+=row[i].s;
  if(w>=h){ var rw=s/h, ry=y;
    for(var j=0;j<row.length;j++){ var rh=row[j].s/rw; out.push({n:row[j],x:x,y:ry,w:rw,h:rh}); ry+=rh; }
    return {x:x+rw,y:y};
  } else { var rh=s/w, xx=x;
    for(var j2=0;j2<row.length;j2++){ var rw2=row[j2].s/rh; out.push({n:row[j2],x:xx,y:y,w:rw2,h:rh}); xx+=rw2; }
    return {x:x,y:y+rh};
  } }
function squarify(items,x,y,w,h,out){
  var row=[],i=0;
  while(i<items.length&&w>1&&h>1){
    var len=Math.min(w,h);
    var c1=worst(row,len), c2=worst(row.concat([items[i]]),len);
    if(c1===Infinity||c2<=c1){ row.push(items[i]); i++; }
    else { var r=layoutRow(row,x,y,w,h,out);
      if(w>=h){ w-=(r.x-x); x=r.x; } else { h-=(r.y-y); y=r.y; }
      row=[]; }
  }
  if(row.length&&w>1&&h>1) layoutRow(row,x,y,w,h,out);
}
function getCell(kk){
  var d=divs[kk];
  if(!d){
    d=document.createElement('div'); d.className='cell new';
    d.dataset.k=kk; map.appendChild(d); divs[kk]=d;
    setTimeout(function(el){ return function(){ el.className='cell'; }; }(d), 40);
    var l=document.createElement('div'); l.className='lbl'; d.appendChild(l);
    var b=document.createElement('div'); b.className='badge'; d.appendChild(b);
    d.style.cursor='pointer';
    d.addEventListener('mousemove',function(ev){
      var el=ev.currentTarget, n=el.__n||{};
      var t=document.getElementById('tip'); t.style.display='block';
      t.style.left=Math.min(ev.clientX+14,window.innerWidth-560)+'px';
      t.style.top=(ev.clientY+14)+'px';
      var fp=n.agg?('聚合 '+n.agg+' 个极小项（已折叠）'):(el.__path||n.p||'');
      t.innerHTML='<div style="color:#9fd1ff;word-break:break-all">'+esc(fp)+'</div><b>'+fmt(n.raw)+'</b>'+
        (n.f?'<span style="color:#888"> · 文件</span>':'<span style="color:#888"> · 目录 · 单击展开/收起 · 双击进入</span>')+
        (n.done?'':'<br><span style="color:#ffd479">counting...</span>')+
        '<br><span style="color:#888">右键：'+(n.f?'打开所在文件夹':'在资源管理器中打开')+'</span>';
    });
    d.addEventListener('mouseleave',function(){ document.getElementById('tip').style.display='none'; });
    d.addEventListener('click',function(ev){ ev.stopPropagation();
      var el=ev.currentTarget, n=el.__n||{};
      if(n.f) return;
      var p=el.__path; if(!p) return;
        if(expanded[p]){ delete expanded[p]; }
        else { expanded[p]=1; if(!cache[p]||!(cache[p].c&&cache[p].c.length)) fetchPath(p); }
        render(); subscribe();
    });
    d.addEventListener('dblclick',function(ev){ ev.stopPropagation();
      var el=ev.currentTarget, n=el.__n||{};
      if(n.f) return;
      var p=el.__path;
      if(p){ navigate(p); } });
    d.addEventListener('contextmenu',function(ev){ ev.preventDefault(); ev.stopPropagation();
      var el=ev.currentTarget, n=el.__n||{};
      var fp=el.__path||n.p||'';
      menuPath=fp; menuSel=!!n.f;
      var isFile=!!n.f;
      document.getElementById('mi-open-t').textContent=isFile?'打开所在文件夹（并选中）':'在资源管理器中打开';
      document.getElementById('mi-enter').style.display=isFile?'none':'';
      document.getElementById('mi-expand').style.display=isFile?'none':'';
      document.getElementById('mi-expand-t').textContent=expanded[fp]?'收起':'展开';
      document.getElementById('mi-copy-t').textContent='复制完整路径';
      document.getElementById('ctxpath').textContent=fp;
      var c=document.getElementById('ctx');
      c.style.display='block';
      c.style.left=Math.min(ev.clientX,window.innerWidth-256)+'px';
      c.style.top=Math.min(ev.clientY,window.innerHeight-200)+'px';
    });
  }
  return d;
}
function paintCell(d,o,x,y,w,h,pth,kk,seen,ci){
  d.__n=o.n; d.__path=pth;
  d.style.left=x+'px'; d.style.top=y+'px';
  d.style.width=Math.max(0,w-2)+'px'; d.style.height=Math.max(0,h-2)+'px';
  d.style.background=o.n.f?(o.n.agg?'#3f3f46':'#6e6e6e'):colors(ci);
  d.classList.toggle('expd',!!expanded[pth]);
  d.classList.toggle('counting',!o.n.done);
  var lbl=d.querySelector('.lbl');
  lbl.textContent=o.n.n+'  '+fmt(o.n.raw)+(expanded[pth]?' ▾':'');
  lbl.style.fontSize=(w>180&&h>50)?'14px':'11px';
  lbl.style.paddingLeft=expanded[pth]?
    (4+Math.max(0,pth.split('\\').length-curPath.split('\\').length)*12)+'px':'';
  d.querySelector('.badge').textContent='';
  seen[kk]=1;
}
function stableOrder(arr,keyBase){
  // 排序迟滞：新项按大小插入，旧项只有比前一名大 12% 才上移——
  // 避免扫描中大小抖动导致方块来回换位，只有"一定程度"才交换
  var st=orderState[keyBase];
  if(!st){ st=orderState[keyBase]={list:[]}; }
  var byName={};
  for(var i=0;i<arr.length;i++) byName[arr[i].n]=arr[i];
  var out=[];
  for(var j=0;j<st.list.length;j++){ var it=byName[st.list[j]]; if(it){ out.push(it); delete byName[st.list[j]]; } }
  for(var k2=0;k2<arr.length;k2++){ if(byName[arr[k2].n]){ out.push(arr[k2]); delete byName[arr[k2].n]; } }
  var changed=true,passes=0;
  while(changed&&passes<60){
    changed=false;passes++;
    for(var m=0;m<out.length-1;m++){
      if(out[m+1].s>out[m].s*1.12){ var t=out[m];out[m]=out[m+1];out[m+1]=t;changed=true; }
    }
  }
  st.list=out.map(function(x){return x.n;});
  return out;
}
function layoutInto(node,x0,y0,w0,h0,keyBase,seen){
  var items=(node.c||[]).slice().sort(function(a,b){return b.s-a.s;});
  var tot=0; for(var q=0;q<items.length;q++) tot+=items[q].s;
  if(!items.length||tot<=0||w0<10||h0<10) return;
  // 第一道：面积折叠（<180px² 不单独成块）
  var MINA=180;
  var k0=(w0*h0)/tot;
  var main=[],rest=0,restN=0;
  for(var q2=0;q2<items.length;q2++){
    var it=items[q2];
    if(it.s*k0>=MINA){ main.push({n:it.n,s:it.s,raw:it.s,p:it.p,f:it.f,done:it.done,c:it.c}); }
    else { rest+=it.s; restN++; }
  }
  var aggS=rest, aggN=restN, agg=aggS>0;
  if(!main.length){
    if(agg){
      var d0=getCell(keyBase+'|:agg');
      paintCell(d0,{n:{n:'… 剩余'+aggN+'项（极小/未扫完）',s:aggS,raw:aggS,done:true,f:1,agg:aggN}},x0,y0,w0,h0,keyBase,keyBase+'|:agg',seen,0);
      d0.style.background='#3f3f46';
    }
    return;
  }
  main=stableOrder(main,keyBase);
  // 第二道：形状检测——squarify 后凡最小边<5px 或长宽比>7 的"细条"并入剩余，
  // 用底部聚合条占位（高度按占比 16px~40%），剩余项重排；迭代至无细条
  var out=[];
  for(var pass=0;pass<4;pass++){
    var goodSum=0; for(var g=0;g<main.length;g++) goodSum+=main[g].s;
    if(goodSum<=0){ main=[]; break; }
    var stripH=agg?Math.max(18,Math.min(Math.round(h0*aggS/(goodSum+aggS)),Math.round(h0*0.4))):0;
    var availH=h0-stripH;
    if(availH<10){ break; }
    var k=(w0*availH)/goodSum;
    var px=main.map(function(it,i2){ return {n:it.n,s:it.s*k,raw:it.s,p:it.p,f:it.f,done:it.done,c:it.c,idx:i2}; });
    out=[]; squarify(px,x0,y0,w0,availH,out);
    var bad=false, keep={};
    for(var b=0;b<out.length;b++){
      var r=out[b];
      var mx=Math.max(r.w,r.h), mn=Math.min(r.w,r.h);
      if(mn<5||mx/mn>7){ bad=true; agg=true; aggS+=r.n.raw; aggN++; }
      else { keep[r.n.idx]=1; }
    }
    if(!bad) break;
    main=main.filter(function(it,i3){ return keep[i3]; });
  }
  var goodSum=0; for(var g2=0;g2<main.length;g2++) goodSum+=main[g2].s;
  if(goodSum<=0){
    if(agg){
      var d1=getCell(keyBase+'|:agg');
      paintCell(d1,{n:{n:'… 剩余'+aggN+'项（极小/未扫完）',s:aggS,raw:aggS,done:true,f:1,agg:aggN}},x0,y0,w0,h0,keyBase,keyBase+'|:agg',seen,0);
      d1.style.background='#3f3f46';
    }
    return;
  }
  var stripH=agg?Math.max(18,Math.min(Math.round(h0*aggS/(goodSum+aggS)),Math.round(h0*0.4))):0;
  var availH=h0-stripH;
  if(availH<10){
    var d2=getCell(keyBase+'|:agg');
    paintCell(d2,{n:{n:'… 剩余'+aggN+'项（极小/未扫完）',s:aggS,raw:aggS,done:true,f:1,agg:aggN}},x0,y0,w0,h0,keyBase,keyBase+'|:agg',seen,0);
    d2.style.background='#3f3f46';
    return;
  }
  var k=(w0*availH)/goodSum;
  var px=main.map(function(it){ return {n:it.n,s:it.s*k,raw:it.s,p:it.p,f:it.f,done:it.done,c:it.c}; });
  out=[]; squarify(px,x0,y0,w0,availH,out);
  var depth=stack.length;
  var sep=(keyBase.charAt(keyBase.length-1)==='\\')?'':'\\';
  for(var i=0;i<out.length;i++){
    var o=out[i], kk=keyBase+'|'+o.n.n;
    var pth=o.n.p||(keyBase+sep+o.n.n);
    var d=getCell(kk);
    paintCell(d,o,o.x,o.y,o.w,o.h,pth,kk,seen,depth+i);
    if(expanded[pth]&&o.n.c&&o.n.c.length){
      var sub=cache[pth]||o.n;
      layoutInto(sub,o.x+2,o.y+16,Math.max(0,o.w-4),Math.max(0,o.h-16),pth,seen);
    }
  }
  if(agg&&stripH>0){
    var akk=keyBase+'|:agg';
    var ad=getCell(akk);
    paintCell(ad,{n:{n:'… 剩余'+aggN+'项（极小/未扫完）',s:aggS,raw:aggS,done:true,f:1,agg:aggN}},x0,y0+availH,w0,stripH,keyBase,akk,seen,depth);
    ad.style.background='#3f3f46';
  }
}
function render(){
  var node = cache[curPath]; if(!node) return;
  var W = map.clientWidth, H = map.clientHeight;
  var items=(node.c||[]);
  var tot=0; for(var q=0;q<items.length;q++) tot+=items[q].s;
  var wait = document.getElementById('wait');
  if(items.length&&tot>0){ wait.style.display='none'; }
  else if(node.done){ wait.style.display='flex'; wait.innerHTML='<div><div style="margin-bottom:10px">'+esc(node.n)+'</div><div style="color:#8a8a8a">空目录，或全部子项已折叠进“剩余”条</div></div>'; }
  else { wait.style.display='flex'; }
  var seen={};
  layoutInto(node,0,0,W,H,curPath,seen);
  for(var key in divs){ if(!seen[key]){ var old=divs[key]; old.style.opacity='0';
    (function(el){ setTimeout(function(){ if(el.parentNode) el.parentNode.removeChild(el); },450); })(old);
    delete divs[key]; } }
  drawBar(node);
}
function drawBar(node){
  var b=document.getElementById('bar'); b.innerHTML='';
  if(stack.length){ var bk=document.createElement('span'); bk.className='crumb'; bk.textContent='⬅ 返回';
    bk.onclick=function(){ goUp(); }; b.appendChild(bk);
    b.appendChild(document.createTextNode(' | ')); }
  function mk(label,p){ var s=document.createElement('span'); s.className='crumb'; s.textContent=label;
    s.onclick=(function(pp){ return function(){ navigate(pp,false); }; })(p); b.appendChild(s); }
  mk('[root]',ROOT);
  var acc=ROOT;
  for(var i=0;i<stack.length;i++){ acc=stack[i].path;
    b.appendChild(document.createTextNode(' \\ ')); mk(stack[i].name,acc); }
  b.appendChild(document.createTextNode(' \\ '));
  var cb=document.createElement('b'); cb.textContent=node.n+' = '+fmt(node.s); b.appendChild(cb);
  document.getElementById('cur').textContent=curPath;
  document.getElementById('stat').innerHTML=node.done?
    'done · <b>单击展开</b> · <b>双击进入</b> · 右键打开':'<b>counting...</b> blocks grow live';
}
var fails=0, waitHtml=document.getElementById('wait').innerHTML;
function netFail(){
  busy=false; fails++;
  if(fails>=3){ var w=document.getElementById('wait'); w.style.display='flex'; w.innerHTML=
    '<div style="text-align:center;max-width:560px;padding:0 16px">'+
    '<div style="color:#ff7b7b;font-size:15px;margin-bottom:8px">无法连接 127.0.0.1:8734（已试 '+fails+' 次）</div>'+
    '<div style="color:#bbb;line-height:1.7">浏览器代理可能拦截了 localhost 请求。<br>'+
    '请把 <b style="color:#ffd479">127.0.0.1 / localhost</b> 加入代理软件的直连(绕过)列表，<br>或暂时关闭系统代理 / TUN 模式，然后刷新本页。</div></div>'; }
}
function openPath(p,sel){ var x=new XMLHttpRequest();
  x.open('GET','/open?path='+encodeURIComponent(p)+(sel?'&sel=1':''),true); x.send(null); }
function copyPath(p,fbEl){
  function restore(){ if(fbEl) fbEl.textContent='复制完整路径'; }
  function ok(){ if(fbEl){ fbEl.textContent='✓ 已复制'; setTimeout(restore,900); } }
  function fail(){ if(fbEl){ fbEl.textContent='复制失败'; setTimeout(restore,1200); } }
  function fallback(){ var t=document.createElement('textarea'); t.value=p;
    document.body.appendChild(t); t.select();
    var done=false; try{ done=document.execCommand('copy'); }catch(e){ }
    document.body.removeChild(t);
    if(done){ ok(); } else { fail(); } }
  if(navigator.clipboard&&navigator.clipboard.writeText){
    navigator.clipboard.writeText(p).then(ok,fallback);
  } else { fallback(); }
}
function hideCtx(){ document.getElementById('ctx').style.display='none'; }
document.getElementById('mi-open').addEventListener('click',function(){ openPath(menuPath,menuSel); hideCtx(); });
document.getElementById('mi-copy').addEventListener('click',function(){
  copyPath(menuPath,document.getElementById('mi-copy-t')); setTimeout(hideCtx,650); });
document.getElementById('mi-enter').addEventListener('click',function(){
  if(menuPath&&!menuSel){ navigate(menuPath); } hideCtx(); });
document.getElementById('mi-expand').addEventListener('click',function(){
  var p=menuPath;
  if(p&&!menuSel){
    if(expanded[p]){ delete expanded[p]; }
    else { expanded[p]=1; if(!cache[p]||!(cache[p].c&&cache[p].c.length)) fetchPath(p); }
    render();
  }
  hideCtx();
});
document.addEventListener('mousedown',function(ev){
  var c=document.getElementById('ctx');
  if(c.style.display==='block'&&!c.contains(ev.target)) c.style.display='none';
},true);
function fetchPath(p){
  var x=new XMLHttpRequest();
  x.open('GET','/tree?path='+encodeURIComponent(p),true);
  x.timeout=4000;
  x.onreadystatechange=function(){
    if(x.readyState===4&&x.status===200){
      try{ var j=JSON.parse(x.responseText); cache[p]=j.node; if(expanded[p]) render(); }catch(e){}
    }
  };
  x.send(null);
}
function fetchTree(){
  if(busy) return; busy=true;
  var x=new XMLHttpRequest();
  x.open('GET','/tree?path='+encodeURIComponent(curPath),true);
  x.timeout=4000;
  x.onreadystatechange=function(){
    if(x.readyState===4){ busy=false;
      if(x.status===200){ fails=0;
        var w=document.getElementById('wait'); if(w.innerHTML!==waitHtml){ w.innerHTML=waitHtml; }
        try{ var j=JSON.parse(x.responseText); cache[curPath]=j.node; render();
          for(var p2 in expanded){ if(!cache[p2]||!cache[p2].done) fetchPath(p2); } }catch(e){} }
      else { netFail(); } }
  };
  x.onerror=netFail; x.ontimeout=netFail;
  x.send(null);
}
function goUp(){
  if(!stack.length) return;
  var p=stack.pop(); curPath=p.path; divs={}; map.innerHTML=''; expanded={}; fetchTree(); subscribe();
}
function navigate(path,isChild){
  if(isChild!==false && cache[curPath]){ stack.push({name:cache[curPath].n,path:curPath}); }
  curPath=path; divs={}; map.innerHTML=''; expanded={}; fetchTree(); subscribe();
}
var evtSrc=null, pollTimer=null, sseFails=0;
function subscribe(){
  var paths=[curPath];
  for(var p in expanded){ if(paths.indexOf(p)<0) paths.push(p); }
  if(evtSrc){ try{ evtSrc.close(); }catch(e){} evtSrc=null; }
  try{
    evtSrc=new EventSource('/events?paths='+encodeURIComponent(paths.join('|')));
    evtSrc.onmessage=function(ev){
      sseFails=0;
      if(pollTimer){ clearInterval(pollTimer); pollTimer=null; }
      var w=document.getElementById('wait'); if(w.innerHTML!==waitHtml){ w.innerHTML=waitHtml; }
      try{
        var j=JSON.parse(ev.data);
        for(var p2 in j.paths){ cache[p2]=j.paths[p2]; }
        render();
        for(var p3 in expanded){ if(!cache[p3]||!cache[p3].done) fetchPath(p3); }
      }catch(e){}
    };
    evtSrc.onerror=function(){
      sseFails++;
      if(sseFails>=5&&!pollTimer){ pollTimer=setInterval(fetchTree,600); }
    };
  }catch(e){ if(!pollTimer){ pollTimer=setInterval(fetchTree,600); } }
}
map.addEventListener('click',function(){ goUp(); });
window.addEventListener('resize',function(){ render(); });
document.addEventListener('keydown',function(e){
  if(e.target&&(e.target.tagName==='INPUT'||e.target.tagName==='TEXTAREA')) return;
  if(e.key==='Backspace'&&stack.length){ e.preventDefault(); goUp(); }
  if(e.key==='Escape'){ hideCtx();
    if(Object.keys(expanded).length){ expanded={}; render(); subscribe(); } }
});
fetchTree(); subscribe();
</script>
</body>
</html>
'@

    $viewerHtml = $viewerHtml.Replace('__ROOT__', (EscJson $Root))
    $enc = [System.Text.Encoding]::UTF8

    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
    try { $listener.Start() }
    catch {
        Write-Host ('[serve] FATAL: cannot listen on port ' + $Port + ' - ' + $_.Exception.Message)
        Write-Host ('[serve] 多半是已有一个实例在跑：直接开 http://127.0.0.1:' + $Port + '/ 即可；或用 -Port 换端口。')
        exit 1
    }
    $url = 'http://127.0.0.1:' + $Port + '/'
    Write-Host ('[serve] live map running at ' + $url + '  (Ctrl+C to stop)')
    Write-Host ('[serve] scanning root: ' + $Root + ' (depth ' + $state.depth + ', prune < ' + $MinMB + ' MB)')
    try { Start-Process $url | Out-Null } catch { }

    GetOrStart $Root | Out-Null

    while ($true) {
        try {
            if (-not $listener.Pending()) { Start-Sleep -Milliseconds 120; continue }
            $client = $listener.AcceptTcpClient()
            $handoff = $false
            try {
                $stream = $client.GetStream()
                $stream.ReadTimeout = 5000
                $buf = New-Object byte[] 32768
                $read = $stream.Read($buf, 0, $buf.Length)
                if ($read -le 0) { continue }
                $req = [System.Text.Encoding]::ASCII.GetString($buf, 0, $read)
                $line = ($req -split "`r`n")[0]
                $parts = $line -split ' '
                if ($parts.Count -lt 2) { $client.Close(); continue }
                $target = $parts[1]

                if ($target -eq '/' -or $target -eq '/index.html') {
                    $bytes = $enc.GetBytes($viewerHtml)
                    $head = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: text/html; charset=utf-8`r`nContent-Length: " + $bytes.Length + "`r`nConnection: close`r`nCache-Control: no-store`r`n`r`n")
                    $stream.Write($head, 0, $head.Length); $stream.Write($bytes, 0, $bytes.Length); $stream.Flush()
                }
                elseif ($target.StartsWith('/events')) {
                    # SSE 推流：交给独立 runspace，主循环继续服务其他请求（不关闭连接）
                    $handoff = $true
                    $q = if ($target.Length -gt 8) { $target.Substring(8) } else { '' }
                    $pathsVal = @()
                    foreach ($kv in ($q -split '&')) {
                        $i = $kv.IndexOf('=')
                        if ($i -gt 0 -and $kv.Substring(0, $i) -eq 'paths') {
                            $pathsVal = [System.Uri]::UnescapeDataString($kv.Substring($i + 1)) -split '\|'
                        }
                    }
                    if ($pathsVal.Count -eq 0) { $pathsVal = @($Root) }
                    $sse = [powershell]::Create()
                    $null = $sse.AddScript($sseScript).AddArgument($state).AddArgument($client).AddArgument($Root).AddArgument([string[]]$pathsVal).AddArgument($enc)
                    $null = $sse.BeginInvoke()
                }
                elseif ($target.StartsWith('/tree?')) {
                    $pathVal = ''
                    foreach ($kv in ($target.Substring(6) -split '&')) {
                        $i = $kv.IndexOf('=')
                        if ($i -gt 0 -and $kv.Substring(0, $i) -eq 'path') {
                            $pathVal = NormPath ([System.Uri]::UnescapeDataString($kv.Substring($i + 1)))
                        }
                    }
                    $body = '{"error":"bad path"}'
                    if ($pathVal -and (Test-Path -LiteralPath $pathVal)) {
                        $node = GetOrStart $pathVal
                        [System.Threading.Monitor]::Enter($state.lock)
                        try { $body = '{"node":' + (EmitNode $node) + '}' } finally { [System.Threading.Monitor]::Exit($state.lock) }
                    }
                    $bytes = $enc.GetBytes($body)
                    $head = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: application/json; charset=utf-8`r`nContent-Length: " + $bytes.Length + "`r`nConnection: close`r`nCache-Control: no-store`r`n`r`n")
                    $stream.Write($head, 0, $head.Length); $stream.Write($bytes, 0, $bytes.Length); $stream.Flush()
                }
                elseif ($target.StartsWith('/open?')) {
                    $pathVal = ''; $selVal = $false
                    foreach ($kv in ($target.Substring(6) -split '&')) {
                        $i = $kv.IndexOf('=')
                        if ($i -gt 0) {
                            $k = $kv.Substring(0, $i)
                            $v = [System.Uri]::UnescapeDataString($kv.Substring($i + 1))
                            if ($k -eq 'path') { $pathVal = NormPath $v }
                            if ($k -eq 'sel') { $selVal = ($v -eq '1') }
                        }
                    }
                    $body = '{"error":"bad path"}'
                    if ($pathVal -and ($pathVal -notlike '*"*') -and (Test-Path -LiteralPath $pathVal)) {
                        try {
                            if ($selVal) { Start-Process explorer.exe -ArgumentList ('/select,"' + $pathVal + '"') }
                            else { Start-Process explorer.exe -ArgumentList ('"' + $pathVal + '"') }
                            $body = '{"ok":true}'
                        } catch { $body = '{"error":"' + (EscJson $_.Exception.Message) + '"}' }
                    }
                    $bytes = $enc.GetBytes($body)
                    $head = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: " + $bytes.Length + "`r`nConnection: close`r`nCache-Control: no-store`r`n`r`n")
                    $stream.Write($head, 0, $head.Length); $stream.Write($bytes, 0, $bytes.Length); $stream.Flush()
                }
                elseif ($target -eq '/debug') {
                    $lang = $ExecutionContext.SessionState.LanguageMode
                    [System.Threading.Monitor]::Enter($state.lock)
                    try {
                        $body = '{"lang":"' + $lang + '","queue":' + $state.queue.Count + ',"trees":' + $state.trees.Count + ',"errs":['
                        $first = $true
                        foreach ($eX in $state.errs) {
                            if (-not $first) { $body += ',' }
                            $body += '"' + (EscJson ([string]$eX)) + '"'
                            $first = $false
                        }
                        $body += ']}'
                    } finally { [System.Threading.Monitor]::Exit($state.lock) }
                    $bytes = $enc.GetBytes($body)
                    $head = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: application/json; charset=utf-8`r`nContent-Length: " + $bytes.Length + "`r`nConnection: close`r`nCache-Control: no-store`r`n`r`n")
                    $stream.Write($head, 0, $head.Length); $stream.Write($bytes, 0, $bytes.Length); $stream.Flush()
                }
                else {
                    $head = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 404 Not Found`r`nContent-Length: 0`r`nConnection: close`r`n`r`n")
                    $stream.Write($head, 0, $head.Length); $stream.Flush()
                }
            }
            finally { if (-not $handoff) { $client.Close() } }
        }
        catch {
            if ($_.Exception.Message -like '*Not listening*') {
                Write-Host '[serve] FATAL: listener dead, exiting.'
                break
            }
            Write-Host ('[serve] request error: ' + $_.Exception.Message)
        }
    }
    exit 0
}

# =====================================================================
# Static export mode
# =====================================================================
Write-Host ('[map] walking ' + $Root + ' (depth ' + $Depth + ', prune < ' + $MinMB + ' MB)...')
$tree = Get-Tree $Root ($Depth)
Prune-Tree $tree
Write-Host ('[map] root size: {0:N2} GB' -f ($tree.s / 1GB))

$json = ConvertTo-Json $tree -Depth 12 -Compress

if (-not $Out) { $Out = Join-Path $env:TEMP ('creloc-map-' + ($Root -replace '[:\\]', '_') + '.html') }
$dir = Split-Path -Parent $Out
if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

$html = @'
<!DOCTYPE html>
<html lang="zh">
<head>
<meta charset="utf-8">
<title>c-reloc map</title>
<style>
  html,body{margin:0;height:100%;font:13px/1.4 "Segoe UI",system-ui,sans-serif;background:#111;color:#ddd;overflow:hidden}
  #bar{padding:6px 10px;background:#1b1b1b;border-bottom:1px solid #333;white-space:nowrap;overflow-x:auto}
  #bar b{color:#8fd3ff}
  #bar span.crumb{cursor:pointer;color:#8fd3ff}
  #bar span.crumb:hover{text-decoration:underline}
  #map{position:absolute;top:32px;bottom:26px;left:0;right:0}
  .cell{position:absolute;overflow:hidden;border:1px solid #111;box-sizing:border-box;cursor:pointer}
  .cell .lbl{position:absolute;left:3px;top:2px;right:3px;pointer-events:none;text-shadow:0 1px 2px #000;word-break:break-all}
  #tip{position:fixed;display:none;background:#000c;border:1px solid #555;padding:5px 8px;border-radius:4px;pointer-events:none;z-index:9;max-width:480px}
  #foot{position:absolute;bottom:0;left:0;right:0;height:26px;background:#1b1b1b;border-top:1px solid #333;font-size:12px;padding:4px 10px;color:#999}
</style>
</head>
<body>
<div id="bar"></div>
<div id="map"></div>
<div id="tip"></div>
<div id="foot">click a cell to zoom in &nbsp;|&nbsp; click the top breadcrumb to go back &nbsp;|&nbsp; sizes are logical bytes, links not followed</div>
<script>
var DATA = __DATA__;
var cur = DATA, stack = [];
function fmt(b){ if(b>=1073741824) return (b/1073741824).toFixed(2)+' GB';
  if(b>=1048576) return (b/1048576).toFixed(1)+' MB';
  if(b>=1024) return (b/1024).toFixed(0)+' KB'; return b+' B'; }
function color(d){var base=[[46,104,158],[59,130,111],[133,102,144],[157,119,64],[64,119,157],[121,144,62]];
  var c=base[d%base.length];return 'rgb('+c[0]+','+c[1]+','+c[2]+')';}
function worst(row,len){ if(!row.length) return Infinity;
  var s=0,mx=0,mn=Infinity;
  for(var i=0;i<row.length;i++){s+=row[i].s;if(row[i].s>mx)mx=row[i].s;if(row[i].s<mn)mn=row[i].s;}
  if(mn<=0||s<=0) return Infinity;
  var l=len*len,s2=s*s;
  return Math.max(l*mx/s2, s2/(l*mn)); }
function layoutRow(row,x,y,w,h,out){
  var s=0;for(var i=0;i<row.length;i++)s+=row[i].s;
  if(w>=h){var rw=s/h,ry=y;
    for(var j=0;j<row.length;j++){var rh=row[j].s/rw;out.push({n:row[j],x:x,y:ry,w:rw,h:rh});ry+=rh;}
    return {x:x+rw,y:y};
  }else{var rh=s/w,xx=x;
    for(var j2=0;j2<row.length;j2++){var rw2=row[j2].s/rh;out.push({n:row[j2],x:xx,y:y,w:rw2,h:rh});xx+=rw2;}
    return {x:x,y:y+rh};
  }}
function squarify(items,x,y,w,h,out){
  var row=[],i=0;
  while(i<items.length&&w>1&&h>1){
    var len=Math.min(w,h);
    var c1=worst(row,len),c2=worst(row.concat([items[i]]),len);
    if(c1===Infinity||c2<=c1){row.push(items[i]);i++;}
    else{var r=layoutRow(row,x,y,w,h,out);
      if(w>=h){w-=(r.x-x);x=r.x;}else{h-=(r.y-y);y=r.y;}
      row=[];}
  }
  if(row.length&&w>1&&h>1)layoutRow(row,x,y,w,h,out);
}
function render(){
  var map=document.getElementById('map'),W=map.clientWidth,H=map.clientHeight;
  map.innerHTML='';
  var items=cur.c.slice().sort(function(a,b){return b.s-a.s;});
  var out=[];
  if(items.length&&W>1&&H>1){
    var tot=0;for(var q=0;q<items.length;q++)tot+=items[q].s;
    if(tot>0){var k=(W*H)/tot;
      var px=items.map(function(it){return {n:it.n,s:it.s*k,raw:it.s,c:it.c};});
      squarify(px,0,0,W,H,out);}
  }
  var depth=stack.length;
  for(var i=0;i<out.length;i++){
    var c=out[i],d=document.createElement('div');
    d.className='cell';
    d.style.left=c.x+'px';d.style.top=c.y+'px';d.style.width=Math.max(0,c.w-2)+'px';d.style.height=Math.max(0,c.h-2)+'px';
    d.style.background=color(depth+i);
    if(c.w>50&&c.h>16){var l=document.createElement('div');l.className='lbl';
      l.textContent=c.n.n+'  '+fmt(c.n.raw);
      l.style.fontSize=(c.w>200&&c.h>60)?'14px':'11px';
      d.appendChild(l);}
    d.onmousemove=(function(n){return function(ev){var t=document.getElementById('tip');
      t.style.display='block';t.style.left=(ev.clientX+14)+'px';t.style.top=(ev.clientY+14)+'px';
      t.textContent=n.n+'  =  '+fmt(n.raw);};})(c.n);
    d.onmouseleave=function(){document.getElementById('tip').style.display='none';};
    d.onclick=(function(n){return function(ev){ev.stopPropagation();
      if(n.c&&n.c.length){stack.push(cur);cur=n;render();drawBar();}};})(c.n);
    map.appendChild(d);
  }
  drawBar();
}
function drawBar(){
  var b=document.getElementById('bar');b.innerHTML='';
  function mk(label,node){var s=document.createElement('span');s.className='crumb';s.textContent=label;
    s.onclick=function(){cur=node;stack.length=0;render();};b.appendChild(s);}
  mk('root',DATA);
  for(var i=0;i<stack.length;i++){b.appendChild(document.createTextNode(' \\ '));mk(stack[i].n,stack[i]);}
  b.appendChild(document.createTextNode(' \\ '));
  var cb=document.createElement('b');cb.textContent=cur.n+'  =  '+fmt(cur.s);b.appendChild(cb);
}
document.getElementById('map').onclick=function(){if(stack.length){cur=stack.pop();render();}};
window.onresize=render;render();
</script>
</body>
</html>
'@

$html = $html.Replace('__DATA__', $json)
Set-Content -LiteralPath $Out -Value $html -Encoding UTF8
Write-Host ('[map] html written: ' + $Out)
exit 0
