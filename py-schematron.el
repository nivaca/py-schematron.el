;;; py-schematron.el --- Schematron validation of XML/TEI with Flycheck or Flymake  -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Copyright (C) 2026 Nicolas Vaughan <nicolasvaughan@proton.me>

;; Author: Nicolas Vaughan <nicolasvaughan@proton.me>
;; Version: 0.9.0
;; Package-Requires: ((emacs "31.1"))
;; Keywords: languages, xml, tools
;; URL: https://codeberg.org/nivaca/py-schematron.el

;; This file is part of py-schematron.el, the Emacs package of
;; py-schematron (https://codeberg.org/nivaca/py-schematron).

;; py-schematron is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or (at
;; your option) any later version.

;; py-schematron is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with py-schematron.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; A Flymake backend and a Flycheck checker that check XML documents,
;; TEI editions in particular, against the Schematron rules of their
;; schema, with the program py-schematron.py, of which this package
;; carries its own copy.
;; When the schema is a RelaxNG file, the structure is also checked with
;; jing.  Flycheck is used when it is installed, Flymake otherwise (see
;; `py-schematron-frontend').
;;
;; In nxml-mode, the document's RelaxNG schema is also given to nxml,
;; converted to the compact syntax with trang, so that completion
;; (C-RET) offers the elements and attributes the schema allows and
;; nxml's own validation knows the schema (see
;; `py-schematron-nxml-schema').
;;
;; Errors are underlined as you type, unsaved changes included: the
;; buffer is checked from a private temporary copy, never from the file
;; itself.  The message under the cursor is shown, and the checker's
;; list (Flycheck's C-c ! l, Flymake's M-x flymake-show-buffer-diagnostics)
;; shows them all.
;;
;; The schema is taken from the document's <?xml-model?> processing
;; instructions, as in oXygen and in the VS Code extension; remote
;; schemas are downloaded once and kept in a cache.  Documents without
;; an <?xml-model?> are left alone, unless `py-schematron-schema' names
;; a schema.
;;
;; Setup, once the package is installed:
;;
;;   (add-hook 'nxml-mode-hook #'py-schematron-mode)
;;
;; The Python comes from py-schematron's installer, which the package
;; finds by itself; if the libraries live in a virtual environment of
;; your own instead,
;;
;;   (setopt py-schematron-python "~/.venvs/schematron/bin/python")
;;
;; Flymake checks only files in `trusted-content' (Emacs 30 and later),
;; and this backend is no exception: a document's <?xml-model?> chooses
;; the schema, and the schema's XPath, run by Saxon, can read local files
;; and fetch URLs.  So list the folders of your own documents there:
;;
;;   (setopt trusted-content '("~/Dropbox/docs/editions/"))
;;
;; A file outside those folders gets a warning when it is opened, and
;; M-x py-schematron-trust-file trusts it (or its folder) on request.
;;
;; M-x py-schematron-check-setup says whether Python, its libraries and
;; jing are where they should be.  See README.md for the details.

;;; Code:

(require 'flymake)
(require 'compile)
(require 'cl-lib)
(require 'seq)
(require 'xref)
(require 'subr-x)
(require 'lisp-mnt)

;; The package was py-xmlvalidate until 0.7.0: its options keep working
;; under their former names for now.
(define-obsolete-variable-alias 'py-xmlvalidate-fix-nxml 'py-schematron-fix-nxml "0.8.0")
(define-obsolete-variable-alias 'py-xmlvalidate-frontend 'py-schematron-frontend "0.8.0")
(define-obsolete-variable-alias 'py-xmlvalidate-jing 'py-schematron-jing "0.8.0")
(define-obsolete-variable-alias 'py-xmlvalidate-live-max-size 'py-schematron-live-max-size "0.8.0")
(define-obsolete-variable-alias 'py-xmlvalidate-nxml-schema 'py-schematron-nxml-schema "0.8.0")
(define-obsolete-variable-alias 'py-xmlvalidate-python 'py-schematron-python "0.8.0")
(define-obsolete-variable-alias 'py-xmlvalidate-relaxng 'py-schematron-relaxng "0.8.0")
(define-obsolete-variable-alias 'py-xmlvalidate-schema 'py-schematron-schema "0.8.0")
(define-obsolete-variable-alias 'py-xmlvalidate-schema-type 'py-schematron-schema-type "0.8.0")
(define-obsolete-variable-alias 'py-xmlvalidate-script 'py-schematron-script "0.8.0")
(define-obsolete-variable-alias 'py-xmlvalidate-timeout 'py-schematron-timeout "0.8.0")
(define-obsolete-variable-alias 'py-xmlvalidate-trang 'py-schematron-trang "0.8.0")
(define-obsolete-variable-alias 'py-xmlvalidate-mode 'py-schematron-mode "0.8.0")

(defgroup py-schematron nil
  "Schematron validation of XML/TEI documents with py-schematron.py."
  :group 'tools
  :link '(url-link "https://codeberg.org/nivaca/py-schematron.el")
  :prefix "py-schematron-")

(defconst py-schematron--directory
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "Folder of this file, where the package's py-schematron.py also is.")

(defcustom py-schematron-python nil
  "Python interpreter that has the saxonche and lxml libraries.
nil, the default, means the one that py-schematron's installer made,
if it is installed (see `py-schematron--installer-python'), or else
\"python3\".  Or a file name, such as
\"~/.venvs/schematron/bin/python\".  Python 3.15 or later is needed."
  :type '(choice (const :tag "Automatic: the installer's, or python3" nil)
                 (string :tag "Interpreter")))

(defun py-schematron--installer-python ()
  "Where py-schematron's installer puts its Python.
That is, the Python of the environment it makes, with saxonche and
lxml (installers/install.py in py-schematron)."
  (pcase system-type
    ('windows-nt
     (expand-file-name "py-schematron/venv/Scripts/python.exe"
                       (or (getenv "LOCALAPPDATA") (expand-file-name "~/AppData/Local"))))
    ('darwin (expand-file-name "~/Library/Application Support/py-schematron/venv/bin/python"))
    (_ (expand-file-name "py-schematron/venv/bin/python"
                         (or (getenv "XDG_DATA_HOME") (expand-file-name "~/.local/share"))))))

(defun py-schematron--python ()
  "The Python that runs py-schematron.py.
`py-schematron-python', or else the installer's Python if it exists,
or else \"python3\"."
  (or py-schematron-python
      (let ((installer (py-schematron--installer-python)))
        (and (file-executable-p installer) installer))
      "python3"))

(defcustom py-schematron-script nil
  "Path to py-schematron.py.
When nil, the package's own copy is used: it is looked for next
to this file, also after following the symbolic link to this file,
which is how it is found when Straight builds the package from
links (and, for older layouts, in the folder above)."
  :type '(choice (const :tag "The package's own copy" nil) file))

(defcustom py-schematron-schema nil
  "Schema to validate against, instead of the document's <?xml-model?>.
When nil, the schema is detected from the document.  Relative
names are taken from the document's folder.  Usually set as a
file-local or directory-local variable; see also
`py-schematron-schema-type'."
  :type '(choice (const :tag "Detect from <?xml-model?>" nil) file)
  :safe #'string-or-null-p)

(defcustom py-schematron-schema-type 'rng
  "Type of the file in `py-schematron-schema'.
Ignored when the schema is detected from the document."
  :type '(choice (const :tag "RelaxNG with embedded Schematron" rng)
                 (const :tag "Schematron (.sch)" sch)
                 (const :tag "TEI ODD" odd))
  :safe (lambda (v) (memq v '(rng sch odd))))

(defcustom py-schematron-relaxng t
  "Whether to check the structure with jing when the schema is RelaxNG."
  :type 'boolean
  :safe #'booleanp)

(defcustom py-schematron-jing "jing"
  "The jing program, for the RelaxNG check."
  :type 'string)

(defcustom py-schematron-timeout 120
  "Seconds after which a check is abandoned."
  :type 'natnum)

(defcustom py-schematron-live-max-size nil
  "Largest buffer, in characters, that is checked as you type.
Larger buffers are checked when they are opened and saved only.
When nil, every buffer is checked as you type.  Takes effect
when `py-schematron-mode' is turned on."
  :type '(choice (const :tag "No limit" nil) natnum))

(defcustom py-schematron-frontend 'auto
  "Which checker shows the problems.
`auto' uses Flycheck when it is installed, and Flymake otherwise.
Takes effect when `py-schematron-mode' is turned on."
  :type '(choice (const :tag "Flycheck if installed, else Flymake" auto)
                 (const :tag "Flymake" flymake)
                 (const :tag "Flycheck" flycheck)))

(defcustom py-schematron-nxml-schema t
  "Whether to give `nxml-mode' the document's RelaxNG schema.
After a check whose schema is RelaxNG, the schema is converted to
the compact syntax with trang (see `py-schematron-trang'), kept in
a cache, and set as the buffer's nxml schema, for completion and
nxml's own validation.  A schema chosen otherwise for nxml (for
example through schemas.xml) is never replaced."
  :type 'boolean)

(defcustom py-schematron-trang "trang"
  "The trang converter, for `py-schematron-nxml-schema'.
A program name, or a list: a command and its first arguments, as
  (\"java\" \"-jar\" \"~/bin/trang.jar\")
The input and output options and files are added after them."
  :type '(choice string (repeat string)))

(defconst py-schematron--log-buffer "*py-schematron log*"
  "Buffer that keeps what py-schematron.py and jing print on stderr.")

(defvar-local py-schematron--run nil
  "The check under way in this buffer, as a plist, or nil.")

(defvar-local py-schematron--refresh nil
  "Non-nil when the next check should download the schema again.")


;;;; Reading the programs' output (no side effects)

(defun py-schematron--severity (role)
  "Flymake type for a Schematron ROLE.
A role that names a level wins; otherwise the problem is an error."
  (pcase (downcase (string-trim (or role "")))
    ((or "warning" "warn") :warning)
    ((or "info" "information" "hint") :note)
    (_ :error)))

(defun py-schematron--item (line message type origin &optional code col rules)
  "A problem as a plist: MESSAGE at LINE, of TYPE, found by ORIGIN.
LINE is 1-based (nil when unknown), COL 0-based or nil.  TYPE is a
Flymake type, ORIGIN \"Schematron\", \"RelaxNG\" or \"XML\", and
CODE the Schematron pattern, if any.  RULES are links to the rules
behind it (see `py-schematron--rule-link')."
  (list :line line :col col :message message :type type
        :origin origin :code code :rules rules))

(defun py-schematron--malformed-items (message line)
  "Items for a document that is not well formed.
MESSAGE and LINE are the parser's.  The parser reports where it
noticed the problem, which for a tag mismatch is the closing tag,
often far from the typo; so the line where the unclosed tag was
opened is reported too."
  (let ((items (list (py-schematron--item line message :error "XML"))))
    (when (string-match
           "Opening and ending tag mismatch: \\([^ \t\n]+\\) line \\([0-9]+\\) and \\([^ \t\n,]+\\)"
           message)
      (let ((opened (match-string 1 message))
            (at (string-to-number (match-string 2 message)))
            (closing (match-string 3 message)))
        (unless (eql at line)
          (push (py-schematron--item
                 at
                 (format "<%s> opened here is never closed: the next end tag is </%s>%s.  Check for a typo in the element name."
                         opened closing (if line (format " (line %d)" line) ""))
                 :error "XML")
                (cdr items)))))
    items))

(defun py-schematron--rule-link (rule &optional what)
  "A link to RULE, the hash table {file, line} of an assert or report.
As a plist (:file :line :label); nil when RULE names no file.  WHAT
starts the label (default \"The rule\")."
  (let ((file (and rule (gethash "file" rule)))
        (line (and rule (py-schematron--number (gethash "line" rule)))))
    (and (stringp file)
         (list :file file :line line
               :label (format "%s: %s%s" (or what "The rule") (file-name-nondirectory file)
                              (if line (format ", line %d" line) ""))))))

(defun py-schematron--json-items (json)
  "Items from the parsed --json output JSON of py-schematron.py.
JSON is a hash table, as `json-parse-string' returns it.  There is
only one document, the one being checked."
  (let ((doc (car (append (gethash "documents" json) nil))))
    (cond
     ((null doc) nil)
     ((gethash "error" doc)
      (py-schematron--malformed-items (gethash "error" doc)
                                       (py-schematron--number (gethash "error_line" doc))))
     (t
      (let ((items
             (mapcar (lambda (v)
                       (py-schematron--item
                        (py-schematron--number (gethash "line" v))
                        (let ((text (gethash "text" v)))
                          (if (and (stringp text) (not (string-empty-p text)))
                              text
                            (gethash "message" v)))
                        (py-schematron--severity (gethash "role" v))
                        "Schematron"
                        (let ((p (gethash "pattern" v)))
                          (and (stringp p) (not (string-empty-p p)) p))
                        nil
                        (delq nil (list (py-schematron--rule-link (gethash "rule" v))))))
                     (gethash "violations" doc)))
            (errs (append (gethash "xpath_errors" doc) nil)))
        (when errs
          (setq items
                (append items
                        (list (py-schematron--item
                               nil
                               (format "%d rule(s) failed to evaluate; the verdict is incomplete.\n%s"
                                       (length errs)
                                       (mapconcat
                                        (lambda (e)
                                          (format "- %s [%s]: %s (%s nodes)"
                                                  (let ((m (gethash "message" e)))
                                                    (if (and (stringp m) (not (string-empty-p m)))
                                                        m "(no message)"))
                                                  (gethash "context" e) (gethash "error" e)
                                                  (gethash "nodes" e)))
                                        errs "\n"))
                               :warning "Schematron" nil nil
                               (delq nil (mapcar
                                          (lambda (e)
                                            (py-schematron--rule-link
                                             (gethash "rule" e)
                                             (format "Failed: %s"
                                                     (let ((m (gethash "message" e)))
                                                       (if (and (stringp m) (not (string-empty-p m)))
                                                           m (gethash "context" e))))))
                                          errs)))))))
        items)))))

(defun py-schematron--number (v)
  "V if it is a positive number, else nil (JSON null, false, 0)."
  (and (numberp v) (> v 0) v))

(defconst py-schematron--jing-re
  "^\\(.*?\\):\\([0-9]+\\):\\([0-9]+\\): \\(error\\|warning\\|fatal\\): \\(.*\\)$"
  "A line of jing's output: FILE:LINE:COLUMN: LEVEL: MESSAGE.")

(defun py-schematron--jing-items (output file &optional drop-fatal)
  "Items from jing's OUTPUT about FILE.
DROP-FATAL leaves out the fatal (well-formedness) errors, which
py-schematron.py has already reported."
  (let ((target (expand-file-name file))
        items)
    (dolist (line (split-string output "\r?\n"))
      (when (string-match py-schematron--jing-re (string-trim line))
        (let ((f (match-string 1 (string-trim line)))
              (l (string-to-number (match-string 2 (string-trim line))))
              (c (string-to-number (match-string 3 (string-trim line))))
              (level (match-string 4 (string-trim line)))
              (msg (match-string 5 (string-trim line))))
          (when (and (equal (expand-file-name f) target)
                     (not (and drop-fatal (equal level "fatal"))))
            (push (py-schematron--item l msg (if (equal level "warning") :warning :error)
                                        "RelaxNG" nil (max (1- c) 0))
                  items)))))
    (nreverse items)))

(defun py-schematron--underline (text &optional col)
  "Columns (START . END) to underline on a line whose TEXT is given.
jing's column points just after the offending start tag, often at
the end of the line, which would give an empty underline; so it
runs from that tag's \"<\" to COL.  Without COL, the line's
content, without indentation and trailing spaces, is underlined."
  (let* ((first (string-match-p "[^ \t]" text))
         (whole (if first
                    (cons first (length (string-trim-right text)))
                  (cons 0 (length text)))))
    (if (null col)
        whole
      (let* ((c (min col (length text)))
             (lt (and (> c 0)
                      (let ((i (1- c)) found)
                        (while (and (>= i 0) (not found))
                          (if (eq (aref text i) ?<) (setq found i) (setq i (1- i))))
                        found))))
        (cond (lt (cons lt (max c (1+ lt))))
              ((< c (cdr whole)) (cons c (cdr whole)))
              (t whole))))))

(defun py-schematron--explain-failure (stderr python)
  "The best explanation, from STDERR, of a run that gave no JSON.
Since 1.21 py-schematron.py gives its own errors in JSON too; this
is for Python's own failures, and for older scripts.
PYTHON is the interpreter that was used."
  (if (string-match "No module named '?\\(saxonche\\|lxml\\)" stderr)
      (format "The Python interpreter \"%s\" does not have the '%s' library.  The easiest fix is py-schematron's installer, whose Python the package finds by itself (see the README); or set `py-schematron-python' to a Python that has saxonche and lxml, or install them into this one: %s -m pip install saxonche lxml"
              python (match-string 1 stderr) python)
    (let ((lines (seq-remove
                  (lambda (l)
                    (or (string-empty-p l)
                        (string-match-p "^\\[\\(caché\\|descarga\\|xml-model\\|esquema\\|extracción\\|cosecha\\|aviso\\)\\]" l)))
                  (mapcar #'string-trim (split-string stderr "\n")))))
      (if lines
          (string-join (last lines 3) " ")
        "py-schematron.py failed without a message."))))


;;;; Running the checks

(defun py-schematron--program (name)
  "Full name of the program NAME, or nil if it cannot be run.
NAME is looked up on the variable `exec-path', unless it contains a slash; then
it is a file name, and may start with \"~\"."
  (if (string-search "/" name)
      (let ((f (expand-file-name name)))
        (and (file-executable-p f) (not (file-directory-p f)) f))
    (executable-find name)))

(defun py-schematron--script-candidates ()
  "Where the package's py-schematron.py may be, most likely first.
package-vc and a plain clone keep it next to this file.  Straight
builds the package in a folder of its own, from links to the
files of its clone; following the link to this file leads back
to the clone.  The folder above is looked at last, as in the
layout of py-schematron before 0.3.0, when this file was in its
emacs/ folder."
  (let* ((dir py-schematron--directory)
         (real (file-name-directory
                (file-truename (expand-file-name "py-schematron.el" dir)))))
    (delete-dups
     (mapcar (lambda (d) (expand-file-name "py-schematron.py" d))
             (list dir real
                   (expand-file-name ".." dir) (expand-file-name ".." real))))))

(defun py-schematron--script ()
  "The py-schematron.py to run."
  (expand-file-name
   (or py-schematron-script
       (let ((candidates (py-schematron--script-candidates)))
         (or (seq-find #'file-readable-p candidates) (car candidates))))))

(defun py-schematron--applicable-p ()
  "Whether this buffer is one to check: it has a schema to go by."
  (or py-schematron-schema
      (save-excursion
        (save-restriction
          (widen)
          (goto-char (point-min))
          (search-forward "<?xml-model" nil t)))))

(defun py-schematron--log (text)
  "Append TEXT, a program's stderr, to the log buffer."
  (unless (string-empty-p (string-trim text))
    (with-current-buffer (get-buffer-create py-schematron--log-buffer)
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (insert (format-time-string "-- %T\n") (string-trim-right text) "\n")))))

(defun py-schematron--kill ()
  "Stop the check under way in this buffer, if any, and clean up."
  (when py-schematron--run
    (let ((run py-schematron--run))
      (setq py-schematron--run nil)
      (py-schematron--cleanup run))))

(defun py-schematron--cleanup (run)
  "Kill RUN's processes and timer, and delete its buffers and copy."
  (when-let* ((timer (plist-get run :timer))) (cancel-timer timer))
  (dolist (p (plist-get run :procs))
    (when (process-live-p p) (delete-process p)))
  (dolist (b (plist-get run :buffers))
    (when (buffer-live-p b) (kill-buffer b)))
  (when-let* ((dir (plist-get run :tmpdir)))
    (when (file-directory-p dir) (delete-directory dir t))))

(defun py-schematron--start (run name program args callback)
  "Run PROGRAM with ARGS for RUN, then call CALLBACK.
CALLBACK gets the exit code (nil when the program could not be
started), stdout and stderr.  NAME names the process."
  (let ((out (generate-new-buffer (format " *%s-out*" name)))
        (err (generate-new-buffer (format " *%s-err*" name)))
        (source (current-buffer)))
    (plist-put run :buffers (append (list out err) (plist-get run :buffers)))
    (if (null program)
        (funcall callback nil "" "")
     (condition-case e
        (let ((proc
               (make-process
                :name name :buffer out :stderr err
                :command (cons program args)
                :connection-type 'pipe :noquery t
                :sentinel
                (lambda (p _event)
                  (when (memq (process-status p) '(exit signal))
                    ;; Let the stderr pipe deliver its last output.
                    (when-let* ((ep (get-buffer-process err)))
                      (while (accept-process-output ep 0.05)))
                    (when (and (buffer-live-p source)
                               (eq run (buffer-local-value 'py-schematron--run source)))
                      (let ((stdout (with-current-buffer out (buffer-string)))
                            (stderr (with-current-buffer err (buffer-string))))
                        (py-schematron--log stderr)
                        (with-current-buffer source
                          (funcall callback
                                   (and (eq (process-status p) 'exit) (process-exit-status p))
                                   stdout stderr)))))))))
          (plist-put run :procs (cons proc (plist-get run :procs))))
      (file-error
       (funcall callback nil "" (error-message-string e)))))))

(defun py-schematron--region (it)
  "Buffer positions (BEG . END) to mark for the problem IT."
  (let* ((line (min (max (or (plist-get it :line) 1) 1)
                    (line-number-at-pos (point-max))))
         (bounds (save-excursion
                   (goto-char (point-min))
                   (forward-line (1- line))
                   (cons (point) (line-end-position))))
         (cols (py-schematron--underline
                (buffer-substring-no-properties (car bounds) (cdr bounds))
                (plist-get it :col)))
         (beg (+ (car bounds) (car cols)))
         (end (+ (car bounds) (cdr cols))))
    (when (= beg end)                     ; an empty line: mark one character
      (setq end (min (1+ beg) (point-max)))
      (when (= beg end) (setq beg (max (1- end) (point-min)))))
    (cons beg end)))

(defun py-schematron--diagnostics (items)
  "Flymake diagnostics, in the current buffer, for ITEMS."
  (save-restriction
    (widen)
    (mapcar
     (lambda (it)
       (let ((region (py-schematron--region it)))
         (flymake-make-diagnostic
          (current-buffer) (car region) (cdr region) (plist-get it :type)
          (list (plist-get it :origin) (plist-get it :code) (plist-get it :message)))))
     items)))

(defvar-local py-schematron--rules nil
  "The problems of the last check that link to their rules.
For `py-schematron-goto-rule'.")

(defun py-schematron--check (done)
  "Check the buffer, then call DONE in it with the problems found.
DONE gets the list of problems (see `py-schematron--item') and the
schema the check used, as (PATH . TYPE), or nil when there was none.
A check still under way in the buffer is cancelled first."
  (py-schematron--kill)
  (let* ((source (current-buffer))
         (done (lambda (items used)
                 (when (buffer-live-p source)
                   (with-current-buffer source
                     (setq py-schematron--rules
                           (seq-filter (lambda (i) (plist-get i :rules)) items))))
                 (funcall done items used)))
         (file buffer-file-name)
         (tmpdir (make-temp-file "py-schematron-" t))
         (input (expand-file-name (if file (file-name-nondirectory file) "document.xml")
                                  tmpdir))
         (refresh py-schematron--refresh)
         (schema (and py-schematron-schema
                      (expand-file-name py-schematron-schema)))
         (python (py-schematron--python))
         (run (list :tmpdir tmpdir :procs nil :buffers nil)))
    (setq py-schematron--refresh nil
          py-schematron--run run)
    ;; The buffer's text, saved or not, goes to a private copy;
    ;; --as makes py-schematron.py resolve relative xml-model hrefs and
    ;; report as if it were the real file.
    (let ((coding-system-for-write (or buffer-file-coding-system 'utf-8-unix)))
      (write-region nil nil input nil 'nomessage))
    (plist-put run :timer
               (run-with-timer
                py-schematron-timeout nil
                (let ((source (current-buffer)))
                  (lambda ()
                    (when (and (buffer-live-p source)
                               (eq run (buffer-local-value 'py-schematron--run source)))
                      (with-current-buffer source
                        (py-schematron--finish
                         run done
                         (list (py-schematron--item
                                nil (format "The check was abandoned after %d s (py-schematron-timeout)."
                                            py-schematron-timeout)
                                :error "py-schematron")))))))))
    (py-schematron--start
     run "py-schematron" (py-schematron--program python)
     (append (list (py-schematron--script) "--json")
             (and refresh '("--refresh"))
             (and schema (list (pcase py-schematron-schema-type
                                 ('sch "-s") ('odd "-o") (_ "-r"))
                               schema))
             (and file (list "--as" file))
             (list input))
     (lambda (code stdout stderr)
       (let* ((parsed (and code (string-prefix-p "{" (string-trim-left stdout))
                           (ignore-errors
                             (json-parse-string stdout :null-object nil :false-object nil))))
              ;; a report, or (since 1.21) the program's own fatal error
              (json (and parsed (gethash "documents" parsed) parsed))
              (fatal (and parsed (not json) (gethash "error" parsed))))
         (when refresh
           (py-schematron--say-refreshed stderr json))
         (if (null json)
             (py-schematron--finish
              run done
              (list (py-schematron--item
                     nil
                     (cond
                      ((stringp fatal) fatal)
                      (code (py-schematron--explain-failure stderr python))
                      (t (format "Could not run the Python interpreter \"%s\".  Install py-schematron with its installer, whose Python the package finds by itself, or set `py-schematron-python' to a Python that has saxonche and lxml (M-x py-schematron-check-setup)."
                               python)))
                     :error "py-schematron")))
           (let* ((items (py-schematron--json-items json))
                  (source (gethash "source" json))
                  (used (and source (cons (gethash "path" source) (gethash "type" source))))
                  (malformed (seq-some (lambda (d) (gethash "error" d))
                                       (gethash "documents" json))))
             (if (and py-schematron-relaxng used
                      (equal (cdr used) "rng")
                      (py-schematron--program py-schematron-jing))
                 (py-schematron--start
                  run "py-schematron-jing" (py-schematron--program py-schematron-jing)
                  (list (car used) input)
                  (lambda (jcode jout jerr)
                    (py-schematron--finish
                     run done
                     (append items
                             (if (memq jcode '(0 1))
                                 (py-schematron--jing-items jout input malformed)
                               (list (py-schematron--item
                                      nil (format "jing failed: %s"
                                                  (car (last (split-string (string-trim (concat jerr jout)) "\n"))))
                                      :warning "RelaxNG"))))
                     used)))
               (py-schematron--finish run done items used)))))))))

(defun py-schematron--finish (run done items &optional used)
  "End RUN and give DONE the ITEMS and the schema USED."
  (when (eq run py-schematron--run)
    (setq py-schematron--run nil))
  (py-schematron--cleanup run)
  (funcall done items used))

(defun py-schematron--downloaded-url (json stderr)
  "The URL py-schematron.py downloaded in a run, if any.
From the events of its JSON report; a script older than 1.21 has no
events, so then from its \"[descarga] URL\" line in STDERR."
  (let ((events (if json (gethash "events" json 'none) 'none)))
    (if (eq events 'none)
        (and (string-match "^\\[descarga\\] \\([^ \t\n]+\\)" stderr)
             (match-string 1 stderr))
      (seq-some (lambda (e) (and (equal (gethash "kind" e) "download") (gethash "url" e)))
                events))))

(defun py-schematron--say-refreshed (stderr json)
  "Tell what a --refresh run did, from its STDERR and JSON report."
  (cond
   ((py-schematron--downloaded-url json stderr)
    (message "py-schematron: schema downloaded again from %s"
             (py-schematron--downloaded-url json stderr)))
   (json
    (message "py-schematron: the schema is local (%s); nothing to download"
             (file-name-nondirectory (gethash "path" (gethash "source" json)))))
   (t (message "py-schematron: the schema could not be refreshed; see %s"
               py-schematron--log-buffer))))


;;;; Flymake

(defun py-schematron-flymake (report-fn &rest _args)
  "Flymake backend: check the buffer, then call REPORT-FN.
Each call cancels the check still under way, if any."
  (py-schematron--kill)
  (if (not (py-schematron--applicable-p))
      (funcall report-fn nil)
    (py-schematron--check
     (lambda (items used)
       (funcall report-fn (py-schematron--diagnostics items))
       (py-schematron--nxml-schema used)))))


;;;; Flycheck

(declare-function flycheck-define-generic-checker "ext:flycheck")
(declare-function flycheck-error-new-at-pos "ext:flycheck")
(declare-function flycheck-buffer "ext:flycheck")
(declare-function flycheck-mode "ext:flycheck")
(defvar flycheck-checker)
(defvar flycheck-checkers)
(defvar flycheck-mode)
(defvar flycheck-check-syntax-automatically)
(defvar py-schematron-mode)

(defvar py-schematron--flycheck-defined nil
  "Whether the Flycheck checker `py-schematron' has been defined.")

(defun py-schematron--flycheck-define ()
  "Define the Flycheck checker `py-schematron', once, for this major mode.
Flycheck has no `trusted-content' rule of its own, so the checker's
predicate applies it, as Flymake does."
  (unless py-schematron--flycheck-defined
    (flycheck-define-generic-checker 'py-schematron
      "Schematron, RELAX NG and well-formedness checks of XML/TEI documents,
with py-schematron.py and jing.  See `py-schematron-mode'."
      :start #'py-schematron--flycheck-start
      :interrupt (lambda (_checker _context) (py-schematron--kill))
      :modes '(nxml-mode xml-mode)
      :predicate (lambda () (and py-schematron-mode (trusted-content-p))))
    (add-to-list 'flycheck-checkers 'py-schematron t)
    (setq py-schematron--flycheck-defined t))
  ;; Flycheck wants a checker's major modes; the mode may be turned on
  ;; in others than nxml-mode, so they are added as they come.
  (unless (memq major-mode (get 'py-schematron 'flycheck-modes))
    (put 'py-schematron 'flycheck-modes
         (cons major-mode (get 'py-schematron 'flycheck-modes)))))

(defun py-schematron--flycheck-start (checker callback)
  "Start a check for Flycheck's CHECKER; report through CALLBACK."
  (if (not (py-schematron--applicable-p))
      (funcall callback 'finished nil)
    (py-schematron--check
     (lambda (items used)
       (funcall callback 'finished (py-schematron--flycheck-errors items checker))
       (py-schematron--nxml-schema used))))
  nil)

(defun py-schematron--flycheck-errors (items checker)
  "Flycheck errors of CHECKER, in the current buffer, for ITEMS."
  (save-restriction
    (widen)
    (mapcar
     (lambda (it)
       (let ((region (py-schematron--region it)))
         (flycheck-error-new-at-pos
          (car region)
          (pcase (plist-get it :type) (:warning 'warning) (:note 'info) (_ 'error))
          (format "%s: %s" (plist-get it :origin) (plist-get it :message))
          :end-pos (cdr region) :checker checker :id (plist-get it :code))))
     items)))


;;;; The schema for nxml

(declare-function rng-set-schema-file-1 "rng-loc" (filename))
(defvar rng-current-schema-file-name)

(defvar-local py-schematron--nxml-rnc nil
  "The compact schema this package gave nxml in this buffer, if any.")

(defvar py-schematron--converting (make-hash-table :test #'equal)
  "Conversions under way: compact schema file -> buffers waiting for it.")

(defvar py-schematron--trang-warned nil
  "Whether the missing trang has already been reported.")

;;;; Mending nxml
;;
;; nxml (Emacs 31 and earlier) has bugs in its XSD datatypes that make it
;; reject valid values in TEI and other schemas.  Each is checked for in
;; the running Emacs, and mended only there, so that an Emacs where it is
;; fixed is left alone.  Reported to Emacs as bug#82281 (damaged
;; category tables), bug#82282 (Unicode 3.1 categories), bug#82283 (class
;; subtraction, not mended here) and bug#82284 (collapsed whitespace).

(defcustom py-schematron-fix-nxml t
  "Whether to mend nxml's XSD datatypes where the running Emacs needs it.
When non-nil, as soon as nxml loads its XSD code, the package checks
the running Emacs for these bugs and mends each one found:
- building a Unicode category (\\p{P}, \\p{S}, \\p{C}) damages nxml's
  table of its last part, so # % ! @ ¿ and more are soon rejected;
- the categories are those of Unicode 3.1 (2001), and leave out every
  character beyond U+FFFF and from U+3400 to U+DFFF, so newer letters
  such as the medieval abbreviations ꝑ ꝯ, CJK and Gothic are rejected;
- a value of xsd:token or a similar type keeps one space at either
  end, so \" #U2\" fails TEI's teidata.word pattern.
`py-schematron-about' lists what was mended."
  :type 'boolean)

(defvar py-schematron--nxml-fixes nil
  "The nxml bugs mended in this session, as symbols.")

(defun py-schematron--xsdre-copy-ranges (args)
  "Copy the range lists that nxml's `xsdre-range-list-union' gets in ARGS.
That function joins them with `append', which does not copy the last
one, and then sorts and shortens the result in place.  So the cached
ranges of the last category of a union (Po in \\p{P}, So in \\p{S},
Cn in \\p{C}, and through them \\w) lose characters each time a
pattern uses it, and nxml soon rejects # % ! @ ¿ and more in values
the schema allows, like ed=\"#U2\" in TEI's teidata.word.  With
copies the tables stay whole.  Emacs bug#82281."
  (list (mapcar #'copy-sequence (car args))))

(declare-function xsdre-range-list-union "xsd-regexp" (range-lists))
(declare-function xsdre-make-range "xsd-regexp" (first last))
(declare-function xsdre-make-range-list "xsd-regexp" (list))
(declare-function xsdre-range-first "xsd-regexp" (r))
(declare-function xsdre-range-last "xsd-regexp" (r))
(defvar xsdre-mule-char-set-ranges)
(defvar xsdre-gen-categories)
(defvar xsdre-translations)

(defun py-schematron--xsdre-buggy-p ()
  "Whether this Emacs's `xsdre-range-list-union' changes its arguments.
It is given two fresh lists, the last one out of order, and the
result is whether that list came back changed: the bug of
`py-schematron--xsdre-copy-ranges', found without touching nxml's
tables.  Loads xsd-regexp."
  (require 'xsd-regexp)
  (let* ((last (list (cons 10 20) 5))
         (copy (copy-tree last)))
    (xsdre-range-list-union (list (list 1) last))
    (not (equal last copy))))

(defun py-schematron--in-ranges-p (char ranges)
  "Whether CHAR is in RANGES, a range-list of xsd-regexp."
  (seq-some (lambda (r) (<= (xsdre-range-first r) char (xsdre-range-last r))) ranges))

(defun py-schematron--xsdre-old-unicode-p ()
  "Whether nxml's Unicode categories are its old ones (Emacs bug#82282).
That is, whether the letter U+A751 (Unicode 5.1) is missing from Ll,
or the characters nxml's regexps can match stop short of U+10FFFF."
  (require 'xsd-regexp)
  (or (not (py-schematron--in-ranges-p #xA751 (get 'Ll 'xsdre-ranges)))
      (and (boundp 'xsdre-mule-char-set-ranges)
           (not (py-schematron--in-ranges-p #x10FFFF xsdre-mule-char-set-ranges)))))

(defun py-schematron--unicode-categories ()
  "The Unicode general categories nxml defines, from Emacs's own data.
An alist (CATEGORY . RANGES), RANGES a range-list of xsd-regexp, from
`unicode-category-table', for the characters up to U+10FFFF."
  (let ((ranges nil)
        (names (make-hash-table)))
    (map-char-table
     (lambda (key value)
       (let ((first (if (consp key) (car key) key))
             (last (if (consp key) (cdr key) key)))
         (when (and value (<= first #x10FFFF))
           (let ((name (or (gethash value names)
                           (puthash value (get-char-code-property first 'general-category)
                                    names))))
             (when (memq name xsdre-gen-categories)
               (push (xsdre-make-range first (min last #x10FFFF))
                     (alist-get name ranges)))))))
     unicode-category-table)
    (mapcar (lambda (name) (cons name (xsdre-make-range-list (alist-get name ranges))))
            xsdre-gen-categories)))

(defvar py-schematron--translations (make-hash-table :test #'equal)
  "Translations of XSD regexps, made once each.
See `py-schematron--cache-translation'.")

(defvar py-schematron--cached-classes nil
  "Derived categories whose ranges this package cached.")

(defun py-schematron--cache-translation (translate regexp)
  "Call TRANSLATE on REGEXP only the first time.
With the current Unicode categories a translation can take several
milliseconds, and a TEI schema uses the same few patterns hundreds
of times."
  (or (gethash regexp py-schematron--translations)
      (puthash regexp (funcall translate regexp) py-schematron--translations)))

(defun py-schematron--cache-class (ranges-of cc)
  "Call RANGES-OF on CC, a char-class, once for a derived category such as L."
  (if (and (symbolp cc) (not (get cc 'xsdre-ranges)) (get cc 'xsdre-char-class))
      (progn (push cc py-schematron--cached-classes)
             (put cc 'xsdre-ranges (funcall ranges-of cc)))
    (funcall ranges-of cc)))

(defun py-schematron--trim-collapsed (args)
  "Remove the spaces at either end of the string in ARGS.
For nxml's `rng-xsd-collapse-space', which keeps one at either end
\(Emacs bug#82284)."
  (cons (string-trim (car args) "[ \t\n\r]+" "[ \t\n\r]+") (cdr args)))

(declare-function rng-xsd-collapse-space "rng-xsd" (str convert &rest args))

(defun py-schematron--rng-xsd-buggy-p ()
  "Whether nxml's whitespace collapsing keeps a space at either end."
  (require 'rng-xsd)
  (equal (rng-xsd-collapse-space " a " #'identity) " a "))

(defvar py-schematron--xsdre-checked nil
  "Whether `py-schematron--fix-xsdre' has already looked at this Emacs.")

(defvar py-schematron--rng-xsd-checked nil
  "Whether `py-schematron--fix-rng-xsd' has already looked at this Emacs.")

(defun py-schematron--fix-xsdre ()
  "Mend nxml's regexps of Unicode categories, if this Emacs needs it.
Two bugs, each mended only when this Emacs has it (see
`py-schematron-fix-nxml'): the damaged tables of
`py-schematron--xsdre-copy-ranges', and the old categories of
`py-schematron--xsdre-old-unicode-p', which are rebuilt from Emacs's
own Unicode data, with caches so that nxml is no slower.  If the
first bug had already damaged the tables in this session and the
categories are not rebuilt, they are restored by loading
xsd-regexp's source again.  (Its source: a compiled file, natively
compiled above all, may give back the same, damaged, lists.)"
  (when (and py-schematron-fix-nxml (not py-schematron--xsdre-checked))
    (setq py-schematron--xsdre-checked t)
    (let ((was-loaded (featurep 'xsd-regexp))
          (copy (py-schematron--xsdre-buggy-p))
          (unicode (py-schematron--xsdre-old-unicode-p)))
      (when copy
        (advice-add 'xsdre-range-list-union :filter-args #'py-schematron--xsdre-copy-ranges)
        (push 'category-tables py-schematron--nxml-fixes))
      (when unicode
        (dolist (category (py-schematron--unicode-categories))
          (put (car category) 'xsdre-ranges (cdr category)))
        (when (boundp 'xsdre-mule-char-set-ranges)
          (setq xsdre-mule-char-set-ranges '((0 . #x10FFFF))))
        (unless (boundp 'xsdre-translations)               ; (Emacs's own caches)
          (advice-add 'xsdre-translate :around #'py-schematron--cache-translation)
          (advice-add 'xsdre-char-class-to-range-list :around #'py-schematron--cache-class))
        (push 'unicode py-schematron--nxml-fixes))
      (when (and copy was-loaded (not unicode))
        (condition-case err
            (unless (let ((inhibit-message t) (message-log-max nil))   ; ("uncompressing...")
                      (load "xsd-regexp.el" t t))
              (py-schematron--log "nxml's xsd-regexp.el was not found, so tables damaged \
before this package mended nxml stay so until Emacs restarts"))
          (error (py-schematron--log (format "xsd-regexp.el could not be loaded again: %s"
                                              (error-message-string err))))))
      (when (or copy unicode)
        (py-schematron--log (format "nxml mended: %s" py-schematron--nxml-fixes))))))

(defun py-schematron--fix-rng-xsd ()
  "Mend nxml's whitespace collapsing, if this Emacs needs it.
See `py-schematron--trim-collapsed' and `py-schematron-fix-nxml'."
  (when (and py-schematron-fix-nxml (not py-schematron--rng-xsd-checked))
    (setq py-schematron--rng-xsd-checked t)
    (when (py-schematron--rng-xsd-buggy-p)
      (advice-add 'rng-xsd-collapse-space :filter-args #'py-schematron--trim-collapsed)
      (push 'whitespace py-schematron--nxml-fixes)
      (py-schematron--log (format "nxml mended: %s" py-schematron--nxml-fixes)))))

;; As soon as nxml loads its XSD code, before it compiles any schema.
(with-eval-after-load 'xsd-regexp (py-schematron--fix-xsdre))
(with-eval-after-load 'rng-xsd (py-schematron--fix-rng-xsd))

(defun py-schematron-unload-function ()
  "Undo the package's mending of nxml when the package is unloaded.
The rebuilt Unicode categories stay, being correct."
  (advice-remove 'xsdre-range-list-union #'py-schematron--xsdre-copy-ranges)
  (advice-remove 'xsdre-translate #'py-schematron--cache-translation)
  (advice-remove 'xsdre-char-class-to-range-list #'py-schematron--cache-class)
  (advice-remove 'rng-xsd-collapse-space #'py-schematron--trim-collapsed)
  (dolist (cc py-schematron--cached-classes) (put cc 'xsdre-ranges nil))
  (clrhash py-schematron--translations)
  (setq py-schematron--cached-classes nil
        py-schematron--nxml-fixes nil
        py-schematron--xsdre-checked nil
        py-schematron--rng-xsd-checked nil)
  nil)

(defun py-schematron--rnc-file (rng)
  "Where the compact version of the schema RNG is kept."
  (expand-file-name
   (format "%s-%s.rnc" (substring (md5 (file-truename rng)) 0 12) (file-name-base rng))
   (locate-user-emacs-file "py-schematron/rnc/")))

(defun py-schematron--trang-command ()
  "The trang command as a list, or nil if it cannot be run."
  (let* ((spec (if (stringp py-schematron-trang) (list py-schematron-trang) py-schematron-trang))
         (program (and spec (py-schematron--program (car spec)))))
    (and program
         (cons program (mapcar (lambda (a) (if (string-prefix-p "~" a) (expand-file-name a) a))
                               (cdr spec))))))

(defun py-schematron--nxml-eligible-p ()
  "Whether this package may set the buffer's nxml schema."
  (and py-schematron-nxml-schema
       (derived-mode-p 'nxml-mode)
       (boundp 'rng-current-schema-file-name)
       (or (null rng-current-schema-file-name)        ; nxml's vacuous schema
           (equal rng-current-schema-file-name py-schematron--nxml-rnc))))

(defvar-local py-schematron--rnc-force nil
  "Non-nil: the next check converts the schema for nxml again.
Set by `py-schematron-recreate-nxml-schema'.")

(defun py-schematron--nxml-schema (used)
  "Give nxml the RELAX NG schema USED by the check, as (PATH . TYPE).
The compact copy is converted again when the RelaxNG file is newer,
or when `py-schematron-recreate-nxml-schema' asked for it."
  (let ((force py-schematron--rnc-force))
    (setq py-schematron--rnc-force nil)
    (if (and used (equal (cdr used) "rng") (car used)
             (file-readable-p (car used)) (py-schematron--nxml-eligible-p))
        (let* ((rng (car used))
               (rnc (py-schematron--rnc-file rng)))
          (cond
           ((and (not force) (file-exists-p rnc) (not (file-newer-than-file-p rng rnc)))
            (py-schematron--nxml-apply rnc))
           ((gethash rnc py-schematron--converting)
            (cl-pushnew (current-buffer) (gethash rnc py-schematron--converting)))
           (t (py-schematron--convert rng rnc force))))
      (when force
        (message "py-schematron: %s"
                 (cond ((null used) "the check found no schema, so nxml gets none")
                       ((not (equal (cdr used) "rng"))
                        (format "the schema is not RelaxNG (%s), so nxml gets none" (cdr used)))
                       (t "nxml's schema was not recreated")))))))

(defun py-schematron--nxml-apply (rnc &optional reload)
  "Set the compact schema RNC as the buffer's nxml schema.
With RELOAD, load it again even if it is already the buffer's
schema (after it was converted again).  `rng-set-schema-file-1' is
used, not `rng-set-schema-file', which would offer to save the
schema's location in a schemas.xml file next to the document.  nxml
revalidates by itself when the schema changes."
  (when (and (py-schematron--nxml-eligible-p)
             (or reload (not (equal rng-current-schema-file-name rnc))))
    (condition-case err
        (progn
          (py-schematron--fix-xsdre)
          (py-schematron--fix-rng-xsd)
          (rng-set-schema-file-1 rnc)
          (setq py-schematron--nxml-rnc rnc))
      (error
       (py-schematron--log (format "nxml could not load %s: %s" rnc (error-message-string err)))))))

(defun py-schematron--convert (rng rnc &optional announce)
  "Convert RNG to the compact schema RNC with trang, then apply it.
Every buffer that waits for RNC or already uses it loads the new
copy.  With ANNOUNCE, say so when it is done."
  (let ((command (py-schematron--trang-command)))
    (if (null command)
        (unless py-schematron--trang-warned
          (setq py-schematron--trang-warned t)
          (message "py-schematron: trang not found (%s), so nxml gets no schema; see `py-schematron-trang'"
                   py-schematron-trang))
      (make-directory (file-name-directory rnc) t)
      (let* ((tmpdir (make-temp-file "py-schematron-rnc-" t))
             (out (expand-file-name "schema.rnc" tmpdir))
             (log (generate-new-buffer " *py-schematron-trang*")))
        (puthash rnc (list (current-buffer)) py-schematron--converting)
        (condition-case e
            (make-process
             :name "py-schematron-trang" :buffer log :noquery t :connection-type 'pipe
             :command (append command (list "-I" "rng" "-O" "rnc" rng out))
             :sentinel
             (lambda (p _event)
               (when (memq (process-status p) '(exit signal))
                 (let ((waiting (gethash rnc py-schematron--converting)))
                   (remhash rnc py-schematron--converting)
                   (if (and (eq (process-status p) 'exit) (eq (process-exit-status p) 0)
                            (file-exists-p out))
                       (let ((n 0))
                         (py-schematron--write-rnc out rnc)
                         (dolist (b (buffer-list))
                           (with-current-buffer b
                             (when (or (memq b waiting)
                                       (equal py-schematron--nxml-rnc rnc))
                               (py-schematron--nxml-apply rnc t)
                               (when (equal py-schematron--nxml-rnc rnc)
                                 (setq n (1+ n))))))
                         (when announce
                           (message "py-schematron: nxml's schema recreated from %s (%d buffer%s)"
                                    (file-name-nondirectory rng) n (if (= n 1) "" "s"))))
                     (py-schematron--log (format "trang could not convert %s:\n%s" rng
                                                  (with-current-buffer log (buffer-string))))
                     (when announce
                       (message "py-schematron: trang could not convert %s; see %s"
                                (file-name-nondirectory rng) py-schematron--log-buffer))))
                 (kill-buffer log)
                 (delete-directory tmpdir t))))
          (file-error
           (remhash rnc py-schematron--converting)
           (kill-buffer log)
           (delete-directory tmpdir t)
           (py-schematron--log (format "trang could not be run: %s" (error-message-string e)))))))))

(defun py-schematron--write-rnc (from to)
  "Copy the compact schema FROM to TO, atomically."
  (let ((text (with-temp-buffer
                (insert-file-contents from)
                (buffer-string)))
        (tmp (make-temp-file (expand-file-name ".tmp-" (file-name-directory to)) nil ".rnc")))
    (with-temp-file tmp
      (set-buffer-file-coding-system 'utf-8-unix)
      (insert text))
    (rename-file tmp to t)))

(defun py-schematron--nxml-forget ()
  "Take back the schema this package gave nxml, if it is still in use."
  (when (and py-schematron--nxml-rnc (boundp 'rng-current-schema-file-name)
             (equal rng-current-schema-file-name py-schematron--nxml-rnc))
    (rng-set-schema-file-1 nil))
  (setq py-schematron--nxml-rnc nil))


;;;; Commands and the minor mode

(defvar-local py-schematron--using nil
  "The checker this buffer uses: `flymake' or `flycheck'.")

(defvar-local py-schematron--own-flycheck nil
  "Whether `py-schematron-mode' turned Flycheck on in this buffer.")

(defun py-schematron--frontend ()
  "The checker to use, from `py-schematron-frontend'."
  (pcase py-schematron-frontend
    ('flymake 'flymake)
    ('flycheck 'flycheck)
    (_ (if (or (featurep 'flycheck) (locate-library "flycheck")) 'flycheck 'flymake))))

(defun py-schematron--start-check ()
  "Start a check with the buffer's checker."
  (if (eq py-schematron--using 'flycheck)
      (flycheck-buffer)
    (flymake-start nil t)))

;;;###autoload
(define-minor-mode py-schematron-mode
  "Check the buffer against its Schematron rules, with Flycheck or Flymake.
The schema comes from the document's <?xml-model?> processing
instructions, or from `py-schematron-schema'.  Problems are
underlined as you type, and the checker's list shows them all.
`py-schematron-frontend' chooses the checker.  In `nxml-mode' the
document's RELAX NG schema is also given to nxml, for completion
\(see `py-schematron-nxml-schema').

Only files in `trusted-content' are checked, because the schema
named in a document can make Saxon read files and fetch URLs."
  :lighter nil
  (if py-schematron-mode
      (let ((big (and py-schematron-live-max-size
                      (> (buffer-size) py-schematron-live-max-size))))
        (setq py-schematron--using (py-schematron--frontend))
        (add-hook 'kill-buffer-hook #'py-schematron--kill nil t)
        (unless (trusted-content-p)
          (py-schematron--warn-untrusted))
        (if (eq py-schematron--using 'flycheck)
            (progn
              (require 'flycheck)
              (py-schematron--flycheck-define)
              (setq-local flycheck-checker 'py-schematron)
              (when big
                (setq-local flycheck-check-syntax-automatically
                            (cl-set-difference flycheck-check-syntax-automatically
                                               '(idle-change new-line))))
              (if flycheck-mode
                  (flycheck-buffer)
                (setq py-schematron--own-flycheck t)
                (flycheck-mode 1)))
          (add-hook 'flymake-diagnostic-functions #'py-schematron-flymake nil t)
          (when big
            (setq-local flymake-no-changes-timeout nil))
          (flymake-mode 1)))
    (py-schematron--kill)
    (if (eq py-schematron--using 'flycheck)
        (progn
          (kill-local-variable 'flycheck-checker)
          (kill-local-variable 'flycheck-check-syntax-automatically)
          (cond (py-schematron--own-flycheck (flycheck-mode -1))
                (flycheck-mode (flycheck-buffer))))
      (remove-hook 'flymake-diagnostic-functions #'py-schematron-flymake t)
      (kill-local-variable 'flymake-no-changes-timeout)
      (when flymake-mode (flymake-start)))
    (setq py-schematron--own-flycheck nil
          py-schematron--using nil)
    (py-schematron--nxml-forget)))

(defvar py-schematron--warned (make-hash-table :test #'equal)
  "Files already warned about as untrusted, in this session.")

(defun py-schematron--name ()
  "The visited file's name as `trusted-content' compares it."
  (and buffer-file-truename (abbreviate-file-name buffer-file-truename)))

(defun py-schematron--untrusted-text ()
  "Why the current buffer is not checked, and what to do about it."
  (if (py-schematron--name)
      ;; The Lisp line goes through `format', not `format-message',
      ;; whose curly quotes would make it wrong to paste.
      (concat
       (format-message
        "%s is not in `trusted-content', so it is not checked as you type.  \
To check it, run M-x py-schematron-trust-file, or add to your init file:\n"
        (py-schematron--name))
       (format "  (add-to-list 'trusted-content %S)\n" (py-schematron--name))
       "Only trust files you know: the schema a document names is run by \
Saxon, and its rules can read files and fetch URLs.")
    (format-message "%s visits no file, and only files in `trusted-content' are checked."
                    (buffer-name))))

(defun py-schematron--warn-untrusted ()
  "Warn, once per file and session, that this buffer is not checked."
  (let ((key (or (py-schematron--name) (buffer-name))))
    (unless (gethash key py-schematron--warned)
      (puthash key t py-schematron--warned)
      (display-warning 'py-schematron (py-schematron--untrusted-text) :warning))))

(defun py-schematron--require-trust ()
  "Signal a `user-error' explaining why, if the buffer is not trusted."
  (unless (trusted-content-p)
    (user-error "%s" (car (split-string (py-schematron--untrusted-text) "\n")))))

;;;###autoload
(defun py-schematron-trust-file ()
  "Trust the visited file, or its folder, and start checking it.
Asks first.  The file or folder is added to `trusted-content' for
this session; the line that keeps it for future sessions is put
in the kill ring, to paste into your init file."
  (interactive)
  (let ((name (py-schematron--name)))
    (unless name
      (user-error "This buffer visits no file"))
    (if (trusted-content-p)
        (message "py-schematron: %s is already trusted" name)
      (let* ((folder (file-name-directory name))
             (choice (car (read-multiple-choice
                           (format-message
                            "Trust %s?  Its schema's rules can read files and fetch URLs; trust only files you know"
                            name)
                           `((?f "file" ,(format "Trust only %s" name))
                             (?d "folder" ,(format "Trust every file in %s" folder))
                             (?q "quit" "Trust nothing"))))))
        (unless (eq choice ?q)
          (let* ((entry (if (eq choice ?d) folder name))
                 (line (format "(add-to-list 'trusted-content %S)" entry)))
            (unless (eq trusted-content :all)
              (setq trusted-content (append trusted-content (list entry))))
            (kill-new line)
            (dolist (b (buffer-list))
              (with-current-buffer b
                (when (and py-schematron-mode (trusted-content-p))
                  (py-schematron--start-check))))
            (message "py-schematron: trusted %s for this session; to keep it, paste into your init file (it is in the kill ring): %s"
                     entry line)))))))

(defun py-schematron--ensure-mode ()
  "Turn on `py-schematron-mode' if it is off."
  (unless py-schematron-mode (py-schematron-mode 1)))

;;;###autoload
(defun py-schematron-check ()
  "Check the buffer now."
  (interactive)
  (py-schematron--ensure-mode)
  (py-schematron--require-trust)
  (py-schematron--start-check))

;;;###autoload
(defun py-schematron-refresh-schema ()
  "Download the document's remote schema again, then check the buffer.
For when the schema has changed upstream: py-schematron.py keeps
a downloaded schema in its cache for a day."
  (interactive)
  (py-schematron--ensure-mode)
  (py-schematron--require-trust)
  (setq py-schematron--refresh t)
  (message "py-schematron: refreshing the schema...")
  (py-schematron--start-check))

;;;###autoload
(defun py-schematron-recreate-nxml-schema ()
  "Convert the document's RelaxNG schema for nxml again, and reload it.
The compact copy that nxml uses is normally converted again only when
the RelaxNG file is newer; this converts it now, with a new check,
and reloads it in every buffer that uses it.  Useful when the cached
copy is suspect, or after changing `py-schematron-trang'."
  (interactive)
  (unless (derived-mode-p 'nxml-mode)
    (user-error "Only an nxml-mode buffer has an nxml schema to recreate"))
  (unless py-schematron-nxml-schema
    (user-error "The schema for nxml is turned off (`py-schematron-nxml-schema')"))
  (unless (py-schematron--trang-command)
    (user-error "No trang found (%s); see `py-schematron-trang'" py-schematron-trang))
  (py-schematron--ensure-mode)
  (py-schematron--require-trust)
  (unless (py-schematron--nxml-eligible-p)
    (user-error "This buffer's nxml schema was chosen otherwise (%s); it is not replaced"
                (abbreviate-file-name rng-current-schema-file-name)))
  (setq py-schematron--rnc-force t)
  (message "py-schematron: recreating nxml's schema...")
  (py-schematron--start-check))

;;;###autoload
(defun py-schematron-report ()
  "Show the full report of the visited file, with clickable lines.
Runs py-schematron.py -v on the saved file, in a compilation
buffer; each detailed problem links to its line.  It runs even
when the file is not in `trusted-content', since you asked for
it; the report then ends with a note that live checking is off."
  (interactive)
  (unless buffer-file-name
    (user-error "The buffer is not visiting a file"))
  (when (and (buffer-modified-p)
             (y-or-n-p "Save the buffer first? "))
    (save-buffer))
  (let* ((file buffer-file-name)
         (untrusted (and (not (trusted-content-p)) (py-schematron--untrusted-text)))
         (default-directory (file-name-directory file))
         (args (append (and py-schematron-schema
                            (list (pcase py-schematron-schema-type
                                    ('sch "-s") ('odd "-o") (_ "-r"))
                                  (expand-file-name py-schematron-schema)))
                       (list "-v" file))))
    (with-current-buffer
        (compilation-start
         (mapconcat #'shell-quote-argument
                    (append (list (or (py-schematron--program (py-schematron--python))
                                      (py-schematron--python))
                                  (py-schematron--script))
                            args)
                    " ")
         #'py-schematron-report-mode
         (lambda (_mode) "*py-schematron report*"))
      (setq-local py-schematron--report-file file)
      (setq-local py-schematron--report-untrusted untrusted))))

(defvar-local py-schematron--report-file nil
  "The file a report buffer is about.")
(put 'py-schematron--report-file 'permanent-local t)

(defvar-local py-schematron--report-untrusted nil
  "When the file is not trusted, the note that ends the report.")
(put 'py-schematron--report-untrusted 'permanent-local t)

(defun py-schematron--report-note (buffer _how)
  "End the report in BUFFER with the note about trust, if any."
  (with-current-buffer buffer
    (when py-schematron--report-untrusted
      (let ((inhibit-read-only t))
        (save-excursion
          (goto-char (point-max))
          (insert "\nNote: " py-schematron--report-untrusted "\n"))))))

(define-compilation-mode py-schematron-report-mode "py-schematron"
  "Mode of the buffer of \\[py-schematron-report]."
  (setq-local compilation-exit-message-function #'py-schematron--report-exit)
  (add-hook 'compilation-finish-functions #'py-schematron--report-note nil t)
  (setq-local compilation-error-regexp-alist '(py-schematron))
  (setq-local compilation-error-regexp-alist-alist
              '((py-schematron
                 "^  l\\. +\\([0-9]+\\)  \\[[^]\n]*\\]  " py-schematron--report-file-name 1))))

(defun py-schematron--report-exit (status code msg)
  "The report's last line, from the exit CODE of py-schematron.py.
STATUS and MSG are as in `compilation-exit-message-function'."
  (if (eq status 'exit)
      (pcase code
        (0 '("valid: no violations\n" . "valid"))
        (1 '("violations found\n" . "violations"))
        (3 '("incomplete: a document not well formed, a rule that could not be evaluated, or an error (see above)\n" . "incomplete"))
        (_ (cons msg (number-to-string code))))
    (cons msg (number-to-string code))))

(defun py-schematron--report-file-name ()
  "The file the report buffer is about, for its links."
  py-schematron--report-file)

;;;###autoload
(defun py-schematron-show-log ()
  "Show what py-schematron.py and jing printed on stderr."
  (interactive)
  (display-buffer (get-buffer-create py-schematron--log-buffer)))

;;;###autoload
(defun py-schematron-check-setup ()
  "Say whether Python, its libraries, the script, jing and trang are in place.
Also says which checker, Flycheck or Flymake, is used."
  (interactive)
  (let* ((python (py-schematron--program (py-schematron--python)))
         (script (py-schematron--script))
         (jing (py-schematron--program py-schematron-jing))
         (lines nil))
    (cl-flet ((say (ok text) (push (concat (if ok "  ok   " "  NO   ") text) lines)))
      (if (not python)
          (say nil (format "Python: \"%s\" not found.  Run py-schematron's installer, or set `py-schematron-python'."
                           (py-schematron--python)))
        (let ((probe (with-temp-buffer
                       (cons (call-process python nil t nil "-c"
                                           "import sys; print(sys.version.split()[0]); import saxonche, lxml")
                             (string-trim (buffer-string))))))
          (say (eq (car probe) 0)
               (if (eq (car probe) 0)
                   (format "Python: %s (%s), with saxonche and lxml" python (car (split-string (cdr probe) "\n")))
                 (format "Python: %s cannot import saxonche and lxml.  Install them: %s -m pip install saxonche lxml"
                         python python)))))
      (say (file-readable-p script)
           (format "Script: %s%s" script (if (file-readable-p script) "" " (missing; set `py-schematron-script')")))
      (say jing (if jing (format "jing: %s" jing)
                  (format "jing: \"%s\" not found; the RelaxNG check is skipped (optional)" py-schematron-jing)))
      (let ((frontend (py-schematron--frontend)))
        (say t (format "Checker: %s%s" frontend
                       (if (eq py-schematron-frontend 'auto)
                           (format " (py-schematron-frontend is auto: Flycheck %s)"
                                   (if (eq frontend 'flycheck) "is installed" "is not installed"))
                         ""))))
      (when py-schematron-nxml-schema
        (let ((trang (py-schematron--trang-command)))
          (say trang (if trang
                         (format "trang: %s (nxml gets the document's schema)" (string-join trang " "))
                       (format "trang: %S not found; nxml gets no schema (optional; see `py-schematron-trang')"
                               py-schematron-trang))))))
    (with-current-buffer (get-buffer-create "*py-schematron setup*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "py-schematron setup\n\n" (string-join (nreverse lines) "\n") "\n")
        (special-mode))
      (display-buffer (current-buffer)))))

;;;###autoload
(defun py-schematron-goto-rule ()
  "Open the schema at the rule behind the Schematron error on this line.
That is the assert or report that reported it, in the ODD or RelaxNG
it came from (the file one edits), as py-schematron.py 1.21 and
later say.  With several, choose one.  A problem with no line (rules
that failed to evaluate) is taken as on the first line.  \\[xref-go-back]
returns."
  (interactive)
  (let* ((here (line-number-at-pos))
         (links (seq-mapcat (lambda (i) (plist-get i :rules))
                            (seq-filter (lambda (i) (eql (or (plist-get i :line) 1) here))
                                        py-schematron--rules)))
         (link (cond
                ((null links)
                 (user-error "No Schematron error with a known rule on this line"))
                ((null (cdr links)) (car links))
                (t (let ((label (completing-read "Which rule? "
                                                 (mapcar (lambda (l) (plist-get l :label)) links)
                                                 nil t)))
                     (seq-find (lambda (l) (equal (plist-get l :label) label)) links))))))
    (unless (file-readable-p (plist-get link :file))
      (user-error "The schema %s cannot be read" (plist-get link :file)))
    (xref-push-marker-stack)
    (find-file (plist-get link :file))
    (goto-char (point-min))
    (when (plist-get link :line)
      (forward-line (1- (plist-get link :line))))
    (back-to-indentation)
    (message "%s" (plist-get link :label))))

;;;###autoload
(defun py-schematron-about ()
  "Show what this package is, its version, author, licence and links.
Below, what the package's py-schematron.py says of itself (its
--about): its version, and the Python and libraries it runs with."
  (interactive)
  (let* ((el (expand-file-name "py-schematron.el" py-schematron--directory))
         (version (or (ignore-errors
                        (with-temp-buffer (insert-file-contents el) (lm-version)))
                      "?"))
         (python (py-schematron--program (py-schematron--python)))
         (script (py-schematron--script))
         (program
          (cond
           ((not python)
            (format "(the Python interpreter \"%s\" was not found; see `py-schematron-python')"
                    (py-schematron--python)))
           ((not (file-readable-p script))
            (format "(py-schematron.py was not found: %s)" script))
           (t (with-temp-buffer
                (let ((code (call-process python nil t nil script "--about")))
                  (if (eq code 0)
                      (string-trim (buffer-string))
                    (format "(%s --about failed: %s)" script
                            (string-trim (buffer-string)))))))))
         (link (lambda (url)
                 (insert-text-button url 'action (lambda (_) (browse-url url))
                                     'follow-link t 'help-echo (concat "Open " url)))))
    (with-current-buffer (get-buffer-create "*py-schematron about*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "py-schematron for Emacs %s\n\n" version)
                "Checks XML documents, TEI editions in particular, against the Schematron\n"
                "rules of their schema as you type, with Flycheck or Flymake, and gives\n"
                "nxml-mode the document's RelaxNG schema for completion.\n\n"
                "Author:   Nicolas Vaughan <nicolasvaughan@proton.me>\n"
                "Licence:  GNU General Public License, version 3 or later\n"
                "Code:     ")
        (funcall link "https://codeberg.org/nivaca/py-schematron.el")
        (insert "\n          ")
        (funcall link "https://github.com/nivaca/py-schematron.el")
        (insert "\nProgram:  ")
        (funcall link "https://codeberg.org/nivaca/py-schematron")
        (insert (format "\n\nPackage:  %s\nChecker:  %s%s\nnxml:     %s\n"
                        (abbreviate-file-name (file-truename el))
                        (py-schematron--frontend)
                        (if (eq py-schematron-frontend 'auto) " (py-schematron-frontend is auto)" "")
                        (cond
                         ((not py-schematron-fix-nxml) "left as it is (py-schematron-fix-nxml is nil)")
                         (py-schematron--nxml-fixes
                          (format "mended: %s"
                                  (mapconcat (lambda (f)
                                               (pcase f
                                                 ('category-tables "damaged category tables")
                                                 ('unicode "Unicode categories (now Emacs's own)")
                                                 ('whitespace "whitespace collapsing")))
                                             (reverse py-schematron--nxml-fixes) ", ")))
                         ((and (featurep 'xsd-regexp) (featurep 'rng-xsd)) "nothing to mend in this Emacs")
                         (t "not used yet in this session")))
                "\nThe package's py-schematron.py (--about):\n\n"
                program "\n")
        (goto-char (point-min))
        (special-mode))
      (display-buffer (current-buffer)))))

;; The commands' former names (until 0.7.0, when the package was
;; py-xmlvalidate).
;;;###autoload
(define-obsolete-function-alias 'py-xmlvalidate-mode #'py-schematron-mode "0.8.0")
;;;###autoload
(define-obsolete-function-alias 'py-xmlvalidate-about #'py-schematron-about "0.8.0")
;;;###autoload
(define-obsolete-function-alias 'py-xmlvalidate-check #'py-schematron-check "0.8.0")
;;;###autoload
(define-obsolete-function-alias 'py-xmlvalidate-check-setup #'py-schematron-check-setup "0.8.0")
;;;###autoload
(define-obsolete-function-alias 'py-xmlvalidate-flymake #'py-schematron-flymake "0.8.0")
;;;###autoload
(define-obsolete-function-alias 'py-xmlvalidate-goto-rule #'py-schematron-goto-rule "0.8.0")
;;;###autoload
(define-obsolete-function-alias 'py-xmlvalidate-recreate-nxml-schema #'py-schematron-recreate-nxml-schema "0.8.0")
;;;###autoload
(define-obsolete-function-alias 'py-xmlvalidate-refresh-schema #'py-schematron-refresh-schema "0.8.0")
;;;###autoload
(define-obsolete-function-alias 'py-xmlvalidate-report #'py-schematron-report "0.8.0")
;;;###autoload
(define-obsolete-function-alias 'py-xmlvalidate-show-log #'py-schematron-show-log "0.8.0")
;;;###autoload
(define-obsolete-function-alias 'py-xmlvalidate-trust-file #'py-schematron-trust-file "0.8.0")

(provide 'py-schematron)
;;; py-schematron.el ends here
