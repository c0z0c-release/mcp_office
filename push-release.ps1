<#
.SYNOPSIS
    mcp_office(배포 전용 리파지토리)의 변경 사항을 커밋하고 GitHub 에 push, 릴리스를 만듭니다.

.DESCRIPTION
    release\<버전>\ 폴더 중 가장 최신 버전을 찾아 그 버전을 커밋 메시지와 태그(v<버전>)로 씁니다.
    릴리스에는 설치기 mcp_office.exe 와 서버 exe(mcp_*.exe)를 첨부합니다.
    사용법: .\push-release.ps1 [-Message "메시지"] [-Tag] [-NoRelease] [-DryRun]
    (exe 는 먼저 src\build_installer.ps1 -RebuildServers 로 빌드해 release\<버전>\ 에 놓아야 합니다.)

.PARAMETER Message
    커밋 메시지. 생략하면 최신 버전(예: 0.6.2)을 사용합니다.

.PARAMETER Tag
    v<버전> 태그를 만들어 함께 push 합니다.

.PARAMETER NoRelease
    기본 동작은 push 후 v<버전> 태그로 GitHub Releases 에 릴리스를 만들고 exe 를 첨부하는 것입니다.
    이 옵션을 주면 릴리스 생성을 건너뜁니다. 노트는 README.md '## 버전 히스토리' 의 '### <버전>' 항목에서 가져옵니다. (gh CLI 로그인 필요)

.PARAMETER DryRun
    커밋/push/릴리스 없이 수행할 내용과 릴리스 노트 미리보기만 출력합니다.
#>
[CmdletBinding()]
param(
    [string]$Message,
    [switch]$Tag,
    [switch]$NoRelease,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$releaseRepo = $PSScriptRoot
$artifactDir = Join-Path $releaseRepo 'release'

function Invoke-Git {
    # git 은 진행 상황을 stderr 로 출력하므로 종료 코드로만 실패를 판단한다.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { git -C $releaseRepo @args 2>&1 | ForEach-Object { "$_" } | Write-Host }
    finally { $ErrorActionPreference = $prev }
    if ($LASTEXITCODE -ne 0) {
        throw "git $($args -join ' ') 실패 (exit $LASTEXITCODE)"
    }
}

if (-not (Test-Path (Join-Path $releaseRepo '.git'))) {
    throw "배포 리파지토리를 찾을 수 없습니다: $releaseRepo"
}

# 가장 높은 버전 폴더(release\<버전>)
$latest = Get-ChildItem $artifactDir -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^\d+(\.\d+){1,3}$' } |
    Sort-Object { [version]$_.Name } -Descending |
    Select-Object -First 1
if (-not $latest) {
    throw "배포할 버전 폴더가 없습니다. src\build_installer.ps1 -RebuildServers 를 먼저 실행하세요: $artifactDir"
}
$version = $latest.Name

# 첨부할 파일: 설치기 + 서버 exe. 설치기가 없으면 릴리스를 만들 수 없다.
$installer = Join-Path $latest.FullName 'mcp_office.exe'
if (-not (Test-Path -LiteralPath $installer)) {
    throw "설치기가 없습니다: $installer (src\build_installer.ps1 로 만드세요)"
}
$assets = @(Get-Item -LiteralPath $installer) +
    @(Get-ChildItem $latest.FullName -Directory | ForEach-Object {
        Get-ChildItem $_.FullName -Filter 'mcp_*.exe' -File })

if (-not $Message) { $Message = $version }
$branch = (git -C $releaseRepo rev-parse --abbrev-ref HEAD).Trim()

Write-Host "대상 리파지토리 : $releaseRepo"
Write-Host "브랜치          : $branch"
Write-Host "최신 버전 폴더  : release\$version"
Write-Host "첨부 파일       : $(($assets | ForEach-Object { $_.Name }) -join ', ')"
Write-Host "커밋 메시지     : $Message"

Invoke-Git add -A
$pending = git -C $releaseRepo status --porcelain
if ($pending) {
    Write-Host "`n변경 사항:"
    $pending | ForEach-Object { Write-Host "  $_" }
}
else {
    Write-Host "`n커밋할 변경 사항이 없습니다."
}

# 릴리스 노트: README.md '## 버전 히스토리' 의 '### <버전>' 항목 사용
$tagName = "v$version"
$doRelease = -not $NoRelease
if ($doRelease) {
    $readmePath = Join-Path $releaseRepo 'README.md'
    $readme = if (Test-Path $readmePath) { Get-Content $readmePath -Raw -Encoding UTF8 } else { '' }
    # '## 버전 히스토리' 섹션 안에서만 '### <버전>' 항목을 찾는다. (0.6.1 이 0.6.10 과 섞이지 않도록 제목 끝까지 확인)
    $hist = [regex]::Match($readme, "(?ms)^##\s+버전 히스토리[^\r\n]*\r?\n(.*?)(?=^##\s|\z)")
    $histBody = if ($hist.Success) { $hist.Groups[1].Value } else { '' }
    $m = [regex]::Match($histBody, "(?ms)^###\s+v?$([regex]::Escape($version))(?=[ \t(]|\r?$)[^\r\n]*\r?\n(.*?)(?=^###\s|\z)")
    $changes = if ($m.Success) { $m.Groups[1].Value.Trim() } else { '' }
    if (-not $changes) { $changes = "mcp_office $version 릴리스" }

    $notes = "### What's Changed`n`n$changes`n`n---`n" +
        "> 설치하려면 아래 **Assets** 의 ``mcp_office.exe`` 를 받아 실행하세요. " +
        "서버 exe(``mcp_*.exe``)는 설치기에 모두 들어 있으며 개별 사용을 위해 함께 올립니다. " +
        "``Source code (zip/tar.gz)`` 는 GitHub 이 자동 생성하는 스냅샷이며 실행 파일이 아닙니다."
}

if ($DryRun) {
    if ($doRelease) {
        Write-Host "`n[DryRun] 릴리스 $tagName 노트 미리보기:`n$notes"
    }
    Write-Host "`n[DryRun] 커밋/push/릴리스를 수행하지 않았습니다."
    Invoke-Git reset --quiet
    return
}

if ($pending) {
    Invoke-Git commit -m $Message
}

if ($Tag -or $doRelease) {
    $existing = git -C $releaseRepo tag --list $tagName
    if ($existing) {
        Write-Host "태그 $tagName 이(가) 이미 있어 건너뜁니다."
    }
    else {
        Invoke-Git tag $tagName
    }
}

Invoke-Git push origin $branch
if ($Tag -or $doRelease) { Invoke-Git push origin --tags }

if ($doRelease) {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw "GitHub CLI(gh)가 필요합니다: https://cli.github.com/"
    }
    $repoSlug = ((git -C $releaseRepo remote get-url origin).Trim() -replace '\.git$', '') -replace '^.*github\.com[:/]', ''
    $notesFile = Join-Path ([IO.Path]::GetTempPath()) "mcp_office_notes_$version.md"
    [IO.File]::WriteAllText($notesFile, $notes, (New-Object Text.UTF8Encoding($false)))

    # gh 는 진행 상황/오류를 stderr 로 출력하므로 Stop 모드에서 예외가 되지 않게 종료 코드로만 판단한다.
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        gh release view $tagName --repo $repoSlug 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "릴리스 $tagName 이(가) 이미 있어 건너뜁니다."
        }
        else {
            gh release create $tagName @($assets.FullName) --repo $repoSlug --title $tagName --notes-file $notesFile
            if ($LASTEXITCODE -ne 0) { throw "gh release create 실패 (exit $LASTEXITCODE)" }
        }
    }
    finally {
        $ErrorActionPreference = $prevEap
        Remove-Item $notesFile -ErrorAction SilentlyContinue
    }
}

Write-Host "`n완료: $Message ($branch)"
