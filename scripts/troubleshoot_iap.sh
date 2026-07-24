#!/bin/bash
# Troubleshoot IAP Connection Issues
# Usage: ./troubleshoot_iap.sh <project-id> <zone> <instance-name>

set -e

PROJECT_ID="${1:-}"
ZONE="${2:-}"
INSTANCE_NAME="${3:-}"

if [ -z "$PROJECT_ID" ] || [ -z "$ZONE" ] || [ -z "$INSTANCE_NAME" ]; then
    echo "❌ Usage: $0 <project-id> <zone> <instance-name>"
    echo ""
    echo "Example:"
    echo "  $0 my-project us-central1-f test-vm"
    exit 1
fi

echo "🔍 IAP Troubleshooting for: $INSTANCE_NAME"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check 1: gcloud installed and authenticated
echo "✓ Check 1: gcloud CLI"
if ! command -v gcloud &> /dev/null; then
    echo "  ❌ gcloud not found. Install: https://cloud.google.com/sdk/docs/install"
    exit 1
fi

if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q .; then
    echo "  ❌ Not authenticated. Run: gcloud auth login"
    exit 1
fi
echo "  ✓ gcloud installed and authenticated"
echo ""

# Check 2: Instance exists and is running
echo "✓ Check 2: Instance Status"
INSTANCE_STATUS=$(gcloud compute instances describe "$INSTANCE_NAME" \
    --project="$PROJECT_ID" \
    --zone="$ZONE" \
    --format="value(status)" 2>/dev/null || echo "NOT_FOUND")

if [ "$INSTANCE_STATUS" = "NOT_FOUND" ]; then
    echo "  ❌ Instance '$INSTANCE_NAME' not found in zone '$ZONE'"
    exit 1
fi

if [ "$INSTANCE_STATUS" != "RUNNING" ]; then
    echo "  ⚠️  Instance is $INSTANCE_STATUS (must be RUNNING for IAP)"
    exit 1
fi
echo "  ✓ Instance is RUNNING"
echo ""

# Check 3: IAP API enabled
echo "✓ Check 3: IAP API Status"
IAP_ENABLED=$(gcloud services list --enabled \
    --project="$PROJECT_ID" \
    --filter="name:iap.googleapis.com" \
    --format="value(name)" 2>/dev/null || echo "")

if [ -z "$IAP_ENABLED" ]; then
    echo "  ❌ IAP API is NOT enabled"
    echo ""
    echo "  To enable:"
    echo "  → gcloud services enable iap.googleapis.com --project=$PROJECT_ID"
    echo ""
    echo "  Or via Console:"
    echo "  → https://console.cloud.google.com/apis/library/iap.googleapis.com?project=$PROJECT_ID"
    exit 1
fi
echo "  ✓ IAP API is enabled"
echo ""

# Check 4: Firewall rules for IAP
echo "✓ Check 4: Firewall Rules for IAP"
echo "  IAP uses source IP range: 35.235.240.0/20"

FIREWALL_RULES=$(gcloud compute firewall-rules list \
    --project="$PROJECT_ID" \
    --filter="sourceRanges:35.235.240.0/20" \
    --format="table(name,allowed[].map().firewall_rule().list())" 2>/dev/null || echo "")

if [ -z "$FIREWALL_RULES" ]; then
    echo "  ⚠️  No firewall rules found for IAP source range"
    echo ""
    echo "  Create a firewall rule:"
    echo "  → gcloud compute firewall-rules create allow-iap-rdp \\"
    echo "      --project=$PROJECT_ID \\"
    echo "      --direction=INGRESS \\"
    echo "      --action=ALLOW \\"
    echo "      --rules=tcp:3389 \\"
    echo "      --source-ranges=35.235.240.0/20"
else
    echo "  ✓ Firewall rules exist:"
    echo "$FIREWALL_RULES" | sed 's/^/    /'
fi
echo ""

# Check 5: Permissions
echo "✓ Check 5: IAP Permissions"
CURRENT_USER=$(gcloud config get-value account 2>/dev/null)
echo "  Current user: $CURRENT_USER"

# Try to test tunnel (will fail if no permissions)
echo "  Testing tunnel creation (will timeout after 5s)..."
timeout 5s gcloud compute start-iap-tunnel "$INSTANCE_NAME" 3389 \
    --project="$PROJECT_ID" \
    --zone="$ZONE" \
    --local-host-port=localhost:0 2>&1 | head -5 || true

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📋 Summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "If tunnel still fails, check:"
echo "  1. IAP permissions: roles/iap.tunnelResourceAccessor"
echo "  2. Compute permissions: roles/compute.instanceAdmin.v1"
echo "  3. Network tags on the instance match firewall rules"
echo "  4. VM has network connectivity"
echo ""
echo "Quick fix command:"
echo "  gcloud services enable iap.googleapis.com --project=$PROJECT_ID"
echo ""
