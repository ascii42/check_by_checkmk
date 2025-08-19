#!/bin/bash
# check_by_checkmk.sh
# Icinga plugin: holt Service-Status von Check_MK (REST v2 oder Web-API v1) mit Exclude-Patterns
# Dependencies: curl, jq
#
# Author:
#   Felix Longardt <monitoring@longardt.com>
#
# Version history:
# 2025-08-19 Felix Longardt <monitoring@longardt.com>
# Release: 1.0.0
#   Initial release

set -o errexit
set -o nounset
set -o pipefail

OK=0; WARNING=1; CRITICAL=2; UNKNOWN=3

usage() {
  cat <<EOF
Usage: $0 -h <hostname> -s <site-url> [options]

Options:
  -h, --host            Hostname to check services for
  -s, --site-url        Check_MK site URL (e.g. https://checkmk.example.com/mysite)
  -a, --api-token       API token for authentication
  -u, --user            Automation username
  -p, --secret          Automation secret
  -V, --verify-tls      Verify TLS certificates (default: false)
  -v, --verbose         Show individual service status
  -D, --debug           Show detailed debug information
  -d, --detail          Show service details/output (requires --verbose)
  -P, --perfdata        Include extended performance data in output
  -O, --perfdata-only   Show only performance data (no status message)
  -e, --exclude         Exclude services by name (comma-separated patterns)
  -E, --exclude-output  Exclude services by output/details (comma-separated patterns) (requires --detail)
  -i, --include         Include ONLY services matching name patterns (comma-separated)
  -I, --include-output  Include ONLY services matching output patterns (comma-separated) (requires --detail)
  -j, --include-perfdata Include ONLY these services in performance data (comma-separated)
  -g, --exclude-perfdata Exclude these services from performance data (comma-separated)

Patterns can be:
 - exact names:      "SSH"
 - wildcards:        "Filesystem *"
 - regex (surrounded by slashes): "/^Filesystem \\/.*/"


Examples:
  $0 -h myhost -s https://cmk.example.com/mysite -u automation -p secret
  $0 -h myhost -s https://cmk.example.com/mysite -a api_token -v -d
  $0 -h myhost -s https://cmk.example.com/mysite -u user -p secret -i "Filesystem*" -O
  $0 -h myhost -s https://cmk.example.com/mysite -u user -p secret -P -j "CPU*,Memory*"
  $0 -h myhost -s https://cmk.example.com/mysite -u user -p secret -P -g "ESX*,Mount*"

Note: Include filters are applied before exclude filters. Performance data filters
      work independently of service display filters.
EOF
  exit $UNKNOWN
}

# Defaults
VERIFY_TLS=false
VERBOSE=false
DEBUG=false
DETAIL=false
PERFDATA=false
PERFDATA_ONLY=false
EXCLUDE_OUTPUT=false
API_TOKEN=""
API_USER=""
API_SECRET=""
EXCLUDES=()
OUTPUT_EXCLUDES=()
INCLUDES=()
OUTPUT_INCLUDES=()
PERFDATA_INCLUDES=()
PERFDATA_EXCLUDES=()

# Parse args
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -h|--host) HOST="$2"; shift ;;
    -s|--site-url) SITE_URL="$2"; shift ;;
    -a|--api-token) API_TOKEN="$2"; shift ;;
    -u|--user) API_USER="$2"; shift ;;
    -p|--secret) API_SECRET="$2"; shift ;;
    -V|--verify-tls) VERIFY_TLS=true ;;
    -v|--verbose) VERBOSE=true ;;
    -D|--debug) DEBUG=true ;;
    -d|--detail) DETAIL=true ;;
    -P|--perfdata) PERFDATA=true ;;
    -O|--perfdata-only) PERFDATA_ONLY=true ;;
    -i|--include)
      IFS=',' read -r -a raw_includes <<< "$2"
      for p in "${raw_includes[@]}"; do
        p="${p#"${p%%[![:space:]]*}"}"
        p="${p%"${p##*[![:space:]]}"}"
        [[ -n "$p" ]] && INCLUDES+=("$p")
      done
      shift ;;
    -I|--include-output)
      IFS=',' read -r -a raw_includes <<< "$2"
      for p in "${raw_includes[@]}"; do
        p="${p#"${p%%[![:space:]]*}"}"
        p="${p%"${p##*[![:space:]]}"}"
        [[ -n "$p" ]] && OUTPUT_INCLUDES+=("$p")
      done
      shift ;;
    -j|--include-perfdata)
      IFS=',' read -r -a raw_includes <<< "$2"
      for p in "${raw_includes[@]}"; do
        p="${p#"${p%%[![:space:]]*}"}"
        p="${p%"${p##*[![:space:]]}"}"
        [[ -n "$p" ]] && PERFDATA_INCLUDES+=("$p")
      done
      shift ;;
    -g|--exclude-perfdata)
      IFS=',' read -r -a raw_excludes <<< "$2"
      for p in "${raw_excludes[@]}"; do
        p="${p#"${p%%[![:space:]]*}"}"
        p="${p%"${p##*[![:space:]]}"}"
        [[ -n "$p" ]] && PERFDATA_EXCLUDES+=("$p")
      done
      shift ;;
    -e|--exclude)
      IFS=',' read -r -a raw_excludes <<< "$2"
      for p in "${raw_excludes[@]}"; do
        p="${p#"${p%%[![:space:]]*}"}"
        p="${p%"${p##*[![:space:]]}"}"
        [[ -n "$p" ]] && EXCLUDES+=("$p")
      done
      shift ;;
    -E|--exclude-output)
      IFS=',' read -r -a raw_excludes <<< "$2"
      for p in "${raw_excludes[@]}"; do
        p="${p#"${p%%[![:space:]]*}"}"
        p="${p%"${p##*[![:space:]]}"}"
        [[ -n "$p" ]] && OUTPUT_EXCLUDES+=("$p")
      done
      shift ;;
    *) echo "Unknown parameter: $1"; usage ;;
  esac
  shift
done

[[ -z "${HOST:-}" || -z "${SITE_URL:-}" ]] && usage
if [[ -z "${API_TOKEN:-}" && ( -z "${API_USER:-}" || -z "${API_SECRET:-}" ) ]]; then
  echo "ERROR: Provide either --api-token OR --user + --secret"
  exit $UNKNOWN
fi

# curl options - remove --fail to avoid issues with HTTP status codes
CURL_OPTS=(--silent --show-error --connect-timeout 10 --max-time 30)
[[ "$VERIFY_TLS" = false ]] && CURL_OPTS+=(-k)

get_services_rest_v2() {
  # Check_MK 2.4: Use the view.py endpoint to get service states
  # Use HTTP Basic Auth instead of URL parameters
  local url="${SITE_URL%/}/check_mk/view.py"
  local params="host=${HOST}&view_name=host&output_format=json"

  [[ "$DEBUG" = true ]] && echo "DEBUG: Using view.py endpoint: ${url}?${params}" >&2
  [[ "$DEBUG" = true ]] && echo "DEBUG: Full curl command will be:" >&2
  [[ "$DEBUG" = true ]] && echo "curl ${CURL_OPTS[*]} -u \"${API_USER}:****\" \"${url}?${params}\"" >&2

  if [[ -n "${API_USER:-}" && -n "${API_SECRET:-}" ]]; then
    [[ "$DEBUG" = true ]] && echo "DEBUG: Trying view.py with HTTP Basic Auth" >&2
    # Don't capture debug output in the response - only capture actual curl output
    curl "${CURL_OPTS[@]}" \
      -u "${API_USER}:${API_SECRET}" \
      "${url}?${params}"
  else
    [[ "$DEBUG" = true ]] && echo "DEBUG: No automation credentials for view.py" >&2
    return 1
  fi
}

get_services_webapi_v1() {
  # Alternative: Try direct service view for all services on the host
  local url="${SITE_URL%/}/check_mk/view.py"
  local params="host=${HOST}&view_name=host&output_format=json"

  [[ "$DEBUG" = true ]] && echo "DEBUG: Web API fallback using view.py with Basic Auth..." >&2
  # Don't capture debug output in the response - only capture actual curl output
  curl "${CURL_OPTS[@]}" \
    -u "${API_USER}:${API_SECRET}" \
    "${url}?${params}"
}

# returns 0 if service should be included in performance data
is_perfdata_included() {
  local svcname="$1"
  local pat regex

  # If no perfdata include patterns are specified, include everything
  if [[ ${#PERFDATA_INCLUDES[@]} -eq 0 ]]; then
    [[ "$DEBUG" = true ]] && echo "DEBUG: No perfdata include patterns specified, including '$svcname' in perfdata" >&2
    return 0
  fi

  [[ "$DEBUG" = true ]] && echo "DEBUG: Checking if service '$svcname' should be included in perfdata" >&2
  [[ "$DEBUG" = true ]] && echo "DEBUG: Available perfdata include patterns: ${PERFDATA_INCLUDES[*]}" >&2

  # Check perfdata inclusions
  for pat in "${PERFDATA_INCLUDES[@]}"; do
    [[ -z "$pat" ]] && continue
    [[ "$DEBUG" = true ]] && echo "DEBUG: Processing perfdata include pattern: '$pat'" >&2

    if [[ "$pat" =~ ^/.*/$ ]]; then
      regex="${pat:1:${#pat}-2}"
      [[ "$DEBUG" = true ]] && echo "DEBUG: Testing service name '$svcname' against perfdata include regex '$regex'" >&2

      if [[ "$svcname" =~ $regex ]]; then
        [[ "$DEBUG" = true ]] && echo "DEBUG: *** PERFDATA INCLUDE MATCH *** '$svcname' matched regex '$regex'" >&2
        return 0
      fi
    else
      [[ "$DEBUG" = true ]] && echo "DEBUG: Testing service name '$svcname' against perfdata include wildcard '$pat'" >&2
      if [[ "$svcname" == $pat ]]; then
        [[ "$DEBUG" = true ]] && echo "DEBUG: *** PERFDATA INCLUDE MATCH *** '$svcname' matched wildcard '$pat'" >&2
        return 0
      fi
    fi
  done

  [[ "$DEBUG" = true ]] && echo "DEBUG: Service '$svcname' NOT included in perfdata (no include patterns matched)" >&2
  return 1
}

# returns 0 if service should be excluded from performance data
is_perfdata_excluded() {
  local svcname="$1"
  local pat regex

  [[ "$DEBUG" = true ]] && echo "DEBUG: Checking if service '$svcname' should be excluded from perfdata" >&2
  [[ "$DEBUG" = true ]] && echo "DEBUG: Available perfdata exclude patterns: ${PERFDATA_EXCLUDES[*]}" >&2

  # Check perfdata exclusions
  for pat in "${PERFDATA_EXCLUDES[@]}"; do
    [[ -z "$pat" ]] && continue
    [[ "$DEBUG" = true ]] && echo "DEBUG: Processing perfdata exclude pattern: '$pat'" >&2

    if [[ "$pat" =~ ^/.*/$ ]]; then
      regex="${pat:1:${#pat}-2}"
      [[ "$DEBUG" = true ]] && echo "DEBUG: Testing service name '$svcname' against perfdata exclude regex '$regex'" >&2

      if [[ "$svcname" =~ $regex ]]; then
        [[ "$DEBUG" = true ]] && echo "DEBUG: *** PERFDATA EXCLUDE MATCH *** '$svcname' matched regex '$regex'" >&2
        return 0
      fi
    else
      [[ "$DEBUG" = true ]] && echo "DEBUG: Testing service name '$svcname' against perfdata exclude wildcard '$pat'" >&2
      if [[ "$svcname" == $pat ]]; then
        [[ "$DEBUG" = true ]] && echo "DEBUG: *** PERFDATA EXCLUDE MATCH *** '$svcname' matched wildcard '$pat'" >&2
        return 0
      fi
    fi
  done

  [[ "$DEBUG" = true ]] && echo "DEBUG: Service '$svcname' NOT excluded from perfdata" >&2
  return 1
}

# returns 0 if service should be included (matches include patterns)
is_included() {
  local svcname="$1"
  local output="$2"
  local pat regex

  # If no include patterns are specified, include everything
  if [[ ${#INCLUDES[@]} -eq 0 && ${#OUTPUT_INCLUDES[@]} -eq 0 ]]; then
    [[ "$DEBUG" = true ]] && echo "DEBUG: No include patterns specified, including service '$svcname'" >&2
    return 0
  fi

  [[ "$DEBUG" = true ]] && echo "DEBUG: Checking if service '$svcname' should be included" >&2
  [[ "$DEBUG" = true ]] && echo "DEBUG: Available include patterns: ${INCLUDES[*]}" >&2
  [[ "$DEBUG" = true ]] && echo "DEBUG: Available output include patterns: ${OUTPUT_INCLUDES[*]}" >&2

  # Check service name inclusions
  for pat in "${INCLUDES[@]}"; do
    [[ -z "$pat" ]] && continue
    [[ "$DEBUG" = true ]] && echo "DEBUG: Processing include name pattern: '$pat'" >&2

    if [[ "$pat" =~ ^/.*/$ ]]; then
      regex="${pat:1:${#pat}-2}"
      [[ "$DEBUG" = true ]] && echo "DEBUG: Testing service name '$svcname' against include regex '$regex'" >&2

      if [[ "$svcname" =~ $regex ]]; then
        [[ "$DEBUG" = true ]] && echo "DEBUG: *** INCLUDE MATCH *** '$svcname' matched name regex '$regex'" >&2
        return 0
      fi
    else
      [[ "$DEBUG" = true ]] && echo "DEBUG: Testing service name '$svcname' against include wildcard '$pat'" >&2
      if [[ "$svcname" == $pat ]]; then
        [[ "$DEBUG" = true ]] && echo "DEBUG: *** INCLUDE MATCH *** '$svcname' matched name wildcard '$pat'" >&2
        return 0
      fi
    fi
  done

  # Check service output inclusions
  for pat in "${OUTPUT_INCLUDES[@]}"; do
    [[ -z "$pat" ]] && continue
    [[ "$DEBUG" = true ]] && echo "DEBUG: Processing include output pattern: '$pat'" >&2

    if [[ "$pat" =~ ^/.*/$ ]]; then
      regex="${pat:1:${#pat}-2}"
      [[ "$DEBUG" = true ]] && echo "DEBUG: Testing service output '$output' against include regex '$regex'" >&2

      if [[ "$output" =~ $regex ]]; then
        [[ "$DEBUG" = true ]] && echo "DEBUG: *** INCLUDE MATCH *** '$output' matched output regex '$regex'" >&2
        return 0
      fi
    else
      [[ "$DEBUG" = true ]] && echo "DEBUG: Testing service output '$output' against include wildcard '$pat'" >&2
      if [[ "$output" == $pat ]]; then
        [[ "$DEBUG" = true ]] && echo "DEBUG: *** INCLUDE MATCH *** '$output' matched output wildcard '$pat'" >&2
        return 0
      fi
    fi
  done

  [[ "$DEBUG" = true ]] && echo "DEBUG: Service '$svcname' NOT included (no include patterns matched)" >&2
  return 1
}

# returns 0 if svcname matches any exclude pattern
is_excluded() {
  local svcname="$1"
  local output="$2"
  local pat regex

  [[ "$DEBUG" = true ]] && echo "DEBUG: Checking if service '$svcname' should be excluded" >&2
  [[ "$DEBUG" = true ]] && echo "DEBUG: Available exclude patterns: ${EXCLUDES[*]}" >&2
  [[ "$DEBUG" = true ]] && echo "DEBUG: Available output exclude patterns: ${OUTPUT_EXCLUDES[*]}" >&2

  # Check service name exclusions
  for pat in "${EXCLUDES[@]}"; do
    [[ -z "$pat" ]] && continue
    [[ "$DEBUG" = true ]] && echo "DEBUG: Processing exclude name pattern: '$pat'" >&2

    if [[ "$pat" =~ ^/.*/$ ]]; then
      regex="${pat:1:${#pat}-2}"
      [[ "$DEBUG" = true ]] && echo "DEBUG: Testing service name '$svcname' against exclude regex '$regex'" >&2

      if [[ "$svcname" =~ $regex ]]; then
        [[ "$DEBUG" = true ]] && echo "DEBUG: *** EXCLUDE MATCH *** '$svcname' matched name regex '$regex'" >&2
        return 0
      fi
    else
      [[ "$DEBUG" = true ]] && echo "DEBUG: Testing service name '$svcname' against exclude wildcard '$pat'" >&2
      if [[ "$svcname" == $pat ]]; then
        [[ "$DEBUG" = true ]] && echo "DEBUG: *** EXCLUDE MATCH *** '$svcname' matched name wildcard '$pat'" >&2
        return 0
      fi
    fi
  done

  # Check service output exclusions
  for pat in "${OUTPUT_EXCLUDES[@]}"; do
    [[ -z "$pat" ]] && continue
    [[ "$DEBUG" = true ]] && echo "DEBUG: Processing exclude output pattern: '$pat'" >&2

    if [[ "$pat" =~ ^/.*/$ ]]; then
      regex="${pat:1:${#pat}-2}"
      [[ "$DEBUG" = true ]] && echo "DEBUG: Testing service output '$output' against exclude regex '$regex'" >&2

      if [[ "$output" =~ $regex ]]; then
        [[ "$DEBUG" = true ]] && echo "DEBUG: *** EXCLUDE MATCH *** '$output' matched output regex '$regex'" >&2
        return 0
      fi
    else
      [[ "$DEBUG" = true ]] && echo "DEBUG: Testing service output '$output' against exclude wildcard '$pat'" >&2
      if [[ "$output" == $pat ]]; then
        [[ "$DEBUG" = true ]] && echo "DEBUG: *** EXCLUDE MATCH *** '$output' matched output wildcard '$pat'" >&2
        return 0
      fi
    fi
  done

  [[ "$DEBUG" = true ]] && echo "DEBUG: Service '$svcname' NOT excluded" >&2
  return 1
}

process_services_json() {
  local json="$1"
  local source="$2"

  TOTAL=0; OK_COUNT=0; WARN_COUNT=0; CRIT_COUNT=0; UNKNOWN_COUNT=0
  # Separate arrays for different severity levels
  CRITICAL_DETAILS=()
  WARNING_DETAILS=()
  UNKNOWN_DETAILS=()
  OK_DETAILS=()
  PERFDATA_DETAILS=()

  [[ "$DEBUG" = true ]] && echo "DEBUG: Processing JSON from $source" >&2

  # Both sources now use the view.py table format
  # Format: [["header1", "header2", ...], ["value1", "value2", ...], ...]

  if ! jq -e 'type == "array" and length > 1' >/dev/null 2>&1 <<< "$json"; then
    [[ "$DEBUG" = true ]] && echo "DEBUG: Invalid table format in response" >&2
    return 1
  fi

  # Get the header row to find column positions
  local headers
  headers=$(jq -r '.[0] | @json' <<< "$json" 2>/dev/null || echo "[]")

  [[ "$DEBUG" = true ]] && echo "DEBUG: Table headers: $headers" >&2

  # Find column indices for service_description, service_state, plugin output, and perfometer
  local service_desc_idx state_idx output_idx perfometer_idx state_age_idx check_age_idx
  service_desc_idx=$(jq -r '. as $arr | to_entries[] | select(.value == "service_description") | .key' <<< "$headers" 2>/dev/null || echo "-1")
  state_idx=$(jq -r '. as $arr | to_entries[] | select(.value == "service_state") | .key' <<< "$headers" 2>/dev/null || echo "-1")
  output_idx=$(jq -r '. as $arr | to_entries[] | select(.value == "svc_plugin_output") | .key' <<< "$headers" 2>/dev/null || echo "-1")
  perfometer_idx=$(jq -r '. as $arr | to_entries[] | select(.value == "perfometer") | .key' <<< "$headers" 2>/dev/null || echo "-1")
  state_age_idx=$(jq -r '. as $arr | to_entries[] | select(.value == "svc_state_age") | .key' <<< "$headers" 2>/dev/null || echo "-1")
  check_age_idx=$(jq -r '. as $arr | to_entries[] | select(.value == "svc_check_age") | .key' <<< "$headers" 2>/dev/null || echo "-1")

  [[ "$DEBUG" = true ]] && echo "DEBUG: service_description column: $service_desc_idx, service_state column: $state_idx, plugin_output column: $output_idx, perfometer column: $perfometer_idx" >&2

  if [[ "$service_desc_idx" == "-1" ]] || [[ "$state_idx" == "-1" ]]; then
    [[ "$DEBUG" = true ]] && echo "DEBUG: Required columns not found in table" >&2
    return 1
  fi

  # Process data rows (skip header row)
  local row_count=0
  while IFS= read -r row; do
    [[ -z "$row" || "$row" == "null" ]] && continue

    ((row_count++))
    # Skip the first row (headers)
    if [[ $row_count -eq 1 ]]; then
      [[ "$DEBUG" = true ]] && echo "DEBUG: Skipping header row" >&2
      continue
    fi

    local title state output perfometer state_age check_age
    title=$(jq -r ".[$service_desc_idx] // \"unknown\"" <<< "$row" 2>/dev/null || echo "unknown")
    state=$(jq -r ".[$state_idx] // \"UNKNOWN\"" <<< "$row" 2>/dev/null || echo "UNKNOWN")

    # Get plugin output for detail mode
    if [[ "$output_idx" != "-1" ]]; then
      output=$(jq -r ".[$output_idx] // \"\"" <<< "$row" 2>/dev/null || echo "")
      # Decode HTML entities in output
      output=$(echo "$output" | sed 's/&#x27;/'"'"'/g; s/&lt;/</g; s/&gt;/>/g; s/&amp;/\&/g;')
    else
      output=""
    fi

    # Get performance data if available
    if [[ "$perfometer_idx" != "-1" ]]; then
      perfometer=$(jq -r ".[$perfometer_idx] // \"\"" <<< "$row" 2>/dev/null || echo "")
    else
      perfometer=""
    fi

    # Get state and check ages if available
    if [[ "$state_age_idx" != "-1" ]]; then
      state_age=$(jq -r ".[$state_age_idx] // \"\"" <<< "$row" 2>/dev/null || echo "")
    else
      state_age=""
    fi

    if [[ "$check_age_idx" != "-1" ]]; then
      check_age=$(jq -r ".[$check_age_idx] // \"\"" <<< "$row" 2>/dev/null || echo "")
    else
      check_age=""
    fi

    [[ "$DEBUG" = true ]] && echo "DEBUG: Processing service: '$title' with state '$state'" >&2

    # Skip if no service description
    [[ "$title" == "unknown" || "$title" == "null" || -z "$title" ]] && continue

    # Apply include filters first (if any are specified)
    if ! is_included "$title" "$output"; then
      [[ "$DEBUG" = true ]] && echo "DEBUG: Service '$title' not included by include filters" >&2
      continue
    fi

    # Apply exclude filters
    if is_excluded "$title" "$output"; then
      [[ "$DEBUG" = true ]] && echo "DEBUG: Excluding service '$title'" >&2
      continue
    fi

    ((TOTAL++))

    # Convert state names to numbers and build detail string
    case "$state" in
      "OK") state_num=0; ((OK_COUNT++)); LABEL="[OK]" ;;
      "WARN"|"WARNING") state_num=1; ((WARN_COUNT++)); LABEL="[WARNING]" ;;
      "CRIT"|"CRITICAL") state_num=2; ((CRIT_COUNT++)); LABEL="[CRITICAL]" ;;
      *) state_num=3; ((UNKNOWN_COUNT++)); LABEL="[UNKNOWN]" ;;
    esac

    # Add to appropriate severity-based details array for verbose output
    if [[ "$VERBOSE" = true ]]; then
      if [[ "$DETAIL" = true && -n "$output" ]]; then
        detail_line="${LABEL}: ${title} - ${output}"
      else
        detail_line="${LABEL}: ${title}"
      fi
      
      case "$state" in
        "CRIT"|"CRITICAL") CRITICAL_DETAILS+=("$detail_line") ;;
        "WARN"|"WARNING") WARNING_DETAILS+=("$detail_line") ;;
        "OK") OK_DETAILS+=("$detail_line") ;;
        *) UNKNOWN_DETAILS+=("$detail_line") ;;
      esac
    fi

    # Collect performance data if requested
    if [[ "$PERFDATA" = true || "$PERFDATA_ONLY" = true ]]; then
      # Apply perfdata include/exclude filters
      if is_perfdata_included "$title" && ! is_perfdata_excluded "$title"; then
        local perfdata_line="${title}=${state_num}"
        [[ -n "$state_age" ]] && perfdata_line+=";state_age=${state_age}"
        [[ -n "$check_age" ]] && perfdata_line+=";check_age=${check_age}"
        [[ -n "$perfometer" ]] && perfdata_line+=";perfometer=${perfometer}"
        PERFDATA_DETAILS+=("$perfdata_line")
        [[ "$DEBUG" = true ]] && echo "DEBUG: Added perfdata for '$title': $perfdata_line" >&2
      fi
    fi
  done < <(jq -c '.[]' <<< "$json" 2>/dev/null)

  [[ "$DEBUG" = true ]] && echo "DEBUG: Processed $TOTAL services: OK=$OK_COUNT, WARN=$WARN_COUNT, CRIT=$CRIT_COUNT, UNKNOWN=$UNKNOWN_COUNT" >&2

  # Return success if we processed at least one service
  return $(( TOTAL == 0 ? 1 : 0 ))
}

# Main execution logic
API_USED="none"
RESPONSE=""
API_SUCCESS=false

# Try REST API first (either with Basic Auth or Bearer token)
if [[ -n "${API_USER:-}" && -n "${API_SECRET:-}" ]] || [[ -n "${API_TOKEN:-}" ]]; then
  [[ "$DEBUG" = true ]] && echo "DEBUG: Attempting REST API..." >&2
  set +o errexit
  RESPONSE=$(get_services_rest_v2)
  REST_EXIT=$?
  set -o errexit

  [[ "$DEBUG" = true ]] && echo "DEBUG: Response length: ${#RESPONSE} characters" >&2
  [[ "$DEBUG" = true ]] && echo "DEBUG: Response starts with: ${RESPONSE:0:50}..." >&2

  # Check if response is valid JSON array
  if [[ $REST_EXIT -eq 0 ]]; then
    if jq -e 'type == "array" and length > 0' >/dev/null 2>&1 <<< "$RESPONSE"; then
      [[ "$DEBUG" = true ]] && echo "DEBUG: JSON validation passed, processing services..." >&2
      if process_services_json "$RESPONSE" "rest"; then
        API_USED="REST API v1.0"
        API_SUCCESS=true
        [[ "$DEBUG" = true ]] && echo "DEBUG: REST API successful" >&2
      else
        [[ "$DEBUG" = true ]] && echo "DEBUG: Service processing failed" >&2
      fi
    else
      [[ "$DEBUG" = true ]] && echo "DEBUG: Invalid JSON response" >&2
    fi
  else
    [[ "$DEBUG" = true ]] && echo "DEBUG: REST API failed (exit: $REST_EXIT)" >&2
    [[ "$DEBUG" = true ]] && echo "DEBUG: Response preview: ${RESPONSE:0:200}..." >&2
  fi
fi

# Fall back to Web API v1 if REST API failed and credentials are available
if [[ "$API_SUCCESS" = false ]] && [[ -n "${API_USER:-}" && -n "${API_SECRET:-}" ]]; then
  [[ "$DEBUG" = true ]] && echo "DEBUG: Attempting Web API v1 fallback..." >&2
  set +o errexit
  RESPONSE=$(get_services_webapi_v1)
  WEB_EXIT=$?
  set -o errexit

  [[ "$DEBUG" = true ]] && echo "DEBUG: Response length: ${#RESPONSE} characters" >&2
  [[ "$DEBUG" = true ]] && echo "DEBUG: Response starts with: ${RESPONSE:0:50}..." >&2

  # Check if response is valid JSON array
  if [[ $WEB_EXIT -eq 0 ]]; then
    if jq -e 'type == "array" and length > 0' >/dev/null 2>&1 <<< "$RESPONSE"; then
      [[ "$DEBUG" = true ]] && echo "DEBUG: JSON validation passed, processing services..." >&2
      if process_services_json "$RESPONSE" "webapi"; then
        API_USED="Web API v1"
        API_SUCCESS=true
        [[ "$DEBUG" = true ]] && echo "DEBUG: Web API v1 successful" >&2
      else
        [[ "$DEBUG" = true ]] && echo "DEBUG: Service processing failed" >&2
      fi
    else
      [[ "$DEBUG" = true ]] && echo "DEBUG: Invalid JSON response" >&2
    fi
  else
    [[ "$DEBUG" = true ]] && echo "DEBUG: Web API v1 failed (exit: $WEB_EXIT)" >&2
    [[ "$DEBUG" = true ]] && echo "DEBUG: Response preview: ${RESPONSE:0:200}..." >&2
  fi
fi

# Check if any API call was successful
if [[ "$API_SUCCESS" = false ]]; then
  echo "UNKNOWN - All API requests failed. Response: ${RESPONSE:0:200}..."
  exit $UNKNOWN
fi

# Generate performance data and output results
BASIC_PERFDATA="total=${TOTAL} ok=${OK_COUNT} warning=${WARN_COUNT} critical=${CRIT_COUNT} unknown=${UNKNOWN_COUNT}"

# Build extended performance data if requested
EXTENDED_PERFDATA=""
if [[ "$PERFDATA" = true || "$PERFDATA_ONLY" = true ]] && [[ ${#PERFDATA_DETAILS[@]} -gt 0 ]]; then
  # Join all service performance data
  EXTENDED_PERFDATA=" $(IFS=' '; echo "${PERFDATA_DETAILS[*]}")"
fi

# If --perfdata-only flag is used, only show performance data
if [[ "$PERFDATA_ONLY" = true ]]; then
  if [[ -n "$EXTENDED_PERFDATA" ]]; then
    echo "${BASIC_PERFDATA}${EXTENDED_PERFDATA}"
  else
    echo "${BASIC_PERFDATA}"
  fi
  exit $OK
fi

# Function to print sorted verbose output
print_sorted_details() {
  # Print in order of severity: CRITICAL, WARNING, UNKNOWN, OK
  [[ ${#CRITICAL_DETAILS[@]} -gt 0 ]] && printf "%s\n" "${CRITICAL_DETAILS[@]}"
  [[ ${#WARNING_DETAILS[@]} -gt 0 ]] && printf "%s\n" "${WARNING_DETAILS[@]}"
  [[ ${#UNKNOWN_DETAILS[@]} -gt 0 ]] && printf "%s\n" "${UNKNOWN_DETAILS[@]}"
  [[ ${#OK_DETAILS[@]} -gt 0 ]] && printf "%s\n" "${OK_DETAILS[@]}"
}

# Determine which perfdata to use in the output
FINAL_PERFDATA="$BASIC_PERFDATA"
if [[ "$PERFDATA" = true && -n "$EXTENDED_PERFDATA" ]]; then
  FINAL_PERFDATA="${BASIC_PERFDATA}${EXTENDED_PERFDATA}"
fi

if (( CRIT_COUNT > 0 )); then
  echo "[CRITICAL] - ${CRIT_COUNT} critical services (${API_USED}) | ${FINAL_PERFDATA}"
  [[ "$VERBOSE" = true ]] && print_sorted_details
  exit $CRITICAL
elif (( WARN_COUNT > 0 )); then
  echo "[WARNING] - ${WARN_COUNT} warning services (${API_USED}) | ${FINAL_PERFDATA}"
  [[ "$VERBOSE" = true ]] && print_sorted_details
  exit $WARNING
elif (( UNKNOWN_COUNT > 0 )); then
  echo "[UNKNOWN] - ${UNKNOWN_COUNT} unknown services (${API_USED}) | ${FINAL_PERFDATA}"
  [[ "$VERBOSE" = true ]] && print_sorted_details
  exit $UNKNOWN
else
  echo "[OK] - All ${TOTAL} services OK (${API_USED}) | ${FINAL_PERFDATA}"
  [[ "$VERBOSE" = true ]] && print_sorted_details
  exit $OK
fi
