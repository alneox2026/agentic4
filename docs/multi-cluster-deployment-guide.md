# Multi-Cluster Deployment & State Isolation Guide

This guide explains how to deploy and maintain isolated **Managed Agents Middleware clusters** (for example, `agentic4`, `gemini-prod`, or `antigravity-cluster`) within the same Google Cloud project without resource collisions or state overwrites.

---

## 1. Core Architectural Isolation Principle

Each cluster in our SuperApp architecture operates as an independent, decoupled stack:

```
                  Google Cloud Project (e.g. ceo-dev123)
  ┌─────────────────────────────────┐   ┌─────────────────────────────────────┐
  │       Existing Stack             │   │          agentic4 Stack              │
  │ • existing-gateway               │   │ • agentic4-gateway                   │
  │ • existing-worker                │   │ • agentic4-persistence-worker        │
  │ • existing-billing-api           │   │ • agentic4-billing-api               │
  │ • Topic: existing-turn-events    │   │ • Topic: agentic4-turn-events        │
  │ • Firestore: existing collections│   │ • Firestore: *_agentic4 collections  │
  │ • distinct service accounts      │   │ • agentic4-*-sa accounts             │
  └────────────────┬────────────────┘   └──────────────────┬──────────────────┘
                   │                                       │
                   ▼                                       ▼
      gs://...-tfstate/stacks/existing/        gs://...-tfstate/stacks/agentic4/
```

---

## 2. Terraform State Isolation (`backend.hcl`)

The foundation of multi-cluster isolation is the **Google Cloud Storage Terraform Backend Prefix**.

Each cluster MUST write to its own unique GCS state path:

| Cluster Stack | Remote State GCS Path |
| :--- | :--- |
| **Existing stack** | `gs://<PROJECT_ID>-tfstate/stacks/<existing-stack>/middleware/default.tfstate` |
| **agentic4** | `gs://<PROJECT_ID>-tfstate/stacks/agentic4/middleware/default.tfstate` |
| **Another stack** | `gs://<PROJECT_ID>-tfstate/stacks/<stack-name>/middleware/default.tfstate` |

### How It Works Automatically
Our deployment script [`scripts/cloudshell_deploy_middleware.sh`](../scripts/cloudshell_deploy_middleware.sh) automatically generates `backend.hcl` before running Terraform:

```bash
MIDDLEWARE_STACK_NAME="${MIDDLEWARE_STACK_NAME:-$(basename "${ROOT_DIR}")}"
TF_STATE_PREFIX="${TF_STATE_PREFIX:-stacks/${MIDDLEWARE_STACK_NAME}/middleware}"

cat > backend.hcl <<EOF
bucket = "${PROJECT_ID}-tfstate"
prefix = "${TF_STATE_PREFIX}"
EOF

terraform init -backend-config=backend.hcl -reconfigure
```

---

## 3. Dynamic Resource Naming Checklist

All Terraform resources must be uniquely named per stack. The build script also
uses a per-stack Artifact Registry image prefix, so one stack never deploys a
different stack's mutable `latest` image.

When configuring a new cluster:
1. **Cloud Run Service Names**:
   * `gateway_service_name`: `agentic4-gateway`
   * `worker_service_name`: `agentic4-persistence-worker`
   * `billing_api_service_name`: `agentic4-billing-api`
2. **Pub/Sub Topic**:
   * `pubsub_topic_name`: `agentic4-turn-events`
3. **Service Accounts**:
   * `gateway_service_account_name`: `agentic4-gateway-sa`
   * `worker_service_account_name`: `agentic4-worker-sa`
   * `billing_api_service_account_name`: `agentic4-billing-api-sa`
   * `eventarc_service_account_name`: `agentic4-eventarc-sa`
   * `billing_reconciler_service_account_name`: `agentic4-reconciler-sa`
4. **Firestore Collections**:
   * Use `*_agentic4` collections for a new stack, including webhook receipts
     and cancellation requests. Sharing wallet or webhook collections requires
     an explicit migration and is not a safe default.

---

## 4. Step-by-Step: Deploying a Managed Agents Cluster

### Step A: Local Setup
1. Copy `managed-agents-middleware-template` contents into your new repository folder:
   ```powershell
   cd C:\Users\Admin\Desktop\ANTIGRAVITY\my-managed-agents-stack
   git init -b main
   git remote add origin https://github.com/YOUR_ORG/my-managed-agents-stack.git
   ```
2. In `config/agents.prod.yaml`, configure your managed agents.
3. Commit and push:
   ```powershell
   git add .
   git commit -m "feat: initial commit for managed agents cluster"
   git push -u origin main
   ```

### Step B: Cloud Shell Deployment
```bash
# 1. Clone your new repo
cd ~
git clone https://github.com/YOUR_ORG/my-managed-agents-stack.git my-managed-agents-stack
cd my-managed-agents-stack

# 2. Set Gemini API Key secret in Secret Manager (if not already created)
echo -n "YOUR_GEMINI_API_KEY" | gcloud secrets create gemini-api-key --data-file=-

# 3. Build Middleware Images
bash ./scripts/cloudshell_build_middleware.sh

# 4. Deploy Middleware Infrastructure
# Default deployment:
bash ./scripts/cloudshell_deploy_middleware.sh

# Or override the name explicitly when the repository name is unsuitable:
MIDDLEWARE_STACK_NAME=agentic4 bash ./scripts/cloudshell_deploy_middleware.sh
```

---

## 5. Troubleshooting & FAQs

### Q: Why did Terraform propose deleting an existing cluster?
* **Reason**: The active state contained another stack's resources, often because they were imported into the new stack's state. Renaming service variables then appears to Terraform as a delete-and-create operation.
* **Fix**: Stop before applying. Use a unique `TF_STATE_PREFIX`, never auto-import legacy resources, and investigate the original stack's state before attempting recovery. The deployment script now refuses delete or replace actions unless `ALLOW_TERRAFORM_DELETES=true` is explicitly set.

### Q: Why did Terraform throw an index-already-exists `409`?
* **Reason**: Firestore composite indexes are scoped to their collection. The new stack reused a prior stack's cancellation-request collection while attempting to manage the same index from a different state.
* **Fix**: Use the stack-specific cancellation collection (`subscription_cancellation_requests_agentic4`) and its matching index definition.
