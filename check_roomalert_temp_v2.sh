#!/bin/bash
# Nagios XI plugin for AVTECH Room Alert 3S internal temperature.
# Version 2.0
#
# Reads ROOMALERT3S-MIB::internal-tempc.0, whose value is hundredths of °C.
# Example: 1711 => 17.11 °C
#
# Supports the standard Nagios threshold range syntax:
#   18       alert if value < 0 or value > 18
#   12:18    alert if value < 12 or value > 18
#   ~:18     alert if value > 18
#   12:      alert if value < 12
#   @12:18   alert if value is inside 12 through 18, inclusive
#
# Nagios exit codes:
#   0 = OK
#   1 = WARNING
#   2 = CRITICAL
#   3 = UNKNOWN

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

PROGNAME="$(basename "$0")"
VERSION="2.0"
OID="ROOMALERT3S-MIB::internal-tempc.0"
MIB="ROOMALERT3S-MIB"
SNMPGET="${SNMPGET:-/usr/bin/snmpget}"

HOST=""
COMMUNITY="public"
WARNING="12:18"
CRITICAL="10:20"
LABEL="Room Alert Temperature"
TIMEOUT="10"
RETRIES="1"

usage() {
    cat <<USAGE
$PROGNAME version $VERSION

Usage:
  $PROGNAME -H <host> [-C <community>] [-w <range>] [-c <range>]
            [-l <label>] [-t <timeout>] [-r <retries>]

Required:
  -H  Room Alert IPv4 address or hostname

Optional:
  -C  SNMP v2c community       Default: public
  -w  Nagios warning range     Default: 12:18
  -c  Nagios critical range    Default: 10:20
  -l  Service label            Default: Room Alert Temperature
  -t  SNMP timeout in seconds  Default: 10
  -r  SNMP retries             Default: 1
  -V  Show plugin version
  -h  Show this help

Nagios threshold examples:
  18       Warning/Critical outside 0 through 18
  12:18    Warning/Critical below 12 or above 18
  ~:18     Warning/Critical only above 18
  12:      Warning/Critical only below 12
  @12:18   Warning/Critical inside 12 through 18

Example:
  $PROGNAME -H 10.0.0.35 -C monitoratge \
    -w 12:18 -c 10:20 -l "Temperatura Site"
USAGE
}

unknown() {
    echo "UNKNOWN - $1"
    exit 3
}

# Validate standard Nagios range syntax.
# Valid forms include: 18, 12:18, ~:18, 12:, @12:18, negative/decimal values.
validate_range() {
    local range="$1"

    awk -v range="$range" '
    function isnum(s) {
        return s ~ /^-?([0-9]+([.][0-9]*)?|[.][0-9]+)$/
    }
    BEGIN {
        if (substr(range, 1, 1) == "@") {
            range = substr(range, 2)
        }

        if (range == "") exit 1

        colon_count = gsub(/:/, ":", range)
        if (colon_count > 1) exit 1

        if (colon_count == 0) {
            if (!isnum(range)) exit 1
            exit 0
        }

        split(range, part, ":")
        start = part[1]
        end = part[2]

        if (start != "" && start != "~" && !isnum(start)) exit 1
        if (end != "" && !isnum(end)) exit 1
        if (start == "~" && end == "") exit 1

        # When both bounds are finite, start must not exceed end.
        if (start != "" && start != "~" && end != "" && (start + 0) > (end + 0)) exit 1

        exit 0
    }'
}

# Return success (0) when VALUE triggers RANGE according to Nagios rules.
threshold_triggered() {
    local value="$1"
    local range="$2"

    awk -v value="$value" -v range="$range" '
    BEGIN {
        invert = 0
        if (substr(range, 1, 1) == "@") {
            invert = 1
            range = substr(range, 2)
        }

        if (index(range, ":") == 0) {
            start = 0
            end = range + 0
            start_inf = 0
            end_inf = 0
        } else {
            split(range, part, ":")

            if (part[1] == "~") {
                start_inf = 1
                start = 0
            } else if (part[1] == "") {
                start_inf = 0
                start = 0
            } else {
                start_inf = 0
                start = part[1] + 0
            }

            if (part[2] == "") {
                end_inf = 1
                end = 0
            } else {
                end_inf = 0
                end = part[2] + 0
            }
        }

        inside = (start_inf || value >= start) && (end_inf || value <= end)
        alert = invert ? inside : !inside
        exit(alert ? 0 : 1)
    }'
}

while getopts ":H:C:w:c:l:t:r:hV" option; do
    case "$option" in
        H) HOST="$OPTARG" ;;
        C) COMMUNITY="$OPTARG" ;;
        w) WARNING="$OPTARG" ;;
        c) CRITICAL="$OPTARG" ;;
        l) LABEL="$OPTARG" ;;
        t) TIMEOUT="$OPTARG" ;;
        r) RETRIES="$OPTARG" ;;
        h) usage; exit 0 ;;
        V) echo "$PROGNAME version $VERSION"; exit 0 ;;
        :) unknown "Option -$OPTARG requires a value" ;;
        \?) unknown "Invalid option: -$OPTARG" ;;
    esac
done

[[ -n "$HOST" ]] || { usage; exit 3; }
[[ -x "$SNMPGET" ]] || unknown "snmpget was not found or is not executable at $SNMPGET"
[[ "$TIMEOUT" =~ ^[0-9]+$ ]] || unknown "Timeout must be a non-negative integer"
[[ "$RETRIES" =~ ^[0-9]+$ ]] || unknown "Retries must be a non-negative integer"

validate_range "$WARNING" || unknown "Invalid warning range: $WARNING"
validate_range "$CRITICAL" || unknown "Invalid critical range: $CRITICAL"

SNMP_OUTPUT="$($SNMPGET \
    -v2c \
    -c "$COMMUNITY" \
    -t "$TIMEOUT" \
    -r "$RETRIES" \
    -m "+$MIB" \
    -Oqv \
    "$HOST" \
    "$OID" 2>&1)"
SNMP_STATUS=$?

if [[ $SNMP_STATUS -ne 0 ]]; then
    unknown "SNMP query failed for $HOST: $SNMP_OUTPUT"
fi

# -Oqv normally returns only "1711". Extract a signed integer defensively.
RAW_VALUE="$(printf '%s\n' "$SNMP_OUTPUT" | awk 'match($0, /-?[0-9]+/) { print substr($0, RSTART, RLENGTH); exit }')"
[[ "$RAW_VALUE" =~ ^-?[0-9]+$ ]] || unknown "Invalid SNMP value for $OID: $SNMP_OUTPUT"

# Room Alert exposes hundredths of one degree Celsius: 1711 => 17.11.
TEMPERATURE="$(awk -v raw="$RAW_VALUE" 'BEGIN { printf "%.2f", raw / 100 }')"

# Nagios performance data format:
# label=value[UOM];warning;critical;min;max
# Range strings are preserved so Nagios XI/PNP4Nagios can graph the metric.
PERFDATA="'temperature'=${TEMPERATURE}C;${WARNING};${CRITICAL};;"

# Critical must be evaluated before warning.
if threshold_triggered "$TEMPERATURE" "$CRITICAL"; then
    echo "CRITICAL - $LABEL: ${TEMPERATURE} °C (outside critical range ${CRITICAL}) | $PERFDATA"
    exit 2
elif threshold_triggered "$TEMPERATURE" "$WARNING"; then
    echo "WARNING - $LABEL: ${TEMPERATURE} °C (outside warning range ${WARNING}) | $PERFDATA"
    exit 1
else
    echo "OK - $LABEL: ${TEMPERATURE} °C | $PERFDATA"
    exit 0
fi
