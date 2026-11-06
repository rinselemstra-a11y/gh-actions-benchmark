#!/bin/bash
# bench.sh - hardware-benchmark zonder Python, voor macOS en Linux.
# Zelfde tests en zelfde JSON-structuur als bench.py, zodat
#   python3 bench.py --compare result-a.json result-b.json
# ook met deze resultaten werkt.
#
# Gebruik:  ./bench.sh [label] [workdir] ["eigen commando"]
#   label    naam in de uitvoer (standaard: hostnaam)
#   workdir  map voor de disk-tests (standaard: huidige map)
#   commando optioneel eigen commando om te timen, bv. "mvn -q package"
#
# Let op: de cpu-test is een bash-loop en is alleen vergelijkbaar met andere
# bench.sh-resultaten, niet met bench.py of bench.ps1.

LABEL=${1:-$(hostname | cut -d. -f1)}
WORKDIR=${2:-.}
CMD=$3

now() { perl -MTime::HiRes=time -e 'printf "%.4f", time'; }
dur() { perl -e "printf '%.4f', $2 - $1"; }
div() { perl -e "printf '%.2f', $1 / $2"; }

# ---------------------------------------------------------------- systeeminfo
OS="$(uname -s) $(uname -r)"
ARCH=$(uname -m)
if [ "$(uname -s)" = "Darwin" ]; then
  CPU=$(sysctl -n machdep.cpu.brand_string 2>/dev/null)
  CORES=$(sysctl -n hw.ncpu)
  RAM=$(div "$(sysctl -n hw.memsize)" 1073741824)
else
  CPU=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | sed 's/^ *//')
  CORES=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN)
  RAM=$(div "$(grep MemTotal /proc/meminfo | awk '{print $2}')" 1048576)
fi
GHA=false; [ "$GITHUB_ACTIONS" = "true" ] && GHA=true

echo "Benchmark '$LABEL' gestart in $WORKDIR ..."

# --------------------------------------------------------------------- tests
cpu_work() {
  local i s=0
  for ((i = 0; i < 600000; i++)); do
    s=$(( (s + i * i) % 1000003 ))
  done
}

echo "  cpu single-thread ..."
t0=$(now); cpu_work; t1=$(now)
CPU_SINGLE=$(dur "$t0" "$t1")

echo "  cpu multi-thread ..."
t0=$(now)
for ((w = 0; w < CORES; w++)); do cpu_work & done
wait
t1=$(now)
CPU_MULTI=$(dur "$t0" "$t1")
SPEEDUP=$(perl -e "printf '%.2f', $CPU_SINGLE * $CORES / $CPU_MULTI")

echo "  geheugen ..."
t0=$(now); dd if=/dev/zero of=/dev/null bs=1048576 count=2048 2>/dev/null; t1=$(now)
MEM=$(div 2048 "$(dur "$t0" "$t1")")

echo "  disk sequentieel ..."
SEQ="$WORKDIR/bench_seq.bin"
t0=$(now); dd if=/dev/zero of="$SEQ" bs=1048576 count=512 2>/dev/null; sync; t1=$(now)
DISK_W=$(div 512 "$(dur "$t0" "$t1")")
t0=$(now); dd if="$SEQ" of=/dev/null bs=1048576 2>/dev/null; t1=$(now)
DISK_R=$(div 512 "$(dur "$t0" "$t1")")
rm -f "$SEQ"

echo "  disk kleine bestanden ..."
SMALL="$WORKDIR/bench_small"
mkdir -p "$SMALL"
PAYLOAD=$(head -c 4096 /dev/zero | tr '\0' x)
t0=$(now)
for ((i = 0; i < 3000; i++)); do printf '%s' "$PAYLOAD" > "$SMALL/f$i.txt"; done
for ((i = 0; i < 3000; i++)); do read -r _ < "$SMALL/f$i.txt"; done
rm -rf "$SMALL"
t1=$(now)
SMALL_S=$(dur "$t0" "$t1")
SMALL_OPS=$(div 3000 "$SMALL_S")

CMD_JSON="null"
CMD_LINE=""
if [ -n "$CMD" ]; then
  echo "  commando: $CMD ..."
  t0=$(now); bash -c "$CMD"; rc=$?; t1=$(now)
  CMD_S=$(dur "$t0" "$t1")
  CMD_JSON="$CMD_S, \"cmd_rc\": $rc"
  CMD_LINE=$(printf '%-28s%14s  %s (exit %s)\n' "eigen commando" "$CMD_S s" "$CMD" "$rc")
fi

# ------------------------------------------------------------------ uitvoer
echo
echo "=== $LABEL ==="
echo "$OS ($ARCH)  |  $CPU  |  $CORES cores  |  RAM $RAM GB"
echo
printf '%-28s%14s  %s\n' "test" "waarde" "toelichting"
printf -- '-%.0s' $(seq 1 72); echo
printf '%-28s%14s  %s\n' "cpu single-thread"          "$CPU_SINGLE s" "lager is beter (bash-loop)"
printf '%-28s%14s  %s\n' "cpu multi-thread"           "$CPU_MULTI s"  "$CORES processen, speedup ${SPEEDUP}x"
printf '%-28s%14s  %s\n' "geheugen (dd zero->null)"   "$MEM MB/s"     "hoger is beter"
printf '%-28s%14s  %s\n' "disk sequentieel schrijven" "$DISK_W MB/s"  "512 MB, met sync"
printf '%-28s%14s  %s\n' "disk sequentieel lezen"     "$DISK_R MB/s"  "(kan uit cache komen)"
printf '%-28s%14s  %s\n' "disk kleine bestanden"      "$SMALL_S s"    "3000x schrijven+lezen, $SMALL_OPS/s"
[ -n "$CMD_LINE" ] && echo "$CMD_LINE"
echo

OUT="result-$LABEL.json"
cat > "$OUT" <<EOF
{
  "label": "$LABEL",
  "timestamp": "$(date '+%Y-%m-%d %H:%M:%S')",
  "tool": "bench.sh",
  "system": {
    "hostname": "$(hostname)",
    "os": "$OS",
    "arch": "$ARCH",
    "cpu": "$CPU",
    "cores": $CORES,
    "ram_gb": $RAM,
    "github_actions": $GHA,
    "runner": "$RUNNER_OS $ImageOS"
  },
  "cmd": $( [ -n "$CMD" ] && printf '"%s"' "$CMD" || echo null ),
  "metrics": {
    "cpu_single_s": $CPU_SINGLE,
    "cpu_multi_s": $CPU_MULTI,
    "cpu_multi_workers": $CORES,
    "cpu_multi_speedup": $SPEEDUP,
    "mem_mb_s": $MEM,
    "disk_write_mb_s": $DISK_W,
    "disk_read_mb_s": $DISK_R,
    "small_files_s": $SMALL_S,
    "small_files_ops_s": $SMALL_OPS,
    "cmd_s": $CMD_JSON
  }
}
EOF
echo "Opgeslagen: $OUT"
