;;; py-xmlvalidate-tests.el --- Tests of py-xmlvalidate.el  -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Copyright (C) 2026 Nicolas Vaughan <nicolasvaughan@proton.me>
;; This file is part of py-xmlvalidate.  See the LICENSE file for details.

;;; Commentary:

;; Run from the repository's top folder:
;;
;;   PYXV_PYTHON=~/.venvs/schematron/bin/python JING=jing \
;;     emacs --batch -Q -L emacs -l emacs/test/py-xmlvalidate-tests.el \
;;     -f ert-run-tests-batch-and-exit
;;
;; The first group of tests reads the programs' output and needs nothing
;; else.  The second runs the real py-xmlvalidate.py (and jing, when JING
;; is set) through Flymake, on documents written to a temporary folder;
;; those tests are skipped unless PYXV_PYTHON names a Python with
;; saxonche and lxml.  The script is copied there too, so its download
;; cache stays out of the repository.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'nxml-mode)
(require 'rng-valid)
(require 'rng-nxml)
(eval-and-compile
  (add-to-list 'load-path
               (expand-file-name ".." (file-name-directory
                                       (or load-file-name byte-compile-current-file)))))
(require 'py-xmlvalidate)

(defconst pyxv-test--repo
  (expand-file-name "../.." (file-name-directory (or load-file-name buffer-file-name)))
  "The repository's top folder.")


;;;; Reading the output

(ert-deftest pyxv-severity ()
  (should (eq (py-xmlvalidate--severity "") :error))
  (should (eq (py-xmlvalidate--severity nil) :error))
  (should (eq (py-xmlvalidate--severity " Warning ") :warning))
  (should (eq (py-xmlvalidate--severity "info") :note))
  (should (eq (py-xmlvalidate--severity "fatal") :error)))

(ert-deftest pyxv-json-items ()
  (let* ((json (json-parse-string
                "{\"version\":\"1.15\",\"source\":{\"path\":\"/s.rng\",\"type\":\"rng\"},
                  \"documents\":[{\"file\":\"d.xml\",
                   \"violations\":[{\"pattern\":\"p1\",\"role\":\"\",\"message\":\"M …\",\"text\":\"M x\",\"line\":4},
                                   {\"pattern\":\"\",\"role\":\"warning\",\"message\":\"W\",\"text\":\"\",\"line\":null}],
                   \"xpath_errors\":[{\"message\":\"\",\"context\":\"tei:p\",\"error\":\"XPTY0004\",\"nodes\":3}]}]}"
                :null-object nil :false-object nil))
         (items (py-xmlvalidate--json-items json)))
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

(ert-deftest pyxv-malformed ()
  (let ((items (py-xmlvalidate--malformed-items
                "Opening and ending tag mismatch: notde line 3 and p, line 4, column 5" 4)))
    (should (equal (mapcar (lambda (i) (plist-get i :line)) items) '(4 3)))
    (should (string-match-p "<notde> opened here is never closed: the next end tag is </p> (line 4)"
                            (plist-get (nth 1 items) :message))))
  (should (= 1 (length (py-xmlvalidate--malformed-items "Premature end of data" 9)))))

(ert-deftest pyxv-jing-items ()
  (let* ((out "/tmp/a/d.xml:5:12: error: element \"bogus\" not allowed here\n/tmp/a/other.xml:1:1: error: x\n/tmp/a/d.xml:7:3: fatal: The element type \"p\" must be terminated\n")
         (all (py-xmlvalidate--jing-items out "/tmp/a/d.xml"))
         (some (py-xmlvalidate--jing-items out "/tmp/a/d.xml" t)))
    (should (equal (mapcar (lambda (i) (plist-get i :line)) all) '(5 7)))
    (should (= (plist-get (car all) :col) 11))
    (should (equal (plist-get (car all) :origin) "RelaxNG"))
    (should (= (length some) 1))))

(ert-deftest pyxv-underline ()
  ;; jing's column just after the start tag: from its "<" to the column
  (should (equal (py-xmlvalidate--underline "<p>c<bogus/></p>" 12) '(4 . 12)))
  ;; no column: the content, without indentation and trailing spaces
  (should (equal (py-xmlvalidate--underline "   <p>a</p>  ") '(3 . 11)))
  (should (equal (py-xmlvalidate--underline "") '(0 . 0)))
  ;; a column with no "<" before it
  (should (equal (py-xmlvalidate--underline "abc def" 2) '(2 . 7))))

(ert-deftest pyxv-explain-failure ()
  (should (string-match-p "does not have the 'saxonche' library"
                          (py-xmlvalidate--explain-failure
                           "ModuleNotFoundError: No module named 'saxonche'" "py")))
  (should (equal (py-xmlvalidate--explain-failure
                  "[xml-model] esquema detectado: s.rng\nERROR: no se encuentra s.rng\n" "py")
                 "ERROR: no se encuentra s.rng"))
  (should (equal (py-xmlvalidate--explain-failure "" "py")
                 "py-xmlvalidate.py failed without a message.")))


(ert-deftest pyxv-script-lookup ()
  "The script is found above this file, and through a Straight-style link."
  (let* ((root (make-temp-file "pyxv-lookup-" t))
         (clone (expand-file-name "repos/pkg/" root))
         (build (expand-file-name "build/pkg/" root)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "emacs" clone) t)
          (make-directory build t)
          (with-temp-file (expand-file-name "py-xmlvalidate.py" clone))
          (with-temp-file (expand-file-name "emacs/py-xmlvalidate.el" clone))
          (make-symbolic-link (expand-file-name "emacs/py-xmlvalidate.el" clone)
                              (expand-file-name "py-xmlvalidate.el" build))
          (let ((py-xmlvalidate-script nil))
            ;; package-vc, a clone: the folder above
            (let ((py-xmlvalidate--directory (expand-file-name "emacs/" clone)))
              (should (equal (py-xmlvalidate--script)
                             (expand-file-name "py-xmlvalidate.py" clone))))
            ;; Straight: the build folder, where the .el is a link
            (let ((py-xmlvalidate--directory build))
              (should (equal (file-truename (py-xmlvalidate--script))
                             (file-truename (expand-file-name "py-xmlvalidate.py" clone)))))
            ;; the setting wins
            (let ((py-xmlvalidate-script "~/x.py"))
              (should (equal (py-xmlvalidate--script) (expand-file-name "~/x.py"))))))
      (delete-directory root t))))

;;;; With the real programs

(defvar pyxv-test--dir nil "Temporary folder of the running test.")

(defconst pyxv-test--pi
  "<?xml-model href=\"schema.rng\" type=\"application/xml\" schematypens=\"http://relaxng.org/ns/structure/1.0\"?>")

(defun pyxv-test--rng (max)
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

(defun pyxv-test--write (name text)
  "Write TEXT to NAME in the test folder; return its full name."
  (let ((f (expand-file-name name pyxv-test--dir)))
    (with-temp-file f (insert text))
    f))

(defmacro pyxv-test--with-env (&rest body)
  "Run BODY with a fresh test folder, the script copied into it."
  (declare (indent 0))
  `(let ((python (getenv "PYXV_PYTHON")))
     (unless (and python (file-executable-p (expand-file-name python)))
       (ert-skip "PYXV_PYTHON is not set"))
     (let* ((pyxv-test--dir (make-temp-file "pyxv-test-" t))
            (temporary-file-directory (file-name-as-directory
                                       (expand-file-name "tmp" pyxv-test--dir)))
            (py-xmlvalidate-python python)
            (py-xmlvalidate-jing (or (getenv "JING") "no-such-jing"))
            (py-xmlvalidate-script (expand-file-name "bin/py-xmlvalidate.py" pyxv-test--dir))
            (py-xmlvalidate-live-max-size nil)
            (py-xmlvalidate-schema nil)
            (py-xmlvalidate-frontend 'flymake)
            (py-xmlvalidate-nxml-schema nil)
            (py-xmlvalidate-trang (or (and (getenv "PYXV_TRANG")
                                           (split-string-shell-command (getenv "PYXV_TRANG")))
                                      "no-such-trang"))
            (py-xmlvalidate--trang-warned nil)
            (user-emacs-directory (file-name-as-directory (expand-file-name "emacs.d" pyxv-test--dir)))
            (trusted-content (list (file-name-as-directory
                                    (abbreviate-file-name (file-truename pyxv-test--dir))))))
       (make-directory temporary-file-directory)
       (make-directory (expand-file-name "bin" pyxv-test--dir))
       (copy-file (expand-file-name "py-xmlvalidate.py" pyxv-test--repo) py-xmlvalidate-script)
       (pyxv-test--write "schema.rng" (pyxv-test--rng 2))
       (unwind-protect (progn ,@body)
         (dolist (b (buffer-list))
           (when (and (buffer-file-name b)
                      (string-prefix-p pyxv-test--dir (buffer-file-name b)))
             (with-current-buffer b (set-buffer-modified-p nil))
             (kill-buffer b)))
         (delete-directory pyxv-test--dir t)))))

(defun pyxv-test--wait (pred what &optional secs)
  "Wait until PRED returns non-nil, at most SECS seconds; WHAT for errors."
  (let ((end (+ (float-time) (or secs 60))))
    (while (not (funcall pred))
      (when (> (float-time) end) (error "Timed out waiting for %s" what))
      (accept-process-output nil 0.05))))

(defun pyxv-test--check ()
  "Check the current buffer and wait for the result; return the diagnostics."
  (flymake-start nil t)
  (pyxv-test--wait (lambda () (and (memq #'py-xmlvalidate-flymake (flymake-reporting-backends))
                                   (null py-xmlvalidate--run)))
                   "the check")
  (sort (flymake-diagnostics) (lambda (a b) (< (flymake-diagnostic-beg a) (flymake-diagnostic-beg b)))))

(defun pyxv-test--open (name)
  "Visit NAME in the test folder, with `py-xmlvalidate-mode' on."
  (find-file (expand-file-name name pyxv-test--dir))
  (nxml-mode)
  (py-xmlvalidate-mode 1)
  (current-buffer))

(defun pyxv-test--lines (diags origin)
  "Lines of DIAGS from ORIGIN."
  (sort (mapcar (lambda (d) (line-number-at-pos (flymake-diagnostic-beg d)))
                (seq-filter (lambda (d) (equal (flymake-diagnostic-origin d) origin)) diags))
        #'<))

(defun pyxv-test--describe (diags)
  "DIAGS as text, for failure messages."
  (mapconcat (lambda (d) (format "L%d %s [%s] %s" (line-number-at-pos (flymake-diagnostic-beg d))
                                 (flymake-diagnostic-type d) (flymake-diagnostic-origin d)
                                 (flymake-diagnostic-text d)))
             diags "\n"))

(defun pyxv-test--visible (diags)
  "Every diagnostic covers at least one character."
  (dolist (d diags)
    (should (< (flymake-diagnostic-beg d) (flymake-diagnostic-end d)))))

(ert-deftest pyxv-real-invalid ()
  "Schematron and RelaxNG errors are reported on the offending lines."
  (pyxv-test--with-env
    (pyxv-test--write "invalid.xml" (concat pyxv-test--pi "\n<TEI xmlns=\"http://www.tei-c.org/ns/1.0\">\n<p>a</p>\n<p>b</p>\n<p>c<bogus/></p>\n</TEI>\n"))
    (with-current-buffer (pyxv-test--open "invalid.xml")
      (let ((ds (pyxv-test--check)))
        (message "%s" (pyxv-test--describe ds))
        (should (equal (pyxv-test--lines ds "Schematron") '(2)))
        (should (string-match-p "A TEI may contain at most 2 p, found 3"
                                (flymake-diagnostic-text (car ds))))
        (should (equal (flymake-diagnostic-code (car ds)) "max-p"))
        (when (getenv "JING")
          (should (equal (pyxv-test--lines ds "RelaxNG") '(5)))
          (let ((d (car (last ds))))
            (should (equal (buffer-substring (flymake-diagnostic-beg d) (flymake-diagnostic-end d))
                           "<bogus/>"))))
        (should (seq-every-p (lambda (d) (eq (flymake-diagnostic-type d) :error)) ds))
        (pyxv-test--visible ds)
        ;; nothing left behind: no process, no temporary copy
        (should-not (seq-filter (lambda (p) (string-prefix-p "py-xmlvalidate" (process-name p)))
                                (process-list)))
        (should-not (directory-files temporary-file-directory nil "^py-xmlvalidate-"))))))

(ert-deftest pyxv-real-typo ()
  "A typo: the error points at the unclosed tag as well."
  (pyxv-test--with-env
    (pyxv-test--write "typo.xml" (concat pyxv-test--pi "\n<TEI xmlns=\"http://www.tei-c.org/ns/1.0\">\n<p>a <notde>x\n</p>\n<p>b</note></p>\n</TEI>\n"))
    (with-current-buffer (pyxv-test--open "typo.xml")
      (let ((ds (pyxv-test--check)))
        (message "%s" (pyxv-test--describe ds))
        (should (memq 3 (pyxv-test--lines ds "XML")))
        (should (seq-some (lambda (d) (string-match-p "<notde> opened here is never closed"
                                                      (flymake-diagnostic-text d)))
                          ds))
        (pyxv-test--visible ds)))))

(ert-deftest pyxv-real-unsaved ()
  "Unsaved changes are checked; the file is not touched."
  (pyxv-test--with-env
    (let* ((text (concat pyxv-test--pi "\n<TEI xmlns=\"http://www.tei-c.org/ns/1.0\">\n<p>a</p>\n</TEI>\n"))
           (file (pyxv-test--write "valid.xml" text)))
      (with-current-buffer (pyxv-test--open "valid.xml")
        (should (null (pyxv-test--check)))
        (goto-char (point-min)) (forward-line 3)
        (insert "<p>b</p>\n<p>c</p>\n")
        (let ((ds (pyxv-test--check)))
          (message "%s" (pyxv-test--describe ds))
          (should (buffer-modified-p))
          (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string)) text))
          (should (equal (pyxv-test--lines ds "Schematron") '(2)))
          (pyxv-test--visible ds))))))

(ert-deftest pyxv-real-cancel ()
  "A new check cancels the one under way; only the last one reports."
  (pyxv-test--with-env
    (pyxv-test--write "valid.xml" (concat pyxv-test--pi "\n<TEI xmlns=\"http://www.tei-c.org/ns/1.0\">\n<p>a</p>\n</TEI>\n"))
    (with-current-buffer (pyxv-test--open "valid.xml")
      (flymake-start nil t)
      (goto-char (point-min)) (forward-line 3)
      (insert "<p>b</p>\n<p>c</p>\n")
      (let ((ds (pyxv-test--check)))
        (should (equal (pyxv-test--lines ds "Schematron") '(2)))
        (should-not (directory-files temporary-file-directory nil "^py-xmlvalidate-"))))))

(ert-deftest pyxv-real-no-schema ()
  "A document without <?xml-model?> is left alone."
  (pyxv-test--with-env
    (pyxv-test--write "plain.xml" "<doc><a/></doc>\n")
    (with-current-buffer (pyxv-test--open "plain.xml")
      (should (null (pyxv-test--check))))))

(defconst pyxv-test--invalid
  (concat pyxv-test--pi "\n<TEI xmlns=\"http://www.tei-c.org/ns/1.0\">\n<p>a</p>\n<p>b</p>\n<p>c</p>\n</TEI>\n")
  "A document with one Schematron violation, on line 2.")

(defmacro pyxv-test--capturing-warnings (var &rest body)
  "Run BODY collecting in VAR the texts of the package's warnings.
Flymake's own warnings are left out."
  (declare (indent 1))
  `(let ((,var nil))
     (cl-letf (((symbol-function 'display-warning)
                (lambda (type text &rest _)
                  (when (eq type 'py-xmlvalidate) (push text ,var)))))
       ,@body)))

(ert-deftest pyxv-real-untrusted ()
  "A file outside `trusted-content' is not checked, and the user is told why, once."
  (pyxv-test--with-env
    (pyxv-test--write "invalid.xml" pyxv-test--invalid)
    (let ((trusted-content nil)
          (py-xmlvalidate--warned (make-hash-table :test #'equal)))
      (pyxv-test--capturing-warnings warnings
        (with-current-buffer (pyxv-test--open "invalid.xml")
          (should (= (length warnings) 1))
          (should (string-match-p "invalid.xml is not in .trusted-content., so it is not checked as you type" (car warnings)))
          (should (string-match-p "M-x py-xmlvalidate-trust-file" (car warnings)))
          (should (string-match-p "(add-to-list 'trusted-content \".*invalid.xml\")" (car warnings)))
          (flymake-start nil t)
          (should (flymake-disabled-backends))
          (should (null (flymake-diagnostics)))
          ;; the commands explain instead of doing nothing
          (should (string-match-p "is not in .trusted-content."
                                  (cadr (should-error (py-xmlvalidate-check) :type 'user-error))))
          (should-error (py-xmlvalidate-refresh-schema) :type 'user-error)
          ;; turning the mode on again does not warn again
          (py-xmlvalidate-mode -1) (py-xmlvalidate-mode 1)
          (should (= (length warnings) 1))
          (should-not (directory-files temporary-file-directory nil "^py-xmlvalidate-")))))))

(ert-deftest pyxv-real-trust-file ()
  "`py-xmlvalidate-trust-file' trusts the file or its folder, and checks."
  (pyxv-test--with-env
    (pyxv-test--write "invalid.xml" pyxv-test--invalid)
    (let ((trusted-content nil)
          (py-xmlvalidate--warned (make-hash-table :test #'equal))
          (kill-ring nil))
      (pyxv-test--capturing-warnings warnings
        (with-current-buffer (pyxv-test--open "invalid.xml")
          ;; "quit" changes nothing
          (cl-letf (((symbol-function 'read-multiple-choice) (lambda (&rest _) '(?q "quit"))))
            (py-xmlvalidate-trust-file))
          (should (null trusted-content))
          ;; "file" trusts only this file, and the check runs
          (cl-letf (((symbol-function 'read-multiple-choice) (lambda (&rest _) '(?f "file"))))
            (py-xmlvalidate-trust-file))
          (should (equal trusted-content (list (abbreviate-file-name buffer-file-truename))))
          (should (equal (car kill-ring)
                         (format "(add-to-list 'trusted-content %S)" (car trusted-content))))
          (pyxv-test--wait (lambda () (and (memq #'py-xmlvalidate-flymake (flymake-reporting-backends))
                                           (null py-xmlvalidate--run)))
                           "the check after trusting")
          (should (equal (pyxv-test--lines (flymake-diagnostics) "Schematron") '(2)))
          ;; "folder" trusts the folder
          (setq trusted-content nil)
          (cl-letf (((symbol-function 'read-multiple-choice) (lambda (&rest _) '(?d "folder"))))
            (py-xmlvalidate-trust-file))
          (should (equal trusted-content (list (file-name-directory (abbreviate-file-name buffer-file-truename)))))
          (should (trusted-content-p))
          (should (= (length warnings) 1)))))))  ; the one on opening

(ert-deftest pyxv-real-report-untrusted ()
  "The report runs on an untrusted file, and ends saying live checking is off."
  (pyxv-test--with-env
    (pyxv-test--write "invalid.xml" pyxv-test--invalid)
    (let ((trusted-content nil)
          (py-xmlvalidate--warned (make-hash-table :test #'equal)))
      (pyxv-test--capturing-warnings warnings
        (with-current-buffer (pyxv-test--open "invalid.xml")
          (py-xmlvalidate-report))
        (should (= (length warnings) 1)))
      (let ((report (get-buffer "*py-xmlvalidate report*")))
        (pyxv-test--wait (lambda () (with-current-buffer report
                                      (string-match-p "^Note: " (buffer-string))))
                         "the report's note")
        (with-current-buffer report
          (should (string-match-p "at most 2 p, found 3" (buffer-string)))
          (should (string-match-p "Note: .*invalid.xml is not in .trusted-content." (buffer-string))))
        (kill-buffer report)))))

(ert-deftest pyxv-real-schema-setting ()
  "`py-xmlvalidate-schema' applies to documents without <?xml-model?>."
  (pyxv-test--with-env
    (pyxv-test--write "plain.xml" "<TEI xmlns=\"http://www.tei-c.org/ns/1.0\">\n<p>a</p>\n<p>b</p>\n<p>c</p>\n</TEI>\n")
    (with-current-buffer (pyxv-test--open "plain.xml")
      (setq-local py-xmlvalidate-schema "schema.rng")
      (should (equal (pyxv-test--lines (pyxv-test--check) "Schematron") '(1))))))

(ert-deftest pyxv-real-missing-python ()
  "A Python that cannot be run is explained, not a silent failure."
  (pyxv-test--with-env
    (pyxv-test--write "valid.xml" (concat pyxv-test--pi "\n<TEI xmlns=\"http://www.tei-c.org/ns/1.0\">\n<p>a</p>\n</TEI>\n"))
    (with-current-buffer (pyxv-test--open "valid.xml")
      (let* ((py-xmlvalidate-python "/no/such/python")
             (ds (pyxv-test--check)))
        (should (= (length ds) 1))
        (should (string-match-p "Could not run the Python interpreter \"/no/such/python\""
                                (flymake-diagnostic-text (car ds))))))))

(ert-deftest pyxv-real-refresh ()
  "Refresh: a changed remote schema is downloaded again and applied."
  (pyxv-test--with-env
    (let* ((served (expand-file-name "served" pyxv-test--dir))
           (server nil) (port nil))
      (make-directory served)
      (with-temp-file (expand-file-name "remote.rng" served) (insert (pyxv-test--rng 2)))
      (setq server (make-process
                    :name "pyxv-server" :buffer (generate-new-buffer " *pyxv-server*")
                    :command (list py-xmlvalidate-python "-u" "-m" "http.server" "0"
                                   "--bind" "127.0.0.1" "--directory" served)
                    :noquery t))
      (unwind-protect
          (progn
            (pyxv-test--wait (lambda () (with-current-buffer (process-buffer server)
                                          (goto-char (point-min))
                                          (when (re-search-forward "port \\([0-9]+\\)" nil t)
                                            (setq port (match-string 1)))))
                             "the HTTP server" 20)
            (pyxv-test--write "remote.xml"
                              (concat (replace-regexp-in-string
                                       "schema\\.rng" (format "http://127.0.0.1:%s/remote.rng" port)
                                       pyxv-test--pi)
                                      "\n<TEI xmlns=\"http://www.tei-c.org/ns/1.0\">\n<p>a</p>\n<p>b</p>\n</TEI>\n"))
            (with-current-buffer (pyxv-test--open "remote.xml")
              (should (null (pyxv-test--check)))
              ;; the schema changes upstream: now at most 1 p
              (with-temp-file (expand-file-name "remote.rng" served) (insert (pyxv-test--rng 1)))
              (should (null (pyxv-test--check)))   ; the cached copy still applies
              (setq py-xmlvalidate--refresh t)
              (let ((ds (pyxv-test--check)))
                (should (= (length ds) 1))
                (should (string-match-p "at most 1 p, found 2" (flymake-diagnostic-text (car ds)))))
              (should (string-match-p "downloaded again from http://127.0.0.1"
                                      (with-current-buffer "*Messages*"
                                        (buffer-substring (line-beginning-position 0) (point-max)))))))
        (delete-process server)))))

(ert-deftest pyxv-real-refresh-local ()
  "Refresh on a local schema says there is nothing to download."
  (pyxv-test--with-env
    (pyxv-test--write "valid.xml" (concat pyxv-test--pi "\n<TEI xmlns=\"http://www.tei-c.org/ns/1.0\">\n<p>a</p>\n</TEI>\n"))
    (with-current-buffer (pyxv-test--open "valid.xml")
      (setq py-xmlvalidate--refresh t)
      (pyxv-test--check)
      (should (string-match-p "the schema is local (schema.rng); nothing to download"
                              (with-current-buffer "*Messages*"
                                (buffer-substring (line-beginning-position 0) (point-max))))))))

(ert-deftest pyxv-real-live-max-size ()
  "Buffers over `py-xmlvalidate-live-max-size' are checked on save only."
  (pyxv-test--with-env
    (pyxv-test--write "valid.xml" (concat pyxv-test--pi "\n<TEI xmlns=\"http://www.tei-c.org/ns/1.0\">\n<p>a</p>\n</TEI>\n"))
    (let ((py-xmlvalidate-live-max-size 50))
      (with-current-buffer (pyxv-test--open "valid.xml")
        (should (null flymake-no-changes-timeout))
        (py-xmlvalidate-mode -1)
        (should (eql flymake-no-changes-timeout (default-value 'flymake-no-changes-timeout)))))))

(ert-deftest pyxv-real-report ()
  "The report command links its detailed lines to the file."
  (pyxv-test--with-env
    (pyxv-test--write "invalid.xml" (concat pyxv-test--pi "\n<TEI xmlns=\"http://www.tei-c.org/ns/1.0\">\n<p>a</p>\n<p>b</p>\n<p>c</p>\n</TEI>\n"))
    (let ((file-buffer (pyxv-test--open "invalid.xml")))
      (with-current-buffer file-buffer (py-xmlvalidate-report))
      (let ((report (get-buffer "*py-xmlvalidate report*")))
        (should report)
        (pyxv-test--wait (lambda () (not (get-buffer-process report))) "the report")
        (with-current-buffer report
          (should (string-match-p "at most 2 p, found 3" (buffer-string)))
          (should (string-match-p "py-xmlvalidate violations found at " (buffer-string)))
          (should-not (string-match-p "^Note: " (buffer-string)))
          (goto-char (point-min))
          (compilation-next-error 1)
          (compile-goto-error))
        (should (eq (current-buffer) file-buffer))
        (should (= (line-number-at-pos) 2))
        (kill-buffer report)))))

(ert-deftest pyxv-real-check-setup ()
  "The setup check finds the Python and the script."
  (pyxv-test--with-env
    (py-xmlvalidate-check-setup)
    (with-current-buffer "*py-xmlvalidate setup*"
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

(defmacro pyxv-test--with-flycheck (&rest body)
  "Run BODY with Flycheck loaded from FLYCHECK_DIR, and the Flycheck front end."
  (declare (indent 0))
  `(let ((dir (getenv "FLYCHECK_DIR")))
     (unless (and dir (file-exists-p (expand-file-name "flycheck.el" dir)))
       (ert-skip "FLYCHECK_DIR is not set"))
     (add-to-list 'load-path dir)
     (require 'flycheck)
     (let ((py-xmlvalidate-frontend 'flycheck))
       ,@body)))

(defun pyxv-test--flycheck-check ()
  "Check the current buffer with Flycheck; return its errors."
  (flycheck-buffer)
  (pyxv-test--wait (lambda () (and (not (flycheck-running-p))
                                   (memq flycheck-last-status-change
                                         '(finished no-checker errored interrupted suspicious))))
                   "Flycheck")
  flycheck-current-errors)

(defun pyxv-test--flycheck-text (err)
  "The buffer text Flycheck marks for ERR."
  (buffer-substring (flycheck-line-column-to-position (flycheck-error-line err) (flycheck-error-column err))
                    (flycheck-line-column-to-position (flycheck-error-end-line err)
                                                      (flycheck-error-end-column err))))

(ert-deftest pyxv-flycheck-invalid ()
  "With Flycheck, the same problems on the same lines, with layer and pattern."
  (pyxv-test--with-env
    (pyxv-test--with-flycheck
      (pyxv-test--write "invalid.xml" (concat pyxv-test--pi "\n<TEI xmlns=\"http://www.tei-c.org/ns/1.0\">\n<p>a</p>\n<p>b</p>\n<p>c<bogus/></p>\n</TEI>\n"))
      (with-current-buffer (pyxv-test--open "invalid.xml")
        (should (eq py-xmlvalidate--using 'flycheck))
        (should flycheck-mode)
        (should (eq flycheck-checker 'py-xmlvalidate))
        (let ((errs (pyxv-test--flycheck-check)))
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
            (should (equal (pyxv-test--flycheck-text (cadr errs)) "<bogus/>"))))
        ;; turning the mode off turns off the Flycheck it turned on
        (py-xmlvalidate-mode -1)
        (should-not flycheck-mode)
        (should-not (local-variable-p 'flycheck-checker))
        (should-not (directory-files temporary-file-directory nil "^py-xmlvalidate-"))))))

(ert-deftest pyxv-flycheck-unsaved-and-cancel ()
  "With Flycheck, unsaved text is checked, and a new check replaces a running one."
  (pyxv-test--with-env
    (pyxv-test--with-flycheck
      (pyxv-test--write "valid.xml" (concat pyxv-test--pi "\n<TEI xmlns=\"http://www.tei-c.org/ns/1.0\">\n<p>a</p>\n</TEI>\n"))
      (with-current-buffer (pyxv-test--open "valid.xml")
        (should (null (pyxv-test--flycheck-check)))
        (flycheck-buffer)                          ; started, then replaced
        (goto-char (point-min)) (forward-line 3)
        (insert "<p>b</p>\n<p>c</p>\n")
        (let ((errs (pyxv-test--flycheck-check)))
          (should (equal (mapcar #'flycheck-error-line errs) '(2)))
          (should (buffer-modified-p)))
        (should-not (seq-filter (lambda (p) (string-prefix-p "py-xmlvalidate" (process-name p)))
                                (process-list)))))))

(ert-deftest pyxv-flycheck-untrusted ()
  "With Flycheck too, an untrusted file is not checked, and the user is told once."
  (pyxv-test--with-env
    (pyxv-test--with-flycheck
      (pyxv-test--write "invalid.xml" pyxv-test--invalid)
      (let ((trusted-content nil)
            (py-xmlvalidate--warned (make-hash-table :test #'equal)))
        (pyxv-test--capturing-warnings warnings
          (with-current-buffer (pyxv-test--open "invalid.xml")
            (should (= (length warnings) 1))
            (should (null (pyxv-test--flycheck-check)))
            (should-error (py-xmlvalidate-check) :type 'user-error)
            (should-not (directory-files temporary-file-directory nil "^py-xmlvalidate-"))
            ;; trusting it starts the check with Flycheck
            (cl-letf (((symbol-function 'read-multiple-choice) (lambda (&rest _) '(?f "file"))))
              (py-xmlvalidate-trust-file))
            (pyxv-test--wait (lambda () (and (not (flycheck-running-p))
                                             (eq flycheck-last-status-change 'finished)))
                             "Flycheck after trusting")
            (should (equal (mapcar #'flycheck-error-line flycheck-current-errors) '(2)))))))))

(ert-deftest pyxv-flycheck-already-on ()
  "If Flycheck was already on, turning the mode off leaves it on."
  (pyxv-test--with-env
    (pyxv-test--with-flycheck
      (pyxv-test--write "valid.xml" (concat pyxv-test--pi "\n<TEI xmlns=\"http://www.tei-c.org/ns/1.0\">\n<p>a</p>\n</TEI>\n"))
      (find-file (expand-file-name "valid.xml" pyxv-test--dir))
      (nxml-mode)
      (flycheck-mode 1)
      (py-xmlvalidate-mode 1)
      (should-not py-xmlvalidate--own-flycheck)
      (py-xmlvalidate-mode -1)
      (should flycheck-mode)
      (flycheck-mode -1))))


;;;; The schema for nxml

(defmacro pyxv-test--with-trang (&rest body)
  "Run BODY with trang (PYXV_TRANG) and the nxml schema feature on."
  (declare (indent 0))
  `(progn
     (unless (getenv "PYXV_TRANG") (ert-skip "PYXV_TRANG is not set"))
     (let ((py-xmlvalidate-nxml-schema t))
       ,@body)))

(defun pyxv-test--nxml-ready (rnc-prefix)
  "Wait until nxml's schema is a compact schema in the cache; return it."
  (pyxv-test--wait (lambda () (and rng-current-schema-file-name
                                   (string-prefix-p rnc-prefix rng-current-schema-file-name)))
                   "the nxml schema" 60)
  rng-current-schema-file-name)

(ert-deftest pyxv-nxml-schema ()
  "nxml gets the document's schema: completion, and validation without false errors."
  (pyxv-test--with-env
    (pyxv-test--with-trang
      (pyxv-test--write "valid.xml" (concat pyxv-test--pi "\n<TEI xmlns=\"http://www.tei-c.org/ns/1.0\">\n<p ed=\"#U2 %A\">a</p>\n</TEI>\n"))
      (with-current-buffer (pyxv-test--open "valid.xml")
        (should (null rng-current-schema-file-name))          ; vacuous at first
        (should (null (pyxv-test--check)))
        (let* ((cache (expand-file-name "py-xmlvalidate/rnc/" user-emacs-directory))
               (rnc (pyxv-test--nxml-ready cache)))
          (should (string-suffix-p "-schema.rnc" rnc))
          (should (equal py-xmlvalidate--nxml-rnc rnc))
          ;; the TEI word pattern was widened for nxml
          (should (string-search py-xmlvalidate--word-pattern-for-nxml
                                 (with-temp-buffer (insert-file-contents rnc) (buffer-string))))
          ;; nothing was written next to the document
          (should-not (file-exists-p (expand-file-name "schemas.xml" pyxv-test--dir)))
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
          (py-xmlvalidate-mode -1)
          (should (null rng-current-schema-file-name)))))))

(ert-deftest pyxv-nxml-schema-cached ()
  "A second document with the same schema uses the cached compact schema at once."
  (pyxv-test--with-env
    (pyxv-test--with-trang
      (dolist (f '("a.xml" "b.xml"))
        (pyxv-test--write f (concat pyxv-test--pi "\n<TEI xmlns=\"http://www.tei-c.org/ns/1.0\">\n<p>a</p>\n</TEI>\n")))
      (let ((cache (expand-file-name "py-xmlvalidate/rnc/" user-emacs-directory)) first)
        (with-current-buffer (pyxv-test--open "a.xml")
          (pyxv-test--check)
          (setq first (pyxv-test--nxml-ready cache)))
        (let ((mtime (file-attribute-modification-time (file-attributes first))))
          (with-current-buffer (pyxv-test--open "b.xml")
            (pyxv-test--check)
            ;; set by the time the check reports: no conversion needed
            (should (equal rng-current-schema-file-name first))
            (should (equal mtime (file-attribute-modification-time (file-attributes first))))))))))

(ert-deftest pyxv-nxml-schema-respects-user-choice ()
  "A schema the user gave nxml is never replaced."
  (pyxv-test--with-env
    (pyxv-test--with-trang
      (pyxv-test--write "mine.rnc" "default namespace = \"http://www.tei-c.org/ns/1.0\"\nstart = element TEI { element p { text }* }\n")
      (pyxv-test--write "valid.xml" (concat pyxv-test--pi "\n<TEI xmlns=\"http://www.tei-c.org/ns/1.0\">\n<p>a</p>\n</TEI>\n"))
      (with-current-buffer (pyxv-test--open "valid.xml")
        (let ((mine (expand-file-name "mine.rnc" pyxv-test--dir)))
          (rng-set-schema-file-1 mine)
          (pyxv-test--check)
          (sleep-for 1)
          (accept-process-output nil 2)
          (should (equal rng-current-schema-file-name mine))
          (py-xmlvalidate-mode -1)
          (should (equal rng-current-schema-file-name mine)))))))

(ert-deftest pyxv-nxml-schema-no-trang ()
  "Without trang, one message and no error; the check itself is unaffected."
  (pyxv-test--with-env
    (let ((py-xmlvalidate-nxml-schema t)
          (py-xmlvalidate-trang "no-such-trang")
          (py-xmlvalidate--trang-warned nil))
      (pyxv-test--write "invalid.xml" pyxv-test--invalid)
      (with-current-buffer (pyxv-test--open "invalid.xml")
        (should (equal (pyxv-test--lines (pyxv-test--check) "Schematron") '(2)))
        (should py-xmlvalidate--trang-warned)
        (should (null rng-current-schema-file-name))
        (should (string-match-p "trang not found"
                                (with-current-buffer "*Messages*" (buffer-string))))))))

(ert-deftest pyxv-write-rnc ()
  "The compact schema given to nxml has the TEI word pattern widened."
  (let* ((dir (make-temp-file "pyxv-rnc-" t))
         (from (expand-file-name "in.rnc" dir))
         (to (expand-file-name "out.rnc" dir)))
    (unwind-protect
        (progn
          (with-temp-file from
            (insert "a = xsd:token { pattern = \"" py-xmlvalidate--word-pattern "\" }\n"
                    "b = xsd:token { pattern = \"" py-xmlvalidate--word-pattern "\" }\n"))
          (py-xmlvalidate--write-rnc from to)
          (let ((text (with-temp-buffer (insert-file-contents to) (buffer-string))))
            (should (= 2 (let ((n 0) (i 0))
                           (while (setq i (string-search py-xmlvalidate--word-pattern-for-nxml text i))
                             (setq n (1+ n) i (1+ i)))
                           n)))
            (should-not (string-search (concat "\"" py-xmlvalidate--word-pattern "\"") text))))
      (delete-directory dir t))))

;;; py-xmlvalidate-tests.el ends here
