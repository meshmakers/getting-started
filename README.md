# Getting started with OctoMesh

This readme provides an overview of the OctoMesh platform and how to get started with the OctoMesh CLI.

## Scripts Overview

The `scripts/` folder contains PowerShell scripts to manage the OctoMesh platform:

| Script               | Description                                                                                                                                                                                 |
|----------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `om-install.ps1`     | Installs and configures the OctoMesh platform. Prompts for version selection and license keys, creates SSL certificates, starts Docker containers, and initializes the MongoDB replica set. |
| `om-start.ps1`       | Starts the OctoMesh Docker containers after they have been stopped.                                                                                                                         |
| `om-stop.ps1`        | Stops all running OctoMesh Docker containers without removing data.                                                                                                                         |
| `om-uninstall.ps1`   | Completely removes the OctoMesh platform including all Docker containers and volumes.                                                                                                       |
| `om-login-local.ps1` | Configures the octo-cli for the local environment and initiates an interactive login.                                                                                                       |

## Clone the repository

Clone the repository to your local machine using:

```bash
# using http
https://github.com/meshmakers/getting-started.git
# using ssh
git@github.com:meshmakers/getting-started.git
```

## Prepare your environment

Before you begin, ensure you have the following installed:
* Docker Desktop (4.29+)
* Powershell (7.1+)
* openssl

Edit /etc/hosts or C:\Windows\System32\drivers\etc\hosts file and add the following entry:

```bash
# OctoMesh Identity Services
127.0.0.1 octo-identity-services
# end OctoMesh Identity Services
```

IMPORTANT: Ensure that openssl is available in your PATH: 
```bash
openssl
```

## Install octo-cli
octo-cli is a command-line interface (CLI) tool that allows you to interact with the OctoMesh platform from your terminal. It provides a set of commands that you can use to create, manage, and deploy your OctoMesh applications.

```pwsh
# Install the OctoMesh CLI
choco install octo-cli
```

Ensure that octo-cli installed successfully by running the following command:

```pwsh
octo-cli
```

## Start the OctoMesh platform

Navigate to the root directory of the cloned repository and run the following command:

```pswsh
cd scripts
./om-install.ps1
```
This command will start the OctoMesh platform with mongodb and crate databases, and the OctoMesh services.

## Install the certificate 

In the infrastructure folder, the install script created certificates. To allow the tools to connect to the platform, install the certificate into the local certificate store.

## Log-In to OctoMesh

Navigate to https://octo-identity-services:5003/ in your browser to view the OctoMesh platform.

Use an email and password to register the admin user. Please note that the email must be a valid email address, but it does not have to be a real email address.

## Log-In to OctoMesh CLI
Run the following command to log in to the OctoMesh CLI:

```pwsh
./om-login-local.ps1
```

## URIS
- OctoMesh Identity Services: https://octo-identity-services:5003/
- OctoMesh Repository Playground for system tenant: https://localhost:5001/tenants/octosystem/graphql/playground
- OctoMesh Admin Panel: https://localhost:5005/
- OctoMesh Data Refinery Studio: https://localhost:5011/
- OctoMesh Bot Dashboard: https://localhost:5009/ui/jobs

# Further Reading
- [OctoMesh Documentation](https://docs.meshmakers.cloud)

## Uninstall
To uninstall the OctoMesh platform, run the following command:

```pwsh
./om-uninstall.ps1
```

