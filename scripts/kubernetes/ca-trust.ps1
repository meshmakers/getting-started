# Shared helpers for trusting/untrusting the local root CA on the host.
# Dot-sourced by ../om-install.ps1 and ../om-uninstall.ps1.
#
# Where the certificate has to go:
#   * OS trust store - everywhere. On Windows and macOS this is also what Chrome and
#     Firefox read (Firefox imports it by default: security.enterprise_roots.enabled,
#     on since Firefox 68).
#   * NSS databases - Linux only, because browsers there ignore the OS store:
#     ~/.pki/nssdb for Chromium-family browsers, one cert9.db per Firefox profile.
#     update-ca-certificates does not feed these.
#
# Browsers read their stores only at startup, so both scripts end with a warning that
# Chrome and Firefox have to be closed and reopened. Nothing here inspects or stops
# browser processes.

$script:CaCommonName = "OctoMesh Getting Started Root CA"
$script:LinuxCaFileName = "octomesh-getting-started-root-ca.crt"

function Assert-Elevated {
    if (-not $IsWindows) { return }
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { return }
    Write-Host "Administrator rights are required to update the Windows certificate store." -ForegroundColor Red
    Write-Host "Start PowerShell as Administrator ('Run as administrator') and run this script again." -ForegroundColor Yellow
    Write-Host "Alternatively skip the certificate work: -SkipTrustCa on install, -KeepCaTrust on uninstall." -ForegroundColor Yellow
    exit 1
}

function Get-NssCertutil {
    # NSS certutil for the Linux browser stores. Never on Windows: the certutil.exe on
    # PATH there is an unrelated Microsoft tool.
    if ($IsWindows) { return $null }
    $cmd = Get-Command certutil -ErrorAction SilentlyContinue
    if (-not $cmd) { return $null }
    if ((& $cmd.Source -H 2>&1 | Out-String) -notmatch "NSS") { return $null }
    return $cmd.Source
}

function Get-NssDatabasePaths {
    # Chromium-family browsers share ~/.pki/nssdb; Firefox keeps one database per
    # profile (deb/tarball, snap and flatpak locations).
    $dbs = @()
    $chromeDb = Join-Path $HOME ".pki/nssdb"
    if (Test-Path $chromeDb) { $dbs += $chromeDb }
    $roots = @(
        (Join-Path $HOME ".mozilla/firefox"),
        (Join-Path $HOME "snap/firefox/common/.mozilla/firefox"),
        (Join-Path $HOME ".var/app/org.mozilla.firefox/.mozilla/firefox")
    ) | Where-Object { Test-Path $_ }
    foreach ($root in $roots) {
        $dbs += @(Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue |
            Where-Object { (Test-Path (Join-Path $_.FullName "prefs.js")) -or (Test-Path (Join-Path $_.FullName "cert9.db")) } |
            Select-Object -ExpandProperty FullName)
    }
    return @($dbs)
}

function Add-CaToOsStore([string]$CrtPath) {
    if ($IsMacOS) {
        sudo security delete-certificate -c $script:CaCommonName /Library/Keychains/System.keychain 2>$null
        sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain $CrtPath
        if ($LASTEXITCODE -ne 0) { throw "security add-trusted-cert failed." }
    }
    elseif ($IsWindows) {
        # Replaces the CA left over from a previous install - they share the CN, and a
        # stale one would only add trust nothing can use.
        Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.Subject -match [regex]::Escape($script:CaCommonName) } | Remove-Item -ErrorAction SilentlyContinue
        Import-Certificate -FilePath $CrtPath -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
    }
    else {
        sudo cp $CrtPath "/usr/local/share/ca-certificates/$script:LinuxCaFileName"
        if ($LASTEXITCODE -ne 0) { throw "copying the CA to /usr/local/share/ca-certificates failed." }
        sudo update-ca-certificates | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "update-ca-certificates failed." }
    }
    Write-Host "  Trusted in the OS store." -ForegroundColor Green
}

function Remove-CaFromOsStore {
    if ($IsMacOS) {
        # security delete-certificate also exits non-zero when there is nothing to
        # delete, so check first - an already clean keychain is a success.
        security find-certificate -c $script:CaCommonName /Library/Keychains/System.keychain 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { return $true }
        sudo security delete-certificate -c $script:CaCommonName /Library/Keychains/System.keychain 2>$null
        return ($LASTEXITCODE -eq 0)
    }
    if ($IsWindows) {
        try {
            Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.Subject -match [regex]::Escape($script:CaCommonName) } | Remove-Item -ErrorAction Stop
            return $true
        }
        catch { return $false }
    }
    sudo rm -f "/usr/local/share/ca-certificates/$script:LinuxCaFileName"
    if ($LASTEXITCODE -ne 0) { return $false }
    sudo update-ca-certificates | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Add-CaToBrowserStores([string]$CrtPath) {
    if ($IsWindows -or $IsMacOS) { return }
    $dbs = Get-NssDatabasePaths
    if ($dbs.Count -eq 0) { return }

    $certutil = Get-NssCertutil
    if (-not $certutil) {
        Write-Host "  NSS 'certutil' not found - Chrome and Firefox will not trust the CA." -ForegroundColor Yellow
        Write-Host "  Install it (Debian/Ubuntu: sudo apt install libnss3-tools) and re-run ./om-install.ps1." -ForegroundColor Yellow
        return
    }
    foreach ($db in $dbs) {
        & $certutil -D -d "sql:$db" -n $script:CaCommonName 2>$null | Out-Null
        & $certutil -A -d "sql:$db" -t "C,," -n $script:CaCommonName -i $CrtPath 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  Trusted in browser store $db" -ForegroundColor Green
        }
        else {
            Write-Host "  Could not write to browser store $db (non-fatal)." -ForegroundColor Yellow
        }
    }
}

function Remove-CaFromBrowserStores {
    if ($IsWindows -or $IsMacOS) { return }
    $dbs = Get-NssDatabasePaths
    if ($dbs.Count -eq 0) { return }

    $certutil = Get-NssCertutil
    if (-not $certutil) { return }

    $removed = 0
    foreach ($db in $dbs) {
        & $certutil -L -d "sql:$db" -n $script:CaCommonName 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { continue }
        & $certutil -D -d "sql:$db" -n $script:CaCommonName 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { $removed++ }
        else { Write-Host "  Could not remove the CA from browser store $db (non-fatal)." -ForegroundColor Yellow }
    }
    if ($removed -gt 0) {
        Write-Host "  Removed the CA from $removed browser certificate store(s)." -ForegroundColor Green
    }
}

function Write-BrowserRestartWarning([switch]$Removed) {
    Write-Host ""
    Write-Host "WARNING: browsers read certificate stores only when they start." -ForegroundColor Yellow
    if ($Removed) {
        Write-Host "Chrome and Firefox keep trusting the removed CA until you close them completely" -ForegroundColor Yellow
        Write-Host "and open them again." -ForegroundColor Yellow
    }
    else {
        Write-Host "Close Chrome and Firefox completely and open them again - until you do, they" -ForegroundColor Yellow
        Write-Host "will keep reporting the OctoMesh certificates as untrusted." -ForegroundColor Yellow
    }
    Write-Host "Closing every window is not always enough: an installed web app or a" -ForegroundColor Yellow
    Write-Host "background-apps setting can keep the browser process alive." -ForegroundColor Yellow
}
