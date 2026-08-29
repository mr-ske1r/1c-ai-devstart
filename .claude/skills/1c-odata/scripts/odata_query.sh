#!/usr/bin/env bash
# Query a 1C database published via OData.
# Handles basic auth, common OData parameters, and pretty-prints JSON if jq is available.
# Credentials can be passed as flags or auto-loaded from a .env file in the working directory.

set -euo pipefail

BASE_URL=""
ENTITY=""
FILTER=""
TOP=""
SELECT=""
SKIP=""
ORDERBY=""
EXPAND=""
FORMAT="json"
ODA_USER=""
ODA_PASS=""
COUNT_ONLY=false
INLINE_COUNT=false
EXTRA_PARAMS=""

usage() {
  cat <<'EOF'
Usage: odata_query.sh -b BASE_URL -e ENTITY [options]

Required:
  -b, --base-url URL    Base OData URL, e.g. http://localhost/DemoSSL/odata/standard.odata
  -e, --entity   NAME   Entity name, e.g. Catalog__Товары or Document__РасходнаяНакладная
                        Pass empty string "" to query the service root (list all entities)
                        Pass "$metadata" to fetch the full schema

Optional query parameters:
  -f, --filter   EXPR   OData $filter expression, e.g. "DeletionMark eq false"
  -t, --top      N      $top — limit number of records returned
  -s, --select   FIELDS $select — comma-separated field names, e.g. "Ref_Key,Description"
  -k, --skip     N      $skip — skip first N records (for paging)
  -o, --orderby  FIELD  $orderby expression, e.g. "Description asc"
  -x, --expand   NAMES  $expand — comma-separated navigation property names
  -F, --format   FMT    Response format: json (default) or xml
      --count           Query $count endpoint (returns a plain integer)
      --inline-count    Add $inlinecount=allpages to get total alongside records
      --param    EXPR   Append a raw query parameter, e.g. "--param '\$apply=groupby(...)'"

Authentication (if not set, auto-loaded from .env in CWD):
  -u, --user     USER   Basic auth username  (env: ODATA_USER)
  -p, --pass     PASS   Basic auth password  (env: ODATA_PASSWORD)

Other:
  -h, --help            Show this help

Environment variables (.env in current directory is auto-sourced):
  ODATA_URL       Base OData URL
  ODATA_USER      Username
  ODATA_PASSWORD  Password

Examples:
  # List top 3 items
  ./odata_query.sh -b http://localhost/DemoSSL/odata/standard.odata \
    -e Catalog__ДемоНоменклатура -t 3

  # Filter by field value
  ./odata_query.sh -e Catalog__ДемоНоменклатура -f "DeletionMark eq false" -t 10

  # Select specific fields
  ./odata_query.sh -e Catalog__ДемоНоменклатура -s "Ref_Key,Description,Code" -t 5

  # Count records matching a filter
  ./odata_query.sh -e Catalog__ДемоНоменклатура -f "DeletionMark eq false" --count

  # Expand tabular part
  ./odata_query.sh -e Document__ДемоРеализация -t 3 \
    -x "Document__ДемоРеализация_Товары"

  # List all available OData entities
  ./odata_query.sh -e ""

  # Full schema (field names, types)
  ./odata_query.sh -e '$metadata' -F xml
EOF
}

# Auto-load .env from current working directory if it exists
if [[ -f ".env" ]]; then
  # Only export matching vars, skip comments and blank lines
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

# Inherit from environment (populated by .env above or set externally)
: "${ODATA_URL:=}"
: "${ODATA_USER:=}"
: "${ODATA_PASSWORD:=}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -b|--base-url)     BASE_URL="$2";    shift 2 ;;
    -e|--entity)       ENTITY="$2";      shift 2 ;;
    -f|--filter)       FILTER="$2";      shift 2 ;;
    -t|--top)          TOP="$2";         shift 2 ;;
    -s|--select)       SELECT="$2";      shift 2 ;;
    -k|--skip)         SKIP="$2";        shift 2 ;;
    -o|--orderby)      ORDERBY="$2";     shift 2 ;;
    -x|--expand)       EXPAND="$2";      shift 2 ;;
    -F|--format)       FORMAT="$2";      shift 2 ;;
    -u|--user)         ODA_USER="$2";    shift 2 ;;
    -p|--pass)         ODA_PASS="$2";    shift 2 ;;
    --count)           COUNT_ONLY=true;  shift ;;
    --inline-count)    INLINE_COUNT=true; shift ;;
    --param)           EXTRA_PARAMS="${EXTRA_PARAMS}&${2}"; shift 2 ;;
    -h|--help)         usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

# Flags override .env values; .env values override empty defaults
[[ -z "$BASE_URL" && -n "$ODATA_URL" ]]      && BASE_URL="$ODATA_URL"
[[ -z "$ODA_USER" && -n "$ODATA_USER" ]]     && ODA_USER="$ODATA_USER"
[[ -z "$ODA_PASS" && -n "$ODATA_PASSWORD" ]] && ODA_PASS="$ODATA_PASSWORD"

if [[ -z "$BASE_URL" ]]; then
  echo "Error: --base-url is required (or set ODATA_URL in .env)." >&2
  usage >&2
  exit 1
fi

# URL-encode a string using node's encodeURIComponent.
# Required on Windows where curl sends non-ASCII bytes verbatim, mangling Cyrillic.
# Used for the entity name (path segment) and query parameter values (filter, select, etc.).
urlencode() {
  if command -v node &>/dev/null; then
    node -e "process.stdout.write(encodeURIComponent(process.argv[1]))" -- "$1"
  else
    # Fallback: pass as-is. Works on Linux/macOS; may fail on Windows with Cyrillic.
    printf '%s' "$1"
  fi
}

# Build the URL (entity name is URL-encoded so Cyrillic survives curl on Windows)
BASE_URL="${BASE_URL%/}"
if [[ -z "$ENTITY" ]]; then
  URL="$BASE_URL"
elif $COUNT_ONLY; then
  URL="${BASE_URL}/$(urlencode "${ENTITY}")/\$count"
else
  URL="${BASE_URL}/$(urlencode "${ENTITY}")"
fi

# Assemble query string.
# Parameter values (filter, select, orderby, expand) are URL-encoded so that
# spaces, Cyrillic string literals, and special chars survive in the query string.
if $COUNT_ONLY; then
  # $count endpoint does not use $format
  PARAMS=""
  [[ -n "$FILTER" ]] && PARAMS="\$filter=$(urlencode "${FILTER}")"
else
  PARAMS="\$format=${FORMAT}"
  [[ -n "$TOP" ]]          && PARAMS="${PARAMS}&\$top=${TOP}"
  [[ -n "$SKIP" ]]         && PARAMS="${PARAMS}&\$skip=${SKIP}"
  [[ -n "$SELECT" ]]       && PARAMS="${PARAMS}&\$select=$(urlencode "${SELECT}")"
  [[ -n "$FILTER" ]]       && PARAMS="${PARAMS}&\$filter=$(urlencode "${FILTER}")"
  [[ -n "$ORDERBY" ]]      && PARAMS="${PARAMS}&\$orderby=$(urlencode "${ORDERBY}")"
  [[ -n "$EXPAND" ]]       && PARAMS="${PARAMS}&\$expand=$(urlencode "${EXPAND}")"
  $INLINE_COUNT            && PARAMS="${PARAMS}&\$inlinecount=allpages"
  [[ -n "$EXTRA_PARAMS" ]] && PARAMS="${PARAMS}${EXTRA_PARAMS}"
fi

if [[ -n "$PARAMS" ]]; then
  FULL_URL="${URL}?${PARAMS}"
else
  FULL_URL="${URL}"
fi

# Build curl arguments
# -g / --globoff: prevents curl from interpreting [] {} in URLs
CURL_ARGS=(-s -g --globoff -H "Accept: application/json")

if [[ -n "$ODA_USER" ]]; then
  # Construct Basic Auth header manually to ensure UTF-8 encoding.
  # curl's -u flag uses the system code page on Windows, which mangles Cyrillic.
  AUTH_B64=$(printf '%s:%s' "${ODA_USER}" "${ODA_PASS}" | base64 -w 0 2>/dev/null \
             || printf '%s:%s' "${ODA_USER}" "${ODA_PASS}" | base64)
  CURL_ARGS+=(-H "Authorization: Basic ${AUTH_B64}")
fi

echo "→ GET ${FULL_URL}" >&2

RESPONSE=$(curl "${CURL_ARGS[@]}" "${FULL_URL}")
EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
  echo "curl failed with exit code ${EXIT_CODE}" >&2
  exit $EXIT_CODE
fi

# $count returns a plain integer, no JSON processing needed
if $COUNT_ONLY; then
  echo "$RESPONSE"
  exit 0
fi

# Pretty-print JSON if jq is available; otherwise output raw
if command -v jq &>/dev/null; then
  echo "$RESPONSE" | jq .
else
  echo "$RESPONSE"
fi
