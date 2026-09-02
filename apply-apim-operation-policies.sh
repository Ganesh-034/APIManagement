#!/usr/bin/env bash
set -euo pipefail

RESOURCE_GROUP="${APIM_RESOURCE_GROUP:?APIM_RESOURCE_GROUP is required}"
APIM_NAME="${APIM_SERVICE_NAME:?APIM_SERVICE_NAME is required}"
API_ID="${APIM_API_ID:?APIM_API_ID is required}"
POLICY_FILE="${APIM_POLICY_FILE:?APIM_POLICY_FILE is required}"
API_VERSION="2024-05-01"

EXCLUDED_OPERATIONS=(
  "github-webhook"
)

if [ ! -f "${POLICY_FILE}" ]; then
  echo "##vso[task.logissue type=error]Policy file not found: ${POLICY_FILE}"
  exit 1
fi

if ! grep -q "<allowed-methods>" "${POLICY_FILE}"; then
  echo "##vso[task.logissue type=error]allowed-methods not found in ${POLICY_FILE}"
  exit 1
fi

SUBSCRIPTION_ID=$(az account show --query id --output tsv)

if [ -z "${SUBSCRIPTION_ID}" ]; then
  echo "##vso[task.logissue type=error]Unable to determine subscription ID"
  exit 1
fi

is_excluded() {
  local operation_id="$1"
  local excluded_operation

  for excluded_operation in "${EXCLUDED_OPERATIONS[@]}"; do
    if [ "${operation_id}" = "${excluded_operation}" ]; then
      return 0
    fi
  done

  return 1
}

echo "Fetching operations from API: ${API_ID}"

OPERATIONS=$(az apim api operation list \
  --resource-group "${RESOURCE_GROUP}" \
  --service-name "${APIM_NAME}" \
  --api-id "${API_ID}" \
  --query "[].[name,method,urlTemplate]" \
  --output tsv)

if [ -z "${OPERATIONS}" ]; then
  echo "##vso[task.logissue type=error]No operations found for API ${API_ID}"
  exit 1
fi

TOTAL=$(printf '%s\n' "${OPERATIONS}" | sed '/^[[:space:]]*$/d' | wc -l)

COUNT=0
APPLIED=0
VERIFIED=0
SKIPPED=0
FAILED=0

echo "Found ${TOTAL} operations."

while IFS=$'\t' read -r OPERATION_ID METHOD URL_TEMPLATE; do
  if [ -z "${OPERATION_ID}" ]; then
    continue
  fi

  COUNT=$((COUNT + 1))
  METHOD=$(printf '%s' "${METHOD}" | tr '[:lower:]' '[:upper:]')

  echo ""
  echo "=============================================="
  echo "[${COUNT}/${TOTAL}] ${OPERATION_ID}"
  echo "Method: ${METHOD}"
  echo "Path: ${URL_TEMPLATE}"
  echo "=============================================="

  if is_excluded "${OPERATION_ID}"; then
    echo "Skipping excluded operation: ${OPERATION_ID}"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  GENERATED_XML="${AGENT_TEMPDIRECTORY}/policy-${COUNT}.xml"
  BODY_FILE="${AGENT_TEMPDIRECTORY}/policy-${COUNT}.json"

  awk -v method="${METHOD}" '
    /<allowed-methods>/ {
      print "            <allowed-methods>"
      print "                <method>" method "</method>"

      if (method != "OPTIONS") {
        print "                <method>OPTIONS</method>"
      }

      if (method != "HEAD") {
        print "                <method>HEAD</method>"
      }

      in_allowed_methods = 1
      next
    }

    /<\/allowed-methods>/ {
      print "            </allowed-methods>"
      in_allowed_methods = 0
      next
    }

    in_allowed_methods {
      next
    }

    {
      print
    }
  ' "${POLICY_FILE}" > "${GENERATED_XML}"

  if ! grep -q "<method>${METHOD}</method>" "${GENERATED_XML}"; then
    echo "##vso[task.logissue type=error]Method generation failed for ${OPERATION_ID}"
    FAILED=$((FAILED + 1))
    continue
  fi

  if ! grep -q "<method>OPTIONS</method>" "${GENERATED_XML}"; then
    echo "##vso[task.logissue type=error]OPTIONS generation failed for ${OPERATION_ID}"
    FAILED=$((FAILED + 1))
    continue
  fi

  if ! grep -q "<method>HEAD</method>" "${GENERATED_XML}"; then
    echo "##vso[task.logissue type=error]HEAD generation failed for ${OPERATION_ID}"
    FAILED=$((FAILED + 1))
    continue
  fi

  jq -n \
    --rawfile policy "${GENERATED_XML}" \
    '{
      properties: {
        format: "rawxml",
        value: $policy
      }
    }' > "${BODY_FILE}"

  POLICY_URI="https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.ApiManagement/service/${APIM_NAME}/apis/${API_ID}/operations/${OPERATION_ID}/policies/policy?api-version=${API_VERSION}"

  echo "Applying ${METHOD} policy to ${OPERATION_ID}..."

  if ! az rest \
    --method PUT \
    --uri "${POLICY_URI}" \
    --headers "Content-Type=application/json" "If-Match=*" \
    --body "@${BODY_FILE}" \
    --output none; then

    echo "##vso[task.logissue type=error]Policy deployment failed for ${OPERATION_ID}"
    FAILED=$((FAILED + 1))
    continue
  fi

  APPLIED=$((APPLIED + 1))

  if ! POLICY_XML=$(az rest \
    --method GET \
    --uri "${POLICY_URI}" \
    --query "properties.value" \
    --output tsv); then

    echo "##vso[task.logissue type=error]Unable to retrieve policy for ${OPERATION_ID}"
    FAILED=$((FAILED + 1))
    continue
  fi

  OPERATION_FAILED=0

  for REQUIRED_VALUE in \
    "<cors" \
    "<validate-jwt" \
    "<rate-limit-by-key" \
    "<method>${METHOD}</method>" \
    "<method>OPTIONS</method>" \
    "<method>HEAD</method>"; do

    if ! grep -q "${REQUIRED_VALUE}" <<< "${POLICY_XML}"; then
      echo "##vso[task.logissue type=error]Missing ${REQUIRED_VALUE} for ${OPERATION_ID}"
      OPERATION_FAILED=1
    fi
  done

  if [ "${OPERATION_FAILED}" -eq 0 ]; then
    echo "Policy applied and verified successfully."
    VERIFIED=$((VERIFIED + 1))
  else
    FAILED=$((FAILED + 1))
  fi
done <<< "${OPERATIONS}"

echo ""
echo "=============================================="
echo "APIM Operation Policy Summary"
echo "=============================================="
echo "Total:    ${TOTAL}"
echo "Applied:  ${APPLIED}"
echo "Verified: ${VERIFIED}"
echo "Skipped:  ${SKIPPED}"
echo "Failed:   ${FAILED}"
echo "=============================================="

if [ "${FAILED}" -gt 0 ]; then
  exit 1
fi

echo "All applicable operation policies completed successfully done."
