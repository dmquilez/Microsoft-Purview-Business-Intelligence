Import-Module Az.Accounts
Import-Module AzureADPreview
Import-Module Microsoft.Graph.Authentication
Write-Host "[!] Please login with an account authorized to do the following actions: Azure Key Vault certificate creation and configuration, Azure AD Applications creation and configuration." -f Blue
Write-Host "[!] A login screen will be prompted..." -f Blue
Connect-AzAccount

Write-Host "[!] Connected!" -f Green
"Getting context for AAD and MS Graph auth..."
$context = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile.DefaultContext
$graphToken = [Microsoft.Azure.Commands.Common.Authentication.AzureSession]::Instance.AuthenticationFactory.Authenticate($context.Account, $context.Environment, $context.Tenant.Id.ToString(), $null, [Microsoft.Azure.Commands.Common.Authentication.ShowDialog]::Never, $null, "https://graph.microsoft.com").AccessToken
$aadToken = [Microsoft.Azure.Commands.Common.Authentication.AzureSession]::Instance.AuthenticationFactory.Authenticate($context.Account, $context.Environment, $context.Tenant.Id.ToString(), $null, [Microsoft.Azure.Commands.Common.Authentication.ShowDialog]::Never, $null, "https://graph.windows.net").AccessToken

try {
	Write-Host "[!] Connecting to Azure AD..." -f Blue
	Connect-AzureAD -AadAccessToken $aadToken -AccountId $context.Account.Id -TenantId $context.tenant.id
	# Get the currently logged-in user
	$user = (Get-AzADUser -UserPrincipalName (Get-AzContext).Account.Id)
	$objectId = $user.Id
}
catch {
	Write-Host $_.Exception.Message -f Red
	Exit
}

try {
	$functionapps = @(Get-AzFunctionApp)
	$appSettings = @{}

	Write-Host "[!] Select the Function Web App to use for CBA:" -f Blue
	for ($i = 0; $i -lt $functionapps.Count; $i++) {
		Write-Host "[$i]: $($functionapps[$i].Name)"
	}
	$functionWebAppIndex = Read-Host "Select the Function App to use for CBA (0-$(($functionapps.Count - 1))):"
	if ($functionWebAppIndex -lt 0 -or $functionWebAppIndex -ge $functionapps.Count) {
		Write-Host "[X] Invalid Function Web App index selected. Exiting..." -f Red
		Exit
	}
	$webapp = Get-AzWebApp -ResourceGroupName $($functionapps[$functionWebAppIndex]).ResourceGroup -Name $($functionapps[$functionWebAppIndex]).Name
	ForEach ($item in $webapp.SiteConfig.AppSettings) {
		$appSettings.Add($item.Name, $item.Value)
	}
}
catch {
	Write-Host $_.Exception.Message -f Red
	Exit
}

$keyVaults = @(Get-AzKeyVault)
Write-Host "[!] Select the Key Vault to use for the certificate creation and configuration:" -f Blue
for ($i = 0; $i -lt $keyVaults.Count; $i++) {
	Write-Host "[$i]: $($keyVaults[$i].VaultName)"
}
$keyVaultIndex = Read-Host "Select the Key Vault to use for the certificate creation and configuration (0-$(($keyVaults.Count - 1))):"
if ($keyVaultIndex -lt 0 -or $keyVaultIndex -ge $keyVaults.Count) {
	Write-Host "[X] Invalid Key Vault index selected. Exiting..." -f Red
	Exit
}
$keyVaultName = $keyVaults[$keyVaultIndex].VaultName

$keyVault = Get-AzKeyVault -VaultName $keyVaultName
$accessPolicies = $keyVault.AccessPolicies
$userPolicy = $accessPolicies | Where-Object { $_.ObjectId -eq $objectId }
$hasGetPermission = $userPolicy.PermissionsToCertificates -contains 'get'
$hasCreatePermission = $userPolicy.PermissionsToCertificates -contains 'create'
$hasGetSecretsPermission = $userPolicy.PermissionsToSecrets -contains 'get'

Write-Host "[!] Checking if user has permissions on Azure Key Vault ($keyVaultName)..." -f Blue
if (-not ($hasGetPermission -and $hasCreatePermission -and $hasGetSecretsPermission)) {
	Write-Host "[!] User does not have permissions on Azure Key Vault ($keyVaultName)..." -f Yellow
	Write-Host "[!] Assigning permissions: certificates (create,get) and secrets (get)..." -f Blue
    Set-AzKeyVaultAccessPolicy -VaultName $keyVaultName -ObjectId $objectId -PermissionsToCertificates get,create -PermissionsToSecrets get
	Write-Host "[!] Waiting for permissions to propagate..." -f Yellow
    Start-Sleep -Seconds 10
}

try {
	$certificateName = "MPBI-Identity"
	Write-Host "[!] Creating certificate ($certificateName) in Azure Key Vault ($keyVaultName)..." -f Blue
	$certificatePolicy = New-AzKeyVaultCertificatePolicy -SubjectName "CN=$certificateName" -IssuerName Self -ValidityInMonths 12
	Add-AzKeyVaultCertificate -VaultName $keyVaultName -Name $certificateName -CertificatePolicy $certificatePolicy
}
catch {
	Write-Host $_.Exception.Message -f Red
	Exit
}

try {
	Write-Host "[!] Getting onmicrosoft domain and adding it to App Settings of the Azure function ($($webapp.Name))..." -f Blue
	$tenant = Get-AzureADTenantDetail
	$onmicrosoftDomain = $tenant.VerifiedDomains | Where-Object { $_.Name -like '*.onmicrosoft.com' -and (-not ($_.Name -like '*.mail.onmicrosoft.com')) }
	$appSettings['ONMICROSOFT_DOMAIN'] = $onmicrosoftDomain.Name
}
catch {
	Write-Host $_.Exception.Message -f Red
	Exit
}

try {
	$appName = "MPBI-Identity"
	$replyUrl = "https://localhost"
	Write-Host "[!] Creating Azure AD application ($appname)..." -f Blue
	$appRegistration = New-AzureADApplication -DisplayName $appName -ReplyUrls $replyUrl
	$appSettings['ADAppId'] = $appRegistration.AppId
	Write-Host "[!] Updating Function Web App settings with Azure AD App Id ($($webapp.Name))..." -f Blue
	Set-AzWebApp -ResourceGroupName $webapp.ResourceGroup -Name $webapp.Name -AppSettings $appSettings
}
catch {
	Write-Host $_.Exception.Message -f Red
	Exit
}

try {
	Write-Host "[!] Connecting to MS Graph..." -f Blue
	Connect-MgGraph -AccessToken $graphToken
}
catch {
	Write-Host $_.Exception.Message -f Red
	Exit
}
	
try {
	Write-Host "[!] Getting certificate ($certificateName) from Azure Key Vault ($keyVaultName)..." -f Blue
	$pfxSecret = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name $certificateName -AsPlainText
	$secretByte = [Convert]::FromBase64String($pfxSecret)
	$x509Cert = New-Object Security.Cryptography.X509Certificates.X509Certificate2
	$x509Cert.Import($secretByte, $null, [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable)
	
	$cerBytes = $x509Cert.Export('Cer')
	$cerBytes64 = [System.Convert]::ToBase64String($cerBytes)
	
	$params = @{
		keyCredentials = @(
			@{
				endDateTime   = $x509Cert.NotAfter
				startDateTime = $x509Cert.GetEffectiveDateString()
				type          = "AsymmetricX509Cert"
				usage         = "Verify"
				key           = [System.Text.Encoding]::ASCII.GetBytes($cerBytes64)
				displayName   = "CN=$certificateName"
			}
		)
	}
	
	Write-Host "[!] Updating Azure AD application ($appname) with certificate ($certificateName) for CBA auth..." -f Blue
	Update-MgApplication -ApplicationId $appRegistration.ObjectId -BodyParameter $params
}
catch {
	Write-Host $_.Exception.Message -f Red
	Exit
}
	
try {
	Write-Host "[!] Updating API permissions for Azure AD application ($appname) to allow Exchange.ManageAsApp permission..." -f Blue
	$resourceAppId = "00000002-0000-0ff1-ce00-000000000000"
	$roleObjectId = "dc50a0fb-09a3-484d-be87-e023b12c6440"
	$resourceAccess = New-Object -TypeName Microsoft.Open.AzureAD.Model.RequiredResourceAccess
	$resourceAccess.ResourceAppId = $resourceAppId
	$role = New-Object -TypeName Microsoft.Open.AzureAD.Model.ResourceAccess
	$role.Id = $roleObjectId
	$role.Type = "Role"
	$resourceAccess.ResourceAccess = $role
	Set-AzureADApplication -ObjectId $appRegistration.ObjectId -RequiredResourceAccess $resourceAccess
}
catch {
	Write-Host $_.Exception.Message -f Red
	Exit
}
	 
Write-Host "[OK] Execution completed!" -f Green
Write-Host "[!] Please, grant admin consent for Azure AD Application API permissions at: https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/Overview/appId/$($appRegistration.AppId)/isMSAApp~/false" -f Yellow
