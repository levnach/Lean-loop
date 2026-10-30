"""Process watchdog for the loop: one runaway solver must not take the machine down.

2026-10-27: four `lean` processes at 24 to 41 GB each froze WindowServer.
2026-10-30: eleven `z3` processes left behind by an agent's sweep script (its `subprocess.run`
timeouts killed the Python children, not their `z3`) reached 220 GB on this 48 GB machine;
watchdogd starved and the kernel panicked 25 minutes after loop.sh had exited.

Watched processes are `lean` (except editor language servers) and every binary under LOOP_DIR
(the loop's z3 and test-z3 builds, wherever they were started from). Every POLL seconds a watched
process is killed when its parent has exited (it is an orphan: nobody waits for its result), when
it is above its memory or age limit, and the largest ones go while all of them together exceed the
total limit. The watchdog runs in its own session, one instance per LOOP_DIR, and stays up while
a loop script runs or a watched process remains, so it outlives loop.sh and its background report
refresh. Kills are logged in STATE_DIR/watchdog.log and logs/loop.log.

usage: watchdog.py --loop-dir D --state-dir D --lean-mem-mb N --lean-time-min N
                   --bin-mem-mb N --bin-time-min N --total-mem-mb N --poll-sec N
"""
import argparse
import ctypes
import ctypes.util
import fcntl
import os
import re
import signal
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

# Scripts whose presence keeps the watchdog up. A background subshell of loop.sh keeps its argv.
OWNER = re.compile(r"^(\S*/)?bash (\S*/)?(loop|report_pr|regen_report|run_until_cpp)\.sh( |$)")
LANGUAGE_SERVER = re.compile(r" --(server|worker)( |$)")


@dataclass
class Proc:
    pid: int
    ppid: int
    rss_kb: int
    etime: str
    args: str
    exe: str = ""

    @property
    def seconds(self):
        days, _, clock = self.etime.rpartition("-")
        total = 0
        for part in clock.split(":"):
            total = total * 60 + int(part)
        return total + int(days or 0) * 86400

    @property
    def rss_mb(self):
        return self.rss_kb // 1024


@dataclass
class Limits:
    lean_mem_mb: int
    lean_time_min: int
    bin_mem_mb: int
    bin_time_min: int
    total_mem_mb: int


def kind(proc, loop_dir):
    """'lean', the binary name for a loop-built binary, or None for a process we leave alone."""
    if proc.exe.startswith(loop_dir.rstrip("/") + "/"):
        return os.path.basename(proc.exe)
    argv0 = proc.args.split(" ", 1)[0]
    if os.path.basename(argv0) == "lean" and not LANGUAGE_SERVER.search(proc.args):
        return "lean"
    return None


def scan(procs, limits, loop_dir):
    """Returns (proc, name, reason) for every watched process to kill."""
    kills, kept = [], []
    for proc in procs:
        name = kind(proc, loop_dir)
        if name is None:
            continue
        mem_mb, time_min = ((limits.lean_mem_mb, limits.lean_time_min) if name == "lean"
                            else (limits.bin_mem_mb, limits.bin_time_min))
        if proc.ppid == 1:
            kills.append((proc, name, "orphan"))
        elif proc.rss_mb > mem_mb:
            kills.append((proc, name, "memory"))
        elif proc.seconds > time_min * 60:
            kills.append((proc, name, "time"))
        else:
            kept.append((proc, name))
    total_kb = sum(proc.rss_kb for proc, _ in kept)
    for proc, name in sorted(kept, key=lambda entry: -entry[0].rss_kb):
        if total_kb <= limits.total_mem_mb * 1024:
            break
        kills.append((proc, name, "total"))
        total_kb -= proc.rss_kb
    return kills


_libproc = None


def exe_path(pid):
    global _libproc
    if _libproc is None:
        _libproc = ctypes.CDLL(ctypes.util.find_library("proc") or "libproc.dylib")
    buf = ctypes.create_string_buffer(4096)
    n = _libproc.proc_pidpath(pid, buf, len(buf))
    return buf.value.decode(errors="replace") if n > 0 else ""


def processes():
    out = subprocess.run(["ps", "-axo", "pid=,ppid=,rss=,etime=,args="], capture_output=True, text=True).stdout
    procs = []
    for line in out.splitlines():
        fields = line.split(None, 4)
        if len(fields) < 5:
            continue
        procs.append(Proc(int(fields[0]), int(fields[1]), int(fields[2]), fields[3], fields[4]))
    for proc in procs:
        proc.exe = exe_path(proc.pid)
    return procs


class Watchdog:
    def __init__(self, opts):
        self.loop_dir = opts.loop_dir
        self.state_dir = Path(opts.state_dir)
        self.limits = Limits(opts.lean_mem_mb, opts.lean_time_min, opts.bin_mem_mb, opts.bin_time_min,
                             opts.total_mem_mb)
        self.poll = opts.poll_sec

    def log(self, line):
        stamp = time.strftime("%Y-%m-%d %H:%M:%S")
        with open(Path(self.loop_dir) / "logs" / "loop.log", "a", encoding="utf-8") as fh:
            fh.write("[%s] %s\n" % (stamp, line))

    def kill(self, kills):
        for proc, name, why in kills:
            try:
                os.kill(proc.pid, signal.SIGTERM)
            except ProcessLookupError:
                continue
            self.log("watchdog: killed %s pid %d (%s; rss %d MB, elapsed %s)"
                     % (name, proc.pid, "parent exited" if why == "orphan" else why + " limit", proc.rss_mb,
                        proc.etime))
            with open(self.state_dir / "watchdog.log", "a", encoding="utf-8") as fh:
                fh.write("%s pid %d %s %s rss %d MB elapsed %s\n"
                         % (time.strftime("%Y-%m-%d %H:%M:%S"), proc.pid, name, why, proc.rss_mb, proc.etime))
        if kills:
            time.sleep(5)
            for proc, _, _ in kills:
                try:
                    os.kill(proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass

    def run(self):
        me = os.getpid()
        lim = self.limits
        self.log("watchdog started (pid %d): lean %d MB / %d min, loop binaries %d MB / %d min, %d MB in total, "
                 "orphans killed" % (me, lim.lean_mem_mb, lim.lean_time_min, lim.bin_mem_mb, lim.bin_time_min,
                                     lim.total_mem_mb))
        while True:
            procs = processes()
            kills = scan(procs, self.limits, self.loop_dir)
            self.kill(kills)
            killed = {proc.pid for proc, _, _ in kills}
            owners = any(OWNER.search(proc.args) for proc in procs if proc.pid != me)
            watched = any(kind(proc, self.loop_dir) for proc in procs if proc.pid not in killed)
            if not owners and not watched:
                self.log("watchdog (pid %d): no loop script or watched process left; exiting" % me)
                return
            time.sleep(self.poll)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--loop-dir", required=True)
    parser.add_argument("--state-dir", required=True)
    for flag in ("--lean-mem-mb", "--lean-time-min", "--bin-mem-mb", "--bin-time-min", "--total-mem-mb",
                 "--poll-sec"):
        parser.add_argument(flag, type=int, required=True)
    opts = parser.parse_args()
    # One instance per LOOP_DIR: a second start (the next loop.sh run) finds the lock taken and exits.
    lock = open(Path(opts.state_dir) / "watchdog.lock", "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return 0
    lock.write("%d\n" % os.getpid())
    lock.flush()
    # Outlive the loop scripts and a Ctrl-C in their terminal.
    try:
        os.setsid()
    except OSError:
        pass
    signal.signal(signal.SIGHUP, signal.SIG_IGN)
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    Watchdog(opts).run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
