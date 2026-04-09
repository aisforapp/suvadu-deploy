#!/bin/bash
# Suvadu Cloud Deploy — provisions Cloud Run + GCS in your Google Cloud account.
# Usage: bash deploy.sh [--license-key KEY] [--region REGION] [--project-id ID]
set -euo pipefail

BOLD="\033[1m"
DIM="\033[2m"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
CYAN="\033[36m"
RESET="\033[0m"

DOCKER_IMAGE="docker.io/aisforapp/suvadu-mcp:stable"
DEFAULT_REGION="us-central1"
STATE_FILE="$HOME/.suvadu-deploy-state.json"

info()  { echo -e "${GREEN}==>${RESET} ${BOLD}$1${RESET}"; }
warn()  { echo -e "${YELLOW}==>${RESET} ${BOLD}$1${RESET}"; }
error() { echo -e "${RED}==>${RESET} ${BOLD}$1${RESET}"; exit 1; }
step()  { echo -e "${CYAN}  →${RESET} $1"; }

# ── State management ──

save_state() {
    python3 -c "
import json, sys
state = {}
try:
    state = json.load(open('$STATE_FILE'))
except: pass
state['step'] = '$1'
if len(sys.argv) > 2: state[sys.argv[1]] = sys.argv[2]
json.dump(state, open('$STATE_FILE', 'w'), indent=2)
import os; os.chmod('$STATE_FILE', 0o600)
" "${@:2}" 2>/dev/null || true
}

get_state() {
    python3 -c "
import json
try:
    state = json.load(open('$STATE_FILE'))
    print(state.get('step', ''))
except: print('')
" 2>/dev/null
}

get_state_value() {
    python3 -c "
import json, sys
try:
    state = json.load(open('$STATE_FILE'))
    print(state.get(sys.argv[1], ''))
except: print('')
" "$1" 2>/dev/null
}

# ── Parse arguments ──

LICENSE_KEY=""
REGION="$DEFAULT_REGION"
PROJECT_ID=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --license-key) LICENSE_KEY="$2"; shift 2 ;;
        --region) REGION="$2"; shift 2 ;;
        --project-id) PROJECT_ID="$2"; shift 2 ;;
        *) error "Unknown flag: $1" ;;
    esac
done

# ── Check prerequisites ──

command -v gcloud &>/dev/null || error "gcloud not found. This should not happen in Cloud Shell."

ACCOUNT=$(gcloud config get-value account 2>/dev/null || true)
[[ -z "$ACCOUNT" ]] && error "Not authenticated. Run: gcloud auth login"

# ── Check for existing deployment ──

CURRENT_STEP=$(get_state)
if [[ -n "$CURRENT_STEP" && "$CURRENT_STEP" != "complete" ]]; then
    info "Resuming from previous deployment..."
    PROJECT_ID=$(get_state_value project_id)
    REGION=$(get_state_value region)
    LICENSE_KEY=$(get_state_value license_key)
fi

# ── Prompt for license key if not provided ──

if [[ -z "$LICENSE_KEY" ]]; then
    echo ""
    echo -e "${BOLD}Enter your Suvadu Pro license key:${RESET}"
    echo -e "${DIM}(starts with SVPRO-, check your email)${RESET}"
    read -r LICENSE_KEY
fi

# Validate format
# Note: Full Ed25519 signature validation happens at container startup.
# The deploy script can only check format (no public key available in bash).
[[ "$LICENSE_KEY" == SVPRO-* ]] || error "Invalid license key. Keys start with SVPRO-."
[[ ${#LICENSE_KEY} -gt 50 ]] || error "License key is too short. Check you copied the full key."

# ── Generate project ID if not set ──

if [[ -z "$PROJECT_ID" ]]; then
    RANDOM_SUFFIX=$(python3 -c "import secrets; print(secrets.token_hex(3))")
    PROJECT_ID="suvadu-memory-${RANDOM_SUFFIX}"
fi

echo ""
info "Deploying Suvadu Cloud"
step "Project: $PROJECT_ID"
step "Region: $REGION"
step "Account: $ACCOUNT"
echo ""

# ── Step 1: Select billing account ──

if [[ "$CURRENT_STEP" < "billing_linked" || -z "$CURRENT_STEP" ]]; then
    info "Checking billing account..."
    BILLING_ACCOUNT=$(gcloud billing accounts list --format="value(name)" --filter="open=true" 2>/dev/null | head -1)
    if [[ -z "$BILLING_ACCOUNT" ]]; then
        echo ""
        error "No billing account found. Create one (free, \$300 credit):
  https://console.cloud.google.com/billing

Then re-run this script."
    fi
    step "Billing: $BILLING_ACCOUNT"
fi

# ── Step 2: Create GCP project ──

if [[ "$CURRENT_STEP" < "project_created" || -z "$CURRENT_STEP" ]]; then
    info "Creating GCP project: $PROJECT_ID..."
    if ! gcloud projects create "$PROJECT_ID" --name="Suvadu Memory" --quiet 2>/dev/null; then
        # Check if project already exists (idempotent)
        gcloud projects describe "$PROJECT_ID" &>/dev/null || error "Failed to create project. Try a different --project-id."
        step "Project already exists, continuing..."
    fi
    save_state "project_created" "project_id" "$PROJECT_ID"
    save_state "project_created" "region" "$REGION"
    # Note: license_key is NOT persisted in state file (security)
fi

# ── Step 3: Link billing ──

if [[ "$CURRENT_STEP" < "billing_linked" || -z "$CURRENT_STEP" ]]; then
    info "Linking billing account..."
    gcloud billing projects link "$PROJECT_ID" --billing-account="$BILLING_ACCOUNT" --quiet 2>/dev/null
    save_state "billing_linked"
fi

# ── Step 4: Enable APIs ──

if [[ "$CURRENT_STEP" < "apis_enabled" || -z "$CURRENT_STEP" ]]; then
    info "Enabling Cloud Run, Storage, Secret Manager APIs..."
    gcloud services enable \
        run.googleapis.com \
        storage.googleapis.com \
        secretmanager.googleapis.com \
        --project="$PROJECT_ID" --quiet

    step "Waiting for API propagation (30s)..."
    sleep 30
    save_state "apis_enabled"
fi

# ── Step 5: Create GCS bucket ──

BUCKET="${PROJECT_ID}-data"

if [[ "$CURRENT_STEP" < "bucket_created" || -z "$CURRENT_STEP" ]]; then
    info "Creating storage bucket: $BUCKET..."
    gcloud storage buckets create "gs://$BUCKET" \
        --location="$REGION" \
        --uniform-bucket-level-access \
        --project="$PROJECT_ID" --quiet 2>/dev/null || {
        gcloud storage ls "gs://$BUCKET" &>/dev/null || error "Failed to create bucket"
        step "Bucket already exists, continuing..."
    }
    save_state "bucket_created"
fi

# ── Step 6: Grant IAM ──

if [[ "$CURRENT_STEP" < "iam_granted" || -z "$CURRENT_STEP" ]]; then
    info "Setting up permissions..."
    PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)")
    SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

    gcloud storage buckets add-iam-policy-binding "gs://$BUCKET" \
        --member="serviceAccount:$SA" \
        --role="roles/storage.objectAdmin" \
        --project="$PROJECT_ID" --quiet 2>/dev/null
    save_state "iam_granted"
fi

# ── Step 7: Create secrets ──

if [[ "$CURRENT_STEP" < "secrets_created" || -z "$CURRENT_STEP" ]]; then
    AUTH_TOKEN="sv_$(python3 -c "import secrets; print(secrets.token_hex(24))")"

    info "Storing auth token..."
    echo -n "$AUTH_TOKEN" | gcloud secrets create suvadu-auth-token \
        --data-file=- \
        --replication-policy="automatic" \
        --project="$PROJECT_ID" --quiet 2>/dev/null || true

    info "Storing license key..."
    echo -n "$LICENSE_KEY" | gcloud secrets create suvadu-license-key \
        --data-file=- \
        --replication-policy="automatic" \
        --project="$PROJECT_ID" --quiet 2>/dev/null || true

    # Grant Cloud Run service account access
    PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)" 2>/dev/null)
    SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

    for SECRET in suvadu-auth-token suvadu-license-key; do
        gcloud secrets add-iam-policy-binding "$SECRET" \
            --member="serviceAccount:$SA" \
            --role="roles/secretmanager.secretAccessor" \
            --project="$PROJECT_ID" --quiet 2>/dev/null || true
    done

    # Note: auth_token is NOT persisted in state file (security)
    save_state "secrets_created"
fi

# Retrieve auth token from Secret Manager (not stored in state file for security)
if [[ -z "$AUTH_TOKEN" ]]; then
    AUTH_TOKEN=$(gcloud secrets versions access latest --secret=suvadu-auth-token --project="$PROJECT_ID" 2>/dev/null || echo "")
fi

# ── Step 8: Deploy Cloud Run ──

if [[ "$CURRENT_STEP" < "deployed" || -z "$CURRENT_STEP" ]]; then
    info "Deploying Suvadu to Cloud Run (this takes 1-2 minutes)..."
    gcloud run deploy suvadu-mcp \
        --image="$DOCKER_IMAGE" \
        --region="$REGION" \
        --execution-environment=gen1 \
        --cpu-boost \
        --min-instances=0 \
        --max-instances=1 \
        --memory=512Mi \
        --cpu=1 \
        --timeout=300 \
        --set-env-vars="SUVADU_GCS_BUCKET=$BUCKET" \
        --set-secrets="SUVADU_AUTH_TOKEN=suvadu-auth-token:latest,SUVADU_LICENSE_KEY=suvadu-license-key:latest" \
        --allow-unauthenticated \
        --project="$PROJECT_ID" \
        --quiet
    save_state "deployed"
fi

# ── Step 9: Get endpoint URL ──

SERVICE_URL=$(gcloud run services describe suvadu-mcp \
    --region="$REGION" \
    --project="$PROJECT_ID" \
    --format="value(status.url)" 2>/dev/null)

ENDPOINT="${SERVICE_URL}/mcp?token=${AUTH_TOKEN}"

# ── Step 10: Health check ──

if [[ "$CURRENT_STEP" < "verified" || -z "$CURRENT_STEP" ]]; then
    info "Verifying endpoint..."
    HEALTH_OK=false
    for i in 1 2 3 4 5 6; do
        if curl -sf "${SERVICE_URL}/health" &>/dev/null; then
            HEALTH_OK=true
            break
        fi
        step "Waiting for service to start ($((i * 5))s)..."
        sleep 5
    done

    if $HEALTH_OK; then
        step "Health check passed!"
    else
        warn "Health check timed out — the service may need another minute on first start."
    fi

    save_state "complete" "endpoint" "$ENDPOINT"
    save_state "complete" "service_url" "$SERVICE_URL"
fi

# ── Done ──

echo ""
echo -e "${GREEN}══════════════════════════════════════════${RESET}"
echo -e "${GREEN}  Suvadu Cloud is ready!${RESET}"
echo -e "${GREEN}══════════════════════════════════════════${RESET}"
echo ""
echo -e "  ${BOLD}Your endpoint URL:${RESET}"
echo -e "  ${CYAN}${ENDPOINT}${RESET}"
echo ""
echo -e "  ${DIM}Add to Claude Desktop:${RESET}"
echo -e "    Settings → MCP Servers → Add → paste the URL above"
echo ""
echo -e "  ${DIM}Add to Claude iOS:${RESET}"
echo -e "    Settings → MCP → Add Server → paste the URL above"
echo ""
echo -e "  ${DIM}GCP cost:${RESET} Low — typically free for personal use (you pay Google based on usage)"
echo -e "  ${DIM}Your data:${RESET} In YOUR Google Cloud, not ours."
echo ""
echo -e "  ${DIM}To remove everything:${RESET} bash cleanup.sh"
echo -e "${GREEN}══════════════════════════════════════════${RESET}"
echo ""
