#!/usr/bin/env bash
# manage-users.sh
# opencodex LAN Share - macOS User Access Key Management
# Usage: ./scripts/server/manage-users.sh [-List] [-Create <name>] [-Revoke <id>]

set -uo pipefail

LIST=false
CREATE=""
REVOKE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -List) LIST=true; shift ;;
        -Create) CREATE="$2"; shift 2 ;;
        -Revoke) REVOKE="$2"; shift 2 ;;
        -h|--help)
            echo ""
            echo "opencodex LAN Share - User Management"
            echo ""
            echo "Usage:"
            echo "  ./scripts/server/manage-users.sh -List"
            echo "  ./scripts/server/manage-users.sh -Create <name>"
            echo "  ./scripts/server/manage-users.sh -Revoke <key-id>"
            echo ""
            echo "Examples:"
            echo "  manage-users.sh -List"
            echo "  manage-users.sh -Create 'Zhang San'"
            echo "  manage-users.sh -Revoke e644d636-63cf-4ce0-934e-9a35e9ad8a26"
            echo ""
            exit 0
            ;;
        *) shift ;;
    esac
done

# Ensure admin token is set
if [[ -z "${OPENCODEX_ADMIN_AUTH_TOKEN:-}" ]]; then
    ADMIN_TOKEN_FILE="$HOME/.opencodex/admin-api-token"
    if [[ -f "$ADMIN_TOKEN_FILE" ]]; then
        export OPENCODEX_ADMIN_AUTH_TOKEN
        OPENCODEX_ADMIN_AUTH_TOKEN=$(cat "$ADMIN_TOKEN_FILE" | tr -d '\n')
        echo "[INFO] Loaded admin token from $ADMIN_TOKEN_FILE"
    else
        echo "[ERROR] Admin token not found." >&2
        echo "  Set OPENCODEX_ADMIN_AUTH_TOKEN env var or ensure ~/.opencodex/admin-api-token exists" >&2
        exit 1
    fi
fi

if $LIST; then
    echo ""
    echo "=== Access Keys ==="
    ocx access key list 2>&1
fi

if [[ -n "$CREATE" ]]; then
    echo ""
    echo "Creating access key for: ${CREATE}..."
    ocx access key create "$CREATE" 2>&1
fi

if [[ -n "$REVOKE" ]]; then
    echo ""
    echo "Revoking access key: ${REVOKE}..."
    ocx access key remove "$REVOKE" --yes 2>&1
fi

# If no action specified, show help
if ! $LIST && [[ -z "$CREATE" ]] && [[ -z "$REVOKE" ]]; then
    echo ""
    echo "opencodex LAN Share - User Management"
    echo ""
    echo "Usage:"
    echo "  $0 -List"
    echo "  $0 -Create <name>"
    echo "  $0 -Revoke <key-id>"
    echo ""
fi