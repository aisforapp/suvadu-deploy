#!/bin/bash
# Remove all Suvadu Cloud resources by deleting the GCP project.
set -euo pipefail

STATE_FILE="$HOME/.suvadu-deploy-state.json"

if [[ ! -f "$STATE_FILE" ]]; then
    echo "No Suvadu Cloud deployment found."
    exit 0
fi

PROJECT_ID=$(python3 -c "import json; print(json.load(open('$STATE_FILE'))['project_id'])" 2>/dev/null)

if [[ -z "$PROJECT_ID" ]]; then
    echo "Could not read project ID from state file."
    exit 1
fi

echo ""
echo "This will delete the GCP project '$PROJECT_ID' and ALL data in it."
echo "This includes all your cloud memories."
echo ""
read -p "Are you sure? Type 'yes' to confirm: " CONFIRM

if [[ "$CONFIRM" != "yes" ]]; then
    echo "Cancelled."
    exit 0
fi

echo "Deleting project $PROJECT_ID..."
gcloud projects delete "$PROJECT_ID" --quiet

rm -f "$STATE_FILE"
echo ""
echo "Done. Project scheduled for deletion (30-day recovery window in GCP Console)."
echo ""
