#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Nicolas Vaughan <nicolasvaughan@proton.me>
# This file is part of py-schematron.el. See the LICENSE file for details.
"""Hace el zip de la versión en build/release/: python3 tools/bundle-zip.py

build/release/py-schematron.el-v.VERSION.zip (el ;; Version: de
py-schematron.el), con el paquete en una carpeta del mismo nombre:
py-schematron.el, su copia de py-schematron.py, el README, el registro de
cambios, la licencia, las pruebas y tools/install-trang.py.  Se hace con los
archivos que git sigue, así que no entra nada que solo exista en esta carpeta
(archivos compilados, cachés, archivos de bloqueo del editor...).  Quedan fuera
también este script, tools/release.py y tools/zenodo.py, que no son parte del
paquete, packaging/ (la clave pública que firma las versiones) y los archivos
ocultos.  Los scripts conservan su permiso de ejecución.

build/release se crea en la carpeta del programa si hace falta (tools/release.py
lo publica desde allí y lo borra al final; dist/ no se usa); --output da otra
carpeta.  Si alguno de los archivos del zip tiene cambios que aún no están en un
commit, lo advierte, porque el zip toma los archivos tal como están ahora.
"""

import argparse
import os
import re
import subprocess
import sys
import zipfile

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # (above tools/)
DIST = os.path.join(HERE, "build", "release")  # (not dist/: see tools/release.py)
NAME = "py-schematron.el"

#  What is in the repository but not part of the program
NOT_PART = ("tools/bundle-zip.py", "tools/release.py", "tools/zenodo.py", "packaging/")


def version() -> str:
    """The ;; Version: header of py-schematron.el."""
    with open(os.path.join(HERE, "py-schematron.el"), encoding="utf-8") as f:
        m = re.search(r'^;; Version:\s*(\S+)', f.read(), re.M)
    if not m:
        sys.exit("bundle-zip.py: no ;; Version: in py-schematron.el")
    return m.group(1)


def name() -> str:
    """The name of the zip, without .zip: py-schematron.el-v.0.3.0."""
    return f"{NAME}-v.{version()}"


def git(*args: str) -> str:
    return subprocess.run(["git", *args], cwd=HERE, capture_output=True, text=True, check=True).stdout


def files() -> list[str]:
    """The files of the distribution, relative to the program's folder."""
    out = []
    for f in git("-c", "core.quotePath=false", "ls-files", "-z").split("\0"):
        if not f or f.startswith(NOT_PART) or any(p.startswith(".") for p in f.split("/")):
            continue
        if os.path.isfile(os.path.join(HERE, f)):  # (tracked but deleted: left out)
            out.append(f)
    return sorted(out)


def uncommitted(paths: list[str]) -> list[str]:
    status = git("-c", "core.quotePath=false", "status", "--porcelain", "--", *paths)
    return [line[3:] for line in status.splitlines()]


def bundle_zip(folder: str) -> str:
    """Writes the zip into FOLDER; returns its path."""
    path = os.path.join(folder, name() + ".zip")
    tmp = path + ".tmp"
    with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as z:
        for f in files():
            src = os.path.join(HERE, f)
            info = zipfile.ZipInfo.from_file(src, name() + "/" + f)
            #  (ordinary permissions, whatever this folder has: rw-r--r--, or
            #  rwxr-xr-x for what can be run, as the scripts)
            mode = 0o755 if os.access(src, os.X_OK) else 0o644
            info.external_attr = (0o100000 | mode) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            with open(src, "rb") as data:
                z.writestr(info, data.read())
    os.replace(tmp, path)
    return path


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="tools/bundle-zip.py",
        description=f"Make the release bundle: {name()}.zip.")
    parser.add_argument("-o", "--output", metavar="FOLDER", default=None,
                        help="the folder to write it in (default: build/release, in the program's folder)")
    parser.add_argument("-l", "--list", action="store_true",
                        help="only list the files the zip would have")
    args = parser.parse_args(argv)
    if args.list:
        print("\n".join(files()))
        return
    if args.output is None:
        args.output = DIST
        os.makedirs(DIST, exist_ok=True)
    elif not os.path.isdir(args.output):
        sys.exit(f"bundle-zip.py: there is no folder {args.output}")
    changed = uncommitted(files())
    if changed:
        print("Note: not committed yet, bundled as they are now: " + ", ".join(changed))
    try:
        path = bundle_zip(args.output)
    except OSError as e:
        sys.exit(f"bundle-zip.py: {e}")
    with zipfile.ZipFile(path) as z:
        count = len(z.namelist())
    print(f"Wrote {path} ({count} files, {os.path.getsize(path) / 1e3:.0f} kB).")


if __name__ == "__main__":
    main()
