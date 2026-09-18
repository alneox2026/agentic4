#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Deploy Middleware Infrastructure via Terraform (Gateway, Worker, Billing API, Pub/Sub)
# ==============================================================================

PROJECT_ID="${PROJECT_ID:-ceo-dev123}"
REGION="${REGION:-us-central1}"
REPOSITORY="${REPOSITORY:-ceosystem}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

MIDDLEWARE_STACK_NAME="${MIDDLEWARE_STACK_NAME:-$(basename "${ROOT_DIR}")}"
MIDDLEWARE_IMAGE_PREFIX="${MIDDLEWARE_IMAGE_PREFIX:-${MIDDLEWARE_STACK_NAME}}"

if [[ ! "${MIDDLEWARE_STACK_NAME}" =~ ^[a-z][a-z0-9-]*$ ]]; then
  echo "ERROR: MIDDLEWARE_STACK_NAME must contain only lowercase letters, digits, and hyphens, and start with a letter." >&2
  exit 2
fi

if [[ ! "${MIDDLEWARE_IMAGE_PREFIX}" =~ ^[a-z][a-z0-9-]*$ ]]; then
  echo "ERROR: MIDDLEWARE_IMAGE_PREFIX must contain only lowercase letters, digits, and hyphens, and start with a letter." >&2
  exit 2
fi

# Resolve only this stack's images. Falling back to another middleware's image
# can deploy the wrong application after a shared Artifact Registry repository
# receives a later build.
if [ -n "${TAG:-}" ] && [ "${TAG}" != "latest" ]; then
  GATEWAY_IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/${MIDDLEWARE_IMAGE_PREFIX}-gateway:${TAG}"
  WORKER_IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/${MIDDLEWARE_IMAGE_PREFIX}-persistence-worker:${TAG}"
  BILLING_API_IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/${MIDDLEWARE_IMAGE_PREFIX}-billing-api:${TAG}"
else
  echo "--> Resolving :latest image digests from Artifact Registry..."
  GATEWAY_NAME="${MIDDLEWARE_IMAGE_PREFIX}-gateway"
  WORKER_NAME="${MIDDLEWARE_IMAGE_PREFIX}-persistence-worker"
  BILLING_API_NAME="${MIDDLEWARE_IMAGE_PREFIX}-billing-api"

  GATEWAY_DIGEST="$(gcloud artifacts docker images describe "${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/${GATEWAY_NAME}:latest" --format='value(image_summary.digest)' 2>/dev/null || true)"
  WORKER_DIGEST="$(gcloud artifacts docker images describe "${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/${WORKER_NAME}:latest" --format='value(image_summary.digest)' 2>/dev/null || true)"
  BILLING_API_DIGEST="$(gcloud artifacts docker images describe "${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/${BILLING_API_NAME}:latest" --format='value(image_summary.digest)' 2>/dev/null || true)"

  if [ -z "${GATEWAY_DIGEST}" ] || [ -z "${WORKER_DIGEST}" ] || [ -z "${BILLING_API_DIGEST}" ]; then
    echo "ERROR: One or more ${MIDDLEWARE_IMAGE_PREFIX} images are missing. Run cloudshell_build_middleware.sh successfully first, or pass TAG=<git-sha>." >&2
    exit 1
  fi

  GATEWAY_IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/${GATEWAY_NAME}@${GATEWAY_DIGEST}"
  WORKER_IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/${WORKER_NAME}@${WORKER_DIGEST}"
  BILLING_API_IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/${BILLING_API_NAME}@${BILLING_API_DIGEST}"
fi

# Every cloned middleware stack gets a dedicated state namespace.  Do not use a
# prefix belonging to another stack: Terraform would interpret the renamed
# resources as deletions of that stack.
TF_STATE_PREFIX="${TF_STATE_PREFIX:-stacks/${MIDDLEWARE_STACK_NAME}/middleware}"

echo "================================================================="
echo " Deploying Middleware Infrastructure (Terraform)"
echo " Project ID        : ${PROJECT_ID}"
echo " Region            : ${REGION}"
echo " Stack Name        : ${MIDDLEWARE_STACK_NAME}"
echo " Image Prefix      : ${MIDDLEWARE_IMAGE_PREFIX}"
echo " State Prefix      : ${TF_STATE_PREFIX}"
echo " Gateway Image     : ${GATEWAY_IMAGE}"
echo " Worker Image      : ${WORKER_IMAGE}"
echo " Billing API Image : ${BILLING_API_IMAGE}"
echo "================================================================="

cd "${ROOT_DIR}/infra/terraform"

# Clean any stale generated tfvars
rm -f terraform.auto.tfvars.json

# Generate isolated cluster backend configuration
cat > backend.hcl <<EOF
bucket = "${PROJECT_ID}-tfstate"
prefix = "${TF_STATE_PREFIX}"
EOF

terraform init -backend-config=backend.hcl -reconfigure

BILLING_CATALOG_PATH="${BILLING_CATALOG_PATH:-/app/config/billing.prod.yaml}"
EXTRA_TFVARS=",\"billing_api_catalog_path\": \"${BILLING_CATALOG_PATH}\""
if [ -n "${STRIPE_WEBHOOK_SIGNING_SECRET_ID:-}" ]; then
  EXTRA_TFVARS="${EXTRA_TFVARS},\"billing_api_stripe_webhook_signing_secret_id\": \"${STRIPE_WEBHOOK_SIGNING_SECRET_ID}\",\"billing_api_stripe_webhook_signing_secret_version\": \"${STRIPE_WEBHOOK_SIGNING_SECRET_VERSION:-1}\""
fi

cat > terraform.auto.tfvars.json <<EOF
{
  "project_id": "${PROJECT_ID}",
  "region": "${REGION}",
  "gateway_image": "${GATEWAY_IMAGE}",
  "worker_image": "${WORKER_IMAGE}",
  "billing_api_image": "${BILLING_API_IMAGE}",
  "allowed_origins": ["https://ceoappdev.flutterflow.app"],
  "billing_api_allowed_origins": ["https://ceoappdev.flutterflow.app"],
  "billing_api_stripe_secret_key_secret_version": "1",
  "billing_api_checkout_success_url": "https://ceoappdev.flutterflow.app/billing-complete?session_id={CHECKOUT_SESSION_ID}",
  "billing_api_checkout_cancel_url": "https://ceoappdev.flutterflow.app/billing-cancelled",
  "billing_enforcement_enabled": true,
  "billing_reconciliation_enabled": true${EXTRA_TFVARS}
}
EOF

# Import is deliberately opt-in. Auto-importing a legacy stack into this
# stack's state causes Terraform to destroy those legacy resources when their
# names differ from the current configuration.
if [ "${IMPORT_EXISTING_RESOURCES:-false}" = "true" ]; then
  bash "${ROOT_DIR}/scripts/import_existing_resources.sh"
fi

PLAN_FILE="middleware.tfplan"
rm -f "${PLAN_FILE}"
set +e
terraform plan -detailed-exitcode -out="${PLAN_FILE}"
PLAN_EXIT=$?
set -e

if [ "${PLAN_EXIT}" -eq 0 ]; then
  echo "No infrastructure changes to apply."
  terraform output
  exit 0
elif [ "${PLAN_EXIT}" -ne 2 ]; then
  exit "${PLAN_EXIT}"
fi

DESTRUCTIVE_ADDRESSES="$(terraform show -json "${PLAN_FILE}" | python3 -c '
import json
import sys

for resource in json.load(sys.stdin).get("resource_changes", []):
    if "delete" in resource.get("change", {}).get("actions", []):
        print(resource["address"])
')"

if [ -n "${DESTRUCTIVE_ADDRESSES}" ] && [ "${ALLOW_TERRAFORM_DELETES:-false}" != "true" ]; then
  echo "ERROR: Terraform plans to delete or replace the following resources:" >&2
  echo "${DESTRUCTIVE_ADDRESSES}" >&2
  echo "Refusing to apply. Verify TF_STATE_PREFIX and resource names. Set ALLOW_TERRAFORM_DELETES=true only for an intentional, reviewed deletion." >&2
  exit 1
fi

terraform apply -auto-approve "${PLAN_FILE}"
rm -f "${PLAN_FILE}"

echo "================================================================="
echo " Middleware Deployed Successfully!"
echo "================================================================="
terraform output
