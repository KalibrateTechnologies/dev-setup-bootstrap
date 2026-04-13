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

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

#region ── Elevate ────────────────────────────────────────────────────────────

$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {

    # Collect token before the UAC prompt — elevated processes cannot accept stdin
    if (-not $Token) {
        Write-Host ''
        Write-Host '  A GitHub access token is needed to clone the setup repo.' -ForegroundColor Cyan
        Write-Host '  Opening your browser to create one now...' -ForegroundColor Cyan
        Start-Process 'https://github.com/settings/tokens/new?scopes=repo&description=Dev+Setup+Bootstrap'
        Write-Host ''
        Write-Host '  In the browser: set an expiry, leave "repo" ticked, click Generate token, copy it.' -ForegroundColor Cyan
        $Token = (Read-Host '  Paste token here').Trim()
    }

    # Save this script to a temp file so the elevated process has a real file path
    $tmp = "$env:TEMP\dev-setup-bootstrap.ps1"
    $MyInvocation.MyCommand.ScriptBlock | Set-Content $tmp -Encoding UTF8

    $psExe   = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }
    $argList = "-ExecutionPolicy Bypass -File `"$tmp`" -Token `"$Token`""
    $PSBoundParameters.GetEnumerator() |
        Where-Object { $_.Key -ne 'Token' -and $_.Value -is [switch] -and $_.Value.IsPresent } |
        ForEach-Object { $argList += " -$($_.Key)" }

    Start-Process $psExe -Verb RunAs -ArgumentList $argList
    exit
}

#endregion

Write-Host ''
Write-Host '  ══════════════════════════════════════════' -ForegroundColor Cyan
Write-Host '    Dev environment setup                    ' -ForegroundColor Cyan
Write-Host '  ══════════════════════════════════════════' -ForegroundColor Cyan
Write-Host ''

#region ── Token (elevated path — prompt if not forwarded from pre-UAC step) ──

if (-not $Token) {
    Write-Host '  A GitHub access token is needed to clone the setup repo.' -ForegroundColor Cyan
    Write-Host '  Opening your browser to create one now...' -ForegroundColor Cyan
    Start-Process 'https://github.com/settings/tokens/new?scopes=repo&description=Dev+Setup+Bootstrap'
    Write-Host ''
    Write-Host '  In the browser: set an expiry, leave "repo" ticked, click Generate token, copy it.' -ForegroundColor Cyan
    $Token = (Read-Host '  Paste token here').Trim()
}

#endregion

#region ── Install git ────────────────────────────────────────────────────────

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host '  Installing git...' -NoNewline
    winget install --id Git.Git --silent --accept-package-agreements --accept-source-agreements | Out-Null
    $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [System.Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Host ' FAILED' -ForegroundColor Red
        Write-Host '  Install git from https://git-scm.com and re-run.' -ForegroundColor Red
        exit 1
    }
    Write-Host ' done' -ForegroundColor Green
} else {
    Write-Host '  git already installed' -ForegroundColor DarkGray
}

#endregion

#region ── Clone ──────────────────────────────────────────────────────────────

$repoPath = 'C:\dev-setup'
$cleanUrl = 'https://github.com/KalibrateTechnologies/dev-setup.git'
$authUrl  = "https://oauth2:$Token@github.com/KalibrateTechnologies/dev-setup.git"

if (Test-Path (Join-Path $repoPath '.git')) {
    Write-Host '  Repo already cloned — pulling latest...' -NoNewline
    git -C $repoPath pull --quiet 2>&1 | Out-Null
    Write-Host ' done' -ForegroundColor Green
} else {
    Write-Host '  Cloning setup repo...' -NoNewline
    git clone --quiet $authUrl $repoPath 2>&1 | Out-Null
    # Immediately replace the auth URL so the token is never stored in .git/config
    git -C $repoPath remote set-url origin $cleanUrl
    Write-Host ' done' -ForegroundColor Green
}

#endregion

#region ── Run setup ──────────────────────────────────────────────────────────

Set-ExecutionPolicy Bypass -Scope Process -Force

$setupArgs = @{}
foreach ($k in $PSBoundParameters.Keys) {
    if ($k -ne 'Token') { $setupArgs[$k] = $PSBoundParameters[$k] }
}

& (Join-Path $repoPath 'setup.ps1') @setupArgs

#endregion
