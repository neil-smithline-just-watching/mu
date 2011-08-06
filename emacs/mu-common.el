;;; mu-common.el -- part of mu
;;
;; Copyright (C) 2011 Dirk-Jan C. Binnema

;; Author: Dirk-Jan C. Binnema <djcb@djcbsoftware.nl>
;; Maintainer: Dirk-Jan C. Binnema <djcb@djcbsoftware.nl>
;; Keywords: email
;; Version: 0.0

;; This file is not part of GNU Emacs.
;;
;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; mu message has functions to display a message

;;; Code:

(require 'cl)

(defvar mu-binary "/home/djcb/src/mu/src/mu" "name/path of the mu executable")
(defvar mu-muile-binary "/home/djcb/src/mu/toys/muile/muile"
  "name/path of the muile executable")
(defvar mu-home nil
  "path where mu stores it's data or nil for the defaults (typically, ~/.mu)")

(defvar mu-date-format-short "%x %X" "date format (in strftime(2)
notation) e.g. for mail headers")

(defvar mu-date-format-long "%c" "date format (in strftime(2)
notation) for the mail view and in replied/forwarded message quotations")

(defvar mu-folder-draft "/home/djcb/Maildir/")

(defface mu-date-face    '((t (:foreground "#8c5353"))) "") 
(defface mu-subject-face '((t (:foreground "#dfaf8f"))) "") 
(defface mu-from-face    '((t (:foreground "#7f9f7f"))) "") 
(defface mu-to-face      '((t (:foreground "#7f6655"))) "")
(defface mu-cc-face      '((t (:foreground "#7f6666"))) "")
(defface mu-bcc-face     '((t (:foreground "#7f6677"))) "") 
(defface mu-body-face    '((t (:foreground "#8cd0d3"))) "") 
(defface mu-header-face  '((t (:foreground "#7f9f7f"))) "") 
(defface mu-size-face    '((t (:foreground "#889f7f"))) "") 
(defface mu-flag-face    '((t (:foreground "#dc56cc"))) "") 
(defface mu-path-face    '((t (:foreground "#dc56cc"))) "") 

(defface mu-unread-face    '((t (:bold t))) "") 
(defface mu-face         '((t (:foreground "Gray" :italic t))) "")

(defvar mu-own-address "djcb" "regexp matching my own address")

;;; internal stuff
(defvar mu-parent-buffer nil "the parent buffer for a
buffer (buffer-local), i.e., the buffer we'll return to when this
buffer is killed")


(defun mu-binary-version ()
  "get the version of the mu binary"
  (let ((cmd (concat mu-binary
	       " --version | head -1 | sed 's/.*version //'")))
    (substring (shell-command-to-string cmd) 0 -1)))

(defun mu-inspect (path)
  "inspect message in a guile environment"
  (let ((cmd (concat mu-muile-binary " --msg='" path "'")))
    (ansi-term cmd "*mu-inspect")))

;; (defalias mu-find    mu-headers-find)
;; (defalias mu-display mu-message-display)

(defun mu-str (str)
  "return STR propertized as a mu string (for info, warnings
etc.)"
  (propertize str 'face 'mu-face 'intangible t))

(setq mu-headers-fields
  '(
     (:date          .  20)
     (:flags         .   4)
     (:from-or-to    .  22)
     (:size          .   8)
     (:subject       .  40)))
(setq mu-headers-date-format "%x %X")

(setq mu-header-fields
  '( :from
     :to
     :subject
     :date
     :path))

(setq mu-own-address-regexp "djcb\\|diggler\\|bulkmeel")

(defvar mu-maildir nil "our maildir")
(defvar mu-folder nil "our list of special folders for jumping,
moving")


(defvar mu-maildir nil "location of your maildir, typically ~/Maildir")
(defvar mu-inbox-folder  nil  "location of your inbox folder")
(defvar mu-outbox-folder nil "location of your outbox folder")
(defvar mu-sent-folder   nil "location of your sent folder")
(defvar mu-trash-folder  nil "location of your trash-folder folder")

(setq
  mu-maildir       "/home/djcb/Maildir"
  mu-inbox-folder  "/inbox"
  mu-outbox-folder "/outbox"
  mu-sent-folder   "/sent"
  mu-trash-folder  "/trash")

(defvar mu-quick-folders nil)

(setq mu-quick-folders
  '("/archive" "/bulkarchive" "/todo"))

(defun mu-ask-maildir (prompt &optional fullpath)
  "ask user with PROMPT for a maildir name, if fullpath is
non-nill, return the fulpath (ie, mu-maildir prepended to the
maildir"
  (interactive)
  (let*
    ((showfolders
       (delete-dups
  	 (append (list mu-inbox-folder mu-sent-folder) mu-quick-folders)))
      (chosen (ido-completing-read prompt showfolders)))
    (concat (if fullpath mu-maildir "") chosen)))

(defun mu-ask-key (prompt)
  "Get a char from user, only accepting characters marked with [x] in prompt,
e.g. 'Reply to [a]ll or [s]ender only; returns the character chosen"
  (let ((match 0) (kars '()))
    (while match
      (setq match (string-match "\\[\\(.\\)\\]" prompt match))
      (when match
	(setq kars (cons (match-string 1 prompt) kars))
	(setq match (+ 1 match))))
    (let ((kar)
	   (prompt (replace-regexp-in-string 
		     "\\[\\(.\\)\\]"
		     (lambda(s)
		       (concat "[" (propertize (substring s 1 -1) 'face 'highlight) "]"))
		     prompt)))
      (while (not kar)
	(setq kar (read-char-exclusive prompt))
	(unless (member (string kar) kars)
	  (setq kar nil)))
      kar)))


;; both in mu-find.el and mu-view.el we have the path as a text property; in the
;; latter case we could have use a buffer-local variable, but using a
;; text-property makes this function work for both
(defun mu-get-path ()
  "get the path (a string) of the message at point or nil if it
is not found; this works both for the header list and when
viewing a message"
  (let ((path (get-text-property (point) 'path)))
    (unless path (message "No message at point"))
    path))


;;  The message sexp looks something like:
;; (
;; 	:from (("Donald Duck" . "donald@example.com"))
;; 	:to (("Mickey Mouse" . "mickey@example.com"))
;; 	:subject "Wicked stuff"
;; 	:date (20023 26572 0)
;; 	:size 15165
;; 	:msgid "foobar32423847ef23@pluto.net"
;; 	:path "/home/mickey/Maildir/inbox/cur/1312254065_3.32282.pluto,4cd5bd4e9:2,"
;; 	:priority high
;; 	:flags (new unread)
;; 	:body-txt " <message body>"
;; )
(defun mu-get-message (path)
  "use 'mu view --format=sexp' to get the message at PATH in the
form of an s-expression; parse this s-expression and return the
Lisp data as a plist.  Returns nil in case of error"
  (if (not (file-readable-p path))
    (progn (message "Message is not readable") nil)
    (let* ((cmd (concat mu-binary " view --format=sexp " path))
	    (str (shell-command-to-string cmd))
	    (msglst (read-from-string str)))
      (if msglst
	(car msglst)
	(progn (message "Failed to parse message") nil)))))


(defun mu-quit-buffer ()
  "kill this buffer, and switch to it's parentbuf if it is alive"
  (interactive)  
  (let ((parentbuf mu-parent-buffer))
    (kill-buffer)
    (when (and parentbuf (buffer-live-p parentbuf))
      (switch-to-buffer parentbuf))))

(defun mu-get-new-buffer (bufname)
  "return a new buffer BUFNAME; if such already exists, kill the
old one first"
  (when (get-buffer bufname)
    (kill-buffer bufname))
  (get-buffer-create bufname))

(defun mu-log (frm &rest args)
  (with-current-buffer (get-buffer-create "*mu-log*")
    (goto-char (point-max))
    (insert (apply 'format
	      (concat
		(format-time-string "%x %X " (current-time))
		frm "\n") args))))


(provide 'mu-common)