[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ProfilePath = $PROFILE.CurrentUserCurrentHost,
    [switch]$SkipFzfInstall,
    [switch]$SkipModuleInstall,
    [switch]$SkipPoshGitInstall,
    [string]$PoshGitVersion
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$managedBlockStart = '# >>> homekit-terminal-experience >>>'
$managedBlockEnd = '# <<< homekit-terminal-experience <<<'
$sourceConfiguration = Join-Path $PSScriptRoot 'TerminalExperience.ps1'
$poshGitConfiguration = Join-Path $PSScriptRoot 'PoshGitLazyLoad.ps1'
$configurationDirectory = Join-Path $HOME '.config\homekit\powershell'
$installedConfiguration = Join-Path $configurationDirectory 'TerminalExperience.ps1'
$installedPoshGitConfiguration = Join-Path $configurationDirectory 'PoshGitLazyLoad.ps1'
$script:ProfileWasCreated = $false
$script:ProfileBackedUp = $false

function Write-Status {
    param([string]$Message)

    Write-Host "[homekit] $Message" -ForegroundColor Cyan
}

function Backup-Profile {
    param([string]$Path)

    if (-not $script:ProfileWasCreated -and -not $script:ProfileBackedUp -and (Test-Path -LiteralPath $Path)) {
        $backupPath = "$Path.backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item -LiteralPath $Path -Destination $backupPath
        $script:ProfileBackedUp = $true
        Write-Status "已备份 Profile：$backupPath"
    }
}

if (-not (Test-Path -LiteralPath $sourceConfiguration -PathType Leaf)) {
    throw "找不到配置模板：$sourceConfiguration"
}
if (-not (Test-Path -LiteralPath $poshGitConfiguration -PathType Leaf)) {
    throw "找不到 posh-git 配置模板：$poshGitConfiguration"
}

if (-not $SkipModuleInstall) {
    if (-not (Get-Command Install-PSResource -ErrorAction SilentlyContinue)) {
        throw '未找到 Install-PSResource。请先安装 Microsoft.PowerShell.PSResourceGet。'
    }

    $psFzf = Get-InstalledPSResource -Name PSFzf -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending |
        Select-Object -First 1

    if ($psFzf) {
        Write-Status "PSFzf 已安装：$($psFzf.Version)"
    }
    elseif ($PSCmdlet.ShouldProcess('PSGallery', '安装 PSFzf')) {
        Install-PSResource -Name PSFzf -Repository PSGallery -Scope CurrentUser -TrustRepository
        Write-Status '已安装 PSFzf。'
    }
}

if (-not $SkipPoshGitInstall) {
    if (-not (Get-Command Install-PSResource -ErrorAction SilentlyContinue)) {
        throw '未找到 Install-PSResource。请先安装 Microsoft.PowerShell.PSResourceGet。'
    }

    $poshGit = Get-InstalledPSResource -Name posh-git -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending |
        Select-Object -First 1

    if ($poshGit) {
        Write-Status "posh-git 已安装：$($poshGit.Version)"
    }
    elseif ($PSCmdlet.ShouldProcess('PSGallery', '安装 posh-git')) {
        $poshGitInstallParameters = @{
            Name            = 'posh-git'
            Repository      = 'PSGallery'
            Scope           = 'CurrentUser'
            TrustRepository = $true
        }
        if ($PoshGitVersion) {
            $poshGitInstallParameters.Version = $PoshGitVersion
        }

        Install-PSResource @poshGitInstallParameters
        $versionLabel = if ($PoshGitVersion) { $PoshGitVersion } else { '最新版' }
        Write-Status "已安装 posh-git：$versionLabel"
    }
}

if (-not $SkipFzfInstall -and -not (Get-Command fzf -ErrorAction SilentlyContinue)) {
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        throw '未找到 fzf，且 winget 不可用。请先安装 fzf，或使用 -SkipFzfInstall 跳过。'
    }

    if ($PSCmdlet.ShouldProcess('winget', '安装 junegunn.fzf')) {
        & $winget.Source install --id junegunn.fzf --exact --source winget --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -ne 0) {
            throw "winget 安装 fzf 失败，退出代码：$LASTEXITCODE"
        }
        Write-Status '已通过 winget 安装 fzf。请重新打开 PowerShell 后再使用 Ctrl+R。'
    }
}

if (-not (Test-Path -LiteralPath $configurationDirectory)) {
    if ($PSCmdlet.ShouldProcess($configurationDirectory, '创建配置目录')) {
        New-Item -ItemType Directory -Path $configurationDirectory -Force | Out-Null
    }
}

if ($PSCmdlet.ShouldProcess($installedConfiguration, '部署终端配置')) {
    Copy-Item -LiteralPath $sourceConfiguration -Destination $installedConfiguration -Force
    Write-Status "已部署配置：$installedConfiguration"
}
if ($PSCmdlet.ShouldProcess($installedPoshGitConfiguration, '部署 posh-git 懒加载配置')) {
    Copy-Item -LiteralPath $poshGitConfiguration -Destination $installedPoshGitConfiguration -Force
    Write-Status "已部署配置：$installedPoshGitConfiguration"
}

$profileDirectory = Split-Path -Parent $ProfilePath
if (-not (Test-Path -LiteralPath $profileDirectory)) {
    if ($PSCmdlet.ShouldProcess($profileDirectory, '创建 Profile 目录')) {
        New-Item -ItemType Directory -Path $profileDirectory -Force | Out-Null
    }
}

if (-not (Test-Path -LiteralPath $ProfilePath)) {
    if ($PSCmdlet.ShouldProcess($ProfilePath, '创建 Profile')) {
        New-Item -ItemType File -Path $ProfilePath -Force | Out-Null
        $script:ProfileWasCreated = $true
    }
}

if (Test-Path -LiteralPath $ProfilePath) {
    $profileContent = Get-Content -LiteralPath $ProfilePath -Raw
    if ($null -eq $profileContent) {
        $profileContent = ''
    }
}
else {
    $profileContent = [string]::Empty
}
$managedBlockPattern = "(?ms)^$([regex]::Escape($managedBlockStart)).*?^$([regex]::Escape($managedBlockEnd))\s*"
$managedBlock = @"
$managedBlockStart
# 由 homekit/powershell/Install-TerminalExperience.ps1 管理。
`$terminalExperiencePath = Join-Path `$HOME '.config\homekit\powershell\TerminalExperience.ps1'
if (Test-Path -LiteralPath `$terminalExperiencePath) {
    . `$terminalExperiencePath
}
$managedBlockEnd
"@

$newProfileContent = if ($profileContent -match $managedBlockPattern) {
    if ($Matches[0].Trim() -ceq $managedBlock.Trim()) {
        $profileContent
    }
    else {
        [regex]::Replace($profileContent, $managedBlockPattern, "$managedBlock`r`n")
    }
}
else {
    $separator = if ($profileContent.Length -gt 0 -and -not $profileContent.EndsWith("`n")) { "`r`n" } else { '' }
    "$profileContent$separator`r`n$managedBlock`r`n"
}

if ($newProfileContent -cne $profileContent) {
    if ($PSCmdlet.ShouldProcess($ProfilePath, '写入受管 Profile 配置')) {
        Backup-Profile -Path $ProfilePath
        Set-Content -LiteralPath $ProfilePath -Value $newProfileContent -Encoding utf8NoBOM
        Write-Status "已更新 Profile：$ProfilePath"
    }
}
else {
    Write-Status 'Profile 已包含当前受管配置。'
}

$poshGitMarkerStart = '# >>> homekit-posh-git-lazy-load >>>'
$poshGitMarkerEnd = '# <<< homekit-posh-git-lazy-load <<<'
$poshGitBlockPattern = "(?ms)^$([regex]::Escape($poshGitMarkerStart)).*?^$([regex]::Escape($poshGitMarkerEnd))\s*"
$poshGitBlock = @"
$poshGitMarkerStart
# 由 homekit/powershell/Install-TerminalExperience.ps1 管理。
`$poshGitConfigurationPath = Join-Path `$HOME '.config\homekit\powershell\PoshGitLazyLoad.ps1'
if (Test-Path -LiteralPath `$poshGitConfigurationPath) {
    . `$poshGitConfigurationPath
}
$poshGitMarkerEnd
"@
if (Test-Path -LiteralPath $ProfilePath) {
    $profileContent = Get-Content -LiteralPath $ProfilePath -Raw
    if ($null -eq $profileContent) {
        $profileContent = ''
    }
}
else {
    $profileContent = [string]::Empty
}
$hasExistingPoshGitLazyLoad = Select-String -LiteralPath $ProfilePath -Pattern 'PoshGitLoadAttempted|Import-Module posh-git.*ArgumentList' -Quiet -ErrorAction SilentlyContinue

if ($profileContent -match $poshGitBlockPattern) {
    if ($Matches[0].Trim() -cne $poshGitBlock.Trim() -and $PSCmdlet.ShouldProcess($ProfilePath, '更新 posh-git 懒加载配置')) {
        Backup-Profile -Path $ProfilePath
        $updatedProfileContent = [regex]::Replace($profileContent, $poshGitBlockPattern, "$poshGitBlock`r`n")
        Set-Content -LiteralPath $ProfilePath -Value $updatedProfileContent -Encoding utf8NoBOM
        Write-Status "已更新 Profile：$ProfilePath（posh-git 懒加载）"
    }
}
elseif ($hasExistingPoshGitLazyLoad) {
    Write-Status '检测到已有 posh-git 懒加载配置，未重复写入。'
}
elseif ($PSCmdlet.ShouldProcess($ProfilePath, '写入 posh-git 懒加载配置')) {
    Backup-Profile -Path $ProfilePath
    Add-Content -LiteralPath $ProfilePath -Value "`r`n$poshGitBlock`r`n" -Encoding utf8NoBOM
    Write-Status "已更新 Profile：$ProfilePath（posh-git 懒加载）"
}

Write-Host ''
Write-Host '完成。请新开一个 PowerShell 7 窗口验证：' -ForegroundColor Green
Write-Host '  Get-Module PSReadLine, PSFzf, posh-git'
Write-Host '  Ctrl+R  搜索历史命令'
