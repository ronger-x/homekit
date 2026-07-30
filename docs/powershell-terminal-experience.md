# PowerShell 7 命令补全与历史记录

本目录提供可在多台 Windows PC 上重复使用的 PowerShell 7 终端配置：

- `powershell/Install-TerminalExperience.ps1`：安装依赖、部署配置并更新当前用户的 PowerShell Profile。
- `powershell/TerminalExperience.ps1`：实际加载的 PSReadLine 与 PSFzf 配置模板。
- `powershell/PoshGitLazyLoad.ps1`：按需加载 Git 提示符的 posh-git 配置模板。

安装器默认从 PSGallery 安装当前最新版 `posh-git`，但不会在 PowerShell 启动阶段导入它；首次进入 Git 仓库时才加载，避免普通终端承担冷启动延迟。

## 安装

在仓库根目录、使用 PowerShell 7 执行：

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\powershell\Install-TerminalExperience.ps1
```

脚本会执行以下操作：

1. 从 PSGallery 为当前用户安装 `PSFzf` 和 `posh-git`。
2. 若未找到 `fzf`，通过 `winget` 安装 `junegunn.fzf`。
3. 把三个配置模板复制到 `$HOME\.config\homekit\powershell`。
4. 在 `$PROFILE.CurrentUserCurrentHost` 中添加或更新终端配置；若没有既有 posh-git 懒加载代码，再添加带标记的懒加载配置。
5. Profile 有内容且需要改动时，创建带时间戳的同目录备份。

不需要管理员权限。脚本不执行自动更新，也不会改写 Profile 中不属于该受管块的内容。

若只希望部署 Profile 配置，可跳过依赖安装：

```powershell
.\powershell\Install-TerminalExperience.ps1 -SkipModuleInstall -SkipFzfInstall
```

默认只在未安装时安装最新版。需要固定版本来复现环境时，可显式指定：

```powershell
.\powershell\Install-TerminalExperience.ps1 -PoshGitVersion 1.1.0
```

只跳过 posh-git 安装：

```powershell
.\powershell\Install-TerminalExperience.ps1 -SkipPoshGitInstall
```

先预演将会发生的改动：

```powershell
.\powershell\Install-TerminalExperience.ps1 -WhatIf
```

## 使用

重新打开 PowerShell 7 后：

- `Tab`：显示命令、参数与路径补全菜单。
- `RightArrow`：接受来自历史记录的预测建议。
- 输入前缀后使用 `UpArrow` / `DownArrow`：只在匹配前缀的历史命令间移动。
- `Ctrl+R`：使用 fzf 模糊搜索全部历史命令。
- `F7`：打开 PSReadLine 原生历史记录列表。

历史记录采用增量保存并保留最多 20,000 条。PowerShell 默认的历史文件路径由 PSReadLine 管理，可通过以下命令查看：

```powershell
(Get-PSReadLineOption).HistorySavePath
```

## 验证

```powershell
Get-Module PSReadLine, PSFzf, posh-git
Get-Command fzf
Get-PSReadLineOption | Select-Object PredictionSource, PredictionViewStyle, HistorySaveStyle, MaximumHistoryCount
```

预期 `PSReadLine` 和 `PSFzf` 已加载，`posh-git` 可用，`fzf` 可被找到，预测来源为 `History`，历史保存方式为 `SaveIncrementally`。在普通目录检查时 `posh-git` 可以尚未加载；进入 Git 仓库后应加载。

在输出被重定向或使用 `-NonInteractive` 的会话中，PSReadLine 不支持渲染预测建议，配置会自动跳过预测功能以保持脚本输出干净；正常交互式终端不受影响。

## 更新与迁移

更新 `PSFzf`：

```powershell
Update-PSResource -Name PSFzf -Scope CurrentUser -TrustRepository
```

更新 `posh-git`：

```powershell
Update-PSResource -Name posh-git -Scope CurrentUser -TrustRepository
```

迁移到另一台 PC 时，克隆或复制本仓库后重新执行安装脚本即可。安装脚本使用 `$PROFILE` 和 `$HOME` 动态确定路径，不依赖特定用户名或盘符。检测到已有 posh-git 懒加载配置时不会重复追加。

要移除本配置，从 Profile 删除 `# >>> homekit-terminal-experience >>>` 与 `# <<< homekit-terminal-experience <<<` 之间的内容，并删除 `$HOME\.config\homekit\powershell\TerminalExperience.ps1`。
