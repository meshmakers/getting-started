# Ensure that you have logged in to identity services (e. g. om-login-local.ps1)

# Delete the clients
octo-cli -c DeleteClient --clientid octo-data-refinery-studio
octo-cli -c DeleteClient --clientid octo-template-app

