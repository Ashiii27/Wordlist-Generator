#!/usr/bin/env bash
# =============================================================================
# Professional Wordlist Generator — v3.1
# Generates targeted wordlists for authorized security testing.
# =============================================================================

set -Eeuo pipefail

# =============================================================================
# GLOBALS
# =============================================================================

VERSION="3.1"
LOGFILE="/var/log/wordlist-generator.log"
TMP_DIR=""
START_TIME=$(date +%s)

# Defaults
MAX_WORDS=500000
MAX_OUTPUT_MB=100
COMPRESS=false
VERBOSE=false
DRY_RUN=false
FORCE=false
READ_STDIN=false

TARGET=""
OUTPUT=""
BASE_WORDS=()
YEARS=()
LEET=false
DO_MONTHS=false       # renamed from MONTHS to avoid conflict with MONTHS_LIST
DO_SEASONS=false      # renamed from SEASONS for consistency
COMMON_PATTERNS=true
CASE="lower,upper,capitalize"
SEPARATORS=","
SPECIAL_CHARS="!@#"
DIGITS="0-9"

# Counters and files
WRITE_COUNT=0
RAW_FILE=""

# Required commands
required_cmds=(mktemp sort du awk gzip fold getopt wc)

# =============================================================================
# LOGGING
# =============================================================================

info(){ [[ "$VERBOSE" == true ]] && echo -e "[+] $*"; }
warn(){ echo -e "[!] $*" >&2; }
err(){  echo -e "[-] $*" >&2; cleanup; exit 1; }

# =============================================================================
# CLEANUP
# =============================================================================

cleanup(){
    if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
}

trap 'err "Error at line $LINENO"' ERR
trap cleanup EXIT INT TERM

# =============================================================================
# HELP
# =============================================================================

show_help(){
cat <<EOF
Professional Wordlist Generator v${VERSION}

Usage: $0 [OPTIONS] -o <output>

Required:
  -o, --output FILE       Output file (required)

Input sources:
  -t, --target WORD       Target/company name (added to base words)
  -b, --base-file FILE    File with base words (one per line)
  -w, --word WORD         Add single base word (repeatable)
  --stdin                 Read base words from stdin

Mutation options:
  -y, --years LIST        Comma-separated years e.g. 2020,2021
                          Each year must be numeric.
  -l, --leet              Enable leet substitutions (bounded)
  -m, --months            Include month names
  --seasons               Include seasons
  -c, --case TYPES        Case mutations (comma-separated: lower,upper,capitalize,toggle)
  -s, --separators CHARS  Separators to try (comma-separated)
  --digits RANGE          Digit range or list (e.g. 0-99 or 00-99)
  --special CHARS         Special characters to append (e.g. '!@#')

Limits and misc:
  --max-words N           Max number of entries (default: ${MAX_WORDS})
  --max-size MB           Max output size in MB (default: ${MAX_OUTPUT_MB})
  --compress              Gzip the output
  --no-common             Disable common pattern mutations
  --dry-run               Show sample output, no file writes
  --force                 Overwrite output if it already exists
  -v, --verbose           Verbose mode
  -h, --help              Show this help

Examples:
  $0 -t Acme -y 2023,2024 -o acme.txt
  cat words.txt | $0 --stdin -o combined.txt
  $0 -t Corp -l --months --compress --force -o corp.txt.gz
EOF
exit 0
}

# =============================================================================
# VALIDATION HELPERS
# =============================================================================

validate_int(){
    local val="$1" name="$2"
    if ! [[ "$val" =~ ^[0-9]+$ ]]; then
        err "Invalid integer for $name: '$val'"
    fi
}

validate_years(){
    for y in "${YEARS[@]}"; do
        if ! [[ "$y" =~ ^[0-9]+$ ]]; then
            err "Invalid year value: '$y'. Years must be numeric."
        fi
    done
}

check_cmds(){
    local missing=()
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if (( ${#missing[@]} > 0 )); then
        err "Missing required commands: ${missing[*]}"
    fi
}

# =============================================================================
# WRITE HELPERS
# =============================================================================

increment_write(){
    (( WRITE_COUNT++ )) || true

    if (( WRITE_COUNT % 1000 == 0 )); then
        if [[ -f "$RAW_FILE" ]]; then
            local size_mb
            size_mb=$(du -m "$RAW_FILE" | awk '{print $1}')
            if (( size_mb > MAX_OUTPUT_MB )); then
                err "Temporary file exceeded ${MAX_OUTPUT_MB}MB limit"
            fi
        fi
    fi

    if (( WRITE_COUNT > MAX_WORDS )); then
        err "Reached maximum word limit (${MAX_WORDS})"
    fi
}

safe_write(){
    local line="$1"
    [[ -z "$line" ]] && return
    echo "$line" >> "$RAW_FILE"
    increment_write
}

# =============================================================================
# DIGIT EXPANSION
# =============================================================================

expand_digits(){
    local range="$1"
    if [[ "$range" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        local start="${BASH_REMATCH[1]}" end="${BASH_REMATCH[2]}"
        local width="${#start}"
        for (( i=10#$start; i<=10#$end; i++ )); do
            printf "%0${width}d\n" "$i"
        done
    else
        IFS=',' read -ra parts <<< "$range"
        for p in "${parts[@]}"; do
            echo "$p"
        done
    fi
}

# =============================================================================
# CASE MUTATIONS
# =============================================================================

case_mutate(){
    local word="$1"
    IFS=',' read -ra case_list <<< "$CASE"
    for c in "${case_list[@]}"; do
        case "$c" in
            lower)      echo "${word,,}" ;;
            upper)      echo "${word^^}" ;;
            capitalize) echo "${word^}" ;;
            toggle)
                local toggled="" ch
                for (( i=0; i<${#word}; i++ )); do
                    ch="${word:i:1}"
                    if (( i % 2 == 0 )); then toggled+="${ch,}"; else toggled+="${ch^}"; fi
                done
                echo "$toggled"
                ;;
        esac
    done
}

# =============================================================================
# LEET SUBSTITUTIONS
# Bounded to single and double substitutions to prevent combinatorial explosion.
# Uses bash 4+ associative arrays — requires bash >= 4.0.
# =============================================================================

leet_variants(){
    local w="$1"
    local -A map=( [a]=@ [o]=0 [e]=3 [i]=1 [s]=\$ )
    local variants=("$w")

    # single substitutions
    for k in "${!map[@]}"; do
        if [[ "$w" == *"$k"* ]]; then
            variants+=("${w//$k/${map[$k]}}")
        fi
    done

    # double substitutions
    local keys=("${!map[@]}")
    for (( x=0; x<${#keys[@]}; x++ )); do
        for (( y=x+1; y<${#keys[@]}; y++ )); do
            local k1="${keys[x]}" k2="${keys[y]}"
            if [[ "$w" == *"$k1"* && "$w" == *"$k2"* ]]; then
                local tmp="${w//$k1/${map[$k1]}}"
                tmp="${tmp//$k2/${map[$k2]}}"
                variants+=("$tmp")
            fi
        done
    done

    printf "%s\n" "${variants[@]}" | sort -u
}

# =============================================================================
# WORD COMBINATION
# =============================================================================

combine_words(){
    local w1="$1" w2="$2"
    IFS=',' read -ra seps <<< "$SEPARATORS"
    for sep in "${seps[@]}"; do
        safe_write "${w1}${sep}${w2}"
    done
    safe_write "${w1}${w2}"
}

# =============================================================================
# SPECIAL CHAR APPENDING
# Fixed: split the string into an array by character index instead of using
# read -n1 inside a here-string, which was unreliable across bash versions.
# =============================================================================

append_special_chars(){
    local variant="$1"
    local i ch
    for (( i=0; i<${#SPECIAL_CHARS}; i++ )); do
        ch="${SPECIAL_CHARS:i:1}"
        [[ -n "$ch" ]] && safe_write "${variant}${ch}"
    done
}

# =============================================================================
# CORE GENERATION
# =============================================================================

generate(){
    TMP_DIR=$(mktemp -d)
    RAW_FILE="${TMP_DIR}/raw.txt"
    touch "$RAW_FILE"

    info "Temp dir: $TMP_DIR"
    info "Generating mutations..."

    # read base words from stdin if requested
    if [[ "$READ_STDIN" == true ]]; then
        while IFS= read -r line; do
            [[ -n "$line" ]] && BASE_WORDS+=("$line")
        done
    fi

    if (( ${#BASE_WORDS[@]} == 0 )); then
        err "No base words collected. Provide --target, --word, --base-file, or --stdin with content."
    fi

    for word in "${BASE_WORDS[@]}"; do
        while IFS= read -r variant; do
            safe_write "$variant"

            # leet variants of each case mutation
            if [[ "$LEET" == true ]]; then
                while IFS= read -r lvar; do
                    safe_write "$lvar"
                done < <(leet_variants "$variant")
            fi

            # year appending and prepending
            for year in "${YEARS[@]}"; do
                safe_write "${variant}${year}"
                safe_write "${year}${variant}"
            done

            # digit appending
            while IFS= read -r digit; do
                safe_write "${variant}${digit}"
            done < <(expand_digits "$DIGITS")

            # special character appending — fixed
            append_special_chars "$variant"

        done < <(case_mutate "$word")
    done

    # common patterns — now routed through safe_write via combine_words
    if [[ "$COMMON_PATTERNS" == true ]]; then
        local common_list=(admin welcome password changeme security letmein company login)
        for base in "${BASE_WORDS[@]}"; do
            for common in "${common_list[@]}"; do
                combine_words "$base" "$common"
            done
        done
    fi

    # month combinations — now routed through safe_write via combine_words
    if [[ "$DO_MONTHS" == true ]]; then
        local months_list=(January February March April May June July August September October November December)
        for base in "${BASE_WORDS[@]}"; do
            for m in "${months_list[@]}"; do
                combine_words "$base" "$m"
            done
        done
    fi

    # season combinations — now routed through safe_write via combine_words
    if [[ "$DO_SEASONS" == true ]]; then
        local seasons_list=(Spring Summer Autumn Winter)
        for base in "${BASE_WORDS[@]}"; do
            for s in "${seasons_list[@]}"; do
                combine_words "$base" "$s"
            done
        done
    fi

    info "Sorting and deduplicating..."

    if [[ "$DRY_RUN" == true ]]; then
        echo "[dry-run] Sample of generated words:"
        head -n 50 "$RAW_FILE"
        echo "[dry-run] Total raw lines before dedup: $(wc -l < "$RAW_FILE")"
        return
    fi

    local out_tmp="${OUTPUT}.tmp"

    sort -u "$RAW_FILE" > "$out_tmp"

    # final size check on the deduplicated file
    local size_mb
    size_mb=$(du -m "$out_tmp" | awk '{print $1}')
    if (( size_mb > MAX_OUTPUT_MB )); then
        rm -f "$out_tmp"
        err "Final output exceeded ${MAX_OUTPUT_MB}MB limit. Use --max-size to raise it."
    fi

    if [[ -f "$OUTPUT" && "$FORCE" != true ]]; then
        rm -f "$out_tmp"
        err "Output file already exists: $OUTPUT (use --force to overwrite)"
    fi

    mv "$out_tmp" "$OUTPUT"

    if [[ "$COMPRESS" == true ]]; then
        gzip -f "$OUTPUT"
        OUTPUT="${OUTPUT}.gz"
    fi
}

# =============================================================================
# STATS
# =============================================================================

show_stats(){
    local end_time duration lines size
    end_time=$(date +%s)
    duration=$(( end_time - START_TIME ))

    if [[ "$COMPRESS" == true ]]; then
        lines=$(zcat "$OUTPUT" | wc -l)
    else
        lines=$(wc -l < "$OUTPUT")
    fi

    size=$(du -h "$OUTPUT" | awk '{print $1}')

    echo
    echo "========================================"
    echo " Wordlist Generation Complete"
    echo "========================================"
    echo
    echo "Output file : $OUTPUT"
    echo "Entries     : $lines"
    echo "Size        : $size"
    echo "Duration    : ${duration}s"
    echo
}

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

LONGOPTS="target:,base-file:,word:,output:,years:,leet,months,seasons,no-common,case:,separators:,digits:,special:,max-words:,max-size:,compress,dry-run,stdin,force,verbose,help"

# Short opts:
#   t  target
#   b  base-file
#   w  word
#   o  output
#   y  years
#   l  leet
#   m  months
#   s  separators  (note: --case has no short form to avoid -c ambiguity)
#   v  verbose
#   h  help
SHORTOPTS="t:b:w:o:y:lms:vh"

if ! PARSED=$(getopt --options "$SHORTOPTS" --longoptions "$LONGOPTS" --name "$0" -- "$@"); then
    echo "[-] Argument parsing failed. Use -h for help." >&2
    exit 1
fi

eval set -- "$PARSED"

while true; do
    case "$1" in
        -t|--target)
            TARGET="$2"; shift 2 ;;
        -b|--base-file)
            [[ -f "$2" ]] || err "Base file not found: $2"
            mapfile -t _tmpf < "$2"
            BASE_WORDS+=("${_tmpf[@]}")
            shift 2 ;;
        -w|--word)
            BASE_WORDS+=("$2"); shift 2 ;;
        -o|--output)
            OUTPUT="$2"; shift 2 ;;
        -y|--years)
            IFS=',' read -ra YEARS <<< "$2"; shift 2 ;;
        -l|--leet)
            LEET=true; shift ;;
        -m|--months)
            DO_MONTHS=true; shift ;;
        --seasons)
            DO_SEASONS=true; shift ;;
        --no-common)
            COMMON_PATTERNS=false; shift ;;
        --case)
            CASE="$2"; shift 2 ;;
        -s|--separators)
            SEPARATORS="$2"; shift 2 ;;
        --digits)
            DIGITS="$2"; shift 2 ;;
        --special)
            SPECIAL_CHARS="$2"; shift 2 ;;
        --max-words)
            validate_int "$2" "max-words"; MAX_WORDS="$2"; shift 2 ;;
        --max-size)
            validate_int "$2" "max-size"; MAX_OUTPUT_MB="$2"; shift 2 ;;
        --compress)
            COMPRESS=true; shift ;;
        --dry-run)
            DRY_RUN=true; shift ;;
        --stdin)
            READ_STDIN=true; shift ;;
        --force)
            FORCE=true; shift ;;
        -v|--verbose)
            VERBOSE=true; shift ;;
        -h|--help)
            show_help ;;
        --)
            shift; break ;;
        *)
            echo "[-] Unknown option: $1" >&2; exit 1 ;;
    esac
done

# =============================================================================
# PRE-RUN VALIDATION
# =============================================================================

[[ -n "$OUTPUT" ]] || err "Output file is required. Use -o <file>."

if [[ -z "$TARGET" && ${#BASE_WORDS[@]} -eq 0 && "$READ_STDIN" != true ]]; then
    err "No input provided. Use --target, --word, --base-file, or --stdin."
fi

[[ -n "$TARGET" ]] && BASE_WORDS+=("$TARGET")

# validate years after TARGET has been added so BASE_WORDS is finalized
if (( ${#YEARS[@]} > 0 )); then
    validate_years
fi

check_cmds

# bash version check for associative arrays (leet requires bash >= 4)
if [[ "$LEET" == true && "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    err "Leet substitution requires bash >= 4.0. Current: $BASH_VERSION"
fi

# =============================================================================
# MAIN
# =============================================================================

info "Starting wordlist generator v${VERSION}"

generate

if [[ "$DRY_RUN" != true ]]; then
    show_stats
fi

exit 0
