;;; py-schematron-tests.el --- Tests of py-schematron.el  -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Copyright (C) 2026 Nicolas Vaughan <nicolasvaughan@proton.me>
;; This file is part of py-schematron.el.  See the LICENSE file for details.

;;; Commentary:

;; Run from the repository's top folder:
;;
;;   PYSCH_PYTHON=~/.venvs/schematron/bin/python JING=jing \
;;     FLYCHECK_DIR=~/.emacs.d/straight/build/flycheck PYSCH_TRANG=trang \
;;     emacs --batch -Q -L . -l test/py-schematron-tests.el \
;;     -f ert-run-tests-batch-and-exit
;;
;; The first group of tests reads the programs' output and needs nothing
;; else.  The second runs the real py-schematron.py (and jing, when JING
;; is set) through Flymake, on documents written to a temporary folder;
;; those tests are skipped unless PYSCH_PYTHON names a Python with
;; saxonche and lxml.  The package's py-schematron.py is copied there
;; too, so its download cache stays out of the repository.  The
;; Flycheck tests need FLYCHECK_DIR (a folder with flycheck.el), and the
;; nxml ones PYSCH_TRANG (trang's command line).

;;; Code:

(require 'jka-compr)   ; (its temporary-file template is set on loading: not inside a test)

(defconst pysch-test--word-pattern "(\\p{L}|\\p{N}|\\p{P}|\\p{S})+"
  "TEI's pattern for teidata.word, as trang writes it.")


(require 'ert)
(require 'cl-lib)
(require 'lisp-mnt)
(require 'nxml-mode)
(require 'rng-valid)
(require 'rng-nxml)
(eval-and-compile
  (add-to-list 'load-path
               (expand-file-name ".." (file-name-directory
                                       (or load-file-name byte-compile-current-file)))))
(require 'py-schematron)

(defconst pysch-test--repo
  (expand-file-name ".." (file-name-directory (or load-file-name buffer-file-name)))
  "The repository's top folder, with py-schematron.el and py-schematron.py.")


;;;; Reading the output

(ert-deftest pysch-severity ()
  (should (eq (py-schematron--severity "") :error))
  (should (eq (py-schematron--severity nil) :error))
  (should (eq (py-schematron--severity " Warning ") :warning))
  (should (eq (py-schematron--severity "info") :note))
  (should (eq (py-schematron--severity "fatal") :error)))

(ert-deftest pysch-json-items ()
  (let* ((json (json-parse-string
                "{\"version\":\"1.15\",\"source\":{\"path\":\"/s.rng\",\"type\":\"rng\"},
                  \"documents\":[{\"file\":\"d.xml\",
                   \"violations\":[{\"pattern\":\"p1\",\"role\":\"\",\"message\":\"M …\",\"text\":\"M x\",\"line\":4},
                                   {\"pattern\":\"\",\"role\":\"warning\",\"message\":\"W\",\"text\":\"\",\"line\":null}],
                   \"xpath_errors\":[{\"message\":\"\",\"context\":\"tei:p\",\"error\":\"XPTY0004\",\"nodes\":3}]}]}"
                :null-object nil :false-object nil))
         (items (py-schematron--json-items json)))
    (should (= (length items) 3))
    (should (equal (plist-get (nth 0 items) :message) "M x"))
    (should (equal (plist-get (nth 0 items) :code) "p1"))
    (should (= (plist-get (nth 0 items) :line) 4))
    (should (equal (plist-get (nth 1 items) :message) "W"))
    (should (eq (plist-get (nth 1 items) :type) :warning))
    (should (null (plist-get (nth 1 items) :code)))
    (should (null (plist-get (nth 1 items) :line)))
    (should (string-match-p "1 rule(s) failed.*(no message) \\[tei:p\\]: XPTY0004 (3 nodes)"
                            (replace-regexp-in-string "\n" " " (plist-get (nth 2 items) :message))))))

(ert-deftest pysch-malformed ()
  (let ((items (py-schematron--malformed-items
                "Opening and ending tag mismatch: notde line 3 and p, line 4, column 5" 4)))
    (should (equal (mapcar (lambda (i) (plist-get i :line)) items) '(4 3)))
    (should (string-match-p "<notde> opened here is never closed: the next end tag is </p> (line 4)"
                            (plist-get (nth 1 items) :message))))
  (should (= 1 (length (py-schematron--malformed-items "Premature end of data" 9)))))

(ert-deftest pysch-jing-items ()
  (let* ((out "/tmp/a/d.xml:5:12: error: element \"bogus\" not allowed here\n/tmp/a/other.xml:1:1: error: x\n/tmp/a/d.xml:7:3: fatal: The element type \"p\" must be terminated\n")
         (all (py-schematron--jing-items out "/tmp/a/d.xml"))
         (some (py-schematron--jing-items out "/tmp/a/d.xml" t)))
    (should (equal (mapcar (lambda (i) (plist-get i :line)) all) '(5 7)))
    (should (= (plist-get (car all) :col) 11))
    (should (equal (plist-get (car all) :origin) "RelaxNG"))
    (should (= (length some) 1))))

(ert-deftest pysch-underline ()
  ;; jing's column just after the start tag: from its "<" to the column
  (should (equal (py-schematron--underline "<p>c<bogus/></p>" 12) '(4 . 12)))
  ;; no column: the content, without indentation and trailing spaces
  (should (equal (py-schematron--underline "   <p>a</p>  ") '(3 . 11)))
  (should (equal (py-schematron--underline "") '(0 . 0)))
  ;; a column with no "<" before it
  (should (equal (py-schematron--underline "abc def" 2) '(2 . 7))))

(ert-deftest pysch-explain-failure ()
  (should (string-match-p "does not have the 'saxonche' library"
                          (py-schematron--explain-failure
                           "ModuleNotFoundError: No module named 'saxonche'" "py")))
  (should (equal (py-schematron--explain-failure
                  "[xml-model] esquema detectado: s.rng\nERROR: no se encuentra s.rng\n" "py")
                 "ERROR: no se encuentra s.rng"))
  (should (equal (py-schematron--explain-failure "" "py")
                 "py-schematron.py failed without a message.")))


(ert-deftest pysch-script-lookup ()
  "The script is found next to this file, through a Straight-style link,
and in the folder above (the layout before 0.3.0)."
  (let* ((root (make-temp-file "pysch-lookup-" t))
         (clone (expand-file-name "repos/pkg/" root))
         (build (expand-file-name "build/pkg/" root))
         (old (expand-file-name "old/" root)))
    (unwind-protect
        (progn
          (make-directory clone t)
          (make-directory build t)
          (make-directory (expand-file-name "emacs" old) t)
          (with-temp-file (expand-file-name "py-schematron.py" clone))
          (with-temp-file (expand-file-name "py-schematron.el" clone))
          (make-symbolic-link (expand-file-name "py-schematron.el" clone)
                              (expand-file-name "py-schematron.el" build))
          (with-temp-file (expand-file-name "py-schematron.py" old))
          (with-temp-file (expand-file-name "emacs/py-schematron.el" old))
          (let ((py-schematron-script nil))
            ;; package-vc, a clone: next to the file
            (let ((py-schematron--directory clone))
              (should (equal (py-schematron--script)
                             (expand-file-name "py-schematron.py" clone))))
            ;; Straight: the build folder, where the .el is a link
            (let ((py-schematron--directory build))
              (should (equal (file-truename (py-schematron--script))
                             (file-truename (expand-file-name "py-schematron.py" clone)))))
            ;; the old layout: the folder above
            (let ((py-schematron--directory (expand-file-name "emacs/" old)))
              (should (equal (py-schematron--script)
                             (expand-file-name "py-schematron.py" old))))
            ;; the setting wins
            (let ((py-schematron-script "~/x.py"))
              (should (equal (py-schematron--script) (expand-file-name "~/x.py"))))))
      (delete-directory root t))))

;;;; With the real programs

(defvar pysch-test--dir nil "Temporary folder of the running test.")

(defconst pysch-test--pi
  "<?xml-model href=\"schema.rng\" type=\"application/xml\" schematypens=\"http://relaxng.org/ns/structure/1.0\"?>")

(defun pysch-test--rng (max)
  "A RelaxNG schema allowing at most MAX p, with a Schematron rule."
  (format "<grammar xmlns=\"http://relaxng.org/ns/structure/1.0\"
         xmlns:sch=\"http://purl.oclc.org/dsdl/schematron\"
         ns=\"http://www.tei-c.org/ns/1.0\">
  <sch:ns prefix=\"tei\" uri=\"http://www.tei-c.org/ns/1.0\"/>
  <start>
    <element name=\"TEI\">
      <sch:pattern id=\"max-p\">
        <sch:rule context=\"tei:TEI\">
          <sch:assert test=\"count(tei:p) le %d\">A <sch:name/> may contain at most %d p, found <sch:value-of select=\"count(tei:p)\"/></sch:assert>
        </sch:rule>
      </sch:pattern>
      <oneOrMore><element name=\"p\">
        <optional><attribute name=\"ed\"><list><oneOrMore><data type=\"token\" datatypeLibrary=\"http://www.w3.org/2001/XMLSchema-datatypes\"><param name=\"pattern\">(\\p{L}|\\p{N}|\\p{P}|\\p{S})+</param></data></oneOrMore></list></attribute></optional>
        <zeroOrMore><choice><text/><element name=\"note\"><text/></element></choice></zeroOrMore></element></oneOrMore>
    </element>
  </start>
</grammar>
" max max))

(defun pysch-test--write (name text)
  "Write TEXT to NAME in the test folder; return its full name."
  (let ((f (expand-file-name name pysch-test--dir)))
    (with-temp-file f (insert text))
    f))

(defmacro pysch-test--with-env (&rest body)
  "Run BODY with a fresh test folder, the script copied into it."
  (declare (indent 0))
  `(let ((python (getenv "PYSCH_PYTHON")))
     (unless (and python (file-executable-p (expand-file-name python)))
       (ert-skip "PYSCH_PYTHON is not set"))
     (let* ((pysch-test--dir (make-temp-file "pysch-test-" t))
            (temporary-file-directory (file-name-as-directory
                                       (expand-file-name "tmp" pysch-test--dir)))
            (py-schematron-python python)
            (py-schematron-jing (or (getenv "JING") "no-such-jing"))
            (py-schematron-script (expand-file-name "bin/py-schematron.py" pysch-test--dir))
            (py-schematron-live-max-size nil)
            (py-schematron-schema nil)
            (py-schematron-frontend 'flymake)
            (py-schematron-nxml-schema nil)
            (py-schematron-trang (or (and (getenv "PYSCH_TRANG")
                                           (split-string-shell-command (getenv "PYSCH_TRANG")))
                                      "no-such-trang"))
            (py-schematron--trang-warned nil)
            (user-emacs-directory (file-name-as-directory (expand-file-name "emacs.d" pysch-test--dir)))
            (trusted-content (list (file-name-as-directory
                                    (abbreviate-file-name (file-truename pysch-test--dir))))))
       (make-directory temporary-file-directory)
       (make-directory (expand-file-name "bin" pysch-test--dir))
       (copy-file (expand-file-name "py-schematron.py" pysch-test--repo) py-schematron-script)
       (pysch-test--write "schema.rng" (pysch-test--rng 2))
       (unwind-protect (progn ,@body)
         (dolist (b (buffer-list))
           (when (and (buffer-file-name b)
                      (string-prefix-p pysch-test--dir (buffer-file-name b)))
             (with-current-buffer b (set-buffer-modified-p nil))
             (kill-buffer b)))
         (delete-directory pysch-test--dir t)))))

(defun pysch-test--wait (pred what &optional secs)
  "Wait until PRED returns non-nil, at most SECS seconds; WHAT for errors."
  (let ((end (+ (float-time) (or secs 60))))
    (while (not (funcall pred))
      (when (> (float-time) end) (error "Timed out waiting for %s" what))
      (accept-process-output nil 0.05))))

(defun pysch-test--check ()
  "Check the current buffer and wait for the result; return the diagnostics."
  (flymake-start nil t)
  (pysch-test--wait (lambda () (and (memq #'py-schematron-flymake (flymake-reporting-backends))
                                   (null py-schematron--run)))
                   "the check")
  (sort (flymake-diagnostics) (lambda (a b) (< (flymake-diagnostic-beg a) (flymake-diagnostic-beg b)))))

(defun pysch-test--open (name)
  "Visit NAME in the test folder, with `py-schematron-mode' on."
  (find-file (expand-file-name name pysch-test--dir))
  (nxml-mode)
  (py-schematron-mode 1)
  (current-buffer))

(defun pysch-test--lines (diags origin)
  "Lines of DIAGS from ORIGIN."
  (sort (mapcar (lambda (d) (line-number-at-pos (flymake-diagnostic-beg d)))
                (seq-filter (lambda (d) (equal (flymake-diagnostic-origin d) origin)) diags))
        #'<))

(defun pysch-test--describe (diags)
  "DIAGS as text, for failure messages."
  (mapconcat (lambda (d) (format "L%d %s [%s] %s" (line-number-at-pos (flymake-diagnostic-beg d))
                                 (flymake-diagnostic-type d) (flymake-diagnostic-origin d)
                                 (flymake-diagnostic-text d)))
             diags "\n"))

(defun pysch-test--visible (diags)
  "Every diagnostic covers at least one character."
  (dolist (d diags)
    (should (< (flymake-diagnostic-beg d) (flymake-diagnostic-end d)))))

(ert-deftest pysch-real-invalid ()
  "Schematron and RelaxNG errors are reported on the offending lines."
  (pysch-test--with-env
    (pysch-test--write "invalid.xml" (concat pysch-test--pi "\n<TEI xmlns=\"http://www.tei-c.org/ns/1.0\">\n<p>a</p>\n<p>b</p>\n<p>c<bogus/></p>\n</TEI>\n"))
    (with-current-buffer (pysch-test--open "invalid.xml")
      (let ((ds (pysch-test--check)))
        (message "%s" (pysch-test--describe ds))
        (should (equal (pysch-test--lines ds "Schematron") '(2)))
        (should (string-match-p "A TEI may contain at most 2 p, found 3"
                                (flymake-diagnostic-text (car ds))))
        (should (equal (flymake-diagnostic-code (car ds)) "max-p"))
        (when (getenv "JING")
          (should (equal (pysch-test--lines ds "RelaxNG") '(5)))
          (let ((d (car (last ds))))
            (should (equal (buffer-substring (flymake-diagnostic-beg d) (flymake-diagnostic-end d))
                           "<bogus/>"))))
        (should (seq-every-p (lambda (d) (eq (flymake-diagnostic-type d) :error)) ds))
        (pysch-test--visible ds)
        ;; nothing left behind: no process, no temporary copy
        (should-not (seq-filter (lambda (p) (string-prefix-p "py-schematron" (process-name p)))
                                (process-list)))
        (should-not (directory-files temporary-file-directory nil "^py-schematron-"))))))

(ert-deftest pysch-real-typo ()
  "A typo: the error points at the unclosed tag as well."
  (pysch-test--with-env
    (pysch-test--write "typo.xml" (concat pysch-test--pi "\n<TEI xmlns=\"http://www.tei-c.org/ns/1.0\">\n<p>a <notde>x\n</p>\n<p>b</note></p>\n</TEI>\n"))
    (with-current-buffer (pysch-test--open "typo.xml")
      (let ((ds (pysch-test--check)))
        (message "%s" (pysch-test--describe ds))
        (should (memq 3 (pysch-test--lines ds "XML")))
        (should (seq-some (lambda (d) (string-match-p "<notde> opened here is never closed"
                                                      (flymake-diagnostic-text d)))
                          ds))
        (pysch-test--visible ds)))))

(ert-deftest pysch-real-unsaved ()
  "Unsaved changes are checked; the file is not touched."
  (pysch-test--with-env
    (let* ((text (concat pysch-test--pi "\n<TEI xmlns=\"http://www.tei-c.org/ns/1.0\">\n<p>a</p>\n</TEI>\n"))
           (file (pysch-test--write "valid.xml" text)))
      (with-current-buffer (pysch-test--open "valid.xml")
        (should (null (pysch-test--check)))
        (goto-char (point-min)) (forward-line 3)
        (insert "<p>b</p>\n<p>c</p>\n")
        (let ((ds (pysch-test--check)))
          (message "%s" (pysch-test--describe ds))
          (should (buffer-modified-p))
          (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string)) text))
          (should (equal (pysch-test--lines ds "Schematron") '(2)))
          (pysch-test--visible ds))))))

(ert-deftest pysch-real-cancel ()
  "A new check cancels the one under way; only the last one reports."
  (pysch-test--with-env
    (pysch-test--write "valid.xml" (concat pysch-test--pi "\n<TEI xmlns=\"http://www.tei-c.org/ns/1.0\">\n<p>a</p>\n</TEI>\n"))
    (with-current-buffer (pysch-test--open "valid.xml")
      (flymake-start nil t)
      (goto-char (point-min)) (forward-line 3)
      (insert "<p>b</p>\n<p>c</p>\n")
      (let ((ds (pysch-test--check)))
        (should (equal (pysch-test--lines ds "Schematron") '(2)))
        (should-not (directory-files temporary-file-directory nil "^py-schematron-"))))))

(ert-deftest pysch-real-no-schema ()
  "A document without <?xml-model?> is left alone."
  (pysch-test--with-env
    (pysch-test--write "plain.xml" "<doc><a/></doc>\n")
    (with-current-buffer (pysch-test--open "plain.xml")
      (should (null (pysch-test--check))))))

(defconst pysch-test--invalid
  (concat pysch-test--pi "\n<TEI xmlns=\"http://www.tei-c.org/ns/1.0\">\n<p>a</p>\n<p>b</p>\n<p>c</p>\n</TEI>\n")
  "A document with one Schematron violation, on line 2.")

(defmacro pysch-test--capturing-warnings (var &rest body)
  "Run BODY collecting in VAR the texts of the package's warnings.
Flymake's own warnings are left out."
  (declare (indent 1))
  `(let ((,var nil))
     (cl-letf (((symbol-function 'display-warning)
                (lambda (type text &rest _)
                  (when (eq type 'py-schematron) (push text ,var)))))
       ,@body)))

(ert-deftest pysch-real-untrusted ()
  "A file outside `trusted-content' is not checked, and the user is told why, once."
  (pysch-test--with-env
    (pysch-test--write "invalid.xml" pysch-test--invalid)
    (let ((trusted-content nil)
          (py-schematron--warned (make-hash-table :test #'equal)))
      (pysch-test--capturing-warnings warnings
        (with-current-buffer (pysch-test--open "invalid.xml")
          (should (= (length warnings) 1))
          (should (string-match-p "invalid.xml is not in .trusted-content., so it is not checked as you type" (car warnings)))
          (should (string-match-p "M-x py-schematron-trust-file" (car warnings)))
          (should (string-match-p "(add-to-list 'trusted-content \".*invalid.xml\")" (car warnings)))
          (flymake-start nil t)
          (should (flymake-disabled-backends))
          (should (null (flymake-diagnostics)))
          ;; the commands explain instead of doing nothing
          (should (string-match-p "is not in .trusted-content."
                                  (cadr (should-error (py-schematron-check) :type 'user-error))))
          (should-error (py-schematron-refresh-schema) :type 'user-error)
          ;; turning the mode on again does not warn again
          (py-schematron-mode -1) (py-schematron-mode 1)
          (should (= (length warnings) 1))
          (should-not (directory-files temporary-file-directory nil "^py-schematron-")))))))

(ert-deftest pysch-real-trust-file ()
  "`py-schematron-trust-file' trusts the file or its folder, and checks."
  (pysch-test--with-env
    (pysch-test--write "invalid.xml" pysch-test--invalid)
    (let ((trusted-content nil)
          (py-schematron--warned (make-hash-table :test #'equal))
          (kill-ring nil))
      (pysch-test--capturing-warnings warnings
        (with-current-buffer (pysch-test--open "invalid.xml")
          ;; "quit" changes nothing
          (cl-letf (((symbol-function 'read-multiple-choice) (lambda (&rest _) '(?q "quit"))))
            (py-schematron-trust-file))
          (should (null trusted-content))
          ;; "file" trusts only this file, and the check runs
          (cl-letf (((symbol-function 'read-multiple-choice) (lambda (&rest _) '(?f "file"))))
            (py-schematron-trust-file))
          (should (equal trusted-content (list (abbreviate-file-name buffer-file-truename))))
          (should (equal (car kill-ring)
                         (format "(add-to-list 'trusted-content %S)" (car trusted-content))))
          (pysch-test--wait (lambda () (and (memq #'py-schematron-flymake (flymake-reporting-backends))
                                           (null py-schematron--run)))
                           "the check after trusting")
          (should (equal (pysch-test--lines (flymake-diagnostics) "Schematron") '(2)))
          ;; "folder" trusts the folder
          (setq trusted-content nil)
          (cl-letf (((symbol-function 'read-multiple-choice) (lambda (&rest _) '(?d "folder"))))
            (py-schematron-trust-file))
          (should (equal trusted-content (list (file-name-directory (abbreviate-file-name buffer-file-truename)))))
          (should (trusted-content-p))
          (should (= (length warnings) 1)))))))  ; the one on opening

(ert-deftest pysch-real-report-untrusted ()
  "The report runs on an untrusted file, and ends saying live checking is off."
  (pysch-test--with-env
    (pysch-test--write "invalid.xml" pysch-test--invalid)
    (let ((trusted-content nil)
          (py-schematron--warned (make-hash-table :test #'equal)))
      (pysch-test--capturing-warnings warnings
        (with-current-buffer (pysch-test--open "invalid.xml")
          (py-schematron-report))
        (should (= (length warnings) 1)))
      (let ((report (get-buffer "*py-schematron report*")))
        (pysch-test--wait (lambda () (with-current-buffer report
                                      (string-match-p "^Note: " (buffer-string))))
                         "the report's note")
        (with-current-buffer report
          (should (string-match-p "at most 2 p, found 3" (buffer-string)))
          (should (string-match-p "Note: .*invalid.xml is not in .trusted-content." (buffer-string))))
        (kill-buffer report)))))

(ert-deftest pysch-real-schema-setting ()
  "`py-schematron-schema' applies to documents without <?xml-model?>."
  (pysch-test--with-env
    (pysch-test--write "plain.xml" "<TEI xmlns=\"http://www.tei-c.org/ns/1.0\">\n<p>a</p>\n<p>b</p>\n<p>c</p>\n</TEI>\n")
    (with-current-buffer (pysch-test--open "plain.xml")
      (setq-local py-schematron-schema "schema.rng")
      (should (equal (pysch-test--lines (pysch-test--check) "Schematron") '(1))))))

(ert-deftest pysch-real-missing-python ()
  "A Python that cannot be run is explained, not a silent failure."
  (pysch-test--with-env
    (pysch-test--write "valid.xml" (concat pysch-test--pi "\n<TEI xmlns=\"http://www.tei-c.org/ns/1.0\">\n<p>a</p>\n</TEI>\n"))
    (with-current-buffer (pysch-test--open "valid.xml")
      (let* ((py-schematron-python "/no/such/python")
             (ds (pysch-test--check)))
        (should (= (length ds) 1))
        (should (string-match-p "Could not run the Python interpreter \"/no/such/python\""
                                (flymake-diagnostic-text (car ds))))))))

(ert-deftest pysch-real-fatal-error ()
  "The program's own fatal error comes from its JSON, word for word."
  (pysch-test--with-env
    (pysch-test--write "valid.xml" (concat pysch-test--pi "\n<TEI xmlns=\"http://www.tei-c.org/ns/1.0\">\n<p>a</p>\n</TEI>\n"))
    (with-current-buffer (pysch-test--open "valid.xml")
      (let* ((py-schematron-schema (expand-file-name "missing.sch" pysch-test--dir))
             (py-schematron-schema-type 'sch)
             (ds (pysch-test--check)))
        (should (= (length ds) 1))
        (should (string-match-p "missing\\.sch" (flymake-diagnostic-text (car ds))))
        (should-not (string-match-p "^\\[" (flymake-diagnostic-text (car ds))))))))

(ert-deftest pysch-downloaded-url ()
  "The URL of a download: from the report's events, or an older script's stderr."
  (let ((report (lambda (events)
                  (json-parse-string (json-serialize
                                      `((documents . []) ,@(and events `((events . ,events))))))))
        (url "https://example.org/s.rng"))
    (should (equal (py-schematron--downloaded-url
                    (funcall report `[((kind . "xml-model") (message . "m"))
                                      ((kind . "download") (message . ,url) (url . ,url))])
                    "")
                   url))
    ;; events without a download: nothing was downloaded, whatever stderr says
    (should-not (py-schematron--downloaded-url
                 (funcall report `[((kind . "cache") (message . "m") (url . ,url))])
                 (concat "[descarga] " url)))
    ;; an older script: no events, so stderr
    (should (equal (py-schematron--downloaded-url (funcall report nil)
                                                   (concat "[xml-model] x\n[descarga] " url "\n"))
                   url))
    (should (equal (py-schematron--downloaded-url nil (concat "[descarga] " url)) url))
    (should-not (py-schematron--downloaded-url nil ""))))

(ert-deftest pysch-rule-links ()
  "Violations and XPath errors link to their rules; older JSON has none."
  (let* ((json (json-parse-string
                (json-serialize
                 '((documents
                    . [((file . "d.xml")
                        (violations
                         . [((pattern . "p") (context . "tei:p") (type . "assert") (role . "")
                             (message . "m") (text . "m") (path . "/x") (line . 3)
                             (rule . ((file . "/s/smed-schema.xml") (line . 186))))
                            ((pattern . "p") (context . "tei:p") (type . "assert") (role . "")
                             (message . "old") (text . "old") (path . "/y") (line . 4))])
                        (xpath_errors
                         . [((message . "broken") (context . "tei:q") (error . "XPTY0004")
                             (nodes . 2) (rule . ((file . "/s/smed-schema.xml") (line . 200))))]))])))))
         (items (py-schematron--json-items json)))
    (should (equal (plist-get (nth 0 items) :rules)
                   '((:file "/s/smed-schema.xml" :line 186
                      :label "The rule: smed-schema.xml, line 186"))))
    (should-not (plist-get (nth 1 items) :rules))
    (should (equal (plist-get (nth 2 items) :rules)
                   '((:file "/s/smed-schema.xml" :line 200
                      :label "Failed: broken: smed-schema.xml, line 200"))))))

(ert-deftest pysch-real-goto-rule ()
  "From the Schematron error on line 2 to the assert in schema.rng, and back."
  (pysch-test--with-env
    (pysch-test--write "invalid.xml" pysch-test--invalid)
    (let ((doc (pysch-test--open "invalid.xml")))
      (with-current-buffer doc
        (should (pysch-test--check))
        (goto-char (point-min))
        (should-error (py-schematron-goto-rule) :type 'user-error)   ; line 1: none
        (forward-line 1))
      (set-buffer doc)
      (py-schematron-goto-rule)                ; (it visits the schema)
      (should (equal (file-name-nondirectory buffer-file-name) "schema.rng"))
      (should (looking-at-p "<sch:assert"))
      (kill-buffer))))

(ert-deftest pysch-installer-python ()
  "With `py-schematron-python' nil, the installer's Python if it exists, else python3."
  (let* ((dir (make-temp-file "pysch-data-" t))
         (process-environment (cons (concat "XDG_DATA_HOME=" dir) process-environment))
         (system-type 'gnu/linux)
         (python (expand-file-name "py-schematron/venv/bin/python" dir)))
    (unwind-protect
        (progn
          (should (equal (py-schematron--installer-python) python))
          (let ((py-schematron-python nil))
            (should (equal (py-schematron--python) "python3"))      ; (not installed)
            (make-directory (file-name-directory python) t)
            (with-temp-file python (insert "#!/bin/sh\n"))
            (set-file-modes python #o755)
            (should (equal (py-schematron--python) python)))
          (let ((py-schematron-python "/my/python"))                 ; (a setting wins)
            (should (equal (py-schematron--python) "/my/python"))))
      (delete-directory dir t))))

(ert-deftest pysch-obsolete-names ()
  "The package's names until 0.7.0 still work, as obsolete aliases."
  (let ((out (pysch-test--fresh-emacs
              '(setq py-xmlvalidate-python "/opt/py")
              '(require 'py-xmlvalidate)
              '(princ (format "%S %S %S %S" py-schematron-python
                              (fboundp 'py-xmlvalidate-mode)
                              (fboundp 'py-xmlvalidate-goto-rule)
                              (featurep 'py-schematron))))))
    (should (string-search "\"/opt/py\" t t t" out))))

(ert-deftest pysch-real-refresh ()
  "Refresh: a changed remote schema is downloaded again and applied."
  (pysch-test--with-env
    (let* ((served (expand-file-name "served" pysch-test--dir))
           (server nil) (port nil))
      (make-directory served)
      (with-temp-file (expand-file-name "remote.rng" served) (insert (pysch-test--rng 2)))
      (setq server (make-process
                    :name "pysch-server" :buffer (generate-new-buffer " *pysch-server*")
                    :command (list py-schematron-python "-u" "-m" "http.server" "0"
                                   "--bind" "127.0.0.1" "--directory" served)
                    :noquery t))
      (unwind-protect
          (progn
            (pysch-test--wait (lambda () (with-current-buffer (process-buffer server)
                                          (goto-char (point-min))
                                          (when (re-search-forward "port \\([0-9]+\\)" nil t)
                                            (setq port (match-string 1)))))
                             "the HTTP server" 20)
            (pysch-test--write "remote.xml"
                              (concat (replace-regexp-in-string
                                       "schema\\.rng" (format "http://127.0.0.1:%s/remote.rng" port)
                                       pysch-test--pi)
                                      "\n<TEI xmlns=\"http://www.tei-c.org/ns/1.0\">\n<p>a</p>\n<p>b</p>\n</TEI>\n"))
            (with-current-buffer (pysch-test--open "remote.xml")
              (should (null (pysch-test--check)))
              ;; the schema changes upstream: now at most 1 p
              (with-temp-file (expand-file-name "remote.rng" served) (insert (pysch-test--rng 1)))
              (should (null (pysch-test--check)))   ; the cached copy still applies
              (setq py-schematron--refresh t)
              (let ((ds (pysch-test--check)))
                (should (= (length ds) 1))
                (should (string-match-p "at most 1 p, found 2" (flymake-diagnostic-text (car ds)))))
              (should (string-match-p "downloaded again from http://127.0.0.1"
                                      (with-current-buffer "*Messages*"
                                        (buffer-substring (line-beginning-position 0) (point-max)))))))
        (delete-process server)))))

(ert-deftest pysch-real-refresh-local ()
  "Refresh on a local schema says there is nothing to download."
  (pysch-test--with-env
    (pysch-test--write "valid.xml" (concat pysch-test--pi "\n<TEI xmlns=\"http://www.tei-c.org/ns/1.0\">\n<p>a</p>\n</TEI>\n"))
    (with-current-buffer (pysch-test--open "valid.xml")
      (setq py-schematron--refresh t)
      (pysch-test--check)
      (should (string-match-p "the schema is local (schema.rng); nothing to download"
                              (with-current-buffer "*Messages*"
                                (buffer-substring (line-beginning-position 0) (point-max))))))))

(ert-deftest pysch-real-live-max-size ()
  "Buffers over `py-schematron-live-max-size' are checked on save only."
  (pysch-test--with-env
    (pysch-test--write "valid.xml" (concat pysch-test--pi "\n<TEI xmlns=\"http://www.tei-c.org/ns/1.0\">\n<p>a</p>\n</TEI>\n"))
    (let ((py-schematron-live-max-size 50))
      (with-current-buffer (pysch-test--open "valid.xml")
        (should (null flymake-no-changes-timeout))
        (py-schematron-mode -1)
        (should (eql flymake-no-changes-timeout (default-value 'flymake-no-changes-timeout)))))))

(ert-deftest pysch-real-report ()
  "The report command links its detailed lines to the file."
  (pysch-test--with-env
    (pysch-test--write "invalid.xml" (concat pysch-test--pi "\n<TEI xmlns=\"http://www.tei-c.org/ns/1.0\">\n<p>a</p>\n<p>b</p>\n<p>c</p>\n</TEI>\n"))
    (let ((file-buffer (pysch-test--open "invalid.xml")))
      (with-current-buffer file-buffer (py-schematron-report))
      (let ((report (get-buffer "*py-schematron report*")))
        (should report)
        (pysch-test--wait (lambda () (not (get-buffer-process report))) "the report")
        (with-current-buffer report
          (should (string-match-p "at most 2 p, found 3" (buffer-string)))
          (should (string-match-p "py-schematron violations found at " (buffer-string)))
          (should-not (string-match-p "^Note: " (buffer-string)))
          (goto-char (point-min))
          (compilation-next-error 1)
          (compile-goto-error))
        (should (eq (current-buffer) file-buffer))
        (should (= (line-number-at-pos) 2))
        (kill-buffer report)))))

(ert-deftest pysch-real-check-setup ()
  "The setup check finds the Python and the script."
  (pysch-test--with-env
    (py-schematron-check-setup)
    (with-current-buffer "*py-schematron setup*"
      (should (string-match-p "ok   Python: .*with saxonche and lxml" (buffer-string)))
      (should (string-match-p "ok   Script: " (buffer-string))))))

;;;; Flycheck

;; Flycheck is loaded only when the tests run (from FLYCHECK_DIR).
(defvar flycheck-last-status-change)
(defvar flycheck-current-errors)
(defvar flycheck-mode)
(defvar flycheck-checker)
(declare-function flycheck-mode "ext:flycheck")
(declare-function flycheck-buffer "ext:flycheck")
(declare-function flycheck-running-p "ext:flycheck")
(declare-function flycheck-line-column-to-position "ext:flycheck")
(declare-function flycheck-error-line "ext:flycheck")
(declare-function flycheck-error-column "ext:flycheck")
(declare-function flycheck-error-end-line "ext:flycheck")
(declare-function flycheck-error-end-column "ext:flycheck")
(declare-function flycheck-error-level "ext:flycheck")
(declare-function flycheck-error-message "ext:flycheck")
(declare-function flycheck-error-id "ext:flycheck")

(defmacro pysch-test--with-flycheck (&rest body)
  "Run BODY with Flycheck loaded from FLYCHECK_DIR, and the Flycheck front end."
  (declare (indent 0))
  `(let ((dir (getenv "FLYCHECK_DIR")))
     (unless (and dir (file-exists-p (expand-file-name "flycheck.el" dir)))
       (ert-skip "FLYCHECK_DIR is not set"))
     (add-to-list 'load-path dir)
     (require 'flycheck)
     (let ((py-schematron-frontend 'flycheck))
       ,@body)))

(defun pysch-test--flycheck-check ()
  "Check the current buffer with Flycheck; return its errors."
  (flycheck-buffer)
  (pysch-test--wait (lambda () (and (not (flycheck-running-p))
                                   (memq flycheck-last-status-change
                                         '(finished no-checker errored interrupted suspicious))))
                   "Flycheck")
  flycheck-current-errors)

(defun pysch-test--flycheck-text (err)
  "The buffer text Flycheck marks for ERR."
  (buffer-substring (flycheck-line-column-to-position (flycheck-error-line err) (flycheck-error-column err))
                    (flycheck-line-column-to-position (flycheck-error-end-line err)
                                                      (flycheck-error-end-column err))))

(ert-deftest pysch-flycheck-invalid ()
  "With Flycheck, the same problems on the same lines, with layer and pattern."
  (pysch-test--with-env
    (pysch-test--with-flycheck
      (pysch-test--write "invalid.xml" (concat pysch-test--pi "\n<TEI xmlns=\"http://www.tei-c.org/ns/1.0\">\n<p>a</p>\n<p>b</p>\n<p>c<bogus/></p>\n</TEI>\n"))
      (with-current-buffer (pysch-test--open "invalid.xml")
        (should (eq py-schematron--using 'flycheck))
        (should flycheck-mode)
        (should (eq flycheck-checker 'py-schematron))
        (let ((errs (pysch-test--flycheck-check)))
          (message "%s" (mapconcat (lambda (e) (format "L%d %s %s" (flycheck-error-line e)
                                                       (flycheck-error-level e) (flycheck-error-message e)))
                                   errs "\n"))
          (should (equal (mapcar #'flycheck-error-line errs) (if (getenv "JING") '(2 5) '(2))))
          (let ((s (car errs)))
            (should (eq (flycheck-error-level s) 'error))
            (should (equal (flycheck-error-id s) "max-p"))
            (should (string-match-p "\\`Schematron: A TEI may contain at most 2 p, found 3" (flycheck-error-message s))))
          (when (getenv "JING")
            (should (string-prefix-p "RelaxNG: " (flycheck-error-message (cadr errs))))
            (should (equal (pysch-test--flycheck-text (cadr errs)) "<bogus/>"))))
        ;; turning the mode off turns off the Flycheck it turned on
        (py-schematron-mode -1)
        (should-not flycheck-mode)
        (should-not (local-variable-p 'flycheck-checker))
        (should-not (directory-files temporary-file-directory nil "^py-schematron-"))))))

(ert-deftest pysch-flycheck-unsaved-and-cancel ()
  "With Flycheck, unsaved text is checked, and a new check replaces a running one."
  (pysch-test--with-env
    (pysch-test--with-flycheck
      (pysch-test--write "valid.xml" (concat pysch-test--pi "\n<TEI xmlns=\"http://www.tei-c.org/ns/1.0\">\n<p>a</p>\n</TEI>\n"))
      (with-current-buffer (pysch-test--open "valid.xml")
        (should (null (pysch-test--flycheck-check)))
        (flycheck-buffer)                          ; started, then replaced
        (goto-char (point-min)) (forward-line 3)
        (insert "<p>b</p>\n<p>c</p>\n")
        (let ((errs (pysch-test--flycheck-check)))
          (should (equal (mapcar #'flycheck-error-line errs) '(2)))
          (should (buffer-modified-p)))
        (should-not (seq-filter (lambda (p) (string-prefix-p "py-schematron" (process-name p)))
                                (process-list)))))))

(ert-deftest pysch-flycheck-untrusted ()
  "With Flycheck too, an untrusted file is not checked, and the user is told once."
  (pysch-test--with-env
    (pysch-test--with-flycheck
      (pysch-test--write "invalid.xml" pysch-test--invalid)
      (let ((trusted-content nil)
            (py-schematron--warned (make-hash-table :test #'equal)))
        (pysch-test--capturing-warnings warnings
          (with-current-buffer (pysch-test--open "invalid.xml")
            (should (= (length warnings) 1))
            (should (null (pysch-test--flycheck-check)))
            (should-error (py-schematron-check) :type 'user-error)
            (should-not (directory-files temporary-file-directory nil "^py-schematron-"))
            ;; trusting it starts the check with Flycheck
            (cl-letf (((symbol-function 'read-multiple-choice) (lambda (&rest _) '(?f "file"))))
              (py-schematron-trust-file))
            (pysch-test--wait (lambda () (and (not (flycheck-running-p))
                                             (eq flycheck-last-status-change 'finished)))
                             "Flycheck after trusting")
            (should (equal (mapcar #'flycheck-error-line flycheck-current-errors) '(2)))))))))

(ert-deftest pysch-flycheck-already-on ()
  "If Flycheck was already on, turning the mode off leaves it on."
  (pysch-test--with-env
    (pysch-test--with-flycheck
      (pysch-test--write "valid.xml" (concat pysch-test--pi "\n<TEI xmlns=\"http://www.tei-c.org/ns/1.0\">\n<p>a</p>\n</TEI>\n"))
      (find-file (expand-file-name "valid.xml" pysch-test--dir))
      (nxml-mode)
      (flycheck-mode 1)
      (py-schematron-mode 1)
      (should-not py-schematron--own-flycheck)
      (py-schematron-mode -1)
      (should flycheck-mode)
      (flycheck-mode -1))))


;;;; The schema for nxml

(defmacro pysch-test--with-trang (&rest body)
  "Run BODY with trang (PYSCH_TRANG) and the nxml schema feature on."
  (declare (indent 0))
  `(progn
     (unless (getenv "PYSCH_TRANG") (ert-skip "PYSCH_TRANG is not set"))
     (let ((py-schematron-nxml-schema t))
       ,@body)))

(defun pysch-test--nxml-ready (rnc-prefix)
  "Wait until nxml's schema is a compact schema in the cache; return it."
  (pysch-test--wait (lambda () (and rng-current-schema-file-name
                                   (string-prefix-p rnc-prefix rng-current-schema-file-name)))
                   "the nxml schema" 60)
  rng-current-schema-file-name)

(ert-deftest pysch-nxml-schema ()
  "nxml gets the document's schema: completion, and validation without false errors."
  (pysch-test--with-env
    (pysch-test--with-trang
      (pysch-test--write "valid.xml" (concat pysch-test--pi "\n<TEI xmlns=\"http://www.tei-c.org/ns/1.0\">\n<p ed=\"#U2 %A\">a</p>\n</TEI>\n"))
      (with-current-buffer (pysch-test--open "valid.xml")
        (should (null rng-current-schema-file-name))          ; vacuous at first
        (should (null (pysch-test--check)))
        (let* ((cache (expand-file-name "py-schematron/rnc/" user-emacs-directory))
               (rnc (pysch-test--nxml-ready cache)))
          (should (string-suffix-p "-schema.rnc" rnc))
          (should (equal py-schematron--nxml-rnc rnc))
          ;; nxml's copy is trang's, with TEI's word pattern unchanged
          (should (string-search pysch-test--word-pattern
                                 (with-temp-buffer (insert-file-contents rnc) (buffer-string))))
          (should (advice-member-p #'py-schematron--xsdre-copy-ranges 'xsdre-range-list-union))
          ;; nothing was written next to the document
          (should-not (file-exists-p (expand-file-name "schemas.xml" pysch-test--dir)))
          ;; completion: inside TEI, p is offered
          (goto-char (point-min)) (search-forward "<TEI")
          (end-of-line)
          (rng-set-state-after (point))
          (should (member "p" (mapcar #'cdr (rng-match-possible-start-tag-names))))
          ;; nxml's validation: ed="#U2 %A" is valid (nxml alone would reject it)
          (rng-validate-mode 1)
          (while (rng-do-some-validation))
          (should (= rng-error-count 0))
          ;; and an element the schema does not allow is an error
          (goto-char (point-min)) (search-forward "</p>") (insert "<bogus/>")
          (while (rng-do-some-validation))
          (should (= rng-error-count 1))
          ;; turning the mode off gives nxml back its vacuous schema
          (py-schematron-mode -1)
          (should (null rng-current-schema-file-name)))))))

(ert-deftest pysch-nxml-schema-cached ()
  "A second document with the same schema uses the cached compact schema at once."
  (pysch-test--with-env
    (pysch-test--with-trang
      (dolist (f '("a.xml" "b.xml"))
        (pysch-test--write f (concat pysch-test--pi "\n<TEI xmlns=\"http://www.tei-c.org/ns/1.0\">\n<p>a</p>\n</TEI>\n")))
      (let ((cache (expand-file-name "py-schematron/rnc/" user-emacs-directory)) first)
        (with-current-buffer (pysch-test--open "a.xml")
          (pysch-test--check)
          (setq first (pysch-test--nxml-ready cache)))
        (let ((mtime (file-attribute-modification-time (file-attributes first))))
          (with-current-buffer (pysch-test--open "b.xml")
            (pysch-test--check)
            ;; set by the time the check reports: no conversion needed
            (should (equal rng-current-schema-file-name first))
            (should (equal mtime (file-attribute-modification-time (file-attributes first))))))))))

(ert-deftest pysch-nxml-schema-respects-user-choice ()
  "A schema the user gave nxml is never replaced."
  (pysch-test--with-env
    (pysch-test--with-trang
      (pysch-test--write "mine.rnc" "default namespace = \"http://www.tei-c.org/ns/1.0\"\nstart = element TEI { element p { text }* }\n")
      (pysch-test--write "valid.xml" (concat pysch-test--pi "\n<TEI xmlns=\"http://www.tei-c.org/ns/1.0\">\n<p>a</p>\n</TEI>\n"))
      (with-current-buffer (pysch-test--open "valid.xml")
        (let ((mine (expand-file-name "mine.rnc" pysch-test--dir)))
          (rng-set-schema-file-1 mine)
          (pysch-test--check)
          (sleep-for 1)
          (accept-process-output nil 2)
          (should (equal rng-current-schema-file-name mine))
          (py-schematron-mode -1)
          (should (equal rng-current-schema-file-name mine)))))))

(ert-deftest pysch-nxml-schema-no-trang ()
  "Without trang, one message and no error; the check itself is unaffected."
  (pysch-test--with-env
    (let ((py-schematron-nxml-schema t)
          (py-schematron-trang "no-such-trang")
          (py-schematron--trang-warned nil))
      (pysch-test--write "invalid.xml" pysch-test--invalid)
      (with-current-buffer (pysch-test--open "invalid.xml")
        (should (equal (pysch-test--lines (pysch-test--check) "Schematron") '(2)))
        (should py-schematron--trang-warned)
        (should (null rng-current-schema-file-name))
        (should (string-match-p "trang not found"
                                (with-current-buffer "*Messages*" (buffer-string))))))))

(declare-function xsdre-translate "xsd-regexp" (regexp))

(defun pysch-test--fresh-emacs (&rest forms)
  "Evaluate FORMS in a new batch Emacs with the package; return what they print."
  (let ((process-environment (cons (concat "PATH=" invocation-directory path-separator
                                           (getenv "PATH"))
                                   process-environment)))
    (with-temp-buffer
      (let ((code (apply #'call-process (expand-file-name invocation-name invocation-directory)
                         nil t nil "--batch" "-Q" "-L" pysch-test--repo
                         (mapcan (lambda (f) (list "--eval" (prin1-to-string f))) forms))))
        (unless (eq code 0) (error "Emacs failed (%s): %s" code (buffer-string)))
        (buffer-string)))))

(defconst pysch-test--nxml-probe
  '(progn
     (defun probe (pattern s)
       (string-match-p (concat "\\`" (xsdre-translate pattern) "\\'") s))
     (princ (format "fixes=%S\n" py-schematron--nxml-fixes))
     ;; \p{P} used three times, in different patterns (translations are cached)
     (princ (format "P=%S\n" (list (and (probe "\\p{P}" "#") t) (and (probe "[\\p{P}]" "#") t)
                                   (and (probe "(\\p{P})" "#") t))))
     (princ (format "L=%S\n" (mapcar (lambda (c) (and (probe "\\p{L}+" c) t)) '("ꝑ" "𝔄" "中"))))
     (princ (format "dot=%S\n" (and (probe "." "𝔄") t)))
     (princ (format "tei=%S\n" (list (and (probe "[^\\p{C}\\p{Z}]+" "ꝑ#U2") t)
                                     (and (probe "(\\p{L}|\\p{N}|\\p{P}|\\p{S})+" "ꝑ⸗#U2") t))))
     (princ (format "token=%S\n"
                    (and (rng-dt-make-value
                          (cdr (rng-xsd-compile 'token '((pattern . "(\\p{L}|\\p{N}|\\p{P}|\\p{S})+"))))
                          " #U2")
                         t))))
  "Prints what nxml's XSD code does with the cases its bugs get wrong.")

(ert-deftest pysch-nxml-mending ()
  "nxml's three bugs are mended as soon as it loads its XSD code."
  (let ((out (pysch-test--fresh-emacs
              '(require 'py-schematron) '(require 'rng-xsd) pysch-test--nxml-probe)))
    (should (string-match-p "^fixes=(whitespace unicode category-tables)$" out))
    (should (string-match-p "^P=(t t t)$" out))
    (should (string-match-p "^L=(t t t)$" out))
    (should (string-match-p "^dot=t$" out))
    (should (string-match-p "^tei=(t t)$" out))
    (should (string-match-p "^token=t$" out))))

(ert-deftest pysch-nxml-mending-off ()
  "With `py-schematron-fix-nxml' nil, nxml is left as it is, bugs and all."
  (let ((out (pysch-test--fresh-emacs
              '(require 'py-schematron) '(setq py-schematron-fix-nxml nil)
              '(require 'rng-xsd) pysch-test--nxml-probe)))
    (should (string-match-p "^fixes=nil$" out))
    (should (string-match-p "^P=(t nil nil)$" out))         ; damaged after the first use
    (should (string-match-p "^L=(nil nil nil)$" out))
    (should (string-match-p "^token=nil$" out))))

(ert-deftest pysch-nxml-mending-late ()
  "Loaded after nxml has damaged its tables, the package still mends them."
  (let ((out (pysch-test--fresh-emacs
              '(require 'rng-xsd)
              '(progn (xsdre-translate "\\p{P}") (xsdre-translate "\\p{P}"))   ; (the damage)
              '(require 'py-schematron)
              '(py-schematron--fix-xsdre) '(py-schematron--fix-rng-xsd)
              pysch-test--nxml-probe)))
    (should (string-match-p "^P=(t t t)$" out))
    (should (string-match-p "^L=(t t t)$" out))
    (should (string-match-p "^token=t$" out))))

(declare-function xsdre-make-range-list "xsd-regexp" (list))

(ert-deftest pysch-xsdre-fixed-emacs ()
  "An Emacs whose union copies its lists is left alone: no advice."
  (require 'xsd-regexp)
  (let ((fixed (lambda (range-lists)
                 (xsdre-make-range-list (apply #'append (append range-lists (list nil))))))
        (had (advice-member-p #'py-schematron--xsdre-copy-ranges 'xsdre-range-list-union)))
    (advice-remove 'xsdre-range-list-union #'py-schematron--xsdre-copy-ranges)
    (unwind-protect
        (cl-letf (((symbol-function 'xsdre-range-list-union) fixed))
          (let ((py-schematron--xsdre-checked nil))
            (should-not (py-schematron--xsdre-buggy-p))
            (py-schematron--fix-xsdre)
            (should-not (advice-member-p #'py-schematron--xsdre-copy-ranges
                                         'xsdre-range-list-union))
            (should py-schematron--xsdre-checked)))
      (when had
        (advice-add 'xsdre-range-list-union :filter-args #'py-schematron--xsdre-copy-ranges)))))

;;;; Recreating the schema for nxml

(defun pysch-test--offered (after)
  "Element names nxml offers just after the first occurrence of AFTER."
  (save-excursion
    (goto-char (point-min))
    (search-forward after)
    (rng-set-state-after (point))
    (sort (mapcar #'cdr (rng-match-possible-start-tag-names)) #'string<)))

(defconst pysch-test--valid
  (concat pysch-test--pi "\n<TEI xmlns=\"http://www.tei-c.org/ns/1.0\">\n<p>a</p>\n</TEI>\n")
  "A valid document for the test schema.")

(ert-deftest pysch-nxml-schema-recreate ()
  "The command converts the schema again, and every buffer using it reloads it."
  (pysch-test--with-env
    (pysch-test--with-trang
      (dolist (f '("a.xml" "b.xml")) (pysch-test--write f pysch-test--valid))
      (let ((cache (expand-file-name "py-schematron/rnc/" user-emacs-directory))
            (a (pysch-test--open "a.xml")) b rnc)
        (with-current-buffer a (pysch-test--check) (setq rnc (pysch-test--nxml-ready cache)))
        (setq b (pysch-test--open "b.xml"))
        (with-current-buffer b (pysch-test--check) (should (equal rng-current-schema-file-name rnc)))
        ;; spoil the cached copy (p becomes q) and load it in both buffers
        (let ((text (with-temp-buffer (insert-file-contents rnc) (buffer-string))))
          (should (string-search "element p " text))
          (with-temp-file rnc (insert (string-replace "element p " "element q " text))))
        (dolist (buf (list a b))
          (with-current-buffer buf
            (rng-set-schema-file-1 rnc)
            (should-not (member "p" (pysch-test--offered "<TEI")))))
        ;; recreate it from one of them
        (with-current-buffer a (py-schematron-recreate-nxml-schema))
        (pysch-test--wait (lambda () (with-current-buffer b (member "p" (pysch-test--offered "<TEI"))))
                         "the other buffer to reload" 60)
        (with-current-buffer a (should (member "p" (pysch-test--offered "<TEI"))))
        (should-not (string-search "element q " (with-temp-buffer (insert-file-contents rnc) (buffer-string))))
        (should (string-search pysch-test--word-pattern
                               (with-temp-buffer (insert-file-contents rnc) (buffer-string))))
        (should (string-match-p "nxml.s schema recreated from schema.rng (2 buffers)"
                                (with-current-buffer "*Messages*" (buffer-string))))
        (should-not (file-exists-p (expand-file-name "schemas.xml" pysch-test--dir)))))))

(ert-deftest pysch-nxml-schema-follows-rng ()
  "When the RelaxNG file changes, the next check converts it again and the
open buffer reloads it, although the compact file keeps its name."
  (pysch-test--with-env
    (pysch-test--with-trang
      (pysch-test--write "a.xml" pysch-test--valid)
      (let ((cache (expand-file-name "py-schematron/rnc/" user-emacs-directory))
            (rng (expand-file-name "schema.rng" pysch-test--dir)) rnc)
        (with-current-buffer (pysch-test--open "a.xml")
          (pysch-test--check)
          (setq rnc (pysch-test--nxml-ready cache))
          (should (member "note" (pysch-test--offered "<p>")))
          ;; the schema changes on disk: note becomes remark
          (let ((text (with-temp-buffer (insert-file-contents rng) (buffer-string))))
            (with-temp-file rng (insert (string-replace "<element name=\"note\">" "<element name=\"remark\">" text))))
          (set-file-times rng (time-add nil 10))
          (pysch-test--check)
          (pysch-test--wait (lambda () (member "remark" (pysch-test--offered "<p>")))
                           "the reloaded schema" 60)
          (should (equal rng-current-schema-file-name rnc))
          (should-not (member "note" (pysch-test--offered "<p>"))))))))

(ert-deftest pysch-nxml-schema-recreate-refusals ()
  "The command explains why it cannot run."
  (pysch-test--with-env
    (pysch-test--write "a.xml" pysch-test--valid)
    (let ((py-schematron-nxml-schema t)
          (py-schematron--warned (make-hash-table :test #'equal)))
      (pysch-test--capturing-warnings warnings
        (with-current-buffer (pysch-test--open "a.xml")
          (let ((py-schematron-trang "no-such-trang"))
            (should (string-match-p "No trang found"
                                    (cadr (should-error (py-schematron-recreate-nxml-schema)
                                                        :type 'user-error)))))
          (let ((py-schematron-nxml-schema nil))
            (should-error (py-schematron-recreate-nxml-schema) :type 'user-error))
          (when (getenv "PYSCH_TRANG")
            (let ((trusted-content nil))
              (should (string-match-p "is not in .trusted-content."
                                      (cadr (should-error (py-schematron-recreate-nxml-schema)
                                                          :type 'user-error))))))
          (should (<= (length warnings) 1)))))))

;;;; About

(ert-deftest pysch-real-about ()
  "The about buffer: the package's version from its header, author, links,
and the program's own --about; a missing Python is said, not an error."
  (pysch-test--with-env
    (let ((version (with-temp-buffer
                     (insert-file-contents (expand-file-name "py-schematron.el" pysch-test--repo))
                     (lm-version)))
          (py-schematron-script nil))
      (py-schematron-about)
      (with-current-buffer "*py-schematron about*"
        (should (string-prefix-p (format "py-schematron for Emacs %s\n" version) (buffer-string)))
        (should (string-search "Nicolas Vaughan <nicolasvaughan@proton.me>" (buffer-string)))
        (should (string-match-p "^py-schematron\\.py [0-9]+\\.[0-9]+$" (buffer-string)))
        (should (string-search "saxonche:" (buffer-string)))
        (should (string-match-p "^nxml:     " (buffer-string)))
        (goto-char (point-min))
        (search-forward "https://codeberg.org/nivaca/py-schematron.el")
        (should (button-at (1- (point))))
        (should buffer-read-only))
      (let ((py-schematron-python "/no/such/python"))
        (py-schematron-about)
        (with-current-buffer "*py-schematron about*"
          (should (string-search "was not found" (buffer-string))))))))

;;; py-schematron-tests.el ends here
