;;; ob-exp.el --- Exportation of org-babel source blocks

;; Copyright (C) 2009 Eric Schulte, Dan Davison

;; Author: Eric Schulte, Dan Davison
;; Keywords: literate programming, reproducible research
;; Homepage: http://orgmode.org
;; Version: 0.01

;;; License:

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
;; Boston, MA 02110-1301, USA.

;;; Commentary:

;; for more information see the comments in org-babel.el

;;; Code:
(require 'ob)
(require 'org-exp-blocks)
(eval-when-compile
  (require 'cl))

(add-to-list 'org-export-interblocks '(src org-babel-exp-inline-src-blocks))
(add-to-list 'org-export-interblocks '(lob org-babel-exp-lob-one-liners))
(add-hook 'org-export-blocks-postblock-hook 'org-exp-res/src-name-cleanup)

(org-export-blocks-add-block '(src org-babel-exp-src-blocks nil))

(defvar org-babel-function-def-export-keyword "function"
  "When exporting a source block function, this keyword will
appear in the exported version in the place of source name
line. A source block is considered to be a source block function
if the source name is present and is followed by a parenthesized
argument list. The parentheses may be empty or contain
whitespace. An example is the following which generates n random
(uniform) numbers.

#+source: rand(n)
#+begin_src R
  runif(n)
#+end_src
")

(defvar org-babel-function-def-export-indent 4
  "When exporting a source block function, the block contents
will be indented by this many characters. See
`org-babel-function-def-export-name' for the definition of a
source block function.")

(defvar obe-marker nil)
(defvar org-current-export-file)
(defvar org-babel-lob-one-liner-regexp)
(defvar org-babel-ref-split-regexp)
(declare-function org-babel-get-src-block-info "ob" (&optional header-vars-only))
(declare-function org-babel-lob-get-info "ob-lob" ())
(declare-function org-babel-ref-literal "ob-ref" (ref))

(defun org-babel-exp-src-blocks (body &rest headers)
  "Process src block for export.  Depending on the 'export'
headers argument in replace the source code block with...

both ---- display the code and the results

code ---- the default, display the code inside the block but do
          not process

results - just like none only the block is run on export ensuring
          that it's results are present in the org-mode buffer

none ----- do not display either code or results upon export"
  (interactive)
  (message "org-babel-exp processing...")
  (when (member (nth 0 headers) org-babel-interpreters)
    (save-excursion
      (goto-char (match-beginning 0))
      (let* ((info (org-babel-get-src-block-info))
	     (params (nth 2 info)))
	;; expand noweb references in the original file
	(setf (nth 1 info)
	      (if (and (cdr (assoc :noweb params))
		       (string= "yes" (cdr (assoc :noweb params))))
		  (org-babel-expand-noweb-references
		   info (get-file-buffer org-current-export-file))
		(nth 1 info)))
	(org-babel-exp-do-export info 'block)))))

(defun org-babel-exp-inline-src-blocks (start end)
  "Process inline src blocks between START and END for export.
See `org-babel-exp-src-blocks' for export options, currently the
options and are taken from `org-babel-defualt-inline-header-args'."
  (interactive)
  (save-excursion
    (goto-char start)
    (while (and (< (point) end)
                (re-search-forward org-babel-inline-src-block-regexp end t))
      (let* ((info (save-match-data (org-babel-parse-inline-src-block-match)))
	     (params (nth 2 info))
	     (replacement
	      (save-match-data
		(if (org-babel-in-example-or-verbatim)
		    (buffer-substring (match-beginning 0) (match-end 0))
		  ;; expand noweb references in the original file
		  (setf (nth 1 info)
			(if (and (cdr (assoc :noweb params))
				 (string= "yes" (cdr (assoc :noweb params))))
			    (org-babel-expand-noweb-references
			     info (get-file-buffer org-current-export-file))
			  (nth 1 info)))
		  (org-babel-exp-do-export info 'inline)))))
	(setq end (+ end (- (length replacement) (length (match-string 1)))))
	(replace-match replacement t t nil 1)))))

(defun org-exp-res/src-name-cleanup ()
  "Cleanup leftover #+results and #+srcname lines as part of the
org export cycle.  This should only be called after all block
processing has taken place."
  (interactive)
  (save-excursion
    (goto-char (point-min))
    (while (org-re-search-forward-unprotected
	    (concat
	     "\\("org-babel-source-name-regexp"\\|"org-babel-result-regexp"\\)")
	    nil t)
      (delete-region
       (progn (beginning-of-line) (point))
       (progn (end-of-line) (+ 1 (point)))))))

(defun org-babel-in-example-or-verbatim ()
  "Return true if the point is currently in an escaped portion of
an org-mode buffer code which should be treated as normal
org-mode text."
  (or (org-in-indented-comment-line) 
      (save-excursion
	(save-match-data
	  (goto-char (point-at-bol))
	  (looking-at "[ \t]*:[ \t]")))
      (org-in-regexps-block-p "^[ \t]*#\\+begin_src" "^[ \t]*#\\+end_src")))

(defun org-babel-exp-lob-one-liners (start end)
  "Process #+lob (Library of Babel) calls between START and END for export.
See `org-babel-exp-src-blocks' for export options. Currently the
options are taken from `org-babel-default-header-args'."
  (interactive)
  (let (replacement)
    (save-excursion
      (goto-char start)
      (while (and (< (point) end)
		  (re-search-forward org-babel-lob-one-liner-regexp nil t))
	(setq replacement
	      (let ((lob-info (org-babel-lob-get-info)))
		(save-match-data
		  (org-babel-exp-do-export
		   (list "emacs-lisp" "results"
			 (org-babel-merge-params
			  org-babel-default-header-args
			  (org-babel-parse-header-arguments
			   (org-babel-clean-text-properties
			    (concat ":var results="
				    (mapconcat #'identity
					       (butlast lob-info) " ")))))
			 (car (last lob-info)))
		   'lob))))
	(setq end (+ end (- (length replacement) (length (match-string 0)))))
	(replace-match replacement t t)))))

(defun org-babel-exp-do-export (info type)
  "Return a string containing the exported content of the current
code block respecting the value of the :exports header argument."
  (flet ((silently () (let ((session (cdr (assoc :session (nth 2 info)))))
			(when (and session
				   (not (equal "none" session))
				   (not (assoc :noeval (nth 2 info))))
			  (org-babel-exp-results info type 'silent))))
	 (clean () (org-babel-remove-result info)))
    (case (intern (or (cdr (assoc :exports (nth 2 info))) "code"))
      ('none (silently) (clean) "")
      ('code (silently) (clean) (org-babel-exp-code info type))
      ('results (org-babel-exp-results info type))
      ('both (concat (org-babel-exp-code info type)
		     "\n\n"
		     (org-babel-exp-results info type))))))

(defvar backend)
(defun org-babel-exp-code (info type)
  "Return the code the current code block in a manner suitable
for exportation by org-mode.  This function is called by
`org-babel-exp-do-export'.  The code block will not be
evaluated."
  (let ((lang (nth 0 info))
        (body (nth 1 info))
        (switches (nth 3 info))
        (name (nth 4 info))
        (args (mapcar
	       #'cdr
	       (org-remove-if-not (lambda (el) (eq :var (car el))) (nth 2 info)))))
    (case type
      ('inline (format "=%s=" body))
      ('block
          (let ((str
		 (format "#+BEGIN_SRC %s %s\n%s%s#+END_SRC\n" lang switches body
			 (if (and body (string-match "\n$" body))
			     "" "\n"))))
            (when name
	      (add-text-properties
	       0 (length str)
	       (list 'org-caption
		     (format "%s(%s)"
			     name
			     (mapconcat #'identity args ", ")))
	       str))
	    str))
      ('lob
       (let ((call-line (and (string-match "results=" (car args))
                             (substring (car args) (match-end 0)))))
         (cond
          ((eq backend 'html)
           (format "\n#+HTML: <label class=\"org-src-name\">%s</label>\n"
		   call-line))
          ((format ": %s\n" call-line))))))))

(defun org-babel-exp-results (info type &optional silent)
  "Return the results of the current code block in a manner
suitable for exportation by org-mode.  This function is called by
`org-babel-exp-do-export'.  The code block will be evaluated.
Optional argument SILENT can be used to inhibit insertion of
results into the buffer."
  (let ((lang (nth 0 info))
	(body (nth 1 info))
	(params
	 ;; lets ensure that we lookup references in the original file
	 (mapcar
	  (lambda (pair)
	    (if (and org-current-export-file
		     (eq (car pair) :var)
		     (string-match org-babel-ref-split-regexp (cdr pair))
		     (null (org-babel-ref-literal (match-string 2 (cdr pair)))))
		`(:var . ,(concat (match-string 1 (cdr pair))
				  "=" org-current-export-file
				  ":" (match-string 2 (cdr pair))))
	      pair))
	  (nth 2 info))))
    (case type
      ('inline
        (let ((raw (org-babel-execute-src-block
                    nil info '((:results . "silent"))))
              (result-params (split-string (cdr (assoc :results params)))))
          (unless silent
	    (cond ;; respect the value of the :results header argument
	     ((member "file" result-params)
	      (org-babel-result-to-file raw))
	     ((or (member "raw" result-params) (member "org" result-params))
	      (format "%s" raw))
	     ((member "code" result-params)
	      (format "src_%s{%s}" lang raw))
	     (t
	      (if (stringp raw)
		  (if (= 0 (length raw)) "=(no results)="
		    (format "%s" raw))
		(format "%S" raw)))))))
      ('block
          (org-babel-execute-src-block
	   nil info (org-babel-merge-params
		     params `((:results . ,(if silent "silent" "replace")))))
        "")
      ('lob
       (save-excursion
	 (re-search-backward org-babel-lob-one-liner-regexp nil t)
	 (org-babel-execute-src-block
	  nil info (org-babel-merge-params
		    params `((:results . ,(if silent "silent" "replace")))))
	 "")))))

(provide 'ob-exp)
;;; ob-exp.el ends here
