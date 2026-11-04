# config 步骤执行规范（migrate 的 config 型步骤必读）

每一步都必须：先备份 → 修改 → 把撤销信息记入 manifest 条目的 `configUndo` 数组。

## type=command

直接执行；撤销用规则里该步骤的 `undo` 命令（脚本不负责，由 agent 执行）。

## type=env

```powershell
$name = 'GRADLE_USER_HOME'; $value = '<展开后的值>'
$old = [Environment]::GetEnvironmentVariable($name, 'User')   # $null = 原本不存在
[Environment]::SetEnvironmentVariable($name, $value, 'User')
# 记入 configUndo：@{type='env'; name=$name; previousValue=$old}
```

env 型配置只对新进程生效（已开着的 IDE / 终端要重启才读到），向用户说明。

## type=path_update（改用户 PATH，务必先备份整条 PATH）

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

## type=file_edit（如 JetBrains 的 idea.properties）

```powershell
Copy-Item '<配置文件>' '<reloc根>\undo\<id>\<文件名>.bak' -Force
# 修改后记入 configUndo：@{type='file'; original='<原路径>'; backup='<备份路径>'}
```

## type=manual（AI 无法代劳的 UI 操作，如 WPS 云文档缓存位置）

AI 引导用户在软件界面里完成设置 → 等用户确认完成 → 验证结果（新位置出现数据、软件同步
正常）→ 在 manifest 记录一条 config 型条目（status=active，notes 标注
manual/software-native-migration）入台账。`data.mode=manual` 标记此类：数据迁移由软件自身
机制完成，Move-Reloc 不参与。

## manifest 安全更新写法（不要手拼 JSON 字符串）

```powershell
$m = Get-Content -Raw -Encoding UTF8 '<manifest>' | ConvertFrom-Json
$e = @($m.entries) | Where-Object { $_.id -eq '<id>' -and $_.source -eq '<source>' } | Select-Object -First 1
$e | Add-Member -NotePropertyName configUndo -NotePropertyValue @(
  [pscustomobject]@{ type = 'env'; name = 'GRADLE_USER_HOME'; previousValue = $null }
) -Force
$m.updatedAt = (Get-Date).ToString('o')
$m | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath '<manifest>' -Encoding UTF8
```
