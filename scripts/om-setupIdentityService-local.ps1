# Ensure that you have logged in to identity services (om-login-local.ps1)

$client_Id = "octo-data-refinery-studio"
$uri =  "http://localhost:5011/"

octo-cli -c AddAuthorizationCodeClient --clienturi $uri --clientid $client_Id --redirectUri $uri --name "OctoMesh Data Refinery Studio"
octo-cli -c AddScopeToClient --clientid $client_Id --name "assetSystemAPI.full_access"
octo-cli -c AddScopeToClient --clientid $client_Id --name "identityAPI.full_access"
octo-cli -c AddScopeToClient --clientid $client_Id --name "botAPI.full_access"
octo-cli -c AddScopeToClient --clientid $client_Id --name "communicationSystemAPI.full_access"
octo-cli -c AddScopeToClient --clientid $client_Id --name "communicationTenantAPI.full_access"
octo-cli -c AddScopeToClient --clientid $client_Id --name "reportingSystemAPI.full_access"
octo-cli -c AddScopeToClient --clientid $client_Id --name "reportingTenantAPI.full_access"
