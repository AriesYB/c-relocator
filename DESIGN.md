# c-relocator 设计文档

**C 盘配置重定向与数据迁移 Skill**

- 版本：v0.1（草案，待评审）
- 日期：2026-11-03

---

## 1. 背景与定位

C 盘被开发工具链的默认写入位置吃满：npm、pip、conda、Gradle、Maven、cargo、Go、
JetBrains 索引、CUDA、WSL/Docker 虚拟盘……市面清理软件只能"删垃圾"，治不了
"程序总往 C 盘写"这个本因。本项目解决的是**重定向**：

> 对支持官方配置的工具，改配置并把已有数据迁走；
> 对不支持配置的路径，建目录联接（junction）并把数据迁走；
> 全程 manifest 记录，支持撤销与重装系统后一键重建。

**形态**：一个 ZCode 个人 skill（承载知识 + 工作流 + 护栏）+ 自带 PowerShell 脚本。
不是 GUI 软件，不是驻留后台服务，不做删除垃圾式的"清理"。

### 1.1 目标

| # | 目标 |
|---|------|
| G1 | `config` 型工具：AI 修改官方配置 + 迁移已有数据 + 验证配置生效 |
| G2 | 无配置可改的路径：建 junction + 迁移数据，程序无感知 |
| G3 | manifest 记录一切迁移，支持 `undo`（撤销）与 `rebuild`（重装系统后重建链接） |
| G4 | 所有危险操作固化在脚本里，AI 只调用脚本，禁止即兴手搓 robocopy/rmdir |
| G5 | 可重复执行：`audit` 周期性扫描，发现新的"漏网之鱼" |

### 1.2 非目标

- 不做垃圾清理 / 删除冗余文件类功能（那是另一类工具的职责）。
- 不做 GUI（先 CLI + skill；确有需要后续再套壳）。
- 不处理系统目录（见 deny 名单，永不操作）。
- 不管理项目内部的 venv / node_modules（属于"项目别建在 C 盘"，不是迁移问题）。

---

## 2. 总体架构

### 2.1 三种处理机制

| 机制 | 含义 | 优先级 | 典型例子 |
|------|------|--------|----------|
| `config` | 用工具官方配置项重定向（环境变量 / CLI 配置 / 配置文件） | **优先** | npm、pip、Gradle、cargo、Go、JetBrains、conda |
| `junction` | 目录联接兜底：数据实移到目标盘，原位置放链接 | 次之 | CUDA Toolkit、不让选安装路径的软件 |
| `deny` | 拒绝清单 | **永不操作** | 见 §7.1 |

规则库决定每个条目用哪种机制。`deny` 在 SKILL.md（铁律）和规则库里双重设防。

**为什么 config 优先于 junction**：config 重定向不依赖文件系统链接，卸载、更新、
重装 Windows 都不会踩坑，且重装后只需重跑配置命令；junction 是给"没得选"的场景兜底。

### 2.2 仓库结构

```
creloc/
├── DESIGN.md                  # 本文档
├── README.md
└── skill/                     # 规范 skill 结构，整体复制/链接到个人技能目录安装
    ├── SKILL.md               # 工作流 + 铁律（写给人和对 AI 的约束）
    ├── rules.json             # 规则库（纯数据，可独立维护扩充）
    └── scripts/
        ├── Scan-Reloc.ps1     # 扫描：体积统计 + 规则识别（只读，无写操作）
        ├── Move-Reloc.ps1     # 迁移核心：唯一允许执行移动/建链接的入口
        └── Undo-Reloc.ps1     # 撤销 / 重建 / 确认删除备份
```

安装方式：把 `skill/` 目录复制或链接到个人技能目录
（`~\.agents\skills\c-relocator\`），skill 名 `c-relocator`，后续发布到 skill 市场。

### 2.3 运行时状态（不进仓库）

| 内容 | 位置 | 说明 |
|------|------|------|
| 迁移根目录（reloc 根） | 首次运行推荐 + 用户确认（§6.0） | 推荐规则：非 C 盘的本地固定 NTFS 盘中剩余空间最大者，命名 `<盘>:\Reloc`；各工具数据按 `<id>` 分目录 |
| manifest | `<reloc根>\manifest.json` | **唯一状态源**，所有迁移的台账 |
| 配置文件备份 | `<reloc根>\undo\<id>\` | 改配置前先备份原文件，供 undo 还原 |
| 数据备份 | 原目录就地改名 `*.reloc-bak` | 迁移后保留，显式确认后才删 |

---

## 3. 规则库 `rules.json`

规则库是纯数据，SKILL.md 只教 AI 怎么读它、怎么执行。条目 schema：

| 字段 | 类型 | 说明 |
|------|------|------|
| `id` | string | 唯一标识，如 `npm`、`jetbrains-system` |
| `name` | string | 展示名 |
| `mechanism` | enum | `config` / `junction` / `deny` |
| `detect.paths` | string[] | 待检测路径（支持 `%ENV%` 展开），用于 audit 体积统计 |
| `detect.processes` | string[] | 迁移前必须确认未运行的进程名（如 `node`、`java`） |
| `config.steps` | step[] | 仅 `config` 型：按序执行的配置步骤（见下） |
| `data.targets` | map | 源路径 → 迁移目标路径（`{reloc}` 占位 reloc 根） |
| `verify` | string[] | 迁移后的验证命令（如 `npm config get prefix`） |
| `risk` | enum | `low` / `medium` / `high`；medium 及以上 migrate 前必须先询问用户 |
| `notes` | string | 给 AI 的注意事项 |

`config.steps` 支持三种步骤类型：

- `command`：执行 CLI 配置命令（如 `npm config set prefix "{reloc}\npm"`）。
- `env`：设置用户级环境变量（`setx`，如 `GRADLE_USER_HOME`）。
- `file_edit`：编辑配置文件（如 JetBrains 的 `idea.properties`）；执行前自动把
  原文件备份到 `undo\<id>\`。

### 3.1 示例条目（npm）

```json
{
  "id": "npm",
  "name": "npm（全局包 prefix + 下载缓存 cache）",
  "mechanism": "config",
  "detect": {
    "paths": ["%LOCALAPPDATA%\\npm", "%LOCALAPPDATA%\\npm-cache"],
    "processes": ["node"]
  },
  "config": {
    "steps": [
      { "type": "command", "cmd": "npm config set prefix \"{reloc}\\npm\"" },
      { "type": "command", "cmd": "npm config set cache \"{reloc}\\npm-cache\"" }
    ]
  },
  "data": {
    "targets": {
      "%LOCALAPPDATA%\\npm": "{reloc}\\npm",
      "%LOCALAPPDATA%\\npm-cache": "{reloc}\\npm-cache"
    }
  },
  "verify": ["npm config get prefix", "npm config get cache"],
  "risk": "low",
  "notes": "迁移后旧 PATH 里的 %LOCALAPPDATA%\\npm 失效，需检查用户 PATH 环境变量是否引用旧 prefix。"
}
```

### 3.2 deny 条目示例

```json
{
  "id": "windows-system",
  "mechanism": "deny",
  "detect": { "paths": ["C:\\Windows", "C:\\ProgramData\\Microsoft"] },
  "notes": "系统目录、WinSxS、WindowsApps、Office ClickToRun、%LOCALAPPDATA%\\Microsoft 大部分——服务和更新机制依赖，junction 会导致更新/修复异常。"
}
```

### 3.3 计划覆盖清单（M2 逐步铺开）

- **config 型**：npm、pip、conda（pkgs_dirs/envs_dirs）、Gradle（`GRADLE_USER_HOME`）、
  Maven（settings.xml）、cargo/rustup（`CARGO_HOME`/`RUSTUP_HOME`）、Go（`GOPATH`）、
  JetBrains 索引（`idea.properties` 的 `idea.system.path`）、
  HuggingFace/PyTorch（`HF_HOME`/`TORCH_HOME`）、Android（SDK 路径 + `ANDROID_AVD_HOME`）。
- **junction 型**：CUDA Toolkit、`C:\ProgramData\NVIDIA Corporation\Downloader`（仅清缓存提示）、
  以及任何 audit 中新发现的不给选路径的软件。
- **官方自带迁移、不重复造轮子**（规则库标注"用官方命令"，由 AI 执行）：
  WSL（`wsl --export/--import`）、Docker Desktop（设置里改 disk image location）。
- **medium risk（默认纳入规则库，migrate 前必问）**：浏览器配置目录、
  `%LOCALAPPDATA%` 下的单个大型应用数据目录。

---

## 4. 脚本设计

### 4.1 `Move-Reloc.ps1` —— 唯一危险操作入口

AI 迁移数据一律调此脚本，禁止自己拼 robocopy/mklink/rmdir。

**参数**

| 参数 | 说明 |
|------|------|
| `-Source` | 源目录（C 盘） |
| `-Target` | 目标目录（reloc 根下） |
| `-Mode` | `junction`（复制→建链接）或 `copy`（仅复制，供 config 型用） |
| `-BlockProcesses` | 进程名列表，发现任一在跑则拒绝执行 |
| `-Id` | 规则库条目 id（写入 manifest） |

**junction 模式流程（顺序即安全设计）**

1. **预检**：源存在且不是已有链接；源目录树内无嵌套链接（robocopy `/XJ` 会跳过它们，
   搬完会缺文件）；目标盘为本地固定 NTFS 卷；目标盘剩余空间 ≥ 源体积 × 1.1；
   源不在 deny 名单；`-BlockProcesses` 无一在运行。任一不过即失败退出。
2. **robocopy 复制**：`/E /COPY:DAT /DCOPY:DAT /XJ /R:1 /W:1`。
   `/XJ` 防穿透链接造成循环/误伤。退出码 < 8 视为成功（robocopy 1~7 是各种"成功带提示"）。
3. **失败即清理**：复制中途失败（≥8）→ 删除目标侧半成品 → 源目录毫发无损 → 报错退出，
   不写 manifest 成功状态。
4. **复制全部成功后**才把源目录改名 `*.reloc-bak`（原地保留，回滚点）。
5. **建 junction**：`New-Item -ItemType Junction`（目标此时已存在）。
6. **哨兵验证**：向目标写一个 sentinel 文件，通过 C 盘原路径读回并比对内容一致；
   再抽查一个已有大文件对比长度。
7. **写 manifest**：状态 `backup-pending`（链接已生效，备份待确认删除）。
8. 输出结果与下一步指引（备份删除由 `Undo-Reloc.ps1 -Action confirm` 在用户显式确认后单独执行）。

注：复制阶段 C/D 两盘同时占空间，属预期；先复制后改名的顺序保证任何时刻
失败都能干净回滚。

**copy 模式**：仅执行步骤 1~3 + manifest（状态 `copy-done`，源目录待配置验证后
经 `Undo-Reloc.ps1 -Action confirm` 删除）。无链接、无改名。

**删除 junction 的固定姿势**：统一用 `cmd /c rmdir "<junction路径>"`（rmdir 对
junction 只删链接本身，不动目标）；禁止 `Remove-Item -Recurse` 作用于链接路径。

### 4.2 `Scan-Reloc.ps1` —— 只读扫描

- 展开 rules.json 各条目 `detect.paths`，统计体积，输出排行。
- 可选 `-TopDirs`：对 `%LOCALAPPDATA%`、`%APPDATA%`、`%USERPROFILE%` 做一层/两层
  目录体积扫描，找规则库没覆盖的新大头（漏网之鱼）。
- 标注每条状态：未迁移 / 已迁移（查 manifest）/ 已是链接（识别 junction，防重复操作）。

### 4.3 `Undo-Reloc.ps1` —— 撤销与重建

- `-Action undo -Id <id>`：junction 型 → `rmdir` 链接 → 把 `.reloc-bak` 改名回原路径
  （备份已删时改为把目标盘数据 robocopy `/MOVE` 搬回）；copy 型 → 原目录还在则只删目标盘
  副本，已 confirm 过则把数据搬回原位。同时按条目 `configUndo` 记录还原环境变量 / PATH /
  配置文件；规则里的 `undo` 命令（如 `npm config delete prefix`）由 AI 执行。
- `-Action rebuild`：读 manifest，凡 junction 型条目目标数据仍在而 C 盘链接丢失
  （重装系统场景）→ 批量重建 junction。
- `-Action confirm -Id <id>`：先重跑哨兵验证（junction 型；copy 型校验源不是链接），
  通过后才删 `.reloc-bak` / 旧源目录，manifest 状态改为 `active`。

---

## 5. Manifest 设计（`<reloc根>\manifest.json`）

```json
{
  "version": 1,
  "relocRoot": "D:\\Reloc",
  "entries": [
    {
      "id": "jetbrains-system",
      "mechanism": "junction",
      "source": "C:\\Users\\HetFrame\\AppData\\Local\\JetBrains",
      "target": "D:\\Reloc\\jetbrains-system",
      "bytes": 32145678901,
      "linkType": "junction",
      "movedAt": "2026-11-03T21:00:00",
      "backup": "C:\\Users\\HetFrame\\AppData\\Local\\JetBrains.reloc-bak",
      "status": "backup-pending"
    },
    {
      "id": "npm",
      "mechanism": "config",
      "configBackup": "D:\\Reloc\\undo\\npm\\",
      "configChanged": [".npmrc: prefix", ".npmrc: cache"],
      "entries": [
        { "source": "%LOCALAPPDATA%\\npm-cache", "target": "D:\\Reloc\\npm\\npm-cache", "status": "copy-done" }
      ]
    }
  ]
}
```

状态机：`copy-done / backup-pending → active → undone`；失败写 `failed` 并保留现场。

---

## 6. SKILL.md 工作流（概要）

### 6.0 首次运行（初始化 reloc 根）

manifest 不存在时先初始化：按"非 C 盘的本地固定 NTFS 盘中剩余空间最大"生成推荐值
`<盘>:\Reloc`，向用户展示推荐值并请其确认或改选（不得未经确认自行选定），然后创建
`<reloc根>\undo\` 目录与初始 manifest（`version` / `relocRoot` / `entries`）。

**子命令**（skill 入口参数）：

| 子命令 | 行为 | 写操作 |
|--------|------|--------|
| `audit` | Scan-Reloc 扫描 + 对照规则库 + 输出建议表（机制/体积/风险） | 无 |
| `migrate <id>` | 单条完整迁移：预检 → 脚本 → 验证 → 汇报 | 有 |
| `undo <id>` | 撤销该条迁移 | 有 |
| `rebuild` | 重装系统后批量重建链接 | 有 |
| `preplace <路径>` | 预占位：在安装软件**之前**把预期写入路径建好 junction（对付不让选盘符的安装器） | 有 |
| `status` | 读 manifest 汇报现状 | 无 |

**铁律**（写死在 SKILL.md，AI 任何时候不得违反）：

1. deny 名单内的路径永不执行任何写操作，包括用户明确要求时也要先警告再拒绝。
2. 删除备份（`.reloc-bak` / 源目录）是唯一不可逆动作，必须用户显式确认后经
   `-ConfirmDelete` 执行，且脚本内部先重跑验证。
3. 一切文件移动与链接创建必须经 `Move-Reloc.ps1`；junction 删除必须 `rmdir`。
4. 进程检查不通过（相关软件在运行）→ 拒绝迁移，提示用户退出后重试。
5. 任何一步失败即停止并汇报现场（已完成的步骤、当前状态、建议动作），不自行跳步补救。

---

## 7. 安全护栏汇总

### 7.1 deny 名单（永不操作）

`C:\Windows` 全部（含 WinSxS、Installer）、`C:\Program Files\WindowsApps`、
`C:\ProgramData\Microsoft`（搜索索引 / Defender）、`%LOCALAPPDATA%\Microsoft` 大部分、
Office ClickToRun（`Program Files\Microsoft Office`、`Common Files\microsoft shared\ClickToRun`）、
杀毒软件目录。原则：**被系统服务、Windows 更新、Office 即点即用机制依赖的目录一律不动。**

### 7.2 预检清单（脚本强制）

源不是已有链接 · 源树内无嵌套链接 · 目标盘 NTFS + 本地固定磁盘 · 剩余空间 ≥ 源 × 1.1 ·
不在 deny 名单 · 相关进程未运行。

### 7.3 流程护栏

先复制后改名（失败零损失回滚）· `/XJ` 防穿透 · 哨兵验证通过才算成功 ·
两步删除 · manifest 全程台账 · agent 审批机制作为最外层人工闸门。

### 7.4 实现陷阱备忘（脚本维护者向，2026-11-03 实战沉淀）

- PowerShell 变量名大小写不敏感且参数可带类型约束：局部变量与参数同名（如 `$rules` 撞上
  `[string]$Rules`）会把数组赋值强转成拼接字符串，循环静默跑错。写脚本时变量命名避开参数名。
- `[Environment]::SetEnvironmentVariable('Path', …)` 固定写 REG_SZ；原值若是 REG_EXPAND_SZ 且含
  %VAR% 条目会被破坏。PATH 回写一律走 Registry API 按 GetValueKind 回写（SKILL.md 片段已按此实现）。
- robocopy 退出码 0~7 均为成功语义，≥8 才是失败。
- npm 生成的 `.cmd` shim 用 `%~dp0` 相对路径，整目录平移 + PATH 改指即无损；个别宿主 shell 直跑
  `.cmd` 会报 0xC0000142 假失败，验证用 PowerShell `&` 调用并对比新旧位置。

---

## 8. 风险与边界（诚实清单）

| 风险 | 缓解 |
|------|------|
| 个别卸载器卸载时穿透 junction 清掉 D 盘数据 | manifest 台账 + 工作流约定"卸载软件前先查它是否涉及链接目录"，先撤链接再卸载 |
| junction 依赖 NTFS 本地固定盘 | 预检强制；exFAT/网络路径直接拒绝 |
| config 型工具重装/升级后配置丢失 | audit 时顺带跑 verify 命令检测配置是否仍生效 |
| 迁移占用 C/D 两份临时空间 | 流程设计已声明；audit 输出提示所需空间 |
| 锁定文件导致 robocopy 失败 | 进程预检 + 失败干净回滚，源不受影响 |
| 浏览器等 medium risk 目录偶发更新异常 | risk=medium 条目 migrate 前强制询问用户 |
| 重装 Windows 后链接全丢 | `rebuild` 从 manifest 一键重建（数据在 D 盘完好） |

---

## 9. 里程碑

| 阶段 | 内容 | 验收 |
|------|------|------|
| **M1 骨架实战** | SKILL.md + rules.json 首批条目（npm、pip、jetbrains-system 等 + deny 名单）+ 三脚本 + manifest；在本机真实迁移 npm 与 JetBrains 索引 | 迁移后 IDE 正常打开、`npm config get` 指向新位置、哨兵验证过、undo 演练成功一次 |
| **M2 规则库铺开** | §3.3 全部条目 + Scan-Reloc（含 TopDirs 找漏网之鱼）+ audit 子命令成型 | 本机 audit 出一份完整报告，migrate 覆盖 config/junction 两种机制各 ≥2 条 |
| **M3 收尾** | Undo/Rebuild/ConfirmDelete + preplace + README + skill 安装到个人技能目录 | 重装演练（删链接→rebuild 恢复）、卸载前撤链接演练通过 |

---

## 10. 决策记录（2026-11-03 评审）

1. **迁移根目录**：不写死默认值。首次运行生成推荐值（非 C 盘的本地固定 NTFS 盘中
   剩余空间最大者，命名 `<盘>:\Reloc`），由用户确认或改选后才初始化（见 §6.0）。
2. **命名**：项目与 skill 定名 `c-relocator`（原草案 creloc 不够直观）。
3. **远程仓库**：GitHub 公开仓开源，后续发布到 skill 市场。
4. **备份删除策略**：即删 + 用户显式确认 + 脚本强制重验证（不加冷却期，沿用草案）。
5. **medium risk 条目**：纳入规则库，audit 仅提示，不主动 migrate（沿用草案）。
