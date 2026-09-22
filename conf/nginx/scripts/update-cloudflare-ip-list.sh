#!/bin/bash
set -euo pipefail

# Update the trusted Cloudflare proxy ranges without exposing a partial file.

TARGET_FILE="${CLOUDFLARE_IP_LIST_FILE:-/etc/nginx/globals/cloudflare-ip-list.conf}"
IPV4_URL="${CLOUDFLARE_IPV4_URL:-https://www.cloudflare.com/ips-v4}"
IPV6_URL="${CLOUDFLARE_IPV6_URL:-https://www.cloudflare.com/ips-v6}"
TEMP_FILE=$(mktemp "${TARGET_FILE}.tmp.XXXXXX")

cleanup() {
    rm -f "$TEMP_FILE"
}
trap cleanup EXIT

validate_ipv4_cidr() {
    local cidr="$1"
    local address
    local prefix
    local octet
    local -a octets

    [[ "$cidr" == */* ]] || return 1
    address=${cidr%/*}
    prefix=${cidr##*/}
    [[ "$address" != */* ]] || return 1
    [[ "$prefix" =~ ^(0|[1-9][0-9]?)$ ]] || return 1
    [ "$prefix" -le 32 ] || return 1

    IFS='.' read -r -a octets <<< "$address"
    [ "${#octets[@]}" -eq 4 ] || return 1
    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^(0|[1-9][0-9]{0,2})$ ]] || return 1
        [ "$octet" -le 255 ] || return 1
    done
}

count_ipv6_hextets() {
    local sequence="$1"
    local hextet
    local -a hextets

    if [ -z "$sequence" ]; then
        printf '0\n'
        return 0
    fi

    IFS=':' read -r -a hextets <<< "$sequence"
    for hextet in "${hextets[@]}"; do
        [[ "$hextet" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
    done
    printf '%s\n' "${#hextets[@]}"
}

validate_ipv6_cidr() {
    local cidr="$1"
    local address
    local prefix
    local left
    local right
    local left_count
    local right_count
    local total_count

    [[ "$cidr" == */* ]] || return 1
    address=${cidr%/*}
    prefix=${cidr##*/}
    [[ "$address" != */* ]] || return 1
    [[ "$prefix" =~ ^(0|[1-9][0-9]{0,2})$ ]] || return 1
    [ "$prefix" -le 128 ] || return 1
    [[ "$address" =~ ^[0-9A-Fa-f:]+$ ]] || return 1

    if [[ "$address" == *::* ]]; then
        right=${address#*::}
        [[ "$right" != *::* ]] || return 1
        left=${address%%::*}
        [[ "$left" != :* && "$left" != *: ]] || return 1
        [[ "$right" != :* && "$right" != *: ]] || return 1
        left_count=$(count_ipv6_hextets "$left") || return 1
        right_count=$(count_ipv6_hextets "$right") || return 1
        total_count=$((left_count + right_count))
        [ "$total_count" -lt 8 ] || return 1
    else
        [[ "$address" != :* && "$address" != *: ]] || return 1
        total_count=$(count_ipv6_hextets "$address") || return 1
        [ "$total_count" -eq 8 ] || return 1
    fi
}

append_ranges() {
    local family="$1"
    local ranges="$2"
    local range
    local count=0

    while IFS= read -r range; do
        [ -n "$range" ] || continue

        case "$family" in
            ipv4)
                if ! validate_ipv4_cidr "$range"; then
                    echo "ERROR: Invalid IPv4 range received: $range" >&2
                    return 1
                fi
                ;;
            ipv6)
                if ! validate_ipv6_cidr "$range"; then
                    echo "ERROR: Invalid IPv6 range received: $range" >&2
                    return 1
                fi
                ;;
        esac

        printf 'set_real_ip_from %s;\n' "$range"
        count=$((count + 1))
    done <<< "$ranges"

    if [ "$count" -eq 0 ]; then
        echo "ERROR: Cloudflare returned an empty ${family} range list" >&2
        return 1
    fi
}

ipv4_ranges=$(curl -fsSL "$IPV4_URL")
ipv6_ranges=$(curl -fsSL "$IPV6_URL")

append_ranges ipv4 "$ipv4_ranges" >> "$TEMP_FILE"
append_ranges ipv6 "$ipv6_ranges" >> "$TEMP_FILE"

if [ -e "$TARGET_FILE" ]; then
    chmod --reference="$TARGET_FILE" "$TEMP_FILE"
else
    chmod 0644 "$TEMP_FILE"
fi

mv -f "$TEMP_FILE" "$TARGET_FILE"
trap - EXIT
