param(
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
# Flow:
#   1. Unelevated PS5 (irm|iex)  -> download to temp file, UAC elevate
#   2. Elevated PS5               -> install PS7, re-launch in pwsh
#   3. Elevated PS7               -> prompt for token, install git, clone, run setup.ps1
#
# Token is NOT collected until step 3 -- no need to forward it across re-launches.

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ScriptUrl = 'https://raw.githubusercontent.com/KalibrateTechnologies/dev-setup-bootstrap/main/bootstrap.ps1'
$TmpScript = "$env:TEMP\dev-setup-bootstrap.ps1"
$Pwsh7Path = 'C:\Program Files\PowerShell\7\pwsh.exe'

# Build switch-forwarding string. Called at script scope so $PSBoundParameters is the script's.
$switchArgs = ''
foreach ($k in $PSBoundParameters.Keys) {
    if ($PSBoundParameters[$k] -is [switch] -and $PSBoundParameters[$k].IsPresent) {
        $switchArgs += " -$k"
    }
}

# -- STEP 1: Self-elevate -------------------------------------------------------
# irm|iex runs the script in-memory so $PSCommandPath is empty here.
# Download to a real temp file first so UAC child can reference it with -File.

$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Invoke-WebRequest -Uri $ScriptUrl -UseBasicParsing -OutFile $TmpScript
    # Always use powershell.exe here -- pwsh may not be installed yet on a new machine
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-ExecutionPolicy Bypass -File `"$TmpScript`"$switchArgs"
    exit
}

# -- STEP 2: Install PS7 and re-launch in it (still in elevated PS5) ------------

Write-Host ''
Write-Host '  Setting up prerequisites...' -ForegroundColor Cyan
Write-Host ''

if ($PSVersionTable.PSVersion.Major -lt 7) {

    if (-not (Test-Path $Pwsh7Path)) {
        Write-Host '  Installing PowerShell 7...' -NoNewline
        winget install --id Microsoft.PowerShell --silent --accept-package-agreements --accept-source-agreements | Out-Null
        if (Test-Path $Pwsh7Path) {
            Write-Host ' done' -ForegroundColor Green
        } else {
            Write-Host ' not found at expected path after install' -ForegroundColor Yellow
        }
    } else {
        Write-Host '  PowerShell 7: already installed' -ForegroundColor DarkGray
    }

    if (Test-Path $Pwsh7Path) {
        Write-Host '  Re-launching in PowerShell 7...' -ForegroundColor Cyan
        # Already elevated -- child inherits the elevated token, no -Verb RunAs needed.
        # $PSCommandPath is the temp file we're running from (set because we used -File above).
        Start-Process $Pwsh7Path -ArgumentList "-ExecutionPolicy Bypass -File `"$PSCommandPath`"$switchArgs" -Wait
        exit
    }

    Write-Host ''
    Write-Host '  WARNING: Could not install PowerShell 7. setup.ps1 requires PS7.' -ForegroundColor Yellow
    Write-Host '  Continuing in PS5 -- errors are likely.' -ForegroundColor Yellow
}

# -- STEP 3: Token (now running in PS7 -- normal console, Read-Host works fine) -

Write-Host ''
Write-Host '  Dev environment setup' -ForegroundColor Cyan
Write-Host ''

Write-Host '  A GitHub access token is needed to clone the setup repo.' -ForegroundColor Cyan
Write-Host '  Opening your browser...' -ForegroundColor Cyan
Start-Process 'https://github.com/settings/tokens/new?scopes=repo&description=Dev+Setup+Bootstrap'
Write-Host ''
Write-Host '  Set an expiry, leave "repo" ticked, click Generate token, copy it.' -ForegroundColor Cyan
$Token = (Read-Host '  Paste token here').Trim()

# -- STEP 4: Install git --------------------------------------------------------

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

# -- STEP 5: Clone --------------------------------------------------------------

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

# -- STEP 6: Run setup ----------------------------------------------------------

Set-ExecutionPolicy Bypass -Scope Process -Force

$setupArgs = @{}
foreach ($k in $PSBoundParameters.Keys) {
    $setupArgs[$k] = $PSBoundParameters[$k]
}

& (Join-Path $repoPath 'setup.ps1') @setupArgs
