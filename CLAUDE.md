# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository provides setup scripts and Docker Compose configurations for deploying the OctoMesh platform locally. OctoMesh is a platform with identity services, asset repository services, bot services, and various other microservices.

## Common Commands

All commands must be run from the `scripts/` directory using PowerShell 7.1+.

### Installation and Startup
```pwsh
# Install OctoMesh (core profile - default)
./om-install.ps1

# Install with full profile (includes Data Refinery Studio and Reporting Services)
./om-install.ps1 -DeploymentProfile full

# Install with simulation adapter
./om-install.ps1 -IncludeSimulation

# Install with full profile and simulation adapter
./om-install.ps1 -DeploymentProfile full -IncludeSimulation

# Start containers after stopping
./om-start.ps1
./om-start.ps1 -DeploymentProfile full
./om-start.ps1 -IncludeSimulation

# Stop containers
./om-stop.ps1
./om-stop.ps1 -DeploymentProfile full
./om-stop.ps1 -IncludeSimulation

# Uninstall (removes containers and volumes)
./om-uninstall.ps1
```

### Authentication
```pwsh
# Login to CLI (default tenant: meshtest)
./om-login-local.ps1

# Login with custom tenant
./om-login-local.ps1 -tenantId "mytenant"

# Login with reporting services enabled
./om-login-local.ps1 -includeReporting $true
```

### Setup Identity Service (full profile only)
```pwsh
./om-setupIdentityService-local.ps1
```

## Architecture

### Docker Infrastructure

The platform runs as Docker containers orchestrated by `scripts/octo-mesh/docker-compose.yml`:

- **Databases**:
  - MongoDB 8.0 replica set (3 nodes: ports 27017-27019)
  - CrateDB 5.10 cluster (3 nodes: admin ports 4301-4303, PostgreSQL ports 5432-5434)
- **Message Broker**: RabbitMQ 4.0 (ports 5672, 15672)
- **OctoMesh Services** (all meshmakers Docker images):
  - Identity Services (port 5003)
  - Asset Repository Services (port 5001)
  - Bot Services (port 5009)
  - Communication Controller Services (port 5015)
  - Mesh Adapter (port 5021)
  - Reporting Services (port 5007) - full profile only
  - Data Refinery Studio (port 5011) - full profile only
  - Simulation Adapter (port 5023) - `-IncludeSimulation` switch only

### Deployment Profiles

- `core` (default): All services except Data Refinery Studio and Reporting Services
- `full`: All services including Data Refinery Studio and Reporting Services
- `-IncludeSimulation` switch: Adds Simulation Adapter to any profile

### Environment Configuration

- `scripts/octo-mesh/.env` - Version configuration (tracked)
- `scripts/octo-mesh/.env.local` - Local secrets and passwords (not tracked, see `.env.local.example`)

## Prerequisites

- Docker Desktop 4.29+
- PowerShell 7.1+
- openssl (in PATH)
- octo-cli (`choco install octo-cli`)
- Host entry: `127.0.0.1 octo-identity-services` in /etc/hosts

## Key URLs (after installation)

- Identity Services: https://octo-identity-services:5003/
- GraphQL Playground: https://localhost:5001/tenants/octosystem/graphql/playground
- Bot Dashboard: https://localhost:5009/ui/jobs
- Data Refinery Studio: https://localhost:5011/ (full profile)
- Simulation Adapter: https://localhost:5023/ (`-IncludeSimulation`)
