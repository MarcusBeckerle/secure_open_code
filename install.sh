#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"

echo ""
echo "  SecureOpenCode - Install"
echo "  =========================="
echo ""
echo "  Install dir : $SCRIPT_DIR"
echo ""

# ── Detect Windows Git Bash / MSYS ───────────────────────────────────────────
IS_WINDOWS=false
[[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" || -n "$MSYSTEM" ]] && IS_WINDOWS=true

# ── Prerequisites ─────────────────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
    echo "[ERROR] Docker not found. Install Docker Desktop: https://docker.com"
    exit 1
fi
echo "[+] $(docker --version)"

PYTHON=""
for py in python3 python; do
    if command -v "$py" &>/dev/null; then
        ver=$("$py" -c "import sys; print(sys.version_info[:2])" 2>/dev/null)
        PYTHON="$py"; break
    fi
done
if [ -z "$PYTHON" ]; then
    echo "[ERROR] Python 3.8+ not found."
    exit 1
fi
echo "[+] $($PYTHON --version) ($(command -v $PYTHON))"

# ── Install soc command ────────────────────────────────────────────────────────
echo ""
echo "[+] Installing soc command..."
mkdir -p "$BIN_DIR"

if $IS_WINDOWS; then
    # On Git Bash, symlinks may need elevated perms — use a wrapper script instead
    cat > "$BIN_DIR/soc" << WRAPPER
#!/usr/bin/env bash
exec "$SCRIPT_DIR/soc.sh" "\$@"
WRAPPER
    chmod +x "$BIN_DIR/soc"
    echo "[+] Wrapper created  : $BIN_DIR/soc"
else
    ln -sf "$SCRIPT_DIR/soc.sh" "$BIN_DIR/soc"
    chmod +x "$SCRIPT_DIR/soc.sh"
    echo "[+] Symlink created  : $BIN_DIR/soc -> $SCRIPT_DIR/soc.sh"
fi

# ── Add ~/.local/bin to PATH in shell RC files ────────────────────────────────
echo ""
echo "[+] Configuring shell PATH..."

add_to_path() {
    local rc="$1"
    [ -f "$rc" ] || return 0
    if grep -qF '.local/bin' "$rc" 2>/dev/null; then
        echo "[=] $rc already includes ~/.local/bin"
    else
        printf '\n# SecureOpenCode\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$rc"
        echo "[+] Updated $rc"
    fi
}

added=false
for rc in "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.zshrc" "$HOME/.profile"; do
    add_to_path "$rc" && added=true
done
# If none of the standard files exist, create .bashrc
if [ "$added" = false ]; then
    printf '# SecureOpenCode\nexport PATH="$HOME/.local/bin:$PATH"\n' > "$HOME/.bashrc"
    echo "[+] Created ~/.bashrc with PATH entry"
fi

# Active in this shell session immediately
export PATH="$BIN_DIR:$PATH"
echo "[+] Active in this session."

# ── Python virtual environment ─────────────────────────────────────────────────
echo ""
echo "[+] Setting up Python environment..."
VENV="$SCRIPT_DIR/.venv"

# Remove stale venv so install always starts clean
rm -rf "$VENV"
"$PYTHON" -m venv "$VENV"

if [ -f "$VENV/Scripts/activate" ]; then
    # shellcheck disable=SC1091
    source "$VENV/Scripts/activate"
else
    # shellcheck disable=SC1091
    source "$VENV/bin/activate"
fi

python -m pip install -q --upgrade pip
pip install -q --upgrade -r "$SCRIPT_DIR/requirements.txt"
echo "[+] Python dependencies installed."

# ── Build Docker image ─────────────────────────────────────────────────────────
echo ""
if docker image inspect secure-opencode &>/dev/null; then
    echo "[=] Docker image already built."
else
    echo "[+] Building Docker image secure-opencode (first time, ~1 min)..."
    if docker build -t secure-opencode "$SCRIPT_DIR/docker"; then
        echo "[+] Docker image built."
    else
        echo "[WARN] Image build failed. Open the web UI later and click 'Build Image'."
    fi
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "  Done! Start a new shell (or: source ~/.bashrc), then:"
echo ""
echo "    soc                    Run OpenCode in current directory"
echo "    soc /path/to/project   Run OpenCode in a specific directory"
echo "    ./start-server.sh      Open the management web UI only"
echo ""
