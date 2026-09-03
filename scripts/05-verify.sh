#!/usr/bin/env bash
# Health check: session host status, user assignments, group membership and quota.
set -euo pipefail
cd "$(dirname "$0")/.."
source ./config.sh

az account set --subscription "$SUBSCRIPTION_ID"

echo "==> Session hosts in $HOSTPOOL"
az rest --method get \
  --url "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG_PROD/providers/Microsoft.DesktopVirtualization/hostpools/$HOSTPOOL/sessionHosts?api-version=2024-04-03" \
  -o json | python3 -c "
import json, sys
d = json.load(sys.stdin)
rows = d.get('value', [])
if not rows:
    print('  (none registered yet)')
for v in rows:
    p = v['properties']
    print('  {:28} status={:12} user={}'.format(
        v['name'].split('/')[-1], p.get('status'), p.get('assignedUser') or '-'))
print('  total: {}'.format(len(rows)))
"

echo
echo "==> VM power state"
az vm list -g "$RG_PROD" -d --query "[].{name:name, region:location, power:powerState}" -o table

echo
echo "==> $GROUP_NAME membership"
az ad group member list -g "$GROUP_NAME" --query "[].userPrincipalName" -o tsv | sort | sed 's/^/  /'

echo
echo "==> DASv5 quota"
for r in "$REGION_PRIMARY" "$REGION_SECONDARY"; do
  echo "  $r:"
  az vm list-usage -l "$r" -o tsv --query "[?contains(localName,'DASv5')].[localName,currentValue,limit]" \
    | awk '{printf "    %s: %s / %s vCPUs\n", $1" "$2" "$3, $4, $5}'
done
