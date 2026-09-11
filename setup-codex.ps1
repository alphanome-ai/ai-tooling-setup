<#
.SYNOPSIS
    Configures the Codex CLI for Alphanome's Cloudflare AI Gateway (DeepSeek V4.1-Flash).

.DESCRIPTION
    Installs into %USERPROFILE%\.codex\, from .\config\ (the source of truth):
        config.toml         .\config\config.toml is prepended to the existing
                            file (inside marker comments, so re-runs replace it)
        alp-cf-models.json  copied as-is

    Checks for the Codex CLI and cloudflared first. cloudflared is installed
    automatically when possible; if anything is missing the script explains how
    to install it and stops without writing config.

.PARAMETER SkipPrereqChecks
    Write the config even if codex and/or cloudflared are missing. Useful when
    provisioning an image where the tools get installed later.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File setup-codex.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File setup-codex.ps1 -SkipPrereqChecks
#>
param(
    [switch]$SkipPrereqChecks
)

$ErrorActionPreference = "Stop"

$TargetDir           = Join-Path $HOME ".codex"
$CloudflaredReleases = "https://github.com/cloudflare/cloudflared/releases/latest/download"

# The config and model catalog ship next to this script.
$TomlSrc    = Join-Path $PSScriptRoot "config\config.toml"
$CatalogSrc = Join-Path $PSScriptRoot "config\alp-cf-models.json"
foreach ($f in $TomlSrc, $CatalogSrc) {
    if (-not (Test-Path $f)) {
        [Console]::Error.WriteLine("error: file not found: $f")
        [Console]::Error.WriteLine("error: Run this script from a full checkout of the repository.")
        exit 1
    }
}

# Use [Console]::Error for warnings/errors: Write-Error would become a
# terminating error under $ErrorActionPreference = "Stop".
function Write-Say  { param([string]$Message) Write-Host $Message }
function Write-Warn { param([string]$Message) [Console]::Error.WriteLine("warning: $Message") }
function Write-Err  { param([string]$Message) [Console]::Error.WriteLine("error: $Message") }

function Test-Have {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Get-ToolPath {
    param([string]$Name)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source } else { return $Name }
}

# Writes UTF-8 without a BOM. Set-Content -Encoding UTF8 on Windows PowerShell
# 5.1 prepends a BOM, which TOML and strict JSON parsers can reject.
function Write-Utf8NoBom {
    param([string]$Path, [string]$Content)
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Install-Cloudflared {
    if (Test-Have winget) {
        Write-Say "Installing cloudflared with winget..."
        winget install --id Cloudflare.cloudflared -e --accept-source-agreements --accept-package-agreements
        if ($LASTEXITCODE -eq 0) { return $true }
    }
    if (Test-Have choco) {
        Write-Say "Installing cloudflared with Chocolatey..."
        choco install cloudflared -y
        if ($LASTEXITCODE -eq 0) { return $true }
    }
    if (Test-Have scoop) {
        Write-Say "Installing cloudflared with Scoop..."
        scoop install cloudflared
        if ($LASTEXITCODE -eq 0) { return $true }
    }
    return $false
}

function Show-CloudflaredInstructions {
    [Console]::Error.WriteLine(@"

Install cloudflared manually, then re-run this script:

  winget        winget install --id Cloudflare.cloudflared -e
  Chocolatey    choco install cloudflared -y
  Scoop         scoop install cloudflared
  Manual        download cloudflared-windows-amd64.exe from
                  https://github.com/cloudflare/cloudflared/releases
                rename it to cloudflared.exe and put its folder on your PATH

Docs: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/
"@)
}

# OpenAI's standalone installer, run in a child process so an `exit` inside it
# cannot end this script. CODEX_NON_INTERACTIVE stops it offering to launch
# Codex before our config is written.
function Install-Codex {
    Write-Say "Codex CLI not found; installing with OpenAI's installer..."
    $env:CODEX_NON_INTERACTIVE = "1"
    & (Get-Process -Id $PID).Path -NoProfile -ExecutionPolicy Bypass -Command "irm https://chatgpt.com/codex/install.ps1 | iex"
    if ($LASTEXITCODE -ne 0) { return $false }
    # The installer updates the user PATH for future sessions; this one needs it now.
    $binDir = if ($env:CODEX_INSTALL_DIR) { $env:CODEX_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA "Programs\OpenAI\Codex\bin" }
    $env:Path = "$binDir;$env:Path"
    return $true
}

$MissingPrereqs = $false

# ---------- prerequisite: Codex CLI ----------
# The config is useless without the client, so report this clearly. Whether to
# stop is decided after both checks have run, so the user sees every problem in
# one pass.
if (Test-Have codex) {
    Write-Say "Found Codex CLI: $(Get-ToolPath codex)"
} elseif ((Install-Codex) -and (Test-Have codex)) {
    Write-Say "Installed Codex CLI: $(Get-ToolPath codex)"
} else {
    Write-Err "Codex CLI not found on your PATH, and automatic installation failed."
    [Console]::Error.WriteLine(@"

Install the Codex CLI, then re-run this script:

  Installer         powershell -ExecutionPolicy ByPass -c "irm https://chatgpt.com/codex/install.ps1 | iex"
  npm (all)         npm install -g @openai/codex

Docs: https://developers.openai.com/codex/cli
"@)
    $MissingPrereqs = $true
}

# ---------- prerequisite: cloudflared ----------
# Required by the auth block in config.toml: it performs the Cloudflare Access
# login that authenticates requests to the gateway.
if (Test-Have cloudflared) {
    Write-Say "Found cloudflared: $(Get-ToolPath cloudflared)"
} else {
    Write-Warn "cloudflared not found (required for gateway authentication)."
    Write-Say "Attempting to install cloudflared..."
    $installed = Install-Cloudflared
    if (Test-Have cloudflared) {
        Write-Say "Installed cloudflared: $(Get-ToolPath cloudflared)"
    } elseif ($installed) {
        # Package managers update PATH for future sessions, not this one.
        Write-Warn "cloudflared was installed, but is not on this session's PATH yet."
        Write-Warn "Open a new terminal and re-run this script."
        $MissingPrereqs = $true
    } else {
        Write-Warn "Automatic installation failed or is not supported on this system."
        Show-CloudflaredInstructions
        $MissingPrereqs = $true
    }
}

if ($MissingPrereqs -and -not $SkipPrereqChecks) {
    Write-Err "Missing prerequisites; config was NOT written."
    Write-Err "Resolve the items above and re-run, or pass -SkipPrereqChecks to write the config anyway."
    exit 1
}

# ---------- write configuration ----------
if (-not (Test-Path $TargetDir)) {
    New-Item -ItemType Directory -Path $TargetDir | Out-Null
}

$ConfigPath = Join-Path $TargetDir "config.toml"
$BeginMark  = "# >>> alphanome codex setup >>>"
$EndMark    = "# <<< alphanome codex setup <<<"

# TOML has no way to close a [table], so keys after a header belong to it.
# Our file is therefore split at its first [table] header: its top-level keys
# go at the very top (before any of the user's tables) and its tables go at
# the very bottom (so they can't capture the user's top-level keys).
# Marked blocks from a previous run are stripped, so re-runs never duplicate keys.
# ponytail: header detection is a line starting with "[", fine while
# config\config.toml has no multi-line arrays at the top level.
$head = [System.Collections.Generic.List[string]]::new()
$tail = [System.Collections.Generic.List[string]]::new()
$inTables = $false
foreach ($line in [System.IO.File]::ReadAllLines($TomlSrc)) {
    if ($line -match '^\[') { $inTables = $true }
    if ($inTables) { $tail.Add($line) } else { $head.Add($line) }
}

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add($BeginMark); $lines.AddRange($head); $lines.Add($EndMark)
if (Test-Path $ConfigPath) {
    Copy-Item -Path $ConfigPath -Destination "$ConfigPath.bak" -Force
    $skip = $false
    foreach ($line in [System.IO.File]::ReadAllLines($ConfigPath)) {
        if ($line -eq $BeginMark) { $skip = $true;  continue }
        if ($line -eq $EndMark)   { $skip = $false; continue }
        if (-not $skip) { $lines.Add($line) }
    }
}
$lines.Add($BeginMark); $lines.AddRange($tail); $lines.Add($EndMark)
Write-Utf8NoBom -Path $ConfigPath -Content (($lines -join "`n") + "`n")

# Copied under its own name, which model_catalog_json in config.toml points at.
Copy-Item -Path $CatalogSrc -Destination $TargetDir -Force

Write-Host "Successfully written configuration files to $TargetDir"
