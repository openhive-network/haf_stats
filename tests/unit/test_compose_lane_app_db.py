"""/app/db as .aidev/compose_lane.py serves it to an app-image service.

The app image's /app/db holds the db/version.sql the Dockerfile bakes from GIT_HASH, so
every install writes an app_version row, and a service that mounts over /app/db has none.
The lane serves an unmounted db/ as the tree's own plus that file, written from HEAD, and a
mounted one as mounted. The lane is replayed from a one-service compose file whose service
reads /app (the runtime image's /app -> /tmp/aidev-app) through docker/docker_entrypoint.sh.
"""

from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

import pytest

pytest.importorskip("yaml")

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / ".aidev" / "compose_lane.py"
APP = "/tmp/aidev-app"
TIMEOUT = 120


def tree(tmp_path: Path) -> Path:
    root = tmp_path / "tree"
    for sub in ("db", "endpoints", "scripts", "docker"):
        (root / sub).mkdir(parents=True)
    (root / "db" / "schema.sql").write_text("SELECT 1;\n")
    for name in ("docker_entrypoint.sh", "block-processing-healthcheck.sh", "block-processing-healthcheck.sql"):
        shutil.copy(ROOT / "docker" / name, root / "docker" / name)
    return root


def git_head(root: Path) -> str:
    git = ["git", "-C", str(root), "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"]
    subprocess.run([*git, "init", "-q"], check=True)
    subprocess.run([*git, "add", "-A"], check=True)
    subprocess.run([*git, "commit", "-qm", "t"], check=True)
    return subprocess.run([*git, "rev-parse", "HEAD"], check=True, capture_output=True, text=True).stdout.strip()


def run_service(root: Path, command: str, volumes: str = "") -> tuple[subprocess.CompletedProcess[str], str]:
    (root / "compose.yml").write_text(
        "services:\n  app:\n    image: ${HAF_STATS_IMAGE:-x}\n"
        f"    command: {command}\n" + (f"    volumes: [{volumes}]\n" if volumes else ""))
    out = root / "out"
    result = subprocess.run(
        [sys.executable, str(SCRIPT), str(root / "compose.yml"), "app", str(out), "install"],
        cwd=root, capture_output=True, text=True, timeout=TIMEOUT,
    )
    return result, (out / "app.log").read_text()


def test_unmounted_db_holds_the_tree_and_the_version_sql_the_image_bakes(tmp_path: Path) -> None:
    root = tree(tmp_path)
    head = git_head(root)

    result, log = run_service(root, f'["bash", "-c", "cat {APP}/db/schema.sql {APP}/db/version.sql"]')

    assert result.returncode == 0, log
    assert log.splitlines()[-2:] == [
        "SELECT 1;",
        "TRUNCATE haf_stats_app.app_version; "
        f"INSERT INTO haf_stats_app.app_version (git_hash) VALUES ('{head[:8]}');",
    ]


def test_unmounted_db_outside_a_git_checkout_is_unspecified(tmp_path: Path) -> None:
    root = tree(tmp_path)

    result, log = run_service(root, f'["cat", "{APP}/db/version.sql"]')

    assert result.returncode == 0, log
    assert log.splitlines()[-1].endswith("VALUES ('unspecified');")


def test_mounted_db_is_served_as_mounted_without_a_version_sql(tmp_path: Path) -> None:
    root = tree(tmp_path)
    git_head(root)
    baseline = root / "baseline-db"
    baseline.mkdir()
    (baseline / "old.sql").write_text("SELECT 0;\n")

    result, log = run_service(
        root, f'["bash", "-c", "cat {APP}/db/old.sql && test ! -e {APP}/db/version.sql"]',
        volumes='"./baseline-db:/app/db:ro"')

    assert result.returncode == 0, log
    assert log.splitlines()[-1] == "SELECT 0;"
