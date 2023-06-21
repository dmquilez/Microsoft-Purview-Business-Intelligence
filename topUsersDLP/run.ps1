using namespace System.Net

# Input bindings are passed in via param block.
param($Request, $TriggerMetadata)

# Write to the Azure Functions log stream.
Write-Host "PowerShell HTTP trigger function processed a request."

# Azure Storage ENV variables
$storageConnectionString = [Environment]::GetEnvironmentVariable("AzureWebJobsStorage")
$tableName = [Environment]::GetEnvironmentVariable("ACTIVITYEXPLORER_EXPORT_TABLENAME")

# Associate values to output bindings by calling 'Push-OutputBinding'.
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
$topResults = $Request.Query.TopResults

$StorageContext = New-AzStorageContext -ConnectionString $storageConnectionString
$table = Get-AzStorageTable -Name $tableName -Context $StorageContext -ErrorVariable ev -ErrorAction SilentlyContinue
if ($ev) {
    responseRequest("Table $tableName doesn't exist. Please check your configuration or try again later after running the GetData action.")
}

# Interact with query parameters or the body of the request.
if (-not $startTime) {
    responseRequest("You must include a startTime paramater in your request.")
}
else {
    $startTime = [DateTime] $startTime
    $startTime = $startTime.ToString("yyyy-MM-ddTHH:mm:ssZ")
}

# Interact with query parameters or the body of the request.
if (-not $endTime) {
    $endTime = $(Get-Date).AddDays(-7).ToString("yyyy-MM-ddTHH:mm:ssZ")
}else {
    $endTime = [DateTime] $endTime
    $endTime = $endTime.ToString("yyyy-MM-ddTHH:mm:ssZ")
}

if (-not $topResults) {
    $topResults = 10
}

#Define custom filter string
$customFilter = "Happened ge datetime'$startTime' and Happened le datetime'$endTime' and Activity eq 'DLP rule matched'"

# Check if additional parameters were included in the request
if ($workload) {
    $customFilter += " and PartitionKey eq '$workload'"
}

$cloudTable = $table.CloudTable
$result = Get-AzTableRow `
    -table $cloudTable `
    -customFilter $customFilter


$usersActions = @()

foreach ($item in $result) {
    $jsonPolicyMatchInfo = $item.PolicyMatchInfo | ConvertFrom-Json
    $objectExists = $usersActions | Where-Object { $_.user -eq $item.User }
    if ($objectExists) {
        $objectExists.policiesMatched += $jsonPolicyMatchInfo
        $objectExists.count++
    }
    else {
        $usersActions += New-Object PSObject -property $([ordered]@{ 
                user            = $item.User
                count           = 1
                policiesMatched = @($jsonPolicyMatchInfo)
            })     
    }
}

$usersActions = $usersActions | Sort-Object { - $_.count } | Select-Object -First $topResults
$res = $usersActions | ConvertTo-Json
responseRequest($res)
