# Akamai Property mTLS Enforcement Update Script

This script automates the process of adding mTLS (mutual TLS) enforcement behaviors to Akamai properties that contain an `mTLS-check` rule with empty behaviors.

## Overview

The script performs the following operations:

- Fetches all properties for a specified group if PROPERTY_LIST is not defined
- Downloads the rule tree for each property in the list
- Identifies properties with an `mTLS-check` rule that has empty behaviors
- Adds the `enforceMtlsSettings` behavior to those rules
- Replaces `Certificate invalid` child rule behaviors under `mTLS-check` with the behavior from `custom_response.json`
- Saves the updated rule trees to the `updated_rules/` directory
- Creates a new property version with the new behavior added

## Prerequisites

### 1. Akamai CLI Installation

Install the Akamai CLI tool:

```bash
# macOS (using Homebrew)
brew install akamai

# Or download from: https://github.com/akamai/cli
```

### 2. Property Manager Plugin

Install the Property Manager CLI plugin:

```bash
akamai install property-manager
```

### 3. Akamai API Credentials

Configure your `.edgerc` file with your Akamai API credentials:

```ini
[gss]
client_secret = your-client-secret
host = your-host.luna.akamaiapis.net
access_token = your-access-token
client_token = your-client-token
```

Place this file in your home directory (`~/.edgerc`) or specify a custom location.

### 4. Additional Tools

Ensure you have `jq` installed for JSON processing:

```bash
# macOS
brew install jq

# Linux (Debian/Ubuntu)
apt-get install jq
```

## Configuration

### 1. Update Script Variables

Edit [update.sh](update.sh) and configure the following variables.
Group and Contract ID are required if you want to update all properties in a group:

```bash
SECTION="default"              # .edgerc section to use
GROUP_ID="grp_xxxxx"           # Your Akamai group ID
CONTRACT_ID="ctr_y-yyyyyy"     # Your Akamai contract ID
```

To find your group and contract IDs:

```bash
akamai property-manager list-groups --section <section>
```

### 2. Configure CA Set ID

**IMPORTANT:** Before running the script, you must configure the correct Certificate Authority (CA) Set ID in [enforce_mtls.json](enforce_mtls.json).

#### Finding Your CA Set ID

Use the Akamai API endpoint to retrieve available CA sets.

More info can be found here: https://techdocs.akamai.com/mtls-edge-truststore/reference/get-ca-sets

Or use the Akamai Control Center to find your CA Set ID under:

- **Certificate Provisioning System** → **mTLS Edge TrustStore** → **CA Sets**

#### Update enforce_mtls.json

Edit the `certificateAuthoritySet` array to include your CA Set ID:

```json
{
  "name": "enforceMtlsSettings",
  "options": {
    "certificateAuthoritySet": ["YOUR_CA_SET_ID"],
    "enableAuthSet": true,
    "enableDenyRequest": false,
    "enableOcspStatus": false,
    "enableCompleteClientCertificate": false,
    "clientCertificateAttributes": [],
    "edgeChecksTitle": "",
    "originChecksTitle": ""
  }
}
```

### 3. Configure Custom mTLS Failure Response

Edit [custom_response.json](custom_response.json) to define the behavior that should replace existing behaviors in the `Certificate invalid` child rule under `mTLS-check`.

Example:

```json
{
  "name": "constructResponse",
  "options": {
    "enabled": true,
    "responseCode": 403,
    "forceEviction": false,
    "ignorePurge": false,
    "body": "<html><body>Invalid Client Certificate</body></html>"
  }
}
```

## Usage

### Basic Usage

Run the script with your configured settings:

```bash
./update.sh
```

### With Account Switch Key

If you need to use an account switch key (for partner/multi-account access):

```bash
ACCOUNTSWITCH="X-YY-1234567:A-BCDEF" ./update.sh
```

Or hardcode it in the script by setting the `ACCOUNTSWITCH` variable.

### Update Specific Properties Only

By default, the script processes all properties in the configured group. To update only specific properties, use the `PROPERTY_LIST` variable with a comma-separated list of property names:

```bash
PROPERTY_LIST="property1,property2,property3" ./update.sh
```

This is useful when you:

- Want to test the script on a few properties before rolling out to all
- Only need to update a subset of properties
- Want to avoid the API call to fetch all properties from the group

### Combine With Account Switch Key

You can combine both options:

```bash
ACCOUNTSWITCH="X-YY-1234567:A-BCDEF" PROPERTY_LIST="property1,property2" ./update.sh
```

## Output

The script creates an `updated_rules/` directory containing:

- `{property_name}_rules.json` - Original rule tree for each processed property
- `{property_name}_updated_rules.json` - Updated rule tree with mTLS enforcement (only for properties where the behavior was added)

## How It Works

1. **Fetch Properties:** Retrieves all properties for the specified group and contract (or uses the provided PROPERTY_LIST)
2. **Download Rules:** Downloads the rule tree for each property
3. **Check for mTLS-check Rule:** Searches for rules named `mTLS-check` with empty behaviors
4. **Add Enforcement:** If found, adds the `enforceMtlsSettings` behavior from `enforce_mtls.json`
5. **Replace Invalid-Cert Behavior:** Replaces behaviors on the `Certificate invalid` child rule under `mTLS-check` with `custom_response.json`
6. **Save Updated Rules:** Writes the updated rule tree to `updated_rules/{property_name}_updated_rules.json`
7. **Push to Akamai:** Creates a new property version with the updated rules on the Akamai platform

## Important Notes

- The script only processes properties that have an `mTLS-check` rule with **empty behaviors**
- If a property has multiple `mTLS-check` rules, only those with empty behaviors are updated
- Properties with existing behaviors in the `mTLS-check` rule are skipped to prevent overwriting
- **The script automatically pushes changes to Akamai**, creating a new property version
- The new version is **not activated** - you must activate it manually on staging/production after verification
- Review the generated files in `updated_rules/` and test on staging before production activation

## Property Activation

The script automatically creates a new property version with the updated mTLS configuration, but it does **not** activate the new version. You must manually activate the property version after verification.

To activate a property on staging:

```bash
akamai property-manager activate-version \
  --section "$SECTION" \
  --network staging \
  --property "PROPERTY_NAME"
```

To activate on production:

```bash
akamai property-manager activate-version \
  --section "$SECTION" \
  --network production \
  --property "PROPERTY_NAME"
```

**Best Practice:** Always activate to staging first, test thoroughly, then activate to production.

## Troubleshooting

### Authentication Errors

- Verify your `.edgerc` file credentials
- Ensure the section name matches (`SECTION` variable)
- Check that your API credentials have the required permissions

### jq Errors

- Ensure `jq` is installed and in your PATH
- Validate that `enforce_mtls.json` contains valid JSON

### No Properties Found

- Verify `GROUP_ID` and `CONTRACT_ID` are correct
- Check that you have access to the specified group

## License

This script is provided as-is for use with Akamai properties.
