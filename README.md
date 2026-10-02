# webclientifier

One script to add the **Remote Desktop HTML5 web client** to an existing RDS deployment that currently only has the classic RD Web Access page (`/RDWeb`).

Once installed, users can connect straight from a browser, with no RDP client needed, at:

```
https://<your RDWeb name>/RDWeb/webclient/index.html
```

## Where to run it

Run it on the server that hosts the **RD Web Access** role, which is the server serving `/RDWeb`.

| Layout | Run on |
| --- | --- |
| RDG + RDS (Gateway and Web Access on the RDG, Broker and Session Host on the RDS) | **RDG** |
| Single server (all roles on one box) | That server |
| Multiple Web Access servers | **Each** Web Access server |

If RD Web Access isn't installed on the server, the script stops without changing anything.

## Usage

From an **elevated Windows PowerShell 5.1** prompt (not PowerShell 7):

```powershell
.\webclientifier.ps1
```

### Options

| Parameter | Description |
| --- | --- |
| `-ConnectionBroker <fqdn>` | Set the Connection Broker if auto-detection fails. |
| `-BrokerCertPath <path.cer>` | Use this broker certificate (public key only) instead of auto-detecting it. |
| `-AllowExpiredCert` | Install even if the broker certificate has expired, without prompting. |
| `-IncludeTest` | Also publish to the web client's test channel. |
| `-AllowTelemetry` | Leave Microsoft telemetry on (it's suppressed by default). |

```powershell
.\webclientifier.ps1 -ConnectionBroker rds01.contoso.local -BrokerCertPath C:\temp\broker.cer
```

## What it does

1. **Checks prerequisites:** admin rights, Windows PowerShell 5.1, Server 2016 or later, and the RD Web Access role installed.
2. **Installs the `RDWebClientManagement` module** from the PowerShell Gallery. It updates NuGet and PowerShellGet first if needed. This runs in a clean child PowerShell process, so an old PowerShellGet already loaded in your window can't break it.
3. **Finds the Connection Broker.** It tries RDWeb's `web.config`, then whether the broker role is on this server, then the session host settings that point to the broker.
4. **Gets the broker certificate** assigned to the RDS deployment (the RDRedirector role, falling back to RDPublishing):
   - If the same certificate is on this server (typical with a shared or wildcard cert), it uses that copy.
   - Otherwise it exports the certificate from the broker over PowerShell remoting.
   - It warns if the certificate is self-signed.
   - If the certificate has expired, it asks whether to **Retry** (after you renew or assign a new certificate), **Use anyway**, or **Abort**.
5. **Imports the certificate and publishes the latest web client** to production.
6. **Checks the licensing mode** and warns if it's Per Device.

The script is safe to re-run. Each run gets the latest module and web client package and re-imports the current certificate.

## Requirements

- Windows Server 2016 or later on both the Web Access server and the Connection Broker.
- Internet access from the Web Access server to the PowerShell Gallery.
- **A trusted, CA-issued certificate** on the deployment. With a self-signed certificate, the web client fails to connect even when the classic RDWeb page works.
- **Per User RDS CALs.** The web client doesn't support Per Device licensing.
- PowerShell remoting (WinRM) from the Web Access server to the broker. This is only needed when the broker's certificate isn't already on the Web Access server.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `Could not work out the Connection Broker` | RDWeb on that server has no broker configured. Check that the server is in the RDS deployment as RD Web Access (Server Manager → Remote Desktop Services → Overview, on the broker), then re-run with `-ConnectionBroker <fqdn>`. |
| Web client loads but can't connect | Usually a certificate problem: it's self-signed, doesn't match the broker's name, or the web client still has an old one. Check the certificate, then re-run the script. |
| Users are refused a licence | The deployment is using Per Device CALs. Switch it to Per User. |
| Script looks frozen | Text may be selected in the console window, which pauses the script. Press **Enter** or **Esc**. |

## Uninstalling

```powershell
Uninstall-RDWebClient
```

This removes the web client from `/RDWeb/webclient`. The classic RDWeb page is not affected.
