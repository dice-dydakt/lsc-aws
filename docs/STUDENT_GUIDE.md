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
4. **Make a quantified recommendation** — Defend an infrastructure choice using a Pareto frontier plot and explicit conditions for when your recommendation changes.

---

## What You Will Deploy

All three environments run **identical application logic**: a brute-force k-nearest-neighbor (k-NN) search over 50,000 vectors of dimension 128. The workload is deliberately compute-heavy at initialization (building the dataset) and lightweight per request (~23–65ms).

```
┌─────────────────────────────────────────────────────────────┐
│                                                             │
│  Target A: AWS Lambda (Function URL)                        │
│    • Zip deployment (Python 3.12 + NumPy layer)            │
│    • Container image deployment (ECR)                      │
│                                                             │
│  Target B: ECS Fargate (behind ALB)                         │
│    • 0.5 vCPU / 1 GB, same Docker image                   │
│    • 1 task, no auto-scaling                               │
│                                                             │
│  Target C: EC2 t3.small (direct HTTP)                       │
│    • Docker container, same image                          │
│    • Always warm                                           │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## Assignments

### Assignment 1: Deploy All Environments

Deploy the four targets (Lambda zip, Lambda container, Fargate, EC2) following the User Manual (`docs/USER_MANUAL.md`). Verify that all endpoints return identical k-NN results for the same query vector.

**Deliverable:** Screenshot or terminal output showing successful responses from all four endpoints with matching `results` arrays.

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
4. Record server-side `query_time_ms` from the response body.

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

### Assignment 4: Scenario C — Cost at Zero Load

**Goal:** Compute the idle cost of each environment.

**What to do:**
- This is entirely analytical — no traffic is sent.
- Look up current AWS pricing for us-east-1 (link to pricing pages below).
- Compute hourly and monthly idle cost for each environment.

**Pricing references (verify — prices may change):**
- Lambda: https://aws.amazon.com/lambda/pricing/
- Fargate: https://aws.amazon.com/fargate/pricing/
- EC2: https://aws.amazon.com/ec2/pricing/on-demand/

**Analysis:**
- Compute monthly idle cost assuming 18 hours/day idle, 6 hours/day active.
- State which environment has zero idle cost and explain why.

---

### Assignment 5: Scenario D — Burst from Zero

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

### Assignment 6: Cost Model and Break-Even Analysis

**Goal:** Compute monthly costs under a realistic traffic model and find the break-even point.

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

---

### Assignment 7: Pareto Frontier and Recommendation

**Goal:** Synthesize all data into a recommendation.

**Deliverables:**

1. **Pareto frontier scatter plot** with:
   - X axis: p99 latency under burst (Scenario D), in milliseconds
   - Y axis: monthly cost under the traffic model from Assignment 6
   - Each environment as one point
   - An additional point for **Lambda with Provisioned Concurrency** (estimate its latency and cost — you don't need to deploy this)
   - Label which solutions are Pareto-optimal

2. **Recommendation** (1 page max):
   - Given the SLO (p99 < 500ms) and traffic model, which environment do you recommend?
   - Justify with specific numbers from your measurements.
   - State the conditions under which your recommendation would change (e.g., "if average load exceeds X RPS..." or "if the SLO were relaxed to Y ms...").

---

### Assignment 8: Reflection

Write half a page answering:

1. What did you not measure that would improve the analysis?
2. What assumption in the cost model is most likely to be wrong?
3. Where does Kubernetes fit on the Pareto plot you drew? What would you need to measure to place it there?

---

## Grading Rubric

| Component | Points | Notes |
|---|---|---|
| Setup correctness (Assignment 1) | 10 | All four environments deployed, functional, same workload |
| Scenario A data + decomposition (Assignment 2) | 20 | Cold starts observed and quantified; zip vs container compared |
| Scenario B latency table (Assignment 3) | 15 | All four environments, both concurrency levels |
| Cost model (Assignment 6) | 20 | Correct formula application; break-even derived algebraically |
| Pareto plot (Assignment 7) | 15 | Correct axes, Pareto-optimal solutions identified |
| Recommendation quality (Assignment 7) | 15 | Quantitatively supported, conditions for reversal stated |
| Raw data submitted | 5 | Reproducibility check |
| **Total** | **100** | |

**Important:** A recommendation unsupported by specific numbers scores at most 5/15. A recommendation that contradicts your own data with no explanation scores 0/15.

---

## Submission Format

Submit a single **PDF or ZIP** containing:

1. **Raw data** — `hey` output files, CloudWatch REPORT line exports, AWS pricing screenshots with dates.
2. **Figures** — Latency decomposition bar chart, latency table, cost vs. RPS chart, Pareto frontier plot.
3. **Report** — Max 4 pages (excluding figures and raw data) covering Sections 1–4 as described above.

---

## Time Estimate

- Deployment: 1–1.5 hours
- Running scenarios: 1–1.5 hours (including 20-minute idle waits)
- Analysis and report: 1–1.5 hours
- **Total: 3–4 hours** (excluding report writing)

---

## Important Reminders

1. **Terminate all resources when done!** Run `deploy/99-cleanup.sh`. A forgotten t3.small costs ~$3.50/week.
2. **AWS Academy sessions expire after ~4 hours.** Note resource IDs and endpoint URLs before the session expires.
3. **Do not use API Gateway** in front of Lambda — it adds 5–15ms overhead and invalidates the comparison.
4. **Document your region.** All resources should be in `us-east-1` unless your Academy account restricts this.
