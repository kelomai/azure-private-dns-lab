@description('The name prefix for all resources')
param namePrefix string = 'dnstest'

@description('Azure region for resources')
param location string = resourceGroup().location

@description('Admin username for the domain controller')
param adminUsername string = 'azureadmin'

@description('Admin password for the domain controller')
@secure()
param adminPassword string

@description('Domain name for Active Directory')
param domainName string = 'contoso.local'

@description('Hub Virtual Network address prefix')
param hubVnetAddressPrefix string = '10.0.0.0/16'

@description('Subnet address prefix for domain controller')
param dcSubnetPrefix string = '10.0.1.0/24'

@description('Subnet address prefix for Azure Bastion')
param bastionSubnetPrefix string = '10.0.3.0/26'

@description('Subnet address prefix for DNS Private Resolver inbound endpoint')
param dnsResolverInboundSubnetPrefix string = '10.0.4.0/28'

@description('Subnet address prefix for DNS Private Resolver outbound endpoint')
param dnsResolverOutboundSubnetPrefix string = '10.0.5.0/28'

@description('Spoke Virtual Network address prefix')
param spokeVnetAddressPrefix string = '10.1.0.0/16'

@description('Subnet address prefix for client VMs in spoke')
param clientSubnetPrefix string = '10.1.1.0/24'

@description('Subnet address prefix for private endpoints in spoke')
param spokePrivateEndpointSubnetPrefix string = '10.1.2.0/24'

@description('VM Size for domain controller')
param vmSize string = 'Standard_D2s_v3'

@description('VM Size for client machine')
param clientVmSize string = 'Standard_B2s'

// Hub Virtual Network
resource hubVnet 'Microsoft.Network/virtualNetworks@2023-05-01' = {
  name: '${namePrefix}-hub-vnet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        hubVnetAddressPrefix
      ]
    }
    dhcpOptions: {
      dnsServers: [
        '10.0.4.4' // DNS Resolver Inbound Endpoint (static IP)
      ]
    }
    subnets: [
      {
        name: 'DomainControllerSubnet'
        properties: {
          addressPrefix: dcSubnetPrefix
          networkSecurityGroup: {
            id: nsg.id
          }
        }
      }
      {
        name: 'AzureBastionSubnet'
        properties: {
          addressPrefix: bastionSubnetPrefix
        }
      }
      {
        name: 'DnsResolverInboundSubnet'
        properties: {
          addressPrefix: dnsResolverInboundSubnetPrefix
          delegations: [
            {
              name: 'Microsoft.Network.dnsResolvers'
              properties: {
                serviceName: 'Microsoft.Network/dnsResolvers'
              }
            }
          ]
        }
      }
      {
        name: 'DnsResolverOutboundSubnet'
        properties: {
          addressPrefix: dnsResolverOutboundSubnetPrefix
          delegations: [
            {
              name: 'Microsoft.Network.dnsResolvers'
              properties: {
                serviceName: 'Microsoft.Network/dnsResolvers'
              }
            }
          ]
        }
      }
    ]
  }
}

// Network Security Group for Client
resource clientNsg 'Microsoft.Network/networkSecurityGroups@2023-05-01' = {
  name: '${namePrefix}-client-nsg'
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowRDP'
        properties: {
          priority: 1000
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '3389'
        }
      }
    ]
  }
}

// Spoke Virtual Network
resource spokeVnet 'Microsoft.Network/virtualNetworks@2023-05-01' = {
  name: '${namePrefix}-spoke-vnet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        spokeVnetAddressPrefix
      ]
    }
    dhcpOptions: {
      dnsServers: [
        '10.0.4.4' // DNS Resolver Inbound Endpoint (static IP)
      ]
    }
    subnets: [
      {
        name: 'ClientSubnet'
        properties: {
          addressPrefix: clientSubnetPrefix
          networkSecurityGroup: {
            id: clientNsg.id
          }
        }
      }
      {
        name: 'PrivateEndpointSubnet'
        properties: {
          addressPrefix: spokePrivateEndpointSubnetPrefix
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}

// VNet Peering: Hub to Spoke
resource hubToSpokePeering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-05-01' = {
  parent: hubVnet
  name: 'hub-to-spoke'
  properties: {
    remoteVirtualNetwork: {
      id: spokeVnet.id
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: false
  }
}

// VNet Peering: Spoke to Hub
resource spokeToHubPeering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-05-01' = {
  parent: spokeVnet
  name: 'spoke-to-hub'
  properties: {
    remoteVirtualNetwork: {
      id: hubVnet.id
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: false
  }
}

// Network Security Group for DC
resource nsg 'Microsoft.Network/networkSecurityGroups@2023-05-01' = {
  name: '${namePrefix}-dc-nsg'
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowDNS'
        properties: {
          priority: 1100
          protocol: '*'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '53'
        }
      }
      {
        name: 'AllowAD'
        properties: {
          priority: 1200
          protocol: '*'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRanges: [
            '88'
            '135'
            '389'
            '445'
            '464'
            '636'
            '3268'
            '3269'
          ]
        }
      }
    ]
  }
}

// Network Interface for Domain Controller
resource dcNic 'Microsoft.Network/networkInterfaces@2023-05-01' = {
  name: '${namePrefix}-dc-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: hubVnet.properties.subnets[0].id
          }
          privateIPAllocationMethod: 'Static'
          privateIPAddress: '10.0.1.4'
        }
      }
    ]
  }
}

// Domain Controller VM
resource dcVM 'Microsoft.Compute/virtualMachines@2023-03-01' = {
  name: '${namePrefix}-dc'
  location: location
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: 'DC01'
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        enableAutomaticUpdates: true
        provisionVMAgent: true
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2016-Datacenter'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        diskSizeGB: 128
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: dcNic.id
        }
      ]
    }
  }
}

// Custom Script Extension to configure Domain Controller
resource dcScript 'Microsoft.Compute/virtualMachines/extensions@2023-03-01' = {
  parent: dcVM
  name: 'ConfigureADDC'
  location: location
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    protectedSettings: {
      commandToExecute: 'powershell.exe -ExecutionPolicy Unrestricted -Command "Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools; Install-ADDSForest -DomainName ${domainName} -SafeModeAdministratorPassword (ConvertTo-SecureString -String \'${adminPassword}\' -AsPlainText -Force) -InstallDns -Force"'
    }
  }
}

// Storage Account
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: '${namePrefix}${uniqueString(resourceGroup().id)}'
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    publicNetworkAccess: 'Disabled'
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
  }
}

// Private DNS Zone for Blob Storage
resource privateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.blob.${environment().suffixes.storage}'
  location: 'global'
  properties: {}
}

// Link Private DNS Zone to Hub VNet
resource privateDnsZoneHubLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: privateDnsZone
  name: '${namePrefix}-hub-vnet-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: hubVnet.id
    }
  }
}

// Link Private DNS Zone to Spoke VNet
resource privateDnsZoneSpokeLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: privateDnsZone
  name: '${namePrefix}-spoke-vnet-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: spokeVnet.id
    }
  }
}

// Private Endpoint for Blob Storage (in Spoke VNet)
resource blobPrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-05-01' = {
  name: '${namePrefix}-blob-pe'
  location: location
  properties: {
    subnet: {
      id: spokeVnet.properties.subnets[1].id
    }
    privateLinkServiceConnections: [
      {
        name: '${namePrefix}-blob-pe-connection'
        properties: {
          privateLinkServiceId: storageAccount.id
          groupIds: [
            'blob'
          ]
        }
      }
    ]
  }
}

// Private DNS Zone Group
resource privateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-05-01' = {
  parent: blobPrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'blob-config'
        properties: {
          privateDnsZoneId: privateDnsZone.id
        }
      }
    ]
  }
}

// Public IP for Azure Bastion
resource bastionPublicIP 'Microsoft.Network/publicIPAddresses@2023-05-01' = {
  name: '${namePrefix}-bastion-pip'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

// Azure Bastion
resource bastion 'Microsoft.Network/bastionHosts@2023-05-01' = {
  name: '${namePrefix}-bastion'
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    ipConfigurations: [
      {
        name: 'bastionIpConfig'
        properties: {
          subnet: {
            id: hubVnet.properties.subnets[1].id // AzureBastionSubnet
          }
          publicIPAddress: {
            id: bastionPublicIP.id
          }
        }
      }
    ]
  }
}

// DNS Private Resolver
resource dnsResolver 'Microsoft.Network/dnsResolvers@2022-07-01' = {
  name: '${namePrefix}-dns-resolver'
  location: location
  properties: {
    virtualNetwork: {
      id: hubVnet.id
    }
  }
}

// DNS Resolver Inbound Endpoint
resource dnsResolverInboundEndpoint 'Microsoft.Network/dnsResolvers/inboundEndpoints@2022-07-01' = {
  parent: dnsResolver
  name: '${namePrefix}-inbound-endpoint'
  location: location
  properties: {
    ipConfigurations: [
      {
        subnet: {
          id: hubVnet.properties.subnets[2].id // DnsResolverInboundSubnet
        }
        privateIpAllocationMethod: 'Static'
        privateIpAddress: '10.0.4.4'
      }
    ]
  }
}

// DNS Resolver Outbound Endpoint
resource dnsResolverOutboundEndpoint 'Microsoft.Network/dnsResolvers/outboundEndpoints@2022-07-01' = {
  parent: dnsResolver
  name: '${namePrefix}-outbound-endpoint'
  location: location
  properties: {
    subnet: {
      id: hubVnet.properties.subnets[3].id // DnsResolverOutboundSubnet
    }
  }
}

// DNS Forwarding Ruleset
resource dnsForwardingRuleset 'Microsoft.Network/dnsForwardingRulesets@2022-07-01' = {
  name: '${namePrefix}-forwarding-ruleset'
  location: location
  properties: {
    dnsResolverOutboundEndpoints: [
      {
        id: dnsResolverOutboundEndpoint.id
      }
    ]
  }
}

// DNS Forwarding Rule to Domain Controller
resource dnsForwardingRuleToDC 'Microsoft.Network/dnsForwardingRulesets/forwardingRules@2022-07-01' = {
  parent: dnsForwardingRuleset
  name: 'forward-to-dc'
  properties: {
    domainName: '${domainName}.'
    targetDnsServers: [
      {
        ipAddress: '10.0.1.4'
        port: 53
      }
    ]
    forwardingRuleState: 'Enabled'
  }
}

// Link DNS Forwarding Ruleset to Spoke VNet
resource dnsForwardingRulesetSpokeLink 'Microsoft.Network/dnsForwardingRulesets/virtualNetworkLinks@2022-07-01' = {
  parent: dnsForwardingRuleset
  name: '${namePrefix}-spoke-link'
  properties: {
    virtualNetwork: {
      id: spokeVnet.id
    }
  }
}

// Windows 11 Client VM NIC (in Spoke VNet)
resource clientNic 'Microsoft.Network/networkInterfaces@2023-05-01' = {
  name: '${namePrefix}-client-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: spokeVnet.properties.subnets[0].id
          }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

// Windows 11 Client VM
resource clientVM 'Microsoft.Compute/virtualMachines@2023-03-01' = {
  name: '${namePrefix}-client'
  location: location
  properties: {
    hardwareProfile: {
      vmSize: clientVmSize
    }
    osProfile: {
      computerName: 'CLIENT01'
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        enableAutomaticUpdates: true
        provisionVMAgent: true
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsDesktop'
        offer: 'Windows-11'
        sku: 'win11-23h2-pro'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        diskSizeGB: 128
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: clientNic.id
        }
      ]
    }
  }
}

output domainControllerIP string = dcNic.properties.ipConfigurations[0].properties.privateIPAddress
output clientVMPrivateIP string = clientNic.properties.ipConfigurations[0].properties.privateIPAddress
output storageAccountName string = storageAccount.name
output storageAccountId string = storageAccount.id
output privateDnsZoneName string = privateDnsZone.name
output hubVnetName string = hubVnet.name
output hubVnetId string = hubVnet.id
output spokeVnetName string = spokeVnet.name
output spokeVnetId string = spokeVnet.id
output privateEndpointName string = blobPrivateEndpoint.name
output bastionName string = bastion.name
output dnsResolverName string = dnsResolver.name
output dnsResolverInboundEndpointIP string = '10.0.4.4'
