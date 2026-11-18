#!/bin/zsh
cd "$(dirname "$0")"

# Python 解释器探测：根目录 .venv 优先，回退归档 venv，再回退系统 uv/python
if [ -x ".venv/bin/python" ]; then
  PY=".venv/bin/python"
elif [ -x "archive/ganss-mac/.venv/bin/python" ]; then
  PY="archive/ganss-mac/.venv/bin/python"
elif command -v uv >/dev/null 2>&1; then
  uv venv --python 3.12 .venv 2>/dev/null
  uv pip install --python .venv/bin/python hidapi 2>/dev/null
  PY=".venv/bin/python"
else
  PY="python3"
  echo "警告: 使用系统 python3，需手动安装 hidapi 依赖"
fi

PID=$(lsof -ti :8340 2>/dev/null)
if [ -n "$PID" ]; then
  echo "终止旧进程 (PID $PID)…"
  kill $PID 2>/dev/null; sleep 1
  kill -9 $PID 2>/dev/null
fi

echo "使用解释器: $PY"
exec $PY run.py
