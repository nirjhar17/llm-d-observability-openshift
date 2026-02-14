# llm-d: How Your Model Gets Requests (and How We Fixed It)

> This guide explains how requests reach your LLM on OpenShift AI,
> what every piece does in plain English, and documents the bug we found and fixed.

---

## Table of Contents

1. [The Simple Version -- What Is All This Stuff?](#1-simple-version)
2. [Your 3 Gateways -- Why Do I Have Three?](#2-your-3-gateways)
3. [How a Request Travels -- Step by Step](#3-request-flow)
4. [The Bug We Found and Fixed](#4-the-bug)
5. [How to Check Each Layer (Debugging)](#5-debugging)
6. [Copy-Paste Commands](#6-commands)

---

## 1. The Simple Version -- What Is All This Stuff? <a name="1-simple-version"></a>

Imagine you're ordering food from a restaurant chain that has multiple kitchens:

```
YOU (curl / browser / GuideLLM)
 |
 |  "I want a chat completion"
 v
GATEWAY = The front door. It receives your request from the internet.
 |
 |  "This request is for the Qwen model"
 v
EPP = The smart host. It looks at ALL kitchens and picks the
      best one (least busy, most cache, shortest queue).
 |
 |  "Send this to Kitchen #2, it has the prefix cached"
 v
vLLM POD = The kitchen. It actually runs your model and
           generates the tokens.
```

That's it. Three pieces: **Gateway** (front door), **EPP** (smart host), **vLLM** (kitchen).

### Every Term Explained Simply

| Term | Simple Explanation |
|------|-------------------|
| **Gateway** | A pod running Envoy proxy. It's the entry point from the internet. Creates an AWS load balancer URL you can curl. |
| **HTTPRoute** | A rule that says "if someone goes to URL X, send them to backend Y". Like a restaurant menu that says "pizza is in kitchen A, pasta is in kitchen B". |
| **Envoy** | The software inside the Gateway pod. It does the actual work of receiving, routing, and forwarding requests. You don't interact with it directly. |
| **InferencePool** | A group of model pods (your vLLM replicas) + a pointer to the EPP service. It tells the system "these pods serve the same model, use EPP to pick between them". |
| **EPP** | Endpoint Picker Protocol. A small gRPC server that Envoy asks "which pod should I send this to?" before every request. It knows each pod's queue depth, memory usage, and cache state. |
| **ext-proc** | External Processing filter. This is HOW Envoy talks to EPP. Envoy has a built-in feature called "ext-proc" that can send request data to an external server. That external server is EPP. |
| **vLLM** | Your model server. Runs the actual LLM. Exposes an OpenAI-compatible API at `/v1/chat/completions`. |
| **EnvoyFilter** | A Kubernetes resource that lets you modify Envoy's behavior without rebuilding it. Like a config patch. We used this to fix the bug. |
| **Headless Service** | A Kubernetes Service that doesn't have a single IP address. Instead, it gives you the individual IPs of each pod. This lets EPP route to a SPECIFIC pod, not just "any pod in the group". |

### How EPP Picks the Best Pod

EPP scores every vLLM pod on three things, then picks the one with the highest total score:

| What It Checks | Plain English | Score Weight |
|---------------|---------------|-------------|
| **Queue depth** | How many requests are waiting in line at this pod? Less = better. | 2 |
| **KV cache usage** | How full is this pod's GPU memory? Less full = better. | 2 |
| **Prefix cache** | Does this pod already have the user's prompt cached from a previous request? If yes, much faster! | 3 (most important) |

---

## 2. Your 3 Gateways -- Why Do I Have Three? <a name="2-your-3-gateways"></a>

This is confusing because you have **3 front doors** to the same building. Here's why:

```
YOUR CLUSTER
│
├── data-science-gateway ......... For the RHOAI Dashboard, Notebooks, Pipelines.
│                                  NOT for your model. You never send model
│                                  requests here. Ignore it for inference.
│
├── openshift-ai-inference ....... Created automatically by the LLMInferenceService
│                                  operator when you deployed your model.
│                                  NO authentication. Open to anyone with the URL.
│                                  Good for testing.
│
└── maas-gateway ................. Created by YOU (from the MaaS blog post).
                                   HAS authentication (Kuadrant AuthPolicy).
                                   HAS rate limiting (Kuadrant RateLimitPolicy).
                                   This is your "production" endpoint.
```

### Side by Side

|  | data-science-gateway | openshift-ai-inference | maas-gateway |
|--|---------------------|----------------------|-------------|
| **Created by** | RHOAI platform | LLMInferenceService operator | You (manually) |
| **What it's for** | Dashboard, notebooks | Testing model access | Production model access |
| **Serves your model?** | No | **Yes** | **Yes** |
| **Needs auth?** | Yes (OAuth) | **No** (open!) | **Yes** (API key) |
| **Uses EPP?** | No | **Yes** | **Yes** |
| **Same vLLM pods?** | N/A | **Yes** (same 2 pods) | **Yes** (same 2 pods) |

### The Key Point

`openshift-ai-inference` and `maas-gateway` are **two different doors into the same room**. They both reach the same InferencePool, the same EPP, and the same vLLM pods. The only difference is authentication.

For testing, use `openshift-ai-inference` (no auth needed, just curl it).
For real users, use `maas-gateway` (has API key protection).

### How to Find Your Gateway URLs

```bash
oc get gateway -A -o custom-columns=\
'NAME:.metadata.name,ADDRESS:.status.addresses[0].value'
```

---

## 3. How a Request Travels -- Step by Step <a name="3-request-flow"></a>

### The Path of a Chat Completion Request

```
YOU                     GATEWAY POD               EPP POD             vLLM POD
 |                          |                        |                    |
 |---POST /v1/chat/----->   |                        |                    |
 |   completions            |                        |                    |
 |   (with JSON body)       |                        |                    |
 |                          |                        |                    |
 |                     1. Receives your request      |                    |
 |                     2. Matches the URL to an      |                    |
 |                        HTTPRoute rule             |                    |
 |                     3. Rule says: "this goes      |                    |
 |                        to InferencePool"          |                    |
 |                     4. Sends headers+body ------> |                    |
 |                        to EPP via ext-proc        |                    |
 |                                                   |                    |
 |                                              5. EPP scores            |
 |                                                 all vLLM pods         |
 |                                              6. Picks the best one    |
 |                                              7. Returns "use pod      |
 |                     8. Receives EPP's  <------   10.128.16.25"        |
 |                        decision                   |                    |
 |                     9. Forwards the FULL          |                    |
 |                        request (headers+body) -----------------------> |
 |                                                                   10. vLLM runs
 |                                                                       the model
 |                                                                   11. Returns
 |                     12. Forwards response <------------------------   tokens
 | <---response------- back to you                                       |
 |                          |                        |                    |
```

### The 3 URL Rules (HTTPRoute)

Your model has 3 URL paths. Each takes a **different route**:

| URL Path | Goes Through EPP? | Backend |
|----------|-------------------|---------|
| `/my-first-model/qwen3-0-6b/v1/chat/completions` | **Yes** (InferencePool) | EPP picks the best vLLM pod |
| `/my-first-model/qwen3-0-6b/v1/completions` | **Yes** (InferencePool) | EPP picks the best vLLM pod |
| `/my-first-model/qwen3-0-6b/v1/models` (or anything else) | **No** (direct Service) | Round-robin to any vLLM pod |

This is why `/v1/models` (GET) always worked but `/v1/chat/completions` (POST) was broken -- they take different paths inside the cluster!

### Important: The Model Name

When you send a request to vLLM, the `"model"` field in your JSON body must match what vLLM registered. On our cluster:

- **Wrong**: `"model": "qwen3-0-6b"` (this is the Kubernetes name)
- **Right**: `"model": "Qwen/Qwen3-0.6B"` (this is the HuggingFace name vLLM uses)

To check: `curl -sk "https://$GW/my-first-model/qwen3-0-6b/v1/models"`

---

## 4. The Bug We Found and Fixed <a name="4-the-bug"></a>

### What Was Broken

When you sent a POST request (chat completion) through the Gateway:

```
What you sent:     {"model":"Qwen/Qwen3-0.6B", "messages":[...]}  (89 bytes)
What Envoy got:    89 bytes (correct!)
What vLLM got:     NOTHING (empty body!)
What vLLM said:    400 "Field required" (because the body was empty)
```

The request body (your JSON with the prompt) was disappearing somewhere between Envoy and vLLM.

### Why It Was Broken

**The short version**: Istio 1.26.2 has a bug in how it handles request bodies when using the InferencePool/EPP feature.

**The longer version**:

When Envoy sends your request to EPP for routing decisions, it uses a feature called `ext-proc` (External Processing). This feature has a setting called `request_body_mode` that controls how the request body is handled:

- `BUFFERED` = Send the whole body to EPP at once, then forward it to vLLM. **Simple and reliable.**
- `FULL_DUPLEX_STREAMED` = Stream the body to EPP in chunks. **Complex and new.**

Istio 1.26.2 was setting `FULL_DUPLEX_STREAMED` mode. In this mode, the body was being sent to EPP for processing, but **never forwarded to vLLM**. The body got "eaten" by the ext-proc filter.

### How We Fixed It

We applied an **EnvoyFilter** (a Kubernetes resource that patches Envoy's config) that changes the body mode from `FULL_DUPLEX_STREAMED` to `BUFFERED`:

```bash
oc apply -f manifests/08-envoyfilter-fix-extproc-body.yaml
```

That's it. One YAML file. The result:

```
BEFORE the fix:  POST /v1/chat/completions → 400 "body required"
AFTER the fix:   POST /v1/chat/completions → 200 OK (model responds!)
```

### What We Tried First (That Didn't Work)

| Attempt | What Happened |
|---------|--------------|
| Upgrade Istio from 1.26.2 to 1.27.3 (which fixes the bug natively) | The Sail operator (Service Mesh 3) keeps reverting the version back to 1.26.2 within seconds |
| Remove the ownership reference so the operator stops controlling it | Sail operator re-adds the ownership AND reverts the version |
| Scale down the RHOAI operator, then upgrade | Sail operator (not RHOAI) is the one controlling the version, so RHOAI being down didn't help |
| Upgrade RHOAI to a newer version | Already on latest (3.2.0), no newer version available |

The EnvoyFilter was the only approach that worked because it patches Envoy directly without changing any operator-managed resources.

### Is This Fix Permanent?

- **Yes**, the EnvoyFilter persists across pod restarts and cluster reboots.
- **When Istio is eventually upgraded to 1.27+** (in a future RHOAI release), this EnvoyFilter can be removed because 1.27 fixes the body forwarding natively.
- The fix currently only applies to the `openshift-ai-inference` gateway. To also fix `maas-gateway`, apply a second EnvoyFilter (see the manifest file for instructions).

---

## 5. How to Check Each Layer (Debugging) <a name="5-debugging"></a>

If something breaks in the future, check these layers in order.

### Check 1: Is the Gateway running?

```bash
oc get pods -A -l 'gateway.networking.k8s.io/gateway-name'
```

**Good output**: All pods show `1/1 Running`
**Bad output**: `CrashLoopBackOff` or `0/1`

### Check 2: Does the Gateway have an external URL?

```bash
oc get gateway -A
```

Look for an address in `STATUS`. If it says `<none>`, the load balancer wasn't created.

### Check 3: Are the routes attached?

```bash
oc get httproute -A
```

Every route should show `Accepted: True` in its status.

### Check 4: Is the InferencePool working?

```bash
oc get inferencepool.inference.networking.x-k8s.io -A
```

It should exist and show `Accepted: True`.

### Check 5: Is EPP running?

```bash
oc get pods -n my-first-model | grep scheduler
```

Should be `1/1 Running`. Check logs if not:

```bash
oc logs -n my-first-model deploy/qwen3-0-6b-kserve-router-scheduler --tail=20
```

**Good sign**: `gRPC server listening {"name": "ext-proc", "port": 9002}`

### Check 6: Are the vLLM pods running?

```bash
oc get pods -n my-first-model -l app.kubernetes.io/name=qwen3-0-6b
```

Should show your replicas as `Running`.

### Check 7: Is the EnvoyFilter applied?

```bash
oc get envoyfilter -n openshift-ingress
```

Should show `fix-extproc-body-mode`. If it's missing, re-apply it:

```bash
oc apply -f manifests/08-envoyfilter-fix-extproc-body.yaml
```

### Check 8: Quick end-to-end test

```bash
export GW=$(oc get gateway openshift-ai-inference -n openshift-ingress \
  -o jsonpath='{.status.addresses[0].value}')

# Does vLLM respond? (bypasses EPP)
curl -sk "https://$GW/my-first-model/qwen3-0-6b/v1/models"

# Does chat completion work? (goes through EPP)
curl -sk -X POST "https://$GW/my-first-model/qwen3-0-6b/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model":"Qwen/Qwen3-0.6B","messages":[{"role":"user","content":"Hi"}],"max_tokens":5}'
```

If the first works but the second gives `400 "body required"`, the EnvoyFilter is missing.
If the second gives `404 "model does not exist"`, the model name is wrong (check `/v1/models` output).

### Check 9: The Envoy access log (most useful for debugging)

```bash
GWPOD=$(oc get pods -n openshift-ingress \
  -l gateway.networking.k8s.io/gateway-name=openshift-ai-inference \
  -o jsonpath='{.items[0].metadata.name}')
oc logs -n openshift-ingress $GWPOD -c istio-proxy --tail=5
```

Each line is one request. Here's how to read the important parts:

```
[timestamp] "POST /v1/chat/completions HTTP/2" 200 - via_upstream - "-" 106 656 694
                                                ^^^                     ^^^     ^^^
                                           HTTP status              body size  time(ms)
```

- `200` = success
- `400` = body was stripped (EnvoyFilter missing)
- `404` = wrong model name
- `401` = auth required (you're hitting maas-gateway, use openshift-ai-inference)

The access log also shows which vLLM pod handled the request:

```
"10.128.16.25:8000" outbound|54321||...inference-pool-ip-...
 ^^^^^^^^^^^^^^^^^  ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
 The specific pod   Went through InferencePool (EPP routing)
```

If you see `outbound|8000||...kserve-workload-svc...` instead, the request went to the direct Service (no EPP). This happens for `/v1/models` and other catch-all paths.

---

## 6. Copy-Paste Commands <a name="6-commands"></a>

### Set Up Your Environment

```bash
# Gateway URL (no auth)
export GW=$(oc get gateway openshift-ai-inference -n openshift-ingress \
  -o jsonpath='{.status.addresses[0].value}')
echo "Gateway: https://$GW"
```

### Test the Model

```bash
# Health check
curl -sk "https://$GW/my-first-model/qwen3-0-6b/v1/models" | python3 -m json.tool

# Chat completion
curl -sk -X POST "https://$GW/my-first-model/qwen3-0-6b/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model":"Qwen/Qwen3-0.6B","messages":[{"role":"user","content":"Hello!"}],"max_tokens":20}' \
  | python3 -m json.tool
```

### Check Versions

```bash
oc get istio -A                    # Istio version (e.g., v1.26.2)
oc get csv -n openshift-operators | grep servicemesh3  # OSSM3 operator version
oc get csv -n redhat-ods-operator | grep rhods         # RHOAI version
```

### Check All Resources for Your Model

```bash
oc get pods,svc,deploy -n my-first-model
oc get inferencepool.inference.networking.x-k8s.io -n my-first-model
oc get httproute -n my-first-model
oc get envoyfilter -n openshift-ingress
```

### Watch Logs (Open 3 Terminals)

```bash
# Terminal 1: Envoy (shows every request)
GWPOD=$(oc get pods -n openshift-ingress \
  -l gateway.networking.k8s.io/gateway-name=openshift-ai-inference \
  -o jsonpath='{.items[0].metadata.name}')
oc logs -f -n openshift-ingress $GWPOD -c istio-proxy

# Terminal 2: EPP (shows routing decisions)
oc logs -f -n my-first-model deploy/qwen3-0-6b-kserve-router-scheduler

# Terminal 3: Send a request
curl -sk -X POST "https://$GW/my-first-model/qwen3-0-6b/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model":"Qwen/Qwen3-0.6B","messages":[{"role":"user","content":"Hi"}],"max_tokens":5}'
```

---

## Appendix: What the LLMInferenceService Creates Automatically

When you deploy a model using `LLMInferenceService`, the operator creates ALL of these for you:

```
LLMInferenceService (qwen3-0-6b)           <-- You create ONLY this
    |
    |-- Deployment (qwen3-0-6b-kserve)               = vLLM pods (your model)
    |-- Deployment (qwen3-0-6b-kserve-router-scheduler) = EPP pod (smart router)
    |-- Service (qwen3-0-6b-kserve-workload-svc)     = Direct access to vLLM
    |-- Service (qwen3-0-6b-epp-service)              = EPP gRPC service
    |-- InferencePool (qwen3-0-6b-inference-pool)     = Groups vLLM pods + EPP
    |      |-- Headless Service (auto-created by Istio)
    |-- HTTPRoute (qwen3-0-6b-kserve-route)           = URL routing rules
    |-- DestinationRule (x2)                           = TLS settings
```

You don't need to create any of these manually. The only thing you might need to add manually is:
- The **EnvoyFilter** (to fix the body-forwarding bug on Istio 1.26)
- The **maas-gateway HTTPRoute** (if you want auth/rate-limiting via Kuadrant)
