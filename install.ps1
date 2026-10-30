#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$InstallDir = "$env:LOCALAPPDATA\Programs\decompile",
    [switch]$Uninstall
)

$ErrorActionPreference = "Stop"

$AppName  = "decompile"
$AppExe   = "$AppName.exe"
$Repo     = "eeverestt/decompile"
$Branch   = "main"
$ZipUrl   = "https://github.com/$Repo/archive/refs/heads/$Branch.zip"

function Write-Step([string]$m) { Write-Host "  [*] $m" -ForegroundColor Cyan }
function Write-Ok([string]$m)   { Write-Host "  [+] $m" -ForegroundColor Green }
function Write-Warn([string]$m) { Write-Host "  [!] $m" -ForegroundColor Yellow }
function Write-Err([string]$m)  { Write-Host "  [x] $m" -ForegroundColor Red }

function Test-Command([string]$n) { [bool](Get-Command $n -ErrorAction SilentlyContinue) }

function Get-ProjectFile([string]$root) {
    $all = Get-ChildItem -Path $root -Filter "*.csproj" -Recurse -File -ErrorAction SilentlyContinue
    if (-not $all) { return $null }
    $preferred = $all | Where-Object {
        (Get-Content $_.FullName -Raw) -match "<AssemblyName>\s*decompiler\s*</AssemblyName>"
    } | Select-Object -First 1
    if ($preferred) { return $preferred.FullName }
    return $all[0].FullName
}

function Add-ToUserPath([string]$dir) {
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if (-not $userPath) { $userPath = "" }
    $parts = $userPath -split ';' | Where-Object { $_ }
    if ($parts -contains $dir) { return $false }
    $newPath = if ($userPath.TrimEnd(';')) { "$userPath;$dir" } else { $dir }
    [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
    return $true
}

function Remove-FromUserPath([string]$dir) {
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if (-not $userPath) { return $false }
    $parts = $userPath -split ';' | Where-Object { $_ -and $_ -ne $dir }
    $newPath = $parts -join ';'
    if ($newPath -ne $userPath) {
        [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
        return $true
    }
    return $false
}

if ($Uninstall) {
    Write-Step "Uninstalling $AppName..."
    $target = Join-Path $InstallDir $AppExe
    if (Test-Path $target) {
        Remove-Item $target -Force
        Write-Ok "Removed $target"
    } else {
        Write-Warn "Nothing to remove at $target"
    }
    if (Remove-FromUserPath $InstallDir) {
        Write-Ok "Removed $InstallDir from user PATH"
    }
    return
}

Write-Host ""
Write-Host "  $('-' * 58)"
Write-Host "  decompile installer"
Write-Host "  $('-' * 58)"
Write-Host ""

Write-Step "Checking dependencies..."
if (-not (Test-Command "dotnet")) {
    Write-Err ".NET SDK not found. Install from https://dot.net"
    exit 1
}
Write-Ok ".NET SDK $(& dotnet --version)"

if (Test-Command "java") {
    $previousEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $javaVersion = (& java -version 2>&1 | Select-Object -First 1) -replace '.*version "(.*?)".*','$1'
    $ErrorActionPreference = $previousEAP
    Write-Ok "Java $javaVersion"
} else {
    Write-Warn "java not found on PATH - decompile needs a JRE at runtime"
    Write-Warn "Install from https://adoptium.net/"
}

$tempRoot = Join-Path $env:TEMP ("decompile-install-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
$zipPath = Join-Path $tempRoot "src.zip"

try {
    Write-Step "Downloading $Repo@$Branch..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $ZipUrl -OutFile $zipPath -UseBasicParsing
    Write-Ok "Downloaded"

    Write-Step "Extracting source..."
    $extractDir = Join-Path $tempRoot "src"
    Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force
    $projectFile = Get-ProjectFile $extractDir
    if (-not $projectFile) { throw "No .csproj found in downloaded source" }
    $projectDir = Split-Path -Parent $projectFile
    Write-Ok "Found $([IO.Path]::GetFileName($projectFile))"

    Write-Step "Publishing (Release, single-file, self-contained)..."
    Push-Location $projectDir
    try {
        & dotnet publish `
            -c Release `
            -r win-x64 `
            --self-contained true `
            -p:PublishSingleFile=true `
            -o (Join-Path $projectDir "publish") `
            --nologo `
            -v quiet
        if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed" }
    } finally {
        Pop-Location
    }

    $builtExe = Join-Path $projectDir "publish\decompiler.exe"
    if (-not (Test-Path $builtExe)) { throw "Publish output missing: $builtExe" }

    Write-Step "Installing binary to $InstallDir..."
    if (-not (Test-Path $InstallDir)) {
        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    }
    $target = Join-Path $InstallDir $AppExe
    Copy-Item $builtExe $target -Force
    Write-Ok "Binary installed"

    Write-Step "Configuring PATH..."
    if (Add-ToUserPath $InstallDir) {
        Write-Ok "Added $InstallDir to user PATH (open a new terminal)"
    } else {
        Write-Ok "$InstallDir is already on user PATH"
    }

    if (-not ($env:Path -split ';' -contains $InstallDir)) {
        $env:Path = "$env:Path;$InstallDir"
    }

    Write-Host ""
    Write-Ok "Installed: $target"
    Write-Host ""
    Write-Host "  Try: decompile --help"
    Write-Host ""
}
finally {
    Write-Step "Cleaning up source files..."
    try { Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    Write-Ok "Source removed."
}