#!/usr/bin/env bash

IMAGE="secure-opencode"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROC_DIR="${1:-$PWD}"

# Resolve to absolute path
if command -v realpath &>/dev/null; then
    ROC_DIR="$(realpath "$ROC_DIR")"
elif [[ "$OSTYPE" == "darwin"* ]]; then
    ROC_DIR="$(cd "$ROC_DIR" && pwd)"
fi

# On Windows Git Bash / MSYS2 / Cygwin: convert to Windows path for Docker volume mount
if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" || -n "$MSYSTEM" ]]; then
    ROC_DIR="$(cygpath -w "$ROC_DIR")"
fi

# Validate directory
UNIX_DIR="$ROC_DIR"
if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" || -n "$MSYSTEM" ]]; then
    UNIX_DIR="$(cygpath -u "$ROC_DIR" 2>/dev/null || echo "$ROC_DIR")"
fi
if [ ! -d "$UNIX_DIR" ]; then
    echo "[soc] ERROR: Directory not found: $ROC_DIR"
    exit 1
fi

echo ""
echo "[soc] Directory : $ROC_DIR"
echo "[soc] Image     : $IMAGE"
echo ""

# ── Ensure Flask management server is running ────────────────────────────────
ensure_server() {
    if curl -sf --max-time 2 http://localhost:5000/ >/dev/null 2>&1; then
        return 0
    fi
    echo "[soc] Management server not running. Starting it..."
    if [ -f "$SCRIPT_DIR/.venv/bin/python" ]; then
        FLASK_PYTHON="$SCRIPT_DIR/.venv/bin/python"
    elif [ -f "$SCRIPT_DIR/.venv/Scripts/python.exe" ]; then
        FLASK_PYTHON="$SCRIPT_DIR/.venv/Scripts/python.exe"
    else
        echo "[soc] No virtualenv found. Running full setup (this may take a minute)..."
        bash "$SCRIPT_DIR/start-server.sh" &
        FLASK_PYTHON=""
    fi
    if [ -n "$FLASK_PYTHON" ]; then
        PORT=5000 "$FLASK_PYTHON" "$SCRIPT_DIR/app.py" >/dev/null 2>&1 &
    fi
    echo "[soc] Waiting for server to be ready..."
    for i in $(seq 1 60); do
        sleep 0.5
        if (echo >/dev/tcp/127.0.0.1/5000) 2>/dev/null; then
            echo "[soc] Server ready."
            return 0
        fi
    done
    echo "[soc] WARN: Server timeout, continuing anyway."
}
ensure_server

# Build image if missing
if ! docker image inspect "$IMAGE" &>/dev/null; then
    echo "[soc] Image not found. Building $IMAGE..."
    docker build -t "$IMAGE" "$SCRIPT_DIR/docker"
    echo ""
fi

# Check for existing running container with the same host path label
EXISTING=""
while IFS= read -r cname; do
    if [ -z "$cname" ]; then continue; fi
    label_path="$(docker inspect "$cname" --format '{{index .Config.Labels "opencode.host_path"}}' 2>/dev/null)"
    if [ "$label_path" = "$ROC_DIR" ]; then
        EXISTING="$cname"
        break
    fi
done < <(docker ps --filter "label=opencode.managed=true" --format "{{.Names}}" 2>/dev/null)

open_ui() {
    if command -v xdg-open &>/dev/null; then xdg-open "http://localhost:5000"
    elif command -v open &>/dev/null; then open "http://localhost:5000"
    elif command -v start &>/dev/null; then start "http://localhost:5000"
    fi
}

if [ -n "$EXISTING" ]; then
    echo "[soc] Reusing existing session: $EXISTING"
    echo "[soc] Type 'exit' in OpenCode to detach. Container stays running."
    echo ""
    open_ui
    docker exec -it -w /workspace "$EXISTING" opencode
    CNAME="$EXISTING"
else
    # Generate container name from directory base name
    DIRNAME="$(basename "$ROC_DIR" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-//;s/-$//')"
    SUFFIX="$(cat /dev/urandom 2>/dev/null | tr -dc 'a-z0-9' | head -c 5 || printf '%05d' "$$")"
    CNAME="soc-${DIRNAME}-${SUFFIX}"

    echo "[soc] Starting session : $CNAME"
    echo "[soc] Type 'exit' in OpenCode to detach. Container stays running."
    echo "[soc] Manage sessions  : http://localhost:5000"
    echo ""

    docker run -d \
        -v "$ROC_DIR:/workspace" \
        --label opencode.managed=true \
        --label "opencode.host_path=$ROC_DIR" \
        --name "$CNAME" \
        "$IMAGE" sleep infinity >/dev/null

    open_ui
    docker exec -it -w /workspace "$CNAME" opencode
fi

echo ""
echo "[soc] OpenCode exited. Session container is still running."
echo "[soc] Reconnect : docker exec -it -w /workspace $CNAME opencode"
echo "[soc] Stop      : docker stop $CNAME && docker rm $CNAME"
echo "[soc] Web UI    : http://localhost:5000"
echo ""
