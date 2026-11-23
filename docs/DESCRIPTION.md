How py-schematron.el was made
=============================

py-schematron.el is an Emacs package that checks XML and TEI documents
against the Schematron rules of their schema as you type, and underlines
each offence in the buffer, with Flymake or with Flycheck.  It runs
py-schematron.py, the program of the py-schematron project, which it
carries in its own copy, and jing for RelaxNG schemas; it also gives the
document's RelaxNG schema to nxml-mode, so that nxml can complete what the
schema allows.  Nicolas Vaughan made it in November 2026, for the
editions of the SMTrad project, after the extension for Visual Studio
Code had shown what such a tool should do in an editor.  It was called
py-xmlvalidate until version 0.7.0, and lived in the `emacs/` folder of
the program's repository until 0.2.0.  Here I explain how it was made, in
seven stages.

py-schematron.el is free software, under the GNU General Public License,
version 3 or later, like Emacs itself and Flycheck, which it uses when it
is installed.  The program it runs, py-schematron.py, is under the same
licence, and uses Saxon HE, through saxonche (Mozilla Public License 2.0),
and lxml (BSD licence).  jing and trang, by James Clark, are under a BSD
licence.  The full list, with the tools used to test it, is in
`docs/THIRD-PARTY.md`.

Nicolas Vaughan is Associate Professor of Literature at the School of Arts
and Humanities of the Universidad de los Andes, Bogotá, Colombia.

1. A first version
------------------

I write my editions in Emacs as much as in VS Code, so the next step
after the extension was to have the same checks in Emacs.  I weighed two
designs: a language server, which both editors could share, or a backend
for Flymake, which comes with Emacs.  I chose Flymake.  Python with its
libraries starts in about 15 milliseconds, and the time of a large
edition goes into the rules themselves, so a server that stays running
would have saved nothing worth its complexity.

Version 0.1.0 is a Flymake backend that does what the extension does:
it writes the buffer, unsaved changes included, to a private temporary
copy, runs `py-schematron.py --json --as FILE` on it, so that relative
`<?xml-model?>` paths still work, and turns the report into diagnostics.
When the schema is RelaxNG it runs jing too.  A newer check cancels the
one still under way, and no process or temporary file is left behind.
There are commands to check at once, to download a remote schema again,
to see the full report, to check the setup and to see the log.

Emacs 31 lets Flymake run only on files in `trusted-content`, unless a
backend declares itself always safe.  I decided not to declare it: the
`<?xml-model?>` of a document chooses the schema, and Saxon runs its
XPath, which can read files and fetch URLs.  So the package respects that
rule.  In 0.1.2 an untrusted file became hard to miss: a warning, once
per file, with the line to add to the init file, and
`M-x py-schematron-trust-file` (I give the commands their present
names), which trusts the file or its folder
after asking.  Version 0.1.1 made it install with Straight, which builds
the package from links: the package follows the link to its own file
back to Straight's clone, to find py-schematron.py there.

2. Flycheck and nxml
--------------------

Many Emacs users have Flycheck instead of Flymake, so 0.2.0 registers a
Flycheck checker as well, and an option chooses; by default Flycheck is
used when it is installed.  Flycheck has no `trusted-content` rule, so
the package applies it itself there.

The same version gave nxml-mode the document's schema.  nxml validates
the structure and completes elements and attributes, but it reads only
the compact syntax of RelaxNG, and it does not understand
`<?xml-model?>`.  After each check, the package converts the document's
RelaxNG schema to the compact syntax with trang, keeps the conversion in
a cache, and gives it to nxml.  A schema the user chose by hand is never
replaced, and nothing is written next to the document.
`tools/install-trang.py` downloads trang, checks its SHA-1 and installs
it.

3. A repository of its own
--------------------------

Until 0.2.0 the package depended on the program's repository, and ran
the copy of the program in the folder above its own.  In 0.3.0 it moved
to a repository of its own, with its history extracted and its tags
renamed, and it now carries its own copy of py-schematron.py, which the
program's `tools/sync-plugins.py` updates.  The recipes became simpler,
with no `:files` and no `:lisp-dir`.

The next two versions added commands.  `M-x
py-schematron-recreate-nxml-schema` converts the schema for nxml again,
at once, and reloads it in every buffer that uses it (0.4.0); the same
version fixed buffers that kept nxml's old copy after the RelaxNG file
changed, because the name of the converted file stays the same.  `M-x
py-schematron-about` shows the package's version, author, licence and
links, and what its copy of the program says of itself (0.5.0), so a bug
report can say at once which versions were involved.

4. nxml's bugs
--------------

On my editions, nxml rejected values the schema allows: `#`, `%`, `!`,
`@` and `¿` in attributes whose datatype is TEI's word pattern, the
medieval abbreviations `ꝑ` and `ꝯ`, and `ed=" #U2"`.  jing accepted all
of them.  I found four bugs in nxml's XSD datatypes, in Emacs itself.
Building a Unicode category such as `\p{P}` damaged nxml's cached table
of the last category in it, because `xsdre-range-list-union` merged the
lists in place; the categories date from Unicode 3.1 and stop at
U+FFFF; and `xsd:token` values kept a space at either end.

The first fix, in 0.2.0, widened TEI's word pattern in nxml's copy of
the schema, which helped that pattern only.  Version 0.5.1 mended the
first bug at its cause, with an advice that has nxml copy the lists
first.  In 0.6.0 the package began to check whether the running Emacs
has the bug before mending it, by giving the function two fresh lists
and seeing whether it changes them, so that an Emacs where it is fixed is
left alone.  Version 0.7.0 mended the other bugs in the same way,
rebuilding the categories from Emacs's own Unicode data, with caches so
that nxml is no slower, and an option turns all of it off.  I reported
the four bugs to Emacs (bug#82281 to bug#82284), each with a recipe from
`emacs -Q`; the reports are kept in `upstream/`.  In 1.0.2, on the Emacs
maintainer's advice, the categories are read from Emacs's table of the
general-category property, which names each character's category, as
characters.el does, instead of looking the name up for each range.

5. Following the program
------------------------

The package grew with the program.  In 0.6.0 it stopped reading the
program's Spanish messages on stderr, and took the fatal errors and the
events (such as a schema downloaded again) from the JSON report, as the
extension does.  The same version added `M-x py-schematron-goto-rule`,
which opens the schema at the assert or report behind the error on the
current line: in the ODD or RelaxNG the user edits, not the `.sch` made
from it, since py-schematron.py 1.21 says where each rule is written.

When the program was renamed py-schematron, the package was renamed with
it, as py-schematron.el (0.8.0).  Every option and command took the new
prefix, and the former names stayed as obsolete aliases, with a file
`py-xmlvalidate.el` that made `(require 'py-xmlvalidate)` still work, so
that an older configuration would not break at once.  Version 0.9.0
followed the program's installers: while `py-schematron-python` is nil,
its new default, the package uses the Python of the installer's
environment, which already has saxonche and lxml, and nobody has to set
up Python by hand.

6. Windows
----------

The installers made Windows a real target, and I have no Windows
machine.  From 0.9.1 the tests run on GitHub on Windows at every push,
and on macOS for each release, with GNU's own Windows build of Emacs,
downloaded and checked against its published SHA-256.  They found a
series of problems.  Emacs on Windows reads the output of a process in
the system's code page, so every accented letter of the messages came
out garbled; the package now reads it as UTF-8, which is what
py-schematron.py writes (0.9.2).  Python ends its lines with CR LF there,
which left a stray `^M` in the About buffer, and `M-x
py-schematron-trust-file` could stop with "Selecting deleted buffer"
when starting the checks killed other buffers on the way (0.9.3).

Windows has no `jing` command either; jing comes there as a `jing.jar`.
In 0.10.0 `py-schematron-jing` can name a `jing.jar`, which the package
runs with Java, or a whole command line, and when no jing is found the
package uses the `jing.jar` named by the variable `JING_JAR`.

The most serious finding came last.  On Windows, Flymake calls the
backend for a file outside `trusted-content`, where on Linux and macOS it
does not.  The backend had left that rule to Flymake, so there a
document I had not trusted was checked, and its schema run.  Since
0.10.1 the backend refuses such a file itself, as the Flycheck checker
already did; its test calls the backend directly, as Flymake does on
Windows, and fails without the fix.

7. Version 1.0
--------------

Before 1.0 I ran package-lint, which checks a package against the
conventions of the Emacs package archives.  It found one real thing: the
fixes for nxml went in as soon as nxml loaded its XSD code, through
`with-eval-after-load`, so loading the package alone changed Emacs.  In
0.11.0 they go in when the mode is turned on in an nxml-mode buffer,
before nxml compiles the schema it validates with, and package-lint runs
on GitHub with the tests.  Version 1.0.0 removed the former names, as
0.9.1 had announced, together with `py-xmlvalidate.el`.  With that the
package's names and settings are stable.

Testing
-------

The package has 46 ERT tests (`test/py-schematron-tests.el`), run in a
batch Emacs.  Some need no Python: they read the reports of
py-schematron.py and jing, find the program (also through a link like
Straight's), choose the jing command (a program, a `jing.jar`, or the one
in `JING_JAR`), and check the mending of nxml's datatypes in a fresh
Emacs, and that loading the package alone mends nothing.  The others run
the real programs on documents made for each case.  Through Flymake they
check the lines and underlines, a misspelt element, unsaved changes, a
check cancelled by a newer one, a remote schema refreshed from a small
web server, a file outside `trusted-content` (its warning, the commands
that refuse, the note at the end of its report, trusting it on request,
and that the backend itself refuses it), accented messages, the report
buffer and its links, and that no process or temporary copy is left
behind.  Through Flycheck they check the same lines, layers and
underlines, unsaved text, the trust rule, and that turning the mode off
leaves Flycheck as it found it.  With trang, they check that nxml gets
the schema and offers its elements, accepts `ed="#U2"`, finds a
misplaced element, reuses the cached conversion, never replaces a schema
chosen by hand, and gets its vacuous schema back.

On GitHub the package is byte-compiled with warnings as errors, checked
with package-lint, and tested on Linux and Windows at every push and on
macOS for each release.  `tools/release.py` runs the tests again before
each release, and checks that the files downloaded from Codeberg and
GitHub are the ones it uploaded.  The package was also installed with
`package-vc-install` and with Straight into empty profiles, and tried on
the Latin edition, about 26,000 lines: Flycheck's check took 2.6
seconds, nxml had the schema 0.7 seconds later and found no errors, and
inside an `<rdg>` it offered the 123 elements the schema allows there.
The package has about 1,530 lines of Emacs Lisp, and its tests about
1,140.
