#!/bin/bash

# Docker Installation Script for Ubuntu
# Author: Juan Edwin Calizaya Llanos
# Date: 2025-07-29

set -e 

echo "Updating package list..."
sudo apt-get update

echo "Installing required packages..."
sudo apt-get install -y ca-certificates curl gnupg

echo "Creating directory for Docker GPG key..."
sudo install -m 0755 -d /etc/apt/keyrings

echo "Downloading Docker GPG key..."
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc

echo "Setting appropriate permissions for the GPG key..."
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo "Adding Docker repository to APT sources..."
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

echo "Updating package list with Docker repository..."
sudo apt-get update

echo "Installing Docker Engine and related components..."
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

echo "Enabling and starting the Docker service..."
sudo systemctl enable docker
sudo systemctl start docker

echo "Docker installation completed successfully."
echo "You can verify the installation by running: sudo docker version"
