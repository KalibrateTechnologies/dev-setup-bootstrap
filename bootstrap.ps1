param(
    [switch]$SkipPackages,
    [switch]$SkipNetFx,
    [switch]$SkipDotNetWorkloads,
    [switch]$SkipDotNetTools,
    [switch]$SkipAzureExtensions,
    [switch]$SkipVSCodeExtensions,
    [switch]$SkipNpmGlobals,
    [switch]$SkipAzureAuth,
    [switch]$IncludeVS,
    [switch]$BootstrapAdminPrereqs,
    [switch]$BootstrapRunSetup,
    [string]$RepoPathOverride
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

# Build switch-forwarding string for public switches only.
$switchArgs = ''
$publicSwitches = @(
    'SkipPackages',
    'SkipNetFx',
    'SkipDotNetWorkloads',
    'SkipDotNetTools',
    'SkipAzureExtensions',
    'SkipVSCodeExtensions',
    'SkipNpmGlobals',
    'SkipAzureAuth',
    'IncludeVS'
)
foreach ($k in $publicSwitches) {
    if ($PSBoundParameters.ContainsKey($k) -and ($PSBoundParameters[$k] -is [switch]) -and $PSBoundParameters[$k].IsPresent) {
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

function Ensure-UsableWorkingDirectory {
    try {
        $cwd = (Get-Location).Path
        if ($cwd -and (Test-Path $cwd)) {
            return
        }
    }
    catch {
        # Current directory is invalid; reset below.
    }

    $fallback = if (Test-Path "$env:SystemDrive\") { "$env:SystemDrive\" } else { $env:TEMP }
    Set-Location $fallback
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

function Ensure-GitSafeDirectory {
    param([Parameter(Mandatory = $true)][string]$RepoPath)

    # Current user (covers non-elevated/manual git usage for this identity)
    $globalSafe = git config --global --get-all safe.directory 2>$null
    if (-not ($globalSafe | Where-Object { $_ -eq $RepoPath })) {
        git config --global --add safe.directory $RepoPath 2>$null | Out-Null
    }
}

function Update-RepoWithToken {
    param(
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string]$AuthUrl,
        [Parameter(Mandatory = $true)][string]$CleanUrl
    )

    Ensure-UsableWorkingDirectory
    Ensure-GitSafeDirectory -RepoPath $RepoPath

    # Use token-auth remote for this update to avoid browser/device login prompts,
    # then immediately restore clean origin URL.
    git -C $RepoPath remote set-url origin $AuthUrl 2>&1 | Out-Null
    try {
        git -C $RepoPath pull --quiet 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            return $false
        }
        return $true
    }
    finally {
        git -C $RepoPath remote set-url origin $CleanUrl 2>&1 | Out-Null
    }
}

# -- Flow control ---------------------------------------------------------------
$repoPath = if ($RepoPathOverride) { $RepoPathOverride } else { 'C:\dev-setup' }
$cleanUrl = 'https://github.com/KalibrateTechnologies/dev-setup.git'

# irm|iex runs the script in-memory so $PSCommandPath is empty here.
# Download to a real temp file first so child processes can reference it with -File.
# Always refresh when we're the top-level entrypoint so users pick up latest changes;
# skip re-download only when we ARE the cached copy (re-launched via -File $TmpScript).
if ($PSCommandPath -ne $TmpScript) {
    try {
        Invoke-WebRequest -Uri $ScriptUrl -UseBasicParsing -OutFile $TmpScript -ErrorAction Stop
    }
    catch {
        if (-not (Test-Path $TmpScript)) { throw }
        Write-Host "  Could not refresh bootstrap from $ScriptUrl; using cached copy." -ForegroundColor Yellow
    }
}

if ($BootstrapAdminPrereqs) {
    Write-Host ''
    Write-Host '  Setting up prerequisites...' -ForegroundColor Cyan
    Write-Host ''

    Repair-WinGetPackageManagerBootstrap

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Install-GitDirect
        Refresh-Path
    }

    if (-not (Find-Pwsh7)) {
        Install-PowerShell7Direct
        Refresh-Path
    }

    return
}

if ($BootstrapRunSetup) {
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        $pwsh7 = Find-Pwsh7
        if (-not $pwsh7) {
            Write-Host ' FAILED (PowerShell 7 not found after prerequisite stage)' -ForegroundColor Red
            exit 1
        }

        Write-Host '  Re-launching in PowerShell 7...' -ForegroundColor Cyan
        Start-Process $pwsh7 -ArgumentList "-NoExit -ExecutionPolicy Bypass -File `"$PSCommandPath`" -BootstrapRunSetup -RepoPathOverride `"$repoPath`"$switchArgs" -Wait
        return
    }

    Write-Host ''
    Write-Host '  Dev environment setup' -ForegroundColor Cyan
    Write-Host ''
    Start-BootstrapTranscript

    Set-ExecutionPolicy Bypass -Scope Process -Force
    $setupArgs = @{}
    foreach ($k in $publicSwitches) {
        if ($k -eq 'IncludeVS') { continue }
        if ($PSBoundParameters.ContainsKey($k)) {
            $setupArgs[$k] = $PSBoundParameters[$k]
        }
    }
    # orchestrator.ps1 uses -SkipVS (opt-out); bootstrap exposes -IncludeVS (opt-in).
    # Default = do not install Visual Studio unless caller explicitly opts in.
    if (-not $IncludeVS) { $setupArgs['SkipVS'] = $true }

    & (Join-Path $repoPath 'orchestrator.ps1') @setupArgs
    return
}

$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()

if ($me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host '  This bootstrap is intended to be started from a normal PowerShell window.' -ForegroundColor Yellow
    Write-Host '  Repo clone/pull should happen as the signed-in user so repo ownership stays correct.' -ForegroundColor Yellow
    Write-Host '  Re-run the bootstrap from a non-elevated shell.' -ForegroundColor Yellow
    return
}

if (-not (Get-Command git -ErrorAction SilentlyContinue) -or -not (Find-Pwsh7) -or -not (Get-WingetPath)) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoExit -ExecutionPolicy Bypass -File `"$TmpScript`" -BootstrapAdminPrereqs$switchArgs" -Wait
    Refresh-Path
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host ' FAILED' -ForegroundColor Red
    Write-Host '  git is still not available after prerequisite stage. Install git manually from https://git-scm.com then re-run.' -ForegroundColor Red
    exit 1
}

if (-not (Find-Pwsh7)) {
    Write-Host ' FAILED' -ForegroundColor Red
    Write-Host '  PowerShell 7 is still not available after prerequisite stage. Install it manually from https://aka.ms/powershell then re-run.' -ForegroundColor Red
    exit 1
}

Ensure-UsableWorkingDirectory

Write-Host ''
Write-Host '  Dev environment setup' -ForegroundColor Cyan
Write-Host ''
Write-Host '  A GitHub access token is needed to clone the setup repo and authenticate gh CLI.' -ForegroundColor Cyan
Write-Host '  Opening your browser...' -ForegroundColor Cyan
# Scopes pre-selected in the URL:
#   repo       - clone/pull private repos (required)
#   read:org   - gh CLI needs this to list org repos and check membership
#   read:user  - gh CLI user identity / profile lookups
Start-Process 'https://github.com/settings/tokens/new?scopes=repo,read:org,read:user&description=Dev+Setup+Bootstrap'
Write-Host ''
Write-Host '  All required scopes are pre-ticked (repo, read:org, read:user).' -ForegroundColor Cyan
Write-Host '  Set an expiry, click Generate token, copy it.' -ForegroundColor Cyan
$Token = (Read-Host '  Paste token here').Trim()

$authUrl  = "https://oauth2:$Token@github.com/KalibrateTechnologies/dev-setup.git"
$ghTokenFile = Join-Path $env:ProgramData ("dev-setup\\bootstrap-gh-token-" + [guid]::NewGuid().ToString('N') + '.txt')
if (-not (Test-Path (Split-Path $ghTokenFile -Parent))) {
    New-Item -Path (Split-Path $ghTokenFile -Parent) -ItemType Directory -Force | Out-Null
}
Set-Content -Path $ghTokenFile -Value $Token -Encoding ASCII

if (Test-Path (Join-Path $repoPath '.git')) {
    Write-Host '  Repo already cloned - pulling latest...' -NoNewline
    if (Update-RepoWithToken -RepoPath $repoPath -AuthUrl $authUrl -CleanUrl $cleanUrl) {
        Write-Host ' done' -ForegroundColor Green
    }
    else {
        Write-Host ' FAILED' -ForegroundColor Red
        Write-Host '  Could not pull latest dev-setup repo. Check token access and network, then re-run.' -ForegroundColor Red
        exit 1
    }
}
else {
    Write-Host '  Cloning setup repo...' -NoNewline
    git clone --quiet $authUrl $repoPath 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host ' FAILED' -ForegroundColor Red
        Write-Host '  Could not clone dev-setup repo. Check token access and network, then re-run.' -ForegroundColor Red
        exit 1
    }
    git -C $repoPath remote set-url origin $cleanUrl 2>&1 | Out-Null
    Ensure-GitSafeDirectory -RepoPath $repoPath
    Write-Host ' done' -ForegroundColor Green
}

$pwsh7 = Find-Pwsh7
if (-not $pwsh7) {
    Write-Host ' FAILED' -ForegroundColor Red
    Write-Host '  PowerShell 7 not found to continue setup after repo clone.' -ForegroundColor Red
    exit 1
}

# Invoke orchestrator.ps1 non-elevated. It runs the admin phase (setup.ps1) via
# UAC itself, then the BAU phase (bau-setup.ps1) in-process as the current
# (BAU) user — the correct identity for writing to ~/.gitconfig, ~/.vscode,
# ~/.azure, etc. on split-account machines.
# orchestrator.ps1 exposes -SkipVS (opt-out); bootstrap exposes -IncludeVS
# (opt-in). Translate here to preserve the "don't install VS by default"
# behaviour of the bootstrap.
$orchArgs = @(
    '-NoLogo'
    '-NoProfile'
    '-ExecutionPolicy', 'Bypass'
    '-File', "$repoPath\orchestrator.ps1"
    '-BootstrapGhTokenFile', $ghTokenFile
    '-BauUser', "$env:USERDOMAIN\$env:USERNAME"
)
foreach ($k in $publicSwitches) {
    if ($k -eq 'IncludeVS') { continue }
    if ($PSBoundParameters.ContainsKey($k) -and $PSBoundParameters[$k].IsPresent) {
        $orchArgs += "-$k"
    }
}
if (-not $IncludeVS) { $orchArgs += '-SkipVS' }

# Use Start-Process -NoNewWindow -Wait rather than & so that pwsh7 runs in
# this same console window and blocks the parent. Calling & with a Store-stub
# pwsh.exe (%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe) launches PS7 as a
# detached window and returns immediately, causing the BAU phase to silently
# disappear when that window closes.
Start-Process -FilePath $pwsh7 -ArgumentList $orchArgs -NoNewWindow -Wait
