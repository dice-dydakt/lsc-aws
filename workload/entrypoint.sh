#!/bin/bash
if [ "$MODE" = "server" ]; then
    exec python app.py
else
    exec python -m awslambdaric "$@"
fi
