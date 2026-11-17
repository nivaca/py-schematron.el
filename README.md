# py-xmlvalidate for Emacs

Checks XML documents, TEI editions in particular, against the Schematron
rules of their schema, with `py-xmlvalidate.py`, the program of
[py-xmlvalidate](https://codeberg.org/nivaca/py-xmlvalidate), and shows the
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
  flymake-show-buffer-diagnostics`. `M-x py-xmlvalidate-report` shows the
  full text report of the saved file, with each line linked to the
  document.
- **Completion:** in nxml-mode, `C-RET` offers the elements and attributes
  the document's schema allows where the cursor is (see [The schema for
  nxml](#the-schema-for-nxml)).

## Before you start

The package runs `py-xmlvalidate.py`, a Python program, and it needs
**Python 3.15 or later with two libraries, `saxonche` and `lxml`.**
Emacs does not install them for you.

1. **Python.** In a terminal, `python3 --version` should print 3.15 or
   higher. If it does not, install Python from your system's packages
   (`sudo dnf install python3`, `sudo apt install python3 python3-venv`)
   or from <https://www.python.org/downloads/>.

2. **The libraries,** in a virtual environment of their own (recent
   systems refuse `pip install` outside one):

   ```sh
   python3 -m venv ~/.venvs/schematron
   ~/.venvs/schematron/bin/pip install saxonche lxml
   ```

   On Windows: `py -m venv %USERPROFILE%\.venvs\schematron`, then
   `%USERPROFILE%\.venvs\schematron\Scripts\pip install saxonche lxml`.

3. **jing** (optional) for the RelaxNG check: `sudo dnf install jing`,
   `sudo apt install jing`, or <https://relaxng.org/jclark/jing.html>.
   Without it, only the Schematron rules are checked.

4. **trang** (optional) to give nxml the schema; it needs Java. From the
   repository's folder (Straight's clone is in
   `~/.emacs.d/straight/repos/py-xmlvalidate`),

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
Each clones the whole repository, and the package uses that clone's own
`py-xmlvalidate.py`, so updating the package updates the script too.

### With package-vc (built into Emacs)

In your init file:

```elisp
(package-vc-install
 '(py-xmlvalidate :url "https://codeberg.org/nivaca/py-xmlvalidate"
                  :lisp-dir "emacs"))
```

or, with `use-package`:

```elisp
(use-package py-xmlvalidate
  :vc (:url "https://codeberg.org/nivaca/py-xmlvalidate" :lisp-dir "emacs"
       :rev :newest)
  :hook (nxml-mode . py-xmlvalidate-mode)
  :custom
  (py-xmlvalidate-python "~/.venvs/schematron/bin/python"))
```

(`:rev :newest` follows the latest commit, as `package-vc-install` does;
with use-package's default, the last release, Emacs 31.1.90 fails to find
the package's main file.) `M-x package-vc-upgrade` updates the package.

### With Straight

With `use-package`:

```elisp
(use-package py-xmlvalidate
  :straight (:host codeberg :repo "nivaca/py-xmlvalidate"
             :files ("emacs/*.el"))
  :hook (nxml-mode . py-xmlvalidate-mode)
  :custom
  (py-xmlvalidate-python "~/.venvs/schematron/bin/python"))
```

or without it:

```elisp
(straight-use-package
 '(py-xmlvalidate :host codeberg :repo "nivaca/py-xmlvalidate"
                  :files ("emacs/*.el")))
(add-hook 'nxml-mode-hook #'py-xmlvalidate-mode)
```

`:files` is needed because the Lisp file is in `emacs/`, not at the top
of the repository; it leaves the tests (`emacs/test/`) out of the build.
Straight builds the package from links to its clone, and the package
follows the link back to the clone to find `py-xmlvalidate.py` (this
needs version 0.1.1 or later). `M-x straight-pull-package RET
py-xmlvalidate` updates it. From GitHub, use `:host github`.

### From a clone

If you already have a clone of the repository:

```elisp
(add-to-list 'load-path "/path/to/py-xmlvalidate/emacs")
(require 'py-xmlvalidate)
```

## Setup

Three lines, if you did not use a `use-package` form above:

```elisp
(add-hook 'nxml-mode-hook #'py-xmlvalidate-mode)
(setopt py-xmlvalidate-python "~/.venvs/schematron/bin/python")
(setopt trusted-content '("~/Dropbox/docs/editions/"))   ; your folders
```

**Why `trusted-content`.** Since Emacs 30, Flymake checks only the files
you trust, and this package follows that rule, with Flycheck too (which
has no such rule of its own). A document's
`<?xml-model?>` chooses the schema, and the schema's rules are XPath that
Saxon runs: they can read files on your computer and fetch URLs. So an XML
file from elsewhere is not checked until you put it, or its folder, in
`trusted-content`. Folder names end in `/`.

When you open a file that is not trusted, a warning in the `*Warnings*`
buffer says so, once per file, with the line to add to your init file.
`M-x py-xmlvalidate-trust-file` trusts it on request: it asks whether to
trust the file alone or its whole folder, adds it to `trusted-content` for
the session, starts checking, and puts the line that keeps it in the kill
ring, ready to paste into your init file. Trust single files rather than
folders like `~/Downloads/`, where files from elsewhere arrive. Until a
file is trusted, `py-xmlvalidate-check` and `py-xmlvalidate-refresh-schema`
say why they cannot run, and `py-xmlvalidate-report` (which runs, since
you asked for it) ends with the same note.

Then `M-x py-xmlvalidate-check-setup` says whether Python, its libraries,
the script and jing are in place.

## Flycheck or Flymake

With `py-xmlvalidate-frontend` set to `auto` (the default), the package
uses Flycheck when it is installed, and Flymake otherwise; `flycheck` or
`flymake` chooses one. With Flycheck, the package selects its own checker
in the buffer (`flycheck-checker`), turns Flycheck on if it was off (and off
again when `py-xmlvalidate-mode` is turned off), and the problems appear in
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
  result in `~/.emacs.d/py-xmlvalidate/rnc/`; it converts again only when
  the RelaxNG file changes, so other documents with the same schema get it
  at once;
- it sets it as the buffer's schema without saving its location (nxml's
  own command would offer to write a `schemas.xml` next to the document);
- it never replaces a schema you gave nxml yourself (with
  `M-x rng-set-schema-file` or through `schemas.xml`), and takes its own
  back when `py-xmlvalidate-mode` is turned off.

Then `C-RET` completes element and attribute names from the schema, and
`rng-validate-mode`, if it is on, checks the structure at once, with no
program to run.

One adjustment is made in nxml's copy of the schema. nxml's tables for the
Unicode categories `\p{P}` and `\p{S}` leave out ASCII and Latin-1
punctuation and symbols such as `#`, `%`, `!`, `@` and `§`, so it rejects
values that the schema allows, like `ed="#U2"` in TEI's `teidata.word`. In
the copy for nxml, that pattern also accepts those characters explicitly.
nxml's copy is thus a little more permissive than the schema, never
stricter; the full check is still jing's, in the checker's list.

The converter is `py-xmlvalidate-trang`: `"trang"` (what
`tools/install-trang.py` installs), or a command line as a list, for
example the copy inside oXygen:

```elisp
(setopt py-xmlvalidate-trang
        '("java" "-cp" "~/bin/oxygen/lib/oxygen-patched-trang.jar"
          "com.thaiopensource.relaxng.translate.Driver"))
```

Without trang, the package says so once and nxml keeps its vacuous schema;
nothing else changes. `py-xmlvalidate-nxml-schema` set to `nil` turns the
feature off.

## Commands

| Command | What it does |
|---|---|
| `py-xmlvalidate-mode` | Turns the checking on or off in the buffer |
| `py-xmlvalidate-check` | Checks the buffer now |
| `py-xmlvalidate-refresh-schema` | Downloads the document's remote schema again (after it changed upstream), then checks |
| `py-xmlvalidate-report` | Full report of the saved file, in a buffer with links to the lines |
| `py-xmlvalidate-trust-file` | Trusts the file, or its folder, after asking; starts checking it |
| `py-xmlvalidate-check-setup` | Says whether Python, saxonche, lxml, the script, jing and trang are found, and which checker is used |
| `py-xmlvalidate-show-log` | What `py-xmlvalidate.py` and jing printed (schema detection, downloads, cache) |

## Settings

`M-x customize-group RET py-xmlvalidate`. `trusted-content` still has to
be set (see [Setup](#setup)), whichever way the package was installed.

The settings:

| Variable | Default | Meaning |
|---|---|---|
| `py-xmlvalidate-python` | `"python3"` | Python with saxonche and lxml; may start with `~` |
| `py-xmlvalidate-script` | `nil` | `py-xmlvalidate.py` to run; `nil` is the repository's copy |
| `py-xmlvalidate-schema` | `nil` | Schema to use instead of the `<?xml-model?>`; relative to the document |
| `py-xmlvalidate-schema-type` | `rng` | Its type: `rng`, `sch` or `odd` |
| `py-xmlvalidate-relaxng` | `t` | Also check the structure with jing, when the schema is RelaxNG |
| `py-xmlvalidate-jing` | `"jing"` | The jing program |
| `py-xmlvalidate-timeout` | `120` | Seconds after which a check is abandoned |
| `py-xmlvalidate-live-max-size` | `nil` | Larger buffers (in characters) are checked on opening and saving only |
| `py-xmlvalidate-frontend` | `auto` | `flycheck`, `flymake`, or `auto` (Flycheck if installed) |
| `py-xmlvalidate-nxml-schema` | `t` | Give nxml-mode the document's RelaxNG schema, for completion |
| `py-xmlvalidate-trang` | `"trang"` | The trang converter: a program, or a command line as a list |

`py-xmlvalidate-schema` and `py-xmlvalidate-schema-type` are safe as
file-local or directory-local variables, for documents without an
`<?xml-model?>`:

```elisp
;; .dir-locals.el
((nxml-mode . ((py-xmlvalidate-schema . "schema/smed-schema.rng"))))
```

How quickly the problems appear is Flycheck's `flycheck-idle-change-delay`,
or Flymake's `flymake-no-changes-timeout` (half a second of no typing by
default).

## Speed

Starting the check costs little (Python with its libraries loads in about
15 ms); the time goes into the rules. A small document is checked in a
tenth of a second; a 26,000-line edition, in about two seconds (with
py-xmlvalidate.py 1.16, which comes with the package). While a check
runs, Flymake's mode-line indicator says so, and typing again cancels it
and starts a new one, so nothing piles up. For very large files you may
prefer `py-xmlvalidate-live-max-size`.

## Tests

From the repository's top folder:

```sh
PYXV_PYTHON=~/.venvs/schematron/bin/python JING=jing \
  FLYCHECK_DIR=~/.emacs.d/straight/build/flycheck PYXV_TRANG=trang \
  emacs --batch -Q -L emacs -l emacs/test/py-xmlvalidate-tests.el \
  -f ert-run-tests-batch-and-exit
```

Without `PYXV_PYTHON`, only the tests that read the programs' output run;
without `FLYCHECK_DIR` (a folder with `flycheck.el`), the Flycheck tests are
skipped, and without `PYXV_TRANG` (trang's command line), the nxml ones.
