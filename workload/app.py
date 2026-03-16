import os
import time
import socket
import json

import numpy as np
from flask import Flask, request, jsonify, make_response

from generate_dataset import generate_dataset

# --- Global scope: executed at import/startup time (Lambda init cost) ---
DATASET = generate_dataset()
COLD_START = True
INSTANCE_ID = os.environ.get("AWS_LAMBDA_LOG_STREAM_NAME", socket.gethostname())

app = Flask(__name__)


@app.route("/search", methods=["POST"])
def search():
    global COLD_START
    is_cold = COLD_START
    COLD_START = False

    data = request.get_json(force=True)
    query = np.array(data["query"], dtype=np.float32)

    start = time.perf_counter()
    dists = np.linalg.norm(DATASET - query, axis=1)
    top5_idx = np.argpartition(dists, 5)[:5]
    top5_idx = top5_idx[np.argsort(dists[top5_idx])]
    elapsed_ms = (time.perf_counter() - start) * 1000

    results = [
        {"index": int(i), "distance": float(dists[i])} for i in top5_idx
    ]

    resp = make_response(jsonify({
        "results": results,
        "query_time_ms": round(elapsed_ms, 3),
        "instance_id": INSTANCE_ID,
    }))
    resp.headers["X-Server-Time-Ms"] = f"{elapsed_ms:.3f}"
    resp.headers["X-Instance-Id"] = INSTANCE_ID
    resp.headers["X-Cold-Start"] = str(is_cold).lower()
    return resp


@app.route("/health", methods=["GET"])
def health():
    return jsonify({"status": "ok"})


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
