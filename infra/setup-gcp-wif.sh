#!/usr/bin/env bash
# =============================================================================
# setup-gcp-wif.sh
# One-time-per-environment bootstrap: WIF + Terraform state bucket + bootstrap SA.
# Run by an operator with Owner/admin on the project. Creates only what Terraform
# cannot bootstrap itself (its own backend bucket and the WIF pool it authenticates
# through).
#
# Usage:
#   ./infra/setup-gcp-wif.sh --env dev --project-id charlie-sandpit \
#       --org intelia-charlie --repo lineage-and-usage-agents- \
#       [--region australia-southeast1] [--registry-repo lineage-agents] [--teardown]
# =============================================================================
set -euo pipefail

ENVIRONMENT="" PROJECT_ID="" REGION="australia-southeast1"
ORG="" REPO="" REGISTRY_REPO="lineage-agents" TEARDOWN="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)            ENVIRONMENT="$2"; shift 2 ;;
    --project-id)     PROJECT_ID="$2"; shift 2 ;;
    --region)         REGION="$2"; shift 2 ;;
    --org)            ORG="$2"; shift 2 ;;
    --repo)           REPO="$2"; shift 2 ;;
    --registry-repo)  REGISTRY_REPO="$2"; shift 2 ;;
    --teardown)       TEARDOWN="true"; shift ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

for v in ENVIRONMENT PROJECT_ID ORG REPO; do
  if [[ -z "${!v}" ]]; then echo "ERROR: --$(echo "$v" | tr '[:upper:]' '[:lower:]') is required" >&2; exit 1; fi
done
case "$ENVIRONMENT" in dev|sit|prod) ;; *) echo "ERROR: --env must be dev|sit|prod" >&2; exit 1 ;; esac

ENVIRONMENT="$(echo "$ENVIRONMENT" | tr '[:upper:]' '[:lower:]')"
TF_STATE_BUCKET="${PROJECT_ID}-gcs-tfstate-${ENVIRONMENT}"
SA_NAME="data-tf-sa-${ENVIRONMENT}"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
WIF_POOL_ID="github-pool-${ENVIRONMENT}"
WIF_PROVIDER_ID="github-provider-${ENVIRONMENT}"

echo ">> Checking gcloud auth..."
ACTIVE_ACCOUNT="$(gcloud config get-value account 2>/dev/null || true)"
if [[ -z "$ACTIVE_ACCOUNT" || "$ACTIVE_ACCOUNT" == "(unset)" ]]; then
  echo "ERROR: no active gcloud account. Run: gcloud auth login" >&2; exit 1
fi
echo "   Authenticated as: $ACTIVE_ACCOUNT"

PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
gcloud config set project "$PROJECT_ID" >/dev/null

if [[ "$TEARDOWN" == "true" ]]; then
  echo ">> Teardown for ${ENVIRONMENT}..."
  gcloud iam workload-identity-pools providers delete "$WIF_PROVIDER_ID" \
    --workload-identity-pool="$WIF_POOL_ID" --location=global --project="$PROJECT_ID" --quiet 2>/dev/null || true
  gcloud iam workload-identity-pools delete "$WIF_POOL_ID" \
    --location=global --project="$PROJECT_ID" --quiet 2>/dev/null || true
  gcloud iam service-accounts delete "$SA_EMAIL" --project="$PROJECT_ID" --quiet 2>/dev/null || true
  echo "   Teardown complete (state bucket left intact — delete manually if intended)."
  exit 0
fi

echo "=============================================="
echo " Bootstrap: ${ENVIRONMENT}  project=${PROJECT_ID} (${PROJECT_NUMBER})"
echo " GitHub: ${ORG}/${REPO}   SA: ${SA_EMAIL}"
echo "=============================================="

# 1. Enable baseline + project-specific APIs
echo ">> Enabling APIs..."
gcloud services enable \
  iam.googleapis.com iamcredentials.googleapis.com sts.googleapis.com \
  cloudresourcemanager.googleapis.com storage.googleapis.com \
  secretmanager.googleapis.com artifactregistry.googleapis.com \
  run.googleapis.com firestore.googleapis.com aiplatform.googleapis.com \
  bigquery.googleapis.com cloudbuild.googleapis.com \
  --project="$PROJECT_ID"

# 2. Bootstrap SA
echo ">> Ensuring bootstrap SA ${SA_NAME}..."
if ! gcloud iam service-accounts describe "$SA_EMAIL" --project="$PROJECT_ID" >/dev/null 2>&1; then
  gcloud iam service-accounts create "$SA_NAME" \
    --display-name="Terraform Bootstrap (GitHub Actions, WIF)" \
    --description="Used by GitHub Actions via WIF. No key ever exported." \
    --project="$PROJECT_ID"
  echo "   Created. Waiting 60s for propagation..."; sleep 60
else
  echo "   Already exists."
fi

# 3. Roles — everything Terraform needs to manage this project's resources
echo ">> Granting bootstrap roles..."
BOOTSTRAP_ROLES=(
  roles/artifactregistry.admin
  roles/run.admin
  roles/iam.serviceAccountAdmin
  roles/iam.serviceAccountUser
  roles/resourcemanager.projectIamAdmin
  roles/secretmanager.admin
  roles/storage.admin
  roles/datastore.owner
  roles/bigquery.admin
  roles/firebase.admin
)
for ROLE in "${BOOTSTRAP_ROLES[@]}"; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${SA_EMAIL}" --role="$ROLE" --condition=None --quiet >/dev/null
done

# 4. WIF pool
echo ">> Ensuring WIF pool ${WIF_POOL_ID}..."
if ! gcloud iam workload-identity-pools describe "$WIF_POOL_ID" \
     --location=global --project="$PROJECT_ID" >/dev/null 2>&1; then
  gcloud iam workload-identity-pools create "$WIF_POOL_ID" \
    --location=global --display-name="GitHub Actions Pool (${ENVIRONMENT})" --project="$PROJECT_ID"
  echo "   Created. Waiting 60s..."; sleep 60
else
  echo "   Already exists."
fi

# 5. OIDC provider (locked to the GitHub org)
echo ">> Ensuring WIF provider ${WIF_PROVIDER_ID}..."
if ! gcloud iam workload-identity-pools providers describe "$WIF_PROVIDER_ID" \
     --workload-identity-pool="$WIF_POOL_ID" --location=global --project="$PROJECT_ID" >/dev/null 2>&1; then
  gcloud iam workload-identity-pools providers create-oidc "$WIF_PROVIDER_ID" \
    --location=global --workload-identity-pool="$WIF_POOL_ID" \
    --display-name="GitHub Actions Provider (${ENVIRONMENT})" \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="google.subject=assertion.sub,attribute.actor=assertion.actor,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner" \
    --attribute-condition="assertion.repository_owner == '${ORG}'" \
    --project="$PROJECT_ID"
else
  gcloud iam workload-identity-pools providers update-oidc "$WIF_PROVIDER_ID" \
    --workload-identity-pool="$WIF_POOL_ID" --location=global \
    --attribute-condition="assertion.repository_owner == '${ORG}'" \
    --project="$PROJECT_ID" --quiet
fi

# 6. Bind SA to the repo's principalSet
echo ">> Binding SA to WIF for ${ORG}/${REPO}..."
sleep 30
gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" --project="$PROJECT_ID" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${WIF_POOL_ID}/attribute.repository/${ORG}/${REPO}" \
  --quiet >/dev/null

# 7. State bucket (versioned)
echo ">> Ensuring state bucket gs://${TF_STATE_BUCKET}..."
if ! gcloud storage buckets describe "gs://${TF_STATE_BUCKET}" >/dev/null 2>&1; then
  gcloud storage buckets create "gs://${TF_STATE_BUCKET}" \
    --project="$PROJECT_ID" --location="$REGION" --uniform-bucket-level-access
  gcloud storage buckets update "gs://${TF_STATE_BUCKET}" --versioning
fi
gcloud storage buckets add-iam-policy-binding "gs://${TF_STATE_BUCKET}" \
  --member="serviceAccount:${SA_EMAIL}" --role="roles/storage.objectAdmin" >/dev/null

cat <<EOF

==============================================
 Bootstrap complete. Add these to GitHub → Settings → Environments → ${ENVIRONMENT}:
==============================================
PROJECT_ID:     ${PROJECT_ID}
PROJECT_NUMBER: ${PROJECT_NUMBER}
REGION:         ${REGION}

Derived automatically by .github/actions/gcp-auth (FYI):
WIF_PROVIDER: projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${WIF_POOL_ID}/providers/${WIF_PROVIDER_ID}
SA_EMAIL:     ${SA_EMAIL}
STATE_BUCKET: ${TF_STATE_BUCKET}
REGISTRY:     ${REGION}-docker.pkg.dev/${PROJECT_ID}/${REGISTRY_REPO}-${ENVIRONMENT}

Next steps:
  1. Add PROJECT_ID, PROJECT_NUMBER, REGION as vars in GitHub Environment '${ENVIRONMENT}'
  2. Run the Infra Build workflow for '${ENVIRONMENT}'
  3. After first backend deploy, add BACKEND_URL as a GitHub Environment var (get it from Terraform output or the Cloud Run console)
  4. Re-run Infra Build to build the frontend image with the correct API base URL
EOF
