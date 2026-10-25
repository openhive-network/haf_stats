#!/usr/bin/env python3
"""Run one of the project's CI compose lanes inside the AIDEV runtime container.

    compose_lane.py COMPOSE_FILE WAIT_SERVICE OUT_DIR SUITE

CI runs docker/docker-compose-ci.yml (endpoint-tests) and
docker/docker-compose-ci-install.yml (install-test) with `docker compose up` and
`docker compose wait <service>`. A slot has no docker daemon, so this replays the
same file: it reads the services, their commands, environment, volumes,
healthchecks and depends_on conditions from the compose file itself (so a step the
project adds to its CI lane runs here too), and runs each one as a local process.

  - `postgres` is the stack's service (.aidev/test-stack.compose.yml), reached by
    that name; it is never started here.
  - a `postgres:*` service with `entrypoint: [/bin/sh, -c]` runs its command with sh.
  - an app-image service (`image: ${HAF_STATS_IMAGE...}`) runs
    docker/docker_entrypoint.sh with its command, as the app image's ENTRYPOINT does,
    over /app (the runtime image's /app -> /tmp/aidev-app) holding the db/,
    endpoints/ and scripts/ it mounts (the tree's own when it mounts none).
  - `postgrest` runs the postgrest binary with the service's environment.
  - `rewriter` (built from Dockerfile.rewriter) runs openresty over the tree's
    docker/haf_stats_nginx.conf.template and endpoints/rewrite_rules.conf, rendered
    as docker/rewriter_entrypoint.sh renders them, on unprivileged ports.
  - `tavern` runs /opt/venv's pytest over the mounted tests with the `-m` marker
    expression the service's command names (CI pip-installs the same versions).

Bind mounts at container paths are served by rewriting those paths in commands,
environment values and mounted shell scripts; host names of the services run here
resolve to 127.0.0.1. Each service's output goes to OUT_DIR/<service>.log; one junit
case per service goes to OUT_DIR/<SUITE>.xml (tavern's own report beside it).
Exit 0 iff WAIT_SERVICE exited 0.
"""
from __future__ import annotations

import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from xml.sax.saxutils import escape, quoteattr

import yaml

STACK_SERVICES = {"postgres"}
LANE_TIMEOUT = 600  # CI's `timeout 600 docker compose ... wait`
REWRITER_PORTS = {"80": "18080", "81": "18081"}
POSTGREST_PORT = "3000"
APP_LINK = Path("/tmp/aidev-app")
LOG_TAIL_LINES = 80
CONTROL = re.compile(r"\x1b\[[0-9;]*[A-Za-z]|[\x00-\x08\x0b\x0c\x0e-\x1f]")


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


class Service:
    def __init__(self, name: str, spec: dict, lane: "Lane"):
        self.name = name
        self.spec = spec
        self.lane = lane
        self.proc: subprocess.Popen | None = None
        self.started = 0.0
        self.ended = 0.0
        self.rc: int | None = None
        self.healthy = False
        self.up_at_end = False
        self.health_checks = 0
        self.next_health = 0.0
        self.long_running = name in ("postgrest", "rewriter")
        self.logfile = lane.out / f"{name}.log"
        self.workdir = Path(tempfile.mkdtemp(prefix=f"lane-{name}-"))
        self.mounts = self._mounts()
        self.staged_files: set[Path] = set()

    # container path -> host path, for this service's bind mounts
    def _mounts(self) -> dict[str, Path]:
        result = {}
        for vol in self.spec.get("volumes", []) or []:
            if not isinstance(vol, str):
                continue
            parts = vol.split(":")
            if len(parts) < 2 or not parts[0].startswith("."):
                continue
            result[parts[1]] = (self.lane.compose_dir / parts[0]).resolve()
        return result

    def depends(self) -> dict[str, str]:
        deps = self.spec.get("depends_on") or {}
        if isinstance(deps, list):
            return {d: "service_started" for d in deps}
        return {d: (c or {}).get("condition", "service_started") for d, c in deps.items()}

    def rewrite(self, text: str) -> str:
        """Container paths of this service's mounts -> host paths; service hosts -> 127.0.0.1."""
        for cpath in sorted(self.mounts, key=len, reverse=True):
            if cpath.startswith("/app/"):
                continue  # served through /app itself
            host = str(self.staged(cpath))
            text = re.sub(r"(?<![\w/.-])" + re.escape(cpath) + r"(?=$|[^\w.-])", host, text)
        for local in self.lane.local_hosts:
            if local == "rewriter":  # served on unprivileged ports here
                for port, mapped in REWRITER_PORTS.items():
                    text = re.sub(r"(?<=//)rewriter:" + port + r"(?=/|$)", "127.0.0.1:" + mapped, text)
                text = re.sub(r"(?<=//)rewriter(?=/|$)", "127.0.0.1:" + REWRITER_PORTS["80"], text)
            text = re.sub(r"(?<=//)" + re.escape(local) + r"(?=[:/]|$)", "127.0.0.1", text)
        return text

    def staged(self, cpath: str) -> Path:
        """A mounted shell script gets its own container paths rewritten too."""
        host = self.mounts[cpath]
        if host.is_file() and host.suffix == ".sh":
            dest = self.workdir / host.name
            if dest not in self.staged_files:
                self.staged_files.add(dest)  # before rewriting: a script may name itself
                dest.write_text(self.rewrite(host.read_text()))
            return dest
        return host

    def env(self) -> dict[str, str]:
        env = dict(os.environ)
        raw = self.spec.get("environment") or {}
        if isinstance(raw, list):
            raw = dict(item.split("=", 1) for item in raw)
        for key, value in raw.items():
            value = "" if value is None else str(value)
            value = self.rewrite(value)
            if value in self.lane.local_hosts:
                value = "127.0.0.1"
            env[key] = value
        return env

    def command(self) -> list[str]:
        image = str(self.spec.get("image", ""))
        cmd = self.spec.get("command")
        if self.name == "postgrest":
            return ["postgrest"]
        if self.name == "rewriter":
            return self.lane.rewriter_command(self)
        if self.name == "tavern":
            return self.lane.tavern_command(self, cmd)
        if "HAF_STATS_IMAGE" in image:
            self.lane.point_app(self)
            args = cmd if isinstance(cmd, list) else shlex.split(cmd or "")
            return ["bash", str(APP_LINK / "docker_entrypoint.sh")] + [self.rewrite(a) for a in args]
        if image.startswith("postgres:"):
            entry = self.spec.get("entrypoint")
            if entry != ["/bin/sh", "-c"]:
                raise SystemExit(f"{self.name}: unsupported entrypoint {entry!r}")
            script = cmd[0] if isinstance(cmd, list) else cmd
            return ["sh", "-c", self.rewrite(script)]
        raise SystemExit(f"{self.name}: no local runner for image {image!r}")

    def start(self) -> None:
        argv = self.command()
        log(f"== {self.lane.suite}: start {self.name}")
        env = self.env()
        if self.name == "postgrest":
            env.setdefault("PGRST_SERVER_PORT", POSTGREST_PORT)
            env.setdefault("PGRST_SERVER_HOST", "127.0.0.1")
        handle = open(self.logfile, "w")
        handle.write("$ " + shlex.join(argv) + "\n")
        handle.flush()
        self.proc = subprocess.Popen(argv, cwd=self.lane.root, env=env, stdout=handle,
                                     stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                                     start_new_session=True)
        self.started = time.monotonic()
        hc = self.spec.get("healthcheck") or {}
        self.next_health = self.started + seconds(hc.get("start_period", "0s"))

    def poll(self) -> None:
        if self.proc is None or self.rc is not None:
            return
        rc = self.proc.poll()
        if rc is not None:
            self.rc = rc
            self.ended = time.monotonic()
            log(f"== {self.lane.suite}: {self.name} exited {rc} after {self.ended - self.started:.0f}s")
            return
        hc = self.spec.get("healthcheck")
        if hc and not self.healthy and time.monotonic() >= self.next_health:
            test = hc["test"]
            if isinstance(test, list) and test[0] == "CMD-SHELL":
                probe = ["sh", "-c", self.rewrite(test[1])]
            elif isinstance(test, list) and test[0] == "CMD":
                probe = [self.rewrite(a) for a in test[1:]]
            else:
                probe = ["sh", "-c", self.rewrite(str(test))]
            if self.name == "rewriter":
                probe = [re.sub(r"127\.0\.0\.1:(\d+)", lambda m: "127.0.0.1:" + REWRITER_PORTS.get(m[1], m[1]), a)
                         for a in probe]
            try:
                ok = subprocess.run(probe, env=self.env(), cwd=self.lane.root, capture_output=True,
                                    timeout=seconds(hc.get("timeout", "30s")) + 5).returncode == 0
            except subprocess.TimeoutExpired:
                ok = False
            self.health_checks += 1
            self.healthy = ok
            if ok:
                log(f"== {self.lane.suite}: {self.name} healthy")
            self.next_health = time.monotonic() + seconds(hc.get("interval", "30s"))

    def satisfies(self, condition: str) -> bool | None:
        """True when met, None while pending, False when it can no longer be met."""
        if condition == "service_started":
            return True if self.proc is not None else None
        if condition == "service_healthy":
            if self.healthy:
                return True
            if self.rc is not None:
                return False
            hc = self.spec.get("healthcheck") or {}
            if self.health_checks >= int(hc.get("retries", 3)) + 1 and not self.healthy:
                return False
            return None
        if condition == "service_completed_successfully":
            if self.rc is None:
                return None
            return self.rc == 0
        raise SystemExit(f"{self.name}: unsupported depends_on condition {condition!r}")

    def stop(self) -> None:
        if self.proc is not None and self.rc is None:
            try:
                os.killpg(self.proc.pid, 15)
                self.proc.wait(timeout=10)
            except (ProcessLookupError, subprocess.TimeoutExpired):
                try:
                    os.killpg(self.proc.pid, 9)
                except ProcessLookupError:
                    pass


def seconds(value) -> float:
    if isinstance(value, (int, float)):
        return float(value)
    match = re.fullmatch(r"(\d+(?:\.\d+)?)(ms|s|m)?", str(value).strip())
    if not match:
        return 1.0
    number, unit = float(match[1]), match[2] or "s"
    return number / 1000 if unit == "ms" else number * 60 if unit == "m" else number


class Lane:
    def __init__(self, compose: Path, wait: str, out: Path, suite: str):
        self.compose_dir = compose.parent.resolve()
        self.root = Path.cwd().resolve()
        self.out = out
        self.suite = suite
        self.wait = wait
        data = yaml.safe_load(compose.read_text())
        specs = data["services"]
        self.local_hosts = [n for n in specs if n not in STACK_SERVICES]
        self.services = {n: Service(n, s, self) for n, s in specs.items() if n not in STACK_SERVICES}
        if wait not in self.services:
            raise SystemExit(f"{compose}: no service {wait!r}")

    def point_app(self, svc: Service) -> None:
        """/app for this service: the db/, endpoints/, scripts/ it mounts, else the tree's."""
        app = svc.workdir / "app"
        app.mkdir(exist_ok=True)
        for sub in ("db", "endpoints"):
            (app / sub).symlink_to(svc.mounts.get(f"/app/{sub}", self.root / sub))
        # The Dockerfile copies scripts/ and the entrypoints with --chmod=755.
        shutil.copytree(svc.mounts.get("/app/scripts", self.root / "scripts"), app / "scripts", symlinks=True)
        for name in ("docker_entrypoint.sh", "block-processing-healthcheck.sh", "block-processing-healthcheck.sql"):
            shutil.copy(self.root / "docker" / name, app / name)
        for path in [app / "docker_entrypoint.sh", app / "block-processing-healthcheck.sh", *(app / "scripts").rglob("*")]:
            if path.is_file() and not path.is_symlink():
                path.chmod(0o755)
        tmp = APP_LINK.with_name(APP_LINK.name + ".new")
        if tmp.is_symlink() or tmp.exists():
            tmp.unlink()
        tmp.symlink_to(app)
        tmp.replace(APP_LINK)

    def rewriter_command(self, svc: Service) -> list[str]:
        prefix = svc.workdir / "openresty"
        (prefix / "conf").mkdir(parents=True)
        (prefix / "logs").mkdir()
        env = svc.env()
        log_line = "rewrite_log on;" if env.get("REWRITE_LOG") == "on" else "# rewrite_log off;"
        conf = (self.root / "docker/haf_stats_nginx.conf.template").read_text()
        conf = (conf.replace("${REWRITE_LOG}", log_line)
                .replace("${POSTGREST_HOST}", env.get("POSTGREST_HOST", "haf-stats-api"))
                .replace("${POSTGREST_PORT}", env.get("POSTGREST_PORT", "3000")))
        for port, local in REWRITER_PORTS.items():
            conf = re.sub(r"(listen\s+[0-9.]*:?)" + port + r"\b", r"\g<1>" + local, conf)
        (prefix / "conf/nginx.conf").write_text(conf)
        shutil.copy(self.root / "endpoints/rewrite_rules.conf", prefix / "conf/rewrite_rules.conf")
        mime = Path("/usr/local/openresty/nginx/conf/mime.types")
        if mime.exists():
            shutil.copy(mime, prefix / "conf/mime.types")
        return ["openresty", "-p", str(prefix), "-c", str(prefix / "conf/nginx.conf"),
                "-g", f"daemon off; pid {prefix}/logs/nginx.pid;"]

    def tavern_command(self, svc: Service, cmd) -> list[str]:
        text = cmd if isinstance(cmd, str) else " ".join(cmd or [])
        pytest_part = text[text.index("pytest "):].strip().rstrip('"').strip()
        args = shlex.split(svc.rewrite(pytest_part))[1:]
        junit = self.out / "tavern.xml"
        return ["pytest", "-p", "no:cacheprovider", f"--junitxml={junit}", "-o", "junit_family=xunit1"] + args

    def run(self) -> int:
        deadline = time.monotonic() + LANE_TIMEOUT
        target = self.services[self.wait]
        try:
            while target.rc is None and time.monotonic() < deadline:
                progressed = False
                for svc in self.services.values():
                    svc.poll()
                for svc in self.services.values():
                    if svc.proc is not None:
                        continue
                    states = [self.services[d].satisfies(c) if d in self.services else True
                              for d, c in svc.depends().items()]
                    if all(s is True for s in states):
                        svc.start()
                        progressed = True
                if any(s.long_running and s.rc is not None for s in self.services.values()):
                    break  # a server died: nothing downstream of it can pass
                if not progressed:
                    if self._blocked(target):
                        break
                    time.sleep(0.2)
        finally:
            for svc in self.services.values():
                svc.poll()
                svc.up_at_end = svc.proc is not None and svc.rc is None
                svc.stop()
            for svc in self.services.values():
                svc.poll()
        self._junit()
        if target.rc is None:
            log(f"== {self.suite}: {self.wait} never completed")
            return 1
        return 0 if target.rc == 0 else 1

    def _blocked(self, target: Service) -> bool:
        """True when the target can no longer start or finish."""
        def dead(svc: Service, seen: set) -> bool:
            if svc.name in seen:
                return False
            seen.add(svc.name)
            if svc.proc is not None:
                return False
            for dep, cond in svc.depends().items():
                other = self.services.get(dep)
                if other is None:
                    continue
                if other.satisfies(cond) is False or dead(other, seen):
                    return True
            return False
        if target.proc is None:
            return dead(target, set())
        return False

    def _junit(self) -> None:
        cases = []
        for svc in self.services.values():
            took = (svc.ended or time.monotonic()) - svc.started if svc.started else 0.0
            head = f'<testcase classname={quoteattr(self.suite)} name={quoteattr(svc.name)} time="{took:.1f}">'
            if svc.proc is None:
                cases.append(f'{head}<skipped message="not started: a dependency did not succeed"/></testcase>')
            elif svc.long_running:
                ok = svc.up_at_end  # a server must still be up when the lane ends
                cases.append(head + ("" if ok else f'<failure message="exited {svc.rc}">{escape(tail(svc.logfile))}</failure>') + "</testcase>")
            elif svc.rc == 0:
                cases.append(head + "</testcase>")
            else:
                msg = "never finished" if svc.rc is None else f"exit {svc.rc}"
                cases.append(f'{head}<failure message={quoteattr(msg)}>{escape(tail(svc.logfile))}</failure></testcase>')
        failures = sum("<failure" in c for c in cases)
        skipped = sum("<skipped" in c for c in cases)
        (self.out / f"{self.suite}.xml").write_text(
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            f'<testsuite name={quoteattr(self.suite)} tests="{len(cases)}" failures="{failures}" errors="0" skipped="{skipped}">\n'
            + "\n".join(cases) + "\n</testsuite>\n")


def tail(path: Path) -> str:
    if not path.is_file():
        return ""
    lines = CONTROL.sub("", path.read_text(errors="replace")).splitlines()
    return "\n".join(lines[-LOG_TAIL_LINES:])


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    compose, wait, out, suite = argv
    out_dir = Path(out)
    out_dir.mkdir(parents=True, exist_ok=True)
    return Lane(Path(compose), wait, out_dir, suite).run()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
