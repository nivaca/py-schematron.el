;;; py-xmlvalidate.el --- Former name of py-schematron  -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Copyright (C) 2026 Nicolas Vaughan <nicolasvaughan@proton.me>

;; This file is part of py-schematron.el.  See the LICENSE file for
;; details.

;;; Commentary:

;; The package was called py-xmlvalidate until 0.7.0.  This file lets
;; (require 'py-xmlvalidate) and (use-package py-xmlvalidate ...) go on
;; working for now: it loads py-schematron, whose options and commands
;; keep their former names as obsolete aliases.  Use py-schematron.

;;; Code:

(require 'py-schematron)

(provide 'py-xmlvalidate)

;;; py-xmlvalidate.el ends here
