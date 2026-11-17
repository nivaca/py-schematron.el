# py-xmlvalidate for Emacs

A Flymake backend that checks XML documents, TEI editions in particular,
against the Schematron rules of their schema, with `py-xmlvalidate.py`, the
program of [py-xmlvalidate](https://codeberg.org/nivaca/py-xmlvalidate).
When the schema is a RelaxNG file, it also checks the structure with jing.
It needs Emacs 31 or later, and nothing from outside Emacs except Python.

- **When:** as you type (when typing pauses), on opening and on saving,
  for every buffer with an `<?xml-model?>`. Unsaved changes are checked
  from a private temporary copy; your file is never written.
- **What you see:** each problem underlined, with its message in the echo
  area when the cursor is on it; its layer (**Schematron**, **RelaxNG**,
  or **XML** when the document is not well formed) and, for Schematron, the
  pattern's id. A misspelt element is also flagged where it was opened.
  The mode line shows Flymake's counts.
- **All of them:** `M-x flymake-show-buffer-diagnostics`. `M-x
  py-xmlvalidate-report` shows the full text report of the saved file, with
  each line linked to the document.

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

## Installation

From Codeberg (or GitHub, with its URL), in your init file:

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
the package's main file.) The whole repository is cloned, so the package
uses its own copy of
`py-xmlvalidate.py`; `M-x package-vc-upgrade` updates both. If you already
have a clone, `(add-to-list 'load-path "/path/to/py-xmlvalidate/emacs")`
and `(require 'py-xmlvalidate)` work as well.

## Setup

Three lines, if you did not use the `use-package` form above:

```elisp
(add-hook 'nxml-mode-hook #'py-xmlvalidate-mode)
(setopt py-xmlvalidate-python "~/.venvs/schematron/bin/python")
(setopt trusted-content '("~/Dropbox/docs/editions/"))   ; your folders
```

**Why `trusted-content`.** Since Emacs 30, Flymake checks only the files
you trust, and this package follows that rule. A document's
`<?xml-model?>` chooses the schema, and the schema's rules are XPath that
Saxon runs: they can read files on your computer and fetch URLs. So an XML
file from elsewhere is not checked until you put it, or its folder, in
`trusted-content`. Folder names end in `/`. When a file is not trusted, the
package says so when you open it.

Then `M-x py-xmlvalidate-check-setup` says whether Python, its libraries,
the script and jing are in place.

## Commands

| Command | What it does |
|---|---|
| `py-xmlvalidate-mode` | Turns the checking on or off in the buffer |
| `py-xmlvalidate-check` | Checks the buffer now |
| `py-xmlvalidate-refresh-schema` | Downloads the document's remote schema again (after it changed upstream), then checks |
| `py-xmlvalidate-report` | Full report of the saved file, in a buffer with links to the lines |
| `py-xmlvalidate-check-setup` | Says whether Python, saxonche, lxml, the script and jing are found |
| `py-xmlvalidate-show-log` | What `py-xmlvalidate.py` and jing printed (schema detection, downloads, cache) |

## Settings

`M-x customize-group RET py-xmlvalidate`:

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

`py-xmlvalidate-schema` and `py-xmlvalidate-schema-type` are safe as
file-local or directory-local variables, for documents without an
`<?xml-model?>`:

```elisp
;; .dir-locals.el
((nxml-mode . ((py-xmlvalidate-schema . "schema/smed-schema.rng"))))
```

How quickly the problems appear is Flymake's
`flymake-no-changes-timeout` (half a second of no typing by default).

## Speed

Starting the check costs little (Python with its libraries loads in about
15 ms); the time goes into the rules. A small document is checked in a
tenth of a second; a 26,000-line edition, in about 3.5 s. While a check
runs, Flymake's mode-line indicator says so, and typing again cancels it
and starts a new one, so nothing piles up. For very large files you may
prefer `py-xmlvalidate-live-max-size`.

## Tests

From the repository's top folder:

```sh
PYXV_PYTHON=~/.venvs/schematron/bin/python JING=jing \
  emacs --batch -Q -L emacs -l emacs/test/py-xmlvalidate-tests.el \
  -f ert-run-tests-batch-and-exit
```

Without `PYXV_PYTHON`, only the tests that read the programs' output run.
