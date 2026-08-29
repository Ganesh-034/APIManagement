#!/bin/bash
set -e

RESOURCE_GROUP="soc-watchtower-prod"
APIM_NAME="soc-watchtower-api"
API_ID="soc-watchtower-backend-dev-test"
OPERATION_ID="logout"
POLICY_FILE="../infra/global-policy.xml"         # path relative to this script's location
# ---------------------------------------

if [ ! -f "$POLICY_FILE" ]; then
  echo "❌ Policy file not found at: $POLICY_FILE"
  exit 1
fi

echo "Fetching method for operation: $OPERATION_ID ..."

METHOD=$(az apim api operation show \
  --resource-group "$RESOURCE_GROUP" \
  --service-name "$APIM_NAME" \
  --api-id "$API_ID" \
  --operation-id "$OPERATION_ID" \
  --query "method" -o tsv)

if [ -z "$METHOD" ]; then
  echo "❌ Could not find operation '$OPERATION_ID' — check the ID and try again."
  exit 1
fi

echo "Found method: $METHOD"
echo "Reading $POLICY_FILE and trimming <allowed-methods> to: $METHOD, OPTIONS, HEAD ..."

# Avoid duplicating HEAD if the operation's own method IS HEAD (or GET,
# where you might separately want HEAD anyway — but per your instruction,
# OPTIONS and HEAD are always included regardless of the endpoint's method).
TRIMMED_XML=$(awk -v method="$METHOD" '
  /<allowed-methods>/ {
    print "            <allowed-methods>"
    print "                <method>" method "</method>"
    if (method != "OPTIONS") print "                <method>OPTIONS</method>"
    if (method != "HEAD") print "                <method>HEAD</method>"
    in_block = 1
    next
  }
  /<\/allowed-methods>/ {
    print "            </allowed-methods>"
    in_block = 0
    next
  }
  in_block { next }
  { print }
' "$POLICY_FILE")

echo "Getting subscription ID ..."
SUBSCRIPTION_ID=$(az account show --query id -o tsv)

echo "Building REST request body (JSON-escaping the XML via Node) ..."

BODY_FILE="./_generated-policy-body-${OPERATION_ID}.json"
node -e "
const xml = \`${TRIMMED_XML}\`;
const body = { properties: { format: 'rawxml', value: xml } };
console.log(JSON.stringify(body));
" > "$BODY_FILE"

echo "Applying policy via Azure REST API ..."

az rest --method put \
  --uri "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.ApiManagement/service/${APIM_NAME}/apis/${API_ID}/operations/${OPERATION_ID}/policies/policy?api-version=2022-08-01" \
  --body "@${BODY_FILE}"

echo ""
echo "✅ Policy applied to '$OPERATION_ID' with <allowed-methods> set to: $METHOD, OPTIONS, HEAD"
echo "   Your original $POLICY_FILE on disk is unchanged."

rm -f "$BODY_FILE"

echo "   Go check it in the Portal to confirm."
