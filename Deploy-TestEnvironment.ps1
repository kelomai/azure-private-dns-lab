<#
.SYNOPSIS
    Deploys a test Azure environment for DNS testing with Private Link.

.DESCRIPTION
    This script deploys an Azure environment containing:
    - Virtual Network with subnets
    - Domain Controller VM with Active Directory
    - Storage Account with Private Endpoint
    - Private DNS Zone for blob storage

.PARAMETER ResourceGroupName
    Name of the resource group to create/use

.PARAMETER Location
    Azure region for deployment (default: eastus)

.PARAMETER NamePrefix
    Prefix for all resource names (default: dnstest)

.PARAMETER AdminUsername
    Admin username for the domain controller (default: azureadmin)

.PARAMETER AdminPassword
    Admin password for the domain controller (will prompt if not provided)

.PARAMETER DomainName
    Active Directory domain name (default: contoso.local)

.PARAMETER SkipVNetDnsUpdate
    Skip updating VNet DNS servers to point to the DC (useful for troubleshooting)

.EXAMPLE
    .\Deploy-TestEnvironment.ps1 -ResourceGroupName "rg-dnstest" -Location "eastus"

.EXAMPLE
    .\Deploy-TestEnvironment.ps1 -ResourceGroupName "rg-dnstest" -AdminPassword (ConvertTo-SecureString "P@ssw0rd123!" -AsPlainText -Force)

.NOTES
    Requires:
    - Azure CLI (az)
    - Contributor or Owner role on the subscription
    - Deployment takes approximately 20-30 minutes
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$Location = 'eastus',

    [Parameter(Mandatory = $false)]
    [string]$NamePrefix = 'dnstest',

    [Parameter(Mandatory = $false)]
    [string]$AdminUsername = 'azureadmin',

    [Parameter(Mandatory = $false)]
    [SecureString]$AdminPassword,

    [Parameter(Mandatory = $false)]
    [string]$DomainName = 'contoso.local',

    [Parameter(Mandatory = $false)]
    [switch]$SkipVNetDnsUpdate
)

# Check if Azure CLI is installed
try {
    $azVersion = az version 2>$null | ConvertFrom-Json
    Write-Host "Azure CLI version: $($azVersion.'azure-cli')" -ForegroundColor Green
}
catch {
    Write-Error "Azure CLI is not installed. Please install it from: https://aka.ms/installazurecliwindows"
    exit 1
}

# Function to validate password complexity
function Test-PasswordComplexity {
    param([string]$Password)

    if ($Password.Length -lt 8 -or $Password.Length -gt 123) {
        return $false, "Password must be between 8-123 characters"
    }

    $complexityCount = 0
    if ($Password -cmatch '[A-Z]') { $complexityCount++ } # Uppercase
    if ($Password -cmatch '[a-z]') { $complexityCount++ } # Lowercase
    if ($Password -match '\d') { $complexityCount++ }     # Digit
    if ($Password -match '[^a-zA-Z0-9]') { $complexityCount++ } # Special character

    if ($complexityCount -lt 3) {
        return $false, "Password must meet at least 3 of: uppercase, lowercase, digit, special character"
    }

    # Check for control characters
    if ($Password -match '[\x00-\x1F\x7F]') {
        return $false, "Password cannot contain control characters"
    }

    return $true, "Valid"
}

# Function to generate a secure password
function New-SecurePassword {
    $uppercase = 'ABCDEFGHJKLMNPQRSTUVWXYZ'  # Excluded I, O for clarity
    $lowercase = 'abcdefghijkmnopqrstuvwxyz'  # Excluded l for clarity
    $digits = '23456789'  # Excluded 0, 1 for clarity
    $special = '!@#$%^&*'

    # Ensure at least one of each type
    $password = @(
        $uppercase[(Get-Random -Maximum $uppercase.Length)]
        $lowercase[(Get-Random -Maximum $lowercase.Length)]
        $digits[(Get-Random -Maximum $digits.Length)]
        $special[(Get-Random -Maximum $special.Length)]
    )

    # Add random characters to make it 16 characters total
    $allChars = $uppercase + $lowercase + $digits + $special
    for ($i = 0; $i -lt 12; $i++) {
        $password += $allChars[(Get-Random -Maximum $allChars.Length)]
    }

    # Shuffle the password
    return -join ($password | Sort-Object { Get-Random })
}

# Get admin password if not provided
$passwordWasGenerated = $false
if (-not $AdminPassword) {
    Write-Host "`nGenerating secure password for domain controller..." -ForegroundColor Cyan
    $generatedPassword = New-SecurePassword
    $AdminPassword = ConvertTo-SecureString -String $generatedPassword -AsPlainText -Force
    $passwordWasGenerated = $true

    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "Generated Administrator Password" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host $generatedPassword -ForegroundColor Yellow
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "`nIMPORTANT: Save this password securely!" -ForegroundColor Red
    Write-Host "You will need it to RDP to the domain controller." -ForegroundColor Yellow
    Write-Host ""

    $continue = Read-Host "Press Enter to continue with deployment"

    # Use the generated password directly (no need to validate, we know it's good)
    $adminPasswordPlainText = $generatedPassword
}
else {
    # Convert SecureString to plain text for az CLI
    $adminPasswordPlainText = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($AdminPassword))

    # Validate password if it was provided as parameter
    $isValid, $message = Test-PasswordComplexity -Password $adminPasswordPlainText
    if (-not $isValid) {
        Write-Error "Provided password does not meet Azure requirements: $message"
        exit 1
    }
}

# Check if logged in to Azure
Write-Host "`nChecking Azure login status..." -ForegroundColor Cyan
$accountInfo = az account show 2>$null | ConvertFrom-Json

if (-not $accountInfo) {
    Write-Host "Not logged in to Azure. Logging in..." -ForegroundColor Yellow
    az login
    $accountInfo = az account show | ConvertFrom-Json
}

Write-Host "Logged in to subscription: $($accountInfo.name)" -ForegroundColor Green
Write-Host "Subscription ID: $($accountInfo.id)" -ForegroundColor Green

# Create resource group if it doesn't exist
Write-Host "`nChecking resource group..." -ForegroundColor Cyan
$rgExists = az group exists --name $ResourceGroupName | ConvertFrom-Json

if (-not $rgExists) {
    Write-Host "Creating resource group '$ResourceGroupName' in $Location..." -ForegroundColor Yellow
    az group create --name $ResourceGroupName --location $Location --output none
    Write-Host "Resource group created" -ForegroundColor Green
}
else {
    Write-Host "Resource group '$ResourceGroupName' already exists" -ForegroundColor Green
}

# Get the Bicep template path
$bicepTemplatePath = Join-Path $PSScriptRoot "main.bicep"

if (-not (Test-Path $bicepTemplatePath)) {
    Write-Error "Bicep template not found at: $bicepTemplatePath"
    exit 1
}

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Deployment Configuration" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Resource Group: $ResourceGroupName" -ForegroundColor White
Write-Host "Location: $Location" -ForegroundColor White
Write-Host "Name Prefix: $NamePrefix" -ForegroundColor White
Write-Host "Domain Name: $DomainName" -ForegroundColor White
Write-Host "Admin Username: $AdminUsername" -ForegroundColor White
Write-Host "`nThis deployment will take approximately 30-40 minutes" -ForegroundColor Yellow
Write-Host "The domain controller will be configured with Active Directory Domain Services" -ForegroundColor Yellow
Write-Host "Azure Bastion and DNS Private Resolver will be deployed for secure access" -ForegroundColor Yellow

$continue = Read-Host "`nDo you want to continue? (Y/N)"
if ($continue -ne "Y" -and $continue -ne "y") {
    Write-Host "Deployment cancelled" -ForegroundColor Yellow
    exit 0
}

# Deploy the Bicep template
Write-Host "`nStarting deployment..." -ForegroundColor Cyan
$deploymentName = "dns-test-env-$(Get-Date -Format 'yyyyMMddHHmmss')"

try {
    $deploymentOutput = az deployment group create `
        --name $deploymentName `
        --resource-group $ResourceGroupName `
        --template-file $bicepTemplatePath `
        --parameters namePrefix=$NamePrefix `
                     location=$Location `
                     adminUsername=$AdminUsername `
                     "adminPassword=$adminPasswordPlainText" `
                     domainName=$DomainName `
        --output json | ConvertFrom-Json

    if ($LASTEXITCODE -ne 0) {
        throw "Deployment failed with exit code $LASTEXITCODE"
    }

    Write-Host "`nDeployment completed successfully!" -ForegroundColor Green
}
catch {
    Write-Error "Deployment failed: $_"
    Write-Host "`nTo view deployment details, run:" -ForegroundColor Yellow
    Write-Host "az deployment group show --resource-group $ResourceGroupName --name $deploymentName" -ForegroundColor Yellow
    exit 1
}

# Get deployment outputs
$dcPrivateIP = $deploymentOutput.properties.outputs.domainControllerIP.value
$clientPrivateIP = $deploymentOutput.properties.outputs.clientVMPrivateIP.value
$storageAccountName = $deploymentOutput.properties.outputs.storageAccountName.value
$privateDnsZoneName = $deploymentOutput.properties.outputs.privateDnsZoneName.value
$hubVnetName = $deploymentOutput.properties.outputs.hubVnetName.value
$spokeVnetName = $deploymentOutput.properties.outputs.spokeVnetName.value
$privateEndpointName = $deploymentOutput.properties.outputs.privateEndpointName.value
$bastionName = $deploymentOutput.properties.outputs.bastionName.value
$dnsResolverName = $deploymentOutput.properties.outputs.dnsResolverName.value
$dnsResolverInboundEndpointIP = $deploymentOutput.properties.outputs.dnsResolverInboundEndpointIP.value

# Get the private endpoint IP from the network interface
Write-Host "`nRetrieving private endpoint IP address..." -ForegroundColor Cyan
$privateEndpoint = az network private-endpoint show `
    --resource-group $ResourceGroupName `
    --name $privateEndpointName `
    --output json | ConvertFrom-Json

$nicId = $privateEndpoint.networkInterfaces[0].id
$nicName = $nicId.Split('/')[-1]
$nic = az network nic show --ids $nicId --output json | ConvertFrom-Json
$privateEndpointIP = $nic.ipConfigurations[0].privateIPAddress

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Deployment Outputs" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Hub VNet Name: $hubVnetName" -ForegroundColor White
Write-Host "Spoke VNet Name: $spokeVnetName" -ForegroundColor White
Write-Host "Domain Controller Private IP (Hub): $dcPrivateIP" -ForegroundColor White
Write-Host "Client VM Private IP (Spoke): $clientPrivateIP" -ForegroundColor White
Write-Host "Storage Account Name (Spoke): $storageAccountName" -ForegroundColor White
Write-Host "Private DNS Zone: $privateDnsZoneName" -ForegroundColor White
Write-Host "Storage Private Endpoint IP (Spoke): $privateEndpointIP" -ForegroundColor White
Write-Host "Azure Bastion (Hub): $bastionName" -ForegroundColor White
Write-Host "DNS Resolver (Hub): $dnsResolverName" -ForegroundColor White
Write-Host "DNS Resolver Inbound Endpoint IP: $dnsResolverInboundEndpointIP" -ForegroundColor White

# Wait for DC to be fully configured (Custom Script Extension takes time)
Write-Host "`nWaiting for Domain Controller configuration to complete..." -ForegroundColor Cyan
Write-Host "This may take 10-15 minutes. Checking every 60 seconds..." -ForegroundColor Yellow

$maxWaitTime = 1800 # 30 minutes
$waitInterval = 60  # 1 minute
$elapsedTime = 0
$dcReady = $false

while ($elapsedTime -lt $maxWaitTime -and -not $dcReady) {
    Start-Sleep -Seconds $waitInterval
    $elapsedTime += $waitInterval

    $vmStatus = az vm get-instance-view `
        --resource-group $ResourceGroupName `
        --name "$NamePrefix-dc" `
        --output json | ConvertFrom-Json

    $extension = $vmStatus.extensions | Where-Object { $_.name -eq 'ConfigureADDC' }

    if ($extension) {
        $provisioningState = $extension.provisioningState
        $statusMessage = if ($extension.statuses) { $extension.statuses[0].message } else { "" }

        Write-Host "[$elapsedTime seconds] Extension Status: $provisioningState" -ForegroundColor Cyan

        if ($provisioningState -eq 'Succeeded') {
            $dcReady = $true
            Write-Host "Domain Controller is ready!" -ForegroundColor Green
        }
        elseif ($provisioningState -eq 'Failed') {
            Write-Warning "Custom Script Extension failed. Check VM for details."
            Write-Host "Status Message: $statusMessage" -ForegroundColor Yellow
            break
        }
    }
}

if (-not $dcReady) {
    Write-Warning "Domain Controller configuration is taking longer than expected."
    Write-Host "You can check the status later using:" -ForegroundColor Yellow
    Write-Host "az vm get-instance-view --resource-group $ResourceGroupName --name $NamePrefix-dc" -ForegroundColor Yellow
}

# Verify VNet DNS configuration
if (-not $SkipVNetDnsUpdate -and $dcReady) {
    Write-Host "`nVerifying VNet DNS configuration..." -ForegroundColor Cyan

    try {
        # Verify Hub VNet DNS points to DC
        $hubVnet = az network vnet show `
            --resource-group $ResourceGroupName `
            --name $hubVnetName `
            --output json | ConvertFrom-Json

        if ($hubVnet.dhcpOptions.dnsServers -contains $dcPrivateIP) {
            Write-Host "Hub VNet DNS configured correctly" -ForegroundColor Green
            Write-Host "  DNS Server: $dcPrivateIP (Domain Controller)" -ForegroundColor White
        }

        # Verify Spoke VNet DNS points to DNS Resolver Inbound Endpoint
        $spokeVnet = az network vnet show `
            --resource-group $ResourceGroupName `
            --name $spokeVnetName `
            --output json | ConvertFrom-Json

        if ($spokeVnet.dhcpOptions.dnsServers -contains $dnsResolverInboundEndpointIP) {
            Write-Host "Spoke VNet DNS configured correctly" -ForegroundColor Green
            Write-Host "  DNS Server: $dnsResolverInboundEndpointIP (DNS Resolver Inbound Endpoint)" -ForegroundColor White
        }
    }
    catch {
        Write-Warning "Failed to verify VNet DNS servers: $_"
    }
}

# Display connection information
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Next Steps" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "1. Connect to VMs via Azure Bastion:" -ForegroundColor White
Write-Host "   - Go to Azure Portal > Resource Groups > $ResourceGroupName" -ForegroundColor Yellow
Write-Host "   - Select VM ($NamePrefix-dc or $NamePrefix-client)" -ForegroundColor Yellow
Write-Host "   - Click 'Connect' > 'Bastion'" -ForegroundColor Yellow
Write-Host "   - Username: $AdminUsername" -ForegroundColor Yellow
Write-Host "   - Password: (the password you provided)" -ForegroundColor Yellow
Write-Host ""
Write-Host "2. Hub-Spoke Architecture:" -ForegroundColor White
Write-Host "   Hub VNet: $hubVnetName (DC, Bastion, DNS Resolver)" -ForegroundColor Yellow
Write-Host "   Spoke VNet: $spokeVnetName (Client, Storage)" -ForegroundColor Yellow
Write-Host "   VNets are peered for communication" -ForegroundColor Yellow
Write-Host ""
Write-Host "3. DNS Flow:" -ForegroundColor White
Write-Host "   Spoke VNet -> DNS Resolver Inbound ($dnsResolverInboundEndpointIP)" -ForegroundColor Yellow
Write-Host "   DNS Resolver Outbound -> Domain Controller ($dcPrivateIP)" -ForegroundColor Yellow
Write-Host "   On-premises can forward to: $dnsResolverInboundEndpointIP" -ForegroundColor Yellow
Write-Host ""
Write-Host "4. Test DNS from Client VM:" -ForegroundColor White
Write-Host "   Resolve-DnsName $storageAccountName.blob.core.windows.net" -ForegroundColor Yellow
Write-Host "   (Should resolve to private endpoint IP: $privateEndpointIP)" -ForegroundColor Yellow
Write-Host ""
Write-Host "5. Test AD domain resolution from Client VM:" -ForegroundColor White
Write-Host "   Resolve-DnsName $DomainName" -ForegroundColor Yellow
Write-Host "   (Should resolve via DNS Resolver to DC)" -ForegroundColor Yellow
Write-Host ""
Write-Host "6. On DC, test DNS scripts:" -ForegroundColor White
Write-Host "   .\New-DNSConditionalForwarder.ps1 -DomainName '$privateDnsZoneName'" -ForegroundColor Yellow
Write-Host "   .\Export-DNSZone.ps1 -ZoneName '$DomainName' -ExportPath 'C:\DNSBackups'" -ForegroundColor Yellow

# Save connection info to file
$connectionInfoPath = Join-Path $PSScriptRoot "connection-info.txt"
$connectionInfo = @"
==========================================================
Azure DNS Test Environment - Hub-Spoke Architecture
==========================================================
Deployment Date: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
Resource Group: $ResourceGroupName
Location: $Location

Hub VNet:
  Name: $hubVnetName
  Address Space: 10.0.0.0/16
  DNS Server: $dcPrivateIP (Domain Controller)
  Resources: Domain Controller, Azure Bastion, DNS Private Resolver

Spoke VNet:
  Name: $spokeVnetName
  Address Space: 10.1.0.0/16
  DNS Server: $dnsResolverInboundEndpointIP (DNS Resolver Inbound Endpoint)
  Resources: Windows 11 Client VM, Storage Account with Private Endpoint

Domain Controller (Hub VNet):
  VM Name: $NamePrefix-dc
  Private IP: $dcPrivateIP
  OS: Windows Server 2016
  Username: $AdminUsername
  Domain: $DomainName

Client VM (Spoke VNet):
  VM Name: $NamePrefix-client
  Private IP: $clientPrivateIP
  OS: Windows 11 Pro
  Username: $AdminUsername

Storage Account (Spoke VNet):
  Name: $storageAccountName
  Private Endpoint IP: $privateEndpointIP
  Private DNS Zone: $privateDnsZoneName

Azure Bastion (Hub VNet):
  Name: $bastionName
  Connection: Azure Portal > VM > Connect > Bastion

DNS Private Resolver (Hub VNet):
  Name: $dnsResolverName
  Inbound Endpoint IP: $dnsResolverInboundEndpointIP
  Outbound Endpoint: Forwards to DC ($dcPrivateIP)
  Use inbound IP for on-premises DNS forwarding

DNS Flow:
  1. Spoke VNet uses DNS Resolver Inbound Endpoint ($dnsResolverInboundEndpointIP)
  2. DNS Resolver forwards domain queries ($DomainName) to DC ($dcPrivateIP)
  3. DC resolves AD DNS and Azure Private DNS via conditional forwarder
  4. Client VM can resolve both AD and Azure Private DNS zones

Test Commands (run on Client VM):
  # Test storage private DNS resolution
  Resolve-DnsName $storageAccountName.blob.core.windows.net

  # Test AD domain resolution
  Resolve-DnsName $DomainName

  # Join domain (optional)
  Add-Computer -DomainName $DomainName -Credential (Get-Credential)

DNS Scripts (run on DC):
  .\New-DNSConditionalForwarder.ps1 -DomainName '$privateDnsZoneName'
  .\Export-DNSZone.ps1 -ZoneName '$DomainName' -ExportPath 'C:\DNSBackups'

Cleanup:
  az group delete --name $ResourceGroupName --yes --no-wait
"@

$connectionInfo | Out-File -FilePath $connectionInfoPath -Encoding UTF8
Write-Host "`nConnection information saved to: $connectionInfoPath" -ForegroundColor Green
Write-Host "`nDeployment complete!" -ForegroundColor Green
