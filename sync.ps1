# sync.ps1 -- copy pirasea.lua from Wave Workspace to repo, commit, push.
# Usage: pwsh -File sync.ps1 [optional commit message]
param([string]$Msg = "Update pirasea")

$src  = 'C:\Users\jayde\AppData\Local\Wave\Workspace\pirasea.lua'
$xeno = 'C:\Users\jayde\AppData\Local\Xeno\workspace\pirasea.lua'
$repo = 'C:\Users\jayde\pirasea-hub'

if (-not (Test-Path $src)) { Write-Error "source not found: $src"; exit 1 }

# em-dash strip for Xeno (Xeno's loadstring chokes on U+2014)
$t = [System.IO.File]::ReadAllText($src)
$t = $t -replace [char]0x2014, ' - '

# 1) mirror to Xeno (with em-dash strip)
[System.IO.File]::WriteAllText($xeno, $t, (New-Object System.Text.UTF8Encoding $false))

# 2) copy raw original to repo
Copy-Item $src "$repo\pirasea.lua" -Force

# 3) commit + push if anything changed
Set-Location $repo
$status = git status --porcelain
if (-not $status) {
    Write-Host "[sync] no changes -- skipping commit"
    exit 0
}

git add -A
git commit -m "$Msg" | Out-Null
$pushOut = git push 2>&1
Write-Host "[sync] pushed: $(Get-Item "$repo\pirasea.lua").Length bytes"
Write-Host $pushOut
