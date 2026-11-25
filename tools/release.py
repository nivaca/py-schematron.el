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
     this commit, release notes found, (in a plugin) a copy of
     py-schematron.py that is the same as ../py-schematron's, the signing
     key in gpg, and packaging/RPM-GPG-KEY-REPO, its public key;
  2. runs the tests (the unittest suites of the programs, the Emacs
     package's ERT tests, the extension's unit tests); for py-schematron,
     when $PY_SCHEMATRON_CORPUS names a corpus, also tools/corpus-check.py,
     which compares the results with the last release's on every document,
     and stops if any changed (--accept-corpus-changes, when that is meant);
  3. makes the file, and signs it with the project's key (SIGNING_KEY): a
     detached armored signature FILE.asc, and dist/SHA256SUMS with its own
     SHA256SUMS.asc; each signature is then checked as a user would check
     it, in a temporary GNUPGHOME that has only the published public key,
     and the release stops if one does not verify;
  4. tags the commit with a signed tag (git tag --sign), checks it with
     git tag --verify against the published key only, and pushes main and
     the tag to Codeberg and GitHub; an unsigned tag already there, on the
     same commit, is replaced by the signed one;
  5. makes the release on Codeberg (with tea) and on GitHub (with gh), with
     the notes, the file, the signatures, SHA256SUMS and the public key
     (and brings the notes of a release that exists up to date);
  6. downloads every file from both and compares it with the local one;
  7. collects the deposit for Zenodo in dist/zenodo/ (tools/zenodo.py
     collect: the tree of the tag, signed, with SHA256SUMS and the public
     key, each signature checked with only that key) and uploads it to
     Zenodo as a draft, with the token in $ZENODO_TOKEN, unless
     --no-zenodo.  The draft is never published here: review it and
     publish it on Zenodo by hand.

Each step that is already done is skipped (a signed tag or a release that
exists, a signature that still verifies, a file already attached), so after
a failure the script can simply be run again, and running it on a release
made before signing adds what it lacks.  --dry-run does steps 1 to 3 and
says what it would do after.  Without --yes it asks before step 4.

It needs git, gpg (with the signing key), tea (logged in as "codeberg"),
gh (logged in to GitHub) and, unless --no-zenodo, a Zenodo token in
$ZENODO_TOKEN.
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
# La clave con que se firma todo lo publicado: la misma en todos los
# proyectos del autor (la que fija packaging/build-rpm.sh en los que hacen
# un RPM).  $SIGNING_KEY la cambia solo en una prueba o un caso raro.
SIGNING_KEY = "81870643CA221AF90C30554EBE6832CD35994948"
SUMS = ROOT / "dist" / "SHA256SUMS"


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


# ------------------------------------------------------------------ the signatures

def signing_key() -> str:
    return os.environ.get("SIGNING_KEY") or SIGNING_KEY


def public_key(repo: str) -> Path:
    """The public key published with every release of REPO."""
    return ROOT / "packaging" / f"RPM-GPG-KEY-{repo}"


def key_fingerprints(public: Path) -> list[str]:
    """The fingerprints of the keys (and subkeys) in the file PUBLIC."""
    out = run("gpg", "--batch", "--show-keys", "--with-colons", str(public), cwd=ROOT)
    return [line.split(":")[9] for line in out.splitlines() if line.startswith("fpr:")]


class PublicOnly:
    """A temporary GNUPGHOME that knows only PUBLIC, as a user's would after
    importing the published key; entering gives the environment to run gpg
    (or git tag --verify) in.  Never the system's keys."""

    def __init__(self, public: Path):
        self.public = public

    def __enter__(self):
        self.dir = tempfile.TemporaryDirectory(prefix="release-gpg-")
        home = Path(self.dir.name)
        home.chmod(0o700)          # (gpg quiere su carpeta solo para el usuario)
        self.env = dict(os.environ, GNUPGHOME=str(home))
        run("gpg", "--batch", "--quiet", "--import", str(self.public), env=self.env)
        return self.env

    def __exit__(self, *exc):
        # Un GNUPGHOME nuevo arranca keyboxd o gpg-agent: se detienen antes
        # de borrar la carpeta.
        subprocess.run(["gpgconf", "--kill", "all"], env=self.env, capture_output=True)
        self.dir.cleanup()


def signature_ok(path: Path, env) -> bool:
    asc = path.with_name(path.name + ".asc")
    return asc.is_file() and subprocess.run(
        ["gpg", "--batch", "--verify", str(asc), str(path)], env=env,
        capture_output=True).returncode == 0


def sign_files(files: list[Path], key: str, public: Path, sums: Path) -> list[Path]:
    """Sign FILES and SUMS, which lists their SHA-256 as sha256sum -c reads it,
    with KEY, and check every signature with only PUBLIC known.  A signature
    that still verifies is kept, so that running again changes nothing.
    Return what is published: the files, SUMS, the signatures and PUBLIC."""
    names = [f.name for f in files]
    if len(set(names)) != len(names):     # (SHA256SUMS va por nombre)
        raise Failure("Two files to publish have the same name")
    text = "".join(f"{sha256(f.read_bytes())}  {f.name}\n" for f in files)
    if not sums.is_file() or sums.read_text(encoding="utf-8") != text:
        sums.write_text(text, encoding="utf-8")
    signed = files + [sums]
    with PublicOnly(public) as env:
        for path in signed:
            if signature_ok(path, env):
                say(f"  {path.name}.asc: kept, it verifies")
                continue
            p = subprocess.run(["gpg", "--batch", "--yes", "--local-user", key, "--armor",
                                "--detach-sign", "--output", f"{path}.asc", str(path)],
                               capture_output=True, text=True)
            if p.returncode != 0:
                raise Failure(f"gpg could not sign {path.name} with {key} (is the key's "
                              f"passphrase cached?):\n{p.stderr.strip()}")
            say(f"  {path.name}.asc: signed")
        bad = [p.name for p in signed if not signature_ok(p, env)]
    if bad:
        raise Failure(f"These do not verify with the published key {public.name}: "
                      + ", ".join(bad))
    say(f"  every signature verifies with only {public.name}")
    return signed + [p.with_name(p.name + ".asc") for p in signed] + [public]


def tag_verifies(tag: str, public: Path) -> bool:
    """Whether TAG is a signed tag that verifies with only PUBLIC known."""
    with PublicOnly(public) as env:
        return subprocess.run(["git", "tag", "--verify", tag], cwd=ROOT, env=env,
                              capture_output=True).returncode == 0


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


def codeberg_release(k, tag, body, assets):
    path = f"/repos/{OWNER}/{k.repo}/releases"
    rel = tea_api(f"{path}/tags/{tag}")
    if rel.get("id"):
        say(f"  Codeberg: the release {tag} exists")
        if (rel.get("body") or "").strip() != body.strip():
            with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
                json.dump({"body": body}, f)
            try:
                tea_api("-X", "PATCH", f"{path}/{rel['id']}", "-d", f"@{f.name}")
            finally:
                os.unlink(f.name)
            say("  Codeberg: its notes brought up to date")
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
    attached = {a.get("name") for a in rel.get("assets") or []}
    for asset in assets:
        if asset.name in attached:
            say(f"  Codeberg: {asset.name} is attached")
        else:
            run("tea", "releases", "assets", "create", "--login", "codeberg",
                "--repo", f"{OWNER}/{k.repo}", tag, str(asset))
            say(f"  Codeberg: {asset.name} attached")


def github_release(k, tag, body, assets):
    slug = f"{OWNER}/{k.repo}"
    p = subprocess.run(["gh", "release", "view", tag, "-R", slug, "--json", "assets,body"],
                       cwd=ROOT, capture_output=True, text=True)
    with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False) as f:
        f.write(body)
    try:
        if p.returncode != 0:
            run("gh", "release", "create", tag, *map(str, assets), "-R", slug, "--verify-tag",
                "--title", tag, "--notes-file", f.name)
            say(f"  GitHub: release {tag} made, with {', '.join(a.name for a in assets)}")
            return
        say(f"  GitHub: the release {tag} exists")
        rel = json.loads(p.stdout)
        if (rel.get("body") or "").strip() != body.strip():
            run("gh", "release", "edit", tag, "-R", slug, "--notes-file", f.name)
            say("  GitHub: its notes brought up to date")
    finally:
        os.unlink(f.name)
    attached = {a.get("name") for a in rel.get("assets", [])}
    for asset in assets:
        if asset.name in attached:
            say(f"  GitHub: {asset.name} is attached")
        else:
            run("gh", "release", "upload", tag, str(asset), "-R", slug)
            say(f"  GitHub: {asset.name} attached")


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def verify(k, tag, assets):
    for asset in assets:
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
            say(f"  {forge}: {asset.name} is the same file ({local[:16]})")


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
    key, public = signing_key(), public_key(k.repo)
    if subprocess.run(["gpg", "--batch", "--list-secret-keys", key],
                      capture_output=True).returncode != 0:
        raise Failure(f"The signing key {key} is not in this machine's gpg")
    if not public.is_file():
        raise Failure(f"There is no {public.relative_to(ROOT)}, the public key published "
                      f"with the release (gpg --armor --export {key} > it)")
    if key not in key_fingerprints(public):
        raise Failure(f"{public.relative_to(ROOT)} is not the public key of {key}")
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
    parser.add_argument("--no-zenodo", action="store_true",
                        help="don't upload the deposit to Zenodo (by default it goes as a draft, never "
                             "published, with the token in $ZENODO_TOKEN)")
    parser.add_argument("--notes", metavar="FILE",
                        help="the release notes, instead of those of the changelog or README")
    args = parser.parse_args(argv)
    try:
        # Sin token se para aquí, antes de hacer nada, y no al final
        if not args.no_zenodo and not args.dry_run and not os.environ.get("ZENODO_TOKEN"):
            raise Failure("the upload to Zenodo needs a token in $ZENODO_TOKEN; --no-zenodo leaves it out")
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
        say("== signatures")
        key, public = signing_key(), public_key(k.repo)
        assets = sign_files([asset], key, public, SUMS)
        fpr = " ".join(key[i:i + 4] for i in range(0, len(key), 4))
        body = (f"{notes}\n\n{k.footer(asset.name)}\n\n"
                f"Every file is signed with the project's key ({fpr}): `FILE.asc` is the "
                f"signature of `FILE`, and `SHA256SUMS`, signed too, lists their SHA-256. "
                f"To check one: `gpg --import {public.name}`, then "
                f"`gpg --verify {asset.name}.asc {asset.name}`.\n")
        if args.dry_run:
            zenodo = "collect the deposit for Zenodo" + ("" if args.no_zenodo else " and upload it as a draft")
            say(f"== dry run: would tag {tag}, push main and {tag} to Codeberg and GitHub, "
                f"release with these notes, and {zenodo}:\n")
            say(body)
            return
        if not args.yes:
            answer = input(f"Tag {tag}, push and release {k.repo} {version}? [y/N] ")
            if answer.strip().lower() not in ("y", "yes"):
                say("Stopped; nothing was tagged or pushed.")
                return
        say("== tag and push")
        if tagged and tag_verifies(tag, public):
            say(f"  {tag} is signed")
        else:
            # Una etiqueta sin firma en este mismo commit (de antes de que se
            # firmara todo) se reemplaza por una firmada.
            git("tag", "--force", "--sign", "--local-user", key, "--message", tag, tag)
            say(f"  tagged {tag}, signed" + (" (it was not)" if tagged else ""))
        if not tag_verifies(tag, public):
            raise Failure(f"git tag --verify {tag} fails with only {public.name}")
        say(f"  git tag --verify {tag}: good, with only {public.name}")
        local_tag = git("rev-parse", f"refs/tags/{tag}")
        for forge, host in FORGES.items():
            url = f"git@{host}:{OWNER}/{k.repo}.git"
            remote = git("ls-remote", url, f"refs/tags/{tag}").split("\t")[0]
            # (si la forja tiene la etiqueta vieja, sin firma, se fuerza: es el mismo commit)
            ref = f"+refs/tags/{tag}" if remote and remote != local_tag else tag
            git("push", url, "main", ref)
            say(f"  {forge}: pushed main and {tag}"
                + (" (the signed tag replaces the old one)" if ref.startswith("+") else ""))
        say("== releases")
        codeberg_release(k, tag, body, assets)
        github_release(k, tag, body, assets)
        say("== check the downloads")
        verify(k, tag, assets)
        # The deposit for Zenodo: always made, uploaded unless --no-zenodo (a draft, never published here)
        say("== Zenodo")
        zenodo = [sys.executable, str(ROOT / "tools" / "zenodo.py")]
        run(*zenodo, "collect", "--tag", tag, capture=False)
        if args.no_zenodo:
            say("  not uploaded (--no-zenodo)")
        else:
            run(*zenodo, "upload", capture=False)
        say(f"== {k.repo} {version} released")
    except Failure as e:
        sys.exit(f"release.py: {e}")


if __name__ == "__main__":
    main()
