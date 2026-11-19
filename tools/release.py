#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Nicolas Vaughan <nicolasvaughan@proton.me>
# This file is part of py-schematron. See the LICENSE file for details.
"""Release the current version: python3 tools/release.py [--dry-run]
[--yes] [--skip-tests] [--notes FILE]

The same script serves four repositories (py-schematron; the plugins
py-schematron.el and py-schematron-vscode, which get their copy from
tools/sync-plugins.py; and ODD2RNG, whose copy is made by hand) and works
out which one it is in:

  py-schematron         version: __version__ of py-schematron.py
                         notes:   its row in the version history of README.md
                         file:    dist/py-schematron-v.VERSION.zip (tools/bundle-zip.py)
  py-schematron.el   version: the Version header of py-schematron.el
                         notes:   its section of CHANGELOG.md
                         file:    dist/py-schematron.el-v.VERSION.zip (tools/bundle-zip.py)
  py-schematron-vscode  version: package.json
                         notes:   its section of CHANGELOG.md
                         file:    dist/validate-schematron-VERSION.vsix (npm run package)
  ODD2RNG                version: __version__ of odd2rng.py
                         notes:   its section of CHANGELOG.md
                         file:    dist/ODD2RNG-v.VERSION.zip (tools/bundle-zip.py)

The tag is vVERSION.  In order, the script:

  1. checks: on main, nothing uncommitted, a tag that is new or already on
     this commit, release notes found, and (in a plugin) a copy of
     py-schematron.py that is the same as ../py-schematron's;
  2. runs the tests (the unittest suites of the programs, the Emacs
     package's ERT tests, the extension's unit tests); for py-schematron,
     when $PY_SCHEMATRON_CORPUS names a corpus, also tools/corpus-check.py,
     which compares the results with the last release's on every document,
     and stops if any changed (--accept-corpus-changes, when that is meant);
  3. makes the file;
  4. tags the commit and pushes main and the tag to Codeberg and GitHub;
  5. makes the release on Codeberg (with tea) and on GitHub (with gh), with
     the notes and the file;
  6. downloads the file from both and compares it with the local one.

Each step that is already done is skipped (a tag or a release that exists,
a file already attached), so after a failure the script can simply be run
again.  --dry-run does steps 1 to 3 and says what it would do after.
Without --yes it asks before step 4.

It needs git, tea (logged in as "codeberg") and gh (logged in to GitHub).
"""

import sys

if sys.version_info < (3, 15):
    sys.exit(f"release.py needs Python 3.15 or later; this is "
             f"Python {sys.version.split()[0]}.")

import argparse  # noqa: E402
import hashlib  # noqa: E402
import json  # noqa: E402
import os  # noqa: E402
import re  # noqa: E402
import shutil  # noqa: E402
import subprocess  # noqa: E402
import tempfile  # noqa: E402
import time  # noqa: E402
import urllib.request  # noqa: E402
from pathlib import Path  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
OWNER = "nivaca"
FORGES = {"Codeberg": "codeberg.org", "GitHub": "github.com"}


class Failure(Exception):
    """A check or a step that failed; its text is said and the script stops."""


def say(text=""):
    print(text, flush=True)


def run(*cmd, cwd=ROOT, env=None, capture=True, check=True):
    """Run a command; return its stdout (or None when not captured)."""
    p = subprocess.run(cmd, cwd=cwd, env=env, text=True,
                       capture_output=capture)
    if check and p.returncode != 0:
        detail = (p.stderr or p.stdout or "").strip() if capture else ""
        raise Failure(f"{' '.join(map(str, cmd))} failed ({p.returncode})"
                      + (f":\n{detail}" if detail else ""))
    return p.stdout if capture else None


def git(*args, check=True):
    return run("git", *args, check=check).strip()


# ------------------------------------------------------------------ the three kinds

def read(path: Path) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def changelog_notes(version: str) -> str | None:
    """The section of CHANGELOG.md headed "## VERSION ...", without its heading."""
    m = re.search(rf"^## {re.escape(version)}\b.*?\n(.*?)(?=^## |\Z)", read("CHANGELOG.md"),
                  re.M | re.S)
    return m.group(1).strip() if m else None


def readme_notes(version: str) -> str | None:
    """The text of the row "| **VERSION** | date | text |" of README.md."""
    m = re.search(rf"^\| \*\*{re.escape(version)}\*\* \| [^|]+ \| (.*) \|$", read("README.md"), re.M)
    return m.group(1).strip() if m else None


class Program:
    repo = "py-schematron"

    def version(self):
        m = re.search(r'^__version__\s*=\s*"([^"]+)"', read("py-schematron.py"), re.M)
        return m.group(1) if m else None

    def notes(self, version):
        return readme_notes(version)

    def asset(self, version):
        return ROOT / "dist" / f"py-schematron-v.{version}.zip"

    def footer(self, name):
        return (f"File: `{name}`, the scripts, the tests and the documentation.")

    accept_corpus_changes = False

    def test(self):
        run(sys.executable, "-m", "unittest", "discover", "-s", "tests", capture=False)
        check = ROOT / "tools" / "corpus-check.py"
        if not (check.is_file() and os.environ.get("PY_SCHEMATRON_CORPUS")):
            say("  (no corpus check: set PY_SCHEMATRON_CORPUS to the folders of your documents)")
            return
        say("== the corpus check")
        result = subprocess.run([sys.executable, str(check)], cwd=ROOT)
        if result.returncode == 1 and not self.accept_corpus_changes:
            raise Failure("Results changed on the corpus (above); if that is meant, "
                          "run again with --accept-corpus-changes")
        if result.returncode not in (0, 1):
            raise Failure(f"tools/corpus-check.py failed ({result.returncode})")

    def build(self, version):
        run(sys.executable, "tools/bundle-zip.py", capture=False)


class Emacs:
    repo = "py-schematron.el"

    def version(self):
        m = re.search(r"^;; Version: (\S+)", read("py-schematron.el"), re.M)
        return m.group(1) if m else None

    def notes(self, version):
        return changelog_notes(version)

    def asset(self, version):
        return ROOT / "dist" / f"py-schematron.el-v.{version}.zip"

    def footer(self, name):
        return ("With Straight: `M-x straight-pull-package RET py-schematron`, then restart "
                f"Emacs.\n\nFile: `{name}`, the package, its copy of py-schematron.py, the "
                "README, the changelog, the tests and the trang installer.")

    @staticmethod
    def emacs():
        """An Emacs that runs in batch mode (a wrapper named emacs, say one
        that calls emacsclient, is passed over): $EMACS, or the first one."""
        candidates = [os.environ.get("EMACS")] + [
            str(Path(d) / "emacs") for d in os.environ.get("PATH", "").split(os.pathsep) if d]
        for e in filter(None, candidates):
            if not os.access(e, os.X_OK):
                continue
            env = dict(os.environ, PATH=os.pathsep.join([str(Path(e).parent), os.environ.get("PATH", "")]))
            p = subprocess.run([e, "--batch", "-Q", "--eval", "(princ emacs-version)"],
                               env=env, capture_output=True, text=True)
            if p.returncode == 0 and re.fullmatch(r"\d+(\.\d+)+", p.stdout.strip()):
                return e, env
        raise Failure("No Emacs found that runs in batch mode; name one with EMACS=...")

    def test(self):
        e, env = self.emacs()

        def tool(var, name):
            if os.environ.get(var):
                return os.environ[var]
            found = shutil.which(name) or (Path.home() / "bin" / name)
            return str(found) if Path(found).is_file() else None
        env.setdefault("PYSCH_PYTHON", sys.executable)
        for var, name in (("JING", "jing"), ("PYSCH_TRANG", "trang")):
            if (found := tool(var, name)):
                env[var] = found
        flycheck = Path.home() / ".emacs.d" / "straight" / "build" / "flycheck"
        if "FLYCHECK_DIR" not in env and flycheck.is_dir():
            env["FLYCHECK_DIR"] = str(flycheck)
        missing = [v for v in ("JING", "PYSCH_TRANG", "FLYCHECK_DIR") if v not in env]
        if missing:
            say(f"  (not set, so some tests are skipped: {', '.join(missing)})")
        run(e, "--batch", "-Q", "-L", ".", "-l", "test/py-schematron-tests.el",
            "-f", "ert-run-tests-batch-and-exit", env=env, capture=False)

    def build(self, version):
        run(sys.executable, "tools/bundle-zip.py", capture=False)


class VSCode:
    repo = "py-schematron-vscode"

    def version(self):
        return json.loads(read("package.json")).get("version")

    def notes(self, version):
        return changelog_notes(version)

    def asset(self, version):
        return ROOT / "dist" / f"validate-schematron-{version}.vsix"

    def footer(self, name):
        return ("Install it from the Visual Studio Marketplace, or with this `.vsix`: "
                f"`code --install-extension {name}`.\n\nFile: `{name}`, the extension.")

    def test(self):
        env = dict(os.environ)
        env.setdefault("VALIDATE_PYTHON", sys.executable)
        run("npm", "test", env=env, capture=False)

    def build(self, version):
        run("npm", "run", "package", capture=False)


class Odd2rng(Program):
    repo = "ODD2RNG"

    def version(self):
        m = re.search(r'^__version__\s*=\s*"([^"]+)"', read("odd2rng.py"), re.M)
        return m.group(1) if m else None

    def notes(self, version):
        return changelog_notes(version)

    def asset(self, version):
        return ROOT / "dist" / f"ODD2RNG-v.{version}.zip"

    def footer(self, name):
        return (f"File: `{name}`, the script, its installer, the tests and the documentation.")

    def test(self):
        run(sys.executable, "-m", "unittest", "discover", "-s", "tests", capture=False)


def kind():
    if (ROOT / "odd2rng.py").is_file():
        return Odd2rng()
    if (ROOT / "py-schematron.el").is_file():
        return Emacs()
    if (ROOT / "package.json").is_file():
        return VSCode()
    if (ROOT / "py-schematron.py").is_file():
        return Program()
    raise Failure(f"{ROOT} is none of the four repositories")


# ------------------------------------------------------------------ the forges

def tea_api(*args):
    """tea api against Codeberg; the JSON it answers (tea retries are ours)."""
    for attempt in range(3):
        p = subprocess.run(["tea", "api", "--login", "codeberg", *args],
                           cwd=ROOT, capture_output=True, text=True)
        try:
            return json.loads(p.stdout)
        except json.JSONDecodeError:
            if attempt == 2:
                raise Failure(f"tea api {' '.join(args)}: {(p.stderr or p.stdout).strip()}")
            time.sleep(3)


def codeberg_release(k, tag, body, asset):
    path = f"/repos/{OWNER}/{k.repo}/releases"
    rel = tea_api(f"{path}/tags/{tag}")
    if rel.get("id"):
        say(f"  Codeberg: the release {tag} exists")
    else:
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump({"tag_name": tag, "name": tag, "body": body}, f)
        try:
            rel = tea_api("-X", "POST", path, "-d", f"@{f.name}")
        finally:
            os.unlink(f.name)
        if not rel.get("id"):
            raise Failure(f"Codeberg did not make the release: {rel.get('message', rel)}"
                          + ("\n(Is the repository's Releases unit on? PATCH has_releases true.)"
                             if "release" in str(rel.get("message", "")).lower() else ""))
        say(f"  Codeberg: release {tag} made")
    if any(a.get("name") == asset.name for a in rel.get("assets") or []):
        say(f"  Codeberg: {asset.name} is attached")
    else:
        run("tea", "releases", "assets", "create", "--login", "codeberg",
            "--repo", f"{OWNER}/{k.repo}", tag, str(asset))
        say(f"  Codeberg: {asset.name} attached")


def github_release(k, tag, body, asset):
    slug = f"{OWNER}/{k.repo}"
    p = subprocess.run(["gh", "release", "view", tag, "-R", slug, "--json", "assets"],
                       cwd=ROOT, capture_output=True, text=True)
    if p.returncode != 0:
        with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False) as f:
            f.write(body)
        try:
            run("gh", "release", "create", tag, str(asset), "-R", slug, "--verify-tag",
                "--title", tag, "--notes-file", f.name)
        finally:
            os.unlink(f.name)
        say(f"  GitHub: release {tag} made, with {asset.name}")
        return
    say(f"  GitHub: the release {tag} exists")
    if any(a.get("name") == asset.name for a in json.loads(p.stdout).get("assets", [])):
        say(f"  GitHub: {asset.name} is attached")
    else:
        run("gh", "release", "upload", tag, str(asset), "-R", slug)
        say(f"  GitHub: {asset.name} attached")


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def verify(k, tag, asset):
    local = sha256(asset.read_bytes())
    for forge, host in FORGES.items():
        url = f"https://{host}/{OWNER}/{k.repo}/releases/download/{tag}/{asset.name}"
        for attempt in range(5):
            try:
                with urllib.request.urlopen(url, timeout=60) as r:
                    remote = sha256(r.read())
                break
            except OSError as e:
                if attempt == 4:
                    raise Failure(f"{forge}: could not download {url}: {e}")
                time.sleep(5)
        if remote != local:
            raise Failure(f"{forge}: {asset.name} differs from the local file "
                          f"({remote[:16]} against {local[:16]})")
        say(f"  {forge}: the download is the same file ({local[:16]})")


# ------------------------------------------------------------------ the steps

def checks(k, notes_file):
    version = k.version()
    if not version:
        raise Failure("No version found")
    tag = f"v{version}"
    branch = git("rev-parse", "--abbrev-ref", "HEAD")
    if branch != "main":
        raise Failure(f"On branch {branch}, not main")
    dirty = git("status", "--porcelain", "--untracked-files=no")
    if dirty:
        raise Failure(f"Uncommitted changes:\n{dirty}")
    head = git("rev-parse", "HEAD")
    tagged = git("rev-parse", "-q", "--verify", f"refs/tags/{tag}^{{commit}}", check=False)
    if tagged and tagged != head:
        raise Failure(f"The tag {tag} exists on another commit ({tagged[:7]}); "
                      f"is the version bumped?")
    if notes_file:
        notes = Path(notes_file).read_text(encoding="utf-8").strip()
    else:
        notes = k.notes(version)
        if not notes:
            raise Failure(f"No release notes for {version} (in "
                          f"{'README.md' if type(k) is Program else 'CHANGELOG.md'}); "
                          f"write them, or give --notes FILE")
    if isinstance(k, (Emacs, VSCode)):
        main_script = ROOT.parent / "py-schematron" / "py-schematron.py"
        if main_script.is_file():
            if main_script.read_bytes() != (ROOT / "py-schematron.py").read_bytes():
                raise Failure("This copy of py-schematron.py is not the same as "
                              f"{main_script}; run tools/sync-plugins.py there and commit")
        else:
            say(f"  (no {main_script} to compare the copy of py-schematron.py with)")
    return version, tag, bool(tagged), notes


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="tools/release.py",
        description="Test, build, tag, push and release the current version on Codeberg "
                    "and GitHub, then check the downloads.")
    parser.add_argument("--dry-run", action="store_true",
                        help="check, test and build, and say what would follow; change nothing")
    parser.add_argument("--yes", action="store_true", help="do not ask before tagging and pushing")
    parser.add_argument("--skip-tests", action="store_true", help="do not run the tests")
    parser.add_argument("--accept-corpus-changes", action="store_true",
                        help="py-schematron: go on although tools/corpus-check.py found changed results")
    parser.add_argument("--notes", metavar="FILE",
                        help="the release notes, instead of those of the changelog or README")
    args = parser.parse_args(argv)
    try:
        k = kind()
        k.accept_corpus_changes = args.accept_corpus_changes
        say(f"== {k.repo}: checks")
        version, tag, tagged, notes = checks(k, args.notes)
        say(f"  version {version}, tag {tag}" + (" (exists on this commit)" if tagged else ""))
        if args.skip_tests:
            say("== tests skipped")
        else:
            say("== tests")
            k.test()
        say("== the file")
        k.build(version)
        asset = k.asset(version)
        if not asset.is_file():
            raise Failure(f"The build did not make {asset}")
        say(f"  {asset.relative_to(ROOT)} ({asset.stat().st_size:,} bytes)")
        body = f"{notes}\n\n{k.footer(asset.name)}\n"
        if args.dry_run:
            say(f"== dry run: would tag {tag}, push main and {tag} to Codeberg and GitHub, "
                f"and release with these notes:\n")
            say(body)
            return
        if not args.yes:
            answer = input(f"Tag {tag}, push and release {k.repo} {version}? [y/N] ")
            if answer.strip().lower() not in ("y", "yes"):
                say("Stopped; nothing was tagged or pushed.")
                return
        say("== tag and push")
        if not tagged:
            git("tag", "-a", tag, "-m", tag)
            say(f"  tagged {tag}")
        for forge, host in FORGES.items():
            git("push", f"git@{host}:{OWNER}/{k.repo}.git", "main", tag)
            say(f"  {forge}: pushed main and {tag}")
        say("== releases")
        codeberg_release(k, tag, body, asset)
        github_release(k, tag, body, asset)
        say("== check the downloads")
        verify(k, tag, asset)
        say(f"== {k.repo} {version} released")
    except Failure as e:
        sys.exit(f"release.py: {e}")


if __name__ == "__main__":
    main()
