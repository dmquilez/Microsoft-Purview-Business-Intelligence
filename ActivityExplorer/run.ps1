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

function responseRequest($body) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::OK
            Body       = $body
        })
}

# Export-ActivityExplorerData variables
$startTime = $Request.Query.StartTime
$endTime = $Request.Query.EndTime
$workload = $Request.Query.Workload
$activity = $Request.Query.Activity

$StorageContext = New-AzStorageContext -ConnectionString $storageConnectionString
$table = Get-AzStorageTable -Name $tableName -Context $StorageContext -ErrorVariable ev -ErrorAction SilentlyContinue
if ($ev) {
    responseRequest("Table $tableName doesn't exist. Please check your configuration or try again later after running the GetData action.")
}

# Interact with query parameters or the body of the request.
if (-not $startTime) {
    $startTime = $(Get-Date).AddDays(-7).ToString("yyyy-MM-ddTHH:mm:ssZ")
}else{
    $startTime = [DateTIme] $startTime
    $startTime = $startTime.ToString("yyyy-MM-ddTHH:mm:ssZ")
}

# Interact with query parameters or the body of the request.
if (-not $endTime) {
    $endTime = $(Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
}else{
    $endTime = [DateTIme] $endTime
    $endTime = $endTime.ToString("yyyy-MM-ddTHH:mm:ssZ")
}

#Define custom filter string
$customFilter = "Happened ge datetime'$startTime' and Happened le datetime'$endTime'"

# Check if additional parameters were included in the request
if ($workload) {
    $customFilter += " and PartitionKey eq '$workload'"
}

if ($activity) {
    $customFilter += " and Activity eq '$activity'"
}

$customFilter

$cloudTable = $table.CloudTable
$result = Get-AzTableRow `
    -table $cloudTable `
    -customFilter $customFilter

$table = Get-AzStorageTable -Name $sitTableName -Context $StorageContext -ErrorVariable ev -ErrorAction SilentlyContinue
$cloudTable = $table.CloudTable
$sitResult = Get-AzTableRow `
    -table $cloudTable `

$table = Get-AzStorageTable -Name $slTableName -Context $StorageContext -ErrorVariable ev -ErrorAction SilentlyContinue
$cloudTable = $table.CloudTable
$slResult = Get-AzTableRow `
    -table $cloudTable `

    foreach ($item in $result) {
    if ($item.EmailInfo) {
        $item.EmailInfo = $item.EmailInfo | ConvertFrom-Json
    }
    if ($item.PolicyMatchInfo) {
        $item.PolicyMatchInfo = $item.PolicyMatchInfo | ConvertFrom-Json
    }
    if ($item.SensitiveInfoTypeBucketsData) {
        $item.SensitiveInfoTypeBucketsData = $item.SensitiveInfoTypeBucketsData | ConvertFrom-Json
    }
    if ($item.SensitiveInfoTypeData) {
        $item.SensitiveInfoTypeData = $item.SensitiveInfoTypeData | ConvertFrom-Json
    }
    $item.Happened = $($item.Happened).ToString("yyyy-MM-ddTHH:mm:ssZ")
    
        foreach ($sit in $sitResult) {
            if ($item.SensitiveInfoTypeBucketsData.Id -eq $sit.RowKey) {
                $item.SensitiveInfoTypeBucketsData.Id = $sit.PartitionKey
            }
            if ($item.SensitiveInfoTypeData.SensitiveInfoTypeId -eq $sit.RowKey) {
                $item.SensitiveInfoTypeData.SensitiveInfoTypeId = $sit.PartitionKey
            }
        }
    if ($item.SensitivityLabel) {
        foreach ($sl in $slResult) {
            if ($item.SensitivityLabel -eq $sl.PartitionKey) {
                $item.SensitivityLabel = $sl.DisplayName
            }
        }
    }
    }


$result = $result | ConvertTo-Json -Depth 4
responseRequest($result)