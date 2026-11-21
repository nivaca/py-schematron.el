Open-source software used by py-schematron.el
=============================================

py-schematron.el is free software, under the GNU General Public License,
version 3 or later (GPL-3.0-or-later).  The package is made of its own
files only: `py-schematron.el` and a copy of `py-schematron.py`, from
[py-schematron](https://github.com/nivaca/py-schematron), by the same
author and under the same licence.  None of the programs below is copied
into this repository or into the release zip; each is installed separately
and keeps its own licence.

What the package runs with
--------------------------

| Software | What it is used for | Licence |
|---|---|---|
| [GNU Emacs](https://www.gnu.org/software/emacs/) 31.1 or later, with the libraries it includes (Flymake, nxml-mode, `xsd-regexp`, `rng-xsd`, `compile`, `xref`, `cl-lib`, `seq`, `lisp-mnt`) | The editor, and the Flymake backend, the nxml schema and the rest of the package | GPL-3.0-or-later |
| [Flycheck](https://www.flycheck.org/) (optional) | The checker used instead of Flymake when Flycheck is installed | GPL-3.0-or-later |
| [Python](https://www.python.org/) 3.15 or later, with its standard library | Runs `py-schematron.py` | Python Software Foundation License (PSF-2.0) |
| [saxonche](https://pypi.org/project/saxonche/) (SaxonC-HE, by Saxonica) | Evaluates the Schematron rules with XPath 3.1, in `py-schematron.py` | Mozilla Public License 2.0 (MPL-2.0) |
| [lxml](https://lxml.de/) | Finds the line and the `xml:id` of each offence, in `py-schematron.py` | BSD-3-Clause |
| [libxml2](https://gitlab.gnome.org/GNOME/libxml2) and [libxslt](https://gitlab.gnome.org/GNOME/libxslt) | The C libraries under lxml (included in its wheels) | MIT |
| [jing](https://relaxng.org/jclark/jing.html), by James Clark (optional) | Checks the RelaxNG structure | BSD-3-Clause (Thai Open Source Software Center) |
| [trang](https://relaxng.org/jclark/trang.html), by James Clark (optional) | Converts the RelaxNG schema to the compact syntax for nxml (`py-schematron-nxml-schema`); `tools/install-trang.py` downloads it from the [jing-trang](https://github.com/relaxng/jing-trang) project | BSD-3-Clause (Thai Open Source Software Center) |
| A Java runtime, such as [OpenJDK](https://openjdk.org/) (only with jing or trang) | Runs jing and trang | GPL-2.0 with the Classpath Exception (OpenJDK) |
| [TEI Stylesheets](https://github.com/TEIC/Stylesheets): `odds/extract-isosch.xsl` and `common/functions.xsl` (only for ODD schemas) | Extract the Schematron rules of an ODD, in `py-schematron.py`.  They are not distributed with the package | Dual licence: BSD-2-Clause or Creative Commons Attribution-ShareAlike 3.0 (CC-BY-SA-3.0), at the user's choice |

The jing distributed by its project (a `jing.jar`, as on Windows) carries
some libraries of its own, such as Xerces and Saxon 9; their licences are
in the `doc/` folder of that distribution.

What is used to develop and test it
-----------------------------------

These are not needed to use the package, and none of them is distributed
with it.

| Software | What it is used for | Licence |
|---|---|---|
| ERT (part of GNU Emacs) | The tests in `test/py-schematron-tests.el` | GPL-3.0-or-later |
| [package-lint](https://github.com/purcell/package-lint) | Checks the package headers and conventions, in the tests on GitHub | GPL-3.0-or-later |
| [GitHub Actions](https://github.com/features/actions): `actions/checkout`, `actions/setup-python`, [`purcell/setup-emacs`](https://github.com/purcell/setup-emacs) | Run the tests on Linux, macOS and Windows | MIT |
