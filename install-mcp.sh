#!/bin/bash
#
# Builds and installs the SwiftShot MCP server so that AI coding agents can
# take screenshots through SwiftShot.
#
#   ./install-mcp.sh              # build + install to ~/.local/bin
#   ./install-mcp.sh --no-install # only build
#
set -e

cd "$(dirname "$0")"

INSTALL_DIR="${HOME}/.local/bin"
INSTALL_BIN="${INSTALL_DIR}/swiftshot-mcp"
DO_INSTALL=1

for arg in "$@"; do
  case "$arg" in
    --no-install) DO_INSTALL=0 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

echo "==> Building the MCP server (release)..."
cd MCP
swift build -c release
cd ..

BINARY="MCP/.build/release/swiftshot-mcp"
if [ ! -x "$BINARY" ]; then
  echo "The MCP server binary was not produced." >&2
  exit 1
fi

if [ "$DO_INSTALL" -eq 1 ]; then
  echo "==> Installing to $INSTALL_BIN..."
  mkdir -p "$INSTALL_DIR"
  cp "$BINARY" "$INSTALL_BIN"
  chmod +x "$INSTALL_BIN"
  echo "    Installed: $INSTALL_BIN"
else
  echo "==> Built only: $BINARY"
fi

echo
echo "==> Register the server with your agent."
echo
echo "    Claude Code:"
echo "      claude mcp add swiftshot -- ${INSTALL_BIN}"
echo
echo "    Any other MCP client (add to the server config):"
cat <<'JSON'
    {
      "mcpServers": {
        "swiftshot": {
          "command": "REPLACE_WITH_PATH/swiftshot-mcp"
        }
      }
    }
JSON
echo
echo "    SwiftShot has to be running (it owns the Screen Recording permission):"
echo "      open -a SwiftShot"
echo
echo "==> Verify the setup:"
echo "      python3 Tests/e2e_mcp.py"
