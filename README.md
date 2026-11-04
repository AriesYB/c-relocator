# c-relocator

> Stop "C: drive full" at the root: redirect dev-tool storage with official configs or NTFS junctions — fully logged, undoable, rebuildable.
>
> 把"C 盘怎么又满了"变成一次性配置问题：对开发工具链做**配置重定向 + 数据迁移**，不做垃圾清理。

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-Windows%2010%2F11-blue)
![Agent](https://img.shields.io/badge/agent-Skills%20spec-green)

npm, pip, Gradle, cargo, Go, JetBrains indexes, HuggingFace, CUDA, WPS cloud, WeChat… they all
write to `C:` by default. Cleaner apps only delete the mess; **c-relocator moves the writer**:

- **Config-first**: for tools with official redirect options (env vars / CLI config / config files),
  the agent sets them and migrates existing data.
- **Junction fallback**: for paths with no official option (CUDA toolkit, IDE data dirs), it moves the
  data to another drive and drops an NTFS junction at the original location — apps never notice.
- **Manifest ledger**: every migration is recorded in `manifest.json` — undo any single entry,
  rebuild all junctions after a Windows reinstall, or pre-place junctions *before* installing
  software that refuses to ask for a path.
- **Safety model**: a hard deny-list (script + rules double line), one audited entry point for all
  moves (copy-then-rename, auto-rollback, sentinel verification), and deletion of backups is the only
  irreversible step — explicit user consent + forced re-verification.
- **Live disk mapping**: `Map-Reloc` streams a SpaceSniffer-style interactive treemap over SSE —
  blocks grow while scanning, click to expand in place, double-click to enter, right-click menu
  (open in Explorer / copy full path), sort hysteresis so tiles never jitter, slivers auto-fold
  into an aggregate bar, gray = file / colored = directory, animated stripes = still scanning.

## Install

Works with any agent that supports the [Agent Skills](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/overview) format (Claude Code, Codex, ZCode, OpenCode, Cursor…).

**Universal (skills CLI):**

```bash
npx skills add AriesYB/c-relocator
```

**Claude Code (plugin marketplace):**

```
/plugin marketplace add AriesYB/c-relocator
/plugin install c-relocator@ariesyb
```

**Manual:** copy the `skill/` folder to your agent's skills directory
(e.g. `~/.agents/skills/c-relocator`, `~/.claude/skills/c-relocator`, `~/.codex/skills/c-relocator`).

> Windows only. Junction creation needs no admin rights; operating under `Program Files` does.

## What the agent can do

| Command | Behavior |
|---|---|
| `audit` / `discover` | read-only scans: rules-based health check + TopDirs long-tail discovery + HTML treemap |
| `migrate <id>` | full migration: precheck → copy → config steps → verify (both config生效 and data-usable layers) |
| `undo <id>` | restore data/links + env vars / PATH / config files |
| `rebuild` | recreate all junctions after a Windows reinstall (data lives on the target drive) |
| `preplace <path>` | pre-place a junction before installing software that won't let you pick a drive |
| `confirm <id>` | re-verify, then delete the backup (the only irreversible step) |

The rule library (`rules.json`) ships with ~20 entries: npm, pip, conda, Gradle, Maven, cargo/rustup,
Go, HuggingFace, JetBrains (both AppData sides), VS Code, bun, WPS cloud drive, QQ/WeChat/WeCom data,
Electron updater caches, `~/.cache`, CUDA toolkit — plus deny entries. It's plain data; extend it freely.

## Real-world validation

Developed and verified on a machine that went from **1 GB free** on `C:` to double-digit GB in one
session: JetBrains (11.9 GB), WPS cloud (18.2 GB), Tencent data (11.5 GB, incl. hunting down an
invisible directory-handle locker), pip/gradle/npm/maven/bun/VS Code, 27 Electron updater caches in
one batch — every mechanism in this skill ran against production data first. Battle scars are
recorded in [DESIGN.md](DESIGN.md) §7.4.

## Safety notes

- Never touches: `C:\Windows` (WinSxS, Installer), `WindowsApps`, `ProgramData\Microsoft`,
  `%LOCALAPPDATA%\Microsoft`, Office ClickToRun, antivirus dirs.
- Junctions depend on NTFS fixed local disks; exFAT/network targets are rejected.
- Uninstalling software that sits behind a junction: undo the junction first (uninstallers may
  follow links). The manifest tells you which entries are linked.
- WSL / Docker virtual disks use their own official migration paths — the skill refuses to
  junction those.
- DELETING a backup is irreversible. The agent must ask you first, and the script re-verifies
  before deleting.

## Repository layout

```
skill/
├── SKILL.md        # workflow + iron rules (the skill itself)
├── rules.json      # rule library — pure data, extend freely
└── scripts/
    ├── Scan-Reloc.ps1   # read-only audit scanner (rules + TopDirs)
    ├── Map-Reloc.ps1    # live SSE treemap (SpaceSniffer-style interactions)
    ├── Move-Reloc.ps1   # THE migration entrypoint (junction/copy, -KeepLinks, -ResumeFromCopy)
    └── Undo-Reloc.ps1   # undo / rebuild / confirm-delete (-AllowLinkTree)
DESIGN.md           # design doc: architecture, safety model, field lessons (zh)
```

## License

[MIT](LICENSE)
