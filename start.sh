#!/bin/zsh
cd "$(dirname "$0")"
# 端口清理：8340 被旧进程占用时优雅终止
PID=$(lsof -ti :8340 2>/dev/null)
if [ -n "$PID" ]; then
  echo "端口 8340 被占用 (PID $PID)，终止旧进程…"
  kill $PID 2>/dev/null
  sleep 1
  kill -9 $PID 2>/dev/null
fi
exec ganss-mac/.venv/bin/python run.py
