#!/usr/bin/env bash
# Provision an OpenBSD tailnet host as a private OmniFocus WebDAV sync server.
# Usage: ./install.sh <host> [omnifocus-username]
# Author: Dmitry Kalashnikov
set -euo pipefail

usage() {
    echo "usage: $0 <host> [omnifocus-username]" >&2
    echo "  host                 SSH target on your tailnet, e.g. puffy or user@puffy" >&2
    echo "  omnifocus-username   sync username (prompted on the host if omitted)" >&2
    exit 1
}

[[ $# -ge 1 && $# -le 2 ]] || usage
host=$1
of_user=${2:-}
if [[ -n $of_user && ! $of_user =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "error: username may only contain letters, digits, '.', '_' and '-'" >&2
    exit 1
fi

script_dir=$(cd "$(dirname "$0")" && pwd)

remote_tmp=$(ssh "$host" 'mktemp -d')
trap 'ssh "$host" "rm -rf $remote_tmp" >/dev/null 2>&1 || true' EXIT

scp -q "$script_dir/setup-remote.sh" "$host:$remote_tmp/setup-remote.sh"
# -t gives doas and the password prompts a TTY; secrets are typed directly on the remote side
ssh -t "$host" "doas ksh $remote_tmp/setup-remote.sh $of_user"
