param([ValidateSet('start', 'stop', 'status')][string]$Action = 'start', [ValidateSet('hosts', 's5')][string]$Mode = 's5', [switch]$Elevated)
$ErrorActionPreference = 'Stop'
# Avoid inheriting incompatible PowerShell 7 modules when called from another host.
$env:PSModulePath = Join-Path $PSHOME 'Modules'
$root = $PSScriptRoot
$log = Join-Path $root 'setup.log'
$hostsPath = Join-Path $env:windir 'System32/drivers/etc/hosts'
$hostsStatePath = Join-Path $root 'hosts-state.json'
# Byte-preserving encoding: retain existing hosts content, including its encoding.
$hostsEncoding = [Text.Encoding]::GetEncoding(28591)
function Restore-MockHosts {
    if (-not (Test-Path -LiteralPath $hostsStatePath)) { return }
    $state = Get-Content -LiteralPath $hostsStatePath -Raw | ConvertFrom-Json
    $content = [IO.File]::ReadAllText($hostsPath, $hostsEncoding)
    if ($content.Contains($state.block)) {
        [IO.File]::WriteAllText($hostsPath, $content.Replace($state.block, ''), $hostsEncoding)
        Clear-DnsClientCache
    } elseif ($content.Contains($state.marker)) {
        throw 'The managed hosts block was edited. Restore its original block before stopping; backup is in hosts-backup-*.'
    }
    Remove-Item -LiteralPath $hostsStatePath
}
function Add-MockHosts {
    $content = [IO.File]::ReadAllText($hostsPath, $hostsEncoding)
    foreach ($line in ($content -split "`n")) {
        $active = ($line -split '#', 2)[0]
        if ($active -match '(?i)(^|\s)ab\.chatgpt\.com(\s|$)') { throw 'Existing ab.chatgpt.com hosts mapping found. Stop and restore the old mock first.' }
    }
    $marker = '# Codex Minimal Mock ' + [Guid]::NewGuid().ToString('N')
    $block = "`r`n$marker BEGIN`r`n127.0.0.1 ab.chatgpt.com`r`n$marker END`r`n"
    Copy-Item -LiteralPath $hostsPath -Destination (Join-Path $root ('hosts-backup-' + [Guid]::NewGuid().ToString('N')))
    @{marker=$marker; block=$block} | ConvertTo-Json | Set-Content -LiteralPath $hostsStatePath -Encoding UTF8
    [IO.File]::WriteAllText($hostsPath, $content + $block, $hostsEncoding)
    Clear-DnsClientCache
}
if ($Action -eq 'status') {
    Write-Output ('Package: ' + $root)
    $listeners = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -in 443,1089,18443 })
    if ($listeners.Count) { $listeners | Select-Object LocalAddress,LocalPort,OwningProcess | Format-Table } else { Write-Output 'NOT RUNNING: no listener on 443, 1089 or 18443.' }
    $nodeCommand = Get-Command node.exe -ErrorAction SilentlyContinue
    if ($nodeCommand -and (Test-Path -LiteralPath (Join-Path $root 'runtime.json'))) {
        & $nodeCommand.Source (Join-Path $root 'server.cjs') status
        if ($LASTEXITCODE -ne 0) { Write-Output 'HTTPS health check failed. Inspect startup output below.' }
    } elseif (-not $nodeCommand) { Write-Output 'Node.js was not found on PATH.' }
    else { Write-Output 'No runtime.json: first-time setup has not completed.' }
    foreach ($name in @('setup.log','server-error.log','socks.jsonl','requests.jsonl')) {
        $diagnosticPath = Join-Path $root $name
        if (Test-Path -LiteralPath $diagnosticPath) {
            Write-Output ('--- ' + $name + ' ---')
            Get-Content -LiteralPath $diagnosticPath -Tail 12
        }
    }
    exit 0
}
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    if ($Elevated) { throw 'Administrator rights are required for the local test certificate.' }
    $argsText = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" ' + $Action + ' -Mode ' + $Mode + ' -Elevated'
    $child = Start-Process powershell.exe -ArgumentList $argsText -Verb RunAs -WindowStyle Hidden -Wait -PassThru
    if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log }
    exit $child.ExitCode
}
Start-Transcript -LiteralPath $log -Force | Out-Null
try {
    Import-Module Microsoft.PowerShell.Security -ErrorAction Stop
    Get-PSDrive Cert -ErrorAction Stop | Out-Null
    $runtimePath = Join-Path $root 'runtime.json'
    $pidPath = Join-Path $root 'server.pid'
    $scriptPath = Join-Path $root 'server.cjs'
    $runtime = if (Test-Path -LiteralPath $runtimePath) { Get-Content -LiteralPath $runtimePath -Raw | ConvertFrom-Json } else { $null }
    $owned = $null
    if (Test-Path -LiteralPath $pidPath) {
        $savedPid = [int](Get-Content -LiteralPath $pidPath -Raw)
        $candidate = Get-CimInstance Win32_Process -Filter "ProcessId=$savedPid"
        if ($candidate -and $candidate.Name -eq 'node.exe' -and $candidate.CommandLine.Contains(('"' + $scriptPath + '"'))) { $owned = $candidate }
        elseif ($candidate) { throw 'PID belongs to a different process; refusing to stop or replace it.' }
    }
    if ($Action -eq 'stop') {
        if ($owned) { Stop-Process -Id $owned.ProcessId -Force }
        Restore-MockHosts
        if ($runtime -and -not $runtime.pretrusted) {
            $trustPath = 'Cert:\LocalMachine\Root\' + $runtime.thumbprint
            if (Test-Path -LiteralPath $trustPath) { Remove-Item -LiteralPath $trustPath }
        }
        if (Test-Path -LiteralPath $pidPath) { Remove-Item -LiteralPath $pidPath }
        Write-Output 'Stopped. Managed hosts mapping and test certificate trust removed. Disable any proxy rule separately.'
        exit 0
    }
    $node = (Get-Command node.exe -ErrorAction Stop).Source
    $nodeVersion = & $node --version
    if ($LASTEXITCODE -ne 0 -or [int]($nodeVersion.TrimStart('v').Split('.')[0]) -lt 18) { throw 'Node.js 18 or newer is required on PATH. No npm/pip packages are needed.' }
    if ($owned) {
        $runningStatus = & $node $scriptPath status
        if ($LASTEXITCODE -ne 0) { throw 'An existing process is unhealthy. Run stop.cmd, then start.cmd.' }
        $runningMode = if ($runtime.mode) { $runtime.mode } else { 's5' }
        if ($runningMode -eq $Mode) {
            Write-Output $runningStatus
            Write-Output ('Already running in ' + $Mode + ' mode.')
            exit 0
        }
        throw ('Currently running in ' + $runningMode + ' mode. Run stop.cmd before switching modes.')
    }
    Restore-MockHosts
    $ports = if ($Mode -eq 'hosts') { @(443) } else { @(1089,18443) }
    foreach ($port in $ports) {
        if (Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue) { throw "Port $port is already in use." }
    }
    $certPath = Join-Path $root 'server.cer'
    if ($runtime) {
        $cert = [Security.Cryptography.X509Certificates.X509Certificate2]::new($certPath)
        if ($cert.Thumbprint -ne $runtime.thumbprint -or $cert.NotAfter -lt (Get-Date).AddDays(1)) {
            throw 'Certificate expired or mismatched. Run stop.cmd, then remove runtime.json, server.cer and server.pfx before starting again.'
        }
    } else {
        $cert = New-SelfSignedCertificate -Type SSLServerAuthentication -Subject 'CN=ab.chatgpt.com' -DnsName 'ab.chatgpt.com' -FriendlyName 'Codex Local Mock Minimal' -CertStoreLocation 'Cert:\LocalMachine\My' -KeyAlgorithm RSA -KeyLength 2048 -HashAlgorithm SHA256 -KeyExportPolicy Exportable -NotAfter (Get-Date).AddDays(90)
        $password = [Guid]::NewGuid().ToString('N') + [Guid]::NewGuid().ToString('N')
        try {
            Export-PfxCertificate -Cert $cert -FilePath (Join-Path $root 'server.pfx') -Password (ConvertTo-SecureString $password -AsPlainText -Force) | Out-Null
            Export-Certificate -Cert $cert -FilePath $certPath | Out-Null
            $runtime = [pscustomobject]@{password=$password; thumbprint=$cert.Thumbprint; pretrusted=(Test-Path -LiteralPath ('Cert:\LocalMachine\Root\' + $cert.Thumbprint))}
            $runtime | ConvertTo-Json | Set-Content -LiteralPath $runtimePath -Encoding UTF8
        } finally {
            Remove-Item -LiteralPath ('Cert:\LocalMachine\My\' + $cert.Thumbprint) -DeleteKey
        }
    }
    $runtime | Add-Member -NotePropertyName mode -NotePropertyValue $Mode -Force
    $runtime | ConvertTo-Json | Set-Content -LiteralPath $runtimePath -Encoding UTF8
    try {
        if ($Mode -eq 'hosts') { Add-MockHosts }
        Import-Certificate -FilePath $certPath -CertStoreLocation 'Cert:\LocalMachine\Root' | Out-Null
        $startup = New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{ShowWindow=[uint16]0}
        $created = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
            CommandLine=('"' + $node + '" "' + $scriptPath + '"'); CurrentDirectory=$root; ProcessStartupInformation=$startup
        }
        if ($created.ReturnValue -ne 0) { throw "Independent startup failed: $($created.ReturnValue)" }
        for ($attempt=0; $attempt -lt 20; $attempt++) {
            Start-Sleep -Milliseconds 250
            $status = & $node $scriptPath status
            if ($LASTEXITCODE -eq 0 -and ($status | ConvertFrom-Json).pid -eq $created.ProcessId -and (Test-Path -LiteralPath $pidPath)) {
                if ($Mode -eq 'hosts') { Write-Output 'Started independently in HOSTS mode. HTTPS: 127.0.0.1:443. Domain mapping installed.' }
                else { Write-Output 'Started independently in SOCKS5 mode. Proxy: 127.0.0.1:1089. Target: ab.chatgpt.com:443.' }
                Write-Output $status
                exit 0
            }
        }
        throw 'Startup failed. See server-error.log.'
    } catch {
        if ($created -and $created.ReturnValue -eq 0) {
            $failed = Get-CimInstance Win32_Process -Filter "ProcessId=$($created.ProcessId)"
            if ($failed -and $failed.CommandLine.Contains(('"' + $scriptPath + '"'))) { Stop-Process -Id $failed.ProcessId -Force }
        }
        if (-not $runtime.pretrusted) { Remove-Item -LiteralPath ('Cert:\LocalMachine\Root\' + $runtime.thumbprint) -ErrorAction SilentlyContinue }
        Restore-MockHosts
        throw
    }
} catch {
    Write-Output ('ERROR: ' + $_.Exception.Message)
    exit 1
} finally {
    Stop-Transcript | Out-Null
}
