# Technical Implementation Notes

## Design Decisions

### Why Hub-Spoke Topology?

- **Production-like** - Mirrors real enterprise networks
- **Scalable** - Easy to add more spoke VNets
- **Segregation** - Shared services (DC, Bastion, DNS) separated from workloads
- **Cost-effective** - Single Bastion and DNS Resolver serve multiple spokes

### Why DNS Resolver for Both VNets?

**Microsoft Best Practice:** Both hub and spoke VNets point to DNS Resolver Inbound Endpoint (10.0.4.4).

- **Centralized DNS** - Single DNS configuration point
- **Consistent resolution** - All VMs use same DNS path
- **Hybrid-ready** - On-premises can forward to DNS Resolver
- **Scalable** - Add spokes without changing DNS config

**DNS Flow:**
```
Client/DC VMs → DNS Resolver Inbound (10.0.4.4)
                    ↓
            Forwarding Rules Check
                    ↓
    contoso.local → DC (10.0.1.4) via Outbound Endpoint
    blob.core.windows.net → Azure Private DNS
    Other → Azure DNS (168.63.129.16)
```

### Why No Public IPs on VMs?

**Security Best Practice:**
- No direct internet exposure
- No RDP brute force attacks
- Bastion provides audited, SSL-encrypted access
- Follows zero-trust principles

### Why Custom Script Extension (Not DSC)?

- **More reliable** - No external dependencies
- **Simpler** - Single PowerShell command
- **Faster** - No DSC module downloads
- **Easier debugging** - Clear logs in `C:\WindowsAzure\Logs`
- **Self-contained** - Everything in Bicep template

### Why Storage Private Endpoint?

Tests key Azure scenario:
- Private Link integration
- Azure Private DNS zones
- Multi-VNet private DNS resolution
- Common enterprise requirement

## Resource Specifications

### Domain Controller

| Setting | Value | Why |
|---------|-------|-----|
| OS | Windows Server 2016 | Stable, well-tested |
| Size | Standard_D2s_v3 | 2 vCPU, 8GB RAM - sufficient for lab |
| Disk | 128GB Premium SSD | Single disk simplifies lab |
| IP | 10.0.1.4 (static) | Predictable for DNS |
| Domain | contoso.local | Standard test domain |

**AD Database Location:** OS disk (C:\) - acceptable for lab, not for production.

### Client VM

| Setting | Value | Why |
|---------|-------|-----|
| OS | Windows 11 Pro 23H2 | Latest client OS |
| Size | Standard_B2s | 2 vCPU, 4GB RAM - cost-optimized |
| Disk | 128GB Standard SSD | Cost savings |
| IP | Dynamic (DHCP) | Realistic client config |

### Azure Bastion

| Setting | Value | Why |
|---------|-------|-----|
| SKU | Basic | Cost-effective for lab |
| Subnet | 10.0.3.0/26 | Minimum size for Bastion |

**Cost Note:** Bastion is ~$140/month (49% of total cost). Delete when not testing.

### DNS Private Resolver

| Component | Value | Why |
|-----------|-------|-----|
| Inbound Endpoint | 10.0.4.4 (static) | Predictable for VNet DNS config |
| Inbound Subnet | 10.0.4.0/28 | Minimum required size |
| Outbound Endpoint | 10.0.5.0/28 | Separate subnet required |
| Forwarding Rule | contoso.local → 10.0.1.4 | Route domain queries to DC |

**Static IP:** Prevents circular dependency in Bicep (VNet references DNS Resolver, DNS Resolver deployed in VNet).

### Storage Account

| Setting | Value | Why |
|---------|-------|-----|
| Type | StorageV2 | Standard account type |
| Replication | Standard LRS | Cheapest for lab |
| Public Access | Disabled | Forces private endpoint usage |
| Private Endpoint | 10.1.2.0/24 subnet | Tests private link |

### Private DNS Zone

| Setting | Value | Why |
|---------|-------|-----|
| Name | privatelink.blob.core.windows.net | Required for blob private endpoints |
| Linked VNets | Hub + Spoke | Both need to resolve private endpoint |
| Auto-registration | Disabled | Manual control for lab |

**Critical:** Zone MUST be linked to both VNets for private endpoint resolution to work from both sides.

## Network Design

### IP Address Allocation

| Network | CIDR | Size | Usage |
|---------|------|------|-------|
| Hub VNet | 10.0.0.0/16 | 65,536 IPs | Shared services |
| - DC Subnet | 10.0.1.0/24 | 254 IPs | Domain controllers |
| - Bastion Subnet | 10.0.3.0/26 | 62 IPs | Azure Bastion (min size) |
| - DNS In Subnet | 10.0.4.0/28 | 14 IPs | DNS Resolver inbound |
| - DNS Out Subnet | 10.0.5.0/28 | 14 IPs | DNS Resolver outbound |
| Spoke VNet | 10.1.0.0/16 | 65,536 IPs | Workloads |
| - Client Subnet | 10.1.1.0/24 | 254 IPs | Client VMs |
| - PE Subnet | 10.1.2.0/24 | 254 IPs | Private endpoints |

### VNet Peering

**Configuration:**
- Bidirectional (hub-to-spoke AND spoke-to-hub)
- Allow forwarded traffic: True (for DNS)
- Allow virtual network access: True (for VM connectivity)
- Allow gateway transit: False (no VPN gateway)

### Network Security Groups

**DC NSG:**
```
Allow DNS (53) from VirtualNetwork
Allow LDAP (389) from VirtualNetwork
Allow Kerberos (88) from VirtualNetwork
Allow RDP (3389) from AzureBastionSubnet
```

**Client NSG:**
```
Allow RDP (3389) from AzureBastionSubnet
Allow outbound to VirtualNetwork
```

## Deployment Process

### Timeline

| Phase | Duration | Details |
|-------|----------|---------|
| Infrastructure | 3-5 min | VNets, NSGs, NICs, Storage, Private DNS |
| VM Creation | 2-3 min | Provision DC and Client VMs |
| VM Boot | 2-3 min | Windows startup |
| AD Configuration | 12-18 min | Install AD DS, promote to DC, restart |
| Bastion & DNS | 2-3 min | Deploy access and DNS services |
| **Total** | **30-40 min** | End-to-end deployment |

### AD Configuration Script

```powershell
# Executed via Custom Script Extension
Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools
Install-ADDSForest `
  -DomainName contoso.local `
  -SafeModeAdministratorPassword (ConvertTo-SecureString $password -AsPlainText -Force) `
  -InstallDns `
  -Force
# VM automatically restarts after promotion
```

### Validation Performed by Deploy Script

1. Check Azure CLI installed
2. Verify/generate password
3. Confirm Azure login
4. Create resource group
5. Deploy Bicep template
6. Monitor Custom Script Extension (up to 30 min)
7. Verify VNet DNS configuration
8. Save connection info

## Cost Breakdown (East US)

| Resource | Monthly | % of Total |
|----------|---------|------------|
| Azure Bastion | ~$140 | 49% |
| DC VM (D2s_v3) | ~$70 | 25% |
| Client VM (B2s) | ~$30 | 11% |
| DC Disk (128GB Premium) | ~$20 | 7% |
| Client Disk (128GB Standard) | ~$10 | 3% |
| DNS Private Resolver | ~$10 | 3% |
| Storage Account | ~$1.50 | 1% |
| Private Endpoint | ~$1 | <1% |
| VNet Peering | ~$1 | <1% |
| **Total** | **~$283** | **100%** |

**Cost Optimization:**
- Delete Bastion when not testing: Save $140/month
- Stop VMs when not using: Save ~$100/month
- Use B-series burstable for DC: Save ~$20/month

## Production Differences

**This is a LAB, not production-ready. Key differences:**

| Setting | Lab | Production |
|---------|-----|------------|
| AD Database | OS disk | Separate data disk on premium storage |
| DC Count | 1 | Minimum 2 for redundancy |
| Backup | None | Azure Backup or DPM |
| Monitoring | None | Azure Monitor, Log Analytics |
| DNS Resolver | Single | Redundant across regions |
| VM Size | Cost-optimized | Performance-optimized |
| Availability | None | Availability Sets or Zones |
| Bastion SKU | Basic | Standard (more features) |
| Storage | Standard LRS | Premium or GRS |

## Troubleshooting Tips

### Extension Logs

- **Location:** `C:\WindowsAzure\Logs\Plugins\Microsoft.Compute.CustomScriptExtension\`
- **Files:** Look for `*.log` files with timestamps
- **Common Issues:**
  - Password complexity failure
  - Network timeout during promotion
  - DNS server installation failure

### DNS Issues

```powershell
# Check VNet DNS in Azure Portal
az network vnet show --ids <vnet-id> --query dhcpOptions

# Should return: { "dnsServers": ["10.0.4.4"] }
```

### Peering Issues

```bash
# Check peering status
az network vnet peering list -g rg-dnstest --vnet-name dnstest-hub-vnet --query [].peeringState
# Should return: "Connected"
```

### Bastion Issues

- Check NSGs allow 443 from your IP
- Verify Bastion subnet has correct name: "AzureBastionSubnet"
- Confirm Bastion is in same region as VMs

## Files in This Repository

| File | Purpose |
|------|---------|
| **Deploy-TestEnvironment.ps1** | Orchestrates deployment using Azure CLI |
| **main.bicep** | Infrastructure as Code template (all Azure resources) |
| **main.parameters.json** | Sample parameters for manual deployment |
| **Export-DNSZone.ps1** | Backup DNS zones to JSON |
| **Import-DNSZone.ps1** | Restore DNS zones from JSON |
| **New-DNSConditionalForwarder.ps1** | Create DNS conditional forwarders (optional) |
| **docs/GUIDE.md** | Complete deployment and testing guide |
| **docs/TECHNICAL-NOTES.md** | This file - technical details |

## Key Bicep Design Patterns

### Circular Dependency Resolution

**Problem:** VNet needs DNS Resolver IP, DNS Resolver deploys into VNet.

**Solution:** Use static IP (10.0.4.4) for DNS Resolver Inbound Endpoint.

```bicep
// Hub VNet references static IP (no dependency)
dhcpOptions: {
  dnsServers: ['10.0.4.4']
}

// DNS Resolver uses that static IP
dnsResolverInboundEndpoint: {
  privateIpAllocationMethod: 'Static'
  privateIpAddress: '10.0.4.4'
}
```

### Password Handling

```bicep
@secure()
param adminPassword string

// Used in VM creation - never logged or displayed
```

PowerShell script generates secure password and passes as secure string.

### Custom Script Extension

```bicep
resource dcExtension 'Microsoft.Compute/virtualMachines/extensions@2023-03-01' = {
  parent: dcVm
  name: 'ConfigureAD'
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    settings: {}
    protectedSettings: {
      commandToExecute: 'powershell.exe -ExecutionPolicy Unrestricted -Command "..."'
    }
  }
}
```

## Reference Links

- [Azure DNS Private Resolver](https://docs.microsoft.com/azure/dns/dns-private-resolver-overview)
- [Azure Private Link](https://docs.microsoft.com/azure/private-link/private-link-overview)
- [Azure Bastion](https://docs.microsoft.com/azure/bastion/bastion-overview)
- [Hub-Spoke Topology](https://docs.microsoft.com/azure/architecture/reference-architectures/hybrid-networking/hub-spoke)
- [Active Directory on Azure VMs](https://docs.microsoft.com/azure/architecture/example-scenario/identity/adds-extend-domain)
