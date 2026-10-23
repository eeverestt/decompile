#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="$HOME/.local/bin"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "[*] Publishing..."
cd "$PROJECT_DIR"
dotnet publish -c Release \
    --self-contained false \
    -p:PublishSingleFile=true \
    -o "$PROJECT_DIR/publish" \
    --nologo \
    -v quiet

mkdir -p "$INSTALL_DIR"
install -m 755 "$PROJECT_DIR/publish/decompiler" "$INSTALL_DIR/decompile"
echo "[+] Installed: $INSTALL_DIR/decompile"

if ! echo "$PATH" | tr ':' '\n' | grep -qx "$INSTALL_DIR"; then
    echo ""
    echo "[!] $INSTALL_DIR is not on your PATH."
    echo "    Add this to ~/.bashrc:"
    echo "        export PATH=\"\$HOME/.local/bin:\$PATH\""
    echo "    Then run: source ~/.bashrc"
fi

if ! command -v java >/dev/null 2>&1; then
    echo ""
    echo "[!] java not found. Install it with:"
    echo "    sudo apt install openjdk-21-jre-headless"
fi

echo ""
echo "[+] Done. Try:  decompile <mod.jar> <minecraft_version>"