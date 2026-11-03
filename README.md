# c-relocator

> 把"C 盘怎么又满了"变成一次性配置问题：对开发工具链做**配置重定向 + 数据迁移**，不做垃圾清理。

npm、pip、Gradle、cargo、Go、JetBrains 索引、HuggingFace、CUDA……这些工具默认往 C 盘写，
清理软件只能删垃圾，治不了本因。c-relocator 是一个 ZCode skill：

- **能配置的工具**：改官方配置（环境变量 / CLI 配置 / 配置文件）并把已有数据迁走，迁完验证生效。
- **不能配置的路径**：建目录联接（junction），数据实移到其他盘，C 盘原位置放链接，程序无感知。
- **全程台账**：manifest 记录每次迁移，支持撤销（undo）、重装系统后一键重建链接（rebuild）、
  装新软件前预占位（preplace，专治不让选安装路径的安装器）。
- **安全模型**：拒绝名单写死（脚本 + 规则库双重防线）；危险操作只经一个入口脚本
  （先复制后改名、失败零损失回滚、哨兵验证）；删除备份是唯一不可逆动作，
  必须显式确认且脚本先重验证。

## 安装（ZCode skill）

把 `skill/` 目录复制到个人技能目录：

```
skill/ -> ~\.agents\skills\c-relocator\
```

包含：`SKILL.md`（工作流与铁律）、`rules.json`（规则库，纯数据可自行扩充）、
`scripts/`（Scan 只读扫描 / Move 唯一迁移入口 / Undo 撤销重建确认）。

## 使用示例

对 AI 说：

- "C 盘又满了，audit 一下看看有什么能迁的"
- "把 JetBrains 索引迁到 D 盘"
- "我要装 CUDA，先帮我预占位"
- "上次迁的 npm 不对，撤销"

## 状态

M1（骨架 + npm / pip / JetBrains 实战）进行中，规则库持续扩充，详见 [DESIGN.md](DESIGN.md)。

## 安全声明

- 永不操作：`C:\Windows`（含 WinSxS、Installer）、`WindowsApps`、`ProgramData\Microsoft`、
  `%LOCALAPPDATA%\Microsoft`、`%APPDATA%\Microsoft`、Office ClickToRun 等系统/托管目录。
- 迁移有风险：执行前让 AI 复述将要做的动作；备份删除前脚本会强制重新验证。
- WSL / Docker 虚拟磁盘走各自官方迁移方式，不用 junction 硬搬。
