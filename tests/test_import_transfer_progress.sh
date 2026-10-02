#!/bin/bash
# What the operator sees during a long transfer: progress lines that an
# 80 column terminal never wraps, the whole of an earlier complete scan
# when the count of this pass runs out of time, a time left that rests on
# what is measured or says it is unknown, and how busy the disks of the
# old server are. Synthetic rsync and ssh, no network.
# Put a different awk on PATH to run the same checks with Debian mawk.
# Arguments name the tests to run, all of them otherwise.
# shellcheck disable=SC2034,SC2329,SC2030,SC2031
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/kvs-transfer-progress.XXXXXX")
# stop_tree <pid>...: TERM to processes and to everything they started:
# the pipelines and the samplers of a test stop with it.
stop_tree() {
    local pid
    local -a children
    for pid in "$@"; do
        mapfile -t children < <(pgrep -P "$pid" 2>/dev/null || true)
        kill "$pid" 2>/dev/null || true
        [ "${#children[@]}" -eq 0 ] || stop_tree "${children[@]}"
    done
}
# The tests running side by side stop with the one that failed.
pids=()
trap 'stop_tree "${pids[@]}"; rm -rf "$TEST_DIR"' EXIT
# shellcheck source=/dev/null
source "$ROOT_DIR/docker/lib/import.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
# has <file> <pattern> <message>: the file holds a line matching the
# pattern, or the test fails with the message and the file.
has() { grep -q -- "$2" "$1" || fail "$3: $(cat -v "$1")"; }

# screen <columns> [before-summary]: what a terminal that wide shows once
# the output on stdin is drawn. Lines wrap at the last column (the cursor
# waits there until the next character), a newline also returns the
# carriage as the terminal driver does, and the cursor moves up and erases
# as told. before-summary stops where the final summary starts.
cat > "$TEST_DIR/screen.py" <<'PY'
import re
import sys

width = int(sys.argv[1])
data = sys.stdin.read()
if len(sys.argv) > 2:
    end = data.rfind("  Transferred")
    if end >= 0:
        start = data.rfind("\r\x1b[", 0, end)
        data = data[:start if start >= 0 else end]
rows = [[]]
row = col = 0
pending = False
escape = re.compile(r"\x1b\[([0-9]*)([AJK])")
i = 0
while i < len(data):
    match = escape.match(data, i)
    if match:
        count = int(match.group(1) or "1")
        if match.group(2) == "A":
            row = max(0, row - count)
            pending = False
        elif match.group(2) == "K":
            del rows[row][col:]
        else:
            del rows[row][col:]
            del rows[row + 1:]
        i = match.end()
        continue
    char = data[i]
    i += 1
    if char == "\r":
        col = 0
        pending = False
    elif char == "\n":
        row += 1
        col = 0
        pending = False
    elif char == "\x1b":
        sys.exit("unknown escape sequence: %r" % data[i - 1:i + 6])
    else:
        if pending:
            row += 1
            col = 0
            pending = False
        while len(rows) <= row:
            rows.append([])
        line = rows[row]
        while len(line) < col:
            line.append(" ")
        if col < len(line):
            line[col] = char
        else:
            line.append(char)
        if col == width - 1:
            pending = True
        else:
            col += 1
    while len(rows) <= row:
        rows.append([])
print("\n".join("".join(r).rstrip() for r in rows).strip("\n"))
PY
screen() { python3 "$TEST_DIR/screen.py" "$@"; }

# last_block <file>: the last block of lines a terminal rendering drew
# before its summary, without the control sequences. The file is read
# with its carriage returns, which Python would otherwise make newlines.
last_block() {
    python3 -c '
import re
import sys
data = re.sub(r"\r|\x1b\[[0-9]*A", "", open(sys.argv[1], newline="").read())
blocks = [chunk for chunk in data.split("\x1b[J")[:-1] if chunk]
print(blocks[-1].replace("\x1b[K", "") if blocks else "")
' "$1"
}

# left_seconds <file>: the last time left a rendering shows, in seconds,
# whatever its wording around "H:MM:SS left".
left_seconds() {
    tr '\r' '\n' < "$1" | sed 's/\x1b\[[0-9]*[AJK]//g' |
        sed -n 's/.* \([0-9][0-9]*\):\([0-9][0-9]\):\([0-9][0-9]\) left.*/\1 \2 \3/p' |
        tail -n 1 | awk '{ print $1 * 3600 + $2 * 60 + $3 }'
}

# widest <file>: the longest line of a rendering, terminal or log, in
# characters, control sequences aside.
widest() {
    tr '\r' '\n' < "$1" | sed 's/\x1b\[[0-9]*[AJK]//g' | awk '{ if (length($0) > n) n = length($0) } END { print n + 0 }'
}

# big_site_records: the records of a site of millions of files whose count
# did not finish, one a second.
big_site_records() {
    local i
    for ((i = 1; i <= 3; i++)); do
        printf ' %d 0%% 3.10MB/s 5:10:2%d (xfr#%d, ir-chk=1500/%d)\r' $((64424509440 + i * 1048576)) "$i" $((5000000 + i)) $((5400000 + i))
        sleep 1.1
    done
}

# The second line of the old display took more than 80 columns there.
# Each redraw went up one line where the terminal had wrapped two, and
# left a stale line behind it, a screen filling with old figures.
test_the_progress_never_wraps_an_80_column_terminal() {
    big_site_records | import_rsync_progress 0 0 yes > "$TEST_DIR/wrap.raw"
    screen 80 before-summary < "$TEST_DIR/wrap.raw" > "$TEST_DIR/wrap.during"
    screen 80 < "$TEST_DIR/wrap.raw" > "$TEST_DIR/wrap.after"
    [ "$(grep -c '5,000,00' "$TEST_DIR/wrap.during")" -eq 1 ] ||
        fail "the terminal must show one progress block, not stale ones: $(cat "$TEST_DIR/wrap.during")"
    [ "$(grep -c '5,000,00' "$TEST_DIR/wrap.after")" -eq 1 ] ||
        fail "the summary must replace the progress block: $(cat "$TEST_DIR/wrap.after")"
    [ "$(grep -c elapsed "$TEST_DIR/wrap.after")" -eq 0 ] ||
        fail "the summary must leave nothing of the progress: $(cat "$TEST_DIR/wrap.after")"
    echo 'PASS: the progress never wraps an 80 column terminal'
}

# The largest figures a transfer can show: ten TB, a billion files and
# entries at 150,000 a second, many disks with long names; and a billion
# files at one a second, a time left of thirty years. Every line, on a
# terminal and in a log, holds within 79 columns.
wide_records() {
    local i
    for ((i = 0; i <= 6; i++)); do
        printf ' %d 0%% 999.99MB/s 999:59:59 (xfr#%d, ir-chk=1/%d)\r' \
            $((10995116277760 - (6 - i) * 1048471142)) $((999999999 - (6 - i) * 150000)) $((999999999 - (6 - i) * 150000))
        [ "$i" -eq 6 ] || sleep 1
    done
}
slow_records() {
    local i
    for ((i = 0; i <= 6; i++)); do
        printf ' %d 0%% 1.00kB/s 0:00:0%d (xfr#%d, ir-chk=1/%d)\r' "$i" "$i" "$i" $((i + 2))
        [ "$i" -eq 6 ] || sleep 1
    done
}
test_every_line_holds_within_79_columns() {
    local i now mode
    local -a pids=()
    now=$(date +%s)
    {
        printf '%s 120 nvme10n1 100' "$now"
        for ((i = 11; i <= 22; i++)); do printf ' nvme%sn1 99' "$i"; done
        printf '\n'
    } > "$TEST_DIR/wide.disks"
    for mode in yes no; do
        wide_records | IMPORT_PROGRESS_ENTRIES=999999999 IMPORT_PROGRESS_COUNTED=2026-09-28 IMPORT_PROGRESS_DISKS="$TEST_DIR/wide.disks" \
            import_rsync_progress 10995116277760 999999999 "$mode" > "$TEST_DIR/wide.$mode" &
        pids+=("$!")
        slow_records | import_rsync_progress 0 999999999 "$mode" > "$TEST_DIR/slow.$mode" &
        pids+=("$!")
    done
    for i in "${pids[@]}"; do wait "$i"; done
    for mode in yes no; do
        [ "$(widest "$TEST_DIR/wide.$mode")" -le 79 ] || fail "a line is wider than 79 columns ($mode): $(cat -v "$TEST_DIR/wide.$mode")"
        [ "$(widest "$TEST_DIR/slow.$mode")" -le 79 ] || fail "a line is wider than 79 columns ($mode): $(cat -v "$TEST_DIR/slow.$mode")"
    done
    last_block "$TEST_DIR/wide.yes" > "$TEST_DIR/wide.block"
    has "$TEST_DIR/wide.block" '^  Copied:  10240.00 GB of 10240.00 GB (100%), 999,999,999 of 999,999,999 files$' "the largest copy"
    has "$TEST_DIR/wide.block" '^  Checked: 999,999,998 of about 999,999,999 entries (99%), count of 2026-09-28$' "the largest check"
    # The rates depend on where the records fall in the seconds.
    has "$TEST_DIR/wide.block" '^  Rates:   [0-9.]* MB/s, 1[0-9][0-9],[0-9]* files/s copied, 1[0-9][0-9],[0-9]* entries/s checked$' "the largest rates"
    has "$TEST_DIR/wide.block" '^  Disks:   old server busy nvme10n1 100%, nvme11n1 99%, 11 more (last 120 s)$' "the most disks"
    last_block "$TEST_DIR/slow.yes" > "$TEST_DIR/slow.block"
    has "$TEST_DIR/slow.block" '^  Time:    0:00:0[6-9] elapsed, over 10,000 hours left (pace so far)$' \
        "a time left of years must say so in a few words"
    echo 'PASS: every line holds within 79 columns, on a terminal and in a log'
}

# A repeat of a large site copies few files and checks all the others:
# the old time left followed the bytes and the files alone and showed two
# seconds while six thousand entries were still to check at a hundred a
# second.
test_the_time_left_counts_the_entries_still_to_check() {
    local i left
    {
        printf ' 0 0%% 0.00kB/s 0:00:00 (xfr#0, to-chk=6000/6000)\r'
        for ((i = 1; i <= 7; i++)); do
            sleep 1
            files=$((i < 3 ? i : 3))
            printf ' %d 0%% 1.00kB/s 0:00:0%d (xfr#%d, to-chk=%d/6000)\r' $((files * 1000)) "$i" "$files" $((6000 - i * 100))
        done
    } | import_rsync_progress 4000 4 yes > "$TEST_DIR/entries.raw"
    left=$(left_seconds "$TEST_DIR/entries.raw")
    [ -n "$left" ] && [ "$left" -ge 35 ] && [ "$left" -le 90 ] ||
        fail "the time left must follow the 5,300 entries still to check at about 100 a second, not the last file: ${left:-none}: $(last_block "$TEST_DIR/entries.raw")"
    last_block "$TEST_DIR/entries.raw" | grep -q '^  Checked: 700 of 6,000 entries (11%)$' ||
        fail "the entries checked must show against the whole the scan found: $(last_block "$TEST_DIR/entries.raw")"
    echo 'PASS: the time left counts the entries still to check'
}

# The count of this pass ran out of time; an earlier pass counted the
# site. The entries checked are measured against it, said to be an
# estimate with its date, and the time left follows them.
test_an_earlier_count_measures_the_progress() {
    local i left
    for ((i = 0; i <= 6; i++)); do
        printf ' %d 0%% 1.00MB/s 0:00:0%d (xfr#%d, ir-chk=10/%d)\r' $((i * 1048576)) "$i" $((i * 90)) $((i * 100 + 110))
        [ "$i" -eq 6 ] || sleep 1
    done | IMPORT_PROGRESS_ENTRIES=2100 IMPORT_PROGRESS_COUNTED=2026-09-28 import_rsync_progress 0 0 yes > "$TEST_DIR/earlier.raw"
    last_block "$TEST_DIR/earlier.raw" > "$TEST_DIR/earlier.block"
    has "$TEST_DIR/earlier.block" '^  Copied:  6.0 MB, 540 files$' "the copy alone, without a total"
    has "$TEST_DIR/earlier.block" '^  Checked: 700 of about 2,100 entries (33%), count of 2026-09-28$' \
        "the earlier count must measure the checks, dated"
    has "$TEST_DIR/earlier.block" '^  Time:    0:00:0[6-9] elapsed, about 0:00:[0-9][0-9] left (pace so far)$' \
        "the entries left must give a time left"
    left=$(left_seconds "$TEST_DIR/earlier.raw")
    [ "$left" -ge 10 ] && [ "$left" -le 30 ] || fail "1,400 entries left at about 100 a second must take about 14 s, not $left"
    echo 'PASS: an earlier count measures the progress of a pass whose count ran out of time'
}

# Nothing tells what is left: the count ran out of time and no earlier
# pass counted the site. Once the scan of this pass is done, its own
# figure is the whole.
test_nothing_known_means_left_unknown() {
    local out
    printf ' 1000 0%% 1.00kB/s 0:00:01 (xfr#1, ir-chk=10/100)\n' | import_rsync_progress 0 0 no > "$TEST_DIR/unknown.out"
    has "$TEST_DIR/unknown.out" '^  Checked: 90 of 100 entries found so far, scan running$' "the scan counts what it found"
    has "$TEST_DIR/unknown.out" '^  Time:    0:00:0[0-9] elapsed, left unknown: no complete count of this site yet$' \
        "without any count the time left must be unknown"
    printf ' 1000 0%% 1.00kB/s 0:00:01 (xfr#1, to-chk=10/100)\n' | import_rsync_progress 0 0 no > "$TEST_DIR/unknown.out"
    has "$TEST_DIR/unknown.out" '^  Checked: 90 of 100 entries (90%)$' "a scan that is done is the whole"
    # Known, but not before five seconds of pace.
    has "$TEST_DIR/unknown.out" '^  Time:    0:00:0[0-9] elapsed, time left unknown yet$' "a scan that is done tells what is left"
    echo 'PASS: without any count what is left is unknown'
}

# An earlier count smaller than what this scan already found is out of
# date: set aside, not shown as a percentage past the whole.
test_a_grown_site_sets_the_earlier_count_aside() {
    printf ' 1000 0%% 1.00kB/s 0:00:01 (xfr#1, ir-chk=10/1500)\n' |
        IMPORT_PROGRESS_ENTRIES=1000 IMPORT_PROGRESS_COUNTED=2026-09-28 import_rsync_progress 0 0 no > "$TEST_DIR/grown.out"
    has "$TEST_DIR/grown.out" '^  Checked: 1,490 of 1,500 entries found so far, scan running$' "an outgrown count is no whole"
    has "$TEST_DIR/grown.out" '^  Time:    0:00:0[0-9] elapsed, left unknown, the site grew since 2026-09-28$' \
        "an earlier count the scan outgrew must be set aside"
    echo 'PASS: an earlier count the site outgrew is set aside'
}

# The rate changes with the region of the site. The time left follows the
# pace of the last window (two seconds here, five minutes by default),
# not the average since the start.
test_the_time_left_follows_the_recent_pace() {
    local i checked=0 left
    for ((i = 0; i <= 7; i++)); do
        if [ "$i" -le 3 ]; then checked=$((i * 1000)); else checked=$((checked + 100)); fi
        printf ' 0 0%% 0.00kB/s 0:00:0%d (xfr#0, ir-chk=0/%d)\r' "$i" "$checked"
        [ "$i" -eq 7 ] || sleep 1
    done | IMPORT_PROGRESS_PACE=2 IMPORT_PROGRESS_ENTRIES=20000 IMPORT_PROGRESS_COUNTED=2026-09-28 \
        import_rsync_progress 0 0 yes > "$TEST_DIR/pace.raw"
    left=$(left_seconds "$TEST_DIR/pace.raw")
    # 16,600 entries left: 166 s at the last 100 a second, 35 s at the
    # average since the start.
    [ "$left" -ge 110 ] && [ "$left" -le 250 ] || fail "the time left must follow the last pace, got $left s: $(last_block "$TEST_DIR/pace.raw")"
    last_block "$TEST_DIR/pace.raw" | grep -q 'left (pace of the last 2 s)$' || fail "the window must be named: $(last_block "$TEST_DIR/pace.raw")"
    echo 'PASS: the time left follows the recent pace'
}

# repeat_records <copied bytes a second> <seconds copying> <seconds
# checking>: a repeat of 2,000 entries, 40,000 bytes in 20 files to
# copy. It copies, two files a second, for the first seconds, and checks
# 100 entries a second for the seconds given; the records go on, eight in
# all, a second apart.
repeat_records() {
    local i copied=0 files=0 checked=0
    for ((i = 0; i <= 7; i++)); do
        printf ' %d 0%% 1.00kB/s 0:00:0%d (xfr#%d, ir-chk=%d/2000)\r' "$copied" "$i" "$files" $((2000 - checked))
        if [ "$i" -lt "$2" ]; then copied=$((copied + $1)); files=$((files + 2)); fi
        [ "$i" -ge "$3" ] || checked=$((checked + 100))
        [ "$i" -eq 7 ] || sleep 1
    done
}

# A repeat copies where the walk meets a changed file and checks entries
# in between. A figure that stopped while another moves keeps its average
# since the start, instead of leaving the time left unknown while the
# walk goes on. One that never moved leaves a floor; a window where
# nothing moved, no figure.
test_a_figure_at_rest_keeps_its_average() {
    local pid name left
    local -a pids=()
    for name in bursts untouched stopped; do
        case "$name" in
            bursts) repeat_records 2000 2 8 ;;
            untouched) repeat_records 0 0 8 ;;
            stopped) repeat_records 2000 2 3 ;;
        esac | IMPORT_PROGRESS_PACE=2 IMPORT_PROGRESS_ENTRIES=2000 IMPORT_PROGRESS_COUNTED=2026-09-28 \
            import_rsync_progress 40000 20 yes > "$TEST_DIR/rest.$name" &
        pids+=("$!")
    done
    for pid in "${pids[@]}"; do wait "$pid"; done
    # 36,000 bytes left at the 4,000 of the first two seconds over about
    # seven: about 63 s, where the 1,300 entries left take 13 s.
    left=$(left_seconds "$TEST_DIR/rest.bursts")
    [ -n "$left" ] && [ "$left" -ge 50 ] && [ "$left" -le 90 ] ||
        fail "bytes at rest while the walk goes on must keep their average: ${left:-none}: $(last_block "$TEST_DIR/rest.bursts")"
    last_block "$TEST_DIR/rest.bursts" > "$TEST_DIR/rest.block"
    has "$TEST_DIR/rest.block" '^  Time:    0:00:0[6-9] elapsed, about 0:01:[0-9][0-9] left (pace of the last 2 s)$' "an estimate"
    last_block "$TEST_DIR/rest.untouched" > "$TEST_DIR/rest.block"
    has "$TEST_DIR/rest.block" '^  Time:    0:00:0[6-9] elapsed, at least 0:00:[1-3][0-9] left (pace of the last 2 s)$' \
        "bytes that never moved leave the time of the checks as a floor"
    last_block "$TEST_DIR/rest.stopped" > "$TEST_DIR/rest.block"
    has "$TEST_DIR/rest.block" '^  Time:    0:00:0[6-9] elapsed, time left unknown: no progress in the last 2 s$' \
        "nothing moved in the window, no time left"
    echo 'PASS: a figure at rest keeps its average, one that never moved gives a floor'
}

# A terminal narrower than the lines: each is cut to its width, so the
# redraw still finds them where it left them.
test_a_narrow_terminal_cuts_the_lines() {
    big_site_records | IMPORT_PROGRESS_COLUMNS=50 import_rsync_progress 0 0 yes > "$TEST_DIR/narrow.raw"
    screen 50 before-summary < "$TEST_DIR/narrow.raw" > "$TEST_DIR/narrow.during"
    [ "$(grep -c '5,000,00' "$TEST_DIR/narrow.during")" -eq 1 ] ||
        fail "a narrow terminal must show one progress block: $(cat "$TEST_DIR/narrow.during")"
    [ "$(widest "$TEST_DIR/narrow.during")" -le 49 ] ||
        fail "a narrow terminal must get its lines cut: $(cat "$TEST_DIR/narrow.during")"
    echo 'PASS: a narrow terminal gets its lines cut to its width'
}

# The reading of import_disk_sampler, as the progress shows it.
test_the_disk_line() {
    local now out
    now=$(date +%s)
    disk_out() {
        printf ' 1000 0%% 1.00kB/s 0:00:01 (xfr#1)\n' | IMPORT_PROGRESS_DISKS="$TEST_DIR/disks" import_rsync_progress 0 0 no | grep '^  Disks:' || true
    }
    printf '%s 30 sda 98 sdb 97\n' "$now" > "$TEST_DIR/disks"
    [ "$(disk_out)" = '  Disks:   old server busy sda 98%, sdb 97% (last 30 s)' ] || fail "two disks: $(disk_out)"
    printf '%s 0 unknown nodisk\n' "$now" > "$TEST_DIR/disks"
    [ "$(disk_out)" = '  Disks:   the old server lists no whole disk in /proc/diskstats' ] || fail "no disk: $(disk_out)"
    printf '%s 0 unknown noanswer\n' "$now" > "$TEST_DIR/disks"
    [ "$(disk_out)" = '  Disks:   the old server gave no reading over SSH' ] || fail "no answer: $(disk_out)"
    printf '%s 30 sda 98 sdb 97\n' "$((now - 600))" > "$TEST_DIR/disks"
    [[ "$(disk_out)" == '  Disks:   no reading from the old server for 0:10:0'[0-9] ]] || fail "a stale reading: $(disk_out)"
    rm -f "$TEST_DIR/disks"
    [ -z "$(disk_out)" ] || fail "no reading yet, no line: $(disk_out)"
    printf 'garbage\n' > "$TEST_DIR/disks"
    [ -z "$(disk_out)" ] || fail "a reading that is not one, no line: $(disk_out)"
    echo 'PASS: the disks of the old server show as the sampler read them'
}

# The --stats block of the final rsync is for the caller: off the screen,
# whole in its file; everything else rsync prints passes through.
test_the_stats_block_stays_off_the_screen() {
    local out
    out=$(printf ' 100 100%% 1.00kB/s 0:00:01 (xfr#1, to-chk=0/3)\nrsync: something to say\n\nNumber of files: 3 (reg: 2, dir: 1)\nNumber of regular files transferred: 1\nTotal file size: 200 bytes\nTotal transferred file size: 100 bytes\nLiteral data: 100 bytes\nMatched data: 0 bytes\nFile list size: 0\n\nsent 10 bytes  received 100 bytes  220.00 bytes/sec\ntotal size is 200  speedup is 1.82\n' |
        IMPORT_PROGRESS_STATS="$TEST_DIR/stats" import_rsync_progress 0 0 no)
    grep -q '^rsync: something to say$' <<< "$out" || fail "what rsync says passes through: $out"
    if grep -Eq 'Number of|Total|sent |total size' <<< "$out"; then fail "the --stats block must stay off the screen: $out"; fi
    [ "$(import_rsync_stats_totals < "$TEST_DIR/stats")" = $'1\t100\t2\t200\t3' ] || fail "the --stats block must be kept whole: $(cat "$TEST_DIR/stats")"
    out=$(printf 'Number of files: 3 (reg: 2, dir: 1)\n' | import_rsync_progress 0 0 no)
    grep -q '^Number of files: 3' <<< "$out" || fail "without a file for it, the block passes through: $out"
    echo 'PASS: the --stats block stays off the screen'
}

# A complete count is kept with its date and its source; it stands for a
# later pass of the same source and exclusions only.
test_counts_serve_the_same_source_only() {
    local loaded
    IMPORT_MARKER_DIR="$TEST_DIR/markers"
    mkdir -p "$IMPORT_MARKER_DIR"
    import_mark_destination "$TEST_DIR/www/example.test" ssh://root@old.test:22/srv/site
    import_count_save "$TEST_DIR/www/example.test" scope-a 1250 1000 5000000
    [ -f "$IMPORT_MARKER_DIR/example.test.count" ] || fail "the count must be kept next to the source marker"
    loaded=$(import_count_load "$TEST_DIR/www/example.test" scope-a) || fail "the count of the same source must load"
    [[ "$loaded" =~ ^1250\ 1000\ 5000000\ [0-9]+$ ]] || fail "entries, files, bytes and date: $loaded"
    [ "$(( $(date +%s) - ${loaded##* } ))" -lt 60 ] || fail "the date is the moment of the count: $loaded"
    if import_count_load "$TEST_DIR/www/example.test" scope-b > /dev/null; then fail "other exclusions, another site"; fi
    import_mark_destination "$TEST_DIR/www/example.test" ssh://root@other.test:22/srv/site
    if import_count_load "$TEST_DIR/www/example.test" scope-a > /dev/null; then fail "another source, another site"; fi
    import_mark_destination "$TEST_DIR/www/example.test" ssh://root@old.test:22/srv/site
    sed -i 's/^entries=.*/entries=many/' "$IMPORT_MARKER_DIR/example.test.count"
    if import_count_load "$TEST_DIR/www/example.test" scope-a > /dev/null; then fail "a damaged count is no count"; fi
    rm "$IMPORT_MARKER_DIR/example.test.count"
    import_count_save "$TEST_DIR/www/example.test" scope-a 0 0 0
    [ ! -e "$IMPORT_MARKER_DIR/example.test.count" ] || fail "a count of nothing is not kept"
    [ "$(import_count_scope /tmp/\* /backup)" = "$(import_count_scope /tmp/\* /backup)" ] &&
        [ "$(import_count_scope /tmp/\* /backup)" != "$(import_count_scope /tmp/\*)" ] || fail "the scope follows the exclusions"
    (
        unset IMPORT_MARKER_DIR
        import_count_save "$TEST_DIR/www/other.test" scope-a 10 8 100
        [ ! -e "$TEST_DIR/www/other.test.count" ] && [ ! -e "$TEST_DIR/www/other.test/.kvs-import-source.count" ] || exit 1
        if import_count_load "$TEST_DIR/www/other.test" scope-a > /dev/null; then exit 1; fi
    ) || fail "without IMPORT_MARKER_DIR no count is kept: the mirror would delete it"
    unset IMPORT_MARKER_DIR
    echo 'PASS: a count serves later passes of the same source and exclusions only'
}

# The whole chain in import_remote_files: a pass whose count finishes
# keeps it, and so does a final rsync that went through the site (its
# --stats); a later pass whose count runs out of time measures against it
# and says so; another source, or other exclusions, get "unknown".
test_a_timed_out_count_measures_against_the_earlier_one() {
    local bin="$TEST_DIR/count-bin" destination="$TEST_DIR/count-www/example.test" out
    mkdir -p "$bin" "$TEST_DIR/count-logs" "$TEST_DIR/count-markers"
    cat > "$bin/rsync" <<'RSYNC'
#!/bin/bash
for arg in "$@"; do
    if [ "$arg" = --dry-run ]; then
        [ -z "${FIXTURE_COUNT_SLEEP:-}" ] || sleep "$FIXTURE_COUNT_SLEEP"
        printf 'Number of files: 1,250 (reg: 1,000, dir: 250)\nNumber of regular files transferred: 400\n'
        printf 'Total file size: 5,000,000 bytes\nTotal transferred file size: 2,000,000 bytes\n'
        exit 0
    fi
done
printf ' 0 0%% 0.00kB/s 0:00:00 (xfr#0, ir-chk=100/300)\r'
printf ' 2000000 100%% 1.00MB/s 0:00:02 (xfr#400, to-chk=0/1300)\n'
if [[ " $* " == *" --stats "* ]] && [ -z "${FIXTURE_NO_STATS:-}" ]; then
    printf '\nNumber of files: 1,300 (reg: 1,040, dir: 260)\nNumber of created files: 400\n'
    printf 'Number of regular files transferred: 400\nTotal file size: 5,200,000 bytes\n'
    printf 'Total transferred file size: 2,000,000 bytes\n\nsent 1 bytes  received 2 bytes  3.00 bytes/sec\n'
    printf 'total size is 5,200,000  speedup is 2.60\n'
fi
RSYNC
    chmod +x "$bin/rsync"
    (
        PATH="$bin:$PATH"
        IMPORT_TRANSFER_JOBS=1 IMPORT_REMOTE_SUDO=no IMPORT_SIZE_TIMEOUT=1 IMPORT_TRANSFER_RETRIES=0
        IMPORT_SSH_TARGET=root@old.test IMPORT_TRANSFER_LOG_DIR="$TEST_DIR/count-logs"
        IMPORT_MARKER_DIR="$TEST_DIR/count-markers"
        import_ssh_rsh() { printf unused; }
        import_mark_destination "$destination" ssh://root@old.test:22/srv/site
        # A count that finishes is kept; without --stats from the final
        # rsync, it is what stays.
        FIXTURE_NO_STATS=1 import_remote_files /srv/site "$destination" yes > "$TEST_DIR/count.out" 2>&1 ||
            fail "a transfer with a count failed: $(cat "$TEST_DIR/count.out")"
        grep -q '^entries=1250$' "$TEST_DIR/count-markers/example.test.count" &&
            grep -q '^files=1000$' "$TEST_DIR/count-markers/example.test.count" &&
            grep -q '^bytes=5000000$' "$TEST_DIR/count-markers/example.test.count" ||
            fail "the count must be kept: $(cat "$TEST_DIR/count-markers/example.test.count" 2>&1)"
        grep -q '^  Checked: 200 of 1,250 entries (16%)$' "$TEST_DIR/count.out" ||
            fail "a pass with its own count measures against it, no estimate: $(cat "$TEST_DIR/count.out")"
        # The final rsync went through the site: its own figures, fresher.
        import_remote_files /srv/site "$destination" yes > "$TEST_DIR/count.out" 2>&1 ||
            fail "a transfer with a count failed: $(cat "$TEST_DIR/count.out")"
        grep -q '^entries=1300$' "$TEST_DIR/count-markers/example.test.count" ||
            fail "the --stats of the final rsync must be kept: $(cat "$TEST_DIR/count-markers/example.test.count")"
        if grep -q 'Number of files' "$TEST_DIR/count.out"; then fail "the --stats block must stay off the screen: $(cat "$TEST_DIR/count.out")"; fi
        # The count of the next pass runs out of time.
        FIXTURE_COUNT_SLEEP=3 import_remote_files /srv/site "$destination" yes > "$TEST_DIR/count.out" 2>&1 ||
            fail "a transfer whose count ran out of time failed: $(cat "$TEST_DIR/count.out")"
        grep -q "^  The count did not finish in time (IMPORT_SIZE_TIMEOUT=1, 0 for no limit): the progress measures against the count of $(date +%Y-%m-%d) instead, an estimate (the site then held 1,300 entries, 1,040 files, 4 MB)$" "$TEST_DIR/count.out" &&
            grep -q "^  Checked: 200 of about 1,300 entries (15%), count of $(date +%Y-%m-%d)$" "$TEST_DIR/count.out" ||
            fail "the earlier count must stand in, dated: $(cat "$TEST_DIR/count.out")"
        # Other exclusions, another site.
        FIXTURE_COUNT_SLEEP=3 import_remote_files /srv/site "$destination" yes /backup > "$TEST_DIR/count.out" 2>&1 ||
            fail "a transfer whose count ran out of time failed: $(cat "$TEST_DIR/count.out")"
        grep -q '^  The count did not finish in time (IMPORT_SIZE_TIMEOUT=1, 0 for no limit) and no earlier pass from this source finished one: the transfer shows its counts without a whole, and what is left stays unknown$' "$TEST_DIR/count.out" &&
            grep -q '^  Time:    0:00:0[0-9] elapsed, left unknown: no complete count of this site yet$' "$TEST_DIR/count.out" ||
            fail "a count of other exclusions must not stand in: $(cat "$TEST_DIR/count.out")"
        # Another source, another site.
        import_mark_destination "$destination" ssh://root@new.test:22/srv/site
        FIXTURE_COUNT_SLEEP=3 FIXTURE_NO_STATS=1 import_remote_files /srv/site "$destination" yes > "$TEST_DIR/count.out" 2>&1 ||
            fail "a transfer whose count ran out of time failed: $(cat "$TEST_DIR/count.out")"
        grep -q 'left unknown: no complete count of this site yet' "$TEST_DIR/count.out" ||
            fail "a count of another source must not stand in: $(cat "$TEST_DIR/count.out")"
    ) || exit 1
    echo 'PASS: a count that ran out of time is replaced by the earlier one of the same source, dated'
}

# rsync -H: the site counts every name of a hard-linked file, the copy
# transfers it once, and the entries count every name on both sides: the
# kept count and the checks of the transfer agree.
test_hard_links_count_every_name_as_an_entry() {
    local bin="$TEST_DIR/links-bin" site="$TEST_DIR/links-site" destination="$TEST_DIR/links-www/example.test"
    mkdir -p "$bin" "$site/sub" "$TEST_DIR/links-logs" "$TEST_DIR/links-markers"
    cat > "$bin/ssh" <<'SSH'
#!/bin/bash
# Runs the remote command here: options and the target go.
while [ $# -gt 0 ]; do
    case "$1" in
        -o|-p|-i|-S|-l) shift 2 ;;
        -*) shift ;;
        *) break ;;
    esac
done
shift
exec bash -c "$*"
SSH
    chmod +x "$bin/ssh"
    echo one > "$site/a"
    echo two > "$site/b"
    echo three > "$site/sub/c"
    ln "$site/a" "$site/y"
    ln "$site/a" "$site/sub/x"
    (
        PATH="$bin:$PATH"
        IMPORT_TRANSFER_JOBS=1 IMPORT_REMOTE_SUDO=no IMPORT_TRANSFER_RETRIES=0
        IMPORT_SSH_TARGET=root@old.test IMPORT_SSH_OPTS=() IMPORT_SSH_COMMAND=(ssh)
        IMPORT_TRANSFER_LOG_DIR="$TEST_DIR/links-logs" IMPORT_MARKER_DIR="$TEST_DIR/links-markers"
        import_mark_destination "$destination" "ssh://root@old.test:22$site"
        import_remote_files "$site" "$destination" yes > "$TEST_DIR/links.out" 2>&1 || fail "the copy failed: $(cat "$TEST_DIR/links.out")"
        grep -q "^  To transfer:     3 files, 0 kB of the site's 5 files, 0 kB$" "$TEST_DIR/links.out" ||
            fail "three files to copy of the five names of the site: $(cat "$TEST_DIR/links.out")"
        grep -q '^entries=7$' "$TEST_DIR/links-markers/example.test.count" && grep -q '^files=5$' "$TEST_DIR/links-markers/example.test.count" ||
            fail "the kept count holds every name: $(cat "$TEST_DIR/links-markers/example.test.count")"
        grep -q '^  Transferred 3 files, ' "$TEST_DIR/links.out" && grep -q '; 7 entries checked$' "$TEST_DIR/links.out" ||
            fail "the copy transfers each linked file once and checks every name: $(cat "$TEST_DIR/links.out")"
        [ "$(stat -c %i "$destination/a")" = "$(stat -c %i "$destination/sub/x")" ] || fail "the links must stay links"
    ) || exit 1
    echo 'PASS: hard links count every name as an entry on both sides'
}

# Two readings of the old server: the busy share of each whole disk over
# the time between them on its own clock.
test_disk_busy_from_two_readings() {
    local out
    cat > "$TEST_DIR/reading1" <<'EOF'
100.00 1500.00
   8       0 sda 1 0 8 1 1 0 8 1 0 1000 2
   8       1 sda1 1 0 8 1 1 0 8 1 0 900 2
   8      16 sdb 1 0 8 1 1 0 8 1 0 500 2 0 0 0 0
   9       0 md0 1 0 8 0 1 0 8 0 0 0 0
 253       0 dm-0 1 0 8 1 1 0 8 1 0 700 2
   7       0 loop0 1 0 8 1 1 0 8 1 0 50 2
disk sda
disk sdb
EOF
    cat > "$TEST_DIR/reading2" <<'EOF'
130.00 1560.00
   8       0 sda 9 0 80 9 9 0 80 9 1 25000 30
   8       1 sda1 9 0 80 9 9 0 80 9 1 24900 30
   8      16 sdb 9 0 80 9 9 0 80 9 0 15500 30 0 0 0 0
   9       0 md0 9 0 80 0 9 0 80 0 0 0 0
 253       0 dm-0 9 0 80 9 9 0 80 9 0 29000 30
   7       0 loop0 9 0 80 9 9 0 80 9 0 50 2
disk sda
disk sdb
EOF
    out=$(import_disk_busy "$TEST_DIR/reading1" "$TEST_DIR/reading2")
    [ "$out" = '30 sda 80 sdb 50' ] || fail "whole disks only, the busiest first: '$out'"
    # Without /sys, the usual names of whole disks.
    grep -v '^disk ' "$TEST_DIR/reading1" > "$TEST_DIR/reading1.nosys"
    grep -v '^disk ' "$TEST_DIR/reading2" > "$TEST_DIR/reading2.nosys"
    out=$(import_disk_busy "$TEST_DIR/reading1.nosys" "$TEST_DIR/reading2.nosys")
    [ "$out" = '30 sda 80 sdb 50' ] || fail "the usual names of whole disks without /sys: '$out'"
    # A counter that went back is dropped, more than the time is 100%.
    sed 's/ 15500 30 / 100 30 /; s/ 25000 30$/ 99000 30/' "$TEST_DIR/reading2" > "$TEST_DIR/reading2.odd"
    out=$(import_disk_busy "$TEST_DIR/reading1" "$TEST_DIR/reading2.odd")
    [ "$out" = '30 sda 100' ] || fail "a counter gone back is dropped, the share capped: '$out'"
    # md and device-mapper only, as some virtual servers list.
    printf '100.00 1.00\n9 0 md0 1 0 8 0 1 0 8 0 0 0 0\ndisk md0x\n' > "$TEST_DIR/reading1.md"
    printf '130.00 1.00\n9 0 md0 1 0 8 0 1 0 8 0 0 0 0\ndisk md0x\n' > "$TEST_DIR/reading2.md"
    out=$(import_disk_busy "$TEST_DIR/reading1.md" "$TEST_DIR/reading2.md")
    [ "$out" = '30 nodisk' ] || fail "no whole disk: '$out'"
    # A reading without the clock of the old server says nothing.
    sed 1d "$TEST_DIR/reading2" > "$TEST_DIR/reading2.noclock"
    [ -z "$(import_disk_busy "$TEST_DIR/reading1" "$TEST_DIR/reading2.noclock")" ] || fail "no clock, no figure"
    [ -z "$(import_disk_busy "$TEST_DIR/reading2" "$TEST_DIR/reading1")" ] || fail "a clock that went back, no figure"
    echo 'PASS: the busy share of each whole disk comes from two readings'
}

# make_reading_ssh <bin>: an ssh that answers the readings of the old
# server from FIXTURE_READINGS (1, 2, 3, then the last one again),
# records its arguments in FIXTURE_SSH_LOG, hangs with FIXTURE_SSH_HANG
# and fails with FIXTURE_SSH_FAIL. Anything else is run here.
make_reading_ssh() {
    mkdir -p "$1"
    cat > "$1/ssh" <<'SSH'
#!/bin/bash
printf '%s\n' "$*" >> "$FIXTURE_SSH_LOG"
case "$*" in
    *"/proc/diskstats"*)
        if [ -n "${FIXTURE_SSH_HANG:-}" ]; then echo "$$" > "$FIXTURE_SSH_HANG"; exec sleep 60; fi
        [ -z "${FIXTURE_SSH_FAIL:-}" ] || exit 255
        n=$(($(cat "$FIXTURE_READINGS/counter" 2>/dev/null || echo 0) + 1))
        echo "$n" > "$FIXTURE_READINGS/counter"
        [ -f "$FIXTURE_READINGS/$n" ] || n=last
        exec cat "$FIXTURE_READINGS/$n"
        ;;
esac
while [ $# -gt 0 ]; do
    case "$1" in
        -o|-p|-i|-S|-l) shift 2 ;;
        -*) shift ;;
        *) break ;;
    esac
done
shift
exec bash -c "$*"
SSH
    cat > "$1/sshpass" <<'SSHPASS'
#!/bin/bash
[ "$1" != -e ] || shift
exec "$@"
SSHPASS
    chmod +x "$1/ssh" "$1/sshpass"
    mkdir -p "$FIXTURE_READINGS"
    printf '100.00 1.00\n8 0 sda 1 0 8 1 1 0 8 1 0 1000 2\n8 16 sdb 1 0 8 1 1 0 8 1 0 500 2\ndisk sda\ndisk sdb\n' > "$FIXTURE_READINGS/1"
    printf '130.00 1.00\n8 0 sda 1 0 8 1 1 0 8 1 0 25000 2\n8 16 sdb 1 0 8 1 1 0 8 1 0 15500 2\ndisk sda\ndisk sdb\n' > "$FIXTURE_READINGS/2"
    printf '160.00 1.00\n8 0 sda 1 0 8 1 1 0 8 1 0 55000 2\n8 16 sdb 1 0 8 1 1 0 8 1 0 15500 2\ndisk sda\ndisk sdb\n' > "$FIXTURE_READINGS/last"
}

# wait_for <seconds> <command...>: true once the command is, false after.
wait_for() {
    local end=$((SECONDS + $1))
    shift
    until "$@"; do
        [ "$SECONDS" -lt "$end" ] || return 1
        sleep 0.1
    done
}

# ends_within <seconds> <pid>: true when a child of this shell has ended
# within that time (a watchdog kills it otherwise).
ends_within() {
    local start=$SECONDS watchdog
    (sleep "$(($1 + 2))"; kill -KILL "$2" 2>/dev/null) > /dev/null 2>&1 &
    watchdog=$!
    wait "$2" 2>/dev/null || true
    stop_tree "$watchdog"
    wait "$watchdog" 2>/dev/null || true
    [ $((SECONDS - start)) -le "$1" ]
}

# stops_within <seconds> <pid>: TERM to a child of this shell, true when
# it has ended within that time.
stops_within() {
    kill "$2"
    ends_within "$@"
}

# The sampler reads the old server through the SSH connection, never with
# a prompt, writes what it found, keeps the last reading when one does not
# come, and stops at once on TERM, its SSH command and its pause with it;
# with an owner, it stops by itself once the owner is gone.
test_the_sampler_reads_the_disks_and_stops() {
    local bin="$TEST_DIR/sampler-bin" pid="" hung owner=""
    export FIXTURE_READINGS="$TEST_DIR/sampler-readings" FIXTURE_SSH_LOG="$TEST_DIR/sampler-ssh.log"
    make_reading_ssh "$bin"
    (
        # A check that fails leaves no sampler reading on.
        trap 'stop_tree "$pid" "$owner"' EXIT
        PATH="$bin:$PATH"
        IMPORT_SSH_TARGET=root@old.test IMPORT_SSH_COMMAND=(ssh) IMPORT_SSH_OPTS=(-o ControlPath=/nonexistent/ssh-%C -p 22)
        import_disk_sampler "$TEST_DIR/sampler.disks" 1 &
        pid=$!
        wait_for 10 grep -q ' 30 sda 100 sdb 0$' "$TEST_DIR/sampler.disks" 2>/dev/null ||
            fail "the sampler must write the busy share of the disks: $(cat "$TEST_DIR/sampler.disks" 2>&1)"
        [[ "$(cat "$TEST_DIR/sampler.disks")" =~ ^[0-9]+\ 30\ sda\ 100\ sdb\ 0$ ]] || fail "epoch, seconds, disks: $(cat "$TEST_DIR/sampler.disks")"
        grep -q '^-o BatchMode=yes -o ControlPath=/nonexistent/ssh-%C -p 22 root@old.test cat /proc/uptime /proc/diskstats; ' "$FIXTURE_SSH_LOG" ||
            fail "the reading must never prompt and use the connection options: $(head -n 1 "$FIXTURE_SSH_LOG")"
        stops_within 2 "$pid" || fail "the sampler must stop on TERM"
        [ ! -e "$TEST_DIR/sampler.disks.previous" ] && [ ! -e "$TEST_DIR/sampler.disks.reading" ] ||
            fail "the sampler must take its readings with it"
        calls=$(wc -l < "$FIXTURE_SSH_LOG")
        sleep 1.5
        [ "$(wc -l < "$FIXTURE_SSH_LOG")" -eq "$calls" ] || fail "a stopped sampler must read no more"
        # A reading that does not come: unknown, until one does.
        rm -f "$TEST_DIR/sampler.disks"
        FIXTURE_SSH_FAIL=1 import_disk_sampler "$TEST_DIR/sampler.disks" 1 &
        pid=$!
        wait_for 5 test -s "$TEST_DIR/sampler.disks" || fail "a failed reading must be told"
        [[ "$(cat "$TEST_DIR/sampler.disks")" =~ ^[0-9]+\ 0\ unknown\ noanswer$ ]] || fail "no answer: $(cat "$TEST_DIR/sampler.disks")"
        stops_within 2 "$pid" || fail "the sampler must stop on TERM"
        # A hung reading ends with the sampler.
        FIXTURE_SSH_HANG="$TEST_DIR/sampler.hung" import_disk_sampler "$TEST_DIR/sampler.disks" 1 &
        pid=$!
        wait_for 5 test -s "$TEST_DIR/sampler.hung" || fail "the hung reading never started"
        hung=$(cat "$TEST_DIR/sampler.hung")
        stops_within 2 "$pid" || fail "TERM must end the sampler at once, its reading hung"
        wait_for 3 eval '! kill -0 '"$hung"' 2>/dev/null' || fail "TERM must end the hung SSH command of the sampler"
        # With the password of sshpass a lost master may be opened again.
        : > "$FIXTURE_SSH_LOG"
        IMPORT_SSH_COMMAND=(sshpass -e ssh)
        import_disk_sampler "$TEST_DIR/sampler.disks" 1 &
        pid=$!
        wait_for 5 test -s "$FIXTURE_SSH_LOG" || fail "the sampler did not read through sshpass"
        stops_within 2 "$pid" || fail "the sampler must stop on TERM"
        if grep -q BatchMode "$FIXTURE_SSH_LOG"; then fail "sshpass answers the password: no batch mode"; fi
        # Its owner killed outright, the sampler stops by itself.
        IMPORT_SSH_COMMAND=(ssh)
        sleep 60 &
        owner=$!
        : > "$FIXTURE_SSH_LOG"
        import_disk_sampler "$TEST_DIR/sampler.disks" 1 "$owner" &
        pid=$!
        wait_for 5 test -s "$FIXTURE_SSH_LOG" || fail "the sampler of an owner did not read"
        kill -KILL "$owner"
        wait "$owner" 2>/dev/null || true
        ends_within 3 "$pid" || fail "the sampler must stop once its owner is gone"
        [ ! -e "$TEST_DIR/sampler.disks.previous" ] || fail "the sampler of a gone owner must take its readings with it"
    ) || exit 1
    echo 'PASS: the sampler reads the disks without a prompt and stops at once, or with its owner'
}

# A transfer killed outright cannot stop its sampler with its trap: the
# sampler sees that the shell of the transfer is gone and reads no more.
test_a_killed_transfer_stops_reading_the_disks() {
    local bin="$TEST_DIR/killed-bin" job="" owner="" rsync_pid="" calls
    export FIXTURE_READINGS="$TEST_DIR/killed-readings" FIXTURE_SSH_LOG="$TEST_DIR/killed-ssh.log"
    export FIXTURE_RSYNC_PIDS="$TEST_DIR/killed-rsync.pids"
    make_reading_ssh "$bin"
    cat > "$bin/rsync" <<'RSYNC'
#!/bin/bash
for arg in "$@"; do
    if [ "$arg" = --dry-run ]; then
        printf 'Number of files: 3 (reg: 2, dir: 1)\nNumber of regular files transferred: 2\nTotal file size: 2048 bytes\nTotal transferred file size: 2048 bytes\n'
        exit 0
    fi
done
# The final rsync: its parent is the shell of import_remote_files.
echo "$PPID $$" > "$FIXTURE_RSYNC_PIDS"
exec sleep 60
RSYNC
    chmod +x "$bin/rsync"
    (
        trap 'stop_tree "$job" "$rsync_pid"' EXIT
        PATH="$bin:$PATH"
        IMPORT_TRANSFER_JOBS=1 IMPORT_REMOTE_SUDO=no IMPORT_TRANSFER_RETRIES=0 IMPORT_DISKSTATS_INTERVAL=1
        IMPORT_SSH_TARGET=root@old.test IMPORT_SSH_COMMAND=(ssh) IMPORT_SSH_OPTS=(-p 22)
        IMPORT_TRANSFER_LOG_DIR="$TEST_DIR/killed-logs"
        mkdir -p "$IMPORT_TRANSFER_LOG_DIR" "$TEST_DIR/killed-tmp"
        import_ssh_rsh() { printf unused; }
        TMPDIR="$TEST_DIR/killed-tmp" import_remote_files /srv/site "$TEST_DIR/killed-dest" yes > "$TEST_DIR/killed.out" 2>&1 &
        job=$!
        wait_for 10 test -s "$FIXTURE_RSYNC_PIDS" || fail "the final rsync never started: $(cat "$TEST_DIR/killed.out")"
        read -r owner rsync_pid < "$FIXTURE_RSYNC_PIDS"
        wait_for 5 test -s "$FIXTURE_SSH_LOG" || fail "the sampler of the transfer did not read"
        kill -KILL "$owner"
        wait "$job" 2>/dev/null || true
        # A reading under way may still end; then none.
        sleep 2.5
        calls=$(wc -l < "$FIXTURE_SSH_LOG")
        sleep 2
        [ "$(wc -l < "$FIXTURE_SSH_LOG")" -eq "$calls" ] || fail "the sampler of a killed transfer must read no more"
    ) || exit 1
    echo 'PASS: a transfer killed outright leaves no sampler reading the old server'
}

# import_remote_files reads the disks during the transfer when asked to,
# shows them, and stops reading when it ends.
test_the_transfer_shows_the_disks() {
    local bin="$TEST_DIR/shown-bin" calls
    export FIXTURE_READINGS="$TEST_DIR/shown-readings" FIXTURE_SSH_LOG="$TEST_DIR/shown-ssh.log"
    make_reading_ssh "$bin"
    # The second reading, then the same again: one figure whenever the
    # progress looks.
    mv -f "$FIXTURE_READINGS/2" "$FIXTURE_READINGS/last"
    cat > "$bin/rsync" <<'RSYNC'
#!/bin/bash
for arg in "$@"; do
    if [ "$arg" = --dry-run ]; then
        printf 'Number of files: 3 (reg: 2, dir: 1)\nNumber of regular files transferred: 2\nTotal file size: 2048 bytes\nTotal transferred file size: 2048 bytes\n'
        exit 0
    fi
done
sleep 2.5
printf ' 1024 50%% 1.00kB/s 0:00:01 (xfr#1, ir-chk=1/3)\r'
sleep 0.5
printf ' 2048 100%% 1.00kB/s 0:00:02 (xfr#2, to-chk=0/3)\n'
RSYNC
    chmod +x "$bin/rsync"
    (
        PATH="$bin:$PATH"
        IMPORT_TRANSFER_JOBS=1 IMPORT_REMOTE_SUDO=no IMPORT_TRANSFER_RETRIES=0 IMPORT_DISKSTATS_INTERVAL=1
        IMPORT_SSH_TARGET=root@old.test IMPORT_SSH_COMMAND=(ssh) IMPORT_SSH_OPTS=(-p 22)
        IMPORT_TRANSFER_LOG_DIR="$TEST_DIR/shown-logs"
        mkdir -p "$IMPORT_TRANSFER_LOG_DIR"
        import_ssh_rsh() { printf unused; }
        import_remote_files /srv/site "$TEST_DIR/shown-dest" yes > "$TEST_DIR/shown.out" 2>&1 ||
            fail "the transfer failed: $(cat "$TEST_DIR/shown.out")"
        grep -q '^  Disks:   old server busy sda 80%, sdb 50% (last 30 s)$' "$TEST_DIR/shown.out" ||
            fail "the transfer must show the disks: $(cat "$TEST_DIR/shown.out")"
        calls=$(wc -l < "$FIXTURE_SSH_LOG")
        sleep 2.5
        [ "$(wc -l < "$FIXTURE_SSH_LOG")" -eq "$calls" ] || fail "the readings must stop with the transfer"
        # 0, the default, reads nothing.
        : > "$FIXTURE_SSH_LOG"
        IMPORT_DISKSTATS_INTERVAL=0 import_remote_files /srv/site "$TEST_DIR/shown-dest" yes > "$TEST_DIR/shown.out" 2>&1 ||
            fail "the transfer failed: $(cat "$TEST_DIR/shown.out")"
        [ ! -s "$FIXTURE_SSH_LOG" ] && ! grep -q 'Disks:' "$TEST_DIR/shown.out" || fail "no interval, no reading"
    ) || exit 1
    echo 'PASS: the transfer shows the disks of the old server and stops reading them at its end'
}

# setup.sh reads the disks every 30 s unless told otherwise, and refuses
# an interval it cannot use.
test_the_setup_validates_the_interval() {
    local status
    # shellcheck disable=SC2016  # The line of setup.sh, as it is written.
    grep -qxF 'IMPORT_DISKSTATS_INTERVAL="${IMPORT_DISKSTATS_INTERVAL:-30}"' "$ROOT_DIR/docker/setup.sh" ||
        fail "the setup must read the disks every 30 s by default"
    awk '$0 == "import_inspect_remote() {" { capture = 1 } capture { print } capture && /^}$/ { exit }' \
        "$ROOT_DIR/docker/setup.sh" > "$TEST_DIR/inspect.sh"
    for value in 301 -1 abc 1.5; do
        status=0
        (
            # shellcheck source=/dev/null
            source "$TEST_DIR/inspect.sh"
            IMPORT_TRANSFER_JOBS=4 IMPORT_DISKSTATS_INTERVAL=$value import_inspect_remote
        ) > "$TEST_DIR/inspect.out" 2>&1 || status=$?
        [ "$status" -ne 0 ] || fail "IMPORT_DISKSTATS_INTERVAL=$value must be refused"
        has "$TEST_DIR/inspect.out" 'IMPORT_DISKSTATS_INTERVAL must be an integer from 0 to 300' "IMPORT_DISKSTATS_INTERVAL=$value must be refused"
    done
    for value in 0 30 300; do
        (
            # shellcheck source=/dev/null
            source "$TEST_DIR/inspect.sh"
            IMPORT_TRANSFER_JOBS=4 IMPORT_DISKSTATS_INTERVAL=$value IMPORT_EXPORTER=/nonexistent RED='' NC='' import_inspect_remote
        ) > "$TEST_DIR/inspect.out" 2>&1 || true
        if grep -q 'IMPORT_DISKSTATS_INTERVAL' "$TEST_DIR/inspect.out"; then fail "IMPORT_DISKSTATS_INTERVAL=$value must be taken"; fi
    done
    echo 'PASS: the setup validates IMPORT_DISKSTATS_INTERVAL'
}

if [ "$#" -gt 0 ]; then
    for name in "$@"; do "$name"; done
    exit 0
fi
# The tests that take seconds of real time run side by side.
for name in test_the_progress_never_wraps_an_80_column_terminal test_every_line_holds_within_79_columns \
    test_the_time_left_counts_the_entries_still_to_check test_an_earlier_count_measures_the_progress \
    test_the_time_left_follows_the_recent_pace test_a_narrow_terminal_cuts_the_lines \
    test_a_timed_out_count_measures_against_the_earlier_one test_the_sampler_reads_the_disks_and_stops \
    test_the_transfer_shows_the_disks test_a_killed_transfer_stops_reading_the_disks test_a_figure_at_rest_keeps_its_average; do
    "$name" &
    pids+=("$!")
done
test_nothing_known_means_left_unknown
test_a_grown_site_sets_the_earlier_count_aside
test_the_disk_line
test_the_stats_block_stays_off_the_screen
test_counts_serve_the_same_source_only
test_hard_links_count_every_name_as_an_entry
test_disk_busy_from_two_readings
test_the_setup_validates_the_interval
for pid in "${pids[@]}"; do
    wait "$pid" || exit 1
done
echo 'All transfer progress tests passed.'
