# Professional Wordlist Generator

A targeted wordlist generator for authorized penetration testing and CTF work. Given one or more base words (a company name, a product, a person), it produces a comprehensive set of mutations covering case variations, leet substitutions, digit suffixes, year combinations, special characters, common password patterns, months, and seasons. Output is deduplicated, size-bounded, and optionally gzip compressed.

---

## Requirements

- bash 4.0 or higher (required for associative arrays used in leet substitution)
- Standard GNU utilities: mktemp, sort, du, awk, gzip, fold, getopt, wc
- Linux or WSL (macOS ships bash 3 by default — install bash via Homebrew if needed)

To check your bash version:

```bash
bash --version
```

---

## Installation

No installation needed. Just clone and make executable.

```bash
git clone https://github.com/Ashiii27/Wordlist-Generator
cd Wordlist-Generator
chmod +x wordlist-generator.sh
```

---

## Quick start

Generate a wordlist targeting a company called Acme with years 2023 and 2024:

```bash
./wordlist-generator.sh -t Acme -y 2023,2024 -o acme.txt
```

Generate from a file of base words with leet substitution and month combinations:

```bash
./wordlist-generator.sh -b words.txt -l --months -o output.txt
```

Pipe words from stdin:

```bash
cat seeds.txt | ./wordlist-generator.sh --stdin -o combined.txt
```

Preview output without writing any files:

```bash
./wordlist-generator.sh -t Corp -l -y 2024 --dry-run -o /dev/null
```

---

## All options

### Input sources

At least one input source is required. Multiple sources can be combined and they are all merged into the same base word pool.

-t / --target sets a target or company name and adds it directly to the base word pool.

-b / --base-file reads words from a file, one word per line.

-w / --word adds a single word to the base pool. This flag is repeatable.

--stdin reads base words from standard input, one per line.

### Mutation options

-y / --years takes a comma-separated list of numeric years such as 2021,2022,2023. Each year is appended and prepended to every base word variant.

-l / --leet enables leet substitutions. For each word variant the script produces single and double character swaps using the map a→@ o→0 e→3 i→1 s→$. Full combinatorial leet is intentionally not done to avoid generating millions of low-value entries. Requires bash 4+.

-m / --months appends all twelve month names (January through December) to each base word, with and without separators.

--seasons appends Spring, Summer, Autumn, and Winter to each base word.

--case controls which case variants are produced. Accepts a comma-separated list of lower, upper, capitalize, and toggle. Default is lower,upper,capitalize. Toggle produces alternating case like aCmE.

-s / --separators sets the separator characters tried when combining words. Passed as a comma-separated list. Default is a single comma, meaning no separator and comma are both tried.

--digits sets the digit range or list to append to each variant. Accepts a range like 0-9 or 00-99 (zero-padded) or a comma-separated list like 1,2,3. Default is 0-9.

--special sets the special characters to append to each variant. Passed as a string where each character is tried individually. Default is !@#.

--no-common disables the built-in common password pattern combinations. By default the script combines each base word with: admin, welcome, password, changeme, security, letmein, company, and login.

### Output and limits

-o / --output sets the output file path. This is the only required flag.

--max-words sets the maximum number of entries to generate before aborting. Default is 500000. The count is tracked incrementally so the script stops as soon as the limit is hit rather than generating everything and then trimming.

--max-size sets the maximum output size in megabytes. Checked periodically during generation and again on the final deduplicated output. Default is 100.

--compress gzip-compresses the output file after writing. The output path gets a .gz suffix appended.

--force allows overwriting an existing output file. Without this flag the script will abort if the output path already exists.

--dry-run prints the first 50 generated lines and a raw line count without writing anything to disk. Useful for estimating output size before committing.

-v / --verbose enables progress messages during generation.

-h / --help prints the help text and exits.

---

## How mutations are generated

For each base word the script first produces all requested case variants. Then for each case variant it generates leet substitutions (if enabled), appends and prepends each year, appends each digit in the configured range, and appends each special character. All of this goes through a central safe_write function that tracks the running line count and checks the file size every 1000 writes.

After the per-word mutations, if common patterns are enabled the script combines each base word with a fixed list of common password suffixes using whatever separators are configured. Month and season combinations follow the same logic.

Once all mutations are written to a temporary file, the script runs sort -u to deduplicate and writes the result atomically using a .tmp file and mv. If the deduplicated file exceeds the size limit, it is removed and the script exits with an error.

Temporary files are created under a mktemp directory and are always cleaned up on exit, interrupt, or error via a trap on EXIT INT TERM.

---

## Output size estimation

The number of entries grows quickly with multiple mutations enabled. A rough guide for a single base word with default settings:

With just case mutations and digits 0-9: around 40 entries.
Add years 2020-2024: around 140 entries.
Add leet: around 300-600 entries depending on character composition.
Add months: adds 36 entries per separator per base word.
Add common patterns: adds 8 entries per separator per base word.

Use --dry-run first on any configuration you have not run before.

---

## Examples

Minimal run with a single target:

```bash
./wordlist-generator.sh -t acme -o acme.txt
```

Full mutation set with compression:

```bash
./wordlist-generator.sh \
    -t acme \
    -y 2022,2023,2024 \
    -l \
    --months \
    --seasons \
    --case lower,upper,capitalize,toggle \
    --special '!@#$' \
    --digits 0-99 \
    --compress \
    --force \
    -o acme-full.txt
```

Combine a target with a custom word file and stdin:

```bash
echo "acmecorp" | ./wordlist-generator.sh \
    -t acme \
    -b extra-words.txt \
    --stdin \
    -y 2023,2024 \
    -o combined.txt
```

Increase limits for a large engagement:

```bash
./wordlist-generator.sh \
    -t targetcorp \
    -y 2019,2020,2021,2022,2023,2024 \
    -l --months --seasons \
    --max-words 2000000 \
    --max-size 500 \
    -o large.txt
```

Disable common patterns for a clean minimal list:

```bash
./wordlist-generator.sh -t acme --no-common -o acme-minimal.txt
```

---

## Differences between v3.0 and v3.1

v3.0 had several bugs that v3.1 fixes.

The special character loop in v3.0 used read -r -n1 inside a here-string which behaved unpredictably across bash versions and would silently drop characters. v3.1 replaces this with a dedicated append_special_chars function that walks the string by character index using substring syntax.

The common patterns, months, and seasons blocks in v3.0 wrote directly to the raw file with >> bypassing safe_write entirely. This meant those lines were never counted against MAX_WORDS or checked against MAX_OUTPUT_MB during generation. v3.1 routes all writes through safe_write via the combine_words function.

The boolean flag MONTHS and the local array MONTHS_LIST in v3.0 shared a scope which was fragile and confusing. v3.1 renames the boolean flags to DO_MONTHS and DO_SEASONS to make the intent unambiguous.

The -c short option in v3.0 was assigned to --case but --case requires an argument and the short option string had no colon after c, so -c would silently not work. v3.1 removes the short form for --case entirely and maps -s to --separators instead.

Years were never validated in v3.0. Passing a non-numeric value like --years abc,2024 would silently produce garbage output. v3.1 validates all year values with validate_years and exits with a clear error if any are non-numeric.

The getopt failure path in v3.0 called show_help which exits 0, masking the error from calling scripts. v3.1 prints a short error and exits 1.

show_stats in v3.0 used local end_time=$(date +%s) without declaring variables first, which in strict mode could mask a subshell exit code. v3.1 declares all locals at the top of the function.

A bash version check was added before the leet path since declare -A requires bash 4+. On bash 3 (default on macOS) the script will now exit with a clear error instead of silently failing.

---

## Legal notice

This tool is for use in authorized penetration testing engagements, CTF competitions, and personal security research only. Do not use it to attack systems you do not own or do not have explicit written permission to test.
