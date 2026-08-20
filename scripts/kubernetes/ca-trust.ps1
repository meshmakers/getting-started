# Shared helpers for trusting/untrusting the local root CA on the host.
# Dot-sourced by ../om-install.ps1 and ../om-uninstall.ps1.
#
# Trust stores that matter for the getting-started experience:
#   * OS store           - Chrome/Edge/Safari on Windows and macOS, curl/octo-cli everywhere.
#   * NSS (Linux only)   - Chrome/Chromium read ~/.pki/nssdb, Firefox reads per-profile cert9.db.
#                          update-ca-certificates does NOT feed these, so they are handled here.
#                          The sqlite backend (cert9.db) accepts certutil writes while
#                          the browser is running, so nothing has to be closed - the
#                          browser only has to restart before it sees the new CA.
#   * Firefox on Windows/macOS - needs nothing: it imports the OS root store by
#                          default (security.enterprise_roots.enabled, on since FF 68).

function Assert-Elevated {
    # Writing to Cert:\LocalMachine\Root (and removing from it) requires an elevated
    # process on Windows, and PowerShell cannot elevate in place - so re-launch the
    # calling script through UAC and let this one exit. Unix relies on per-command sudo.
    if (-not $IsWindows) { return }

    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { return }

    $script = $MyInvocation.PSCommandPath
    if (-not $script) { $script = $PSCommandPath }
    Write-Host "Administrator rights are required to update the Windows certificate store." -ForegroundColor Yellow
    Write-Host "Re-launching $([System.IO.Path]::GetFileName($script)) elevated - accept the UAC prompt." -ForegroundColor Yellow

    # Rebuild the original invocation: switches as bare names, everything else quoted.
    # License keys are deliberately NOT forwarded - a command line is visible to every
    # process on the machine. The elevated run picks them up from local-config.json, or
    # asks for them.
    $argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$script`"")
    foreach ($entry in $script:ElevationParameters.GetEnumerator()) {
        if ($entry.Key -like "*LicenseKey") { continue }
        if ($entry.Value -is [switch]) {
            if ($entry.Value.IsPresent) { $argList += "-$($entry.Key)" }
        }
        else {
            $argList += "-$($entry.Key)"
            $argList += "`"$($entry.Value)`""
        }
    }

    try {
        $process = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $argList -Verb RunAs -PassThru -Wait
        exit $process.ExitCode
    }
    catch {
        throw "Elevation was declined or failed. Start an elevated PowerShell and run the script there."
    }
}

$script:CaNickname = "OctoMesh Getting Started Root CA"
# Executable names of the browsers that keep their own certificate stores.
# chrome_crashpad_handler is deliberately absent: it holds no NSS database and exits
# with its browser.
$script:BrowserProcessPattern = '^(google-)?chrom(e|ium)(-browser|-stable|-beta|-dev)?$|^firefox(-bin|-esr|-developer-edition)?$|^Google Chrome( Beta| Canary| Dev)?$|^Firefox( Developer Edition| Nightly)?$'
$script:LinuxCaFileName = "octomesh-getting-started-root-ca.crt"

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

function Stop-BrowserProcesses {
    # A browser is a process tree (Chrome: zygotes, renderers, utility processes);
    # children can outlive the parent, so poll and re-kill instead of sleeping once.
    foreach ($p in (Get-RunningBrowserProcesses)) {
        try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch { }
    }
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
        $still = Get-RunningBrowserProcesses
        if ($still.Count -eq 0) { return $true }
        foreach ($p in $still) {
            try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch { }
        }
        Start-Sleep -Milliseconds 500
    }
    Write-Host "  Some browser processes are still running - close them manually." -ForegroundColor Yellow
    return $false
}

function Invoke-BrowserRestartOffer {
    # The certificate is already installed at this point; a browser only has to restart
    # to read it, so offering to close it is pure convenience - declining costs nothing.
    # The prompt is skipped when stdin is not a console: Read-Host would block forever
    # on an open pipe carrying no data, which is what CI looks like.
    $running = Get-RunningBrowserProcesses
    if ($running.Count -eq 0) { return }

    $list = ($running | ForEach-Object { Get-BrowserProcessBaseName $_.ProcessName } | Sort-Object -Unique) -join ", "
    Write-Host ""
    Write-Host "Chrome/Firefox are running ($list) and need a restart to pick up the new" -ForegroundColor Cyan
    Write-Host "certificate. The certificate itself is already installed." -ForegroundColor Cyan
    if ([Console]::IsInputRedirected) {
        Write-Host "Restart them when convenient." -ForegroundColor Cyan
        return
    }
    $confirm = Read-Host "Type 'yes' to close them now, or press Enter to restart them yourself later"
    if ($confirm -ne "yes") {
        Write-Host "Left running - restart Chrome/Firefox when convenient." -ForegroundColor Cyan
        return
    }
    if (Stop-BrowserProcesses) {
        Write-Host "  Closed - reopen Chrome/Firefox whenever you like." -ForegroundColor Green
    }
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

function Get-FirefoxProfilePaths {
    # Linux profile roots only - the NSS path is Linux-only (deb/tarball, snap, flatpak).
    # A profile directory is any child of a root holding prefs.js or cert9.db.
    $roots = @(
        (Join-Path $HOME ".mozilla/firefox"),
        (Join-Path $HOME "snap/firefox/common/.mozilla/firefox"),
        (Join-Path $HOME ".var/app/org.mozilla.firefox/.mozilla/firefox")
    ) | Where-Object { Test-Path $_ }
    $profiles = @()
    foreach ($root in $roots) {
        $profiles += @(Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue |
            Where-Object { (Test-Path (Join-Path $_.FullName "prefs.js")) -or (Test-Path (Join-Path $_.FullName "cert9.db")) } |
            Select-Object -ExpandProperty FullName)
    }
    return @($profiles)
}

function Get-NssDatabasePaths {
    # Chromium-family browsers share one user-wide NSS database; Firefox keeps one per
    # profile.
    $dbs = @()
    $chromeDb = Join-Path $HOME ".pki/nssdb"
    if (Test-Path $chromeDb) { $dbs += $chromeDb }
    return @($dbs + (Get-FirefoxProfilePaths))
}

function Add-CaToNssStore([string]$Certutil, [string]$Db, [string]$CrtPath) {
    & $Certutil -D -d "sql:$Db" -n $script:CaNickname 2>$null | Out-Null
    & $Certutil -A -d "sql:$Db" -t "C,," -n $script:CaNickname -i $CrtPath 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Add-CaToNssStores([string]$CrtPath) {
    # Linux only: everywhere else Chrome and Firefox both read the OS trust store
    # (Firefox imports it by default since FF 68).
    if ($IsWindows -or $IsMacOS) { return }
    $dbs = Get-NssDatabasePaths
    if ($dbs.Count -eq 0) { return }

    $certutil = Get-NssCertutil
    if (-not $certutil) {
        Write-Host "  NSS 'certutil' not found - Chrome and Firefox will not trust the CA." -ForegroundColor Yellow
        Write-Host "  Install it (Debian/Ubuntu: sudo apt install libnss3-tools) and re-run ./om-install.ps1." -ForegroundColor Yellow
        return
    }

    # cert9.db is sqlite and accepts the write with the browser open; the browser only
    # has to restart to read it (see Invoke-BrowserRestartOffer).
    foreach ($db in $dbs) {
        if (Add-CaToNssStore $certutil $db $CrtPath) {
            Write-Host "  Trusted in NSS store $db" -ForegroundColor Green
        }
        else {
            Write-Host "  Could not write to NSS store $db (non-fatal) - close that browser and re-run ./om-install.ps1." -ForegroundColor Yellow
        }
    }
}

function Test-CaInNssStore([string]$Certutil, [string]$Db) {
    & $Certutil -L -d "sql:$Db" -n $script:CaNickname 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Remove-CaFromNssStores {
    if ($IsWindows -or $IsMacOS) { return }
    $dbs = Get-NssDatabasePaths
    if ($dbs.Count -eq 0) { return }

    $certutil = Get-NssCertutil
    if (-not $certutil) { return }

    $removed = 0
    foreach ($db in $dbs) {
        if (-not (Test-CaInNssStore $certutil $db)) { continue }
        & $certutil -D -d "sql:$db" -n $script:CaNickname 2>$null | Out-Null
        if (Test-CaInNssStore $certutil $db) {
            Write-Host "  Could not remove the CA from $db (non-fatal) - close that browser and re-run." -ForegroundColor Yellow
        }
        else { $removed++ }
    }
    if ($removed -gt 0) {
        Write-Host "  Removed the CA from $removed browser certificate store(s)." -ForegroundColor Green
    }
}

function Add-CaToOsStore([string]$CrtPath) {
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
        # security delete-certificate also exits non-zero when there is nothing to
        # delete, so check for the certificate first - an already clean keychain is a
        # success, not a failure.
        security find-certificate -c $script:CaNickname /Library/Keychains/System.keychain 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            sudo security delete-certificate -c $script:CaNickname /Library/Keychains/System.keychain 2>$null
            if ($LASTEXITCODE -ne 0) { $failed = $true }
        }
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
