# PowerShell 7 + posh-git 安装与低延迟配置

本文档适用于 Windows 上的 PowerShell 7，说明 `posh-git` 的安装、Profile 配置、启动耗时验证、更新、回滚和故障排查。

推荐配置不会在 PowerShell 启动阶段直接导入 `posh-git`，而是在首次进入 Git 仓库时按需加载。这样可以保留 Git 分支提示和补全功能，同时避免每次打开普通终端都承担模块冷加载耗时。

## 适用环境

- Windows 10/11
- PowerShell 7.x
- Git for Windows 2.15 或更高版本
- `posh-git` 1.1.0 或兼容版本

查看当前环境：

```powershell
$PSVersionTable.PSVersion
git --version
```

如果尚未安装 PowerShell 7 或 Git for Windows，可使用 `winget`：

```powershell
winget install --id Microsoft.PowerShell --source winget
winget install --id Git.Git --exact --source winget
```

安装完成后重新打开 PowerShell 7。

## 安装 posh-git

### 推荐方式：PSResourceGet

PowerShell 7 自带或已安装 `Microsoft.PowerShell.PSResourceGet` 时，执行：

```powershell
Get-PSResourceRepository
Install-PSResource -Name posh-git -Version 1.1.0 -Repository PSGallery -Scope CurrentUser -TrustRepository
```

`CurrentUser` 安装不需要管理员权限。`TrustRepository` 仅表示本次命令信任所指定的软件源；执行前应确认 `PSGallery` 地址正确。

### 兼容方式：PowerShellGet

如果系统没有 `Install-PSResource`，使用：

```powershell
Get-PSRepository
Install-Module -Name posh-git -RequiredVersion 1.1.0 -Repository PSGallery -Scope CurrentUser
```

首次使用 `PowerShellGet` 时，PowerShell 可能提示安装 NuGet provider 或确认软件源，按提示完成即可。

上述命令固定安装本机已经验证的 1.1.0。若要安装其他版本，可调整或移除版本参数，但升级后必须重新验证模块参数、提示符接管行为和启动耗时。

### 验证安装

```powershell
Get-Module -ListAvailable posh-git |
    Sort-Object Version -Descending |
    Select-Object -First 1 Name, Version, Path
```

预期能够看到 `posh-git` 的版本和模块清单路径。也应确认 Git 可执行文件能够被发现：

```powershell
Get-Command git
git --version
```

## 准备 PowerShell Profile

Windows Terminal 中的 PowerShell 7 通常加载当前用户、当前宿主的 Profile。不要硬编码用户目录，应始终通过 `$PROFILE` 获取实际路径：

```powershell
$PROFILE.CurrentUserCurrentHost
```

创建 Profile 目录和文件，并在修改已有文件前备份：

```powershell
$profilePath = $PROFILE.CurrentUserCurrentHost
$profileDirectory = Split-Path -Parent $profilePath

New-Item -ItemType Directory -Path $profileDirectory -Force | Out-Null

if (Test-Path -LiteralPath $profilePath) {
    $backupPath = "$profilePath.backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item -LiteralPath $profilePath -Destination $backupPath
    "Profile backup: $backupPath"
}
else {
    New-Item -ItemType File -Path $profilePath -Force | Out-Null
}

notepad $profilePath
```

## 配置方式

### 直接导入方式

最简单的配置是在 Profile 中加入：

```powershell
Import-Module posh-git
```

这种方式会在每次启动 PowerShell 时解析整个模块、执行 `git --version` 并注册提示符与补全。在当前主机上，冷导入约增加 1.3 秒，因此不作为推荐配置。

不要运行 `Add-PoshGitToProfile`。该命令会向 Profile 追加启动期 `Import-Module posh-git`，重新引入冷启动延迟；反复使用还可能产生重复配置。

### 推荐方式：进入 Git 仓库时按需加载

将下面的代码放在 `$PROFILE.CurrentUserCurrentHost` 靠前位置，并删除已有的启动期 `Import-Module posh-git`：

```powershell
# posh-git 冷启动需要较长时间；仅在首次进入 Git 仓库时加载。
$script:PoshGitFallbackPrompt = $function:prompt
$script:PoshGitLoadAttempted = $false

function global:prompt {
    if (-not $script:PoshGitLoadAttempted -and $PWD.Provider.Name -eq 'FileSystem') {
        $directory = $PWD.ProviderPath

        while ($directory) {
            if (Test-Path -LiteralPath (Join-Path $directory '.git')) {
                $script:PoshGitLoadAttempted = $true

                try {
                    # ForcePoshGitPrompt=true，让模块接管当前的延迟加载提示符。
                    Import-Module posh-git -Global -ArgumentList $true -ErrorAction Stop
                    return & (Get-Command prompt -CommandType Function).ScriptBlock
                }
                catch {
                    Write-Warning "posh-git 加载失败：$($_.Exception.Message)"
                    break
                }
            }

            $parent = Split-Path -Parent $directory
            if (-not $parent -or $parent -eq $directory) {
                break
            }

            $directory = $parent
        }
    }

    & $script:PoshGitFallbackPrompt
}
```

这段配置的行为如下：

1. 在普通目录启动 PowerShell 时使用原生提示符，不导入 `posh-git`。
2. 每次显示提示符时向上检查当前目录及其父目录是否存在 `.git` 文件或目录，因此也兼容 Git worktree。
3. 首次进入 Git 仓库时导入 `posh-git`，随后由 `posh-git` 接管当前会话的提示符。
4. 模块加载失败时只尝试一次，并回退到原生提示符，避免每次显示提示符都重复报错。

注意：如果终端的初始目录本身就是 Git 仓库，首次提示符仍会承担一次模块冷加载耗时。希望优先获得快速首屏时，可把 Windows Terminal 的 `startingDirectory` 设置为 `%USERPROFILE%`。

`-ArgumentList $true` 按位置传给 posh-git 的首个模块参数 `ForcePoshGitPrompt`，用于替换上面的延迟加载提示符。`Import-Module -Force` 只表示强制重新加载模块，不具有相同作用；`-ForcePoshGitPrompt` 也不是 `Import-Module` 的命名参数。

导入失败后，本会话不会自动重试。修复 Git、模块路径或 Profile 后，应打开新会话，或手动执行导入命令验证。

## 使配置生效

保存 Profile 后，关闭并重新打开 PowerShell 7。若当前会话已经导入过 `posh-git`，不建议仅运行 `. $PROFILE` 验证，因为现有提示符状态可能影响结果；应使用新会话测试。

先在非 Git 目录验证模块没有提前加载：

```powershell
Set-Location $HOME
Get-Module posh-git
```

预期没有输出。再进入一个 Git 仓库：

```powershell
Set-Location E:\workspace\homekit
prompt | Out-Null
Get-Module posh-git
```

预期能够看到 `posh-git`，后续提示符包含分支和工作区状态。

也可以在独立进程中确认 Profile 本身没有提前导入模块：

```powershell
pwsh -NoLogo -NonInteractive -Command '[bool](Get-Module posh-git)'
```

预期输出 `False`。

检查启动输出：

```powershell
pwsh -NoLogo -NonInteractive -Command '"READY"'
```

正常情况下只输出 `READY`，不再出现类似下面的耗时提示：

```text
Loading personal and system profiles took 1191ms.
```

## 测量启动耗时

下面的命令分别测量不加载 Profile 和正常加载 Profile 的进程启动时间。建议先预热两次，再连续测量至少七次，避免单次结果受磁盘缓存或安全软件扫描影响。

```powershell
$pwsh = (Get-Command pwsh).Source

function Measure-PwshStart {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $samples = 1..7 | ForEach-Object {
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        & $pwsh @Arguments 2>&1 | Out-Null
        $stopwatch.Stop()
        [math]::Round($stopwatch.Elapsed.TotalMilliseconds, 1)
    }

    $sorted = @($samples | Sort-Object)
    [pscustomobject]@{
        Runs     = $samples -join ', '
        MedianMs = $sorted[3]
        MinMs    = $sorted[0]
        MaxMs    = $sorted[-1]
    }
}

Measure-PwshStart -Arguments @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', 'exit 0')
Measure-PwshStart -Arguments @('-NoLogo', '-NonInteractive', '-Command', 'exit 0')
```

如需包含首次提示符渲染，把最后一项命令改为 `prompt | Out-Null`。

## 当前主机验证记录

验证日期：2026-07-20。

- PowerShell：7.6.3
- posh-git：1.1.0
- Git for Windows：2.55.0.windows.2
- Profile：`D:\Users\ronger\Documents\PowerShell\Microsoft.PowerShell_profile.ps1`
- 原 Profile 备份：`D:\Users\ronger\Documents\PowerShell\Microsoft.PowerShell_profile.ps1.backup-20260720-115352`

9 轮测试的中位数：

| 测试项 | 直接启动期导入 | 按 Git 仓库懒加载 |
| --- | ---: | ---: |
| 正常加载 Profile 后退出 | 约 1496 ms | 约 297 ms |
| 加载 Profile 并渲染首次主目录提示符 | 约 2200 ms | 约 448 ms |

`pwsh -NoProfile` 的启动中位数约为 210 ms。以上结果用于比较当前主机上的相对变化，不应视为其他设备的固定性能指标。

## 更新 posh-git

使用 PSResourceGet 安装时：

```powershell
Update-PSResource -Name posh-git -Scope CurrentUser -TrustRepository
```

使用 PowerShellGet 安装时：

```powershell
Update-Module -Name posh-git
```

更新后重新打开 PowerShell，并重新执行安装验证和启动耗时测试。不要在 Profile 中加入自动更新命令，否则每次启动都可能访问网络并增加延迟。

## 回滚配置

列出 Profile 备份：

```powershell
Get-ChildItem -Path "$($PROFILE.CurrentUserCurrentHost).backup-*" |
    Sort-Object LastWriteTime -Descending
```

选择正确的备份后恢复：

```powershell
$backupPath = 'D:\path\to\Microsoft.PowerShell_profile.ps1.backup-yyyyMMdd-HHmmss'
Copy-Item -LiteralPath $backupPath -Destination $PROFILE.CurrentUserCurrentHost -Force
```

恢复后关闭所有 PowerShell 窗口，再打开新会话验证。

## 卸载 posh-git

先从 Profile 中删除延迟加载代码，然后关闭当前 PowerShell 会话。

PSResourceGet：

```powershell
Get-InstalledPSResource -Name posh-git | Uninstall-PSResource
```

PowerShellGet：

```powershell
Uninstall-Module -Name posh-git -AllVersions
```

## 故障排查

### 仍然出现 Profile 加载耗时提示

PowerShell 最多可能加载四个 Profile。检查它们是否存在：

```powershell
@(
    $PROFILE.AllUsersAllHosts
    $PROFILE.AllUsersCurrentHost
    $PROFILE.CurrentUserAllHosts
    $PROFILE.CurrentUserCurrentHost
) | Select-Object -Unique | ForEach-Object {
    [pscustomobject]@{
        Path   = $_
        Exists = Test-Path -LiteralPath $_
    }
}
```

然后在所有存在的文件中检查 `Import-Module`、外部程序调用、网络请求和自动更新命令：

```powershell
$profilePaths = @(
    $PROFILE.AllUsersAllHosts
    $PROFILE.AllUsersCurrentHost
    $PROFILE.CurrentUserAllHosts
    $PROFILE.CurrentUserCurrentHost
) | Select-Object -Unique | Where-Object { Test-Path -LiteralPath $_ }

Select-String -Path $profilePaths -Pattern 'Import-Module|Invoke-WebRequest|curl|winget|Update-'
```

### 进入 Git 仓库后没有显示分支

依次检查：

```powershell
git rev-parse --show-toplevel
Get-Item -Force .git -ErrorAction SilentlyContinue
Get-Module -ListAvailable posh-git
Import-Module posh-git -Global -ArgumentList $true -Force -Verbose
```

如果手动导入成功，检查 Profile 中是否在延迟加载代码之后又定义了其他 `prompt` 函数。

### 与 Oh My Posh 或 Starship 冲突

一个会话应只让一个框架接管 `prompt`。如果使用 Oh My Posh、Starship 或其他完整提示符框架，不要再使用 `ForcePoshGitPrompt=true`；应改用对应框架自带的 Git 状态组件。

### Profile 路径与预期不一致

Documents 目录可能被 OneDrive、组策略或手动设置重定向到其他盘符。以当前会话返回的路径为准：

```powershell
$PROFILE.CurrentUserCurrentHost
```

不要假设 Profile 一定位于 `C:\Users\<用户名>\Documents\PowerShell`。

## 安全注意事项

- 仅从可信 PowerShell 仓库安装模块，并在安装前检查 `Get-PSResourceRepository` 或 `Get-PSRepository` 的地址。
- 不要在 Profile 中硬编码访问令牌、密码或其他凭据。
- 不要在 Profile 中执行自动下载、自动更新或需要管理员权限的命令。
- 修改 Profile 前保留带时间戳的备份，发生语法错误时可用 `pwsh -NoProfile` 启动应急会话并恢复。

## 参考资料

- [posh-git GitHub 仓库](https://github.com/dahlbyk/posh-git)
- [PowerShell Gallery：posh-git 1.1.0](https://www.powershellgallery.com/packages/posh-git/1.1.0)
- [Install-PSResource 文档](https://learn.microsoft.com/powershell/module/microsoft.powershell.psresourceget/install-psresource)
