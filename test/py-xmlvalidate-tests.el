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
(require 'nxml-mode)
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
      <oneOrMore><element name=\"p\"><zeroOrMore><choice><text/><element name=\"note\"><text/></element></choice></zeroOrMore></element></oneOrMore>
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

(ert-deftest pyxv-real-untrusted ()
  "A file outside `trusted-content' is not checked, and the user is told why."
  (pyxv-test--with-env
    (pyxv-test--write "invalid.xml" (concat pyxv-test--pi "\n<TEI xmlns=\"http://www.tei-c.org/ns/1.0\">\n<p>a</p>\n<p>b</p>\n<p>c</p>\n</TEI>\n"))
    (let ((trusted-content nil))
      (with-current-buffer (pyxv-test--open "invalid.xml")
        (should (string-match-p "invalid.xml is not in .trusted-content."
                                (with-current-buffer "*Messages*"
                                  (buffer-substring (point-min) (point-max)))))
        (flymake-start nil t)
        (should (flymake-disabled-backends))
        (should (null (flymake-diagnostics)))
        (should-not (directory-files temporary-file-directory nil "^py-xmlvalidate-"))))))

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

;;; py-xmlvalidate-tests.el ends here
