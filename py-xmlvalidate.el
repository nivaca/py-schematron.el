;;; py-xmlvalidate.el --- Schematron validation of XML/TEI with Flymake  -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Copyright (C) 2026 Nicolas Vaughan <nicolasvaughan@proton.me>

;; Author: Nicolas Vaughan <nicolasvaughan@proton.me>
;; Version: 0.1.2
;; Package-Requires: ((emacs "31.1"))
;; Keywords: languages, xml, tools
;; URL: https://codeberg.org/nivaca/py-xmlvalidate

;; This file is part of py-xmlvalidate.

;; py-xmlvalidate is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or (at
;; your option) any later version.

;; py-xmlvalidate is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with py-xmlvalidate.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; A Flymake backend that checks XML documents, TEI editions in
;; particular, against the Schematron rules of their schema, with the
;; program py-xmlvalidate.py of this same repository.  When the schema is
;; a RelaxNG file, the structure is also checked with jing.
;;
;; Errors are underlined as you type, unsaved changes included: the
;; buffer is checked from a private temporary copy, never from the file
;; itself.  The message under the cursor is shown in the echo area, and
;; M-x flymake-show-buffer-diagnostics lists them all.
;;
;; The schema is taken from the document's <?xml-model?> processing
;; instructions, as in oXygen and in the VS Code extension; remote
;; schemas are downloaded once and kept in a cache.  Documents without
;; an <?xml-model?> are left alone, unless `py-xmlvalidate-schema' names
;; a schema.
;;
;; Setup, once the package is installed:
;;
;;   (add-hook 'nxml-mode-hook #'py-xmlvalidate-mode)
;;
;; and, if the libraries live in a virtual environment,
;;
;;   (setopt py-xmlvalidate-python "~/.venvs/schematron/bin/python")
;;
;; Flymake checks only files in `trusted-content' (Emacs 30 and later),
;; and this backend is no exception: a document's <?xml-model?> chooses
;; the schema, and the schema's XPath, run by Saxon, can read local files
;; and fetch URLs.  So list the folders of your own documents there:
;;
;;   (setopt trusted-content '("~/Dropbox/docs/editions/"))
;;
;; A file outside those folders gets a warning when it is opened, and
;; M-x py-xmlvalidate-trust-file trusts it (or its folder) on request.
;;
;; M-x py-xmlvalidate-check-setup says whether Python, its libraries and
;; jing are where they should be.  See emacs/README.md for the details.

;;; Code:

(require 'flymake)
(require 'compile)
(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(defgroup py-xmlvalidate nil
  "Schematron validation of XML/TEI documents with py-xmlvalidate.py."
  :group 'tools
  :link '(url-link "https://codeberg.org/nivaca/py-xmlvalidate")
  :prefix "py-xmlvalidate-")

(defconst py-xmlvalidate--directory
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "Folder of this file: the emacs/ folder of the repository.")

(defcustom py-xmlvalidate-python "python3"
  "Python interpreter that has the saxonche and lxml libraries.
For example \"~/.venvs/schematron/bin/python\".  Python 3.15 or
later is needed."
  :type 'string)

(defcustom py-xmlvalidate-script nil
  "Path to py-xmlvalidate.py.
When nil, the copy in the repository this package was installed
from is used: it is looked for next to this file and in the
folder above, also after following symbolic links, which is how
it is found when Straight builds the package from links."
  :type '(choice (const :tag "The repository's copy" nil) file))

(defcustom py-xmlvalidate-schema nil
  "Schema to validate against, instead of the document's <?xml-model?>.
When nil, the schema is detected from the document.  Relative
names are taken from the document's folder.  Usually set as a
file-local or directory-local variable; see also
`py-xmlvalidate-schema-type'."
  :type '(choice (const :tag "Detect from <?xml-model?>" nil) file)
  :safe #'string-or-null-p)

(defcustom py-xmlvalidate-schema-type 'rng
  "Type of the file in `py-xmlvalidate-schema'.
Ignored when the schema is detected from the document."
  :type '(choice (const :tag "RelaxNG with embedded Schematron" rng)
                 (const :tag "Schematron (.sch)" sch)
                 (const :tag "TEI ODD" odd))
  :safe (lambda (v) (memq v '(rng sch odd))))

(defcustom py-xmlvalidate-relaxng t
  "Whether to check the structure with jing when the schema is RelaxNG."
  :type 'boolean
  :safe #'booleanp)

(defcustom py-xmlvalidate-jing "jing"
  "The jing program, for the RelaxNG check."
  :type 'string)

(defcustom py-xmlvalidate-timeout 120
  "Seconds after which a check is abandoned."
  :type 'natnum)

(defcustom py-xmlvalidate-live-max-size nil
  "Largest buffer, in characters, that is checked as you type.
Larger buffers are checked when they are opened and saved only.
When nil, every buffer is checked as you type.  Takes effect
when `py-xmlvalidate-mode' is turned on."
  :type '(choice (const :tag "No limit" nil) natnum))

(defconst py-xmlvalidate--log-buffer "*py-xmlvalidate log*"
  "Buffer that keeps what py-xmlvalidate.py and jing print on stderr.")

(defvar-local py-xmlvalidate--run nil
  "The check under way in this buffer, as a plist, or nil.")

(defvar-local py-xmlvalidate--refresh nil
  "Non-nil when the next check should download the schema again.")


;;;; Reading the programs' output (no side effects)

(defun py-xmlvalidate--severity (role)
  "Flymake type for a Schematron ROLE.
A role that names a level wins; otherwise the problem is an error."
  (pcase (downcase (string-trim (or role "")))
    ((or "warning" "warn") :warning)
    ((or "info" "information" "hint") :note)
    (_ :error)))

(defun py-xmlvalidate--item (line message type origin &optional code col)
  "A problem as a plist: MESSAGE at LINE, of TYPE, found by ORIGIN.
LINE is 1-based (nil when unknown), COL 0-based or nil.  TYPE is a
Flymake type, ORIGIN \"Schematron\", \"RelaxNG\" or \"XML\", and
CODE the Schematron pattern, if any."
  (list :line line :col col :message message :type type
        :origin origin :code code))

(defun py-xmlvalidate--malformed-items (message line)
  "Items for a document that is not well formed.
MESSAGE and LINE are the parser's.  The parser reports where it
noticed the problem, which for a tag mismatch is the closing tag,
often far from the typo; so the line where the unclosed tag was
opened is reported too."
  (let ((items (list (py-xmlvalidate--item line message :error "XML"))))
    (when (string-match
           "Opening and ending tag mismatch: \\([^ \t\n]+\\) line \\([0-9]+\\) and \\([^ \t\n,]+\\)"
           message)
      (let ((opened (match-string 1 message))
            (at (string-to-number (match-string 2 message)))
            (closing (match-string 3 message)))
        (unless (eql at line)
          (push (py-xmlvalidate--item
                 at
                 (format "<%s> opened here is never closed: the next end tag is </%s>%s.  Check for a typo in the element name."
                         opened closing (if line (format " (line %d)" line) ""))
                 :error "XML")
                (cdr items)))))
    items))

(defun py-xmlvalidate--json-items (json)
  "Items from the parsed --json output JSON of py-xmlvalidate.py.
JSON is a hash table, as `json-parse-string' returns it.  There is
only one document, the one being checked."
  (let ((doc (car (append (gethash "documents" json) nil))))
    (cond
     ((null doc) nil)
     ((gethash "error" doc)
      (py-xmlvalidate--malformed-items (gethash "error" doc)
                                       (py-xmlvalidate--number (gethash "error_line" doc))))
     (t
      (let ((items
             (mapcar (lambda (v)
                       (py-xmlvalidate--item
                        (py-xmlvalidate--number (gethash "line" v))
                        (let ((text (gethash "text" v)))
                          (if (and (stringp text) (not (string-empty-p text)))
                              text
                            (gethash "message" v)))
                        (py-xmlvalidate--severity (gethash "role" v))
                        "Schematron"
                        (let ((p (gethash "pattern" v)))
                          (and (stringp p) (not (string-empty-p p)) p))))
                     (gethash "violations" doc)))
            (errs (append (gethash "xpath_errors" doc) nil)))
        (when errs
          (setq items
                (append items
                        (list (py-xmlvalidate--item
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
                               :warning "Schematron")))))
        items)))))

(defun py-xmlvalidate--number (v)
  "V if it is a positive number, else nil (JSON null, false, 0)."
  (and (numberp v) (> v 0) v))

(defconst py-xmlvalidate--jing-re
  "^\\(.*?\\):\\([0-9]+\\):\\([0-9]+\\): \\(error\\|warning\\|fatal\\): \\(.*\\)$"
  "A line of jing's output: FILE:LINE:COLUMN: LEVEL: MESSAGE.")

(defun py-xmlvalidate--jing-items (output file &optional drop-fatal)
  "Items from jing's OUTPUT about FILE.
DROP-FATAL leaves out the fatal (well-formedness) errors, which
py-xmlvalidate.py has already reported."
  (let ((target (expand-file-name file))
        items)
    (dolist (line (split-string output "\r?\n"))
      (when (string-match py-xmlvalidate--jing-re (string-trim line))
        (let ((f (match-string 1 (string-trim line)))
              (l (string-to-number (match-string 2 (string-trim line))))
              (c (string-to-number (match-string 3 (string-trim line))))
              (level (match-string 4 (string-trim line)))
              (msg (match-string 5 (string-trim line))))
          (when (and (equal (expand-file-name f) target)
                     (not (and drop-fatal (equal level "fatal"))))
            (push (py-xmlvalidate--item l msg (if (equal level "warning") :warning :error)
                                        "RelaxNG" nil (max (1- c) 0))
                  items)))))
    (nreverse items)))

(defun py-xmlvalidate--underline (text &optional col)
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

(defun py-xmlvalidate--explain-failure (stderr python)
  "The best explanation, from STDERR, of a run that gave no JSON.
PYTHON is the interpreter that was used."
  (if (string-match "No module named '?\\(saxonche\\|lxml\\)" stderr)
      (format "The Python interpreter \"%s\" does not have the '%s' library.  Set `py-xmlvalidate-python' to a Python that has saxonche and lxml, or install them into this one: %s -m pip install saxonche lxml"
              python (match-string 1 stderr) python)
    (let ((lines (seq-remove
                  (lambda (l)
                    (or (string-empty-p l)
                        (string-match-p "^\\[\\(caché\\|descarga\\|xml-model\\|esquema\\|extracción\\|cosecha\\|aviso\\)\\]" l)))
                  (mapcar #'string-trim (split-string stderr "\n")))))
      (if lines
          (string-join (last lines 3) " ")
        "py-xmlvalidate.py failed without a message."))))


;;;; Running the checks

(defun py-xmlvalidate--program (name)
  "Full name of the program NAME, or nil if it cannot be run.
NAME is looked up on the variable `exec-path', unless it contains a slash; then
it is a file name, and may start with \"~\"."
  (if (string-search "/" name)
      (let ((f (expand-file-name name)))
        (and (file-executable-p f) (not (file-directory-p f)) f))
    (executable-find name)))

(defun py-xmlvalidate--script-candidates ()
  "Where the repository's py-xmlvalidate.py may be, most likely first.
package-vc and a plain clone keep this file in the repository's
emacs/ folder, so the script is in the folder above.  Straight
builds the package in a folder of its own, from links to the
files of its clone; following the link to this file leads back
to the clone."
  (let* ((dir py-xmlvalidate--directory)
         (real (file-name-directory
                (file-truename (expand-file-name "py-xmlvalidate.el" dir)))))
    (delete-dups
     (mapcar (lambda (d) (expand-file-name "py-xmlvalidate.py" d))
             (list (expand-file-name ".." dir) dir
                   (expand-file-name ".." real) real)))))

(defun py-xmlvalidate--script ()
  "The py-xmlvalidate.py to run."
  (expand-file-name
   (or py-xmlvalidate-script
       (let ((candidates (py-xmlvalidate--script-candidates)))
         (or (seq-find #'file-readable-p candidates) (car candidates))))))

(defun py-xmlvalidate--applicable-p ()
  "Whether this buffer is one to check: it has a schema to go by."
  (or py-xmlvalidate-schema
      (save-excursion
        (save-restriction
          (widen)
          (goto-char (point-min))
          (search-forward "<?xml-model" nil t)))))

(defun py-xmlvalidate--log (text)
  "Append TEXT, a program's stderr, to the log buffer."
  (unless (string-empty-p (string-trim text))
    (with-current-buffer (get-buffer-create py-xmlvalidate--log-buffer)
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (insert (format-time-string "-- %T\n") (string-trim-right text) "\n")))))

(defun py-xmlvalidate--kill ()
  "Stop the check under way in this buffer, if any, and clean up."
  (when py-xmlvalidate--run
    (let ((run py-xmlvalidate--run))
      (setq py-xmlvalidate--run nil)
      (py-xmlvalidate--cleanup run))))

(defun py-xmlvalidate--cleanup (run)
  "Kill RUN's processes and timer, and delete its buffers and copy."
  (when-let* ((timer (plist-get run :timer))) (cancel-timer timer))
  (dolist (p (plist-get run :procs))
    (when (process-live-p p) (delete-process p)))
  (dolist (b (plist-get run :buffers))
    (when (buffer-live-p b) (kill-buffer b)))
  (when-let* ((dir (plist-get run :tmpdir)))
    (when (file-directory-p dir) (delete-directory dir t))))

(defun py-xmlvalidate--start (run name program args callback)
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
                               (eq run (buffer-local-value 'py-xmlvalidate--run source)))
                      (let ((stdout (with-current-buffer out (buffer-string)))
                            (stderr (with-current-buffer err (buffer-string))))
                        (py-xmlvalidate--log stderr)
                        (with-current-buffer source
                          (funcall callback
                                   (and (eq (process-status p) 'exit) (process-exit-status p))
                                   stdout stderr)))))))))
          (plist-put run :procs (cons proc (plist-get run :procs))))
      (file-error
       (funcall callback nil "" (error-message-string e)))))))

(defun py-xmlvalidate--diagnostics (items)
  "Flymake diagnostics, in the current buffer, for ITEMS."
  (save-restriction
    (widen)
    (mapcar
     (lambda (it)
       (let* ((line (min (max (or (plist-get it :line) 1) 1)
                         (line-number-at-pos (point-max))))
              (bounds (save-excursion
                        (goto-char (point-min))
                        (forward-line (1- line))
                        (cons (point) (line-end-position))))
              (cols (py-xmlvalidate--underline
                     (buffer-substring-no-properties (car bounds) (cdr bounds))
                     (plist-get it :col)))
              (beg (+ (car bounds) (car cols)))
              (end (+ (car bounds) (cdr cols))))
         (when (= beg end)                ; an empty line: mark one character
           (setq end (min (1+ beg) (point-max)))
           (when (= beg end) (setq beg (max (1- end) (point-min)))))
         (flymake-make-diagnostic
          (current-buffer) beg end (plist-get it :type)
          (list (plist-get it :origin) (plist-get it :code) (plist-get it :message)))))
     items)))

(defun py-xmlvalidate-flymake (report-fn &rest _args)
  "Flymake backend: check the buffer, then call REPORT-FN.
Each call cancels the check still under way, if any."
  (py-xmlvalidate--kill)
  (if (not (py-xmlvalidate--applicable-p))
      (funcall report-fn nil)
    (let* ((file buffer-file-name)
           (tmpdir (make-temp-file "py-xmlvalidate-" t))
           (input (expand-file-name (if file (file-name-nondirectory file) "document.xml")
                                    tmpdir))
           (refresh py-xmlvalidate--refresh)
           (schema (and py-xmlvalidate-schema
                        (expand-file-name py-xmlvalidate-schema)))
           (python py-xmlvalidate-python)
           (run (list :tmpdir tmpdir :procs nil :buffers nil)))
      (setq py-xmlvalidate--refresh nil
            py-xmlvalidate--run run)
      ;; The buffer's text, saved or not, goes to a private copy;
      ;; --as makes py-xmlvalidate.py resolve relative xml-model hrefs and
      ;; report as if it were the real file.
      (let ((coding-system-for-write (or buffer-file-coding-system 'utf-8-unix)))
        (write-region nil nil input nil 'nomessage))
      (plist-put run :timer
                 (run-with-timer
                  py-xmlvalidate-timeout nil
                  (let ((source (current-buffer)))
                    (lambda ()
                      (when (and (buffer-live-p source)
                                 (eq run (buffer-local-value 'py-xmlvalidate--run source)))
                        (with-current-buffer source
                          (py-xmlvalidate--kill)
                          (funcall report-fn
                                   (py-xmlvalidate--diagnostics
                                    (list (py-xmlvalidate--item
                                           nil (format "The check was abandoned after %d s (py-xmlvalidate-timeout)."
                                                       py-xmlvalidate-timeout)
                                           :error "py-xmlvalidate"))))))))))
      (py-xmlvalidate--start
       run "py-xmlvalidate" (py-xmlvalidate--program python)
       (append (list (py-xmlvalidate--script) "--json")
               (and refresh '("--refresh"))
               (and schema (list (pcase py-xmlvalidate-schema-type
                                   ('sch "-s") ('odd "-o") (_ "-r"))
                                 schema))
               (and file (list "--as" file))
               (list input))
       (lambda (code stdout stderr)
         (let ((json (and code (string-prefix-p "{" (string-trim-left stdout))
                          (ignore-errors (json-parse-string stdout :null-object nil :false-object nil)))))
           (when refresh
             (py-xmlvalidate--say-refreshed stderr json))
           (if (null json)
               (py-xmlvalidate--finish
                run report-fn
                (list (py-xmlvalidate--item
                       nil
                       (if code
                           (py-xmlvalidate--explain-failure stderr python)
                         (format "Could not run the Python interpreter \"%s\".  Set `py-xmlvalidate-python' to a Python that has saxonche and lxml (M-x py-xmlvalidate-check-setup)."
                                 python))
                       :error "py-xmlvalidate")))
             (let* ((items (py-xmlvalidate--json-items json))
                    (source (gethash "source" json))
                    (malformed (seq-some (lambda (d) (gethash "error" d))
                                         (gethash "documents" json))))
               (if (and py-xmlvalidate-relaxng source
                        (equal (gethash "type" source) "rng")
                        (py-xmlvalidate--program py-xmlvalidate-jing))
                   (py-xmlvalidate--start
                    run "py-xmlvalidate-jing" (py-xmlvalidate--program py-xmlvalidate-jing)
                    (list (gethash "path" source) input)
                    (lambda (jcode jout jerr)
                      (py-xmlvalidate--finish
                       run report-fn
                       (append items
                               (if (memq jcode '(0 1))
                                   (py-xmlvalidate--jing-items jout input malformed)
                                 (list (py-xmlvalidate--item
                                        nil (format "jing failed: %s"
                                                    (car (last (split-string (string-trim (concat jerr jout)) "\n"))))
                                        :warning "RelaxNG")))))))
                 (py-xmlvalidate--finish run report-fn items))))))))))

(defun py-xmlvalidate--finish (run report-fn items)
  "Report ITEMS through REPORT-FN and end RUN."
  (funcall report-fn (py-xmlvalidate--diagnostics items))
  (when (eq run py-xmlvalidate--run)
    (setq py-xmlvalidate--run nil))
  (py-xmlvalidate--cleanup run))

(defun py-xmlvalidate--say-refreshed (stderr json)
  "Tell what a --refresh run did, from its STDERR and JSON output."
  (cond
   ((string-match "^\\[descarga\\] \\([^ \t\n]+\\)" stderr)
    (message "py-xmlvalidate: schema downloaded again from %s" (match-string 1 stderr)))
   (json
    (message "py-xmlvalidate: the schema is local (%s); nothing to download"
             (file-name-nondirectory (gethash "path" (gethash "source" json)))))
   (t (message "py-xmlvalidate: the schema could not be refreshed; see %s"
               py-xmlvalidate--log-buffer))))


;;;; Commands and the minor mode

;;;###autoload
(define-minor-mode py-xmlvalidate-mode
  "Check the buffer against its Schematron rules, with Flymake.
The schema comes from the document's <?xml-model?> processing
instructions, or from `py-xmlvalidate-schema'.  Problems are
underlined as you type; \\[flymake-show-buffer-diagnostics] lists them.

Only files in `trusted-content' are checked, because the schema
named in a document can make Saxon read files and fetch URLs."
  :lighter nil
  (if py-xmlvalidate-mode
      (progn
        (add-hook 'flymake-diagnostic-functions #'py-xmlvalidate-flymake nil t)
        (when (and py-xmlvalidate-live-max-size
                   (> (buffer-size) py-xmlvalidate-live-max-size))
          (setq-local flymake-no-changes-timeout nil))
        (add-hook 'kill-buffer-hook #'py-xmlvalidate--kill nil t)
        (unless (trusted-content-p)
          (py-xmlvalidate--warn-untrusted))
        (flymake-mode 1))
    (remove-hook 'flymake-diagnostic-functions #'py-xmlvalidate-flymake t)
    (kill-local-variable 'flymake-no-changes-timeout)
    (py-xmlvalidate--kill)
    (when flymake-mode (flymake-start))))

(defvar py-xmlvalidate--warned (make-hash-table :test #'equal)
  "Files already warned about as untrusted, in this session.")

(defun py-xmlvalidate--name ()
  "The visited file's name as `trusted-content' compares it."
  (and buffer-file-truename (abbreviate-file-name buffer-file-truename)))

(defun py-xmlvalidate--untrusted-text ()
  "Why the current buffer is not checked, and what to do about it."
  (if (py-xmlvalidate--name)
      ;; The Lisp line goes through `format', not `format-message',
      ;; whose curly quotes would make it wrong to paste.
      (concat
       (format-message
        "%s is not in `trusted-content', so it is not checked as you type.  \
To check it, run M-x py-xmlvalidate-trust-file, or add to your init file:\n"
        (py-xmlvalidate--name))
       (format "  (add-to-list 'trusted-content %S)\n" (py-xmlvalidate--name))
       "Only trust files you know: the schema a document names is run by \
Saxon, and its rules can read files and fetch URLs.")
    (format-message "%s visits no file, and only files in `trusted-content' are checked."
                    (buffer-name))))

(defun py-xmlvalidate--warn-untrusted ()
  "Warn, once per file and session, that this buffer is not checked."
  (let ((key (or (py-xmlvalidate--name) (buffer-name))))
    (unless (gethash key py-xmlvalidate--warned)
      (puthash key t py-xmlvalidate--warned)
      (display-warning 'py-xmlvalidate (py-xmlvalidate--untrusted-text) :warning))))

(defun py-xmlvalidate--require-trust ()
  "Signal a `user-error' explaining why, if the buffer is not trusted."
  (unless (trusted-content-p)
    (user-error "%s" (car (split-string (py-xmlvalidate--untrusted-text) "\n")))))

;;;###autoload
(defun py-xmlvalidate-trust-file ()
  "Trust the visited file, or its folder, and start checking it.
Asks first.  The file or folder is added to `trusted-content' for
this session; the line that keeps it for future sessions is put
in the kill ring, to paste into your init file."
  (interactive)
  (let ((name (py-xmlvalidate--name)))
    (unless name
      (user-error "This buffer visits no file"))
    (if (trusted-content-p)
        (message "py-xmlvalidate: %s is already trusted" name)
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
                (when (and py-xmlvalidate-mode (trusted-content-p))
                  (flymake-start nil t))))
            (message "py-xmlvalidate: trusted %s for this session; to keep it, paste into your init file (it is in the kill ring): %s"
                     entry line)))))))

(defun py-xmlvalidate--ensure-mode ()
  "Turn on `py-xmlvalidate-mode' if it is off."
  (unless py-xmlvalidate-mode (py-xmlvalidate-mode 1)))

;;;###autoload
(defun py-xmlvalidate-check ()
  "Check the buffer now."
  (interactive)
  (py-xmlvalidate--ensure-mode)
  (py-xmlvalidate--require-trust)
  (flymake-start nil t))

;;;###autoload
(defun py-xmlvalidate-refresh-schema ()
  "Download the document's remote schema again, then check the buffer.
For when the schema has changed upstream: py-xmlvalidate.py keeps
a downloaded schema in its cache for a day."
  (interactive)
  (py-xmlvalidate--ensure-mode)
  (py-xmlvalidate--require-trust)
  (setq py-xmlvalidate--refresh t)
  (message "py-xmlvalidate: refreshing the schema...")
  (flymake-start nil t))

;;;###autoload
(defun py-xmlvalidate-report ()
  "Show the full report of the visited file, with clickable lines.
Runs py-xmlvalidate.py -v on the saved file, in a compilation
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
         (untrusted (and (not (trusted-content-p)) (py-xmlvalidate--untrusted-text)))
         (default-directory (file-name-directory file))
         (args (append (and py-xmlvalidate-schema
                            (list (pcase py-xmlvalidate-schema-type
                                    ('sch "-s") ('odd "-o") (_ "-r"))
                                  (expand-file-name py-xmlvalidate-schema)))
                       (list "-v" file))))
    (with-current-buffer
        (compilation-start
         (mapconcat #'shell-quote-argument
                    (append (list (or (py-xmlvalidate--program py-xmlvalidate-python)
                                      py-xmlvalidate-python)
                                  (py-xmlvalidate--script))
                            args)
                    " ")
         #'py-xmlvalidate-report-mode
         (lambda (_mode) "*py-xmlvalidate report*"))
      (setq-local py-xmlvalidate--report-file file)
      (setq-local py-xmlvalidate--report-untrusted untrusted))))

(defvar-local py-xmlvalidate--report-file nil
  "The file a report buffer is about.")
(put 'py-xmlvalidate--report-file 'permanent-local t)

(defvar-local py-xmlvalidate--report-untrusted nil
  "When the file is not trusted, the note that ends the report.")
(put 'py-xmlvalidate--report-untrusted 'permanent-local t)

(defun py-xmlvalidate--report-note (buffer _how)
  "End the report in BUFFER with the note about trust, if any."
  (with-current-buffer buffer
    (when py-xmlvalidate--report-untrusted
      (let ((inhibit-read-only t))
        (save-excursion
          (goto-char (point-max))
          (insert "\nNote: " py-xmlvalidate--report-untrusted "\n"))))))

(define-compilation-mode py-xmlvalidate-report-mode "py-xmlvalidate"
  "Mode of the buffer of \\[py-xmlvalidate-report]."
  (setq-local compilation-exit-message-function #'py-xmlvalidate--report-exit)
  (add-hook 'compilation-finish-functions #'py-xmlvalidate--report-note nil t)
  (setq-local compilation-error-regexp-alist '(py-xmlvalidate))
  (setq-local compilation-error-regexp-alist-alist
              '((py-xmlvalidate
                 "^  l\\. +\\([0-9]+\\)  \\[[^]\n]*\\]  " py-xmlvalidate--report-file-name 1))))

(defun py-xmlvalidate--report-exit (status code msg)
  "The report's last line, from the exit CODE of py-xmlvalidate.py.
STATUS and MSG are as in `compilation-exit-message-function'."
  (if (eq status 'exit)
      (pcase code
        (0 '("valid: no violations\n" . "valid"))
        (1 '("violations found\n" . "violations")))
    (cons msg (number-to-string code))))

(defun py-xmlvalidate--report-file-name ()
  "The file the report buffer is about, for its links."
  py-xmlvalidate--report-file)

;;;###autoload
(defun py-xmlvalidate-show-log ()
  "Show what py-xmlvalidate.py and jing printed on stderr."
  (interactive)
  (display-buffer (get-buffer-create py-xmlvalidate--log-buffer)))

;;;###autoload
(defun py-xmlvalidate-check-setup ()
  "Say whether Python, its libraries, the script and jing are in place."
  (interactive)
  (let* ((python (py-xmlvalidate--program py-xmlvalidate-python))
         (script (py-xmlvalidate--script))
         (jing (py-xmlvalidate--program py-xmlvalidate-jing))
         (lines nil))
    (cl-flet ((say (ok text) (push (concat (if ok "  ok   " "  NO   ") text) lines)))
      (if (not python)
          (say nil (format "Python: \"%s\" not found.  Set `py-xmlvalidate-python'." py-xmlvalidate-python))
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
           (format "Script: %s%s" script (if (file-readable-p script) "" " (missing; set `py-xmlvalidate-script')")))
      (say jing (if jing (format "jing: %s" jing)
                  (format "jing: \"%s\" not found; the RelaxNG check is skipped (optional)" py-xmlvalidate-jing))))
    (with-current-buffer (get-buffer-create "*py-xmlvalidate setup*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "py-xmlvalidate setup\n\n" (string-join (nreverse lines) "\n") "\n")
        (special-mode))
      (display-buffer (current-buffer)))))

(provide 'py-xmlvalidate)
;;; py-xmlvalidate.el ends here
