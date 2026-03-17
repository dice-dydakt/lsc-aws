# AWS Cloud Lab — Technical Reference

This document explains the concepts, implementation details, and AWS services involved in the lab. Each section links to the relevant AWS documentation for further reading.

---

## Table of Contents

1. [Core Concepts](#1-core-concepts)
2. [Application Architecture](#2-application-architecture)
3. [AWS Lambda — Deep Dive](#3-aws-lambda--deep-dive)
4. [ECS Fargate — Deep Dive](#4-ecs-fargate--deep-dive)
5. [EC2 — Deep Dive](#5-ec2--deep-dive)
6. [Load Testing Methodology](#6-load-testing-methodology)
7. [Cost Models](#7-cost-models)
8. [Implementation Details](#8-implementation-details)

---

## 1. Core Concepts

### 1.1 Cold Starts

A **cold start** occurs when a request arrives and no pre-initialized execution environment is available. The system must provision resources before it can handle the request. Different environments have fundamentally different cold start profiles:

| Environment | Cold start trigger | Duration | Frequency |
|---|---|---|---|
| Lambda | First request after idle (~15min), scale-out, deployment | 0.5–3s | Per-request (when no warm env) |
| Fargate | New task provisioning (scale-out) | 30–90s | Per task (rare with pre-started tasks) |
| EC2 | Instance boot (rarely, since always-on) | 60–180s | Per instance (at launch time only) |

The key insight: **Lambda cold starts happen per request** but are short. **Fargate cold starts are per task** and are long, but don't affect individual requests once the task is running.

**AWS Documentation:**
- [Lambda execution environment lifecycle](https://docs.aws.amazon.com/lambda/latest/dg/lambda-runtime-environment.html)
- [Understanding Lambda cold starts](https://docs.aws.amazon.com/lambda/latest/dg/lambda-concurrency.html)

### 1.2 Latency Decomposition

Every request's end-to-end latency can be decomposed into phases:

```
Client-side total latency
├── DNS resolution          (first request only, typically cached)
├── TCP connection setup    (~1 RTT)
├── TLS handshake           (~1-2 RTT for HTTPS)
├── Request transmission    (negligible for small payloads)
├── Server processing
│   ├── Init Duration       (Lambda cold start only: runtime + code init)
│   └── Handler Duration    (actual computation: k-NN search)
├── Response transmission   (negligible)
└── TCP teardown            (async, not measured)
```

In this lab, **Init Duration** and **Handler Duration** are reported separately by Lambda's CloudWatch REPORT lines. Server-side compute time is also available in the response body as `query_time_ms`.

### 1.3 Percentile Latencies (p50, p95, p99)

Percentiles describe the distribution of latencies:

- **p50 (median):** 50% of requests are faster than this. Represents typical user experience.
- **p95:** 95% of requests are faster. Captures most tail latency.
- **p99:** 99% of requests are faster. The "worst reasonable case" — critical for SLOs.

Why p99 matters more than average: if you serve 1 million requests/day, p99 means 10,000 users experience latency above this threshold. A service with p50=50ms but p99=5000ms has a serious problem that averages hide.

### 1.4 Service Level Objectives (SLOs)

An SLO is a quantitative target for service behavior. This lab uses:

> **p99 latency < 500ms**

This means: 99% of all requests must complete in under 500ms. The SLO determines which environments are viable — an environment that is 50% cheaper but violates the SLO is not a valid choice (unless the SLO is renegotiated).

### 1.5 Pareto Optimality

A solution is **Pareto-optimal** if no other solution is better on ALL dimensions simultaneously. In our case, the dimensions are:

- **p99 latency** (lower is better)
- **Monthly cost** (lower is better)

Solution A **dominates** Solution B if A is better than or equal to B on every dimension and strictly better on at least one. A Pareto-dominated solution is never the best choice regardless of how you weight the dimensions.

---

## 2. Application Architecture

### 2.1 The k-NN Workload

The application performs a **brute-force L2 (Euclidean) nearest neighbor search**:

```python
# Core computation (~23ms on 0.5 vCPU)
dists = np.linalg.norm(DATASET - query, axis=1)   # L2 distance to all 50,000 vectors
top5_idx = np.argpartition(dists, 5)[:5]           # Partial sort for top-5
top5_idx = top5_idx[np.argsort(dists[top5_idx])]   # Sort the top-5 by distance
```

This workload was chosen because:
- **Significant initialization cost:** Generating 50,000 × 128 float32 vectors (~24MB) takes 300–600ms, making Lambda's Init Duration clearly visible.
- **Tunable compute cost:** The k-NN search takes ~23ms per request — enough to measure, not so much that it dominates all other latency components.
- **No external dependencies:** Pure NumPy computation with no database or network calls, eliminating confounding variables.
- **Real-world relevance:** Similar to embedding lookup, recommendation engines, and anomaly detection services.

### 2.2 Dual-Mode Docker Image

The same Docker image serves both Lambda and Flask modes, controlled by the `MODE` environment variable:

```
Dockerfile (FROM public.ecr.aws/lambda/python:3.12)
    │
    ├── MODE=server  → entrypoint.sh runs: python app.py  (Flask on port 8080)
    │                   Used by: Fargate, EC2
    │
    └── MODE unset   → entrypoint.sh runs: python -m awslambdaric handler.lambda_handler
                        Used by: Lambda (container image deployment)
```

**Why a single image?** It ensures all environments run identical code. Any performance difference is attributable to the environment, not the application.

**AWS Documentation:**
- [Lambda container image support](https://docs.aws.amazon.com/lambda/latest/dg/images-create.html)
- [Lambda base images](https://docs.aws.amazon.com/lambda/latest/dg/runtimes-images.html)
- [AWS Lambda Runtime Interface Client](https://docs.aws.amazon.com/lambda/latest/dg/runtimes-images.html#runtimes-api-client)

### 2.3 Lambda Zip vs. Container Deployment

Lambda supports two packaging formats:

| | Zip Deployment | Container Image |
|---|---|---|
| **Package** | `.zip` with handler code | Docker image in ECR |
| **Dependencies** | Lambda Layers (NumPy layer) | Bundled in image |
| **Max size** | 50 MB (zip) / 250 MB (unzipped) | 10 GB |
| **Cold start** | Generally faster (smaller package) | Image caching reduces gap |
| **Handler** | `handler.py` (no Flask, direct computation) | Same image as Fargate/EC2 |

The zip handler (`handler.py`) avoids importing Flask to minimize package size and cold start time. It parses the Lambda Function URL event directly and returns a response dict.

**AWS Documentation:**
- [Lambda deployment packages](https://docs.aws.amazon.com/lambda/latest/dg/gettingstarted-package.html)
- [Lambda layers](https://docs.aws.amazon.com/lambda/latest/dg/chapter-layers.html)
- [Lambda Function URLs](https://docs.aws.amazon.com/lambda/latest/dg/lambda-urls.html)

---

## 3. AWS Lambda — Deep Dive

### 3.1 Execution Environment Lifecycle

```
REQUEST ARRIVES
    │
    ├── Warm environment available? ──YES──→ INVOKE handler
    │                                           │
    NO                                          ▼
    │                                       RESPONSE
    ▼
COLD START
    ├── 1. Allocate microVM (Firecracker)
    ├── 2. Initialize runtime (Python 3.12)
    ├── 3. Load deployment package (zip or container image)
    ├── 4. Execute global scope (imports, dataset generation)
    │      └── This is "Init Duration" in CloudWatch
    ├── 5. INVOKE handler
    │      └── This is "Duration" in CloudWatch
    └── 6. RESPONSE
         └── Environment stays warm for ~15 minutes
```

After a response, the execution environment remains warm and can serve subsequent requests without repeating steps 1–4. AWS does not document the exact idle timeout, but it is empirically observed to be approximately 15 minutes (and varies).

**AWS Documentation:**
- [Lambda execution environment](https://docs.aws.amazon.com/lambda/latest/dg/lambda-runtime-environment.html)
- [Firecracker microVM](https://firecracker-microvm.github.io/) (open-source)

### 3.2 Concurrency and Scaling

Lambda creates one execution environment per concurrent request. If 50 requests arrive simultaneously and only 10 warm environments exist, Lambda provisions 40 new ones (each with a cold start).

```
Concurrent requests:     50
Warm environments:       10
Cold starts triggered:   40
```

This is why Scenario C (burst from zero) triggers multiple cold starts — and why Lambda's p99 under burst is dominated by cold-start latency.

**Provisioned Concurrency** pre-warms a specified number of environments. With 10 provisioned concurrent environments, the first 10 requests always skip Init Duration. This eliminates cold starts at the cost of continuous charges (~$0.0000097315/GB-second).

**AWS Documentation:**
- [Lambda concurrency](https://docs.aws.amazon.com/lambda/latest/dg/lambda-concurrency.html)
- [Provisioned concurrency](https://docs.aws.amazon.com/lambda/latest/dg/provisioned-concurrency.html)
- [Reserved concurrency](https://docs.aws.amazon.com/lambda/latest/dg/configuration-concurrency.html)

### 3.3 Function URLs

Function URLs provide a dedicated HTTPS endpoint for a Lambda function without API Gateway. This eliminates API Gateway's 5–15ms overhead.

```
https://<url-id>.lambda-url.<region>.on.aws/
```

Function URLs can use two auth types:
- **NONE:** Public access (may be blocked by organization SCPs in Academy accounts)
- **AWS_IAM:** Requests must be signed with SigV4

**AWS Documentation:**
- [Lambda Function URLs](https://docs.aws.amazon.com/lambda/latest/dg/urls-configuration.html)
- [Function URL security](https://docs.aws.amazon.com/lambda/latest/dg/urls-auth.html)

### 3.4 X-Ray Tracing

AWS X-Ray captures per-invocation trace data, including Init Duration as a separate segment. Enable it with `--tracing-config Mode=Active`.

The CloudWatch `REPORT` log line for each invocation includes:
```
REPORT RequestId: abc123
    Duration: 77.00 ms          ← Handler execution time
    Billed Duration: 78 ms      ← Rounded up to nearest 1ms
    Memory Size: 512 MB         ← Configured memory
    Max Memory Used: 144 MB     ← Actual peak usage
    Init Duration: 613.30 ms    ← ONLY present on cold starts
```

**AWS Documentation:**
- [Lambda + X-Ray](https://docs.aws.amazon.com/lambda/latest/dg/services-xray.html)
- [X-Ray concepts](https://docs.aws.amazon.com/xray/latest/devguide/xray-concepts.html)
- [CloudWatch Lambda metrics](https://docs.aws.amazon.com/lambda/latest/dg/monitoring-metrics.html)

---

## 4. ECS Fargate — Deep Dive

### 4.1 Architecture

```
Internet → ALB (port 80) → Target Group → Fargate Task (port 8080)
                                              │
                                              ├── Container: knn-app
                                              │   └── MODE=server → Flask
                                              ├── 0.5 vCPU, 1 GB RAM
                                              └── awsvpc networking
```

Fargate runs containers without managing EC2 instances. You define a **task definition** (CPU, memory, container image, environment variables) and a **service** (desired count, networking, load balancer).

### 4.2 Key Components

| Component | Purpose | AWS Documentation |
|---|---|---|
| **ECS Cluster** | Logical grouping of tasks/services | [ECS clusters](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/clusters.html) |
| **Task Definition** | Template: image, CPU, memory, env vars, ports | [Task definitions](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task_definitions.html) |
| **Service** | Maintains desired count of running tasks | [ECS services](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/ecs_services.html) |
| **ALB** | Routes HTTP traffic to healthy task IPs | [ALB docs](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/introduction.html) |
| **Target Group** | Health-checked set of task IPs | [Target groups](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/load-balancer-target-groups.html) |
| **ECR** | Docker image registry | [ECR docs](https://docs.aws.amazon.com/AmazonECR/latest/userguide/what-is-ecr.html) |

### 4.3 Networking: `awsvpc` Mode

Fargate tasks use `awsvpc` networking — each task gets its own ENI (Elastic Network Interface) with a private IP in your VPC. For tasks in the default VPC (no NAT gateway), `assignPublicIp: ENABLED` is required so the task can:
1. Pull container images from ECR
2. Send logs to CloudWatch
3. Receive traffic from the ALB

**AWS Documentation:**
- [Fargate networking](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/fargate-task-networking.html)
- [awsvpc mode](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task-networking-awsvpc.html)

### 4.4 Fargate vs. Lambda: Scale-Out Behavior

| Dimension | Lambda | Fargate |
|---|---|---|
| **Scale unit** | Single request | Entire task (container) |
| **Scale-out time** | ~0.5–2s (cold start) | 30–90s (task provisioning) |
| **Concurrency per unit** | 1 request per environment | Many requests per task |
| **Idle cost** | $0 | Continuous (per-second billing) |
| **Max scale** | 1000 concurrent (default) | Service desired count limit |

In this lab, a single Fargate task handles all requests. Although Flask's dev server is multi-threaded by default (since Flask 1.0), concurrency is still limited by the GIL and available CPU — see [Section 8.5](#85-flask-development-server-threading-and-queuing) for details. At concurrency=50, queuing and CPU contention become the dominant latency factors — not per-request compute.

---

## 5. EC2 — Deep Dive

### 5.1 Architecture

```
Internet → EC2 Public IP:8080 → Docker container → Flask app
```

The EC2 instance runs the same Docker image as Fargate, with `MODE=server`. It provides the cleanest baseline because:
- No load balancer overhead (direct IP access)
- No container orchestration overhead
- Always-warm (no provisioning delay after launch)

### 5.2 Instance Type: t3.small

| Spec | Value |
|---|---|
| vCPUs | 2 |
| Memory | 2 GB |
| Network | Up to 5 Gbps |
| Baseline CPU | 20% (burstable) |
| On-demand price | $0.023/hr (us-east-1) |

The `t3` family uses **CPU credits** for burstable performance. The baseline is 20% of 2 vCPUs. During the k-NN computation (~23ms per request), a single request uses well under the baseline, so credit consumption is minimal. Under burst (c=50), concurrent requests contend for the GIL and CPU, but per-request CPU usage remains constant.

**AWS Documentation:**
- [EC2 instance types](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/instance-types.html)
- [Burstable instances](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/burstable-performance-instances.html)
- [EC2 pricing](https://aws.amazon.com/ec2/pricing/on-demand/)

### 5.3 User Data

The EC2 instance uses a **user-data script** — a shell script that runs automatically at first boot:

```bash
#!/bin/bash
yum install -y docker
systemctl enable docker && systemctl start docker
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin <ECR_URI>
docker pull <ECR_URI>:latest
docker run -d -p 8080:8080 -e MODE=server --restart always --name knn-app <ECR_URI>:latest
```

The instance profile (LabRole) provides IAM credentials for ECR access without embedding secrets.

**AWS Documentation:**
- [EC2 user data](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/user-data.html)
- [Instance profiles](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_use_switch-role-ec2_instance-profiles.html)

---

## 6. Load Testing Methodology

### 6.1 Tools

| Tool | Used For | Why |
|---|---|---|
| **`oha`** | All targets (Lambda, Fargate, EC2) | Single binary with native AWS SigV4 support, percentile reporting, histograms |
| **`lambda_loadtest.py`** | Alternative Lambda tester | Python-based, auto-discovers AWS credentials from profiles/instance roles |
| **`awscurl`** | Ad-hoc Lambda testing | CLI tool with SigV4 support |

All scenario scripts use `oha` as the single load testing tool. For Lambda endpoints, `oha` signs requests automatically via `--aws-sigv4`. This ensures consistent measurement methodology across all targets.

### 6.2 What `oha` Reports

```
Summary:
  Success rate:   100.00%
  Total:          5.2341 sec          ← Wall-clock time for all requests
  Slowest:        1.4585 sec          ← Maximum latency (p100)
  Fastest:        0.2962 sec          ← Minimum latency
  Average:        0.3645 sec          ← Arithmetic mean
  Requests/sec:   95.5267             ← Throughput

Response time distribution:
  10.00% in 0.3097 sec
  25.00% in 0.3160 sec
  50.00% in 0.3367 sec                ← p50 (median)
  75.00% in 0.3594 sec
  90.00% in 0.3953 sec
  95.00% in 0.4356 sec                ← p95
  99.00% in 1.3272 sec                ← p99
```

The **response time distribution** is the most important output. Focus on p50, p95, and p99.

**`oha` GitHub:** https://github.com/hatoo/oha

### 6.3 Measurement Confounds

| Confound | Impact | Mitigation |
|---|---|---|
| **Network RTT** | Adds constant offset to all client-side times | Measure from in-region EC2; report server-side times separately |
| **TLS handshake** | HTTPS endpoints have ~50ms overhead (connection reuse helps) | `oha` reuses connections; first request is slower |
| **ALB overhead** | Adds ~2-5ms for Fargate | Acknowledge in analysis; compare to EC2 baseline |
| **DNS resolution** | First request may be slow | Pre-resolve or warm up before measuring |
| **Client-side contention** | Load generator CPU can become bottleneck at high concurrency | Use dedicated EC2 instance for load generation |

### 6.4 Statistical Validity

- **Sample size:** 500 requests per measurement provides reliable p95/p99 estimates.
- **Warm-up:** 20 requests before measurement ensures Lambda environments are warm and OS page caches are populated.
- **Reproducibility:** Fixed query vector (seed=42) and deterministic dataset (seed=0) ensure identical computation across all environments.

---

## 7. Cost Models

### 7.1 Lambda Pricing

Lambda charges for two things:

1. **Requests:** $0.20 per 1 million requests
2. **Compute:** $0.0000166667 per GB-second

GB-seconds = `memory_allocated_GB × execution_duration_seconds × number_of_requests`

Duration is rounded up to the nearest 1ms (changed from 100ms in Dec 2020).

```
Example: 1M requests, 77ms each, 512MB memory
  Request cost:  1,000,000 × $0.20/1M = $0.20
  GB-seconds:    1,000,000 × 0.077 × 0.5 = 38,500
  Compute cost:  38,500 × $0.0000166667 = $0.6417
  Total:         $0.84/month
```

**Free tier:** 1M requests and 400,000 GB-seconds per month (first 12 months).

**Provisioned Concurrency:** $0.0000097315 per GB-second, billed continuously for all provisioned environments regardless of invocations.

**AWS Documentation:**
- [Lambda pricing](https://aws.amazon.com/lambda/pricing/)
- [Lambda billing FAQ](https://docs.aws.amazon.com/lambda/latest/dg/monitoring-metrics.html#monitoring-metrics-invocation)

### 7.2 Fargate Pricing

Fargate charges per-second (1-minute minimum) for allocated vCPU and memory:

| Resource | Price (us-east-1) |
|---|---|
| vCPU per hour | $0.04048 |
| GB memory per hour | $0.004445 |

```
Example: 0.5 vCPU, 1 GB, running 24/7
  vCPU cost:   0.5 × $0.04048 × 24 × 30 = $14.57
  Memory cost: 1.0 × $0.004445 × 24 × 30 = $3.20
  Total:       $17.77/month
```

This is charged regardless of traffic — idle tasks cost the same as busy ones.

**AWS Documentation:**
- [Fargate pricing](https://aws.amazon.com/fargate/pricing/)
- [ECS pricing overview](https://aws.amazon.com/ecs/pricing/)

### 7.3 EC2 Pricing

EC2 on-demand pricing for t3.small in us-east-1: **$0.023/hour**.

```
Monthly cost: $0.023 × 24 × 30 = $16.56
```

Alternatives:
- **Reserved Instance (1yr, no upfront):** ~$0.014/hr → $10.08/month (39% savings)
- **Spot Instance:** ~$0.007/hr → $5.04/month (70% savings, but can be interrupted)
- **Savings Plans:** Similar to RI, more flexible

**AWS Documentation:**
- [EC2 on-demand pricing](https://aws.amazon.com/ec2/pricing/on-demand/)
- [EC2 Reserved Instances](https://aws.amazon.com/ec2/pricing/reserved-instances/)
- [Savings Plans](https://aws.amazon.com/savingsplans/)

### 7.4 Break-Even Analysis

The break-even point is where Lambda's variable cost equals an always-on alternative's fixed cost:

```
Lambda monthly cost = Fixed monthly cost

Let R = average RPS
    D = handler duration (seconds)
    M = memory (GB)
    S = seconds per month = 2,592,000

Per-request Lambda cost:
    C_req = $0.20 / 1,000,000 = $0.0000002
    C_compute = D × M × $0.0000166667

Total Lambda cost:
    R × S × (C_req + C_compute) = Fixed cost

Solving for R:
    R = Fixed cost / (S × (C_req + C_compute))
```

With D=0.077s, M=0.5GB, Fixed=$16.56 (EC2):
```
R = $16.56 / (2,592,000 × ($0.0000002 + 0.077 × 0.5 × $0.0000166667))
R = $16.56 / (2,592,000 × $0.000000842)
R = $16.56 / $2.182
R ≈ 7.6 RPS
```

---

## 8. Implementation Details

### 8.1 File: `workload/app.py`

The Flask application serving the k-NN endpoint. Key design decisions:

- **Dataset at global scope:** `DATASET = generate_dataset()` executes at import time. In Lambda, this runs during Init Duration. In Fargate/EC2, it runs once at container start.
- **Cold start flag:** `COLD_START = True` is set globally and flipped to `False` on first request. This is per-process, not per-container — if a WSGI server forks workers, each worker tracks its own cold start.
- **Instance ID:** `os.environ.get("AWS_LAMBDA_LOG_STREAM_NAME", socket.gethostname())` — Lambda's log stream name uniquely identifies execution environments; hostname works for containers.

### 8.2 File: `workload/handler.py`

The Lambda zip handler. Key design decisions:

- **No Flask import:** The zip handler parses the Function URL event directly to avoid bundling Flask in the zip package (keeping it under 50MB with just NumPy from the layer).
- **Function URL event format:** The `event` dict contains `body` (JSON string), `requestContext`, `headers`, etc. The handler parses `event["body"]` and returns a dict with `statusCode`, `headers`, and `body`.
- **Shared computation:** Both `app.py` and `handler.py` import `generate_dataset` and use the same NumPy computation. The dataset is generated independently in each file's global scope.

**AWS Documentation:**
- [Lambda Function URL event format](https://docs.aws.amazon.com/lambda/latest/dg/urls-invocation.html)
- [Lambda Python handler](https://docs.aws.amazon.com/lambda/latest/dg/python-handler.html)

### 8.3 File: `workload/Dockerfile`

```dockerfile
FROM public.ecr.aws/lambda/python:3.12  # Lambda base image with RIC
COPY requirements.txt ${LAMBDA_TASK_ROOT}/
RUN pip install --no-cache-dir -r ${LAMBDA_TASK_ROOT}/requirements.txt
COPY app.py handler.py generate_dataset.py ${LAMBDA_TASK_ROOT}/
COPY entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
CMD ["handler.lambda_handler"]
```

- **Base image:** `public.ecr.aws/lambda/python:3.12` includes the Lambda Runtime Interface Client (RIC) and Runtime Interface Emulator (RIE). When deployed to Lambda, the actual Lambda runtime replaces the emulator.
- **`LAMBDA_TASK_ROOT`:** Set to `/var/task` by the Lambda base image. All application code goes here.
- **`ENTRYPOINT`:** In Lambda mode, this is overridden by the Lambda runtime. In server mode (`MODE=server`), `entrypoint.sh` runs Flask directly.

### 8.4 File: `deploy/04-fargate.sh`

The most complex deployment script. Notable implementation details:

- **Subnet selection:** ALBs require subnets in at least 2 AZs. The script takes the first 2 subnets from the default VPC — these are typically in different AZs.
- **Security groups:** Two separate groups — one for the ALB (allows port 80 from anywhere) and one for the task (allows port 8080 only from the ALB security group). This implements the principle of least privilege.
- **Health check:** The task definition includes a container health check (`curl http://localhost:8080/health`), and the ALB target group has its own health check on `/health`. Both must pass before the task receives traffic.
- **`assignPublicIp: ENABLED`:** Required in the default VPC (no NAT gateway). Without it, the task cannot pull the container image from ECR or send logs to CloudWatch.

### 8.5 Flask Development Server, Threading, and Queuing

Fargate and EC2 run `app.run(host="0.0.0.0", port=8080)` — Flask's built-in Werkzeug development server. Since Flask 1.0, this server defaults to `threaded=True`, meaning it spawns a new thread for each incoming request rather than handling requests one at a time.

However, threading in Python does not automatically mean parallel execution. Python's **Global Interpreter Lock (GIL)** ensures that only one thread can execute Python bytecode at any given time. So even with multiple threads, the Python portions of request handling (JSON parsing, Flask routing, response building) are serialized.

#### Where NumPy changes the picture

The k-NN computation in this lab is almost entirely inside NumPy:

```python
dists = np.linalg.norm(DATASET - query, axis=1)
```

NumPy is written in C and **releases the GIL** before entering its native code for many operations (element-wise arithmetic, reductions, etc.). During the ~23ms of matrix computation, the GIL is not held, and another thread is free to execute Python code. When the C code finishes, it reacquires the GIL to return the result.

This means two concurrent requests can overlap like this:

```
Thread 1:  [parse JSON ~1ms] [--- NumPy (GIL released, ~23ms) ---] [response ~1ms]
Thread 2:  (waiting for GIL) [parse JSON] [--- NumPy (GIL released, ~23ms) ------] [response ~1ms]
```

Thread 2 cannot parse JSON until Thread 1 releases the GIL by entering NumPy's C code. Once both threads are inside NumPy, their C code can run in parallel on separate CPU cores. The Python portions still serialize on the GIL, but they are fast (~1-2ms) relative to the ~23ms computation, so the wait is short.

The practical limit is CPU cores:
- **Fargate (0.5 vCPU):** Only one core available, so two NumPy calls compete for it. You get concurrency (no queuing) but not parallelism (no speedup per request).
- **EC2 t3.small (2 vCPUs):** Two threads can genuinely compute in parallel on separate cores.

#### What a single-threaded server would look like

If the server were running with `threaded=False` (or equivalently, using a WSGI server like gunicorn with a single worker process), requests would be handled strictly one at a time. Every concurrent request would sit in a TCP accept queue waiting its turn. At concurrency=50 with ~23ms per request, the last request in the queue would wait ~50 × 23ms = 1150ms in the worst case.

In contrast, Lambda avoids this entirely — each invocation gets its own execution environment, so there is no shared queue regardless of concurrency.

#### Production considerations

In production, you would use a WSGI server like `gunicorn` with multiple worker processes. Each worker is a separate process with its own GIL, providing both concurrency and parallelism up to the CPU limit. For example, `gunicorn -w 4` on a 2-vCPU instance gives 4 independent processes that can handle requests truly in parallel.

When analyzing your results, consider what server configuration is in use and how it affects tail latency. The queuing behavior (or lack thereof) is a property of the server configuration, not of the Fargate/EC2 platform itself. Your analysis should distinguish between platform-level differences and server-level bottlenecks.

### 8.7 File: `loadtest/oha-helpers.sh`

Shared helper script sourced by all scenario scripts. Provides two wrapper functions:

- **`oha_lambda`** — calls `oha` with `--aws-sigv4 "aws:amz:<region>:lambda"` and AWS credentials for Lambda Function URL authentication.
- **`oha_http`** — calls `oha` without signing for Fargate/EC2 endpoints.

The helper auto-detects the `oha` binary (checks `PATH`, then `~/oha`) and loads AWS credentials from `~/.aws/credentials` or environment variables.

### 8.8 File: `loadtest/lambda_loadtest.py`

An alternative Python-based load tester that handles AWS SigV4 request signing using `botocore.auth.SigV4Auth`. Useful when `oha` is not available or when you need JSON output with per-request details (cold start detection, server-side timing).

Key implementation details:

- **SigV4 signing:** Uses `botocore.auth.SigV4Auth` to sign each request. Auto-discovers credentials from profiles, environment, or instance roles.
- **Concurrency:** Uses `ThreadPoolExecutor` with configurable worker count.
- **Sequential mode:** `--sequential-delay 1.0` sends one request per second.
- **Response parsing:** Extracts `query_time_ms` and `cold_start` from the response body.

---

## Further Reading

### AWS Architecture

- [AWS Well-Architected Framework — Serverless Lens](https://docs.aws.amazon.com/wellarchitected/latest/serverless-applications-lens/welcome.html)
- [Choosing between Lambda, Fargate, and EC2](https://aws.amazon.com/getting-started/decision-guides/serverless-or-kubernetes-on-aws-how-to-choose/)
- [AWS Compute Decision Guide](https://docs.aws.amazon.com/decision-guides/latest/compute-on-aws-how-to-choose/compute-on-aws-how-to-choose.html)

### Performance and Optimization

- [Lambda performance optimization](https://docs.aws.amazon.com/lambda/latest/dg/best-practices.html)
- [Lambda SnapStart](https://docs.aws.amazon.com/lambda/latest/dg/snapstart.html) (Java only — eliminates cold starts via snapshot/restore)
- [ECS best practices](https://docs.aws.amazon.com/AmazonECS/latest/bestpracticesguide/intro.html)

### Cost Optimization

- [AWS Pricing Calculator](https://calculator.aws/)
- [Lambda cost optimization](https://docs.aws.amazon.com/lambda/latest/dg/best-practices.html#function-configuration)
- [Fargate Spot](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/fargate-capacity-providers.html) (70% savings with interruption risk)

### Monitoring and Observability

- [CloudWatch Logs Insights](https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/AnalyzingLogData.html)
- [X-Ray tracing](https://docs.aws.amazon.com/xray/latest/devguide/aws-xray.html)
- [CloudWatch Container Insights](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/ContainerInsights.html)

### Related Concepts

- [Firecracker microVM](https://firecracker-microvm.github.io/) — the open-source VM manager Lambda uses
- [Kubernetes vs. ECS decision guide](https://docs.aws.amazon.com/decision-guides/latest/containers-on-aws-how-to-choose/containers-on-aws-how-to-choose.html)
- [The CNCF Serverless Whitepaper](https://github.com/cncf/wg-serverless/blob/main/whitepapers/serverless-overview/cncf_serverless_whitepaper_v1.0.pdf)
