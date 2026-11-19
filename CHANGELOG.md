# Changelog

All notable changes to py-schematron for Emacs. The releases, with their
zip files, are on
[Codeberg](https://codeberg.org/nivaca/py-schematron.el/releases) and
[GitHub](https://github.com/nivaca/py-schematron.el/releases). Until
0.2.0 they were published in
[py-schematron](https://codeberg.org/nivaca/py-schematron/releases), as
`emacs-vVERSION`.

## 0.9.1 — 2026-11-19 (py-schematron.py 2.2)

- **The former names will go in 1.0.** The `py-xmlvalidate-…` options and
  commands (obsolete aliases since 0.8.0) and `py-xmlvalidate.el` will be
  removed in version 1.0; a configuration that still uses them should
  change to the `py-schematron` names.
- The tests run on GitHub on Windows too at every push, and on macOS for
  each release, besides Linux; two of them no longer assume a Unix system.
- Carries py-schematron.py 2.2.

## 0.9.0 — 2026-11-19 (py-schematron.py 2.1)

- **No Python to set up by hand.** py-schematron 2.1 has an installer for
  Linux, macOS and Windows that makes a Python environment with saxonche
  and lxml. While `py-schematron-python` is nil, now its default, the
  package uses that environment's Python if it is installed, and
  `python3` otherwise. A value already set keeps working as before.
- The setup steps (*Before you start*) start with the installer; a
  virtual environment of your own remains as an alternative. The error
  messages about Python point to the installer too.
- Carries py-schematron.py 2.1.

## 0.8.0 — 2026-11-19 (py-schematron.py 2.0)

- **The package is renamed py-schematron** (it was py-xmlvalidate), with
  the program, now py-schematron. Its repository is nivaca/py-schematron.el
  on Codeberg and GitHub; the old addresses redirect to it. With Straight:

  ```elisp
  (use-package py-schematron
    :straight (:host codeberg :repo "nivaca/py-schematron.el" :depth 1)
    :hook (nxml-mode . py-schematron-mode))
  ```

  Every option and command is now `py-schematron-…`. The former names
  keep working for now as obsolete aliases, and `(require
  'py-xmlvalidate)` loads the package, so an older configuration still
  works, with warnings. The cache of nxml's schemas moves to
  `~/.emacs.d/py-schematron/`; the old `py-xmlvalidate/` folder there can
  be deleted. The trang installer recognises a wrapper it installed under
  the old name.
- Carries py-schematron.py 2.0.

## 0.7.0 — 2026-11-19 (py-xmlvalidate.py 1.21)

- **Two more nxml bugs mended**, each only where the running Emacs has
  it. nxml's Unicode categories date from Unicode 3.1 and stop at U+FFFF,
  so it rejected the medieval abbreviations `ꝑ` and `ꝯ`, CJK, Gothic and
  other letters in TEI's `teidata.name` and `teidata.word`; the package
  rebuilds them from Emacs's own Unicode data, with caches, so nxml is no
  slower. And `xsd:token` values kept a space at either end, so
  `ed=" #U2"` failed `teidata.word`.
- The fixes now go in as soon as nxml loads its XSD code, not when the
  package first gives nxml a schema, so they also hold for a schema you
  chose yourself. The new option `py-xmlvalidate-fix-nxml` turns them
  off, and `M-x py-xmlvalidate-about` lists what was mended.
- `upstream/` has the four nxml bugs written up for Emacs's bug tracker,
  each with a recipe from `emacs -Q`.

## 0.6.0 — 2026-11-19 (py-xmlvalidate.py 1.21)

- The package no longer reads the program's Spanish messages on stderr:
  the program's fatal errors come from its JSON, word for word, and *the
  schema downloaded again* comes from the report's events. With an older
  `py-xmlvalidate.py` (named in `py-xmlvalidate-script`), stderr is still
  read as before.
- **`M-x py-xmlvalidate-goto-rule`** opens the schema at the rule behind
  the Schematron error on the current line: the assert or report that
  reported it, in the ODD or RelaxNG it came from (the file you edit, not
  the `.sch` made from it). With several, it asks which; `M-,` returns.
  It works with Flymake and with Flycheck. Needs py-xmlvalidate.py 1.21,
  which says where each rule is.
- The fix for nxml's punctuation bug is applied only when the running
  Emacs has the bug: the package first gives `xsdre-range-list-union` two
  fresh lists and sees whether it changes them. Once Emacs fixes it, the
  package leaves nxml alone, with no change needed here.
- The tests run on GitHub every Monday too.

## 0.5.1 — 2026-11-18 (py-xmlvalidate.py 1.20)

- **nxml's punctuation bug is mended at its cause.** nxml rejected `#`,
  `%`, `!`, `@`, `¿` and more in values the schema allows because building
  `\p{P}` (or `\p{S}`, `\p{C}`) damages nxml's cached table of the last
  category in it: `xsdre-range-list-union` merges the lists in place, and
  `append` does not copy the last one. The package now has nxml copy them
  first (an advice, put in the first time it gives nxml a schema, and
  removed on unloading), instead of widening TEI's word pattern in nxml's
  copy of the schema, which fixed that pattern only. nxml's copy is now
  exactly what trang makes.
- Carries py-xmlvalidate.py 1.20, whose `-o` finds the TEI Stylesheets
  through `--stylesheets`, `TEI_STYLESHEETS` or ODD2RNG's configuration.
  `M-x py-xmlvalidate-about` shows which folder it uses.
- The tests run on GitHub at every push (byte-compiling with warnings as
  errors, then the ERT tests with Flycheck, jing and trang), and
  `tools/release.py` makes a release in one command.

## 0.5.0 — 2026-11-18 (py-xmlvalidate.py 1.19)

- `M-x py-xmlvalidate-about` shows what the package is: its version, author,
  licence and links (which can be clicked), the checker in use, and what its
  copy of `py-xmlvalidate.py` says of itself (its new `--about`: the
  program's version, and the Python and libraries it runs with).

## 0.4.0 — 2026-11-18 (py-xmlvalidate.py 1.18)

- `M-x py-xmlvalidate-recreate-nxml-schema` converts the document's
  RelaxNG schema for nxml again, at once, and reloads it in every buffer
  that uses it. It explains why when it cannot run (no trang, a file
  outside `trusted-content`, a schema chosen by hand, a schema that is not
  RelaxNG).
- `py-xmlvalidate-report` ends with "incomplete" when py-xmlvalidate.py
  exits 3: since 1.18 it does so when a rule could not be evaluated, as
  well as for a document that is not well formed.
- Fix: when the RelaxNG file changed, the compact copy was converted
  again, but buffers that already used it kept nxml's old copy until they
  were reopened, because the file name stays the same. Every buffer that
  uses it now reloads it.

## 0.3.0 — 2026-11-18 (py-xmlvalidate.py 1.17)

- The package has a repository of its own, py-xmlvalidate-emacs, and
  carries its own copy of `py-xmlvalidate.py`, next to `py-xmlvalidate.el`.
  The recipes are simpler: Straight needs no `:files`, package-vc no
  `:lisp-dir`. Recipes that point to py-xmlvalidate stop working, because
  its `emacs/` folder is gone; see "Moving from the py-xmlvalidate
  repository" in the README.
- `tools/install-trang.py` moved here with the package.
- The history of the package came along, with its tags renamed from
  `emacs-vVERSION` to `vVERSION`.

## 0.2.0 — 2026-11-17

- Flycheck: a checker as well as the Flymake backend; `py-xmlvalidate-frontend`
  chooses, and `auto` uses Flycheck when it is installed. The package
  applies the `trusted-content` rule itself, since Flycheck has none.
- nxml-mode gets the document's RelaxNG schema, converted to the compact
  syntax with trang and cached, so that `C-RET` completes what the schema
  allows and nxml validates the structure. A schema chosen by hand is never
  replaced, and nothing is written next to the document. nxml's tables for
  `\p{P}` and `\p{S}` leave out ASCII punctuation, so in its copy TEI's
  word pattern also lists those characters.
- `tools/install-trang.py` downloads trang, checks its SHA-1 and installs
  it in `~/bin` (or `~/.local/bin`).

## 0.1.2 — 2026-11-17

- A file outside `trusted-content` is hard to miss: a warning, once per
  file, with the line to add to the init file; `py-xmlvalidate-check` and
  `py-xmlvalidate-refresh-schema` explain why they cannot run; the report
  ends with a note.
- `M-x py-xmlvalidate-trust-file` trusts the file or its folder, after
  asking, for the session, and puts the line that keeps it in the kill ring.

## 0.1.1 — 2026-11-17

- Installs with Straight: the package follows the link to its own file
  back to Straight's clone to find `py-xmlvalidate.py`.

## 0.1.0 — 2026-11-17

- First release: a Flymake backend that checks XML/TEI buffers against
  their Schematron rules as you type, from a private temporary copy, with
  jing for RelaxNG schemas; commands to check, refresh a remote schema, see
  the full report, check the setup and see the log.
