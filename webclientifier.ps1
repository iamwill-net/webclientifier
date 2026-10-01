<#
.SYNOPSIS
    Installs the Remote Desktop HTML5 Web Client on an RD Web Access server.

.DESCRIPTION
    Run this on the server that hosts the RD Web Access role (the /RDWeb site).
    In a typical two-server layout that's the RDG box (RD Gateway + RD Web Access),
    with the RDS box holding the Connection Broker + Session Host.

    Steps:
      1. Checks prerequisites (admin, Windows PowerShell 5.1, RDS-Web-Access installed).
      2-3. In a clean child PowerShell process: updates NuGet / PowerShellGet if needed
         and installs the RDWebClientManagement module.
      4. Finds the Connection Broker (RDWeb's web.config, local broker role, or session
         host settings) and gets the certificate assigned to the deployment's broker
         role - locally if it's the same cert (e.g. wildcard), otherwise exported
         remotely from the broker.
      5. Imports the broker cert and publishes the latest web client package.
      6. Warns if the deployment uses Per Device licensing (not supported by the web client).

.PARAMETER ConnectionBroker
    FQDN of the Connection Broker. Auto-detected if not given.

.PARAMETER BrokerCertPath
    Path to a .cer (public key only) of the broker's certificate. Skips auto-detection.

.PARAMETER IncludeTest
    Also publish the package to the test channel (/RDWeb/webclient-test... via Type Test).

.PARAMETER AllowTelemetry
    By default telemetry is suppressed. Use this to leave it on.

.EXAMPLE
    .\webclientifier.ps1

.EXAMPLE
    .\webclientifier.ps1 -ConnectionBroker rds01.contoso.local -BrokerCertPath C:\temp\broker.cer
#>
[CmdletBinding()]
param(
    [string]$ConnectionBroker,
    [string]$BrokerCertPath,
    [switch]$IncludeTest,
    [switch]$AllowTelemetry
)

$ErrorActionPreference = 'Stop'

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    $msg" -ForegroundColor Green }
function Write-Info($msg) { Write-Host "    $msg" }

# --- Prerequisites ----------------------------------------------------------

Write-Step 'Checking prerequisites'

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from an elevated (Run as administrator) PowerShell prompt.'
}

if ($PSVersionTable.PSEdition -eq 'Core') {
    throw 'Run this in Windows PowerShell 5.1 (powershell.exe), not PowerShell 7 (pwsh.exe).'
}

$webAccess = Get-WindowsFeature -Name RDS-Web-Access
if (-not $webAccess.Installed) {
    throw "RD Web Access (RDS-Web-Access) is not installed on $env:COMPUTERNAME. Run this on the server that hosts /RDWeb - usually the RDG."
}
Write-Ok "RD Web Access is installed on $env:COMPUTERNAME"

$os = [Environment]::OSVersion.Version
if ($os.Build -lt 14393) {
    throw 'The web client requires Windows Server 2016 or later.'
}

# PSGallery requires TLS 1.2
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# --- RDWebClientManagement module ------------------------------------------

Write-Step 'Installing RDWebClientManagement module'

# All package work runs in a clean child process. Once a session has loaded the inbox
# PackageManagement/PowerShellGet 1.0.0.1 it can't load the newer versions, and 1.0.0.1
# has no -AcceptLicense. Exit code 3 = PowerShellGet was just updated, run again fresh.
$installScript = {
    $ErrorActionPreference = 'Stop'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue |
              Where-Object { $_.Version -ge [version]'2.8.5.201' })) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
        Write-Host '    Installed NuGet provider'
    }

    if (-not (Get-Module -ListAvailable -Name PowerShellGet | Where-Object { $_.Version -ge [version]'2.0' })) {
        Install-Module -Name PowerShellGet -Force -AllowClobber -Scope AllUsers
        Write-Host '    Updated PowerShellGet'
        exit 3
    }

    Import-Module PowerShellGet -MinimumVersion 2.0
    Install-Module -Name RDWebClientManagement -AcceptLicense -Force -Scope AllUsers
    exit 0
}
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($installScript.ToString()))

for ($attempt = 1; $attempt -le 2; $attempt++) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded
    if ($LASTEXITCODE -ne 3) { break }
}
if ($LASTEXITCODE -ne 0) {
    if (Get-Module -ListAvailable -Name RDWebClientManagement) {
        Write-Warning 'Could not install/update RDWebClientManagement - continuing with the version already installed.'
    } else {
        throw "Installing RDWebClientManagement failed (exit code $LASTEXITCODE)."
    }
}
$rdwcVersion = (Get-Module -ListAvailable RDWebClientManagement | Sort-Object Version -Descending | Select-Object -First 1).Version
Write-Ok "RDWebClientManagement $rdwcVersion"
Import-Module RDWebClientManagement -Force

# --- Connection Broker ------------------------------------------------------

Write-Step 'Locating Connection Broker'

$localFqdn = ([Net.Dns]::GetHostEntry($env:COMPUTERNAME)).HostName

if (-not $ConnectionBroker) {
    # 1. RDWeb's own config (value is empty or 'localhost' when the broker is on this box)
    $webConfig = Join-Path $env:windir 'Web\RDWeb\Pages\web.config'
    if (Test-Path $webConfig) {
        [xml]$cfg = Get-Content $webConfig
        $value = ($cfg.SelectNodes('//appSettings/add') | Where-Object { $_.key -eq 'radcmserver' }).value
        Write-Info "RDWeb web.config radcmserver = '$value'"
        if ($value -and $value -notin @('localhost', '127.0.0.1', '.')) { $ConnectionBroker = $value }
    }
}

if (-not $ConnectionBroker) {
    # 1b. Effective IIS setting - can be set at a higher level than RDWeb\Pages\web.config
    try {
        Import-Module WebAdministration -ErrorAction Stop
        $value = (Get-WebConfigurationProperty -PSPath 'IIS:\Sites\Default Web Site\RDWeb\Pages' `
                    -Filter "appSettings/add[@key='radcmserver']" -Name value -ErrorAction Stop).Value
        Write-Info "IIS effective radcmserver = '$value'"
        if ($value -and $value -notin @('localhost', '127.0.0.1', '.')) { $ConnectionBroker = $value }
    } catch {
        Write-Info "Couldn't read IIS config ($($_.Exception.Message))"
    }
}

if (-not $ConnectionBroker -and (Get-WindowsFeature -Name RDS-Connection-Broker).Installed) {
    # 2. Broker role is installed on this server
    $ConnectionBroker = $localFqdn
    Write-Info 'Connection Broker role is installed locally'
}

if (-not $ConnectionBroker) {
    # 3. This server is a session host that points at a broker
    $tsKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\ClusterSettings'
    $value = (Get-ItemProperty -Path $tsKey -Name SessionDirectoryLocation -ErrorAction SilentlyContinue).SessionDirectoryLocation
    if ($value) {
        $ConnectionBroker = ($value -split ';')[0]
        Write-Info "Found broker in session host settings: $value"
    }
}

if (-not $ConnectionBroker) {
    throw ('Could not work out the Connection Broker. RDWeb on this server has no broker configured, ' +
           'which usually means it was not added to the RDS deployment (check Server Manager > RDS > Overview on the broker). ' +
           'If it is in the deployment, re-run with -ConnectionBroker <fqdn>.')
}
Write-Ok "Connection Broker: $ConnectionBroker"

# --- Broker certificate -----------------------------------------------------

Write-Step 'Getting Connection Broker certificate'

$tempCer = $null
if (-not $BrokerCertPath) {
    # Use the cert already assigned to the RDS deployment roles. The web client needs the
    # one the broker presents for RDP (RDRedirector); RDPublishing is normally the same cert.
    $thumb = $null
    try {
        Import-Module RemoteDesktop -ErrorAction Stop
        $roleCerts = Get-RDCertificate -ConnectionBroker $ConnectionBroker
        $roleCerts | Format-Table Role, Level, Subject, Thumbprint, ExpiresOn -AutoSize | Out-String | Write-Host

        $thumb = ($roleCerts | Where-Object { $_.Role -eq 'RDRedirector' -and $_.Thumbprint }).Thumbprint
        if (-not $thumb) {
            $thumb = ($roleCerts | Where-Object { $_.Role -eq 'RDPublishing' -and $_.Thumbprint }).Thumbprint
            if ($thumb) { Write-Warning 'No RDRedirector cert configured - using the RDPublishing cert instead.' }
        }
        if (-not $thumb) {
            throw 'No certificate is assigned to the RDRedirector/RDPublishing roles. Assign one in Server Manager > RDS > Deployment Properties > Certificates.'
        }
        if (($roleCerts | Where-Object Thumbprint | Select-Object -ExpandProperty Thumbprint -Unique).Count -gt 1) {
            Write-Warning 'The RDS roles use different certificates - the broker (RDRedirector) cert will be used.'
        }
    } catch [System.Management.Automation.RuntimeException] {
        if ($_.Exception.Message -like 'No certificate is assigned*') { throw }
        Write-Info "Get-RDCertificate failed ($($_.Exception.Message)); falling back to the broker's RDP listener cert"
    }

    $cert = $null
    if ($thumb) {
        Write-Info "Broker RDRedirector thumbprint: $thumb"
        $cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object Thumbprint -eq $thumb
        if ($cert) { Write-Ok 'Same certificate is present locally (shared/wildcard cert)' }
    }

    if (-not $cert) {
        Write-Info "Exporting certificate from $ConnectionBroker via PowerShell remoting"
        $bytes = Invoke-Command -ComputerName $ConnectionBroker -ArgumentList $thumb -ScriptBlock {
            param($thumb)
            if (-not $thumb) {
                # Fall back to whatever the RDP listener is bound to
                $thumb = (Get-CimInstance -Namespace root\cimv2\TerminalServices -ClassName Win32_TSGeneralSetting |
                          Where-Object TerminalName -eq 'RDP-Tcp').SSLCertificateSHA1Hash
            }
            $c = Get-ChildItem Cert:\LocalMachine\My, 'Cert:\LocalMachine\Remote Desktop' -ErrorAction SilentlyContinue |
                 Where-Object Thumbprint -eq $thumb | Select-Object -First 1
            if (-not $c) { throw "Certificate $thumb not found on $env:COMPUTERNAME" }
            $c.Export([Security.Cryptography.X509Certificates.X509ContentType]::Cert)
        }
        $cert = New-Object Security.Cryptography.X509Certificates.X509Certificate2(,[byte[]]$bytes)
        Write-Ok "Exported from $ConnectionBroker"
    }

    $tempCer = Join-Path $env:TEMP "rdbroker-$($cert.Thumbprint).cer"
    [IO.File]::WriteAllBytes($tempCer, $cert.Export([Security.Cryptography.X509Certificates.X509ContentType]::Cert))
    $BrokerCertPath = $tempCer
}

if (-not (Test-Path $BrokerCertPath)) { throw "Broker certificate not found: $BrokerCertPath" }

$brokerCert = New-Object Security.Cryptography.X509Certificates.X509Certificate2($BrokerCertPath)
Write-Info "Subject:  $($brokerCert.Subject)"
$daysLeft = [int]($brokerCert.NotAfter - (Get-Date)).TotalDays
Write-Info "Expires:  $($brokerCert.NotAfter.ToString('dd MMM yyyy')) ($daysLeft days)"
if ($daysLeft -lt 0) { throw 'The broker certificate has expired - renew it first.' }
if ($daysLeft -lt 60) {
    Write-Warning "Broker certificate expires in $daysLeft days. After renewing it, re-run this script so the web client gets the new cert."
}
if ($brokerCert.Subject -eq $brokerCert.Issuer) {
    Write-Warning 'Broker certificate is self-signed. The web client will fail to connect unless every client trusts it - use a CA-issued cert.'
}

# --- Install web client -----------------------------------------------------

Write-Step 'Importing broker certificate into the web client'
Import-RDWebClientBrokerCert -Path $BrokerCertPath
Write-Ok 'Imported'

Write-Step 'Publishing web client package (production)'
Install-RDWebClientPackage
Publish-RDWebClientPackage -Type Production -Latest
Write-Ok 'Published to production'

if ($IncludeTest) {
    Publish-RDWebClientPackage -Type Test -Latest
    Write-Ok 'Published to test'
}

if (-not $AllowTelemetry) {
    Set-RDWebClientDeploymentSetting -Name SuppressTelemetry -Value $true
    Write-Ok 'Telemetry suppressed'
}

if ($tempCer) { Remove-Item $tempCer -Force -ErrorAction SilentlyContinue }

# --- Licensing --------------------------------------------------------------

Write-Step 'Checking RD licensing mode'
try {
    $licMode = (Get-RDLicenseConfiguration -ConnectionBroker $ConnectionBroker -ErrorAction Stop).Mode
    if ("$licMode" -eq 'PerDevice') {
        Write-Warning 'Deployment uses Per Device CALs - the web client needs Per User licensing. Users may be refused a licence until this is changed.'
    } else {
        Write-Ok "Licensing mode: $licMode"
    }
} catch {
    Write-Info "Couldn't read licensing mode ($($_.Exception.Message)). The web client needs Per User CALs - check manually."
}

# --- Done -------------------------------------------------------------------

Write-Step 'Done'
$publicName = $brokerCert.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::DnsName, $false)
if (-not $publicName -or $publicName.StartsWith('*')) { $publicName = '<your public RDWeb name>' }
Write-Host ''
Write-Host "Web client URL: https://$publicName/RDWeb/webclient/index.html" -ForegroundColor Green
Write-Host "Internal URL:   https://$localFqdn/RDWeb/webclient/index.html"
