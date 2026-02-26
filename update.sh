#!/bin/bash

# Make sure to select the correct CA set-id in your enforce_mtls.json file before running this script.
# you can find the CA set-id on API endpoint /mtls-edge-truststore/v2/ca-sets or look it up in Akamai Control Center under "Edge Certificates" > "mTLS Edge Truststore" section.
ENFORCE_MTLS_FILE="enforce_mtls.json"
OUTPUT_DIR="updated_rules"

# Define .edgerc section to be used.
SECTION="gss"

# 'ACCOUNTSWITCH="abc123:A-BCDEFG" ./update.sh' to use accountswitchkey option.
# or set hardcode in ACCOUNTSWITCH variable below. If not set, it will default to empty and no account switch will be used.
ACCOUNTSWITCH="${ACCOUNTSWITCH:-}"  # empty by default

# Optional: Comma-separated list of property names to update. If empty, all properties in the group will be used.
# Usage: PROPERTY_LIST="prop1,prop2,prop3" ./update.sh
PROPERTY_LIST="${PROPERTY_LIST:-}"  # empty by default

# Build account switch flag if set
ACCOUNT_SWITCHKEY=""
if [ -n "$ACCOUNTSWITCH" ]; then
  ACCOUNT_SWITCHKEY="--accountSwitchKey $ACCOUNTSWITCH"
fi

mkdir -p "$OUTPUT_DIR"

# Step 1: Get properties - either from provided list or fetch all properties for the group
if [ -z "$PROPERTY_LIST" ]; then
  # Get group and contract ID via "akamai property-manager list-groups --section <section>" command.
  GROUP_ID="grp_18543"
  CONTRACT_ID="ctr_1-5C13O2"
  
  echo "Fetching properties for group $GROUP_ID..."
  PROPERTIES=$(akamai property-manager list-properties \
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
  akamai property-manager show-ruletree \
    --section "$SECTION" \
    $ACCOUNT_SWITCHKEY \
    --property "$PROPERTY_NAME" \
    --format json > "$RULES_FILE"

  if [ $? -ne 0 ]; then
    echo "  ERROR: Failed to download rules for $PROPERTY_NAME, skipping..."
    continue
  fi

  # Step 4: Check if any mTLS-check has empty behaviors
  # jq explanation:
  # ..                                    - recursively walk entire JSON tree
  # | objects                             - only keep JSON objects
  # | select(                             - filter objects where:
  #     .name == "mTLS-check"             -   name equals "mTLS-check"
  #     and                               -   AND
  #     (.behaviors | length == 0)        -   behaviors array is empty
  #   )
  if jq -e '.. | objects | select(.name == "mTLS-check" and (.behaviors | length == 0))' "$RULES_FILE" > /dev/null 2>&1; then
    echo "  found mTLS-check with empty behavior, adding enforce_mtls..."

        # Step 5: add behavior to mTLS-check (only those with empty behaviors) and save updated rules to new file
        UPDATED_FILE="$OUTPUT_DIR/${PROPERTY_NAME}_updated_rules.json"
        jq --slurpfile enforce_mtls "$ENFORCE_MTLS_FILE" \
        '(.rules.children[] | .. | objects | select(.name == "mTLS-check" and (.behaviors | length == 0)) | .behaviors) = $enforce_mtls' \
        "$RULES_FILE" > "$UPDATED_FILE"

        if [ $? -ne 0 ]; then
          echo "  ERROR: Failed to update rules for $PROPERTY_NAME, skipping..."
          continue
        fi

        # Step 6: Push the updated rules back. This will create a new version of the property with the updated rules!
        echo "  Pushing updated rules..."
        akamai property-manager property-update \
        --section "$SECTION" \
        $ACCOUNT_SWITCHKEY \
        --property "$PROPERTY_NAME" \
        --file "$UPDATED_FILE" \
        --suppress \
        --note "Updated mTLS-check behavior via API call" 

        # Step 7: Activate the property after update (optional, can be done manually after verification)
        #  echo "  Activating property on staging..."
        #  akamai property-manager activate-version \
        #  --section "$SECTION" \
        #  $ACCOUNT_SWITCHKEY \
        #  --network staging \
        #  --property "$PROPERTY_NAME"

  else
    echo "  No mTLS-check with empty behavior found, skipping..."
  fi

done

echo ""
echo "Done processing all properties"