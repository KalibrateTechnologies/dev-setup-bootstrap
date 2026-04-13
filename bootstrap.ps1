param(
    [string]$Token        = '',
    [switch]$SkipPackages,
    [switch]$SkipNetFx,
    [switch]$SkipDotNetWorkloads,
    [switch]$SkipDotNetTools,
    [switch]$SkipAzureExtensions,
    [switch]$SkipVSCodeExtensions,
    [switch]$SkipNpmGlobals,
    [switch]$SkipAzureAuth,
    [switch]$IncludeVS
)
# !! PS5.1 COMPATIBLE !! -- no ?., no &&/||, no ternary ?:
# This script runs on a stock Windows 11 machine where only PS5.1 is installed.
# It installs PS7 and re-launches itself in pwsh before calling setup.ps1.

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ScriptUrl = 'https://raw.githubusercontent.com/KalibrateTechnologies/dev-setup-bootstrap/main/bootstrap.ps1'
$TmpScript = "$env:TEMP\dev-setup-bootstrap.ps1"
$Pwsh7Path = 'C:\Program Files\PowerShell\7\pwsh.exe'

function Build-ArgList {
    $out = ''
    if ($Token) { $out += " -Token `"$Token`"" }
    foreach ($k in $PSBoundParameters.Keys) {
        if ($k -ne 'Token' -and $PSBoundParameters[$k] -is [switch] -and $PSBoundParameters[$k].IsPresent) {
            $out += " -$k"
        }
    }
    return $out
}

function Download-Bootstrap {
    Invoke-WebRequest -Uri $ScriptUrl -UseBasicParsing -OutFile $TmpScript
}

# STEP 1: Self-elevate
# Run unelevated (normal PS window) -- script self-elevates via UAC.
# Token is collected before UAC because the elevated child cannot use stdin.

$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {

    if (-not $Token) {
        Write-Host ''
        Write-Host '  A GitHub access token is needed to clone the setup repo.' -ForegroundColor Cyan
        Write-Host '  Opening your browser...' -ForegroundColor Cyan
        Start-Process 'https://github.com/settings/tokens/new?scopes=repo&description=Dev+Setup+Bootstrap'
        Write-Host ''
        Write-Host '  Set an expiry, leave "repo" ticked, click Generate token, copy it.' -ForegroundColor Cyan
        $Token = (Read-Host '  Paste token here').Trim()
    }

    Download-Bootstrap
    # Always use powershell.exe here -- pwsh may not be installed yet on a new machine
    $argList = "-ExecutionPolicy Bypass -File `"$TmpScript`"$(Build-ArgList)"
    Start-Process powershell.exe -Verb RunAs -ArgumentList $argList
    exit
}

# STEP 2: Token (elevated -- prompt if not forwarded from step 1)

Write-Host ''
Write-Host '  Dev environment setup' -ForegroundColor Cyan
Write-Host ''

if (-not $Token) {
    Write-Host '  A GitHub access token is needed to clone the setup repo.' -ForegroundColor Cyan
    Write-Host '  Opening your browser...' -ForegroundColor Cyan
    Start-Process 'https://github.com/settings/tokens/new?scopes=repo&description=Dev+Setup+Bootstrap'
    Write-Host ''
    Write-Host '  Set an expiry, leave "repo" ticked, click Generate token, copy it.' -ForegroundColor Cyan
    $Token = (Read-Host '  Paste token here').Trim()
}

# STEP 3: Install git

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host '  Installing git...' -NoNewline
    winget install --id Git.Git --silent --accept-package-agreements --accept-source-agreements | Out-Null
    $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [System.Environment]::GetEnvironmentVariable('Path', 'User')
    if (Get-Command git -ErrorAction SilentlyContinue) {
        Write-Host ' done' -ForegroundColor Green
    } else {
        Write-Host ' FAILED' -ForegroundColor Red
        Write-Host '  Install git manually from https://git-scm.com then re-run.' -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host '  git: already installed' -ForegroundColor DarkGray
}

# STEP 4: Install PS7 and re-launch in it
# setup.ps1 requires PS7. On a stock Win11 machine only PS5.1 exists.
# We install PS7 here, then re-launch this script in pwsh so setup.ps1 gets PS7.
# NOTE: no ?. operator -- use Test-Path on the known default install path.

if ($PSVersionTable.PSVersion.Major -lt 7) {

    if (-not (Test-Path $Pwsh7Path)) {
        Write-Host '  Installing PowerShell 7...' -NoNewline
        winget install --id Microsoft.PowerShell --silent --accept-package-agreements --accept-source-agreements | Out-Null
        $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                    [System.Environment]::GetEnvironmentVariable('Path', 'User')
        if (Test-Path $Pwsh7Path) {
            Write-Host ' done' -ForegroundColor Green
        } else {
            Write-Host ' WARNING: pwsh not found at expected path, continuing in PS5' -ForegroundColor Yellow
        }
    } else {
        Write-Host '  PowerShell 7: already installed' -ForegroundColor DarkGray
    }

    if (Test-Path $Pwsh7Path) {
        Write-Host '  Re-launching in PowerShell 7...' -ForegroundColor Cyan
        Download-Bootstrap
        $argList = "-ExecutionPolicy Bypass -File `"$TmpScript`"$(Build-ArgList)"
        Start-Process $Pwsh7Path -Verb RunAs -ArgumentList $argList -Wait
        exit
    }
}

# STEP 5: Clone

$repoPath = 'C:\dev-setup'
$cleanUrl = 'https://github.com/KalibrateTechnologies/dev-setup.git'
$authUrl  = "https://oauth2:$Token@github.com/KalibrateTechnologies/dev-setup.git"

if (Test-Path (Join-Path $repoPath '.git')) {
    Write-Host '  Repo already cloned - pulling latest...' -NoNewline
    git -C $repoPath pull --quiet 2>&1 | Out-Null
    Write-Host ' done' -ForegroundColor Green
} else {
    Write-Host '  Cloning setup repo...' -NoNewline
    git clone --quiet $authUrl $repoPath 2>&1 | Out-Null
    git -C $repoPath remote set-url origin $cleanUrl
    Write-Host ' done' -ForegroundColor Green
}

# STEP 6: Run setup

Set-ExecutionPolicy Bypass -Scope Process -Force

$setupArgs = @{}
foreach ($k in $PSBoundParameters.Keys) {
    if ($k -ne 'Token') { $setupArgs[$k] = $PSBoundParameters[$k] }
}

& (Join-Path $repoPath 'setup.ps1') @setupArgs
