#!/usr/bin/env python3
"""
bench.py - eenvoudige hardware-benchmark om GitHub Actions-runners te
vergelijken met eigen hardware. Werkt op Windows, macOS en Linux, alleen
Python 3.8+ standaardbibliotheek.

Gebruik:
  python bench.py                          # alle tests, label = hostnaam
  python bench.py --label mijn-macbook     # eigen label in de uitvoer
  python bench.py --cmd "mvn -q package"   # ook een eigen commando timen
  python bench.py --compare a.json b.json  # resultaten naast elkaar zetten

Resultaat wordt getoond en weggeschreven als result-<label>.json.
"""
import argparse
import ctypes
import json
import math
import os
import platform
import shutil
import socket
import subprocess
import sys
import time
from multiprocessing import Pool, cpu_count

# ---------------------------------------------------------------- systeeminfo


def total_ram_gb():
    try:
        if sys.platform == "win32":
            class MEMORYSTATUSEX(ctypes.Structure):
                _fields_ = [("dwLength", ctypes.c_ulong), ("dwMemoryLoad", ctypes.c_ulong),
                            ("ullTotalPhys", ctypes.c_ulonglong), ("ullAvailPhys", ctypes.c_ulonglong),
                            ("ullTotalPageFile", ctypes.c_ulonglong), ("ullAvailPageFile", ctypes.c_ulonglong),
                            ("ullTotalVirtual", ctypes.c_ulonglong), ("ullAvailVirtual", ctypes.c_ulonglong),
                            ("ullAvailExtendedVirtual", ctypes.c_ulonglong)]
            st = MEMORYSTATUSEX()
            st.dwLength = ctypes.sizeof(MEMORYSTATUSEX)
            ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(st))
            return round(st.ullTotalPhys / 2**30, 1)
        if sys.platform == "darwin":
            out = subprocess.check_output(["sysctl", "-n", "hw.memsize"], text=True)
            return round(int(out.strip()) / 2**30, 1)
        with open("/proc/meminfo") as f:
            for line in f:
                if line.startswith("MemTotal:"):
                    return round(int(line.split()[1]) * 1024 / 2**30, 1)
    except Exception:
        pass
    return None


def cpu_name():
    try:
        if sys.platform == "darwin":
            return subprocess.check_output(
                ["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip()
        if sys.platform == "win32":
            out = subprocess.check_output(
                ["powershell", "-NoProfile", "-Command",
                 "(Get-CimInstance Win32_Processor).Name"], text=True)
            return out.strip().splitlines()[0]
        with open("/proc/cpuinfo") as f:
            for line in f:
                if line.lower().startswith("model name"):
                    return line.split(":", 1)[1].strip()
    except Exception:
        pass
    return platform.processor() or "onbekend"


def sysinfo():
    return {
        "hostname": socket.gethostname(),
        "os": f"{platform.system()} {platform.release()}",
        "os_version": platform.version(),
        "arch": platform.machine(),
        "cpu": cpu_name(),
        "cores": cpu_count(),
        "ram_gb": total_ram_gb(),
        "python": platform.python_version(),
        "github_actions": os.environ.get("GITHUB_ACTIONS") == "true",
        "runner": (os.environ.get("RUNNER_OS", "") + " " + os.environ.get("ImageOS", "")).strip(),
    }

# --------------------------------------------------------------------- tests


def cpu_work(n=3_000_000):
    """Vaste hoeveelheid rekenwerk: zeef van Eratosthenes + wat floating point."""
    sieve = bytearray([1]) * (n + 1)
    sieve[0] = sieve[1] = 0
    for i in range(2, int(n ** 0.5) + 1):
        if sieve[i]:
            sieve[i * i::i] = bytearray(len(sieve[i * i::i]))
    primes = sum(sieve)
    acc = 0.0
    for i in range(1, 8_000_000):
        acc += math.sqrt(i) * math.sin(i)
    return primes, acc


def _worker(_):
    cpu_work()
    return 0


def test_cpu_single():
    t = time.perf_counter()
    cpu_work()
    return time.perf_counter() - t


def test_cpu_multi(single_time):
    workers = cpu_count()
    t = time.perf_counter()
    with Pool(workers) as p:
        p.map(_worker, range(workers))
    elapsed = time.perf_counter() - t
    return elapsed, workers, (single_time * workers) / elapsed


def test_memory(size_mb=512):
    data = bytearray(size_mb * 2**20)
    t = time.perf_counter()
    copy = bytes(data)          # 1 kopie = size_mb lezen + size_mb schrijven
    elapsed = time.perf_counter() - t
    del copy, data
    return (2 * size_mb) / elapsed


def test_disk_sequential(workdir, size_mb=512):
    path = os.path.join(workdir, "bench_seq.bin")
    chunk = os.urandom(2**20)
    t = time.perf_counter()
    with open(path, "wb") as f:
        for _ in range(size_mb):
            f.write(chunk)
        f.flush()
        os.fsync(f.fileno())
    write_s = time.perf_counter() - t
    t = time.perf_counter()
    with open(path, "rb") as f:
        while f.read(2**20):
            pass
    read_s = time.perf_counter() - t
    os.remove(path)
    return size_mb / write_s, size_mb / read_s


def test_disk_small_files(workdir, count=3000):
    """Veel kleine bestanden: lijkt op git checkout, npm install, Maven-target."""
    d = os.path.join(workdir, "bench_small")
    os.makedirs(d, exist_ok=True)
    payload = b"x" * 4096
    t = time.perf_counter()
    for i in range(count):
        with open(os.path.join(d, f"f{i}.txt"), "wb") as f:
            f.write(payload)
    for i in range(count):
        with open(os.path.join(d, f"f{i}.txt"), "rb") as f:
            f.read()
    shutil.rmtree(d)
    elapsed = time.perf_counter() - t
    return elapsed, count / elapsed


def test_command(cmd):
    t = time.perf_counter()
    rc = subprocess.call(cmd, shell=True)
    return time.perf_counter() - t, rc

# ------------------------------------------------------------------ uitvoer


def fmt(v, unit="", dec=2):
    return "-" if v is None else f"{v:,.{dec}f}{unit}"


def print_result(r):
    s = r["system"]
    m = r["metrics"]
    print()
    print(f"=== {r['label']} ===")
    print(f"{s['os']} ({s['arch']})  |  {s['cpu']}  |  {s['cores']} cores  |  RAM {fmt(s['ram_gb'], ' GB', 1)}")
    if s["github_actions"]:
        print(f"GitHub Actions runner: {s['runner']}")
    print()
    print(f"{'test':<28}{'waarde':>14}  toelichting")
    print("-" * 72)
    print(f"{'cpu single-thread':<28}{fmt(m['cpu_single_s'], ' s'):>14}  lager is beter")
    print(f"{'cpu multi-thread':<28}{fmt(m['cpu_multi_s'], ' s'):>14}  "
          f"{m['cpu_multi_workers']} processen, speedup {fmt(m['cpu_multi_speedup'], 'x', 1)}")
    print(f"{'geheugen (kopie)':<28}{fmt(m['mem_mb_s'], ' MB/s', 0):>14}  hoger is beter")
    print(f"{'disk sequentieel schrijven':<28}{fmt(m['disk_write_mb_s'], ' MB/s', 0):>14}  512 MB, met fsync")
    print(f"{'disk sequentieel lezen':<28}{fmt(m['disk_read_mb_s'], ' MB/s', 0):>14}  (kan uit cache komen)")
    print(f"{'disk kleine bestanden':<28}{fmt(m['small_files_s'], ' s'):>14}  "
          f"3000x schrijven+lezen, {fmt(m['small_files_ops_s'], '/s', 0)}")
    if m.get("cmd_s") is not None:
        print(f"{'eigen commando':<28}{fmt(m['cmd_s'], ' s'):>14}  {r['cmd']} (exit {m['cmd_rc']})")
    print()


def compare(files):
    results = []
    for f in files:
        with open(f, encoding="utf-8-sig") as fh:   # -sig: PowerShell 5.1 schrijft een BOM
            results.append(json.load(fh))
    rows = [
        ("cpu single-thread (s)", "cpu_single_s", True),
        ("cpu multi-thread (s)", "cpu_multi_s", True),
        ("geheugen (MB/s)", "mem_mb_s", False),
        ("disk schrijven (MB/s)", "disk_write_mb_s", False),
        ("disk lezen (MB/s)", "disk_read_mb_s", False),
        ("kleine bestanden (s)", "small_files_s", True),
        ("eigen commando (s)", "cmd_s", True),
    ]
    labels = [r["label"] for r in results]
    print()
    print(f"{'test':<26}" + "".join(f"{l[:19]:>21}" for l in labels))
    print("-" * (26 + 21 * len(labels)))
    for name, key, lower_better in rows:
        vals = [r["metrics"].get(key) for r in results]
        if all(v is None for v in vals):
            continue
        line = f"{name:<26}"
        for i, v in enumerate(vals):
            if v is None:
                line += f"{'-':>21}"
                continue
            cell = f"{v:,.2f}"
            if i > 0 and vals[0]:
                ratio = (vals[0] / v) if lower_better else (v / vals[0])
                cell += f" ({ratio:.2f}x)"
            line += f"{cell:>21}"
        print(line)
    print()
    print(f"Tussen haakjes: factor sneller dan '{labels[0]}' (>1 = sneller, <1 = trager).")
    print("Cores: " + ", ".join(f"{r['label']}={r['system']['cores']}" for r in results))
    print("CPU:   " + " | ".join(f"{r['label']}: {r['system']['cpu']}" for r in results))
    print()

# ---------------------------------------------------------------------- main


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--label", default=None, help="naam voor dit resultaat (standaard: hostnaam)")
    ap.add_argument("--cmd", default=None, help="eigen commando om te timen, bv. een build")
    ap.add_argument("--workdir", default=None, help="map voor disk-tests (standaard: huidige map)")
    ap.add_argument("--out", default=None, help="pad voor JSON-uitvoer")
    ap.add_argument("--compare", nargs="+", metavar="JSON", help="vergelijk resultaatbestanden")
    args = ap.parse_args()

    if args.compare:
        compare(args.compare)
        return

    label = args.label or socket.gethostname()
    workdir = args.workdir or os.getcwd()
    print(f"Benchmark '{label}' gestart in {workdir} ...", flush=True)

    m = {}
    print("  cpu single-thread ...", flush=True)
    m["cpu_single_s"] = test_cpu_single()
    print("  cpu multi-thread ...", flush=True)
    m["cpu_multi_s"], m["cpu_multi_workers"], m["cpu_multi_speedup"] = test_cpu_multi(m["cpu_single_s"])
    print("  geheugen ...", flush=True)
    m["mem_mb_s"] = test_memory()
    print("  disk sequentieel ...", flush=True)
    m["disk_write_mb_s"], m["disk_read_mb_s"] = test_disk_sequential(workdir)
    print("  disk kleine bestanden ...", flush=True)
    m["small_files_s"], m["small_files_ops_s"] = test_disk_small_files(workdir)
    if args.cmd:
        print(f"  commando: {args.cmd} ...", flush=True)
        m["cmd_s"], m["cmd_rc"] = test_command(args.cmd)

    result = {
        "label": label,
        "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
        "system": sysinfo(),
        "cmd": args.cmd,
        "metrics": m,
    }
    print_result(result)

    out = args.out or f"result-{label}.json"
    with open(out, "w", encoding="utf-8") as f:
        json.dump(result, f, indent=2)
    print(f"Opgeslagen: {out}")


if __name__ == "__main__":
    main()
