# py-schematron for Emacs

Checks XML documents, TEI editions in particular, against the Schematron
rules of their schema, with `py-schematron.py`, the program of
[py-schematron](https://codeberg.org/nivaca/py-schematron) (the package
carries its own copy; see [The copy of
py-schematron.py](#the-copy-of-py-schematronpy)), and shows the
problems with Flycheck when it is installed, or with Flymake, which comes
with Emacs. When the schema is a RelaxNG file, it also checks the structure
with jing, and gives the schema to nxml-mode, so that completion offers what
the schema allows. It needs Emacs 31 or later, and nothing from outside
Emacs except Python (trang is optional, for nxml's schema).

- **When:** as you type (when typing pauses), on opening and on saving,
  for every buffer with an `<?xml-model?>`. Unsaved changes are checked
  from a private temporary copy; your file is never written.
- **What you see:** each problem underlined, with its message when the
  cursor is on it; its layer (**Schematron**, **RelaxNG**, or **XML** when
  the document is not well formed) and, for Schematron, the pattern's id.
  A misspelt element is also flagged where it was opened. The mode line
  shows the counts.
- **All of them:** Flycheck's `C-c ! l`, or `M-x
  flymake-show-buffer-diagnostics`. `M-x py-schematron-report` shows the
  full text report of the saved file, with each line linked to the
  document.
- **Completion:** in nxml-mode, `C-RET` offers the elements and attributes
  the document's schema allows where the cursor is (see [The schema for
  nxml](#the-schema-for-nxml)).

## Before you start

The package runs `py-schematron.py`, a Python program, and it needs
**Python 3.15 or later with two libraries, `saxonche` and `lxml`.**
Emacs does not install them for you.

1. **Python.** In a terminal, `python3 --version` should print 3.15 or
   higher. If it does not, install Python from your system's packages
   (`sudo dnf install python3.15`, `sudo apt install python3.15
   python3.15-venv`) or from <https://www.python.org/downloads/>.

2. **The libraries,** with py-schematron's installer, which makes a Python
   environment of its own with saxonche and lxml, in your user folders:

   ```sh
   curl -LsSf https://raw.githubusercontent.com/nivaca/py-schematron/main/installers/install.sh | sh
   ```

   On Windows, in PowerShell:
   `powershell -ExecutionPolicy ByPass -c "irm https://raw.githubusercontent.com/nivaca/py-schematron/main/installers/install.ps1 | iex"`.
   While `py-schematron-python` is nil, its default, the package uses that
   environment's Python by itself, so there is nothing to set.
   py-schematron's
   [README](https://codeberg.org/nivaca/py-schematron#21-with-the-installer-linux-macos-windows)
   explains the installer in detail.

   Or, to manage the Python yourself, a virtual environment of your own
   (recent systems refuse `pip install` outside one):

   ```sh
   python3 -m venv ~/.venvs/schematron
   ~/.venvs/schematron/bin/pip install saxonche lxml
   ```

   and then `(setopt py-schematron-python "~/.venvs/schematron/bin/python")`.

3. **jing** (optional) for the RelaxNG check: `sudo dnf install jing`,
   `sudo apt install jing`, or <https://relaxng.org/jclark/jing.html>.
   Without it, only the Schematron rules are checked.

4. **trang** (optional) to give nxml the schema; it needs Java. From this
   repository's folder (Straight's clone is in
   `~/.emacs.d/straight/repos/py-schematron.el`),

   ```sh
   python3 tools/install-trang.py
   ```

   downloads it from the
   [jing-trang releases](https://github.com/relaxng/jing-trang/releases),
   checks its SHA-1 and installs it as `trang`, the name the package looks
   for: in `~/bin` if that folder exists, otherwise in `~/.local/bin` (with
   its files in `~/.local/share/trang`); `--bin FOLDER` chooses another
   folder. On Debian and Ubuntu,
   `sudo apt install trang` also works. See
   [The schema for nxml](#the-schema-for-nxml).

## Installation

Any of these installs the package from Codeberg (or GitHub, with its URL).
Each clones this repository, which includes the package's copy of
`py-schematron.py`, so updating the package updates the script too.

### With package-vc (built into Emacs)

In your init file:

```elisp
(package-vc-install
 '(py-schematron :url "https://codeberg.org/nivaca/py-schematron.el"))
```

or, with `use-package`:

```elisp
(use-package py-schematron
  :vc (:url "https://codeberg.org/nivaca/py-schematron.el")
  :hook (nxml-mode . py-schematron-mode))
```

use-package installs the latest release; `package-vc-install`, the latest
commit. `M-x package-vc-upgrade` updates the package.

### With Straight

With `use-package`:

```elisp
(use-package py-schematron
  :straight (:host codeberg :repo "nivaca/py-schematron.el")
  :hook (nxml-mode . py-schematron-mode))
```

or without it:

```elisp
(straight-use-package
 '(py-schematron :host codeberg :repo "nivaca/py-schematron.el"))
(add-hook 'nxml-mode-hook #'py-schematron-mode)
```

Straight builds the package from links to its clone (the tests in `test/`
are left out), and the package follows the link back to the clone to find
its `py-schematron.py`. `M-x straight-pull-package RET py-schematron`
updates it. From GitHub, use `:host github`.

### Moving from py-xmlvalidate

Until 0.7.0 the package was called py-xmlvalidate, in the repository
py-xmlvalidate-emacs (and until 0.2.0 in the `emacs/` folder of the
program's repository, then called py-xmlvalidate too). Change the recipe
to one of the above. The former names of the options and commands
(`py-xmlvalidate-…`) keep working for now as obsolete aliases, and
`(require 'py-xmlvalidate)` still loads the package, so an older
configuration works meanwhile, with warnings. With Straight, the old
clones `~/.emacs.d/straight/repos/py-xmlvalidate-emacs` and
`~/.emacs.d/straight/repos/py-xmlvalidate` can then be deleted, and so
can the old cache of nxml's schemas, `~/.emacs.d/py-xmlvalidate/`.

### From a clone

If you already have a clone of the repository:

```elisp
(add-to-list 'load-path "/path/to/py-schematron.el")
(require 'py-schematron)
```

## Setup

Two lines, if you did not use a `use-package` form above:

```elisp
(add-hook 'nxml-mode-hook #'py-schematron-mode)
(setopt trusted-content '("~/Dropbox/docs/editions/"))   ; your folders
```

and, if you set up Python yourself rather than with the installer,
`(setopt py-schematron-python "~/.venvs/schematron/bin/python")`.

**Why `trusted-content`.** Since Emacs 30, Flymake checks only the files
you trust, and this package follows that rule, with Flycheck too (which
has no such rule of its own). A document's
`<?xml-model?>` chooses the schema, and the schema's rules are XPath that
Saxon runs: they can read files on your computer and fetch URLs. So an XML
file from elsewhere is not checked until you put it, or its folder, in
`trusted-content`. Folder names end in `/`.

When you open a file that is not trusted, a warning in the `*Warnings*`
buffer says so, once per file, with the line to add to your init file.
`M-x py-schematron-trust-file` trusts it on request: it asks whether to
trust the file alone or its whole folder, adds it to `trusted-content` for
the session, starts checking, and puts the line that keeps it in the kill
ring, ready to paste into your init file. Trust single files rather than
folders like `~/Downloads/`, where files from elsewhere arrive. Until a
file is trusted, `py-schematron-check` and `py-schematron-refresh-schema`
say why they cannot run, and `py-schematron-report` (which runs, since
you asked for it) ends with the same note.

Then `M-x py-schematron-check-setup` says whether Python, its libraries,
the script and jing are in place.

## Flycheck or Flymake

With `py-schematron-frontend` set to `auto` (the default), the package
uses Flycheck when it is installed, and Flymake otherwise; `flycheck` or
`flymake` chooses one. With Flycheck, the package selects its own checker
in the buffer (`flycheck-checker`), turns Flycheck on if it was off (and off
again when `py-schematron-mode` is turned off), and the problems appear in
Flycheck's usual display: the error list on `C-c ! l`, the fringe, and
flycheck-posframe or flycheck-inline if you use them. Flycheck's message
starts with the layer (`Schematron:`, `RelaxNG:`, `XML:`), and the
Schematron pattern is the error's id.

## The schema for nxml

nxml-mode has its own RelaxNG validation and completion, but it does not
read `<?xml-model?>`: without a schema of its own it uses a "vacuous" one
that allows anything, so `C-RET` offers nothing. After each check whose
schema is RelaxNG, this package gives nxml that schema:

- it converts it to the compact syntax nxml reads, with trang, and keeps the
  result in `~/.emacs.d/py-schematron/rnc/`; it converts again only when
  the RelaxNG file changes, so other documents with the same schema get it
  at once;
- it sets it as the buffer's schema without saving its location (nxml's
  own command would offer to write a `schemas.xml` next to the document);
- it never replaces a schema you gave nxml yourself (with
  `M-x rng-set-schema-file` or through `schemas.xml`), and takes its own
  back when `py-schematron-mode` is turned off.

Then `C-RET` completes element and attribute names from the schema, and
`rng-validate-mode`, if it is on, checks the structure at once, with no
program to run.

When the RelaxNG file changes (for example after you regenerate it from
the ODD), the next check converts it again, and every open buffer that
uses it loads the new copy. `M-x py-schematron-recreate-nxml-schema`
does the same at once, without waiting for a change: it converts the
document's schema again, with a new check, and reloads it in every buffer
that uses it. Use it if the cached copy seems wrong, or after changing
`py-schematron-trang`.

The package also mends three bugs in nxml's XSD datatypes, which make
nxml reject values that the schema allows and jing accepts:

- When nxml builds a Unicode category from its parts (`\p{P}` from `Pc`,
  `Pd` … `Po`), it damages its cached table of the last part, so after the
  first pattern that uses `\p{P}`, `\p{S}` or `\p{C}`, nxml rejects `#`,
  `%`, `!`, `@`, `¿` and more, as in `ed="#U2"` with TEI's
  `teidata.word`.
- nxml's Unicode categories are those of Unicode 3.1 (2001), and leave out
  every character beyond U+FFFF and from U+3400 to U+DFFF. So it rejects
  letters added since, such as the medieval abbreviations `ꝑ` and `ꝯ`,
  and CJK, Gothic and the rest, in TEI's `teidata.name` and
  `teidata.word`. The package rebuilds the categories from Emacs's own
  Unicode data, with caches, so that nxml is no slower (a little faster,
  in fact, on the largest editions).
- Values of `xsd:token` and similar types keep one space at either end
  when their whitespace is collapsed, so `ed=" #U2"` fails `teidata.word`.

Each bug is checked for in the running Emacs, as soon as nxml loads its
XSD code, and mended only if it is there, so an Emacs where it is fixed
is left alone. `M-x py-schematron-about` says what was mended, and
`py-schematron-fix-nxml` set to nil turns all this off. Unloading the
package removes its advice. On 200 TEI editions, nxml mended in this way
agrees with jing on every document. The bugs are reported to Emacs as
[bug#82281](https://debbugs.gnu.org/82281) (the damaged tables),
[bug#82282](https://debbugs.gnu.org/82282) (the old categories) and
[bug#82284](https://debbugs.gnu.org/82284) (the whitespace); a fourth,
[bug#82283](https://debbugs.gnu.org/82283), a class subtraction such as
`[a-z-[aeiou]]` that nxml refuses and then lets anything through, is not
mended here, since TEI schemas do not use it.

The converter is `py-schematron-trang`: `"trang"` (what
`tools/install-trang.py` installs), or a command line as a list, for
example the copy inside oXygen:

```elisp
(setopt py-schematron-trang
        '("java" "-cp" "~/bin/oxygen/lib/oxygen-patched-trang.jar"
          "com.thaiopensource.relaxng.translate.Driver"))
```

Without trang, the package says so once and nxml keeps its vacuous schema;
nothing else changes. `py-schematron-nxml-schema` set to `nil` turns the
feature off.

## Commands

| Command | What it does |
|---|---|
| `py-schematron-mode` | Turns the checking on or off in the buffer |
| `py-schematron-check` | Checks the buffer now |
| `py-schematron-refresh-schema` | Downloads the document's remote schema again (after it changed upstream), then checks |
| `py-schematron-recreate-nxml-schema` | Converts the document's schema for nxml again (with trang) and reloads it in every buffer that uses it |
| `py-schematron-report` | Full report of the saved file, in a buffer with links to the lines |
| `py-schematron-trust-file` | Trusts the file, or its folder, after asking; starts checking it |
| `py-schematron-check-setup` | Says whether Python, saxonche, lxml, the script, jing and trang are found, and which checker is used |
| `py-schematron-goto-rule` | Open the schema at the rule behind the Schematron error on this line: the assert or report, in the ODD or RelaxNG you edit (`M-,` returns). Worth a key in `nxml-mode-map` |
| `py-schematron-about` | What the package is: its version, author, licence and links, and what its `py-schematron.py` says of itself (`--about`) |
| `py-schematron-show-log` | What `py-schematron.py` and jing printed (schema detection, downloads, cache) |

## Settings

`M-x customize-group RET py-schematron`. `trusted-content` still has to
be set (see [Setup](#setup)), whichever way the package was installed.

The settings:

| Variable | Default | Meaning |
|---|---|---|
| `py-schematron-python` | `nil` | Python with saxonche and lxml; may start with `~`. nil: the one py-schematron's installer made, if it is installed, or else `"python3"` |
| `py-schematron-script` | `nil` | `py-schematron.py` to run; `nil` is the package's own copy |
| `py-schematron-schema` | `nil` | Schema to use instead of the `<?xml-model?>`; relative to the document |
| `py-schematron-schema-type` | `rng` | Its type: `rng`, `sch` or `odd` |
| `py-schematron-relaxng` | `t` | Also check the structure with jing, when the schema is RelaxNG |
| `py-schematron-jing` | `"jing"` | The jing program |
| `py-schematron-timeout` | `120` | Seconds after which a check is abandoned |
| `py-schematron-live-max-size` | `nil` | Larger buffers (in characters) are checked on opening and saving only |
| `py-schematron-frontend` | `auto` | `flycheck`, `flymake`, or `auto` (Flycheck if installed) |
| `py-schematron-nxml-schema` | `t` | Give nxml-mode the document's RelaxNG schema, for completion |
| `py-schematron-fix-nxml` | `t` | Mend nxml's XSD datatypes where the running Emacs needs it (see above) |
| `py-schematron-trang` | `"trang"` | The trang converter: a program, or a command line as a list |

`py-schematron-schema` and `py-schematron-schema-type` are safe as
file-local or directory-local variables, for documents without an
`<?xml-model?>`:

```elisp
;; .dir-locals.el
((nxml-mode . ((py-schematron-schema . "schema/smed-schema.rng"))))
```

How quickly the problems appear is Flycheck's `flycheck-idle-change-delay`,
or Flymake's `flymake-no-changes-timeout` (half a second of no typing by
default).

## Speed

Starting the check costs little (Python with its libraries loads in about
15 ms); the time goes into the rules. A small document is checked in a
tenth of a second; a 26,000-line edition, in about two seconds (with
py-schematron.py 1.16 or later; the package carries 1.17). While a check
runs, Flymake's mode-line indicator says so, and typing again cancels it
and starts a new one, so nothing piles up. For very large files you may
prefer `py-schematron-live-max-size`.

## The copy of py-schematron.py

The package carries its own copy of `py-schematron.py`, next to
`py-schematron.el`, so that installing the package is all that is needed.
The program itself is developed in
[py-schematron](https://codeberg.org/nivaca/py-schematron), whose
`tools/sync-plugins.py` copies each new version here; a release of this
package says which version of the program it carries
([CHANGELOG.md](CHANGELOG.md)). To use another copy, for example a clone
of py-schematron, set `py-schematron-script` to its `py-schematron.py`.

## Tests

From this repository's top folder:

```sh
PYSCH_PYTHON=~/.venvs/schematron/bin/python JING=jing \
  FLYCHECK_DIR=~/.emacs.d/straight/build/flycheck PYSCH_TRANG=trang \
  emacs --batch -Q -L . -l test/py-schematron-tests.el \
  -f ert-run-tests-batch-and-exit
```

Without `PYSCH_PYTHON`, only the tests that read the programs' output run;
without `FLYCHECK_DIR` (a folder with `flycheck.el`), the Flycheck tests are
skipped, and without `PYSCH_TRANG` (trang's command line), the nxml ones.

## Releases

`python3 tools/bundle-zip.py` makes `dist/py-schematron.el-v.VERSION.zip`
(the version in `py-schematron.el`) from the files git tracks. Each
release, on [Codeberg](https://codeberg.org/nivaca/py-schematron.el/releases)
and [GitHub](https://github.com/nivaca/py-schematron.el/releases), is
tagged `vVERSION` and has that zip attached; [CHANGELOG.md](CHANGELOG.md)
lists them.

## License

Copyright (C) 2026 Nicolas Vaughan <nicolasvaughan@proton.me>

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
PARTICULAR PURPOSE. See the [GNU General Public License](LICENSE) for more
details.
