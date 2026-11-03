# =====================================================================
# Map-Reloc.ps1 - c-relocator disk-usage mapper (SpaceSniffer-like).
# Walks a root, builds a size tree, and renders a self-contained
# interactive HTML treemap (inline JS, no external dependencies).
# Read-only. PowerShell 5.1+.
#   Map-Reloc.ps1 -Root C:\ -Depth 4 -MinMB 50
#   Map-Reloc.ps1 -Root E:\Reloc -Depth 6 -MinMB 1 -Out map.html
# Prunes deny-listed system dirs by default (migration tool POV);
# -NoPruneDeny shows everything. Reparse points are never followed.
# =====================================================================
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Root,
    [int]$Depth = 4,
    [double]$MinMB = 50,
    [string]$Out = '',
    [switch]$NoPruneDeny,
    [string]$Rules = ''
)

$ErrorActionPreference = 'Continue'

if (-not (Test-Path -LiteralPath $Root)) {
    [Console]::Error.WriteLine('root not found: ' + $Root)
    exit 2
}
$rootItem = Get-Item -LiteralPath $Root -Force
if (-not $rootItem.PSIsContainer) {
    [Console]::Error.WriteLine('root is not a directory: ' + $Root)
    exit 2
}
$Root = $rootItem.FullName.TrimEnd('\')
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

# Recursive walk: always sums full subtree bytes; tree nodes are only
# kept while depth budget remains. Files become leaf nodes when large.
function Get-Tree([string]$path, [int]$depthLeft) {
    $node = New-Node (Split-Path -Leaf $path)
    $children = @(Get-ChildItem -LiteralPath $path -Force -ErrorAction SilentlyContinue)
    foreach ($item in $children) {
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
        if ($item.PSIsContainer) {
            if ((Test-UnderDenyPrefix $item.FullName)) { continue }
            $size = [long]0
            if ($depthLeft -gt 0) {
                $child = Get-Tree $item.FullName ($depthLeft - 1)
                $node.s += $child.s
                $node.c += ,$child
            }
            else {
                $sum = (Get-ChildItem -LiteralPath $item.FullName -Recurse -File -Force -ErrorAction SilentlyContinue |
                    Measure-Object -Property Length -Sum).Sum
                if ($null -eq $sum) { $sum = 0 }
                $size = [long]$sum
                $node.s += $size
                if ($size -ge $minBytes) {
                    $leaf = New-Node $item.Name
                    $leaf.s = $size
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
    $sorted = @($kept | Sort-Object { [long]$_.s } -Descending)
    $node.c = $sorted
}

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
  html,body{margin:0;height:100%;font:13px/1.4 "Segoe UI",system-ui,sans-serif;background:#111;color:#ddd}
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
function pad2(n){return n<10?'0'+n:n;}
function color(d){var base=[[46,104,158],[59,130,111],[133,102,144],[157,119,64],[64,119,157],[121,144,62]];
  var c=base[d%base.length];return 'rgb('+c[0]+','+c[1]+','+c[2]+')';}
function squarify(items,x,y,w,h,out){
  if(!items.length||w<=0||h<=0)return;
  var total=0;for(var i=0;i<items.length;i++)total+=items[i].s;
  var vert=w>=h, fw=vert?h:w, fx=fy=0, rem=total, row=[], rowSum=0;
  function place(){ var rw=rowSum*fw/rem; var ox=x,oy=y;
    for(var i=0;i<row.length;i++){ var rh=row[i].s/rw; var cw,ch;
      if(vert){cw=rw;ch=rh;}else{cw=rh;ch=rw;}
      out.push({n:row[i],x:ox,y:oy,w:cw,h:ch});
      if(vert)oy+=ch;else ox+=cw; }
    if(vert)x+=rw;else y+=rw;
    if(vert)w-=rw;else h-=rw; fw=vert?h:w; rem-=rowSum; row=[];rowSum=0; }
  for(var j=0;j<items.length;j++){
    var it=items[j]; var ratio=rowSum?Math.max((fw*fw*rowSum)/ (rowSum*rowSum), (rowSum*rowSum)/(fw*fw*rowSum)):0;
    var nr=rowSum+it.s; var r1=(fw*fw*nr)/(nr*nr*1.0);
    if(!row.length||r1<=ratio+1e-9||ratio===0){row.push(it);rowSum+=it.s;}
    else{place();j--;}
    if(fw<=0)break;
  }
  if(row.length)place();
}
function render(){
  var map=document.getElementById('map'),W=map.clientWidth,H=map.clientHeight;
  map.innerHTML='';
  var out=[];squarify(cur.c.slice(),0,0,W,H,out);
  var depth=stack.length;
  for(var i=0;i<out.length;i++){
    var c=out[i],d=document.createElement('div');
    d.className='cell';
    d.style.left=c.x+'px';d.style.top=c.y+'px';d.style.width=Math.max(0,c.w-2)+'px';d.style.height=Math.max(0,c.h-2)+'px';
    var lum=0.25+0.5*Math.min(1,c.n.s/(cur.s||1)*8);
    d.style.background=color(depth+i);
    d.style.opacity=lum+0.35;
    var showName=c.w>50&&c.h>16;
    if(showName){var l=document.createElement('div');l.className='lbl';
      l.textContent=c.n.n+'  '+fmt(c.n.s);
      l.style.fontSize=(c.w>200&&c.h>60)?'14px':'11px';
      d.appendChild(l);}
    d.onmousemove=function(ev,n){var t=document.getElementById('tip');
      t.style.display='block';t.style.left=(ev.clientX+14)+'px';t.style.top=(ev.clientY+14)+'px';
      t.textContent=n.n+'  =  '+fmt(n.s)+(n.c&&n.c.length?('  ('+n.c.length+' children)'):'');};
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
