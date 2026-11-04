---
name: c-relocator
description: C 盘满了？把开发工具的数据、缓存、索引从 C 盘迁移到其他盘：能配置的走官方配置重定向（npm/pip/Gradle/JetBrains/CUDA 等），不能配置的用 NTFS junction 链接兜底；全程台账，可撤销、可重建、可预占位。内置实时 treemap 磁盘占用分析可视化，快速定位大目录大文件。用于 C 盘空间不足、C 盘瘦身、迁移工具数据、重定向存储位置、分析磁盘占用。
license: MIT
metadata:
  version: 0.3.1
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

- 规则库：`rules.json`（与本文件同目录，纯数据可自由扩充）
- 脚本：`scripts/Scan-Reloc.ps1`（只读审计）、`scripts/Move-Reloc.ps1`（迁移唯一入口）、`scripts/Undo-Reloc.ps1`（撤销/重建/确认删除）、`scripts/Map-Reloc.ps1`（实时 treemap，后端+前端单文件自包含）。运行方式：`powershell -NoProfile -ExecutionPolicy Bypass -File <脚本> <参数>`
- 参考文档（按需读取）：`references/config-steps.md`（config 步骤执行规范，执行 config 型步骤前必读）、`references/livemap-notes.md`（live map 交互规格与踩坑实录，排障/改 viewer 前必读）
- manifest：`<reloc根>\manifest.json` — 唯一状态源；配置备份：`<reloc根>\undo\<id>\`

## 进程处理规范

迁移被 `-BlockProcesses` 拒绝时：

1. 把正在运行的进程名清单报给用户，首选请用户自行保存工作并关闭。
2. 用户要求代关时，先优雅关闭（等同点窗口 X）：

   ```powershell
   Get-Process -Name 'idea*','jcef*' -ErrorAction SilentlyContinue |
     ForEach-Object { [void]$_.CloseMainWindow() }
   ```

   等 10~20 秒复查；仍未退出且用户明确同意强杀，才允许 `Stop-Process -Force`。
3. 复查进程清单为空后再迁移。AI 不得未经用户同意强杀进程。

## 首次运行：确定 reloc 根

manifest 不存在时：

1. 列候选盘（非 C 的本地固定 NTFS 盘，按剩余空间降序），推荐剩余空间最大者的 `<盘>:\Reloc`：

   ```powershell
   [IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady -and $_.DriveType -eq 'Fixed' -and $_.DriveFormat -eq 'NTFS' -and $_.Name -notlike 'C:*' } |
     Sort-Object AvailableFreeSpace -Descending |
     ForEach-Object { '{0}  {1:N0} GB free' -f $_.Name, ($_.AvailableFreeSpace / 1GB) }
   ```

2. 请用户确认或给其他路径（AskUserQuestion）。**不得未经确认自行选定。**
3. 初始化：`New-Item "$root\undo" -Force`；`@{version=1; relocRoot=$root; entries=@()} | ConvertTo-Json | Set-Content "$root\manifest.json" -Encoding UTF8`。

## 子命令工作流

### status
读 manifest，汇报每条迁移状态（active / backup-pending / copy-done / undone / failed）。

### audit（只读）
`Scan-Reloc.ps1 -Rules <rules.json> -Manifest <manifest>` 规则库体检 → 输出建议表
（条目 / 机制 / 体积 / 风险 / 建议）。新发现的可迁条目先补进 `rules.json` 再 migrate。

### discover（只读）
1. 规则库之外的长尾：`Scan-Reloc.ps1 ... -TopDirs -Top 30` 对 `%LOCALAPPDATA%`、`%APPDATA%`、
   `%USERPROFILE%` 做子目录体积排行（慢时先 `-SkipSizes`）。
2. 全盘视角（SpaceSniffer 式）：`Map-Reloc.ps1 -Serve -Root C:\ -Port 8734 -Rules <rules.json>`
   SSE 流式 treemap——方块实时生长、单击展开/双击进入、右键打开/复制路径、counting 斜纹、
   文件灰目录彩。⚠️ ZCode 沙箱对 C:\ 枚举返回空，须 `Start-Process powershell ... -WindowStyle Hidden`
   脱离沙箱启动。静态导出：同脚本 `-Out map.html`。交互规格与排障详见
   `references/livemap-notes.md`。
3. 大目录**归属识别**（从强到弱）：名字即线索（`%LOCALAPPDATA%\<App>`）→ 目录内找标记
   （.exe 属性 / config / 日志）→ 反查注册表卸载表（HKLM/HKCU `...\Uninstall` 的
   `InstallLocation`/`DisplayIcon`）→ 联网检索 `<目录名> AppData folder which software`。
4. **可迁移性分析**（可选）：归属已知但机制不明且价值高（GB 级）时，用 reverse-engineer-anything
   对安装器/主程序做静态逆向（硬编码路径常量、环境变量、注册表键值），结论写进 rules.json notes。
5. **分类判断**：数据/缓存（无 .exe、有写入）→ config 优先；程序本体（含 .exe/运行时）→
   junction（风险升一级）；系统/托管 → deny。不确定的一律 risk=medium（migrate 前必问用户）。
6. 输出**提案表**（目录/归属/体积/机制/风险/依据），用户逐条确认后写 rules.json 再 migrate；
   未确认的只记录在案。`audit`/`discover` 均只读，唯一写操作是经确认的 rules.json 更新。

### migrate `<id>`
1. 从 `rules.json` 取条目，向用户复述动作（机制/源/目标/体积）；risk=medium 及以上先获确认。
2. 数据迁移（`%ENV%` 与 `{reloc}` 占位符先展开）：

   ```
   Move-Reloc.ps1 -Id <id> -Source <源> -Target <目标> -Manifest <manifest> `
     -Mode <rules 的 data.mode> -BlockProcesses <detect.processes 逗号分隔>
   ```

3. config 型：按 `config.steps` 顺序执行——**规范与代码模板见 `references/config-steps.md`，执行前必读**。
4. 验证两层：配置生效（跑 `verify` 命令）+ 数据可用（实测新位置命令，`.cmd` shim 假失败用
   PowerShell `& '<shim>' --version` 复核）；env 型只对新进程生效，向用户说明。
5. 汇报结果（带 C 盘剩余空间），提醒确认软件正常后再同意删备份（铁律 2）。
6. 删除确认可攒批：可再生缓存合并一次确认；npm 全局包等有状态数据必须先完成配置验证与实测。

### undo `<id>`
`Undo-Reloc.ps1 -Action undo -Id <id> -Manifest <manifest>`（还原数据/链接 + configUndo 记录的环境
变量、PATH、配置文件）；config 型再执行规则里对应步骤的 `undo` 命令。

### rebuild
重装系统后数据在、链接丢失：`Undo-Reloc.ps1 -Action rebuild -Manifest <manifest>` 批量重建 junction。

### confirm（删备份，须用户显式同意）
`Undo-Reloc.ps1 -Action confirm -Id <id> -Manifest <manifest>` — 先重验证再删，状态置 active。

### preplace `<C盘预期路径>`（预占位）
装新软件**之前**把预期路径做成 junction，专治不让选盘符的安装器：确认目标 `<reloc根>\<名称>`、
父目录已存在、路径尚不存在且不在 deny → `New-Item 'D:\Reloc\<名称>'` + `cmd /c mklink /J` →
写 manifest（status=active、bytes=0、notes 标 preplace）。

## 脚本参数速查

```
Move-Reloc.ps1 -Id <id> -Source <C盘源目录> -Target <目标盘目录> -Manifest <manifest>
               [-Mode junction|copy] [-BlockProcesses node,java,...] [-KeepLinks]
Scan-Reloc.ps1 -Rules <rules.json> [-Manifest <manifest>] [-Ids npm,pip]
               [-TopDirs] [-TopRoots <目录,...>] [-Top 20] [-SkipSizes]
Map-Reloc.ps1  -Root <目录> [-Depth 4] [-MinMB 50] [-Out <html>] [-Rules <rules.json>] [-NoPruneDeny]
               [-Serve -Port 8734]
Undo-Reloc.ps1 -Action undo|rebuild|confirm -Manifest <manifest> [-Id <id>] [-AllowLinkTree]
```

`-AllowLinkTree`：删含嵌套链接的树（bun/pnpm 风格）必须显式携带——改用 `rmdir /s /q`
（不跟链接），PS 5.1 的 `Remove-Item -Recurse` 会穿透链接删真实数据。

退出码：Move — 0 成功 / 10 预检失败 / 11 复制失败（已清理半成品）/ 12 后置失败（已回滚）。Undo — 0 / 20。

## 边界与已知风险

- junction 依赖 NTFS 本地固定盘；复制期间 C/D 两盘同时占空间；目标盘空间需 ≥ 源 × 1.1。
- 嵌套链接树默认拒绝迁移（robocopy `/XJ` 跳过导致缺文件）；确认无环后 `-KeepLinks`
  （目标侧重建，指向源内部的改写为新路径）。文件符号链接重建需管理员/开发者模式。
- 卸载软件前先查 manifest 是否涉及链接目录，必要时先 undo 再卸载（卸载器可能穿透链接）。
- WSL / Docker 虚拟磁盘用官方迁移（`wsl --export/--import`、Docker 设置），不要 junction 硬搬。
- 浏览器等 medium risk 条目：默认只在 audit 提示，不主动 migrate。
- Git Bash 里调 cmd 内建命令用 `cmd //c '...'`（双斜杠防 MSYS 路径转义），路径参数用反斜杠。
- live map（-Serve）的交互规格、SSE 细节与踩坑实录：`references/livemap-notes.md`。
