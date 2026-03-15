#!/usr/bin/env bash

# Since you can't install GitHub Copilot from the marketplace inside code-server, this script automates the process of downloading the latest GitHub Copilot and a pinned version of GitHub Copilot Chat, then installing them into a running linuxserver/code-server container.
# - code-server container name: code-server
# - code-server binary: /app/code-server/bin/code-server
# - GitHub.copilot-chat is pinned to selected version

set -euo pipefail

CODE_SERVER_EXEC="/app/code-server/bin/code-server"
COPILOT_CHAT_PINNED_VERSION="0.39.0"

check_dependencies() {
    local missing_deps=()

    for cmd in curl jq docker; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_deps+=("$cmd")
        fi
    done

    if ! command -v gunzip >/dev/null 2>&1 && ! command -v gzip >/dev/null 2>&1; then
        missing_deps+=("gunzip/gzip")
    fi

    if [ "${#missing_deps[@]}" -gt 0 ]; then
        echo "Error: Missing required dependencies: ${missing_deps[*]}"
        exit 1
    fi
}

check_container() {
    if ! docker ps --format '{{.Names}}' | grep -q '^code-server$'; then
        echo "Error: code-server container is not running"
        exit 1
    fi

    if ! docker exec code-server test -x "$CODE_SERVER_EXEC"; then
        echo "Error: code-server executable not found at $CODE_SERVER_EXEC"
        exit 1
    fi
}

ensure_extension_dir() {
    docker exec code-server mkdir -p /config/extensions
}

get_user_data_dir() {
    echo "/config"
}

get_vscode_version() {
    docker exec code-server "$CODE_SERVER_EXEC" --version \
        | grep -o 'with Code [0-9.]*' \
        | awk '{print $3}'
}

get_latest_version() {
    local extension_id="$1"

    local response
    response=$(curl -s -X POST "https://marketplace.visualstudio.com/_apis/public/gallery/extensionquery" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json;api-version=3.0-preview.1" \
        -d "{
            \"filters\": [{
                \"criteria\": [
                    {\"filterType\": 7, \"value\": \"$extension_id\"},
                    {\"filterType\": 12, \"value\": \"4096\"}
                ],
                \"pageSize\": 50
            }],
            \"flags\": 4112
        }")

    echo "$response" | jq -r '
        .results[0].extensions[0].versions[]
        | .version
    ' | sort -V | tail -n 1
}

install_extension_version() {
    local extension_id="$1"
    local version="$2"
    local user_data_dir="$3"

    local extension_name
    extension_name=$(echo "$extension_id" | cut -d'.' -f2)
    local temp_dir="/tmp/code-extensions"

    echo "Installing $extension_id v$version..."

    mkdir -p "$temp_dir"

    local vsix_gz="$temp_dir/$extension_name.vsix.gz"
    local vsix="$temp_dir/$extension_name.vsix"

    echo "  Downloading $extension_id..."
    if ! curl -fsSL "https://marketplace.visualstudio.com/_apis/public/gallery/publishers/GitHub/vsextensions/$extension_name/$version/vspackage" \
        -o "$vsix_gz"; then
        echo "  ✗ Download failed for $extension_id (version $version)"
        return 1
    fi

    if command -v gunzip >/dev/null 2>&1; then
        if ! gunzip -f "$vsix_gz"; then
            echo "  ✗ Failed to decompress vsix for $extension_id"
            return 1
        fi
    else
        if ! gzip -df "$vsix_gz"; then
            echo "  ✗ Failed to decompress vsix for $extension_id"
            return 1
        fi
    fi

    if [ ! -f "$vsix" ]; then
        echo "  ✗ Missing vsix after decompression for $extension_id"
        return 1
    fi

    echo "  Copying vsix into container..."
    if ! docker cp "$vsix" "code-server:/config/tmp_$extension_name.vsix"; then
        echo "  ✗ Failed to copy vsix into container for $extension_id"
        rm -f "$vsix"
        return 1
    fi

    echo "  Running code-server --install-extension..."
    if ! docker exec -w /config code-server "$CODE_SERVER_EXEC" \
        --user-data-dir="$user_data_dir" \
        --install-extension "/config/tmp_$extension_name.vsix" \
        --force; then
        echo "  ✗ code-server rejected or failed to install $extension_id v$version"
        rm -f "$vsix"
        docker exec code-server rm -f "/config/tmp_$extension_name.vsix" >/dev/null 2>&1 || true
        return 1
    fi

    rm -f "$vsix"
    docker exec code-server rm -f "/config/tmp_$extension_name.vsix" >/dev/null 2>&1 || true

    echo "  ✓ $extension_id v$version installed successfully!"
    return 0
}

echo "GitHub Copilot Extensions Installer (Pinned Copilot Chat)"
echo "================================================================"
echo ""

check_dependencies
check_container
ensure_extension_dir

VSCODE_VERSION="$(get_vscode_version || true)"
if [ -n "$VSCODE_VERSION" ]; then
    echo "Detected bundled VS Code version: $VSCODE_VERSION"
fi

USER_DATA_DIR="$(get_user_data_dir)"
echo "Using container user-data-dir: $USER_DATA_DIR"
echo ""

FAILED=0

# 1) Install latest GitHub.copilot
echo "Processing GitHub.copilot..."
LATEST_COPILOT="$(get_latest_version "GitHub.copilot" || true)"
if [ -z "$LATEST_COPILOT" ]; then
    echo "  ✗ Could not determine latest version for GitHub.copilot"
    FAILED=$((FAILED + 1))
else
    echo "  Latest GitHub.copilot version: $LATEST_COPILOT"
    if ! install_extension_version "GitHub.copilot" "$LATEST_COPILOT" "$USER_DATA_DIR"; then
        FAILED=$((FAILED + 1))
    fi
fi
echo ""

# 2) Install pinned GitHub.copilot-chat
echo "Processing GitHub.copilot-chat..."
echo "  Using pinned version: $COPILOT_CHAT_PINNED_VERSION"
if ! install_extension_version "GitHub.copilot-chat" "$COPILOT_CHAT_PINNED_VERSION" "$USER_DATA_DIR"; then
    FAILED=$((FAILED + 1))
fi
echo ""

echo "================================================================"
if [ $FAILED -eq 0 ]; then
    echo "✓ Copilot and Copilot Chat installed successfully."
    echo "You may need to restart code-server: docker restart code-server"
    rm -rf /tmp/code-extensions
else
    echo "⚠ Completed with $FAILED error(s)."
    exit 1
fi
