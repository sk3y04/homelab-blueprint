#!/usr/bin/env bash
# ==========================================================================
# prepare.sh — One-time setup for Matrix Synapse + Element Web
# ==========================================================================
# Run this ONCE before 'docker compose up -d'. It will:
#   1. Load variables from .env
#   2. Generate the Synapse homeserver.yaml and signing keys
#   3. Patch homeserver.yaml to use PostgreSQL instead of SQLite
#   4. Create a default Element Web config.json
#
# Usage:
#   chmod +x prepare.sh
#   ./prepare.sh
#
# After running, review and edit:
#   - <SYNAPSE_DATA_DIR>/homeserver.yaml  (server settings)
#   - ./element-config.json               (Element Web branding)
# Then start the stack:
#   docker compose up -d
# ==========================================================================

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# ── Load .env ─────────────────────────────────────────────────────────────
if [[ ! -f .env ]]; then
    echo -e "${RED}ERROR${NC}: .env file not found. Copy .env.example to .env and fill in your values first."
    exit 1
fi

set -a
source .env
set +a

# ── Validate required variables ───────────────────────────────────────────
for var in SYNAPSE_DATA_DIR SYNAPSE_DB_DIR SYNAPSE_POSTGRES_DB SYNAPSE_POSTGRES_USER SYNAPSE_POSTGRES_PASSWORD; do
    if [[ -z "${!var:-}" ]]; then
        echo -e "${RED}ERROR${NC}: $var is not set in .env"
        exit 1
    fi
done

echo ""
echo "🔑 Matrix Synapse — First-Time Setup"
echo "======================================"
echo ""

# ── Ask for server name ───────────────────────────────────────────────────
read -rp "Enter your Matrix server name (e.g. skey.ovh): " SERVER_NAME
if [[ -z "$SERVER_NAME" ]]; then
    echo -e "${RED}ERROR${NC}: Server name cannot be empty."
    exit 1
fi

# ── Create directories ────────────────────────────────────────────────────
echo -e "  ${GREEN}CREATE${NC}  ${SYNAPSE_DATA_DIR}"
mkdir -p "${SYNAPSE_DATA_DIR}"
echo -e "  ${GREEN}CREATE${NC}  ${SYNAPSE_DB_DIR}"
mkdir -p "${SYNAPSE_DB_DIR}"

# ── Generate Synapse config ───────────────────────────────────────────────
if [[ -f "${SYNAPSE_DATA_DIR}/homeserver.yaml" ]]; then
    echo -e "  ${YELLOW}SKIP${NC}  homeserver.yaml already exists"
else
    echo -e "  ${GREEN}GENERATE${NC}  homeserver.yaml + signing keys"
    docker run --rm \
        -v "${SYNAPSE_DATA_DIR}:/data" \
        -e SYNAPSE_SERVER_NAME="${SERVER_NAME}" \
        -e SYNAPSE_REPORT_STATS=no \
        matrixdotorg/synapse:latest generate
fi

# ── Patch homeserver.yaml for PostgreSQL ──────────────────────────────────
HOMESERVER="${SYNAPSE_DATA_DIR}/homeserver.yaml"

if grep -q "name: sqlite3" "${HOMESERVER}" 2>/dev/null; then
    echo -e "  ${GREEN}PATCH${NC}  homeserver.yaml → PostgreSQL"

    # The file is owned by root (created by Docker), so we run sed inside a
    # container that has write access to the bind-mounted /data volume.
    docker run --rm \
        -v "${SYNAPSE_DATA_DIR}:/data" \
        --entrypoint sh \
        matrixdotorg/synapse:latest \
        -c "sed -i '/^database:/,/^[^[:space:]]/{
/^database:/c\\
database:\\
  name: psycopg2\\
  args:\\
    user: ${SYNAPSE_POSTGRES_USER}\\
    password: \"${SYNAPSE_POSTGRES_PASSWORD}\"\\
    database: ${SYNAPSE_POSTGRES_DB}\\
    host: synapse-db\\
    port: 5432\\
    cp_min: 5\\
    cp_max: 10
/^[[:space:]]*name: sqlite3/d
/^[[:space:]]*args:/d
/^[[:space:]]*database:/d
}' /data/homeserver.yaml"
else
    echo -e "  ${YELLOW}SKIP${NC}  homeserver.yaml already uses PostgreSQL (or was manually edited)"
fi

# ── Create Element Web config.json ────────────────────────────────────────
ELEMENT_DIR="${ELEMENT_CONFIG_DIR:-./element}"
mkdir -p "${ELEMENT_DIR}"
ELEMENT_CFG="${ELEMENT_DIR}/config.json"

if [[ -f "${ELEMENT_CFG}" ]]; then
    echo -e "  ${YELLOW}SKIP${NC}  ${ELEMENT_CFG} already exists"
else
    echo -e "  ${GREEN}CREATE${NC}  ${ELEMENT_CFG}"
    cat > "${ELEMENT_CFG}" <<EOF
{
    "default_server_config": {
        "m.homeserver": {
            "base_url": "https://matrix.${SERVER_NAME}",
            "server_name": "${SERVER_NAME}"
        },
        "m.identity_server": {
            "base_url": "https://vector.im"
        }
    },
    "brand": "Element",
    "integrations_ui_url": "https://scalar.vector.im/",
    "integrations_rest_url": "https://scalar.vector.im/api",
    "integrations_widgets_urls": [
        "https://scalar.vector.im/_matrix/integrations/v1",
        "https://scalar.vector.im/api",
        "https://scalar-staging.vector.im/_matrix/integrations/v1",
        "https://scalar-staging.vector.im/api",
        "https://scalar-staging.riot.im/scalar/api"
    ],
    "disable_custom_urls": false,
    "disable_guests": true,
    "disable_login_language_selector": false,
    "disable_3pid_login": false,
    "default_country_code": "FR",
    "show_labs_settings": true,
    "default_theme": "dark"
}
EOF
fi

echo ""
echo "======================================"
echo -e "${GREEN}✅ Preparation complete!${NC}"
echo ""
echo "Next steps:"
echo "  1. Review and edit: ${HOMESERVER}"
echo "     - Check 'server_name' is set to: ${SERVER_NAME}"
echo "     - Verify the PostgreSQL database block is correct"
echo "     - Optionally enable registration:  enable_registration: true"
echo "  2. Review and edit: ${ELEMENT_CFG}"
echo "     - Customise branding, default theme, etc."
echo "  3. Start the stack:"
echo "     docker compose up -d"
echo "  4. Create your first admin user:"
echo "     docker exec -it synapse register_new_matrix_user -c /data/homeserver.yaml http://localhost:8008"
echo ""
