#!/bin/bash

# Make sure to select the correct CA set-id in your enforce_mtls.json file before running this script.
# you can find the CA set-id on API endpoint /mtls-edge-truststore/v2/ca-sets or look it up in Akamai Control Center under "Edge Certificates" > "mTLS Edge Truststore" section.
ENFORCE_MTLS_FILE="enforce_mtls.json"
CUSTOM_RESPONSE_FILE="custom_response.json"
OUTPUT_DIR="updated_rules"

# Define .edgerc section to be used.
SECTION="gss"

# 'ACCOUNTSWITCH="abc123:A-BCDEFG" ./update.sh' to use accountswitchkey option.
# or set hardcode in ACCOUNTSWITCH variable below. If not set, it will default to empty and no account switch will be used.
ACCOUNTSWITCH="${ACCOUNTSWITCH:-}"  # empty by default

# Optional: Comma-separated list of property names to update. If empty, all properties in the group will be used.
# Usage: PROPERTY_LIST="prop1,prop2,prop3" ./update.sh
PROPERTY_LIST="${PROPERTY_LIST:-}"  # empty by default

# Optional: suppress Node.js deprecation warnings from Akamai CLI internals.
# Set to false to show warnings again.
# Usage: SUPPRESS_NODE_DEPRECATION_WARNINGS="false" ./update.sh
SUPPRESS_NODE_DEPRECATION_WARNINGS="${SUPPRESS_NODE_DEPRECATION_WARNINGS:-true}"

run_akamai() {
  if [ "$SUPPRESS_NODE_DEPRECATION_WARNINGS" = "true" ]; then
    NODE_OPTIONS="--no-deprecation" akamai "$@"
  else
    akamai "$@"
  fi
}

# Build account switch flag if set
ACCOUNT_SWITCHKEY=""
if [ -n "$ACCOUNTSWITCH" ]; then
  ACCOUNT_SWITCHKEY="--accountSwitchKey $ACCOUNTSWITCH"
fi

mkdir -p "$OUTPUT_DIR"

# Step 1: Get properties - either from provided list or fetch all properties for the group
# if you want to check all properties in the group, leave PROPERTY_LIST empty and make sure to set correct GROUP_ID and CONTRACT_ID below.
if [ -z "$PROPERTY_LIST" ]; then
  # Get group and contract ID via "akamai property-manager list-groups --section <section>" command.
  GROUP_ID="grp_18xxx"
  CONTRACT_ID="ctr_1-5Cyyyy"
  
  echo "Fetching properties for group $GROUP_ID..."
  PROPERTIES=$(run_akamai property-manager list-properties \
    --section "$SECTION" \
    $ACCOUNT_SWITCHKEY \
    --groupId "$GROUP_ID" \
    --contractId "$CONTRACT_ID" \
    --format json)
else
  echo "Using provided property list: $PROPERTY_LIST"
  # Convert comma-separated list to JSON array format
  PROPERTIES=$(echo "$PROPERTY_LIST" | tr ',' '\n' | jq -R '.' | jq -s 'map({propertyName: .})')
fi

# Step 2: Loop through each property
# echo "$PROPERTIES"
echo "$PROPERTIES" | jq -r '.[] | .propertyName' | \
while read -r PROPERTY_NAME; do
  echo ""
  echo "Processing property: $PROPERTY_NAME"

  # Step 3: Download the rules for this property
  RULES_FILE="$OUTPUT_DIR/${PROPERTY_NAME}_rules.json"
  run_akamai property-manager show-ruletree \
    --section "$SECTION" \
    $ACCOUNT_SWITCHKEY \
    --property "$PROPERTY_NAME" \
    --format json > "$RULES_FILE"

  if [ $? -ne 0 ]; then
    echo "  ERROR: Failed to download rules for $PROPERTY_NAME, skipping..."
    continue
  fi

  # Step 4: Check if any mTLS-check has empty behaviors. 
  # Only add the enforce_mtls behavior to those with empty behaviors, to avoid overwriting any existing behavior configurations.
  # jq explanation:
  # ..                                    - recursively walk entire JSON tree
  # | objects                             - only keep JSON objects
  # | select(                             - filter objects where:
  #     .name == "mTLS-check"             -   name equals "mTLS-check"
  #     and                               -   AND
  #     (.behaviors | length == 0)        -   behaviors array is empty
  #   )
  MTLS_EMPTY_COUNT=$(jq '[.. | objects | select(.name == "mTLS-check" and (.behaviors | length == 0))] | length' "$RULES_FILE")
  UPDATED_FILE="$OUTPUT_DIR/${PROPERTY_NAME}_updated_rules.json"
  TMP_UPDATED_FILE="$OUTPUT_DIR/${PROPERTY_NAME}_updated_rules.tmp.json"
  CHANGES_MADE="false"

  cp "$RULES_FILE" "$UPDATED_FILE"

  if [ "$MTLS_EMPTY_COUNT" -gt 0 ]; then
    echo "  found $MTLS_EMPTY_COUNT mTLS-check rule(s) with empty behavior, adding enforce_mtls..."

    # Step 5: add behavior to mTLS-check (only those with empty behaviors)
    jq --slurpfile enforce_mtls "$ENFORCE_MTLS_FILE" \
    '(.rules.children[] | .. | objects | select(.name == "mTLS-check" and (.behaviors | length == 0)) | .behaviors) = $enforce_mtls' \
    "$UPDATED_FILE" > "$TMP_UPDATED_FILE"

    if [ $? -ne 0 ]; then
      echo "  ERROR: Failed to update rules for $PROPERTY_NAME, skipping..."
      rm -f "$TMP_UPDATED_FILE" "$UPDATED_FILE"
      continue
    fi

    mv "$TMP_UPDATED_FILE" "$UPDATED_FILE"
    CHANGES_MADE="true"
  else
    echo "  No mTLS-check with empty behavior found. Checking Certificate invalid behavior anyway..."
  fi

  # Step 6: ensure "Certificate invalid" child behavior uses custom_response (not legacy customBehavior)
  CERT_INVALID_COUNT=$(jq '[.. | objects | select(.name == "mTLS-check") | .children[]? | select((.name | ascii_downcase) == "certificate invalid")] | length' "$UPDATED_FILE")
  CERT_INVALID_CUSTOM_COUNT=$(jq '[.. | objects | select(.name == "mTLS-check") | .children[]? | select((.name | ascii_downcase) == "certificate invalid") | select(any(.behaviors[]?; .name == "customBehavior"))] | length' "$UPDATED_FILE")

  echo "  Checking $CERT_INVALID_COUNT Certificate invalid child rule(s); $CERT_INVALID_CUSTOM_COUNT still use customBehavior."

  if [ "$CERT_INVALID_CUSTOM_COUNT" -gt 0 ]; then
    # For each mTLS-check -> child named "Certificate invalid" (case-insensitive),
    # replace the entire .behaviors array with a single behavior object from custom_response.json.
    jq --slurpfile custom_response "$CUSTOM_RESPONSE_FILE" \
    '(
      ..
      | objects
      | select(.name == "mTLS-check")
      | .children[]?
      | select((.name | ascii_downcase) == "certificate invalid")
      | .behaviors
    ) = [$custom_response[0]]' \
    "$UPDATED_FILE" > "$TMP_UPDATED_FILE"

    if [ $? -ne 0 ]; then
      echo "  ERROR: Failed to replace Certificate invalid behavior for $PROPERTY_NAME, skipping..."
      rm -f "$TMP_UPDATED_FILE" "$UPDATED_FILE"
      continue
    fi

    mv "$TMP_UPDATED_FILE" "$UPDATED_FILE"
    CHANGES_MADE="true"
    echo "  Replaced Certificate invalid behaviors with custom_response."
  elif [ "$CERT_INVALID_COUNT" -gt 0 ]; then
    echo "  Certificate invalid behavior already up to date."
  else
    echo "  No Certificate invalid child rule found under mTLS-check."
  fi

  # Step 7: Push only if at least one update changed the rule tree
  if [ "$CHANGES_MADE" = "true" ]; then
    echo "  Pushing updated rules..."
    run_akamai property-manager property-update \
    --section "$SECTION" \
    $ACCOUNT_SWITCHKEY \
    --property "$PROPERTY_NAME" \
    --file "$UPDATED_FILE" \
    --suppress \
    --note "Updated mTLS-check behavior via API call" > /dev/null
  else
    echo "  No changes required for $PROPERTY_NAME, skipping push."
    rm -f "$UPDATED_FILE"
  fi

  # Step 8: Activate the property after update (optional, can be done manually after verification)
  #  echo "  Activating property on staging..."
  #  akamai property-manager activate-version \
  #  --section "$SECTION" \
  #  $ACCOUNT_SWITCHKEY \
  #  --network staging \
  #  --property "$PROPERTY_NAME"

done

echo ""
echo "Done processing all properties"