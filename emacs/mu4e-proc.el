;; mu4e-proc.el -- part of mu4e, the mu mail user agent
;;
;; Copyright (C) 2011-2012 Dirk-Jan C. Binnema

;; Author: Dirk-Jan C. Binnema <djcb@djcbsoftware.nl>
;; Maintainer: Dirk-Jan C. Binnema <djcb@djcbsoftware.nl>

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

;;; Code:
(require 'mu4e-vars)
(require 'mu4e-utils)
(require 'mu4e-meta)


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; internal vars

(defvar mu4e~proc-buf nil "Buffer for results data.")
(defconst mu4e~proc-name "*mu4e-proc*" "Name of the server process, buffer.")
(defvar mu4e~proc-process nil "The mu-server process")


;; dealing with the length cookie that precedes expressions
(defconst mu4e~cookie-pre "\376"
  "Each expression we get from the backend (mu server) starts with
   a length cookie:
   <`mu4e~cookie-pre'><length-in-hex><`mu4e~cookie-post'>.")
(defconst mu4e~cookie-post "\377"
    "Each expression we get from the backend (mu server) starts with
   a length cookie:
   <`mu4e~cookie-pre'><length-in-hex><`mu4e~cookie-post'>.")
(defconst mu4e~cookie-matcher-rx
  (concat mu4e~cookie-pre "\\([[:xdigit:]]+\\)" mu4e~cookie-post)
  "Regular expression matching the length cookie. Match 1 will be
the length (in hex).")
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;


(defun mu4e~proc-start ()
  "Start the mu server process."
  (unless (file-executable-p mu4e-mu-binary)
    (error (format "`mu4e-mu-binary' (%S) not found" mu4e-mu-binary)))
  (let* ((process-connection-type nil) ;; use a pipe
	  (args '("server"))
	  (args (append args (when mu4e-mu-home
			       (list (concat "--muhome=" mu4e-mu-home))))))
    (setq mu4e~proc-buf "")
    (setq mu4e~proc-process (apply 'start-process
			 mu4e~proc-name mu4e~proc-name
		       mu4e-mu-binary args))
    ;; register a function for (:info ...) sexps
    (when mu4e~proc-process
      (set-process-query-on-exit-flag mu4e~proc-process nil)
      (set-process-coding-system mu4e~proc-process 'binary 'utf-8-unix)
      (set-process-filter mu4e~proc-process 'mu4e~proc-filter)
      (set-process-sentinel mu4e~proc-process 'mu4e~proc-sentinel))))

(defun mu4e~proc-kill ()
  "Kill the mu server process."
  (let* ((buf (get-buffer mu4e~proc-name))
	  (proc (and buf (get-buffer-process buf))))
    (when proc
      (let ((delete-exited-processes t))
	;; the mu server signal handler will make it quit after 'quit'
	(mu4e~proc-send-command "quit"))
	;; try sending SIGINT (C-c) to process, so it can exit gracefully
      (ignore-errors
	(signal-process proc 'SIGINT))))
  (setq
    mu4e~proc-process nil
    mu4e~proc-buf nil))

(defun mu4e~proc-is-running ()
  "Whether the mu process is running."
  (and mu4e~proc-process (eq (process-status mu4e~proc-process) 'run)))


(defun mu4e~proc-eat-sexp-from-buf ()
  "'Eat' the next s-expression from `mu4e~proc-buf'. Note: this is a string,
not an emacs-buffer. `mu4e~proc-buf gets its contents from the
mu-servers in the following form:
   <`mu4e~cookie-pre'><length-in-hex><`mu4e~cookie-post'>

Function returns this sexp, or nil if there was
none. `mu4e~proc-buf' is updated as well, with all processed sexp
data removed."
  (when mu4e~proc-buf
    ;; mu4e~cookie-matcher-rx:
    ;;  (concat mu4e~cookie-pre "\\([[:xdigit:]]+\\)]" mu4e~cookie-post)
    (let* ((b (string-match mu4e~cookie-matcher-rx mu4e~proc-buf))
	    (sexp-len
	      (when b (string-to-number (match-string 1 mu4e~proc-buf) 16))))
      ;; does mu4e~proc-buf contain the full sexp?
      (when (and b (>= (length mu4e~proc-buf) (+ sexp-len (match-end 0))))
	;; clear-up start
	(setq mu4e~proc-buf (substring mu4e~proc-buf (match-end 0)))
	;; note: we read the input in binary mode -- here, we take the part that
	;; is the sexp, and convert that to utf-8, before we interpret it.
	(let ((objcons
		(ignore-errors ;; note: this may fail if we killed the process
		  ;; in the middle
		  (read-from-string
		    (decode-coding-string (substring mu4e~proc-buf 0 sexp-len)
		      'utf-8 t)))))
	  (when objcons
	    (setq mu4e~proc-buf (substring mu4e~proc-buf sexp-len))
	    (car objcons)))))))


(defun mu4e~proc-filter (proc str)
  "A process-filter for the 'mu server' output; it accumulates the
strings into valid sexps by checking of the ';;eox' end-of-sexp
marker, and then evaluating them.

The server output is as follows:

   1. an error
      (:error 2 :message \"unknown command\")
      ;; eox
   => this will be passed to `mu4e-error-func'.

   2a. a message sexp looks something like:
 \(
  :docid 1585
  :from ((\"Donald Duck\" . \"donald@example.com\"))
  :to ((\"Mickey Mouse\" . \"mickey@example.com\"))
  :subject \"Wicked stuff\"
  :date (20023 26572 0)
  :size 15165
  :references (\"200208121222.g7CCMdb80690@msg.id\")
  :in-reply-to \"200208121222.g7CCMdb80690@msg.id\"
  :message-id \"foobar32423847ef23@pluto.net\"
  :maildir: \"/archive\"
  :path \"/home/mickey/Maildir/inbox/cur/1312254065_3.32282.pluto,4cd5bd4e9:2,\"
  :priority high
  :flags (new unread)
  :attachments ((2 \"hello.jpg\" \"image/jpeg\") (3 \"laah.mp3\" \"audio/mp3\"))
  :body-txt \" <message body>\"
\)
;; eox
   => this will be passed to `mu4e-header-func'.

  2b. After the list of message sexps has been returned (see 2a.),
  we'll receive a sexp that looks like
  (:found <n>) with n the number of messages found. The <n> will be
  passed to `mu4e-found-func'.

  3. a view looks like:
  (:view <msg-sexp>)
  => the <msg-sexp> (see 2.) will be passed to `mu4e-view-func'.

  4. a database update looks like:
  (:update <msg-sexp> :move <nil-or-t>)

   => the <msg-sexp> (see 2.) will be passed to
   `mu4e-update-func', :move tells us whether this is a move to
   another maildir, or merely a flag change.

  5. a remove looks like:
  (:remove <docid>)
  => the docid will be passed to `mu4e-remove-func'

  6. a compose looks like:
  (:compose <reply|forward|edit|new> [:original<msg-sexp>] [:include <attach>])
  `mu4e-compose-func'."
  (mu4e-log 'misc "* Received %d byte(s)" (length str))
  (setq mu4e~proc-buf (concat mu4e~proc-buf str)) ;; update our buffer
  (let ((sexp (mu4e~proc-eat-sexp-from-buf)))
    (while sexp
      (mu4e-log 'from-server "%S" sexp)
      (cond
	;; a header plist can be recognized by the existence of a :date field
	((plist-get sexp :date)
	  (funcall mu4e-header-func sexp))

	;; the found sexp, we receive after getting all the headers
	((plist-get sexp :found)
	  (funcall mu4e-found-func (plist-get sexp :found)))

	;; viewing a specific message
	((plist-get sexp :view)
	  (funcall mu4e-view-func (plist-get sexp :view)))

	;; receive an erase message
	((plist-get sexp :erase)
	  (funcall mu4e-erase-func))

	;; receive a :sent message
	((plist-get sexp :sent)
	  (funcall mu4e-sent-func
	    (plist-get sexp :docid)
	    (plist-get sexp :path)))

	;; receive a pong message
	((plist-get sexp :pong)
	  (funcall mu4e-pong-func
	    (plist-get sexp :version) (plist-get sexp :doccount)))

	;; something got moved/flags changed
	((plist-get sexp :update)
	  (funcall mu4e-update-func
	    (plist-get sexp :update) (plist-get sexp :move)))

	;; a message got removed
	((plist-get sexp :remove)
	  (funcall mu4e-remove-func (plist-get sexp :remove)))

	;; start composing a new message
	((plist-get sexp :compose)
	  (funcall mu4e-compose-func
	    (plist-get sexp :compose)
	    (plist-get sexp :original)
	    (plist-get sexp :include)))

	;; do something with a temporary file
	((plist-get sexp :temp)
	  (funcall mu4e-temp-func
	    (plist-get sexp :temp)   ;; name of the temp file
	    (plist-get sexp :what)   ;; what to do with it (pipe|emacs|open-with...)
	    (plist-get sexp :param)));; parameter for the action

	;; get some info
	((plist-get sexp :info)
	  (funcall mu4e-info-func sexp))

	;; receive an error
	((plist-get sexp :error)
	  (funcall mu4e-error-func
	    (plist-get sexp :error)
	    (plist-get sexp :message)))

	(t (mu4e-message "Unexpected data from server [%S]" sexp)))

      (setq sexp (mu4e~proc-eat-sexp-from-buf)))))


;; error codes are defined in src/mu-util.h
;;(defconst mu4e-xapian-empty 19 "Error code: xapian is empty/non-existent")

(defun mu4e~proc-sentinel (proc msg)
  "Function that will be called when the mu-server process
terminates."
  (let ((status (process-status proc)) (code (process-exit-status proc)))
    (setq mu4e~proc-process nil)
    (setq mu4e~proc-buf "") ;; clear any half-received sexps
    (cond
      ((eq status 'signal)
	(cond
	  ((eq code 9) (message nil))
	    ;;(message "the mu server process has been stopped"))
	  (t (mu4e-message (format "mu server process received signal %d" code)))))
      ((eq status 'exit)
	(cond
	  ((eq code 0)
	    (message nil)) ;; don't do anything
	  ((eq code 11)
	    (mu4e-message "Database is locked by another process"))
	  ((eq code 19)
	    (mu4e-message "Database empty or non-existent; try indexing some messages"))
	  (t (mu4e-message "mu server process ended with exit code %d" code))))
      (t
	(mu4e-message "Something bad happened to the mu server process")))))

(defun mu4e~proc-send-command (frm &rest args)
  "Send as command to the mu server process; start the process if needed."
  (unless (mu4e~proc-is-running)
    (mu4e~proc-start))
  (let ((cmd (apply 'format frm args)))
    (mu4e-log 'to-server "%s" cmd)
    (process-send-string mu4e~proc-process (concat cmd "\n"))))


(defun mu4e--docid-msgid-param (docid-or-msgid)
  "Construct a backend parameter based on DOCID-OR-MSGID."
  (format
    (if (stringp docid-or-msgid)
      "msgid:\"%s\""
      "docid:%d")
    docid-or-msgid))

(defun mu4e~proc-remove (docid)
  "Remove message identified by docid.
 The results are reporter through either (:update ... ) or (:error
) sexp, which are handled my `mu4e-error-func', respectively."
  (mu4e~proc-send-command "remove docid:%d" docid))

(defun mu4e~proc-find (query &optional maxnum)
  "Start a database query for QUERY, (optionally) getting up to
MAXNUM results. For each result found, a function is called,
depending on the kind of result. The variables `mu4e-error-func'
contain the function that will be called for, resp., a
message (header row) or an error."
  (mu4e~proc-send-command
    "find query:\"%s\"%s" query
    (if maxnum (format " maxnum:%d" maxnum) "")))

(defun mu4e~proc-move (docid-or-msgid &optional maildir flags)
  "Move message identified by DOCID-OR-MSGID. At least one of
  MAILDIR and FLAGS should be specified. Note, even if MAILDIR is
  nil, this is still a move, since a change in flags still implies
  a change in message filename.

MAILDIR (), optionally
setting FLAGS (keyword argument :flags).  optionally setting FLAGS
in the process. If MAILDIR is nil, message will be moved within the
same maildir.

MAILDIR must be a maildir, that is, the part _without_ cur/ or new/
or the root-maildir-prefix. E.g. \"/archive\". This directory must
already exist.

The FLAGS parameter can have the following forms:
  1. a list of flags such as '(passed replied seen)
  2. a string containing the one-char versions of the flags, e.g. \"PRS\"
  3. a delta-string specifying the changes with +/- and the one-char flags,
     e.g. \"+S-N\" to set Seen and remove New.

The flags are any of `deleted', `flagged', `new', `passed', `replied' `seen' or
`trashed', or the corresponding \"DFNPRST\" as defined in [1]. See
`mu4e-string-to-flags' and `mu4e-flags-to-string'.
The server reports the results for the operation through
`mu4e-update-func'.
The results are reported through either (:update ... )
or (:error ) sexp, which are handled my `mu4e-update-func' and
`mu4e-error-func', respectively."
  (unless (or maildir flags)
    (error "At least one of maildir and flags must be specified"))
  (let* ((idparam (mu4e--docid-msgid-param docid-or-msgid))
	  (flagstr
	    (when flags
	      (concat " flags:"
		(if (stringp flags) flags (mu4e-flags-to-string flags)))))
	  (path
	    (when maildir
	      (format " maildir:\"%s\"" maildir))))
    (mu4e~proc-send-command "move %s %s %s"
      idparam (or flagstr "") (or path ""))))


(defun mu4e~proc-index (path)
  "Update the message database for filesystem PATH, which should
point to some maildir directory structure."
  (mu4e~proc-send-command "index path:\"%s\"" path))

(defun mu4e~proc-add (path maildir)
  "Add the message at PATH to the database, with MAILDIR set to the
maildir this message resides in, e.g. '/drafts'; if this works, we
will receive (:info add :path <path> :docid <docid>)."
  (mu4e~proc-send-command "add path:\"%s\" maildir:\"%s\""
    path maildir))

(defun mu4e~proc-sent (path maildir)
  "Add the message at PATH to the database, with MAILDIR set to the
maildir this message resides in, e.g. '/drafts'.

 if this works, we will receive (:info add :path <path> :docid
<docid> :fcc <path>)."
  (mu4e~proc-send-command "sent path:\"%s\" maildir:\"%s\""
    path maildir))

(defun mu4e~proc-compose (type &optional docid)
  "Start composing a message of certain TYPE (a symbol, either
`forward', `reply', `edit' or `new', based on an original
message (ie, replying to, forwarding, editing) with DOCID or nil
for type `new'.

  The result will be delivered to the function registered as
`mu4e-compose-func'."
  (unless (member type '(forward reply edit new))
    (error "Unsupported compose-type %S" type))
  (unless (eq (null docid) (eq type 'new))
    (error "`new' implies docid not-nil, and vice-versa"))
  (mu4e~proc-send-command "compose type:%s docid:%d"
    (symbol-name type) docid))

(defun mu4e~proc-mkdir (path)
  "Create a new maildir-directory at filesystem PATH."
  (mu4e~proc-send-command "mkdir path:\"%s\"" path))

(defun mu4e~proc-extract (action docid partidx &optional path what param)
  "Extract an attachment with index PARTIDX from message with DOCID
and perform ACTION on it (as symbol, either `save', `open', `temp') which
mean:
  * save: save the part to PARAM1 (a path) (non-optional for save)
  * open: open the part with the default application registered for doing so
  * temp: save to a temporary file, then respond with
             (:temp <path> :what <what> :param <param>)."
  (let ((cmd
	  (concat "extract "
	    (case action
	      (save
		(format "action:save docid:%d index:%d path:\"%s\""
		      docid partidx path))
	      (open (format "action:open docid:%d index:%d" docid partidx))
	      (temp
		(format "action:temp docid:%d index:%d what:%s param:\"%s\""
		  docid partidx what param))
	      (otherwise (error "Unsupported action %S" action))))))
    (mu4e~proc-send-command cmd)))


(defun mu4e~proc-ping ()
  "Sends a ping to the mu server, expecting a (:pong ...) in
response."
  (mu4e~proc-send-command "ping"))

(defun mu4e~proc-view (docid-or-msgid)
  "Get one particular message based on its DOCID-OR-MSGID (keyword
argument). The result will be delivered to the function registered
as `mu4e-message-func'."
  (mu4e~proc-send-command "view %s"
    (mu4e--docid-msgid-param docid-or-msgid)))

(provide 'mu4e-proc)

;; End of mu4e-proc.el
