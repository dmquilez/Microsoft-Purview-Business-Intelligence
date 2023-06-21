using namespace System.Net

# Input bindings are passed in via param block.
param($Request, $TriggerMetadata)

# Write to the Azure Functions log stream.
Write-Host "PowerShell HTTP trigger function processed a request."

# Azure Storage ENV variables
$storageConnectionString = [Environment]::GetEnvironmentVariable("AzureWebJobsStorage")
$tableName = [Environment]::GetEnvironmentVariable("ACTIVITYEXPLORER_EXPORT_TABLENAME")
$sitTableName = [Environment]::GetEnvironmentVariable("SIT_TABLENAME")
$slTableName = [Environment]::GetEnvironmentVariable("SL_TABLENAME")
$keyVaultName = [Environment]::GetEnvironmentVariable("KEYVAULT_NAME")
$onMicrosoftDomain = [Environment]::GetEnvironmentVariable("ONMICROSOFT_DOMAIN")
$ADAppId = [Environment]::GetEnvironmentVariable("ADAppId")

# Export-ActivityExplorerData variables
$startTime = $Request.Query.StartTime
$endTime = $Request.Query.EndTime

if (-not $endTime) {
    $date = $(Get-Date).ToString("yyyy/MM/dd")
    $endTime = $date
}

$StorageContext = New-AzStorageContext -ConnectionString $storageConnectionString
Get-AzStorageTable -Name $tableName -Context $StorageContext -ErrorVariable ev -ErrorAction SilentlyContinue
if ($ev) {
    New-AzStorageTable -Name $tableName -Context $StorageContext
    if (-not $startTime) {
        $startTime = $(get-date).AddDays(-1).ToString("yyyy/MM/dd")
    }
}

Get-AzStorageTable -Name $sitTableName -Context $StorageContext -ErrorVariable ev -ErrorAction SilentlyContinue
if ($ev) {
    New-AzStorageTable -Name $sitTableName -Context $StorageContext
}

Get-AzStorageTable -Name $slTableName -Context $StorageContext -ErrorVariable ev -ErrorAction SilentlyContinue
if ($ev) {
    New-AzStorageTable -Name $slTableName -Context $StorageContext
}

$table = Get-AzStorageTable -Name $tableName -Context $StorageContext

if (-not $startTime) {
    $table = Get-AzStorageTable -Name $tableName -Context $StorageContext
    $cloudTable = $table.CloudTable
    $row = Get-AzTableRow `
        -table $cloudTable `
        -customFilter "(PartitionKey eq 'MPBI') and (RowKey eq 'lastTimeStamp')"
    if (!$row) {
        $startTime = $(get-date).AddDays(-1).ToString("yyyy/MM/dd")
    }
    else {
        $startTime = $($row.Happened).ToString("yyyy/MM/dd")
    }
}

# Get certificate for CBA authentication (Security & Compliance module)
Connect-AzAccount -Identity
$pfxSecret = Get-AzKeyVaultSecret -VaultName $keyVaultName -Name "MPBI-Identity" -AsPlainText
$secretByte = [Convert]::FromBase64String($pfxSecret)
$x509Cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList @(,$secretByte)
Connect-IPPSSession -AppId $ADAppId -Certificate $x509Cert -Organization $onMicrosoftDomain

$workloadOptions = @("Exchange", "SharePoint", "OneDrive", "MicrosoftTeams","Endpoint")
$lastPage = $true

foreach ($workload in $workloadOptions) {
    do {
        # Create a batch operation
        [Microsoft.Azure.Cosmos.Table.TableBatchOperation] $batchOperation = New-Object -TypeName Microsoft.Azure.Cosmos.Table.TableBatchOperation
        if (!$lastPage) {
            Write-Host 'Export-ActivityExplorerData (Workload: $workload) (StartTime: $startTime) (EndTime: $endTime) - From Watermark'
            $result = Export-ActivityExplorerData -StartTime $startTime -EndTime $endTime -Filter1 @("Workload",$workload) -PageSize 100 -PageCookie $watermark -OutputFormat Json
        }else{
            Write-Host 'Export-ActivityExplorerData (Workload: $workload) (StartTime: $startTime) (EndTime: $endTime)'
            $result = Export-ActivityExplorerData -StartTime $startTime -EndTime $endTime -Filter1 @("Workload",$workload) -PageSize 100 -OutputFormat Json
        }
        $lastPage = $result.LastPage
        $watermark = $result.Watermark
        $result = $result.ResultData | ConvertTo-Json
        $data = $result | ConvertFrom-Json | ConvertFrom-Json
        $lastTimeStamp = [DateTime] $startTime
        foreach ($item in $data) {
            # Array to store the keys
            $keyArray = @()
            $keys = $item.PSObject.Properties.Name
            $keyArray += $keys
            
            $entity = New-Object -TypeName "Microsoft.Azure.Cosmos.Table.DynamicTableEntity"
            $jsonObjKeys = @("EmailInfo", "SensitiveInfoTypeData", "SensitiveInfoTypeBucketsData", "PolicyMatchInfo")
            
            foreach ($key in $keyArray) {
                if ($jsonObjKeys -contains $key) {
                    $jsonObj = $item.$($key) | ConvertTo-Json
                    $entity.Properties.Add($key, $jsonObj)
                }
                else {
                    $entity.Properties.Add($key, $item.$($key))
                }
        
                # Set the PartitionKey and RowKey based on your data
                $entity.PartitionKey = $item.Workload
                $entity.RowKey = $item.RecordIdentity
            
                $lastHappened = [DateTime] $item.Happened
                if ($lastHappened -gt $lastTimeStamp) {
                    $lastTimeStamp = $lastHappened
                }
            }
            $batchOperation.InsertOrMerge($entity)
        }
        try {
            # check if $batchOperation is empty
            if ($batchOperation.Count -gt 0) {
                $table.CloudTable.ExecuteBatch($batchOperation)
            }          
        }
        catch {
            Write-Host $_.Exception.Message
            Get-PSSession | Remove-PSSession
            exit
        }
    } while (
        !$lastPage
    )
    
    $entity = New-Object -TypeName "Microsoft.Azure.Cosmos.Table.DynamicTableEntity"
    $entity.PartitionKey = "MPBI"
    $entity.RowKey = "lastTimeStamp"
    $entity.Properties.Add("Happened", $lastTimeStamp)
    $table.CloudTable.Execute([Microsoft.Azure.Cosmos.Table.TableOperation]::InsertOrReplace($entity))

}

$sitResult =  Get-DlpSensitiveInformationType
$slResult = Get-Label
Get-PSSession | Remove-PSSession

$table = Get-AzStorageTable -Name $sitTableName -Context $StorageContext

foreach($sit in $sitResult){
    $entity = New-Object -TypeName "Microsoft.Azure.Cosmos.Table.DynamicTableEntity"
    # Set the PartitionKey and RowKey based on your data
    $entity.PartitionKey = $sit.Name
    $entity.RowKey = $sit.Id
    $entity.Properties.Add("Type", $sit.Type)
    $entity.Properties.Add("Publisher", $sit.Publisher)
    $table.CloudTable.Execute([Microsoft.Azure.Cosmos.Table.TableOperation]::InsertOrReplace($entity))
}

$table = Get-AzStorageTable -Name $slTableName -Context $StorageContext

foreach($sl in $slResult){
    $entity = New-Object -TypeName "Microsoft.Azure.Cosmos.Table.DynamicTableEntity"
    # Set the PartitionKey and RowKey based on your data
    $entity.PartitionKey = $sl.Name
    $entity.RowKey = $sl.Priority
    $entity.Properties.Add("DisplayName", $sl.DisplayName)
    $entity.Properties.Add("ContentType", $sl.DisplayName)
    $table.CloudTable.Execute([Microsoft.Azure.Cosmos.Table.TableOperation]::InsertOrReplace($entity))
}

$body = "Data exported from Purview Activity Explorer ($startTime - $endTime) to Azure Storage Table successfully"

# Associate values to output bindings by calling 'Push-OutputBinding'.
Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body       = $body
    })
