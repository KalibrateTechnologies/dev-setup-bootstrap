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

function Start-BootstrapTranscript {
    $logDir = Join-Path $env:ProgramData 'dev-setup\logs'
    if (-not (Test-Path $logDir)) {
        New-Item -Path $logDir -ItemType Directory -Force | Out-Null
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $logPath = Join-Path $logDir "bootstrap-$stamp.log"
    Start-Transcript -Path $logPath -Append | Out-Null
    Write-Host "  Transcript: $logPath" -ForegroundColor DarkGray
}

# Build switch-forwarding string. Called at script scope so $PSBoundParameters is the script's.
$switchArgs = ''
foreach ($k in $PSBoundParameters.Keys) {
    if ($PSBoundParameters[$k] -is [switch] -and $PSBoundParameters[$k].IsPresent) {
        $switchArgs += " -$k"
    }
}

function Find-Pwsh7 {
    # Refresh PATH first so a just-installed pwsh is discoverable
    Refresh-Path

    # Try PATH first (covers both MSI and MSIX installs)
    $cmd = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    # Fallback: known MSI install path
    $msi = 'C:\Program Files\PowerShell\7\pwsh.exe'
    if (Test-Path $msi) { return $msi }

    return $null
}

function Refresh-Path {
    $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [System.Environment]::GetEnvironmentVariable('Path', 'User')
}

function Ensure-AppInstallerDirect {
    if (Get-WingetPath) { return }

    $repo = 'microsoft/winget-cli'
    $apiUrl = "https://api.github.com/repos/$repo/releases/latest"
    $headers = @{ 'User-Agent' = 'dev-setup-bootstrap' }
    $release = Invoke-RestMethod -Uri $apiUrl -Headers $headers -ErrorAction Stop

    $bundle = $release.assets |
        Where-Object { $_.name -eq 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle' } |
        Select-Object -First 1

    if (-not $bundle -or -not $bundle.browser_download_url) {
        Write-Host '  FAILED (could not locate the App Installer msixbundle asset)' -ForegroundColor Red
        exit 1
    }

    $bundlePath = Join-Path $env:TEMP $bundle.name

    try {
        Write-Host '  Downloading App Installer...' -NoNewline
        Invoke-WebRequest -Uri $bundle.browser_download_url -OutFile $bundlePath -UseBasicParsing -ErrorAction Stop
        Write-Host ' done' -ForegroundColor Green

        Write-Host '  Installing App Installer...' -NoNewline
        $proc = Start-Process powershell.exe -ArgumentList @(
            '-NoLogo',
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-Command',
            "Add-AppxPackage -Path `"$bundlePath`" -ErrorAction Stop"
        ) -Wait -PassThru -NoNewWindow

        if ($proc.ExitCode -eq 0) {
            Write-Host ' done' -ForegroundColor Green
        }
        else {
            Write-Host " failed (exit code $($proc.ExitCode))" -ForegroundColor Red
            exit $proc.ExitCode
        }
    }
    finally {
        Remove-Item $bundlePath -ErrorAction SilentlyContinue
    }

    Refresh-Path
    if (-not (Get-WingetPath)) {
        Write-Host '  FAILED (winget still not available after App Installer install)' -ForegroundColor Red
        exit 1
    }
}

function Get-WingetPath {
    Refresh-Path

    $cmd = Get-Command winget -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $appInstaller = Get-AppxPackage -Name Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue
    if ($appInstaller -and $appInstaller.InstallLocation) {
        $wingetExe = Join-Path $appInstaller.InstallLocation 'winget.exe'
        if (Test-Path $wingetExe) { return $wingetExe }
    }

    return $null
}

function Invoke-Winget {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $wingetExe = Get-WingetPath
    if (-not $wingetExe) {
        Repair-WinGetPackageManagerBootstrap
        $wingetExe = Get-WingetPath
    }
    if (-not $wingetExe) {
        Write-Host '  FAILED (winget could not be located after Repair-WinGetPackageManager)' -ForegroundColor Red
        Write-Host '  Install App Installer manually, then re-run.' -ForegroundColor Red
        exit 1
    }

    $output = & $wingetExe @Arguments 2>&1
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        $outputText = ($output | Out-String)
        if ($outputText -match '0x8a15000f|Failed when opening source|Data required by the source is missing|No packages were found among the working sources') {
            Write-Host '  Repairing winget via Microsoft.WinGet.Client...' -ForegroundColor DarkGray
            Repair-WinGetPackageManagerBootstrap
            $output = & $wingetExe @Arguments 2>&1
            $exitCode = $LASTEXITCODE
        }
    }

    if ($exitCode -ne 0) {
        $output | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
        exit $exitCode
    }

    return $output
}

function Install-NuGetProvider {
    if (Get-PackageProvider -Name 'NuGet' -ErrorAction SilentlyContinue) {
        return
    }

    Install-PackageProvider -Name 'NuGet' -ForceBootstrap -Force -Confirm:$false -ErrorAction Stop | Out-Null
}

function Install-WinGetClientModule {
    $module = Get-Module -Name 'Microsoft.WinGet.Client' -ListAvailable -ErrorAction SilentlyContinue
    if (-not $module) {
        $gallery = Get-PSRepository -Name 'PSGallery' -ErrorAction SilentlyContinue
        if ($gallery -and $gallery.InstallationPolicy -ne 'Trusted') {
            Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted -ErrorAction Stop
        }

        Install-Module -Name 'Microsoft.WinGet.Client' -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop | Out-Null
    }
}

function Repair-WinGetPackageManagerBootstrap {
    Ensure-AppInstallerDirect
}

function Install-PowerShell7Direct {
    $psVersion = '7.6.4'
    $msiUrl = "https://github.com/PowerShell/PowerShell/releases/download/v$psVersion/PowerShell-$psVersion-win-x64.msi"
    $msiPath = Join-Path $env:TEMP "PowerShell-$psVersion-win-x64.msi"

    try {
        Write-Host "  Downloading PowerShell $psVersion installer..." -NoNewline
        Invoke-WebRequest -Uri $msiUrl -OutFile $msiPath -UseBasicParsing -ErrorAction Stop
        Write-Host ' done' -ForegroundColor Green

        Write-Host '  Installing PowerShell 7...' -NoNewline
        $args = @(
            '/i', "`"$msiPath`"",
            '/qn',
            '/norestart',
            'ADD_EXPLORER_CONTEXT_MENU_OPENPOWERSHELL=1',
            'ENABLE_PSREMOTING=0',
            'REGISTER_MANIFEST=1'
        ) -join ' '
        $proc = Start-Process msiexec.exe -ArgumentList $args -Wait -PassThru -NoNewWindow
        if ($proc.ExitCode -eq 0) {
            Write-Host ' done' -ForegroundColor Green
        }
        else {
            Write-Host " failed (exit code $($proc.ExitCode))" -ForegroundColor Red
            exit $proc.ExitCode
        }
    }
    finally {
        Remove-Item $msiPath -ErrorAction SilentlyContinue
    }
}

function Install-GitDirect {
    $repo = 'git-for-windows/git'
    $apiUrl = "https://api.github.com/repos/$repo/releases/latest"
    $headers = @{ 'User-Agent' = 'dev-setup-bootstrap' }
    $release = Invoke-RestMethod -Uri $apiUrl -Headers $headers -ErrorAction Stop

    $asset = $release.assets |
        Where-Object { $_.name -match '^Git-.*-64-bit\.exe$' } |
        Select-Object -First 1

    if (-not $asset -or -not $asset.browser_download_url) {
        Write-Host '  FAILED (could not locate the Git for Windows installer asset)' -ForegroundColor Red
        exit 1
    }

    $exePath = Join-Path $env:TEMP $asset.name

    try {
        Write-Host "  Downloading Git installer ($($asset.name))..." -NoNewline
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $exePath -UseBasicParsing -ErrorAction Stop
        Write-Host ' done' -ForegroundColor Green

        Write-Host '  Installing git...' -NoNewline
        $proc = Start-Process $exePath -ArgumentList '/VERYSILENT /NORESTART /SUPPRESSMSGBOXES' -Wait -PassThru -NoNewWindow
        if ($proc.ExitCode -eq 0) {
            Write-Host ' done' -ForegroundColor Green
        }
        else {
            Write-Host " failed (exit code $($proc.ExitCode))" -ForegroundColor Red
            exit $proc.ExitCode
        }
    }
    finally {
        Remove-Item $exePath -ErrorAction SilentlyContinue
    }
}

# -- STEP 1: Self-elevate -------------------------------------------------------
# irm|iex runs the script in-memory so $PSCommandPath is empty here.
# Download to a real temp file first so UAC child can reference it with -File.

$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Invoke-WebRequest -Uri $ScriptUrl -UseBasicParsing -OutFile $TmpScript
    # Always use powershell.exe here -- pwsh may not be installed yet on a new machine
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoExit -ExecutionPolicy Bypass -File `"$TmpScript`"$switchArgs"
    return
}

# -- STEP 2: Install PS7 and re-launch in it (still in elevated PS5) ------------

Write-Host ''
Write-Host '  Setting up prerequisites...' -ForegroundColor Cyan
Write-Host ''

Repair-WinGetPackageManagerBootstrap

if ($PSVersionTable.PSVersion.Major -lt 7) {

    $pwsh7 = Find-Pwsh7

    if (-not $pwsh7) {
        Install-PowerShell7Direct
        $pwsh7 = Find-Pwsh7
        if ($pwsh7) {
            Write-Host '  PowerShell 7 installed' -ForegroundColor Green
        } else {
            Write-Host ' FAILED (not found on PATH after install)' -ForegroundColor Red
            Write-Host '  Install PowerShell 7 manually from https://aka.ms/powershell then re-run.' -ForegroundColor Red
            exit 1
        }
    } else {
        Write-Host '  PowerShell 7: already installed' -ForegroundColor DarkGray
    }

    Write-Host '  Re-launching in PowerShell 7...' -ForegroundColor Cyan
    # Already elevated -- child inherits the elevated token, no -Verb RunAs needed.
    # $PSCommandPath is the temp file we're running from (set because we used -File above).
    Start-Process $pwsh7 -ArgumentList "-NoExit -ExecutionPolicy Bypass -File `"$PSCommandPath`"$switchArgs" -Wait
    return
}

# -- STEP 3: Token (now running in PS7 -- normal console, Read-Host works fine) -

Write-Host ''
Write-Host '  Dev environment setup' -ForegroundColor Cyan
Write-Host ''

Start-BootstrapTranscript

Write-Host '  A GitHub access token is needed to clone the setup repo.' -ForegroundColor Cyan
Write-Host '  Opening your browser...' -ForegroundColor Cyan
Start-Process 'https://github.com/settings/tokens/new?scopes=repo&description=Dev+Setup+Bootstrap'
Write-Host ''
Write-Host '  Set an expiry, leave "repo" ticked, click Generate token, copy it.' -ForegroundColor Cyan
$Token = (Read-Host '  Paste token here').Trim()

# -- STEP 4: Install git --------------------------------------------------------

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Install-GitDirect
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
