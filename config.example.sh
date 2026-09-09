#!/usr/bin/env bash
# Copy to config.sh and fill in your own values:  cp config.example.sh config.sh
# config.sh is gitignored so tenant-specific IDs never get committed.

# ---- Azure subscription / tenant ------------------------------------------
export SUBSCRIPTION_ID="00000000-0000-0000-0000-000000000000"
export TENANT_DOMAIN="yourtenant.onmicrosoft.com"

# ---- Resource groups -------------------------------------------------------
# PROD holds the AVD host pool, workspace, networking and session hosts.
# IMAGE holds the Azure Compute Gallery and the golden-image build VM.
export RG_PROD="hackathon-prod"
export RG_IMAGE="hackathon-test"

# ---- Golden image (Azure Compute Gallery) ----------------------------------
export GALLERY_NAME="DiscoveryGallery"
export IMAGE_DEF="DiscoveryApp-W11"
export IMAGE_VERSION="1.0.0"

# ---- AVD objects -----------------------------------------------------------
export HOSTPOOL="hp-avd-hackathon"
export WORKSPACE="hackathon-wkspace01"
export APPGROUP="hp-avd-hackathon-DAG"

# ---- Identity --------------------------------------------------------------
export GROUP_NAME="HackathonUsers"

# ---- Session host sizing ---------------------------------------------------
# D8as_v5 = 8 vCPU / 32 GiB. D4as_v5 halves cost/quota and is fine for most users.
export VM_SIZE="Standard_D8as_v5"
export VM_ADMIN_USER="xadmin"
export VM_NAME_PREFIX="avd-hack"

# ---- Regions and networking ------------------------------------------------
# UK South = lowest latency for London users. Sweden Central = overflow capacity.
export REGION_PRIMARY="uksouth"
export VNET_PRIMARY="vn-avd-hackathon"
export SUBNET_PRIMARY="avdsubnet"

export REGION_SECONDARY="swedencentral"
export VNET_SECONDARY="vn-avd-hackathon-swc"
export SUBNET_SECONDARY="avdsubnet"
# ---- Shared file storage ---------------------------------------------------
# Storage account names are GLOBALLY unique across Azure: 3-24 chars, lowercase
# letters and digits only. Change this before the first run.
export STORAGE_ACCOUNT="sthackathonchangeme"
export STORAGE_CONTAINER="shared"

# Each region needs its own private DNS zone, and a zone name can exist only
# once per resource group - so the secondary zone gets a resource group of its
# own. See scripts/06-deploy-storage.sh.
export RG_DNS_SECONDARY="hackathon-dns-secondary"

# Group granted upload (write) access to the share. Everyone in GROUP_NAME gets
# read access. Leave empty to make the share read-only for all users.
export UPLOADER_GROUP_NAME=""
