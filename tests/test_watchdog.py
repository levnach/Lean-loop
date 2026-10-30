import unittest

from tools.watchdog import OWNER, Limits, Proc, scan

LOOP = "/Users/me/lean-loop"
LIMITS = Limits(lean_mem_mb=12288, lean_time_min=30, bin_mem_mb=8192, bin_time_min=60, total_mem_mb=24576)
GB = 1024 * 1024


def z3(pid, rss_gb=1, etime="05:00", ppid=500, exe=LOOP + "/repo/build/z3"):
    return Proc(pid, ppid, int(rss_gb * GB), etime, "./build/z3 -smt2 input.smt2", exe)


def lean(pid, rss_gb=1, etime="05:00", ppid=500, args="/elan/bin/lean Proof.lean"):
    return Proc(pid, ppid, int(rss_gb * GB), etime, args, "/elan/toolchains/v4/bin/lean")


def reasons(procs):
    return {proc.pid: (name, why) for proc, name, why in scan(procs, LIMITS, LOOP)}


class WatchdogScanTests(unittest.TestCase):
    def test_orphaned_loop_z3_is_killed_even_when_small(self):
        # 2026-10-30: z3 children of sweep workers killed by subprocess.run timeouts.
        self.assertEqual(reasons([z3(10, rss_gb=0.1, ppid=1)]), {10: ("z3", "orphan")})

    def test_orphaned_lean_is_killed(self):
        self.assertEqual(reasons([lean(11, ppid=1)]), {11: ("lean", "orphan")})

    def test_z3_outside_the_loop_directory_is_left_alone(self):
        self.assertEqual(reasons([z3(12, rss_gb=40, ppid=1, exe="/Users/me/dev/z3/build/z3")]), {})

    def test_editor_language_server_is_left_alone(self):
        self.assertEqual(reasons([lean(13, rss_gb=20, etime="2-00:00:00", args="/elan/bin/lean --server")]), {})

    def test_memory_and_age_limits_are_per_kind(self):
        found = reasons([z3(20, rss_gb=9), lean(21, rss_gb=9), z3(22, etime="01:00:01"), lean(23, etime="31:00")])
        self.assertEqual(found, {20: ("z3", "memory"), 22: ("z3", "time"), 23: ("lean", "time")})

    def test_test_z3_is_watched_under_its_own_name(self):
        self.assertEqual(reasons([z3(24, ppid=1, exe=LOOP + "/repo/build/test-z3")]), {24: ("test-z3", "orphan")})

    def test_largest_go_until_the_total_fits(self):
        # 36 GB: dropping the 11.5 GB lean leaves 24.5 GB, still above 24 GB; dropping the 11 GB one fits.
        procs = [z3(30, rss_gb=7.5), lean(31, rss_gb=11.5), z3(32, rss_gb=6), lean(33, rss_gb=11)]
        self.assertEqual(reasons(procs), {31: ("lean", "total"), 33: ("lean", "total")})

    def test_elapsed_time_formats(self):
        self.assertEqual(z3(1, etime="07").seconds, 7)
        self.assertEqual(z3(1, etime="02:03").seconds, 123)
        self.assertEqual(z3(1, etime="01:02:03").seconds, 3723)
        self.assertEqual(z3(1, etime="2-01:02:03").seconds, 2 * 86400 + 3723)

    def test_loop_scripts_keep_the_watchdog_up_but_mentions_of_them_do_not(self):
        self.assertTrue(OWNER.search("bash /Users/me/lean-loop/loop.sh -n 1 --stop-on-cpp"))
        self.assertTrue(OWNER.search("/bin/bash ./run_until_cpp.sh"))
        self.assertTrue(OWNER.search("bash ./report_pr.sh 48 48"))
        self.assertFalse(OWNER.search("vim loop.sh"))
        self.assertFalse(OWNER.search("tail -f /Users/me/lean-loop/logs/run_until_cpp.sh.out"))


if __name__ == "__main__":
    unittest.main()
