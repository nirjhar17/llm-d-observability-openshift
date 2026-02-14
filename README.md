# llm-d Grafana Observability Stack

> **TL;DR**: This repo gives you Grafana dashboards to see what your LLM is doing on OpenShift AI.
> It also includes a fix for a bug where POST requests (chat completions) fail with `400 "body required"`.

Set up Grafana dashboards on OpenShift to monitor **llm-d** workloads -- from the Gateway/EPP routing layer all the way down to the vLLM model server internals.

## Two Important Files in This Repo

| File | What It Is |
|------|-----------|
| **[README.md](README.md)** (this file) | How to set up the Grafana dashboards and fix the bug |
| **[llm-d-request-flow-guide.md](llm-d-request-flow-guide.md)** | How requests flow through the system, what every piece does, the bug story, and how to debug things |

## What You Get

| Dashboard | What It Shows |
|-----------|--------------|
| **EPP Routing and Pool Health** | How requests enter the system, how they're distributed across model pods, error rates, pool-level health |
| **vLLM Latency, Throughput, and Cache** | What the vLLM model server is doing -- latency (TTFT, TPOT, E2E), token throughput, KV cache pressure, scheduler state |

**How the monitoring works (simplified):**

Your vLLM pods and EPP pod expose metrics (like request counts, latency, cache usage). OpenShift's built-in monitoring (Prometheus) scrapes these metrics automatically. Grafana then queries Prometheus to draw pretty graphs.

```
┌──────────────────────────────────────────────────────┐
│                  Grafana (your dashboards)            │
│   Dashboard 1: How EPP is routing requests           │
│   Dashboard 2: How vLLM is performing                │
└──────────────────────┬───────────────────────────────┘
                       │ asks for metrics
                       v
            ┌─────────────────────┐
            │   Thanos Querier    │   Combines metrics from
            │                     │   two Prometheus instances
            └────┬──────────┬─────┘   into one place
                 │          │
      ┌──────────▼─┐  ┌────▼──────────────────┐
      │ Platform    │  │ User Workload         │
      │ Prometheus  │  │ Monitoring (UWM)      │
      │             │  │ Prometheus            │
      │ Scrapes:    │  │                       │
      │ - node CPU  │  │ Scrapes:              │
      │ - memory    │  │ - vLLM metrics        │
      │ - cluster   │  │ - EPP metrics         │
      │   health    │  │ (via ServiceMonitor)  │
      └─────────────┘  └───────────────────────┘
```

**Why Thanos?** OpenShift has TWO separate Prometheus instances: one for cluster infrastructure and one for user workloads (your model). Thanos combines them so Grafana only needs one datasource.

## Prerequisites

1. **OpenShift cluster** (tested on 4.27 with OpenShift AI 3.0/3.2)
2. **Grafana Operator** installed from OperatorHub
3. **llm-d workload deployed** (LLMInferenceService with vLLM + EPP)
4. **User Workload Monitoring enabled** (for vLLM/EPP metrics)
5. **llm-d-deployer repo cloned** (for Sally's dashboard JSON):
   ```bash
   git clone https://github.com/llm-d/llm-d-deployer.git
   ```

### Installing the Grafana Operator

Go to **OperatorHub** in the OpenShift Console, search for "Grafana Operator" (by Red Hat), and install it in **All Namespaces** mode.

> **AWS STS clusters**: The operator may ask for an IAM role ARN during installation. Create one with no special permissions (Grafana Operator doesn't need AWS API access) and provide its ARN.

## Quick Start

```bash
# Clone this repo
git clone <this-repo-url>
cd llm-d-grafana-observability

# Run the setup script (does everything in order)
./setup.sh
```

The script will:
1. Create the `llm-d-monitoring` namespace
2. Deploy a Grafana instance with an OpenShift Route
3. Create a ServiceAccount with a permanent token for Thanos access
4. Grant `cluster-monitoring-view` permissions
5. Create a GrafanaDatasource pointing to Thanos Querier
6. Deploy both dashboards

At the end it prints the Grafana URL and credentials.

## Manual Step-by-Step Setup

If you prefer to apply each manifest yourself:

### Step 1: Create the Namespace

```bash
oc apply -f manifests/01-namespace.yaml
```

### Step 2: Create the Grafana Instance

```bash
oc apply -f manifests/02-grafana-instance.yaml
```

**Verify:**
```bash
oc get grafana -n llm-d-monitoring
oc get pods -n llm-d-monitoring -l app=grafana
oc get route -n llm-d-monitoring
```

Wait until the pod is `Running` and a Route appears.

### Step 3: Create ServiceAccount + Permanent Token

```bash
oc apply -f manifests/03-serviceaccount.yaml
```

This creates both a ServiceAccount (`grafana-thanos`) and a Secret (`grafana-thanos-token`) that holds a **permanent** (non-expiring) token.

**Verify the token was created:**
```bash
oc get secret grafana-thanos-token -n llm-d-monitoring
```

> **Why a permanent token?** Initially we used `oc create token --duration=8760h`, which creates a time-limited token. If that expires, your datasource stops working. The Secret-based approach creates a token that never expires.

### Step 4: Grant Monitoring Permissions

```bash
oc apply -f manifests/04-clusterrolebinding.yaml
```

This gives the ServiceAccount the `cluster-monitoring-view` role so it can query Thanos.

### Step 5: Create the Datasource

You need to inject the real token into the datasource YAML. The `TOKEN_PLACEHOLDER` in the manifest must be replaced:

```bash
# Get the token
TOKEN=$(oc get secret grafana-thanos-token -n llm-d-monitoring -o jsonpath='{.data.token}' | base64 -d)

# Apply with token injected
sed "s|TOKEN_PLACEHOLDER|${TOKEN}|g" manifests/05-datasource.yaml | oc apply -f -
```

**Verify:**
```bash
oc get grafanadatasource -n llm-d-monitoring
```

Then open the Grafana UI, go to **Connections > Data sources > Prometheus** and click **Test**. It should say "Data source is working."

### Step 6: Create the EPP Routing Dashboard

```bash
oc apply -f manifests/06-dashboard-epp-routing-and-pool-health.yaml
```

This dashboard is fetched directly from the upstream [Gateway API Inference Extension](https://github.com/kubernetes-sigs/gateway-api-inference-extension) GitHub repo.

### Step 7: Create the vLLM Dashboard

This is a two-part step because Sally's dashboard JSON uses a `${DS_PROMETHEUS}` template variable that must be replaced.

**7a: Create the ConfigMap from the fixed JSON:**

```bash
cd /path/to/llm-d-deployer/quickstart/grafana/dashboards

sed 's/${DS_PROMETHEUS}/prometheus/g' llm-d-dashboard.json | \
  sed 's/vllm:/kserve_vllm:/g' | \
  oc create configmap vllm-latency-throughput-and-cache-json \
  --from-file=dashboard.json=/dev/stdin \
  -n llm-d-monitoring
```

What this does:
- Reads `llm-d-dashboard.json` (the real file)
- Replaces `${DS_PROMETHEUS}` with `prometheus` (your datasource UID)
- Replaces `vllm:` with `kserve_vllm:` (RHOAI prefixes all vLLM metrics with `kserve_`)
- Creates a ConfigMap with the fixed JSON under the key `dashboard.json`

> **Why the metric prefix fix?** Sally's original dashboard uses `vllm:` (standard vLLM metrics).
> But on RHOAI/OpenShift AI, the ServiceMonitor adds a `kserve_` prefix, so all metrics
> become `kserve_vllm:`. Without this fix, the dashboard shows "No data".

**7b: Create the GrafanaDashboard CR:**

```bash
oc apply -f manifests/07-dashboard-vllm-latency-throughput-and-cache.yaml
```

**Verify both dashboards:**
```bash
oc get grafanadashboard -n llm-d-monitoring
```

You should see:
```
NAME                                AGE
epp-routing-and-pool-health         ...
vllm-latency-throughput-and-cache   ...
```

## Step 8 (Important!): Fix the Body-Forwarding Bug

There is a bug in Istio 1.26.2 where POST requests (chat completions) going through the InferencePool/EPP have their **request body stripped**. The model receives an empty body and returns `400 "body required"`.

This EnvoyFilter fixes it by changing the body handling mode from `FULL_DUPLEX_STREAMED` (buggy) to `BUFFERED` (works):

```bash
oc apply -f manifests/08-envoyfilter-fix-extproc-body.yaml
```

**How to verify it worked:**
```bash
export GW=$(oc get gateway openshift-ai-inference -n openshift-ingress \
  -o jsonpath='{.status.addresses[0].value}')

# This should return a model response (HTTP 200), not a 400 error
curl -sk -X POST "https://$GW/my-first-model/qwen3-0-6b/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model":"Qwen/Qwen3-0.6B","messages":[{"role":"user","content":"Hello"}],"max_tokens":10}'
```

> **Note**: This fix only applies to the `openshift-ai-inference` gateway. See the comments in the manifest file for how to also fix `maas-gateway`.
>
> When a future RHOAI version ships Istio 1.27+, this EnvoyFilter can be removed.

For the full story on this bug, how we found it, and how to debug the request flow, see [llm-d-request-flow-guide.md](llm-d-request-flow-guide.md).

## File Structure

```
llm-d-grafana-observability/
├── README.md                              # This file
├── setup.sh                               # Automated setup script
├── teardown.sh                            # Clean removal script
├── llm-d-request-flow-guide.md            # Deep-dive: request flow, the bug, debugging guide
└── manifests/
    ├── 01-namespace.yaml                  # llm-d-monitoring namespace
    ├── 02-grafana-instance.yaml           # Grafana CR (the Grafana pod + route)
    ├── 03-serviceaccount.yaml             # SA + permanent token Secret for Thanos
    ├── 04-clusterrolebinding.yaml         # Grant cluster-monitoring-view
    ├── 05-datasource.yaml                 # GrafanaDatasource CR (Thanos Querier)
    ├── 06-dashboard-epp-routing-and-pool-health.yaml
    │                                      # Dashboard 1: EPP/Gateway routing metrics
    ├── 07-dashboard-vllm-latency-throughput-and-cache.yaml
    │                                      # Dashboard 2: vLLM model server metrics
    └── 08-envoyfilter-fix-extproc-body.yaml
                                           # Bug fix: body forwarding for EPP routes
```

## How the Pieces Connect

```
You apply these YAMLs         The Grafana Operator does this automatically
─────────────────────         ──────────────────────────────────────────

01-namespace.yaml         →   Creates the namespace

02-grafana-instance.yaml  →   Operator creates: Pod, Service, Route
                              (You get a URL to access Grafana)

03-serviceaccount.yaml    →   Kubernetes creates: a permanent token in the Secret
04-clusterrolebinding.yaml→   RBAC: SA can now read cluster metrics

05-datasource.yaml        →   Operator configures Grafana to talk to Thanos Querier
   (with real token)          (using the permanent token for auth)

06-dashboard-epp-*.yaml   →   Operator fetches JSON from GitHub URL
                              and loads it into Grafana

07-dashboard-vllm-*.yaml  →   Operator reads JSON from ConfigMap
   + ConfigMap                and loads it into Grafana
```

## Teardown

```bash
./teardown.sh
```

This removes all Grafana resources but keeps the namespace (in case you have other things there). To also delete the namespace:

```bash
oc delete namespace llm-d-monitoring
```

## Troubleshooting

### Datasource shows "Bad Gateway" or "Unauthorized"

The token might be invalid or expired (if you used a time-limited one):

```bash
# Check if the permanent token exists
oc get secret grafana-thanos-token -n llm-d-monitoring

# If missing, re-apply step 3
oc apply -f manifests/03-serviceaccount.yaml

# Then re-inject into datasource (step 5)
TOKEN=$(oc get secret grafana-thanos-token -n llm-d-monitoring -o jsonpath='{.data.token}' | base64 -d)
sed "s|TOKEN_PLACEHOLDER|${TOKEN}|g" manifests/05-datasource.yaml | oc apply -f -
```

### Dashboard shows "No data"

1. **Check that your model is deployed and running:**
   ```bash
   oc get pods -n my-first-model -l app.kubernetes.io/name=qwen3-0-6b
   ```

2. **Check that User Workload Monitoring is scraping vLLM metrics:**
   ```bash
   oc get servicemonitor -n my-first-model
   ```

3. **Try a PromQL query in Grafana Explore:**
   ```
   vllm:num_requests_running
   ```
   If this returns data, the datasource is working and metrics are flowing.

### GrafanaDashboard shows "NO MATCHING INSTANCES"

The `instanceSelector` label doesn't match your Grafana instance:

```bash
# Check your Grafana instance labels
oc get grafana -n llm-d-monitoring -o jsonpath='{.items[0].metadata.labels}'
```

The dashboards expect `dashboards: llm-d-grafana`. If your Grafana has different labels, update the dashboard YAMLs to match.

### The EnvoyFilter is missing or not working

```bash
# Check it exists
oc get envoyfilter fix-extproc-body-mode -n openshift-ingress

# If missing, re-apply
oc apply -f manifests/08-envoyfilter-fix-extproc-body.yaml
```

### Model returns 404 "model does not exist"

The model name in your JSON body must match what vLLM registered (usually the HuggingFace name, not the Kubernetes name):

```bash
# Check what model name vLLM uses
curl -sk "https://$GW/my-first-model/qwen3-0-6b/v1/models" | python3 -m json.tool
```

Use the `id` from the output (e.g., `Qwen/Qwen3-0.6B`) in your request body.

### 401 Unauthorized

You're probably hitting the `maas-gateway` (which requires auth). Use the `openshift-ai-inference` gateway instead for testing:

```bash
export GW=$(oc get gateway openshift-ai-inference -n openshift-ingress \
  -o jsonpath='{.status.addresses[0].value}')
```

## Quick Test -- Is Everything Working?

```bash
export GW=$(oc get gateway openshift-ai-inference -n openshift-ingress \
  -o jsonpath='{.status.addresses[0].value}')

# 1. Does the model respond? (simple health check, no EPP involved)
curl -sk "https://$GW/my-first-model/qwen3-0-6b/v1/models"

# 2. Does chat completion work? (goes through EPP, needs the EnvoyFilter fix)
curl -sk -X POST "https://$GW/my-first-model/qwen3-0-6b/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model":"Qwen/Qwen3-0.6B","messages":[{"role":"user","content":"Hello! Say hi in 5 words."}],"max_tokens":20}' \
  | python3 -m json.tool
```

If both work, your setup is healthy.

## Version Info (What We're Running)

| Component | Version | Notes |
|-----------|---------|-------|
| OpenShift | 4.27 | ROSA on AWS (ap-southeast-1) |
| OpenShift AI (RHOAI) | 3.2.0 | Latest on `fast-3.x` channel |
| Service Mesh (OSSM3) | 3.2.1 | Sail operator |
| Istio | 1.26.2 | Pinned by RHOAI; 1.27.3 is supported but not yet used |
| Envoy | 1.34.2-dev | Inside gateway pods |
| Model | Qwen/Qwen3-0.6B | Via LLMInferenceService + vLLM |

## References

- [llm-d-deployer dashboards](https://github.com/llm-d/llm-d-deployer/tree/main/quickstart/grafana/dashboards) -- Sally O'Malley's original dashboard JSON
- [Gateway API Inference Extension dashboards](https://github.com/kubernetes-sigs/gateway-api-inference-extension/tree/main/tools/dashboards) -- Upstream GIE inference gateway dashboard
- [Grafana Operator docs](https://grafana.github.io/grafana-operator/) -- GrafanaDashboard, GrafanaDatasource CRD reference
- [OpenShift Monitoring](https://docs.openshift.com/container-platform/latest/observability/monitoring/monitoring-overview.html) -- Thanos Querier, User Workload Monitoring
