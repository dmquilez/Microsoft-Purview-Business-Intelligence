targetScope = 'resourceGroup'

var rg = resourceGroup()

var subscription = az.subscription()
var baseName = uniqueString(resourceGroup().id)
var location = rg.location
var packageURL = 'https://github.com/dmquilez/Microsoft-Purview-Business-Intelligence/releases/latest/download/release.zip'
var keyVaultName = 'kv-${baseName}'

resource storageAccount 'Microsoft.Storage/storageAccounts@2021-06-01' = {
  name: '${toLower(baseName)}sa'
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
}


resource appServicePlan 'Microsoft.Web/serverfarms@2021-02-01' = {
  name: '${baseName}-asp'
  location: location
  sku: {
    name: 'Y1'
    tier: 'Dynamic'
  }
}

resource functionApp 'Microsoft.Web/sites@2022-03-01' = {
  name: '${baseName}-app'
  location: location
  kind: 'functionapp'
  identity: {
    type:'SystemAssigned'
  }
  properties: {
    serverFarmId: appServicePlan.id
    siteConfig: {
      appSettings: [
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'powershell'
        }
        {
          name: 'AzureWebJobsStorage'
          value: 'DefaultEndpointsProtocol=https;AccountName=${toLower(baseName)}sa;AccountKey=${listKeys(storageAccount.id, storageAccount.apiVersion).keys[0].value};EndpointSuffix=core.windows.net'
        }
        {
          name: 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING'
          value: 'DefaultEndpointsProtocol=https;AccountName=${toLower(baseName)}sa;AccountKey=${listKeys(storageAccount.id, storageAccount.apiVersion).keys[0].value};EndpointSuffix=core.windows.net'
        }
        {
          name: 'WEBSITE_CONTENTSHARE'
          value: toLower('${baseName}-content')
        }
      ]
    }
    httpsOnly: true
  }
}

resource keyVault 'Microsoft.KeyVault/vaults@2021-11-01-preview' = {
  name: keyVaultName
  location: rg.location
  properties: {
    accessPolicies: [
      {
        objectId: functionApp.identity.principalId
        tenantId: subscription.tenantId
        permissions: {
          certificates: [
            'create'
            'get'
          ]
          secrets: [
            'get'
          ]
        }
      }
    ]
    sku: {
      name: 'standard'
      family: 'A'
    }
    tenantId: subscription.tenantId
  }
  dependsOn: [
    functionApp
  ]
}

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: '${baseName}-la'
  location: location
}

resource applicationInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: '${baseName}-appi'
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
  }
}

resource config 'Microsoft.Web/sites/config@2022-03-01' = {
  parent: functionApp
  name: 'appsettings'
  properties: {
    APPINSIGHTS_INSTRUMENTATIONKEY: applicationInsights.properties.InstrumentationKey
    AzureWebJobsStorage: 'DefaultEndpointsProtocol=https;AccountName=${baseName}sa;EndpointSuffix=${environment().suffixes.storage};AccountKey=${storageAccount.listKeys().keys[0].value}'
    WEBSITE_CONTENTAZUREFILECONNECTIONSTRING: 'DefaultEndpointsProtocol=https;AccountName=${baseName}sa;EndpointSuffix=${environment().suffixes.storage};AccountKey=${storageAccount.listKeys().keys[0].value}'
    FUNCTIONS_WORKER_RUNTIME: 'powershell'
    FUNCTIONS_WORKER_RUNTIME_VERSION: '7.2'
    WEBSITE_CONTENTSHARE: toLower('${baseName}-app')
    SUBSCRIPTION_ID: subscription.subscriptionId
    Project: 'microsoft-purview-business-intelligence'
    WEBSITE_RUN_FROM_PACKAGE: packageURL
    FUNCTIONS_EXTENSION_VERSION: '~4'
    DEBUG: 'false'
    ACTIVITYEXPLORER_EXPORT_TABLENAME: 'ActivityExplorer'
    SIT_TABLENAME: 'SensitiveInformationTypes'
    SL_TABLENAME: 'SensitivityLabels'
    MANAGEDIDENTITY_PRINCIPALID: functionApp.identity.principalId
    KEYVAULT_NAME: keyVaultName
    ONMICROSOFT_DOMAIN: ''
    ADAppId: ''
  }
}
