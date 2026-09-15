#!/bin/bash

set -euo pipefail

# Lightweight remote Claude Code support: mirror a pod's Claude *usage* into a
# local directory that PokeTokenBar can consume via its existing custom scan root.
#
# Only the fields LocalUsageReader.parseClaudeLine actually reads cross the
# cluster boundary — `jq` strips prompts, tool output and file contents pod-side
# before the tar stream is built. A 5 MB session file leaves as ~24 KB gzipped,
# and no conversation content is ever written to this machine.
#
# Claude's scan root is the `projects` directory itself (`<root>/**/*.jsonl`),
# and its provider id is `claude_code`.

pod="${POKETOKENBAR_REMOTE_POD:-$(id -un)-0}"
namespace="${POKETOKENBAR_REMOTE_NAMESPACE:-}"
container="${POKETOKENBAR_REMOTE_CONTAINER:-workspace}"
context="${POKETOKENBAR_REMOTE_CONTEXT:-}"
remote_claude_home="${POKETOKENBAR_REMOTE_CLAUDE_HOME:-/root/.claude}"
interval="${POKETOKENBAR_REMOTE_INTERVAL:-120}"
cache_base="${POKETOKENBAR_REMOTE_CACHE:-$HOME/Library/Application Support/PokeTokenBar/RemoteUsage}"
retain_days="${POKETOKENBAR_REMOTE_RETAIN_DAYS:-0}"
watch=false
configure=false

usage() {
    cat <<'EOF'
Usage: scripts/sync-k8s-claude.sh [OPTIONS] [POD [NAMESPACE [CONTAINER]]]

Mirrors the *usage records* from POD:/root/.claude/projects into PokeTokenBar's
local application-support folder. Prompts and tool output are stripped inside the
pod and never leave it. The default pod is <local-user>-0, the namespace comes
from the current kubectl context, and the default container is workspace.

Options:
  --pod NAME          Kubernetes pod (default: <local-user>-0).
  --namespace NAME    Kubernetes namespace (default: current context).
  --container NAME    Pod container (default: workspace).
  --context NAME      kubectl context (default: current context).
  --remote-home PATH  Claude home in the container (default: /root/.claude).
  --cache PATH        Local mirror base directory.
  --interval SECONDS  Watch interval (default: 120).
  --retain-days N     Delete mirrored sessions older than N days (0 = keep all).
  --watch             Sync continuously.
  --configure         Register the mirror as PokeTokenBar's Claude scan root.
  -h, --help          Show this help.

Environment overrides:
  POKETOKENBAR_REMOTE_CONTEXT, POKETOKENBAR_REMOTE_POD,
  POKETOKENBAR_REMOTE_NAMESPACE, POKETOKENBAR_REMOTE_CONTAINER,
  POKETOKENBAR_REMOTE_CLAUDE_HOME, POKETOKENBAR_REMOTE_CACHE,
  POKETOKENBAR_REMOTE_INTERVAL, POKETOKENBAR_REMOTE_RETAIN_DAYS, KUBECTL_BIN
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pod|--namespace|--container|--context|--remote-home|--cache|--interval|--retain-days)
            if [[ $# -lt 2 ]]; then
                echo "$1 requires a value" >&2
                exit 2
            fi
            case "$1" in
                --pod) pod="$2" ;;
                --namespace) namespace="$2" ;;
                --container) container="$2" ;;
                --context) context="$2" ;;
                --remote-home) remote_claude_home="$2" ;;
                --cache) cache_base="$2" ;;
                --interval) interval="$2" ;;
                --retain-days) retain_days="$2" ;;
            esac
            shift 2
            ;;
        --watch) watch=true; shift ;;
        --configure) configure=true; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; break ;;
        -*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
        *) break ;;
    esac
done

# Options after the first positional are not parsed — reject them instead of
# silently binding `--configure` to $namespace and failing later inside kubectl.
for arg in "$@"; do
    case "$arg" in
        -*) echo "Options must come before the positional pod name: $arg" >&2
            usage >&2; exit 2 ;;
    esac
done

pod="${1:-$pod}"
namespace="${2:-$namespace}"
container="${3:-$container}"

kubectl_bin="${KUBECTL_BIN:-}"
if [[ -z "$kubectl_bin" ]]; then
    kubectl_bin="$(command -v kubectl || true)"
fi
if [[ -z "$kubectl_bin" ]]; then
    for candidate in /opt/homebrew/bin/kubectl /usr/local/bin/kubectl; do
        if [[ -x "$candidate" ]]; then
            kubectl_bin="$candidate"
            break
        fi
    done
fi
if [[ -z "$kubectl_bin" ]]; then
    echo "kubectl not found" >&2
    exit 1
fi

context="${context:-$($kubectl_bin config current-context)}"
if [[ -z "$namespace" ]]; then
    namespace="$($kubectl_bin --context "$context" config view --minify -o 'jsonpath={..namespace}')"
    namespace="${namespace:-default}"
fi
context_dir="${context//\//_}"
context_dir="${context_dir//../_}"
destination="$cache_base/$context_dir/$namespace/$pod/$container/claude/projects"

configure_scan_root() {
    local domain key existing
    if [[ "$(uname -s)" != "Darwin" ]] || ! command -v defaults >/dev/null; then
        echo "--configure requires macOS and the defaults command" >&2
        return 1
    fi
    domain="io.github.chattymin.poketokenbar"
    key="customScanRoots.claude_code"
    existing="$(defaults read "$domain" "$key" 2>/dev/null || true)"
    if [[ -n "$existing" ]] && ! grep -Fqx -- "$destination" <<< "$existing"; then
        defaults write "$domain" "$key" "$existing"$'\n'"$destination"
    elif [[ -z "$existing" ]]; then
        defaults write "$domain" "$key" "$destination"
    fi
    echo "Configured PokeTokenBar Claude scan root: $destination"
}

# Runs inside the pod. $1 = Claude home, $2 = mtime floor (epoch seconds).
# Emits a gzipped tar on stdout carrying slimmed `projects/**/*.jsonl` plus a
# `.remote-files` manifest, so one exec covers both transfer and reconciliation.
remote_program() {
    cat <<'REMOTE'
set -eu
home="$1"; since="$2"
cd "$home" || exit 1
# A missing scan dir must fail the cycle, not ship an empty manifest — an empty
# manifest means "the pod deleted everything" to the reconciler.
[ -d projects ] || { echo "no projects dir under $home" >&2; exit 3; }
command -v jq >/dev/null 2>&1 || { echo "jq not found in pod" >&2; exit 127; }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM
mkdir -p "$tmp/projects"

# Only the fields parseClaudeLine reads. Everything else stays in the pod.
cat > "$tmp/.slim.jq" <<'JQ'
select(.type == "assistant" and .message.usage != null)
| {type, timestamp, requestId,
   message: {id: .message.id, model: .message.model, usage: .message.usage}}
JQ

find projects -type f -name '*.jsonl' -newermt "@$since" -print \
| while IFS= read -r f; do
    mkdir -p "$tmp/$(dirname "$f")"
    # A malformed tail must not abort the whole sync; jq keeps what it parsed.
    jq -c -f "$tmp/.slim.jq" "$f" > "$tmp/$f" 2>/dev/null || true
    # Carry the source mtime across: the app's incremental cache and the
    # local retention sweep both key off it, and a freshly generated slim
    # file would otherwise look modified-today forever.
    touch -r "$f" "$tmp/$f" 2>/dev/null || true
done

# Manifest of everything that currently exists, for stale-copy reconciliation.
find projects -type f -name '*.jsonl' -print | LC_ALL=C sort > "$tmp/.remote-files"

rm -f "$tmp/.slim.jq"
cd "$tmp" && tar -czf - projects .remote-files
REMOTE
}

sync_once() {
    local parent staging marker last_success since remote_files local_files stale_files
    parent="$(dirname "$destination")"
    mkdir -p "$parent" "$destination"
    staging="$(mktemp -d "$parent/.claude-sync.XXXXXX")"
    marker="$destination/.last-sync"
    remote_files="$staging/.remote-files"
    local_files="$staging/.local-files"
    stale_files="$staging/.stale-files"

    last_success=0
    if [[ -f "$marker" ]]; then
        read -r last_success < "$marker" || last_success=0
    fi
    [[ "$last_success" =~ ^[0-9]+$ ]] || last_success=0
    since=$((last_success > 300 ? last_success - 300 : 0))

    if ! remote_program | "$kubectl_bin" --context "$context" exec -i \
        -n "$namespace" "$pod" -c "$container" -- \
        sh -s -- "$remote_claude_home" "$since" \
        | tar -xzf - -C "$staging"; then
        rm -rf "$staging"
        return 1
    fi
    if [[ ! -f "$remote_files" ]]; then
        rm -rf "$staging"
        return 1
    fi

    # Only recently changed sessions cross the boundary after the first sync.
    # `projects/` is stripped: the destination *is* the projects root.
    rsync -a "$staging/projects/" "$destination/"

    # Reconcile removed/moved sessions so a local stale copy cannot be counted twice.
    # An empty manifest is never treated as "the pod deleted everything" — that would
    # wipe the mirror irrecoverably on a transient remote hiccup. Skipping the sweep
    # only risks keeping a stale copy, which is the survivable direction.
    if [[ ! -s "$remote_files" ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') empty remote manifest; skipping stale-file sweep" >&2
    else
        # Paths in the manifest are `projects/...`; strip that prefix to compare.
        sed 's|^projects/|./|' "$remote_files" | LC_ALL=C sort > "$remote_files.rel"
        (cd "$destination" && find . -type f -name '*.jsonl' -print | LC_ALL=C sort) \
            > "$local_files"
        comm -23 "$local_files" "$remote_files.rel" > "$stale_files"
        while IFS= read -r stale; do
            [[ -n "$stale" && "$stale" != /* && "$stale" != *..* ]] || continue
            rm -f "$destination/$stale"
        done < "$stale_files"
        find "$destination" -depth -type d -empty -delete
        mkdir -p "$destination"
    fi

    # Retention: the app only reports today / 5h / week / month, so old mirrored
    # sessions are dead weight. Pruned files are never re-fetched — the mtime
    # filter only ships recently changed sessions — so the mirror stays bounded.
    # The empty-dir sweep can take `$destination` itself, so it is recreated before
    # the marker is written (a missing destination would fail the write under set -e).
    if [[ "$retain_days" =~ ^[0-9]+$ ]] && (( retain_days > 0 )); then
        find "$destination" -type f -name '*.jsonl' -mtime +"$retain_days" -delete
        find "$destination" -depth -type d -empty -delete
        mkdir -p "$destination"
    fi

    date +%s > "$marker"
    rm -rf "$staging"
    echo "$(date '+%Y-%m-%d %H:%M:%S') synced $namespace/$pod:$remote_claude_home/projects (usage only) -> $destination"
}

if [[ "$watch" == true ]]; then
    did_configure=false
    while true; do
        if sync_once; then
            if [[ "$configure" == true && "$did_configure" == false ]]; then
                configure_scan_root || true
                did_configure=true
            fi
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') sync failed; retrying in ${interval}s" >&2
        fi
        sleep "$interval"
    done
else
    sync_once
    if [[ "$configure" == true ]]; then
        configure_scan_root || true
    fi
fi
