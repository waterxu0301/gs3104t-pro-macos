#!/bin/zsh
cd "$(dirname "$0")"
PID=$(lsof -ti :8340 2>/dev/null)
if [ -n "$PID" ]; then echo "终止旧进程 $PID…"; kill $PID 2>/dev/null; sleep 1; kill -9 $PID 2>/dev/null; fi
exec archive/ganss-mac/.venv/bin/python run.py
