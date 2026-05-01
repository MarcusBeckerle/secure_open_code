#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${PORT:-5000}"

echo ""
echo "  SecureOpenCode Management Server"
echo "  =================================="
echo ""

# Resolve Python binary
PYTHON=""
for py in python3 python; do
    if command -v "$py" &>/dev/null; then
        PYTHON="$py"
        break
    fi
done
if [ -z "$PYTHON" ]; then
    echo "[ERROR] Python not found. Install Python 3.8+."
    exit 1
fi

# Create virtual environment
VENV="$SCRIPT_DIR/.venv"
if [ ! -f "$VENV/bin/activate" ] && [ ! -f "$VENV/Scripts/activate" ]; then
    echo "[+] Creating virtual environment..."
    "$PYTHON" -m venv "$VENV"
fi

# Activate (Git Bash on Windows uses Scripts/, Linux/Mac uses bin/)
if [ -f "$VENV/Scripts/activate" ]; then
    # shellcheck disable=SC1091
    source "$VENV/Scripts/activate"
else
    # shellcheck disable=SC1091
    source "$VENV/bin/activate"
fi

echo "[+] Installing dependencies..."
python -m pip install -q --upgrade pip
pip install -q --upgrade -r "$SCRIPT_DIR/requirements.txt"

# Build Docker image if not present
if ! docker image inspect secure-opencode &>/dev/null; then
    echo "[+] Building Docker image secure-opencode..."
    if docker build -t secure-opencode "$SCRIPT_DIR/docker"; then
        echo "[+] Image built."
    else
        echo "[WARN] Image build failed. Build it later from the web UI."
    fi
fi

# Open browser
(sleep 2
 if command -v xdg-open &>/dev/null; then
     xdg-open "http://localhost:$PORT"
 elif command -v open &>/dev/null; then
     open "http://localhost:$PORT"
 elif command -v start &>/dev/null; then
     start "http://localhost:$PORT"
 fi) &

echo "[+] Starting server at http://localhost:$PORT"
echo "    Press Ctrl+C to stop."
echo ""

export PORT="$PORT"
python "$SCRIPT_DIR/app.py"
