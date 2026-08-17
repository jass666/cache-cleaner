# ============================================================
#  cache-cleaner - Push to GitHub (Local Wins)
#  WARNING: Overwrites remote branch with local state.
# ============================================================

param(
    [switch]$AutoYes
)

$REPO_PATH  = $PSScriptRoot
$BRANCH     = 'main'
$REMOTE_URL = 'https://github.com/jass666/cache-cleaner'
$REPO_NAME  = 'cache-cleaner'

function Wait-ForExit {
    if (-not $AutoYes) {
        Read-Host " Press Enter to exit" | Out-Null
    }
}

Write-Host ""
Write-Host " ====================================================="
Write-Host "  $REPO_NAME  |  Force Push to GitHub"
Write-Host " ====================================================="
Write-Host ""
Write-Host " [INFO]  Repo  : $REPO_PATH"
Write-Host " [INFO]  Remote: $REMOTE_URL"
Write-Host " [INFO]  Branch: $BRANCH"
Write-Host ""
Write-Host " [WARN]  Local files will become the GitHub branch state."
Write-Host " [WARN]  This is a force push. Remote-only changes can be overwritten."
Write-Host ""
if ($AutoYes) {
    Write-Host " [INFO]  AutoYes enabled. Starting without prompts."
} else {
    Write-Host " Press ENTER to start, or type anything and press ENTER to abort."
    $confirm = Read-Host " >"
    if ($confirm -ne "") {
        Write-Host ""
        Write-Host " [INFO]  Aborted. Nothing was changed."
        Wait-ForExit
        exit 0
    }
}

Set-Location $REPO_PATH

git rev-parse --is-inside-work-tree 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host " [INFO]  Git repo not initialized. Running git init..."
    git init
    if ($LASTEXITCODE -ne 0) {
        Write-Host " [ERROR] git init failed."
        Wait-ForExit
        exit 1
    }
}

git checkout -B $BRANCH
if ($LASTEXITCODE -ne 0) {
    Write-Host " [ERROR] Could not switch to branch: $BRANCH"
    Wait-ForExit
    exit 1
}

$existingRemote = git remote get-url origin 2>$null
if ($LASTEXITCODE -eq 0) {
    if ($existingRemote -ne $REMOTE_URL) {
        git remote set-url origin $REMOTE_URL
    }
} else {
    git remote add origin $REMOTE_URL
}
if ($LASTEXITCODE -ne 0) {
    Write-Host " [ERROR] Could not configure origin remote."
    Wait-ForExit
    exit 1
}

$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
Set-Content -Path ".deploy_stamp" -Value $timestamp -Encoding UTF8

git add -A
if ($LASTEXITCODE -ne 0) {
    Write-Host " [ERROR] git add failed."
    Wait-ForExit
    exit 1
}

$date = Get-Date -Format "yyyy-MM-dd HH:mm"
$commitMsg = "Push $REPO_NAME $date"
git commit -m $commitMsg
if ($LASTEXITCODE -ne 0) {
    Write-Host " [ERROR] Commit failed."
    Wait-ForExit
    exit 1
}

git push -u origin $BRANCH --force
if ($LASTEXITCODE -ne 0) {
    Write-Host " [ERROR] Force push failed. Check internet, GitHub auth, or branch protection."
    Write-Host " [INFO]  Remote: $REMOTE_URL"
    Wait-ForExit
    exit 1
}

$finalHash = git log -1 --pretty=format:%h
Write-Host ""
Write-Host " [OK]    Push complete: $finalHash"
Write-Host " [OK]    Repo: $REMOTE_URL"
Wait-ForExit
