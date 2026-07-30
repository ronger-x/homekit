# posh-git 懒加载配置：仅在首次进入 Git 仓库时导入模块。
# 不要在 PowerShell 启动阶段直接 Import-Module posh-git。

if (Get-Variable -Scope Script -Name HomekitPoshGitConfigured -ValueOnly -ErrorAction SilentlyContinue) {
    return
}

$script:HomekitPoshGitConfigured = $true
$script:PoshGitFallbackPrompt = $function:prompt
$script:PoshGitLoadAttempted = $false

function global:prompt {
    if (-not $script:PoshGitLoadAttempted -and $PWD.Provider.Name -eq 'FileSystem') {
        $directory = $PWD.ProviderPath

        while ($directory) {
            if (Test-Path -LiteralPath (Join-Path $directory '.git')) {
                $script:PoshGitLoadAttempted = $true

                try {
                    # 按位置传入 ForcePoshGitPrompt=true，让模块接管提示符。
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
