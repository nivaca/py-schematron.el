# nxml's bugs, reported to Emacs

nxml, Emacs's XML mode, has bugs in its XSD datatypes that make it reject
valid values in TEI and other schemas. The package mends them at runtime
in an Emacs that has them (`py-xmlvalidate-fix-nxml`). The reports here
describe them for Emacs's bug tracker, each with a recipe from `emacs
-Q`, the cause, and what fixes it; they were checked against Emacs's
master branch (commit d108780, 2026-11-19), whose nxml code is the same
as in Emacs 31.1.90.

| Report | Bug |
|---|---|
| `reports/1-category-ranges.txt` | Translating `\p{P}` damages nxml's cached table of `Po` (likewise for `\p{S}`, `\p{C}`): after the first use, `#`, `%`, `!`, `@` are rejected |
| `reports/2-unicode-categories.txt` | The Unicode categories are those of Unicode 3.1 (2001), and stop at U+FFFF: medieval abbreviations such as `ꝑ`, CJK and Gothic are rejected; fixing it needs caches, or nxml becomes much slower |
| `reports/3-class-subtraction.txt` | A class subtraction after a range, `[a-z-[aeiou]]`, is refused, and the datatype then accepts anything |
| `reports/4-collapsed-whitespace.txt` | Collapsed values (`xsd:token` and the like) keep a space at either end, so `ed=" #U2"` fails TEI's `teidata.word` |

The reports carry no patches: they say what fixes each bug, and leave
the fix to the Emacs maintainers.

## Sending them

Each report is meant as its own bug report: `M-x report-emacs-bug`, or a
mail to bug-gnu-emacs@gnu.org. Send report 1 first: report 2 refers to
it as `bug#NNNNN`, to be replaced with the number it gets.

## Status

Not sent yet. Once a fix is in Emacs, the package finds that the
running Emacs no longer has the bug and leaves nxml alone; nothing needs
to change here.
