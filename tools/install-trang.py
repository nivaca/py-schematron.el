#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Nicolas Vaughan <nicolasvaughan@proton.me>
# This file is part of py-schematron.el. See the LICENSE file for details.
"""Descarga e instala trang: python3 tools/install-trang.py [--bin FOLDER]
[--version VERSION] [--force | --uninstall]

trang convierte los esquemas RelaxNG entre su sintaxis XML (.rng) y su
sintaxis compacta (.rnc).  Este paquete de Emacs lo usa para darle a nxml-mode
el esquema del documento, que nxml solo lee en la sintaxis compacta.  Es un
programa en Java, del proyecto jing-trang
(https://github.com/relaxng/jing-trang), del autor de jing.

El script descarga el zip de la versión desde GitHub, lo comprueba con el
SHA-1 publicado con él (y, en la versión por omisión, con el que está escrito
más abajo) y lo instala como suele instalarse jing:

    ~/bin/trang.d/   trang.jar, su manual y su licencia
    ~/bin/trang      un pequeño script de shell: exec java -jar .../trang.jar "$@"

Eso, si existe ~/bin.  Si no, los archivos van a ~/.local/share/trang/ y el
script a ~/.local/bin/trang.  --bin FOLDER instala en FOLDER (FOLDER/trang y
FOLDER/trang.d/).

Desde entonces `trang` corre desde cualquier parte, si su carpeta está en el
PATH, y el paquete de Emacs lo encuentra con su ajuste por omisión.  Al final
convierte un esquema diminuto, para comprobar que funciona.  Hace falta Java
(sirve el que use jing).

Un ~/bin/trang que ya exista y que no haya escrito este script se deja en paz,
salvo con --force.  --uninstall borra el script y la carpeta, si son de este
script.  Todo va a las carpetas del propio usuario: no hacen falta permisos de
administrador.
"""

import sys

if sys.version_info < (3, 15):
    sys.exit(f"install-trang.py needs Python 3.15 or later; this is "
             f"Python {sys.version.split()[0]}.")

import argparse  # noqa: E402
import hashlib  # noqa: E402
import os  # noqa: E402
import shutil  # noqa: E402
import subprocess  # noqa: E402
import tempfile  # noqa: E402
import urllib.request  # noqa: E402
import zipfile  # noqa: E402
from pathlib import Path  # noqa: E402

VERSION = "20241231"
SHA1 = {"20241231": "48462bc93cdc5bb5ea1014d37244a6b603d6f6ba"}   # trang-VERSION.zip
URL = "https://github.com/relaxng/jing-trang/releases/download/V{v}/trang-{v}.zip"
FILES = ("trang.jar", "trang-manual.html", "copying.txt")
MARK = "# installed by py-schematron's tools/install-trang.py"
OLD_MARKS = ("# installed by py-xmlvalidate's tools/install-trang.py",)   # (until 0.7.0)


def say(text: str = ""):
    print(text, flush=True)


def fetch(url: str) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": "install-trang.py"})
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return response.read()
    except OSError as e:
        sys.exit(f"Could not download {url}: {e}")


def ours(wrapper: Path) -> bool:
    try:
        text = wrapper.read_text(encoding="utf-8", errors="replace")
        return any(m in text for m in (MARK, *OLD_MARKS))
    except OSError:
        return False


def locations(folder: Path | None) -> tuple[Path, Path]:
    """Where the script and the files go: (FOLDER/trang, FOLDER/trang.d)
    with --bin, or in ~/bin if it exists, or else ~/.local/bin/trang and
    ~/.local/share/trang."""
    if folder is None and (Path.home() / "bin").is_dir():
        folder = Path.home() / "bin"
    if folder is not None:
        return folder / "trang", folder / "trang.d"
    local = Path.home() / ".local"
    return local / "bin" / "trang", local / "share" / "trang"


def install(wrapper: Path, home: Path, version: str, force: bool):
    java = shutil.which("java")
    if not java:
        sys.exit("There is no java on the PATH; trang needs Java (e.g. sudo dnf install java).")
    if (wrapper.exists() or wrapper.is_symlink()) and not ours(wrapper) and not force:
        sys.exit(f"{wrapper} exists and was not written by this script: left alone "
                 f"(--force replaces it).")

    url = URL.format(v=version)
    say(f"Downloading {url}")
    data = fetch(url)
    published = fetch(url + ".sha1").decode("ascii", "replace").split()[0].lower()
    actual = hashlib.sha1(data).hexdigest()
    if actual != published or (version in SHA1 and actual != SHA1[version]):
        sys.exit(f"The download does not match its checksum (SHA-1 {actual}, expected "
                 f"{SHA1.get(version, published)}): nothing installed.")
    say(f"  {len(data) // 1024} KB, SHA-1 {actual}: matches")

    with tempfile.TemporaryDirectory(prefix="install-trang-") as tmp:
        zpath = Path(tmp) / "trang.zip"
        zpath.write_bytes(data)
        with zipfile.ZipFile(zpath) as z:
            new = Path(tmp) / "trang.d"
            new.mkdir()
            for name in FILES:                      # (only these, by exact name)
                member = f"trang-{version}/{name}"
                try:
                    (new / name).write_bytes(z.read(member))
                except KeyError:
                    sys.exit(f"The zip has no {member}: nothing installed.")
        wrapper.parent.mkdir(parents=True, exist_ok=True)
        home.parent.mkdir(parents=True, exist_ok=True)
        if home.exists():
            shutil.rmtree(home)
        shutil.copytree(new, home)
    wrapper.unlink(missing_ok=True)
    wrapper.write_text(f'#!/bin/sh\n{MARK} (trang {version})\n'
                       f'exec java -jar "{home / "trang.jar"}" "$@"\n', encoding="utf-8")
    wrapper.chmod(0o755)
    say(f"  {home}/: {', '.join(FILES)}")
    say(f"  {wrapper}: runs java -jar {home / 'trang.jar'}")
    check(wrapper)


def check(wrapper: Path):
    """Convert a tiny schema, to show that trang runs."""
    with tempfile.TemporaryDirectory(prefix="install-trang-") as tmp:
        rng, rnc = Path(tmp) / "t.rng", Path(tmp) / "t.rnc"
        rng.write_text('<element name="doc" xmlns="http://relaxng.org/ns/structure/1.0">'
                       '<text/></element>\n', encoding="utf-8")
        r = subprocess.run([str(wrapper), "-I", "rng", "-O", "rnc", str(rng), str(rnc)],
                           capture_output=True, text=True)
        if r.returncode == 0 and rnc.is_file() and "element doc" in rnc.read_text():
            say("\ntrang works: it converted a test schema.")
        else:
            say(f"\nNote: trang was installed but the test conversion failed:\n"
                f"{(r.stderr or r.stdout).strip()}")
    dirs = [Path(p).resolve() for p in os.environ.get("PATH", "").split(os.pathsep) if p]
    if wrapper.parent.resolve() not in dirs:
        say(f"Note: {wrapper.parent} is not on your PATH; add it, or give the Emacs "
            f"package the full name ({wrapper}) in py-schematron-trang.")


def uninstall(wrapper: Path, home: Path):
    if wrapper.exists() and not ours(wrapper):
        say(f"  {wrapper} was not written by this script: left alone")
        return
    if wrapper.exists():
        wrapper.unlink()
        say(f"  removed {wrapper}")
    if (home / "trang.jar").exists():
        shutil.rmtree(home)
        say(f"  removed {home}")


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="tools/install-trang.py",
        description="Download trang from the jing-trang releases and install it in ~/bin.")
    parser.add_argument("--bin", type=Path, default=None, metavar="FOLDER",
                        help="where to install (default: ~/bin if it exists, else "
                             "~/.local/bin and ~/.local/share/trang)")
    parser.add_argument("--version", default=VERSION,
                        help=f"the release to install (default: {VERSION})")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--force", action="store_true",
                       help="replace an existing trang that this script did not write")
    group.add_argument("--uninstall", action="store_true",
                       help="remove the trang this script installed")
    args = parser.parse_args(argv)
    wrapper, home = locations(args.bin.expanduser() if args.bin else None)
    if args.uninstall:
        say(f"Removing trang ({wrapper}, {home}):")
        uninstall(wrapper, home)
    else:
        install(wrapper, home, args.version, args.force)


if __name__ == "__main__":
    main()
