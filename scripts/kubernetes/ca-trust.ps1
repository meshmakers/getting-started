# Shared helpers for trusting/untrusting the local root CA on the host.
# Dot-sourced by ../om-install.ps1 and ../om-uninstall.ps1.
#
# Trust stores that matter for the getting-started experience:
#   * OS store           - Chrome/Edge/Safari on Windows and macOS, curl/octo-cli everywhere.
#   * NSS (Linux only)   - Chrome/Chromium read ~/.pki/nssdb, Firefox reads per-profile cert9.db.
#                          update-ca-certificates does NOT feed these, so they are handled here.
#   * Firefox on Windows/macOS - trusts the OS root store once
#                          security.enterprise_roots.enabled is set, which we write to user.js.
# NSS databases are cached in memory by a running browser, so callers must close
# Chrome/Firefox first (see Assert-BrowsersClosed).

$script:CaNickname = "OctoMesh Getting Started Root CA"
# Executable names of the browsers that keep their own certificate stores.
# chrome_crashpad_handler is deliberately absent: it holds no NSS database and exits
# with its browser.
$script:BrowserProcessPattern = '^(google-)?chrom(e|ium)(-browser|-stable|-beta|-dev)?$|^firefox(-bin|-esr|-developer-edition)?$|^Google Chrome( Beta| Canary| Dev)?$|^Firefox( Developer Edition| Nightly)?$'
$script:LinuxCaFileName = "octomesh-getting-started-root-ca.crt"

function Get-CaFingerprint([string]$CrtPath) {
    if (-not (Test-Path $CrtPath)) { return $null }
    $out = openssl x509 -in $CrtPath -noout -fingerprint -sha256 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $out) { return $null }
    return (($out -join "") -replace '.*=', '').Trim().ToUpperInvariant()
}

function Get-BrowserProcessBaseName([string]$ProcessName) {
    # Normalizes what Get-Process reports on the three platforms to a bare executable
    # name:
    #   Linux   "chrome --type=renderer …", "/opt/google/chrome/chrome --type=zygote"
    #   Windows "chrome", "chrome.exe", or a full path containing spaces
    #   macOS   "Google Chrome", "firefox"
    # Command-line flags are cut off first (everything from the first " -"), then the
    # path is reduced to its last segment - so names that legitimately contain a space
    # survive.
    if ([string]::IsNullOrWhiteSpace($ProcessName)) { return "" }
    $name = ($ProcessName.Trim() -split ' +-', 2)[0].Trim()
    $name = ($name -split '[/\\]')[-1]
    return ($name -replace '\.exe$', '')
}

function Test-BrowserProcessName([string]$ProcessName) {
    if ([string]::IsNullOrWhiteSpace($ProcessName)) { return $false }
    # Match the reported name as-is first (covers "Google Chrome" and "chrome.exe"),
    # then the normalized form (covers Linux command lines and full paths).
    if (($ProcessName.Trim() -replace '\.exe$', '') -match $script:BrowserProcessPattern) { return $true }
    return ((Get-BrowserProcessBaseName $ProcessName) -match $script:BrowserProcessPattern)
}

function Get-RunningBrowserProcesses {
    # Works on all three platforms: Linux (process name is the rewritten command
    # line), Windows (chrome/firefox[.exe]) and macOS ("Google Chrome", "firefox").
    return @(Get-Process -ErrorAction SilentlyContinue |
        Where-Object { Test-BrowserProcessName $_.ProcessName })
}

function Assert-BrowsersClosed([switch]$NonInteractive) {
    # NSS certificate databases are only re-read on browser start, and a running
    # browser can overwrite them on exit - so the CA must be (un)installed while
    # Chrome and Firefox are closed. Returns $false when the caller should skip
    # the NSS/Firefox steps.
    $running = Get-RunningBrowserProcesses
    if ($running.Count -eq 0) { return $true }

    $list = ($running | ForEach-Object { Get-BrowserProcessBaseName $_.ProcessName } | Sort-Object -Unique) -join ", "
    Write-Host ""
    Write-Host "Chrome/Firefox are running ($list). Their certificate databases can only be" -ForegroundColor Yellow
    Write-Host "updated while they are closed." -ForegroundColor Yellow
    if ($NonInteractive) {
        Write-Host "Running non-interactively - skipping the browser trust stores. Close the browsers" -ForegroundColor Yellow
        Write-Host "and re-run ./om-install.ps1 to trust the CA in Chrome and Firefox." -ForegroundColor Yellow
        return $false
    }
    Write-Host "They can be reopened as soon as the certificate is installed (a few seconds)." -ForegroundColor Yellow
    $confirm = Read-Host "Type 'yes' to close them now"
    if ($confirm -ne "yes") {
        Write-Host "Skipping the browser trust stores - Chrome and Firefox will warn about the certificate." -ForegroundColor Yellow
        return $false
    }
    foreach ($p in $running) {
        try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch { }
    }
    # A browser is a process tree (Chrome: zygotes, renderers, utility processes);
    # children can outlive the parent by a moment, so poll instead of sleeping once.
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
        $still = Get-RunningBrowserProcesses
        if ($still.Count -eq 0) { return $true }
        foreach ($p in $still) {
            try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch { }
        }
        Start-Sleep -Milliseconds 500
    }
    Write-Host "Some browser processes are still running - close them manually and re-run." -ForegroundColor Yellow
    return $false
}

function Get-NssCertutil {
    # 'certutil' on Windows is an unrelated Microsoft tool - never use it there.
    if ($IsWindows) { return $null }
    $cmd = Get-Command certutil -ErrorAction SilentlyContinue
    if (-not $cmd) { return $null }
    $help = (& $cmd.Source -H 2>&1 | Out-String)
    if ($help -notmatch "NSS") { return $null }
    return $cmd.Source
}

function Get-FirefoxProfileRoots {
    $roots = @()
    if ($IsWindows) {
        $roots += (Join-Path $env:APPDATA "Mozilla\Firefox\Profiles")
    }
    elseif ($IsMacOS) {
        $roots += (Join-Path $HOME "Library/Application Support/Firefox/Profiles")
    }
    else {
        $roots += (Join-Path $HOME ".mozilla/firefox")
        $roots += (Join-Path $HOME "snap/firefox/common/.mozilla/firefox")
        $roots += (Join-Path $HOME ".var/app/org.mozilla.firefox/.mozilla/firefox")
    }
    return @($roots | Where-Object { Test-Path $_ })
}

function Get-FirefoxProfilePaths {
    # A profile directory is any child of a profile root holding prefs.js or cert9.db.
    $profiles = @()
    foreach ($root in (Get-FirefoxProfileRoots)) {
        $profiles += @(Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue |
            Where-Object { (Test-Path (Join-Path $_.FullName "prefs.js")) -or (Test-Path (Join-Path $_.FullName "cert9.db")) } |
            Select-Object -ExpandProperty FullName)
    }
    return @($profiles)
}

function Get-NssDatabasePaths {
    # Chromium-family browsers on Linux share one user-wide NSS database; Firefox
    # keeps one per profile. On Windows/macOS Chrome uses the OS store instead.
    $dbs = @()
    if (-not $IsWindows -and -not $IsMacOS) {
        $chromeDb = Join-Path $HOME ".pki/nssdb"
        if (Test-Path $chromeDb) { $dbs += $chromeDb }
    }
    $dbs += (Get-FirefoxProfilePaths)
    return @($dbs)
}

function Set-FirefoxEnterpriseRoots {
    # Windows/macOS Firefox can import the OS root store; enable it per profile via
    # user.js (written once, kept idempotent) so the OS trust step covers Firefox too.
    $pref = 'user_pref("security.enterprise_roots.enabled", true);'
    $touched = 0
    foreach ($profile in (Get-FirefoxProfilePaths)) {
        $userJs = Join-Path $profile "user.js"
        $existing = if (Test-Path $userJs) { Get-Content $userJs -Raw } else { "" }
        if ($existing -match [regex]::Escape('security.enterprise_roots.enabled')) { continue }
        $prefix = if ([string]::IsNullOrWhiteSpace($existing) -or $existing.EndsWith("`n")) { "" } else { "`n" }
        Add-Content -Path $userJs -Value ("$prefix// Added by OctoMesh getting-started: trust the OS root store (local root CA).`n$pref") -Encoding UTF8
        $touched++
    }
    if ($touched -gt 0) {
        Write-Host "  Firefox: enabled OS root store import in $touched profile(s)." -ForegroundColor Green
    }
}

function Add-CaToNssStores([string]$CrtPath, [switch]$NonInteractive) {
    $dbs = Get-NssDatabasePaths
    $firefoxProfiles = Get-FirefoxProfilePaths
    if ($dbs.Count -eq 0 -and $firefoxProfiles.Count -eq 0) { return }

    if (-not (Assert-BrowsersClosed -NonInteractive:$NonInteractive)) { return }

    if ($IsWindows -or $IsMacOS) {
        Set-FirefoxEnterpriseRoots
        if (-not $IsMacOS) { return }
        # macOS Firefox honours enterprise roots as well; only continue when an NSS
        # certutil is available (brew install nss) for a belt-and-braces import.
    }

    $certutil = Get-NssCertutil
    if (-not $certutil) {
        if (-not $IsWindows -and -not $IsMacOS) {
            Write-Host "  NSS 'certutil' not found - Chrome and Firefox will not trust the CA." -ForegroundColor Yellow
            Write-Host "  Install it (Debian/Ubuntu: sudo apt install libnss3-tools) and re-run ./om-install.ps1." -ForegroundColor Yellow
        }
        return
    }

    foreach ($db in $dbs) {
        & $certutil -D -d "sql:$db" -n $script:CaNickname 2>$null | Out-Null
        & $certutil -A -d "sql:$db" -t "C,," -n $script:CaNickname -i $CrtPath 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  Trusted in NSS store $db" -ForegroundColor Green
        }
        else {
            Write-Host "  Could not write to NSS store $db (non-fatal)." -ForegroundColor Yellow
        }
    }
}

function Remove-CaFromNssStores([switch]$NonInteractive) {
    $dbs = Get-NssDatabasePaths
    if ($dbs.Count -eq 0) { return }
    $certutil = Get-NssCertutil
    if (-not $certutil) { return }
    if (-not (Assert-BrowsersClosed -NonInteractive:$NonInteractive)) { return }
    foreach ($db in $dbs) {
        & $certutil -D -d "sql:$db" -n $script:CaNickname 2>$null | Out-Null
    }
    Write-Host "  Removed the CA from $($dbs.Count) browser certificate store(s)." -ForegroundColor Green
}

function Test-CaTrustedInOsStore([string]$CrtPath) {
    # Cheap idempotency check so repeated installs do not prompt for sudo/elevation.
    $fingerprint = Get-CaFingerprint $CrtPath
    if (-not $fingerprint) { return $false }
    if ($IsWindows) {
        $normalized = $fingerprint -replace ':', ''
        $match = Get-ChildItem Cert:\LocalMachine\Root -ErrorAction SilentlyContinue |
            Where-Object { ([BitConverter]::ToString($_.GetCertHash('SHA256')) -replace '-', '') -eq $normalized }
        return (@($match).Count -gt 0)
    }
    if ($IsMacOS) {
        $existing = security find-certificate -c $script:CaNickname -p /Library/Keychains/System.keychain 2>$null | Out-String
        if ([string]::IsNullOrWhiteSpace($existing)) { return $false }
        $tmp = New-TemporaryFile
        $existing | Set-Content -Path $tmp -Encoding ascii
        $existingFp = Get-CaFingerprint $tmp
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        return ($existingFp -eq $fingerprint)
    }
    $installed = "/usr/local/share/ca-certificates/$script:LinuxCaFileName"
    if (-not (Test-Path $installed)) { return $false }
    return ((Get-CaFingerprint $installed) -eq $fingerprint)
}

function Add-CaToOsStore([string]$CrtPath) {
    if (Test-CaTrustedInOsStore $CrtPath) {
        Write-Host "  OS trust store already holds this CA." -ForegroundColor Green
        return
    }
    if ($IsMacOS) {
        sudo security delete-certificate -c $script:CaNickname /Library/Keychains/System.keychain 2>$null
        sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain $CrtPath
        if ($LASTEXITCODE -ne 0) { throw "security add-trusted-cert failed." }
    }
    elseif ($IsWindows) {
        Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.Subject -match [regex]::Escape($script:CaNickname) } | Remove-Item -ErrorAction SilentlyContinue
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
    $failed = $false
    if ($IsMacOS) {
        sudo security delete-certificate -c $script:CaNickname /Library/Keychains/System.keychain 2>$null
        if ($LASTEXITCODE -ne 0) { $failed = $true }
    }
    elseif ($IsWindows) {
        try {
            Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.Subject -match [regex]::Escape($script:CaNickname) } | Remove-Item -ErrorAction Stop
        }
        catch { $failed = $true }
    }
    else {
        sudo rm -f "/usr/local/share/ca-certificates/$script:LinuxCaFileName"
        if ($LASTEXITCODE -ne 0) { $failed = $true }
        if (-not $failed) {
            sudo update-ca-certificates | Out-Null
            if ($LASTEXITCODE -ne 0) { $failed = $true }
        }
    }
    return (-not $failed)
}
