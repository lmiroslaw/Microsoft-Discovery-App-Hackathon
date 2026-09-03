#!/usr/bin/env bash
# Pins a user to a specific session host, so they land on a known VM instead of
# waiting for automatic assignment on first connect.
#
# The AVD CLI extension has no session-host subcommand, so this uses the ARM REST
# API directly.
#
# Usage:
#   ./04-assign-session-hosts.sh scientist003 3      # user -> avd-hack-3
#   ./04-assign-session-hosts.sh partner1 swctest    # user -> avd-hack-swctest
#
# A personal desktop holds exactly ONE assigned user. Re-running with a different
# user reassigns the host.
set -euo pipefail
cd "$(dirname "$0")/.."
source ./config.sh

USER_PREFIX="${1:?usage: $0 <user-prefix> <vm-suffix>}"
VM_SUFFIX="${2:?usage: $0 <user-prefix> <vm-suffix>}"

UPN="${USER_PREFIX}@${TENANT_DOMAIN}"
SESSION_HOST="${VM_NAME_PREFIX}-${VM_SUFFIX}"

az account set --subscription "$SUBSCRIPTION_ID"

az rest --method patch \
  --url "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG_PROD/providers/Microsoft.DesktopVirtualization/hostpools/$HOSTPOOL/sessionHosts/${SESSION_HOST}?api-version=2024-04-03" \
  --body "{\"properties\": {\"assignedUser\": \"$UPN\"}}" \
  --query "properties.assignedUser" -o tsv

echo "Assigned $UPN -> $SESSION_HOST"
