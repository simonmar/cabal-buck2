#!/usr/bin/env python3
"""The standard comparison of cabal and buck2 builds of a project (see
"Performance" in the README).

Usage: bench/compare.py PROJECT.json WORK_DIR [options]

It needs ghc, cabal, cabal-buck2 and buck2 on PATH, and a checkout of
haskell-buck2 (--rules). The project is cloned into WORK_DIR at the
revision that PROJECT.json gives, and its dependencies are built first, so
that every configuration uses the same ones and their build isn't measured.

Each configuration builds the project's packages without optimisation,
running --jobs jobs at once:

* cabal: cabal build, with GHC's -jsem semaphore shared among the packages.
* buck2-component: buck2, compiling each component with one ghc --make.
* buck2-module: buck2, compiling module by module in the persistent worker
  (--worker, or the buck2-ghc-worker on PATH, or ghc-worker, its earlier
  name).
* repl: cabal repl of the components the JSON lists under "repl", all at
  once (--enable-multi-repl).

Each runs these scenarios. The cheap ones (noop, hub-comment, leaf) run
--repeats times, and the expensive ones (clean, hub-abi) --heavy-repeats
times:

* clean: a build from nothing (for repl, loading the packages).
* noop: building again without a change.
* hub-comment, hub-abi: editing a module that much of the project imports,
  first a comment, then its interface.
* leaf: editing a module that nothing imports.

For buck2-module, each edit is also timed building only the interfaces
(the [interfaces] sub-targets), and for repl, the edits are timed with
:reload. (For buck2-component, the [interfaces] sub-target is built by the
same ghc --make action as the library, so it takes as long.)

Each configuration builds its own copy of the project, so that the build
configurations can take turns: each run of a scenario is made in every one
of them before the next starts, and each run starts with the next one. A
slow spell of the machine (a laptop's power limit, say) then falls on all
of them, not on one. With one run of each (the default for clean and
hub-abi), that only goes so far: on a laptop, --heavy-repeats 3 is safer.
repl runs after the others, since its GHCi session would hold its memory
while they build.

Besides the wall-clock time, each run records the CPU time that the whole
machine spent busy (from /proc/stat, on Linux). That includes buck2's
daemon and workers, which aren't children of the build command, and
anything else running, so the machine should otherwise be idle. Set
against the wall-clock time, it shows whether a configuration is slower
because it does more work or because it keeps fewer CPUs busy.

The results go to WORK_DIR/results.json, and tables of the medians are
printed.
"""

import argparse
import json
import os
import shutil
import statistics
import subprocess
import sys
import time

CONFIGS = ["cabal", "buck2-component", "buck2-module", "repl"]

# The project file the builds use: the project's own (project_file), or one
# written from its packages and project settings.
PROJECT_FILE = "cabal.project.bench"
SCENARIOS = ["clean", "noop", "hub-comment", "hub-abi", "leaf"]

# The scenarios that take minutes rather than seconds, which vary from run to
# run by a few percent, and so are run fewer times.
HEAVY = {"clean", "hub-abi"}


def log(*args):
    print(*args, file=sys.stderr, flush=True)


def run(cmd, cwd, log_path, check=True):
    """Runs cmd, appending its output to log_path, and returns how long it
    took."""
    with open(log_path, "a") as f:
        f.write("\n$ " + " ".join(cmd) + "\n")
        f.flush()
        start = time.monotonic()
        p = subprocess.run(cmd, cwd=cwd, stdout=f, stderr=subprocess.STDOUT)
        elapsed = time.monotonic() - start
    if p.returncode != 0:
        if check:
            sys.exit("failed ({}): {} (see {})".format(p.returncode, " ".join(cmd), log_path))
        return None
    return elapsed


def cpu_seconds():
    """The CPU time that the machine has spent busy since it started, or
    None where /proc/stat isn't available."""
    try:
        with open("/proc/stat") as f:
            fields = [int(x) for x in f.readline().split()[1:]]
    except OSError:
        return None
    # user, nice, system, irq and softirq: everything but idle, iowait and
    # the time a hypervisor took.
    return sum(fields[i] for i in (0, 1, 2, 5, 6)) / os.sysconf("SC_CLK_TCK")


def timed(f):
    """Runs f, which returns the wall-clock time it took, and returns that
    time and the CPU time the machine spent meanwhile."""
    before = cpu_seconds()
    wall = f()
    after = cpu_seconds()
    return wall, after - before if before is not None else None


def git(src, *args):
    subprocess.run(["git", "-c", "user.name=bench", "-c", "user.email=bench@example.com", *args], cwd=src, check=True,
                   stdout=subprocess.DEVNULL)


def checkout(project, work):
    """Clones the project into work/src at its revision, applies its patches
    and commits them, so that `git checkout` of a file restores it."""
    src = os.path.join(work, "src")
    if not os.path.isdir(src):
        subprocess.run(["git", "clone", "--quiet", project["repo"], src], check=True)
    # A buck2 daemon left by an earlier run would be working in directories
    # that the clean removes.
    subprocess.run(["buck2", "kill"], cwd=src, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    git(src, "fetch", "--quiet", "origin", project["rev"])
    git(src, "checkout", "--quiet", "--force", "--detach", project["rev"])
    git(src, "clean", "-fdxq", "-e", "dist-newstyle")
    for patch in project.get("patches", []):
        edit(src, patch)
    if project.get("patches"):
        git(src, "commit", "--quiet", "-am", "bench: patches")
    if "project_file" not in project:
        with open(os.path.join(src, PROJECT_FILE), "w") as f:
            f.write("packages:\n" + "".join("  {}\n".format(p) for p in project["packages"]))
            f.write(project.get("project", ""))
    return src


def copy_for(src, config):
    """A fresh copy of the checkout (with its patches) for one
    configuration, so that the configurations can take turns without
    undoing each other's builds."""
    dst = "{}-{}".format(src, config)
    if os.path.isdir(dst):
        subprocess.run(["buck2", "kill"], cwd=dst, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        shutil.rmtree(dst)
    subprocess.run(["git", "clone", "--quiet", src, dst], check=True)
    if os.path.exists(os.path.join(src, PROJECT_FILE)) and not os.path.exists(os.path.join(dst, PROJECT_FILE)):
        shutil.copy(os.path.join(src, PROJECT_FILE), dst)
    return dst


def build_dependencies(args, src):
    """Builds the project's dependencies, so that no configuration's timed
    builds include them."""
    deps_log = os.path.join(args.work, "dependencies.log")
    build_all = ["cabal", "build", "--project-file=" + PROJECT_FILE, "all", "-O0", "-j{}".format(args.jobs)]
    # cabal can't build only the dependencies when one of them depends on a
    # package of the project (hackage-security on Cabal's Cabal-syntax, say),
    # and builds that one in the project's dist-newstyle rather than the
    # store. Then the whole project is built once, which builds the others.
    if run(build_all[:4] + ["--only-dependencies"] + build_all[4:], src, deps_log, check=False) is None:
        run(build_all, src, deps_log)


def edit(src, change):
    """Applies an edit: `replace` pairs of text, and text to `append`."""
    path = os.path.join(src, change["file"])
    with open(path) as f:
        text = f.read()
    for old, new in change.get("replace", []):
        if text.count(old) != 1:
            sys.exit("{}: expected {!r} once".format(change["file"], old))
        text = text.replace(old, new)
    text += change.get("append", "")
    with open(path, "w") as f:
        f.write(text)


def restore(src, change):
    git(src, "checkout", "--quiet", "--", change["file"])


class Cabal:
    def __init__(self, args, src, log_path):
        self.src, self.log = src, log_path
        self.build_cmd = ["cabal", "build", "--project-file=" + PROJECT_FILE, "all", "-O0",
                          "-j{}".format(args.jobs), "--semaphore"]

    def clean(self):
        shutil.rmtree(os.path.join(self.src, "dist-newstyle"), ignore_errors=True)
        return self.build()

    def build(self):
        return run(self.build_cmd, self.src, self.log)


class Buck2:
    def __init__(self, args, project, src, log_path, per_module):
        self.src, self.log, self.args = src, log_path, args
        self.config = ["-c", "haskell.per_module_worker=" + args.worker] if per_module else []
        with open(os.path.join(src, "cabal-buck2.bzl"), "w") as f:
            f.write('DEFAULTS = {{"*": {{"*": {{"per_module": {}}}}}}}\n'.format(per_module))
        link = os.path.join(src, "buck2")
        if os.path.lexists(link):
            os.remove(link)
        os.symlink(os.path.abspath(args.rules), link)
        self.generate = run(["cabal", "buck2", "--project-file=" + PROJECT_FILE, "-O0"], src, log_path)
        # A package at the project's root has its targets in the root
        # directory's BUCK, alongside the other packages' directories.
        self.targets = ["//:" if p.strip("./") == "" else "//{}/...".format(p.rstrip("/")) for p in project["packages"]]
        query = ["buck2", "uquery", *self.config, "kind(haskell_library, set({}))".format(" ".join(self.targets))]
        p = subprocess.run(query, cwd=src, capture_output=True, text=True)
        with open(log_path, "a") as f:
            f.write("\n$ " + " ".join(query) + "\n" + p.stdout + p.stderr)
        if p.returncode != 0:
            sys.exit("failed ({}): {} (see {})".format(p.returncode, " ".join(query), log_path))
        out = p.stdout
        self.interfaces = [t.strip() + "[interfaces]" for t in out.split() if t.strip()]

    def clean(self):
        run(["buck2", "kill"], self.src, self.log, check=False)
        shutil.rmtree(os.path.join(self.src, "buck-out"), ignore_errors=True)
        return self.build()

    def build(self):
        return run(["buck2", "build", *self.config, "-j", str(self.args.jobs), *self.targets], self.src, self.log)

    def build_interfaces(self):
        return run(["buck2", "build", *self.config, "-j", str(self.args.jobs), *self.interfaces], self.src, self.log)


class Repl:
    """cabal repl of every package, driven through a pipe. After each
    command it asks GHCi to echo a marker, and waits for that."""

    MARKER = "__BENCH_DONE__"

    def __init__(self, args, project, src, log_path):
        self.src, self.log = src, log_path
        self.cmd = ["cabal", "repl", "--project-file=" + PROJECT_FILE, "--enable-multi-repl", "-O0", *project["repl"]]
        self.proc = None

    def clean(self):
        self.stop()
        start = time.monotonic()
        self.proc = subprocess.Popen(self.cmd, cwd=self.src, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.STDOUT, text=True, bufsize=1)
        self.wait()
        return time.monotonic() - start

    def reload(self):
        start = time.monotonic()
        self.proc.stdin.write(":reload\n")
        self.wait()
        return time.monotonic() - start

    def wait(self):
        self.proc.stdin.write(":! echo {}\n".format(self.MARKER))
        self.proc.stdin.flush()
        with open(self.log, "a") as f:
            failed = False
            for line in self.proc.stdout:
                f.write(line)
                # GHCi's prompt may come before the marker on its line.
                if line.rstrip().endswith(self.MARKER):
                    break
                if "Failed," in line:
                    failed = True
            else:
                sys.exit("cabal repl exited (see {})".format(self.log))
        if failed:
            sys.exit("cabal repl failed to load the modules (see {})".format(self.log))

    def stop(self):
        if self.proc:
            self.proc.stdin.close()
            self.proc.wait()
            self.proc = None


def recorder(results, cpu):
    def record(config, scenario, wall_cpu):
        wall, cpu_s = wall_cpu
        results.setdefault(config, {}).setdefault(scenario, []).append(round(wall, 1))
        if cpu_s is not None:
            cpu.setdefault(config, {}).setdefault(scenario, []).append(round(cpu_s))
        log("{:16} {:22} {:7.1f}s {}".format(config, scenario, wall, "" if cpu_s is None else "{:6.0f} CPU-s".format(cpu_s)))
    return record


def edits_of(project):
    return {"hub-comment": project["hub_comment"], "hub-abi": project["hub_abi"], "leaf": project["leaf"]}


def measure(args, project, srcs, configs, record):
    """Runs the scenarios in the build configurations, which take turns:
    each run of a scenario is made in every configuration before the next
    run starts, and each run starts with the next configuration."""

    def repeats(scenario):
        n = len(configs)
        for i in range(args.heavy_repeats if scenario in HEAVY else args.repeats):
            yield configs[i % n:] + configs[:i % n]

    builders = {}
    for config in configs:
        log_path = os.path.join(args.work, "{}.log".format(config))
        if config == "cabal":
            builders[config] = Cabal(args, srcs[config], log_path)
        else:
            builders[config] = Buck2(args, project, srcs[config], log_path, per_module=config == "buck2-module")
            record(config, "generate", (builders[config].generate, None))
    for order in repeats("clean"):
        for config in order:
            record(config, "clean", timed(builders[config].clean))
    for order in repeats("noop"):
        for config in order:
            record(config, "noop", timed(builders[config].build))
    for scenario, change in edits_of(project).items():
        for order in repeats(scenario):
            for config in order:
                builder, src = builders[config], srcs[config]
                edit(src, change)
                record(config, scenario, timed(builder.build))
                restore(src, change)
                builder.build()
                if config == "buck2-module":
                    edit(src, change)
                    record(config, scenario + " [interfaces]", timed(builder.build_interfaces))
                    restore(src, change)
                    builder.build()


def measure_repl(args, project, src, record):
    repl = Repl(args, project, src, os.path.join(args.work, "repl.log"))
    for _ in range(args.heavy_repeats):
        record("repl", "clean", timed(repl.clean))
    for _ in range(args.repeats):
        record("repl", "noop", timed(repl.reload))
    for scenario, change in edits_of(project).items():
        for _ in range(args.heavy_repeats if scenario in HEAVY else args.repeats):
            edit(src, change)
            record("repl", scenario, timed(repl.reload))
            restore(src, change)
            repl.reload()
    repl.stop()


def table(results, fmt):
    rows = ["generate"] + [s for scenario in SCENARIOS for s in (scenario, scenario + " [interfaces]")]
    configs = [c for c in CONFIGS if c in results]
    lines = ["| | " + " | ".join(configs) + " |", "|---" * (len(configs) + 1) + "|"]
    for row in rows:
        cells = [results[c].get(row) for c in configs]
        if any(cells):
            lines.append("| {} | ".format(row) + " | ".join(fmt.format(statistics.median(c)) if c else "" for c in cells) + " |")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("project", help="the project's description (JSON)")
    ap.add_argument("work", help="the directory to clone the project into, and to write the logs and results to")
    ap.add_argument("--rules", required=True, help="the checkout of haskell-buck2 to build with")
    ap.add_argument("--worker", default=shutil.which("buck2-ghc-worker") or shutil.which("ghc-worker"),
                    help="the persistent worker, for buck2-module")
    ap.add_argument("--jobs", type=int, default=os.cpu_count(), help="how many jobs to run at once (default: all the CPUs)")
    ap.add_argument("--repeats", type=int, default=3, help="how many times to run each cheap scenario (default 3)")
    ap.add_argument("--heavy-repeats", type=int, default=1, help="how many times to run clean and hub-abi (default 1)")
    ap.add_argument("--configs", default=",".join(CONFIGS), help="which configurations to run (default all)")
    args = ap.parse_args()
    with open(args.project) as f:
        project = json.load(f)
    global PROJECT_FILE
    PROJECT_FILE = project.get("project_file", PROJECT_FILE)
    os.makedirs(args.work, exist_ok=True)
    src = checkout(project, args.work)
    tools = {name: subprocess.run(cmd, capture_output=True, text=True).stdout.strip().splitlines()[0]
             for name, cmd in [("ghc", ["ghc", "--version"]), ("cabal", ["cabal", "--version"]), ("buck2", ["buck2", "--version"])]}
    configs = [c for c in CONFIGS if c in args.configs.split(",")]
    # A run of some of the configurations adds to the results of the others,
    # if they are of the same project and job count.
    results, cpu = {}, {}
    results_path = os.path.join(args.work, "results.json")
    if os.path.exists(results_path):
        with open(results_path) as f:
            old = json.load(f)
        if (old["project"], old["rev"], old["jobs"]) == (project["name"], project["rev"], args.jobs):
            results = {c: r for c, r in old["results"].items() if c not in configs}
            cpu = {c: r for c, r in old.get("cpu", {}).items() if c not in configs}
    record = recorder(results, cpu)

    def save():
        with open(results_path, "w") as f:
            json.dump({"project": project["name"], "rev": project["rev"], "jobs": args.jobs, "tools": tools,
                       "results": results, "cpu": cpu}, f, indent=1)

    srcs = {config: copy_for(src, config) for config in configs}
    log("building the dependencies")
    for config in configs:
        build_dependencies(args, srcs[config])
    builds = [c for c in configs if c != "repl"]
    if builds:
        measure(args, project, srcs, builds, record)
        save()
    if "repl" in configs:
        measure_repl(args, project, srcs["repl"], record)
        save()
    print("Wall-clock time:\n\n" + table(results, "{:.1f}s"))
    if cpu:
        print("\nCPU time (CPU-seconds, the whole machine):\n\n" + table(cpu, "{:.0f}"))


if __name__ == "__main__":
    main()
