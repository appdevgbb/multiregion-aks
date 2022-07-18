targetScope = 'resourceGroup'
param prefix string 
param regionNum array
param location array
param lbFrontendIpConfigId1 string
param lbFrontendIpConfigId2 string

param privateDnsZoneName string = 'privdns.${prefix}'
param afdName string = 'afd-${prefix}'
param afdEndpointName string = prefix
param afdOriginGroupName string = prefix
param afdRouteName string = prefix
//var afdCustomDomainName = replace('${cnameRecordName}.${dnsZoneName}', '.', '-')
param afdWafPolicyName string = 'afdwaf${prefix}'
param afdSecurityPolicyName string = 'afd-secpol-${prefix}'

// Front Door Region One Backend
param aRecordNameOne string = regionNum[0]
param privateHostnameOne string = '${aRecordNameOne}.${privateDnsZoneName}'
param privateLinkServiceOneName string = '${prefix}-${regionNum[0]}-${location[0]}'
param vNetNameOne string = 'vnet-${prefix}-${regionNum[0]}'
param afdOriginOneName string = regionNum[0]

// Front Door Region Two Backend
param aRecordNameTwo string = regionNum[1]
param privateHostnameTwo string = '${aRecordNameTwo}.${privateDnsZoneName}'
param privateLinkServiceTwoName string = '${prefix}-${regionNum[1]}-${location[1]}'
param vNetNameTwo string = 'vnet-${prefix}-${regionNum[1]}'
param afdOriginTwoName string = regionNum[1]

var privateLinkOriginOneDetails = {
  privateLink: {
    id: privateLinkServiceOne.id
  }
  groupId: '' // Blank for Private Link Service
  privateLinkLocation: location[0]
  requestMessage: 'Private Link service from AFD'
}

var privateLinkOriginTwoDetails = {
  privateLink: {
    id: privateLinkServiceTwo.id
  }
  groupId: '' // Blank for Private Link Service
  privateLinkLocation: location[1]
  requestMessage: 'Private Link service from AFD'
}


resource vnetOne 'Microsoft.Network/virtualNetworks@2021-03-01' existing = {
  name: vNetNameOne

  resource snetPrivateLinkEndpoints 'subnets' existing = {
    name: 'snet-privatelinkservice' 
  }
}

resource vnetTwo 'Microsoft.Network/virtualNetworks@2021-03-01' existing = {
  name: vNetNameTwo

  resource snetPrivateLinkEndpoints 'subnets' existing = {
    name: 'snet-privatelinkservice' 
  }
}

resource privateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: privateDnsZoneName
  location: 'global'
}

resource privateDnsZoneLinkOne 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: privateDnsZone
  name: '${vnetOne.name}-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnetOne.id
    }
  }
}

resource privateDnsZoneLinkTwo 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: privateDnsZone
  name: '${vnetTwo.name}-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnetTwo.id
    }
  }
}


// IP hardcoded to 10.240.4.4 for AKS internal LB
resource aRecordOne 'Microsoft.Network/privateDnsZones/A@2020-06-01' = {
  name: aRecordNameOne
  parent: privateDnsZone
  properties: {
    aRecords: [
      {
        ipv4Address: '10.240.4.4'
      }
    ]
    ttl: 3600
  }
}

// IP hardcoded to 10.240.4.4 for AKS internal LB
resource aRecordTwo 'Microsoft.Network/privateDnsZones/A@2020-06-01' = {
  name: aRecordNameTwo
  parent: privateDnsZone
  properties: {
    aRecords: [
      {
        ipv4Address: '10.240.4.4'
      }
    ]
    ttl: 3600
  }
}

resource privateLinkServiceOne 'Microsoft.Network/privateLinkServices@2020-06-01' = {
  name: privateLinkServiceOneName
  location: location[0]
  properties: {
    enableProxyProtocol: false
    loadBalancerFrontendIpConfigurations: [
      {
        id: lbFrontendIpConfigId1
      }
    ]
    ipConfigurations: [
      {
        name: '${vnetOne::snetPrivateLinkEndpoints.name}-one'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          privateIPAddressVersion: 'IPv4'
          subnet: {
            id: vnetOne::snetPrivateLinkEndpoints.id
          }
          primary: true
        }
      }
    ]
  }
}

resource privateLinkServiceTwo 'Microsoft.Network/privateLinkServices@2020-06-01' = {
  name: privateLinkServiceTwoName
  location: location[1]
  properties: {
    enableProxyProtocol: false
    loadBalancerFrontendIpConfigurations: [
      {
        id: lbFrontendIpConfigId2
      }
    ]
    ipConfigurations: [
      {
        name: '${vnetTwo::snetPrivateLinkEndpoints.name}-one'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          privateIPAddressVersion: 'IPv4'
          subnet: {
            id: vnetTwo::snetPrivateLinkEndpoints.id
          }
          primary: true
        }
      }
    ]
  }
}

resource afdProfile 'Microsoft.Cdn/profiles@2021-06-01' = {
  name: afdName
  location: 'global'
  sku: {
    name: 'Premium_AzureFrontDoor'
  }
}

resource afdEndpoint 'Microsoft.Cdn/profiles/afdEndpoints@2021-06-01' = {
  name: afdEndpointName
  parent: afdProfile
  location: 'global'
  properties: {
    enabledState: 'Enabled'
  }
}

resource afdOriginGroup 'Microsoft.Cdn/profiles/originGroups@2021-06-01' = {
  name: afdOriginGroupName
  parent: afdProfile
  properties: {
    loadBalancingSettings: {
      sampleSize: 4
      successfulSamplesRequired: 2
      additionalLatencyInMilliseconds: 0
    }
    healthProbeSettings: {
      probePath: '/'
      probeRequestType: 'HEAD'
      probeProtocol: 'Http'
      probeIntervalInSeconds: 100
    }
  }
}

resource afdOriginOne 'Microsoft.Cdn/profiles/originGroups/origins@2021-06-01' = {
  name: afdOriginOneName
  parent: afdOriginGroup
  properties: {
    hostName: privateHostnameOne
    httpPort: 80
    httpsPort: 443
    originHostHeader: privateHostnameOne
    priority: 1
    weight: 1000
    sharedPrivateLinkResource: privateLinkOriginOneDetails
  }
}

resource afdOriginTwo 'Microsoft.Cdn/profiles/originGroups/origins@2021-06-01' = {
  name: afdOriginTwoName
  parent: afdOriginGroup
  properties: {
    hostName: privateHostnameTwo
    httpPort: 80
    httpsPort: 443
    originHostHeader: privateHostnameTwo
    priority: 1
    weight: 1000
    sharedPrivateLinkResource: privateLinkOriginTwoDetails
  }
}

resource afdRoute 'Microsoft.Cdn/profiles/afdEndpoints/routes@2021-06-01' = {
  name: afdRouteName
  parent: afdEndpoint
  dependsOn: [
    afdOriginOne // This explicit dependency is required to ensure that the origin group is not empty when the route is created.
    afdOriginTwo
  ]
  properties: {
    originGroup: {
      id: afdOriginGroup.id
    }
    supportedProtocols: [
      'Http'
      'Https'
    ]
    patternsToMatch: [
      '/*'
    ]
    forwardingProtocol: 'MatchRequest'
    linkToDefaultDomain: 'Enabled'
    httpsRedirect: 'Disabled'
  }
}

resource afdWafPolicy 'Microsoft.Network/FrontDoorWebApplicationFirewallPolicies@2020-11-01' = {
  name: afdWafPolicyName
  location: 'global'
  sku: {
    name: 'Premium_AzureFrontDoor'
  }
  properties: {
    policySettings: {
      enabledState: 'Enabled'
      mode: 'Detection'
    }
    managedRules: {
      managedRuleSets: [
        {
          ruleSetType: 'Microsoft_DefaultRuleSet'
          ruleSetVersion: '1.1'
        }
        {
          ruleSetType: 'Microsoft_BotManagerRuleSet'
          ruleSetVersion: '1.0'
        }
      ]
    }
  }
}

resource afdSecurityPolicy 'Microsoft.Cdn/profiles/securityPolicies@2021-06-01' = {
  parent: afdProfile
  name: afdSecurityPolicyName
  properties: {
    parameters: {
      type: 'WebApplicationFirewall'
      wafPolicy: {
        id: afdWafPolicy.id
      }
      associations: [
        {
          domains: [
            {
              id: afdEndpoint.id
            }
          ]
          patternsToMatch: [
            '/*'
          ]
        }
      ]
    }
  }
}

output frontDoorEndpointHostName string = afdEndpoint.properties.hostName
