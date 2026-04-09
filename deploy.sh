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

DOCKER_IMAGE="docker.io/aisforapp/suvadu-mcp:dev"
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
REGION=""
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
fi

# ── Prompt for license key if not provided ──

if [[ -z "$LICENSE_KEY" ]]; then
    echo ""
    echo -e "${BOLD}Enter your Suvadu Pro license key:${RESET}"
    echo -e "${DIM}(starts with SVPRO-, check your email)${RESET}"
    read -r LICENSE_KEY
fi

# Validate format
[[ "$LICENSE_KEY" == SVPRO-* ]] || error "Invalid license key. Keys start with SVPRO-."
[[ ${#LICENSE_KEY} -gt 50 ]] || error "License key is too short. Check you copied the full key."

# ── Step 1: Select billing account ──

info "Checking billing account..."
BILLING_ACCOUNTS=$(gcloud billing accounts list --format="value(name,displayName)" --filter="open=true" 2>/dev/null || true)

if [[ -z "$BILLING_ACCOUNTS" ]]; then
    echo ""
    echo -e "${RED}No billing account found.${RESET}"
    echo ""
    echo -e "  You need a Google Cloud billing account to deploy."
    echo -e "  It's free — Google gives you \$300 credit for 90 days."
    echo ""
    echo -e "  ${BOLD}1.${RESET} Open: ${CYAN}https://console.cloud.google.com/billing${RESET}"
    echo -e "  ${BOLD}2.${RESET} Click 'Create Account' or 'Start Free Trial'"
    echo -e "  ${BOLD}3.${RESET} Come back here and re-run: ${BOLD}bash deploy.sh${RESET}"
    echo ""
    exit 1
fi

# If multiple billing accounts, let user choose
BILLING_COUNT=$(echo "$BILLING_ACCOUNTS" | wc -l | tr -d ' ')
if [[ "$BILLING_COUNT" -gt 1 ]]; then
    echo ""
    echo -e "${BOLD}Multiple billing accounts found:${RESET}"
    echo ""
    INDEX=1
    while IFS=$'\t' read -r ACCT_ID ACCT_NAME; do
        echo -e "  ${BOLD}${INDEX}.${RESET} ${ACCT_NAME} (${ACCT_ID})"
        INDEX=$((INDEX + 1))
    done <<< "$BILLING_ACCOUNTS"
    echo ""
    read -p "Choose (1-${BILLING_COUNT}): " CHOICE
    BILLING_ACCOUNT=$(echo "$BILLING_ACCOUNTS" | sed -n "${CHOICE}p" | cut -f1)
else
    BILLING_ACCOUNT=$(echo "$BILLING_ACCOUNTS" | head -1 | cut -f1)
fi

[[ -z "$BILLING_ACCOUNT" ]] && error "No billing account selected."
step "Billing: $BILLING_ACCOUNT"

# ── Step 2: Choose region ──

if [[ -z "$REGION" ]]; then
    echo ""
    echo -e "${BOLD}Choose a region for your Suvadu Cloud:${RESET}"
    echo ""
    echo -e "  ${BOLD}1.${RESET} us-central1    (Iowa, USA — lowest cost)"
    echo -e "  ${BOLD}2.${RESET} us-east1       (South Carolina, USA)"
    echo -e "  ${BOLD}3.${RESET} europe-west1   (Belgium, Europe)"
    echo -e "  ${BOLD}4.${RESET} asia-southeast1 (Singapore, Asia-Pacific)"
    echo -e "  ${BOLD}5.${RESET} australia-southeast1 (Sydney, Australia)"
    echo ""
    read -p "Choose (1-5) [default: 1]: " REGION_CHOICE
    REGION_CHOICE=${REGION_CHOICE:-1}

    case "$REGION_CHOICE" in
        1) REGION="us-central1" ;;
        2) REGION="us-east1" ;;
        3) REGION="europe-west1" ;;
        4) REGION="asia-southeast1" ;;
        5) REGION="australia-southeast1" ;;
        *) REGION="us-central1" ;;
    esac
fi

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

# ── Step 3: Create GCP project ──

if [[ "$CURRENT_STEP" < "project_created" || -z "$CURRENT_STEP" ]]; then
    info "Creating GCP project: $PROJECT_ID..."
    if ! gcloud projects create "$PROJECT_ID" --name="Suvadu Memory" --quiet 2>&1; then
        # Check if project already exists (idempotent)
        gcloud projects describe "$PROJECT_ID" &>/dev/null || error "Failed to create project. Try a different --project-id."
        step "Project already exists, continuing..."
    fi
    save_state "project_created" "project_id" "$PROJECT_ID"
    save_state "project_created" "region" "$REGION"
    # Note: license_key is NOT persisted in state file (security)
fi

# ── Step 4: Link billing ──

if [[ "$CURRENT_STEP" < "billing_linked" || -z "$CURRENT_STEP" ]]; then
    info "Linking billing account..."
    gcloud billing projects link "$PROJECT_ID" --billing-account="$BILLING_ACCOUNT" --quiet 2>&1 || error "Failed to link billing. Check your billing account permissions."
    save_state "billing_linked"
fi

# ── Step 5: Enable APIs ──

if [[ "$CURRENT_STEP" < "apis_enabled" || -z "$CURRENT_STEP" ]]; then
    info "Enabling Cloud Run, Storage, Secret Manager APIs..."
    gcloud services enable \
        run.googleapis.com \
        storage.googleapis.com \
        secretmanager.googleapis.com \
        --project="$PROJECT_ID" --quiet 2>&1 || error "Failed to enable APIs."

    step "Waiting for API propagation (30s)..."
    sleep 30
    save_state "apis_enabled"
fi

# ── Step 6: Create GCS bucket ──

BUCKET="${PROJECT_ID}-data"

if [[ "$CURRENT_STEP" < "bucket_created" || -z "$CURRENT_STEP" ]]; then
    info "Creating storage bucket: $BUCKET..."
    gcloud storage buckets create "gs://$BUCKET" \
        --location="$REGION" \
        --uniform-bucket-level-access \
        --project="$PROJECT_ID" --quiet 2>&1 || {
        gcloud storage ls "gs://$BUCKET" &>/dev/null || error "Failed to create bucket"
        step "Bucket already exists, continuing..."
    }
    save_state "bucket_created"
fi

# ── Step 7: Grant IAM ──

if [[ "$CURRENT_STEP" < "iam_granted" || -z "$CURRENT_STEP" ]]; then
    info "Setting up permissions..."
    PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)" 2>&1)
    step "Project number: $PROJECT_NUMBER"
    SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
    step "Service account: $SA"

    gcloud storage buckets add-iam-policy-binding "gs://$BUCKET" \
        --member="serviceAccount:$SA" \
        --role="roles/storage.objectAdmin" \
        --project="$PROJECT_ID" --quiet 2>&1 || warn "IAM binding may already exist, continuing..."
    save_state "iam_granted"
fi

# ── Step 8: Create secrets ──

if [[ "$CURRENT_STEP" < "secrets_created" || -z "$CURRENT_STEP" ]]; then
    AUTH_TOKEN="sv_$(python3 -c "import secrets; print(secrets.token_hex(24))")"

    info "Storing auth token..."
    echo -n "$AUTH_TOKEN" | gcloud secrets create suvadu-auth-token \
        --data-file=- \
        --replication-policy="automatic" \
        --project="$PROJECT_ID" --quiet 2>&1 || step "Secret may already exist, continuing..."

    info "Storing license key..."
    echo -n "$LICENSE_KEY" | gcloud secrets create suvadu-license-key \
        --data-file=- \
        --replication-policy="automatic" \
        --project="$PROJECT_ID" --quiet 2>&1 || step "Secret may already exist, continuing..."

    # Grant Cloud Run service account access
    PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)" 2>/dev/null)
    SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

    for SECRET in suvadu-auth-token suvadu-license-key; do
        gcloud secrets add-iam-policy-binding "$SECRET" \
            --member="serviceAccount:$SA" \
            --role="roles/secretmanager.secretAccessor" \
            --project="$PROJECT_ID" --quiet 2>&1 || step "Secret IAM may already exist, continuing..."
    done

    # Note: auth_token is NOT persisted in state file (security)
    save_state "secrets_created"
fi

# Retrieve auth token from Secret Manager (not stored in state file for security)
if [[ -z "${AUTH_TOKEN:-}" ]]; then
    AUTH_TOKEN=$(gcloud secrets versions access latest --secret=suvadu-auth-token --project="$PROJECT_ID" 2>/dev/null || echo "")
fi

# ── Step 9: Deploy Cloud Run ──

if [[ "$CURRENT_STEP" < "deployed" || -z "$CURRENT_STEP" ]]; then
    info "Deploying Suvadu to Cloud Run (this takes 1-2 minutes)..."
    step "Image: $DOCKER_IMAGE"
    step "Memory: 2Gi, CPU: 2"
    gcloud run deploy suvadu-mcp \
        --image="$DOCKER_IMAGE" \
        --region="$REGION" \
        --execution-environment=gen1 \
        --cpu-boost \
        --min-instances=0 \
        --max-instances=1 \
        --memory=2Gi \
        --cpu=2 \
        --timeout=300 \
        --set-env-vars="SUVADU_GCS_BUCKET=$BUCKET" \
        --set-secrets="SUVADU_AUTH_TOKEN=suvadu-auth-token:latest,SUVADU_LICENSE_KEY=suvadu-license-key:latest" \
        --allow-unauthenticated \
        --project="$PROJECT_ID" \
        --quiet 2>&1 || error "Cloud Run deployment failed. Check the logs above."
    save_state "deployed"
fi

# ── Step 10: Get endpoint URL ──

SERVICE_URL=$(gcloud run services describe suvadu-mcp \
    --region="$REGION" \
    --project="$PROJECT_ID" \
    --format="value(status.url)" 2>/dev/null)

if [[ -z "$SERVICE_URL" ]]; then
    error "Could not retrieve service URL. Check Cloud Run console: https://console.cloud.google.com/run?project=$PROJECT_ID"
fi

ENDPOINT="${SERVICE_URL}/mcp?token=${AUTH_TOKEN}"

# ── Step 11: Health check ──

if [[ "$CURRENT_STEP" < "verified" || -z "$CURRENT_STEP" ]]; then
    info "Verifying endpoint..."
    HEALTH_OK=false
    for i in 1 2 3 4 5 6 7 8; do
        HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" "${SERVICE_URL}/health" 2>/dev/null || echo "000")
        if [[ "$HTTP_CODE" == "200" ]]; then
            HEALTH_OK=true
            step "Health check passed!"
            break
        fi
        step "Waiting for service to start ($((i * 5))s)... [HTTP $HTTP_CODE]"
        sleep 5
    done

    if ! $HEALTH_OK; then
        warn "Health check timed out — the service may need another minute on first cold start."
        warn "Try: curl ${SERVICE_URL}/health"
    fi

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
