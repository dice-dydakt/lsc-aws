import json
import time
import os
import socket

import numpy as np

from generate_dataset import generate_dataset

# --- Global scope: triggers dataset generation during Lambda init ---
DATASET = generate_dataset()
COLD_START = True
INSTANCE_ID = os.environ.get("AWS_LAMBDA_LOG_STREAM_NAME", socket.gethostname())


def lambda_handler(event, context):
    global COLD_START
    is_cold = COLD_START
    COLD_START = False

    # Parse body from Function URL event
    body = event.get("body", "{}")
    if event.get("isBase64Encoded", False):
        import base64
        body = base64.b64decode(body).decode("utf-8")
    data = json.loads(body)

    query = np.array(data["query"], dtype=np.float32)

    start = time.perf_counter()
    dists = np.linalg.norm(DATASET - query, axis=1)
    top5_idx = np.argpartition(dists, 5)[:5]
    top5_idx = top5_idx[np.argsort(dists[top5_idx])]
    elapsed_ms = (time.perf_counter() - start) * 1000

    results = [
        {"index": int(i), "distance": float(dists[i])} for i in top5_idx
    ]

    return {
        "statusCode": 200,
        "headers": {
            "Content-Type": "application/json",
            "X-Server-Time-Ms": f"{elapsed_ms:.3f}",
            "X-Instance-Id": INSTANCE_ID,
            "X-Cold-Start": str(is_cold).lower(),
        },
        "body": json.dumps({
            "results": results,
            "query_time_ms": round(elapsed_ms, 3),
            "instance_id": INSTANCE_ID,
            "cold_start": is_cold,
        }),
    }
