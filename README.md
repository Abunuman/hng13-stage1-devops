# HNG13 DevOps Stage 1: Automated Dockerized App Deployment Script

## TASK OBJECTIVE

Develop a robust, production-grade Bash script (deploy.sh) that automates the setup, deployment, and configuration of a Dockerized application on a remote Linux server.

This script streamlines DevOps workflows by handling repository management, Docker installation, environment preparation, container deployment, and reverse proxy configuration, all in one automated process.

## KEY FEATURES

- [x] User Input Validation: Collects and validates GitHub, SSH, and deployment parameters interactively.

- [x] Docker & NGINX Setup: Installs and configures required dependencies automatically.

- [x] Continuous Deployment: Handles git pulls, Docker builds, and container redeployments.

- [x] Reverse Proxy Configuration: Dynamically sets up NGINX to route traffic from port 80 to the application container.

- [x] Logging & Error Handling: Every action is logged with timestamps for easier debugging.

- [x] Idempotent Execution: Can safely re-run without breaking existing setups.

- [x] Cleanup Option: Optional --cleanup flag removes all deployed resources gracefully.

# SCRIPT WORKFLOW

### 1. Collect Parameters from User

Prompts for:

- Git Repository URL

- Personal Access Token (PAT)

- Branch name (defaults to main)

- SSH credentials (Username, Server IP, SSH Key path)

- Application internal port

### 2. Repository Setup

- Authenticates and clones the provided Git repository.

- If already cloned, pulls the latest changes.

- Checks for presence of a Dockerfile or docker-compose.yml.

### 3. Remote Server Preparation

- SSH into the target host.

- Updates system packages.

- Installs Docker, Docker Compose, and NGINX if missing.

- Adds user to Docker group and ensures all services are active.

### 4. Deploy Dockerized Application

- Transfers project files to remote server via scp or rsync.

- Builds and runs Docker containers (docker build or docker-compose up -d).

- Validates container health and ensures the app is accessible on the given port.

### 5. Configure NGINX as a Reverse Proxy

- Dynamically creates NGINX configuration for HTTP → container routing.

- Tests and reloads configuration.

- Ensures app is accessible on port 80 publicly.

### 6. Validation & Logging

Confirms:

- Docker service and target containers are running.

- NGINX is proxying correctly.

- Application responds to HTTP requests.

- Logs all actions to a file named deploy_YYYYMMDD.log.

### 7. Cleanup

Optionally run:

./deploy.sh --cleanup

Removes containers, networks, and NGINX config created during deployment.

## USAGE INSTRUCTION

- Make the script executable

`chmod +x deploy.sh`

- Run the script

`./deploy.sh`

- Follow the interactive prompts to complete setup and deployment.

## REPOSITORY STRUCTURE

.
├── deploy.sh # Main Bash deployment script
├── README.md # Project documentation
└── logs/ # Optional directory for deployment logs

## Author

**Toyyib Muhammad-Jamiu**

**Slack: @NerdRx**

**Track: DevOps – HNG Internship 13**
