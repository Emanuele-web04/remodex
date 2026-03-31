#!/bin/bash

# beforeShellExecution hook for git commit checks.
# Returns JSON only on stdout.

ltrim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  printf '%s' "$value"
}

json_parse_quoted_string() {
  local text="$1"
  local out=""
  local escaped=0
  local i
  local ch

  if [ "${text:0:1}" != '"' ]; then
    return 1
  fi
  text="${text:1}"

  for ((i = 0; i < ${#text}; i++)); do
    ch="${text:i:1}"
    if [ "$escaped" -eq 1 ]; then
      case "$ch" in
        \"|\\|/) out+="$ch" ;;
        b) out+=$'\b' ;;
        f) out+=$'\f' ;;
        n) out+=$'\n' ;;
        r) out+=$'\r' ;;
        t) out+=$'\t' ;;
        u)
          # Keep unicode escapes as-is for safety.
          out+="\\u${text:i+1:4}"
          i=$((i + 4))
          ;;
        *) out+="$ch" ;;
      esac
      escaped=0
      continue
    fi

    case "$ch" in
      \\) escaped=1 ;;
      \")
        printf '%s' "$out"
        return 0
        ;;
      *) out+="$ch" ;;
    esac
  done

  return 1
}

json_get_string() {
  local json="$1"
  local key="$2"
  local rest

  rest="${json#*\"${key}\"}"
  if [ "$rest" = "$json" ]; then
    return 1
  fi
  rest="${rest#*:}"
  rest="$(ltrim "$rest")"
  json_parse_quoted_string "$rest"
}

json_get_first_array_string() {
  local json="$1"
  local key="$2"
  local rest

  rest="${json#*\"${key}\"}"
  if [ "$rest" = "$json" ]; then
    return 1
  fi
  rest="${rest#*:}"
  rest="$(ltrim "$rest")"
  if [ "${rest:0:1}" != "[" ]; then
    return 1
  fi
  rest="${rest:1}"
  rest="$(ltrim "$rest")"
  json_parse_quoted_string "$rest"
}

allow() {
  printf '%s\n' '{"permission":"allow"}'
  exit 0
}

deny() {
  local user_message="$1"
  local agent_message="$2"
  printf '%s\n' "{\"permission\":\"deny\",\"user_message\":\"${user_message}\",\"agent_message\":\"${agent_message}\"}"
  exit 0
}

HOOK_INPUT="$(cat)"
if [ -z "$HOOK_INPUT" ]; then
  allow
fi

ONE_LINE_INPUT="${HOOK_INPUT//$'\n'/}"
ONE_LINE_INPUT="${ONE_LINE_INPUT//$'\r'/}"

COMMAND="$(json_get_string "$ONE_LINE_INPUT" "command" || true)"
HOOK_CWD="$(json_get_string "$ONE_LINE_INPUT" "cwd" || true)"
WORKSPACE_ROOT="$(json_get_first_array_string "$ONE_LINE_INPUT" "workspace_roots" || true)"
if [ -z "$HOOK_CWD" ]; then
  HOOK_CWD="$(pwd -P 2>/dev/null || pwd)"
fi

# Extra safety guard beyond matcher.
if [[ ! "$COMMAND" =~ (^|[[:space:]])git[[:space:]]+commit($|[[:space:]]) ]]; then
  allow
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$WORKSPACE_ROOT"
if [ -z "$REPO_ROOT" ]; then
  REPO_ROOT="$HOOK_CWD"
fi
if [ -z "$REPO_ROOT" ] && [ -d "${SCRIPT_DIR}/../.git" ]; then
  REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
fi
if [ -z "$REPO_ROOT" ]; then
  allow
fi

CONVEX_DIR="${REPO_ROOT}/convex"
if [ ! -d "$CONVEX_DIR" ]; then
  allow
fi

# Block Date.now() in query functions.
DATE_NOW_IN_QUERIES="$(
  grep -r "Date\.now()" "$CONVEX_DIR"/ --include="*.ts" --include="*.js" \
    | grep -B 5 "query({" \
    | grep "Date\.now()" || true
)"
if [ -n "$DATE_NOW_IN_QUERIES" ]; then
  deny \
    "Commit blocked: found Date.now() inside/near Convex query functions." \
    "beforeShellExecution blocked this git commit because Date.now() was detected near query({}) in convex/. Queries should be deterministic for reactivity. Use server-generated timestamps in writes or pass time as an argument."
fi

# Block .filter() chained from Convex db.query().
FILTER_ON_QUERIES="$(
  grep -r "\.query(.*)\s*\.filter(" "$CONVEX_DIR"/ --include="*.ts" --include="*.js" || true
)"
if [ -n "$FILTER_ON_QUERIES" ]; then
  deny \
    "Commit blocked: found .filter() on Convex db.query() calls." \
    "beforeShellExecution blocked this git commit because .filter() was detected on db.query() in convex/. Prefer indexed access patterns such as .withIndex() for performance and correctness."
fi
allow