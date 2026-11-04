---
name: c-relocator
description: C 盘重定向与数据迁移（C 盘瘦身治本方案）：把 npm、pip、Gradle、cargo、Go、JetBrains 索引、HuggingFace 等从 C 盘迁到其他盘。能配置的工具改官方配置并迁移已有数据；不能配置的路径用目录联接 junction 兜底；manifest 全程台账，支持撤销（undo）、重装后重建（rebuild）、装前预占位（preplace）。当用户提到 C 盘满了 / C 盘空间不足 / C 盘瘦身、把某工具的缓存/索引/包迁到其他盘、修改 npm/pip/gradle/cargo/JetBrains/CUDA 存储位置、软件安装不让选盘符、junction/mklink 时使用。
license: MIT
metadata:
  version: 0.2.0
  platform: Windows 10/11 (PowerShell 5.1+)
---

# c-relocator — C 盘重定向与数据迁移

对"程序总往 C 盘写"做治本处理：清理软件只能删，这里做的是**挪 + 改写入位置**。

三种机制（优先级从高到低，`rules.json` 决定每条用什么）：

1. `config` — 用工具官方配置重定向（CLI 配置 / 环境变量 / 配置文件），最干净。
2. `junction` — 目录联接兜底：数据实移到目标盘，C 盘原位置放链接，程序无感知。
3. `deny` — 拒绝清单，永不操作。

## 铁律（任何情况下不得违反）

1. deny 名单内的路径永不执行任何写操作；用户明确要求也要先警告并拒绝。
2. 删除备份是唯一不可逆动作：必须用户显式同意后，经 `Undo-Reloc.ps1 -Action confirm` 执行（脚本内部会先重跑验证）。禁止直接手删 `.reloc-bak` 或旧源目录。
3. 一切数据移动与链接创建必须经 `Move-Reloc.ps1`；junction 删除一律 `cmd /c rmdir`（只删链接不动目标），禁止对链接路径用 `Remove-Item -Recurse`。
4. 迁移前相关进程检查必须通过（脚本 `-BlockProcesses` 强制）；不通过就提示用户关闭后重试，不要绕过。
5. 任何一步失败即停止，向用户汇报：已完成的步骤、当前状态、建议动作。不得自行跳步补救。

## 关键路径

- 规则库：`rules.json`（与本文件同目录）
- 脚本：`scripts/Scan-Reloc.ps1`、`scripts/Move-Reloc.ps1`、`scripts/Undo-Reloc.ps1`（运行方式：`powershell -NoProfile -ExecutionPolicy Bypass -File <脚本> <参数>`）
- manifest：`<reloc根>\manifest.json` — 唯一状态源，所有迁移的台账
- 配置文件备份：`<reloc根>\undo\<id>\`

## 进程处理规范

迁移被 `-BlockProcesses` 拒绝时：

1. 把正在运行的进程名清单报给用户，首选请用户自行保存工作并关闭。
2. 用户要求代关时，先优雅关闭（等同点窗口 X，有未保存内容会弹窗）：

   ```powershell
   Get-Process -Name 'idea*','jcef*' -ErrorAction SilentlyContinue |
     ForEach-Object { [void]$_.CloseMainWindow() }
   ```

   等待 10~20 秒后复查；仍未退出且用户明确同意强杀，才允许 `Stop-Process -Force`。
3. 复查进程清单为空后再迁移。AI 不得未经用户同意强杀进程。

## 首次运行：确定 reloc 根

manifest 不存在时先初始化：

1. 列出候选盘（非 C 的本地固定 NTFS 盘，按剩余空间降序），取剩余空间最大者推荐 `<盘>:\Reloc`：

   ```powershell
   [IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady -and $_.DriveType -eq 'Fixed' -and $_.DriveFormat -eq 'NTFS' -and $_.Name -notlike 'C:*' } |
     Sort-Object AvailableFreeSpace -Descending |
     ForEach-Object { '{0}  {1:N0} GB free' -f $_.Name, ($_.AvailableFreeSpace / 1GB) }
   ```

2. 向用户展示推荐值，请用户确认或给出其他路径（用 AskUserQuestion）。**不得未经确认自行选定。**
3. 创建初始状态：

   ```powershell
   $root = 'D:\Reloc'   # 用户确认后的值
   New-Item -ItemType Directory -Path "$root\undo" -Force | Out-Null
   @{ version = 1; relocRoot = $root; entries = @() } | ConvertTo-Json |
     Set-Content -LiteralPath "$root\manifest.json" -Encoding UTF8
   ```

## 子命令工作流

### status
读 manifest，汇报每条迁移的状态（active / backup-pending / copy-done / undone / failed）。

### audit（只读，无写操作）
1. `Scan-Reloc.ps1 -Rules <rules.json> -Manifest <manifest>` — 规则库条目体检（体积 / 状态 / 机制建议）。
2. 输出建议表：条目 / 机制 / 体积 / 风险 / 建议。新发现的可迁条目先补进 `rules.json` 再 migrate。

### discover（发现规则库之外的长尾，只读）
1. `Scan-Reloc.ps1 -Rules <rules.json> -Manifest <manifest> -TopDirs -Top 30` — 对 `%LOCALAPPDATA%`、
   `%APPDATA%`、`%USERPROFILE%` 做子目录体积排行（含文件数 / .exe 数 / 最近写入；deny 目录与
   链接自动剪枝）。大目录较慢时可先 `-SkipSizes` 看清单再挑着量。按体积从大到小逐个处理。
   全盘视角（SpaceSniffer 式，两种）：
   - **实时动态**（推荐）：`Map-Reloc.ps1 -Serve -Root C:\ -Port 8734 -Rules <rules.json>` —— 启动本地
     服务并自动打开浏览器，方块随扫描进度实时生长（每 600ms 刷新；扫描每 16MB/400 项增量刷新，
     方块连续长大而非跳变），悬停显示完整路径与实时体积。SpaceSniffer 式交互：**单击 = 原地展开/收起**
     （方块顶部 16px 标签条保留不被遮挡，子项在剩余区域内 treemap 拼凑渲染、兄弟块保持可见便于对比；
     两道防细条：面积 <180px² 的极小项不单独成块；布局后再做形状检测——最小边 <5px 或长宽比 >7 的
     细条并入底部灰色"剩余N项（极小/未扫完）"聚合条占位（高度按占比 18px~40%，随扫描进度自动
     增减，迭代至无细条——实测最大长宽比 ≤3.1、最小边 ≥8px）。**文件统一灰色显示、目录多彩**，
     一眼区分不可再分项。**双击 = 进入**（整屏切到该目录），排序带 12% 迟滞——方块平滑地
     逐步长大，只有真正超越相邻块 12% 才交换位置，不会来回跳。
     `⬅ 返回` 按钮 / Backspace 返回上级，Esc 收起全部展开，面包屑跳转；**右键方块在资源管理器中
     打开**（文件则定位所在文件夹并选中——走本地 `/open` 端点，仅 127.0.0.1 可达），**复制完整路径**
     也在右键菜单里。多层展开时每层标签条有深色底+金色下划线+按层级 12px 递进缩进，外层名称
     永不被内层淹没。小方块展开后放不下子块属正常（面积比例限制），用双击进入看。
     数据链路为 **SSE 流式推送**（`/events?paths=…`，版本号门控 + 800ms 节流 + 冗余子路径去重；
     worker 增量 flush 16MB/400 项/250ms 触发版本 +1），断流自动降级回 600ms 轮询。
     已知限制：客户端展开/进入会为该子树创建独立重扫任务，与根 DFS 并行抢 IO，两个都会变慢——
     属架构特性非故障。Ctrl+C 停止。
     ⚠️ ZCode 环境：后台任务（run_in_background）跑在沙箱里，沙箱对 C:\ 等盘的目录枚举会返回空
     （不报错），导致永远扫不出数据。必须用 `Start-Process powershell -ArgumentList ...` 脱离沙箱
     启动（-WindowStyle Hidden），或直接在用户自己的终端里运行。
   - **静态导出**：`Map-Reloc.ps1 -Root C:\ -Depth 4 -MinMB 50 -Out map.html -Rules <rules.json>` ——
     扫完后生成自包含交互式 HTML treemap。
   两种模式均剪枝 deny 目录（`-NoPruneDeny` 连系统目录一起看），永不跟随链接。
2. 对每个大目录做**归属识别**（手段从强到弱）：
   - 名字即线索：`%LOCALAPPDATA%\<App>`、`%LOCALAPPDATA%\Programs\<App>` 多为厂商/产品名；
   - 目录内找标记：`.exe` 的产品属性、settings/config 文件、package 标识、日志内容；
   - 反查注册表卸载表：`HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall` 与
     `HKCU\...\Uninstall` 的 `InstallLocation` / `DisplayIcon` 是否指向该路径；
   - 仍不确定就联网检索：`<目录名> AppData folder which software`、`<App> move cache/data to another drive`。
3. **可迁移性分析（高级，可选）**：归属已知但"支持 config 还是只能 junction / 有没有隐藏的
   安装路径选项"不确定、且目录价值高（GB 级）时，可用 reverse-engineer-anything (REA) 对安装器
   或主程序做静态逆向：提取硬编码路径常量、读取的环境变量名、写注册表的键值——直接回答
   "这个软件认哪些重定向开关"（CUDA 安装器的路径常量、Electron 应用是否读 XXX_HOME 皆可如此确认）。
   REA 成本高，只对高价值未知项使用；结论写进 rules.json 的 notes 注明来源。
4. **分类判断**：文件数巨大、无 .exe、近期有写入 → 数据/缓存（首选 config，无配置则 junction）；
   含 .exe/运行时 → 程序本体（junction 可行，但卸载器穿透风险升一级，risk=medium）；
   属于系统/托管的 → deny。识别不确定的一律 risk=medium（migrate 前必问用户）。
5. 向用户输出**提案表**（目录 / 归属结论 / 体积 / 建议机制 / 风险 / 依据来源），用户逐条确认后：
   确认迁的先写入 `rules.json`（机制、config 步骤、data 映射、verify、risk、notes 带上依据），
   再走标准 migrate 流程。用户没确认的只记录在案，绝不擅自迁移。
6. `audit` 与 `discover` 均只读；唯一写操作是用户确认后更新 `rules.json`。

### migrate `<id>`
1. 从 `rules.json` 取条目，向用户复述将要执行的动作（机制、源、目标、体积）；risk=medium 及以上必须先获用户确认。
2. 数据迁移：对 `data.targets` 每个映射调用一次（`%ENV%` 与 `{reloc}` 占位符先展开成实际路径）：

   ```
   Move-Reloc.ps1 -Id <id> -Source <源> -Target <目标> -Manifest <manifest> `
     -Mode <rules 的 data.mode> -BlockProcesses <detect.processes 逗号分隔>
   ```

3. config 型：按 `config.steps` 顺序执行，遵守下方「config 步骤执行规范」。
4. 验证按两层口径：
   - 配置生效：运行 `verify` 中的命令（如 `pip cache dir`、`npm config get prefix`）。
   - 数据可用：能实测就实测（如对新位置的全局命令跑一次 `--version`）。注意 `.cmd` shim 在个别
     宿主 shell 直跑可能报 0xC0000142 假失败——用 PowerShell `& '<shim>' --version` 复核，并与
     旧位置结果一致才算平移无损。
   - env 型配置只对新进程生效（已开着的 IDE / 终端要重启才读到），向用户说明。
5. 汇报结果（带上 C 盘当前剩余空间，紧张时提示尽快确认），并提醒：确认软件正常后，
   再让用户同意删除备份（铁律 2）。
6. 删除确认可攒批：可再生数据（pip/npm/gradle 的缓存与依赖）验证通过后可合并为一次确认；
   npm 全局包这类有状态数据，确认前必须完成配置验证与命令实测。多条一次迁完时汇总一张
   验证表、一次确认，避免逐条打断。

### undo `<id>`
1. `Undo-Reloc.ps1 -Action undo -Id <id> -Manifest <manifest>`（还原数据/链接，并按条目 `configUndo` 记录还原环境变量、PATH、配置文件）。
2. config 型再执行规则里对应步骤的 `undo` 命令（如 `npm config delete prefix`）。

### rebuild
重装系统后数据还在、链接丢失时：`Undo-Reloc.ps1 -Action rebuild -Manifest <manifest>` 批量重建 junction。

### confirm（删除备份，须用户显式同意）
`Undo-Reloc.ps1 -Action confirm -Id <id> -Manifest <manifest>` — 脚本先重验证再删，manifest 状态置 active。

### preplace `<C盘预期路径>`（预占位）
安装新软件**之前**把预期写入路径做成 junction，专治不让选盘符的安装器：

1. 与用户确认目标 `<reloc根>\<名称>`；C 盘预期路径的父目录需已存在；该路径必须尚不存在且不在 deny 名单。
2. 最小操作：

   ```powershell
   New-Item -ItemType Directory -Path 'D:\Reloc\<名称>' -Force | Out-Null
   cmd /c mklink /J '<C盘预期路径>' 'D:\Reloc\<名称>'
   ```

3. 作为一条 junction 记录写进 manifest（status=active、bytes=0、backup=$null、notes 标注 preplace）。

## config 步骤执行规范

每一步都必须：先备份 → 修改 → 把撤销信息记入 manifest 条目的 `configUndo` 数组。

- `type=command`：直接执行；撤销用规则里该步骤的 `undo` 命令（脚本不负责，由你执行）。
- `type=env`：

  ```powershell
  $name = 'GRADLE_USER_HOME'; $value = '<展开后的值>'
  $old = [Environment]::GetEnvironmentVariable($name, 'User')   # $null = 原本不存在
  [Environment]::SetEnvironmentVariable($name, $value, 'User')
  # 记入 configUndo：@{type='env'; name=$name; previousValue=$old}
  ```

- `type=path_update`（改用户 PATH，务必先备份整条 PATH）：

  ```powershell
  # 第一步先查存储形态：reg query HKCU\Environment /v Path
  # 若为 REG_EXPAND_SZ，严禁用 [Environment]::SetEnvironmentVariable 回写（它固定写 REG_SZ，
  # 会把 %VAR% 条目变成不可展开的死文本）；一律走 Registry API 按原 kind 回写：
  $reg = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
  $old = $reg.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
  $kind = $reg.GetValueKind('Path')
  Set-Content -LiteralPath '<reloc根>\undo\<id>\user-path-<时间戳>.txt' -Value $old -Encoding UTF8
  $new = ($old -split ';' | Where-Object { $_ -and $_.TrimEnd('\') -ne '<旧条目>' }) -join ';'
  if ($new -notlike '*<新条目>*') { $new = '<新条目>;' + $new }
  $reg.SetValue('Path', $new, $kind)   # String 或 ExpandString，按查到的原值
  # 记入 configUndo：@{type='path'; previousValue=$old}
  ```

- `type=file_edit`（如 JetBrains 的 idea.properties）：

  ```powershell
  Copy-Item '<配置文件>' '<reloc根>\undo\<id>\<文件名>.bak' -Force
  # 修改后记入 configUndo：@{type='file'; original='<原路径>'; backup='<备份路径>'}
  ```

- `type=manual`（AI 无法代劳的 UI 操作，如 WPS 云文档缓存位置）：AI 引导用户在软件界面里
  完成设置 → 等用户确认完成 → 验证结果（新位置出现数据、软件同步正常）→ 在 manifest 记录
  一条 config 型条目（status=active，notes 标注 manual/software-native-migration）入台账。
  `data.mode=manual` 标记此类：数据迁移由软件自身机制完成，Move-Reloc 不参与。

manifest 安全更新写法（不要手拼 JSON 字符串）：

```powershell
$m = Get-Content -Raw -Encoding UTF8 '<manifest>' | ConvertFrom-Json
$e = @($m.entries) | Where-Object { $_.id -eq '<id>' -and $_.source -eq '<source>' } | Select-Object -First 1
$e | Add-Member -NotePropertyName configUndo -NotePropertyValue @(
  [pscustomobject]@{ type = 'env'; name = 'GRADLE_USER_HOME'; previousValue = $null }
) -Force
$m.updatedAt = (Get-Date).ToString('o')
$m | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath '<manifest>' -Encoding UTF8
```

## 脚本参数速查

```
Move-Reloc.ps1 -Id <id> -Source <C盘源目录> -Target <目标盘目录> -Manifest <manifest>
               [-Mode junction|copy] [-BlockProcesses node,java,...] [-KeepLinks]
Scan-Reloc.ps1 -Rules <rules.json> [-Manifest <manifest>] [-Ids npm,pip]
               [-TopDirs] [-TopRoots <目录,...>] [-Top 20] [-SkipSizes]
Map-Reloc.ps1  -Root <目录> [-Depth 4] [-MinMB 50] [-Out <html>] [-Rules <rules.json>] [-NoPruneDeny]
Undo-Reloc.ps1 -Action undo|rebuild|confirm -Manifest <manifest> [-Id <id>] [-AllowLinkTree]
```

`-AllowLinkTree`：删除含嵌套链接的树（bun/pnpm 风格）时必须显式携带——此时脚本改用
`rmdir /s /q`（Vista 起不跟链接，只删链接本身），PS 5.1 的 `Remove-Item -Recurse` 会穿透
链接删到目标盘真实数据，绝不能用于链接树。

退出码：Move — 0 成功 / 10 预检失败 / 11 复制失败（已自动清理半成品，源未动）/ 12 后置步骤失败（已回滚）。Undo — 0 成功 / 20 失败（看输出）。

## 边界与已知风险

- junction 依赖 NTFS 本地固定盘；复制期间 C/D 两盘同时占空间；目标盘空间需 ≥ 源 × 1.1。
- 源目录树内有嵌套链接时脚本默认拒绝迁移（robocopy `/XJ` 会跳过它们导致缺文件）。确认链接
  无循环指向后可加 `-KeepLinks`：复制时照旧跳过链接，复制完在目标侧逐个重建——指向源内部的
  链接目标改写为新路径（迁移后自洽，旧数据可删），源外目标原样保留并告警；bun / pnpm 风格的
  缓存树（junction 海量）就是典型场景。文件符号链接的重建需要管理员/开发者模式，失败会告警跳过。
- 卸载软件前先查 manifest 是否涉及链接目录，必要时先 undo 再卸载（个别卸载器会穿透链接清掉目标盘数据）。
- WSL / Docker 用官方迁移（`wsl --export/--import`；Docker 设置里改 disk image location），规则库有标注，不要用 junction 硬搬虚拟磁盘所在目录。
- 浏览器等 medium risk 条目：默认只在 audit 提示，不主动 migrate。
- Git Bash 里调 cmd 内建命令用 `cmd //c '...'`（双斜杠防 MSYS 路径转义），路径参数用反斜杠形式。

### live map（Map-Reloc -Serve）踩坑实录

- **多实例**：重复启动会撞端口。症状：后台日志无限刷 `[serve] request error: Not listening`。
  排查：`Get-NetTCPConnection -LocalPort 8734 -State Listen` 拿 OwningProcess，再比对
  `Get-CimInstance Win32_Process` 的 CommandLine 找出多余实例杀掉。脚本现已在端口被占时
  明确报错退出，不再无限刷。
- **浏览器代理截 localhost**（国内开代理用户高频事故）：页面请求被代理吞掉 → 永远转圈。
  viewer 内置 4s 超时 + 连续失败横幅提示把 127.0.0.1/localhost 加入直连列表。验证服务本身
  用 `curl --noproxy '*' http://127.0.0.1:<port>/debug`。
- **HTML 模板占位符必须带引号**：`var ROOT='__ROOT__'` 不能写成 `var ROOT=__ROOT__`——裸值替换
  产生 `var ROOT=C:\` → 整段脚本语法错误 → 页面黑屏且控制台之外零提示。服务端 curl 200、
  接口正常，唯独页面死了，极易误判成网络/代理问题。
- **treemap 布局前必须归一化**：squarify 的输入是"面积"，拿原始字节数当像素算，一个 60GB
  目录会算出千万像素宽的格子吃掉整个画布（live 版其余方块全变 0，静态版页面被撑成无尽滚动）。
  正确做法：`k=W*H/总字节`，每项 `s×k` 后再进 squarify，标签/悬浮提示仍用原始字节。
- **服务端验证 ≠ 页面验证**：改 viewer JS 后必须用真实浏览器打开看一眼（或 `new Function(
  script文本)` 验语法），curl 只能证明服务端活着。
- **viewer 交互一律 `addEventListener`，禁用处理器属性**（`el.onclick=`/`oncontextmenu=`/`onkeydown=`）：
  ①agent 内置浏览器会在主世界剥离交互类处理器属性（防注入），页面表现为"点击/右键/按键全哑"
  但 onmousemove 正常、脚本源码完整、零报错——极易误判为代码问题；监听器不受影响。
  ②循环里 `var d` + 闭包读 `d.__n` 是经典陷阱：所有监听器共享函数级作用域的变量，全部读到
  最后一项（点 A 目录进了 B 目录）。listener 内用 `ev.currentTarget.__n` 取当前元素数据，
  既避开两个坑，又保证每次 render 刷新的 `d.__n` 是活数据（悬停体积实时更新）。
