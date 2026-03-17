# AWS Cloud Lab — Serverless vs Containers: Latency and Cost Comparison

Measure latency (cold start, warm throughput, burst) and cost of three AWS execution environments — **Lambda**, **Fargate**, and **EC2** — running an identical k-NN workload. Build a cost model, find the break-even point, and make a quantified recommendation.

## Quick Start

1. Read [`docs/STUDENT_GUIDE.md`](docs/STUDENT_GUIDE.md) for assignments and grading
2. Follow [`docs/USER_MANUAL.md`](docs/USER_MANUAL.md) step by step to deploy and test
3. See [`docs/TECHNICAL_REFERENCE.md`](docs/TECHNICAL_REFERENCE.md) for architecture and design details
4. Submit results via this GitHub Classroom repository

## Repository Structure

```
deploy/          Deployment scripts (run in order: 01-ecr.sh → 05-ec2-app.sh)
workload/        Application code (shared across all environments)
loadtest/        Load testing scripts (Scenarios A, B, C)
results/         Output directory for test results and report
docs/            Student guide, user manual, technical reference
```

## Prerequisites

- AWS Academy account with active lab session
- Docker, Python 3.10+, [oha](https://github.com/hatoo/oha)
- See the User Manual for details and an EC2-based alternative
