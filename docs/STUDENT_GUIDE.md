# Lab 3 — Student Guide: Cold Path Latency

## Overview

This lab measures the **cold-start latency** and **cost** of three AWS execution environments — Lambda, Fargate, and EC2 — running the same workload. By the end, you will have real data to answer:

> **Given unpredictable, spiky traffic, which execution environment minimizes cost while keeping p99 latency below 500ms?**

There is no single correct answer. Your recommendation must be supported by your measurements.

---

## Learning Objectives

After completing this lab you should be able to:

1. **Distinguish cold start types** — Lambda execution environment cold starts vs. Fargate task provisioning delays vs. EC2's always-warm model.
2. **Measure and decompose latency** — Use CloudWatch Logs, X-Ray traces, and client-side timing to separate init, handler, and network components.
3. **Build a cost model** — Compute per-request Lambda costs vs. always-on Fargate/EC2 costs and find the break-even RPS.
4. **Make a quantified recommendation** — Defend an infrastructure choice using specific numbers and explicit conditions for when your recommendation changes.

---

## What You Will Deploy

All three environments run **identical application logic**: a brute-force k-nearest-neighbor (k-NN) search over 50,000 vectors of dimension 128. The workload is deliberately compute-heavy at initialization (building the dataset) and lightweight per request (~23–65ms).

| Target | Environment | Details |
|--------|-------------|---------|
| **A** | **AWS Lambda** (Function URL) | Zip deployment (Python 3.12 + NumPy layer) and container image deployment (ECR) |
| **B** | **ECS Fargate** (behind ALB) | 0.5 vCPU / 1 GB, same Docker image, 1 task, no auto-scaling |
| **C** | **EC2 t3.small** (direct HTTP) | Docker container, same image, always warm |

---

## Assignments

### Assignment 1: Deploy All Environments

Deploy the four targets (Lambda zip, Lambda container, Fargate, EC2) following the User Manual (`docs/USER_MANUAL.md`). Verify that all endpoints return identical k-NN results for the same query vector.

**Deliverable:** Save the terminal output showing successful responses from all four endpoints with matching `results` arrays to `results/assignment-1-endpoints.txt`.

---

### Assignment 2: Scenario A — Cold Start Characterization

**Goal:** Measure Lambda cold start latency for both zip and container image deployments.

**What to do:**
1. Ensure Lambda has been idle for at least 20 minutes (no invocations).
2. Send 30 sequential requests (1 per second) to the Lambda zip endpoint.
3. Record which requests triggered a cold start (check `X-Cold-Start` header or CloudWatch REPORT lines with `Init Duration`).
4. Repeat for the container image deployment.

**What to record:**
- For each cold-start invocation: Init Duration, Handler Duration, total client-side latency.
- For each warm invocation: Handler Duration, total client-side latency.

**Analysis:**
- Create a **stacked bar chart** decomposing total latency into: Network RTT, Init Duration, and Handler Duration — for zip cold start, container cold start, and warm invocations.
- Estimate Network RTT using `curl` connect time from the load generator to the Lambda endpoint.
- Comment on whether zip or container cold starts are faster, and explain why.

---

### Assignment 3: Scenario B — Warm Steady-State Throughput

**Goal:** Measure per-request latency at sustained load across all four environments.

**What to do:**
1. Warm up all endpoints with 20 requests each.
2. For each target, run 500 requests at concurrency=10. Record p50, p95, p99.
3. Repeat at concurrency=50.
4. Record server-side `query_time_ms` from the response body. You can sample this with a few `curl` calls to each endpoint, or extract it from CloudWatch application logs.

**What to record:** A table like this:

| Environment | Concurrency | p50 (ms) | p95 (ms) | p99 (ms) | Server avg (ms) |
|---|---|---|---|---|---|
| Lambda (zip) | 10 | | | | |
| Lambda (zip) | 50 | | | | |
| Lambda (container) | 10 | | | | |
| ... | ... | | | | |

**Analysis:**
- Annotate any cell where p99 > 2× p95 (this signals tail latency instability).
- Explain why Lambda p50 barely changes between c=10 and c=50, while Fargate/EC2 p50 increases significantly.
- Explain what causes the latency difference between server-side `query_time_ms` and client-side p50.

---

### Assignment 4: Scenario C — Burst from Zero

**Goal:** Simulate a traffic spike arriving after a period of inactivity.

**What to do:**
1. Let Lambda idle for 20 minutes.
2. Simultaneously send 200 requests at concurrency=50 to all four targets.
3. Record p50, p95, p99, and maximum latency.
4. Check CloudWatch Logs for cold-start `Init Duration` entries during the burst window.

**What to record:** Latency distribution for each target, with cold start count for Lambda.

**Analysis:**
- Explain why Lambda's burst p99 is much higher than Fargate/EC2.
- Identify the bimodal distribution in Lambda latencies (warm cluster vs. cold-start cluster).
- State whether Lambda meets the p99 < 500ms SLO under burst. If not, explain what would need to change.

---

### Assignment 5: Cost at Zero Load

**Goal:** Compute the idle cost of each environment.

**What to do:**
- This is entirely analytical — no traffic is sent.
- Look up current AWS pricing for us-east-1 (link to pricing pages below).
- Compute hourly and monthly idle cost for each environment.

**Pricing references (verify — prices may change):**
- Lambda: https://aws.amazon.com/lambda/pricing/
- Fargate: https://aws.amazon.com/fargate/pricing/
- EC2: https://aws.amazon.com/ec2/pricing/on-demand/

Take screenshots of the relevant pricing sections (with the date visible) and save them to `results/figures/pricing-screenshots/`.

**Analysis:**
- Compute monthly idle cost assuming 18 hours/day idle, 6 hours/day active.
- State which environment has zero idle cost and explain why.

---

### Assignment 6: Cost Model, Break-Even, and Recommendation

**Goal:** Compute monthly costs under a realistic traffic model, find the break-even point, and make a recommendation.

**Traffic model:**
- Peak: 100 RPS for 30 minutes/day
- Normal: 5 RPS for 5.5 hours/day
- Idle: 18 hours/day (0 RPS)

**Lambda cost formula:**
```
Monthly cost = (requests/month × $0.20/1M) + (GB-seconds/month × $0.0000166667)
GB-seconds   = requests × duration_seconds × memory_GB
```

Use your measured p50 handler duration from Scenario B for `duration_seconds` and 512 MB (0.5 GB) for memory.

**Always-on cost:** `hourly_rate × 24 × 30`

**Deliverables:**
1. Computed monthly cost for each environment under this traffic model.
2. **Break-even RPS** — at what average RPS does Lambda become more expensive than Fargate? Show the algebra.
3. A **Cost vs. RPS line chart** showing Lambda's linear cost against Fargate/EC2's flat cost, with the break-even point marked.
4. **Recommendation** (1 page max):
   - Given the SLO (p99 < 500ms) and traffic model, which environment do you recommend?
   - Justify with specific numbers from your measurements.
   - State the conditions under which your recommendation would change (e.g., "if average load exceeds X RPS..." or "if the SLO were relaxed to Y ms...").

---

## Grading Rubric

| Component | Points | Notes |
|---|---|---|
| Setup correctness (Assignment 1) | 1 | All four environments deployed, functional, same workload |
| Scenario A data + decomposition (Assignment 2) | 2 | Cold starts observed and quantified; zip vs container compared |
| Scenario B latency table (Assignment 3) | 1.5 | All four environments, both concurrency levels |
| Scenario C burst data (Assignment 4) | 1.5 | Bimodal distribution identified, SLO assessment |
| Cost model + break-even (Assignments 5–6) | 2 | Correct formula application; break-even derived algebraically |
| Recommendation quality (Assignment 6) | 1.5 | Quantitatively supported, conditions for reversal stated |
| Raw data submitted | 0.5 | Reproducibility check |
| **Total** | **10** | |

**Important:** A recommendation unsupported by specific numbers scores at most 0.5/1.5. A recommendation that contradicts your own data with no explanation scores 0/1.5.

---

## Submission Format

Submit via your **GitHub Classroom repository** (created from this template). Your repository should contain:

```
results/
├── assignment-1-endpoints.txt      # Terminal output verifying all 4 endpoints (Assignment 1)
├── scenario-a-zip.txt              # oha output from Scenario A (zip)
├── scenario-a-container.txt        # oha output from Scenario A (container)
├── scenario-b-*.txt                # oha output from Scenario B (all targets, both concurrencies)
├── scenario-c-*.txt                # oha output from Scenario C (all targets)
├── cloudwatch-zip-reports.txt      # CloudWatch REPORT lines for Lambda zip
├── cloudwatch-container-reports.txt # CloudWatch REPORT lines for Lambda container
└── figures/                        # Generated charts and screenshots
    ├── latency-decomposition.*     # Stacked bar chart (Assignment 2)
    ├── cost-vs-rps.*               # Cost vs. RPS line chart (Assignment 6)
    └── pricing-screenshots/        # AWS pricing page screenshots with dates
results/report.md                   # Report (max 4 pages equivalent) covering all assignments
```

**Notes:**
- The report can be Markdown (`report.md`) or PDF (`report.pdf`).
- Figures can be embedded in the report or placed in `results/figures/`.
- Do **not** commit AWS credentials, `.aws/`, or `loadtest/endpoints.sh` (it contains your endpoint URLs which expire).

---

## Important Reminders

1. **Clean up when done.** Run `deploy/99-cleanup.sh` as good practice. In AWS Academy, resources are automatically terminated when your session expires, so a forgotten instance won't cost you credits.
2. **AWS Academy sessions expire after ~4 hours.** Note resource IDs and endpoint URLs before the session expires.
3. **Do not use API Gateway** in front of Lambda — it adds 5–15ms overhead and invalidates the comparison.
4. **Document your region.** All resources should be in `us-east-1` unless your Academy account restricts this.
