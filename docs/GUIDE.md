# Azure DNS Testing Lab - Complete Guide

This is your complete guide to deploying and testing the Azure DNS Infrastructure Testing Lab.

## Table of Contents

- [Overview](#overview)
- [What Gets Deployed](#what-gets-deployed)
- [Prerequisites](#prerequisites)
- [Deployment](#deployment)
- [Connecting to VMs](#connecting-to-vms)
- [DNS Testing](#dns-testing)
- [Cleanup](#cleanup)
- [Troubleshooting](#troubleshooting)

## Overview

This lab creates a hub-spoke Azure network with:
- **Domain Controller** (Windows Server 2016) with Active Directory and DNS
- **Client VM** (Windows 11) for testing
- **Azure DNS Private Resolver** for hybrid DNS scenarios
- **Private Endpoint** to storage account with Azure Private DNS
- **Azure Bastion** for secure VM access (no public IPs)

**Cost:** ~$280-300/month | **Deploy Time:** ~30-40 minutes

## What Gets Deployed

### Hub VNet (10.0.0.0/16)
- Domain Controller at 10.0.1.4 (AD DS + DNS, domain: contoso.local)
- Azure Bastion for secure browser-based RDP
- DNS Private Resolver (Inbound: 10.0.4.4, Outbound: 10.0.5.0/28)

### Spoke VNet (10.1.0.0/16)
- Windows 11 Client VM for testing
- Storage Account with Private Endpoint
- Private DNS Zone (privatelink.blob.core.windows.net)

### DNS Flow
```
Client/DC → DNS Resolver (10.0.4.4) → Domain queries → DC (10.0.1.4)
                                     → Private endpoint → Azure Private DNS
                                     → External queries → Azure DNS
```

## Prerequisites

- Azure subscription (Contributor or Owner role)
- [Azure CLI](https://docs.microsoft.com/cli/azure/install-azure-cli) installed
- PowerShell 5.1+ (for deployment script)

## Deployment

### Quick Deploy

```powershell
./Deploy-TestEnvironment.ps1 -ResourceGroupName "rg-dnstest" -Location "eastus"
```

The script will:
1. Auto-generate a secure password and display it (**save it!**)
2. Deploy all Azure resources (~30-40 minutes)
3. Configure Domain Controller with AD DS
4. Save connection info to `connection-info.txt`

### Custom Password

```powershell
$password = ConvertTo-SecureString "YourP@ssw0rd!" -AsPlainText -Force
./Deploy-TestEnvironment.ps1 -ResourceGroupName "rg-dnstest" -Location "eastus" -AdminPassword $password
```

### What Happens During Deployment

| Phase | Time | What's Happening |
|-------|------|------------------|
| Infrastructure | 3-5 min | VNets, NSGs, NICs, Storage, Private Endpoint, DNS zones |
| VMs | 2-3 min | Create Domain Controller and Client VMs |
| VM Boot | 2-3 min | Windows startup |
| AD Configuration | 12-18 min | Install AD DS, promote to DC, automatic restart |
| Bastion & DNS Resolver | 2-3 min | Deploy access services |

**Total:** 30-40 minutes

## Connecting to VMs

**IMPORTANT:** VMs have **NO public IPs**. Access is **ONLY** via Azure Bastion.

### Steps to Connect

1. **Open Azure Portal** → https://portal.azure.com
2. **Navigate to your resource group** (e.g., rg-dnstest)
3. **Select a VM** (Domain Controller or Client)
4. **Click Connect** → **Connect** → **Bastion**
5. **Enter credentials:**
   - Username: `azureadmin`
   - Password: (from connection-info.txt)
6. **Click Connect** → Browser tab opens with RDP session

**Connection Notes:**
- Browser-based RDP (no RDP client needed)
- Connection over SSL (port 443)
- May take 10-30 seconds to connect
- To copy files: Copy/paste text directly in browser session

## DNS Testing

### Test 1: Verify DNS Configuration

**On Client VM:**
```powershell
# Check DNS server setting
Get-DnsClientServerAddress -InterfaceAlias "Ethernet*"
# Should show: 10.0.4.4 (DNS Resolver)

# Test domain resolution
Resolve-DnsName dc01.contoso.local
# Should return: 10.0.1.4

# Test connectivity
Test-NetConnection -ComputerName 10.0.1.4 -Port 53
Test-NetConnection -ComputerName 10.0.1.4 -Port 389  # LDAP
```

### Test 2: Private Endpoint Resolution

**On Client VM:**
```powershell
# Get storage account name from connection-info.txt
$storage = "dnsteststorage123"  # Replace with yours

# Resolve storage endpoint
Resolve-DnsName "$storage.blob.core.windows.net"
# Should return private IP: 10.1.2.x (NOT public IP)

# Test connectivity
Test-NetConnection -ComputerName "$storage.blob.core.windows.net" -Port 443
```

### Test 3: DNS Zone Export and Import

**On Domain Controller:**

**Copy DNS Scripts to DC:**
1. In Bastion session, open PowerShell ISE
2. Create folder: `New-Item -Path "C:\DNSScripts" -ItemType Directory`
3. Copy Export-DNSZone.ps1 and Import-DNSZone.ps1 from your local repo
4. Paste into new files in PowerShell ISE, save to C:\DNSScripts\

**Export a DNS Zone:**
```powershell
cd C:\DNSScripts
.\Export-DNSZone.ps1 -ZoneName "contoso.local" -ExportPath "C:\Backup"
# Creates: C:\Backup\contoso.local_20250120_143022.json
```

**Create Test Zone:**
```powershell
# Create new zone with test records
Add-DnsServerPrimaryZone -Name "test.local" -ReplicationScope "Domain"
Add-DnsServerResourceRecordA -Name "server1" -ZoneName "test.local" -IPv4Address "192.168.1.10"
Add-DnsServerResourceRecordA -Name "server2" -ZoneName "test.local" -IPv4Address "192.168.1.11"

# Export the test zone
.\Export-DNSZone.ps1 -ZoneName "test.local" -ExportPath "C:\Backup"
```

**Delete and Restore Zone:**
```powershell
# Delete the zone
Remove-DnsServerZone -Name "test.local" -Force

# Verify it's gone
Get-DnsServerZone -Name "test.local"  # Should error

# Import from backup
$exportFile = Get-ChildItem "C:\Backup\test.local_*.json" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
.\Import-DNSZone.ps1 -ImportFilePath $exportFile.FullName

# Verify restoration
Get-DnsServerResourceRecord -ZoneName "test.local"
```

**Test from Client VM:**
```powershell
# Wait for replication (1-2 minutes)
Start-Sleep -Seconds 60

# Test resolution
Resolve-DnsName server1.test.local
Resolve-DnsName server2.test.local
```

### Test 4: Cross-VNet DNS

**On Client VM (Spoke VNet):**
```powershell
# Query via DNS Resolver
Resolve-DnsName contoso.local -Server 10.0.4.4

# Query DC directly (tests VNet peering)
Resolve-DnsName contoso.local -Server 10.0.1.4

# Both should work due to VNet peering
```

**On Domain Controller (Hub VNet):**
```powershell
# DC should also resolve storage private endpoint
$storage = "dnsteststorage123"  # Your storage name
Resolve-DnsName "$storage.blob.core.windows.net"
# Should return private IP (zone linked to both VNets)
```

## Cleanup

When you're done testing:

```powershell
az group delete --name "rg-dnstest" --yes --no-wait
```

This deletes all resources and stops billing immediately.

## Troubleshooting

### Issue: Deployment Times Out

**Symptom:** Script says "Extension timeout"

**Solution:**
- AD configuration can take up to 30 minutes
- Check VM extension status in Azure Portal: VM → Extensions → CustomScriptExtension
- View logs: Connect to DC → `C:\WindowsAzure\Logs\Plugins\Microsoft.Compute.CustomScriptExtension`

### Issue: Can't Connect to VMs

**Symptom:** Connection fails or can't find connect option

**Solution:**
- VMs have NO public IPs - must use Bastion
- Ensure Bastion is deployed (check resource group)
- Check NSG rules haven't been modified
- Try from Azure Portal (not Azure CLI)

### Issue: DNS Resolution Fails

**Symptom:** `Resolve-DnsName` returns errors or timeouts

**Solution:**
```powershell
# Check DNS configuration
Get-DnsClientServerAddress
# Should show: 10.0.4.4

# If wrong, renew DHCP
ipconfig /renew

# Test DNS Resolver connectivity
Test-NetConnection 10.0.4.4 -Port 53
Test-NetConnection 10.0.1.4 -Port 53

# Check VNet DNS settings in Azure Portal
# Both hub and spoke should point to 10.0.4.4
```

### Issue: Private Endpoint Returns Public IP

**Symptom:** Storage resolves to public IP instead of 10.1.2.x

**Solution:**
```bash
# Verify private DNS zone links
az network private-dns link vnet list \
  --resource-group rg-dnstest \
  --zone-name privatelink.blob.core.windows.net

# Should show links to both hub and spoke VNets
```

### Issue: Zone Import Fails

**Symptom:** "Zone already exists" error

**Solution:**
```powershell
# Use -Force to replace existing
.\Import-DNSZone.ps1 -ImportFilePath "C:\Backup\zone.json" -Force

# Or delete first
Remove-DnsServerZone -Name "test.local" -Force
```

### Validation Checklist

- [ ] VMs are running
- [ ] Can connect via Bastion
- [ ] DNS server setting: 10.0.4.4
- [ ] Domain resolution works (dc01.contoso.local → 10.0.1.4)
- [ ] Storage resolves to private IP (10.1.2.x)
- [ ] VNet peering is Connected
- [ ] AD DS service is running on DC
- [ ] DNS zone export/import works

## DNS Management Scripts

### Export-DNSZone.ps1

Exports AD-integrated DNS zones to JSON for backup and version control.

**Usage:**
```powershell
.\Export-DNSZone.ps1 -ZoneName "contoso.local" -ExportPath "C:\Backup"
```

**Features:**
- Exports all record types (A, AAAA, CNAME, MX, NS, PTR, SRV, TXT, SOA)
- JSON format for easy version control
- Timestamped exports
- Validates AD integration

### Import-DNSZone.ps1

Restores DNS zones from JSON exports.

**Usage:**
```powershell
.\Import-DNSZone.ps1 -ImportFilePath "C:\Backup\contoso.local_20250120.json"

# Replace existing zone
.\Import-DNSZone.ps1 -ImportFilePath "C:\Backup\zone.json" -Force
```

**Features:**
- Creates AD-integrated zones
- Handles all replication scopes
- Skips auto-generated records (SOA, root NS)
- Reports success/failure per record

### New-DNSConditionalForwarder.ps1 (Optional)

Creates DNS conditional forwarders for specific domains.

**Usage:**
```powershell
.\New-DNSConditionalForwarder.ps1 -DomainName "azure.contoso.com" -ForwarderIPAddress "168.63.129.16"

# Create AD-integrated forwarder
.\New-DNSConditionalForwarder.ps1 -DomainName "privatelink.blob.core.windows.net" -ForwarderIPAddress "10.0.4.4" -ADIntegrated $true

# Multiple forwarder IPs
.\New-DNSConditionalForwarder.ps1 -DomainName "contoso.com" -ForwarderIPAddress "10.1.1.1","10.1.1.2"
```

**Features:**
- Creates conditional forwarders for specific domain queries
- Supports AD-integrated or standard forwarders
- Validates IP addresses
- Can configure multiple forwarder IPs
- Force replace existing with `-Force`

**Use Cases:**
- Forward Azure-specific domains to Azure DNS (168.63.129.16)
- Forward private link zones to DNS Resolver
- Forward external domains to specific DNS servers

## Additional Resources

- **Cost Breakdown:**
  - Azure Bastion: ~$140/month (delete when not testing to save)
  - DC VM: ~$70/month
  - Client VM: ~$30/month
  - Storage, DNS Resolver, Disks: ~$40-60/month

- **Architecture Highlights:**
  - Hub-spoke topology (production-like)
  - Both VNets use DNS Resolver (Microsoft best practice)
  - No public IPs on VMs (secure)
  - Private DNS linked to both VNets

- **Common Use Cases:**
  - Testing DNS zone management scripts
  - Learning hub-spoke network patterns
  - Testing Azure Private DNS integration
  - Validating hybrid DNS scenarios
  - DNS backup/restore procedures

## Support

For issues:
- Review this guide's troubleshooting section
- Check Azure Portal deployment logs
- Verify prerequisites are met
- Check VM extension status for AD configuration

---

**Quick Reference:**

| Action | Command |
|--------|---------|
| Deploy | `./Deploy-TestEnvironment.ps1 -ResourceGroupName "rg-dnstest" -Location "eastus"` |
| Connect | Azure Portal → VM → Connect → Bastion |
| Export Zone | `.\Export-DNSZone.ps1 -ZoneName "contoso.local" -ExportPath "C:\Backup"` |
| Import Zone | `.\Import-DNSZone.ps1 -ImportFilePath "C:\Backup\zone.json"` |
| Conditional Forwarder | `.\New-DNSConditionalForwarder.ps1 -DomainName "azure.com" -ForwarderIPAddress "168.63.129.16"` |
| Clean Up | `az group delete --name "rg-dnstest" --yes --no-wait` |

---

**Need more details?** See [TECHNICAL-NOTES.md](TECHNICAL-NOTES.md) for implementation details and design decisions.
