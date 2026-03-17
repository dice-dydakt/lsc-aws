#!/usr/bin/env python3
"""
Load tester for Lambda Function URLs with AWS IAM auth (SigV4 signing).
Alternative to oha for Lambda endpoints. Handles SigV4 signing with auto-credential discovery.
"""
import argparse
import json
import time
import os
import sys
import statistics
from concurrent.futures import ThreadPoolExecutor, as_completed

import boto3
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest
import urllib.request
import urllib.error


def create_signed_request(url, body, credentials, region):
    """Create a SigV4-signed HTTP request."""
    request = AWSRequest(method="POST", url=url,
                         data=body,
                         headers={"Content-Type": "application/json"})
    SigV4Auth(credentials, "lambda", region).add_auth(request)
    return request


def send_request(url, body, credentials, region):
    """Send a single signed request and return timing info."""
    start = time.perf_counter()
    try:
        req = create_signed_request(url, body, credentials, region)
        http_req = urllib.request.Request(
            url, data=body.encode(),
            headers=dict(req.headers),
            method="POST"
        )
        with urllib.request.urlopen(http_req, timeout=30) as resp:
            elapsed = (time.perf_counter() - start) * 1000
            response_body = resp.read().decode()
            headers = dict(resp.headers)

            # Try headers first, fall back to parsing the JSON body
            cold_start = headers.get("X-Cold-Start", headers.get("x-cold-start"))
            server_time = headers.get("X-Server-Time-Ms", headers.get("x-server-time-ms"))
            instance_id = headers.get("X-Instance-Id", headers.get("x-instance-id"))

            try:
                body_json = json.loads(response_body)
                if not cold_start:
                    cs = body_json.get("cold_start")
                    if cs is not None:
                        cold_start = str(cs).lower()
                if not server_time:
                    server_time = str(body_json.get("query_time_ms", "unknown"))
                if not instance_id:
                    instance_id = body_json.get("instance_id", "unknown")
            except (json.JSONDecodeError, KeyError):
                pass

            return {
                "status": resp.status,
                "latency_ms": elapsed,
                "cold_start": cold_start or "unknown",
                "server_time_ms": server_time or "unknown",
                "instance_id": instance_id or "unknown",
                "body": response_body,
            }
    except Exception as e:
        elapsed = (time.perf_counter() - start) * 1000
        return {
            "status": 0,
            "latency_ms": elapsed,
            "error": str(e),
            "cold_start": "unknown",
            "server_time_ms": "unknown",
            "instance_id": "unknown",
        }


def percentile(data, p):
    """Calculate percentile."""
    data = sorted(data)
    k = (len(data) - 1) * p / 100
    f = int(k)
    c = f + 1
    if c >= len(data):
        return data[f]
    return data[f] + (k - f) * (data[c] - data[f])


def run_load_test(url, body, credentials, region, num_requests, concurrency, sequential_delay=0):
    """Run load test with given parameters."""
    results = []

    if sequential_delay > 0:
        # Sequential mode (for Scenario A)
        for i in range(num_requests):
            result = send_request(url, body, credentials, region)
            result["request_num"] = i + 1
            results.append(result)
            sys.stdout.write(f"\r  Request {i+1}/{num_requests}: "
                           f"{result['latency_ms']:.1f}ms "
                           f"cold={result['cold_start']} "
                           f"server={result['server_time_ms']}ms")
            sys.stdout.flush()
            if i < num_requests - 1:
                time.sleep(sequential_delay)
        print()
    else:
        # Concurrent mode (for Scenarios B, D)
        with ThreadPoolExecutor(max_workers=concurrency) as executor:
            futures = []
            for i in range(num_requests):
                futures.append(executor.submit(send_request, url, body, credentials, region))
            for i, future in enumerate(as_completed(futures)):
                result = future.result()
                result["request_num"] = i + 1
                results.append(result)
                if (i + 1) % 50 == 0 or i + 1 == num_requests:
                    sys.stdout.write(f"\r  Completed {i+1}/{num_requests}")
                    sys.stdout.flush()
        print()

    return results


def print_summary(results, label):
    """Print summary of results with percentiles."""
    latencies = [r["latency_ms"] for r in results if r.get("status") == 200]
    errors = [r for r in results if r.get("status") != 200]
    server_times = []
    for r in results:
        try:
            server_times.append(float(r["server_time_ms"]))
        except (ValueError, TypeError):
            pass

    cold_starts = sum(1 for r in results if r.get("cold_start") == "true")

    if not latencies:
        print(f"  {label}: ALL REQUESTS FAILED ({len(errors)} errors)")
        return

    print(f"\n{'='*60}")
    print(f"  {label}")
    print(f"{'='*60}")
    print(f"  Total requests:   {len(results)}")
    print(f"  Successful:       {len(latencies)}")
    print(f"  Errors:           {len(errors)}")
    print(f"  Cold starts:      {cold_starts}")
    print(f"")
    print(f"  Latency (client-side, ms):")
    print(f"    Min:    {min(latencies):.3f}")
    print(f"    Mean:   {statistics.mean(latencies):.3f}")
    print(f"    p50:    {percentile(latencies, 50):.3f}")
    print(f"    p95:    {percentile(latencies, 95):.3f}")
    print(f"    p99:    {percentile(latencies, 99):.3f}")
    print(f"    Max:    {max(latencies):.3f}")
    print(f"    StdDev: {statistics.stdev(latencies):.3f}" if len(latencies) > 1 else "")

    if server_times:
        print(f"")
        print(f"  Server-side time (ms):")
        print(f"    Mean:   {statistics.mean(server_times):.3f}")
        print(f"    Min:    {min(server_times):.3f}")
        print(f"    Max:    {max(server_times):.3f}")

    print(f"{'='*60}")
    return {
        "label": label,
        "total": len(results),
        "successful": len(latencies),
        "errors": len(errors),
        "cold_starts": cold_starts,
        "p50": percentile(latencies, 50),
        "p95": percentile(latencies, 95),
        "p99": percentile(latencies, 99),
        "min": min(latencies),
        "max": max(latencies),
        "mean": statistics.mean(latencies),
        "server_mean": statistics.mean(server_times) if server_times else None,
    }


def main():
    parser = argparse.ArgumentParser(description="Lambda Function URL Load Tester (SigV4)")
    parser.add_argument("url", help="Lambda Function URL (with /search path)")
    parser.add_argument("-n", "--num-requests", type=int, default=100, help="Total requests")
    parser.add_argument("-c", "--concurrency", type=int, default=10, help="Concurrent workers")
    parser.add_argument("--sequential-delay", type=float, default=0,
                        help="Delay between requests in sequential mode (seconds). >0 forces sequential.")
    parser.add_argument("--query-file", default="query.json", help="Path to query JSON file")
    parser.add_argument("--region", default="us-east-1", help="AWS region")
    parser.add_argument("--output", help="Save detailed results to JSON file")
    parser.add_argument("--label", default="", help="Label for this test run")
    args = parser.parse_args()

    with open(args.query_file) as f:
        body = f.read().strip()

    session = boto3.Session()
    credentials = session.get_credentials().get_frozen_credentials()

    label = args.label or f"n={args.num_requests} c={args.concurrency}"
    print(f"\nRunning load test: {label}")
    print(f"  URL: {args.url}")
    print(f"  Requests: {args.num_requests}, Concurrency: {args.concurrency}")

    results = run_load_test(
        args.url, body, credentials, args.region,
        args.num_requests, args.concurrency, args.sequential_delay
    )

    summary = print_summary(results, label)

    if args.output:
        with open(args.output, "w") as f:
            json.dump({"summary": summary, "requests": results}, f, indent=2)
        print(f"  Detailed results saved to {args.output}")

    return summary


if __name__ == "__main__":
    main()
