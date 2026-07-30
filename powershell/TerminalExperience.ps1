# PowerShell 7 的命令补全与历史记录配置。
# 该文件由 Install-TerminalExperience.ps1 部署并由 Profile 点加载。

if (-not (Get-Module PSReadLine)) {
    Import-Module PSReadLine -ErrorAction Stop
}

Set-PSReadLineOption -HistorySaveStyle SaveIncrementally
Set-PSReadLineOption -MaximumHistoryCount 20000
Set-PSReadLineOption -HistorySearchCursorMovesToEnd

# 在重定向或非交互会话中，PowerShell 不支持预测渲染；跳过即可避免污染脚本输出。
if (-not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected -and $Host.UI.SupportsVirtualTerminal) {
    try {
        Set-PSReadLineOption -PredictionSource History -ErrorAction Stop
        Set-PSReadLineOption -PredictionViewStyle ListView -ErrorAction Stop
    }
    catch {
        # 某些嵌入式终端错误报告了虚拟终端支持；保留其余补全和历史功能。
    }
}

# Tab 显示可选择的补全列表；方向键只检索当前输入前缀的历史命令。
Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete
Set-PSReadLineKeyHandler -Key UpArrow -Function HistorySearchBackward
Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward

if (Get-Command fzf -ErrorAction SilentlyContinue) {
    try {
        Import-Module PSFzf -ErrorAction Stop
        Set-PsFzfOption -PSReadlineChordReverseHistory 'Ctrl+r'
    }
    catch {
        Write-Warning "无法启用 PSFzf：$($_.Exception.Message)"
    }
}
else {
    Write-Warning '未找到 fzf；Ctrl+R 模糊历史搜索不可用。运行 Install-TerminalExperience.ps1 可自动安装。'
}
