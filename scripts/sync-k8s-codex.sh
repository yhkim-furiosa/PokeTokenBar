#!/bin/bash

set -euo pipefail

# Lightweight remote Codex support: mirror a pod's Codex *usage* into a local
# directory that PokeTokenBar can consume via its existing custom scan root.
#
# Only the rollout lines LocalUsageReader needs — `session_meta`, `"model"` and
# `token_count` — cross the cluster boundary; the rest of each rollout (prompts,
# tool output, file contents) is dropped pod-side. A 23 MB session file leaves as
# ~195 KB gzipped, and no conversation content is written to this machine.

pod="${POKETOKENBAR_REMOTE_POD:-$(id -un)-0}"
namespace="${POKETOKENBAR_REMOTE_NAMESPACE:-}"
container="${POKETOKENBAR_REMOTE_CONTAINER:-workspace}"
context="${POKETOKENBAR_REMOTE_CONTEXT:-}"
remote_codex_home="${POKETOKENBAR_REMOTE_CODEX_HOME:-/root/.codex}"
interval="${POKETOKENBAR_REMOTE_INTERVAL:-120}"
cache_base="${POKETOKENBAR_REMOTE_CACHE:-$HOME/Library/Application Support/PokeTokenBar/RemoteUsage}"
retain_days="${POKETOKENBAR_REMOTE_RETAIN_DAYS:-0}"
watch=false
configure=false

usage() {
    cat <<'EOF'
Usage: scripts/sync-k8s-codex.sh [OPTIONS] [POD [NAMESPACE [CONTAINER]]]

Mirrors the *usage records* from POD:/root/.codex into PokeTokenBar's local
application-support folder. Prompts and tool output are stripped inside the pod
and never leave it. The default pod is <local-user>-0, the namespace comes from
the current kubectl context, and the default container is workspace.

Options:
  --pod NAME          Kubernetes pod (default: <local-user>-0).
  --namespace NAME    Kubernetes namespace (default: current context).
  --container NAME    Pod container (default: workspace).
  --context NAME      kubectl context (default: current context).
  --remote-home PATH  Codex home in the container (default: /root/.codex).
  --cache PATH        Local mirror base directory.
  --interval SECONDS  Watch interval (default: 120).
  --retain-days N     Delete mirrored sessions older than N days (0 = keep all).
  --watch             Sync continuously.
  --configure         Register the mirror as PokeTokenBar's Codex scan root.
  -h, --help          Show this help.

Environment overrides:
  POKETOKENBAR_REMOTE_CONTEXT, POKETOKENBAR_REMOTE_POD,
  POKETOKENBAR_REMOTE_NAMESPACE, POKETOKENBAR_REMOTE_CONTAINER,
  POKETOKENBAR_REMOTE_CODEX_HOME, POKETOKENBAR_REMOTE_CACHE,
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
                --remote-home) remote_codex_home="$2" ;;
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
destination="$cache_base/$context_dir/$namespace/$pod/$container/codex"

configure_scan_root() {
    local domain key existing
    if [[ "$(uname -s)" != "Darwin" ]] || ! command -v defaults >/dev/null; then
        echo "--configure requires macOS and the defaults command" >&2
        return 1
    fi
    domain="io.github.chattymin.poketokenbar"
    key="customScanRoots.codex"
    existing="$(defaults read "$domain" "$key" 2>/dev/null || true)"
    if [[ -n "$existing" ]] && ! grep -Fqx -- "$destination" <<< "$existing"; then
        defaults write "$domain" "$key" "$existing"$'\n'"$destination"
    elif [[ -z "$existing" ]]; then
        defaults write "$domain" "$key" "$destination"
    fi
    echo "Configured PokeTokenBar Codex scan root: $destination"
}

# Retention: the app only reports today / 5h / week / month, so old mirrored
# sessions are dead weight, and pruned files are never re-fetched (the mtime filter
# only ships recently changed sessions) — so the mirror stays bounded.
#
# Age alone is not a safe criterion here. `expandCodexParentClosure` pulls a fork's
# parent chain into the parse set, and `resolveCodexRollouts` falls back to a
# heuristic replay count when no parent is found — so pruning the old parent of a
# recent fork silently changes that fork's token numbers. Ancestors of retained
# sessions are therefore kept regardless of age.
prune_with_retention() {
    local index keep old_files parent_ids before
    index="$(mktemp)"; keep="$(mktemp)"; old_files="$(mktemp)"; parent_ids="$(mktemp)"

    # path <TAB> session id <TAB> parent id, from each rollout's session_meta line.
    while IFS= read -r f; do
        jq -r 'select(.type == "session_meta")
               | [ (.payload.id // .payload.session_id // ""),
                   (.payload.forked_from_id // .payload.parent_thread_id // "") ]
               | @tsv' "$f" 2>/dev/null | head -1 \
        | while IFS= read -r row; do printf '%s\t%s\n' "$f" "$row"; done
    done < <(find "$destination" -type f -name '*.jsonl') > "$index"

    find "$destination" -type f -name '*.jsonl' ! -mtime +"$retain_days" | LC_ALL=C sort > "$keep"
    # Walk parent links to a fixpoint — a parent may itself be a fork.
    while :; do
        before="$(wc -l < "$keep")"
        awk -F'\t' 'NR==FNR {k[$1]; next} ($1 in k) && $3 != "" {print $3}' \
            "$keep" "$index" | LC_ALL=C sort -u > "$parent_ids"
        awk -F'\t' 'NR==FNR {want[$1]; next} ($2 != "") && ($2 in want) {print $1}' \
            "$parent_ids" "$index" >> "$keep"
        LC_ALL=C sort -u "$keep" -o "$keep"
        [[ "$(wc -l < "$keep")" == "$before" ]] && break
    done

    find "$destination" -type f -name '*.jsonl' -mtime +"$retain_days" | LC_ALL=C sort > "$old_files"
    comm -23 "$old_files" "$keep" | while IFS= read -r stale; do
        [[ -n "$stale" ]] && rm -f "$stale"
    done

    # The sweep can take `$destination` itself; recreate it before the marker write.
    find "$destination" -depth -type d -empty -delete
    mkdir -p "$destination/sessions" "$destination/archived_sessions"
    rm -f "$index" "$keep" "$old_files" "$parent_ids"
}

# Runs inside the pod. $1 = Codex home, $2 = mtime floor (epoch seconds).
# Emits a gzipped tar on stdout carrying slimmed rollouts plus a `.remote-files`
# manifest, so one exec covers both transfer and reconciliation.
remote_program() {
    cat <<'REMOTE'
set -eu
home="$1"; since="$2"
cd "$home" || exit 1
[ -d sessions ] || [ -d archived_sessions ] \
    || { echo "no sessions dir under $home" >&2; exit 3; }
command -v jq >/dev/null 2>&1 || { echo "jq not found in pod" >&2; exit 127; }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM
mkdir -p "$tmp/sessions" "$tmp/archived_sessions"

present=""
for d in sessions archived_sessions; do
    [ -d "$d" ] && present="$present $d"
done

# Keep only the three record shapes LocalUsageReader reads, selected by their JSON
# type and reprojected field by field. A substring match (`grep session_meta|
# "model"|token_count`) would also carry whole `response_item`, `user_message` and
# `world_state` lines whose *content* happens to contain those strings — measured:
# 1472 such lines, including prompts, tool output and AGENTS.md text. Rebuilding the
# object is what makes "no conversation content leaves the pod" true rather than likely.
cat > "$tmp/.slim.jq" <<'JQ'
def slim_meta:
  {timestamp, type,
   payload: {
     id: .payload.id,
     session_id: .payload.session_id,
     forked_from_id: .payload.forked_from_id,
     parent_thread_id: .payload.parent_thread_id,
     thread_source: .payload.thread_source,
     # Only the key codexSessionMeta probes; the rest of `source` carries cwd/originator.
     source: (if (.payload.source | type) == "object" and (.payload.source | has("subagent"))
              then {subagent: .payload.source.subagent} else null end)
   }};

# codexModel reads payload.model or payload.turn_context.model — nothing else.
def slim_model:
  {timestamp, type,
   payload: {
     model: .payload.model,
     turn_context: (if (.payload.turn_context | type) == "object"
                    then {model: .payload.turn_context.model} else null end)
   }};

if .type == "session_meta" then slim_meta
# token_count payloads are usage counters and rate-limit windows — no content.
elif (.payload | type) == "object" and .payload.type == "token_count" then .
elif (.payload | type) == "object"
     and ((.payload | has("model"))
          or ((.payload.turn_context | type) == "object"
              and (.payload.turn_context | has("model")))) then slim_model
else empty end
JQ

if [ -n "$present" ]; then
    # shellcheck disable=SC2086
    find $present -type f -name '*.jsonl' -newermt "@$since" -print \
    | while IFS= read -r f; do
        mkdir -p "$tmp/$(dirname "$f")"
        # jq preserves input order, which the session-meta-before-token_count probe
        # depends on. A malformed tail must not abort the sync; jq keeps what it parsed.
        jq -c -f "$tmp/.slim.jq" "$f" > "$tmp/$f" 2>/dev/null || true
        # Carry the source mtime across: the app's incremental cache and the
        # local retention sweep both key off it, and a freshly generated slim
        # file would otherwise look modified-today forever.
        touch -r "$f" "$tmp/$f" 2>/dev/null || true
    done
    # shellcheck disable=SC2086
    find $present -type f -name '*.jsonl' -print | LC_ALL=C sort > "$tmp/.remote-files"
else
    : > "$tmp/.remote-files"
fi

rm -f "$tmp/.slim.jq"
cd "$tmp" && tar -czf - sessions archived_sessions .remote-files
REMOTE
}

sync_once() {
    local parent staging marker last_success since remote_files local_files stale_files
    parent="$(dirname "$destination")"
    mkdir -p "$parent" "$destination"
    staging="$(mktemp -d "$parent/.codex-sync.XXXXXX")"
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
        sh -s -- "$remote_codex_home" "$since" \
        | tar -xzf - -C "$staging"; then
        rm -rf "$staging"
        return 1
    fi
    if [[ ! -f "$remote_files" ]]; then
        rm -rf "$staging"
        return 1
    fi

    # Only recently changed sessions cross the boundary after the first sync.
    rsync -a "$staging/sessions" "$staging/archived_sessions" "$destination/"

    # Reconcile removed/moved sessions so a local stale copy cannot be counted twice.
    # An empty manifest is never treated as "the pod deleted everything" — that would
    # wipe the mirror irrecoverably on a transient remote hiccup. Skipping the sweep
    # only risks keeping a stale copy, which is the survivable direction.
    mkdir -p "$destination/sessions" "$destination/archived_sessions"
    if [[ ! -s "$remote_files" ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') empty remote manifest; skipping stale-file sweep" >&2
    else
        (cd "$destination" && find sessions archived_sessions -type f -name '*.jsonl' -print \
            | LC_ALL=C sort) > "$local_files"
        comm -23 "$local_files" "$remote_files" > "$stale_files"
        while IFS= read -r stale; do
            [[ -n "$stale" && "$stale" != /* && "$stale" != *..* ]] || continue
            rm -f "$destination/$stale"
        done < "$stale_files"
        find "$destination/sessions" "$destination/archived_sessions" -depth -type d -empty -delete
        mkdir -p "$destination/sessions" "$destination/archived_sessions"
    fi

    if [[ "$retain_days" =~ ^[0-9]+$ ]] && (( retain_days > 0 )); then
        prune_with_retention
    fi

    date +%s > "$marker"
    rm -rf "$staging"
    echo "$(date '+%Y-%m-%d %H:%M:%S') synced $namespace/$pod:$remote_codex_home (usage only) -> $destination"
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
