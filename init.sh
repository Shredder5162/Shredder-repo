#!/bin/bash

# Error handling and logging
set -e
exec 1> >(logger -s -t $(basename $0)) 2>&1

# Root operations
sudo apt-get update
sudo apt-get install -y curl jq pwgen unzip

# Install Azure CLI
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

# Create runner user with password
RUNNER_USER="github-runner"
RUNNER_DIR="/actions-runner"
RUNNER_PASSWORD=$(pwgen -s 20 1)

# Create user and directories
sudo useradd -m -s /bin/bash $RUNNER_USER
echo "$RUNNER_USER:$RUNNER_PASSWORD" | sudo chpasswd
sudo usermod -aG sudo $RUNNER_USER
sudo mkdir -p $RUNNER_DIR
sudo chown -R $RUNNER_USER:$RUNNER_USER $RUNNER_DIR

# Switch to runner user for setup - note the EOF is not quoted now
sudo -u $RUNNER_USER bash << EOF
RUNNER_DIR="/actions-runner"
cd \$RUNNER_DIR

# Get GitHub token and configure
az login --identity
GITHUB_TOKEN=\$(az keyvault secret show --name "github-pat" --vault-name "${keyvault_name}" --query "value" -o tsv)

# Get registration token
TOKEN=\$(curl -L -X POST \\
  -H "Accept: application/vnd.github+json" \\
  -H "Authorization: Bearer \$GITHUB_TOKEN" \\
  -H "X-GitHub-Api-Version: 2022-11-28" \\
  "https://api.github.com/orgs/${github_organization}/actions/runners/registration-token" | jq -r '.token')

# Download and extract runner
curl -o actions-runner-linux-x64-2.321.0.tar.gz -L https://github.com/actions/runner/releases/download/v2.321.0/actions-runner-linux-x64-2.321.0.tar.gz
tar xzf ./actions-runner-linux-x64-2.321.0.tar.gz

# Configure runner
./config.sh --unattended \\
    --url "https://github.com/${github_organization}" \\
    --token "\$TOKEN" \\
    --name "\$HOSTNAME" \\
    --runnergroup "${runner_group_name}" \\
    --labels "azure-vmss" \\
    --work "_work" \\
    --ephemeral \\
    --replace
EOF

# Install and start service
cd $RUNNER_DIR
sudo ./svc.sh install $RUNNER_USER
sudo ./svc.sh start
