# Changelog

All notable changes to py-xmlvalidate for Emacs. The releases, with their
zip files, are on
[Codeberg](https://codeberg.org/nivaca/py-xmlvalidate-emacs/releases) and
[GitHub](https://github.com/nivaca/py-xmlvalidate-emacs/releases). Until
0.2.0 they were published in
[py-xmlvalidate](https://codeberg.org/nivaca/py-xmlvalidate/releases), as
`emacs-vVERSION`.

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
