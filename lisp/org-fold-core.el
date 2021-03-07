;;; org-fold-core.el --- Folding buffer text -*- lexical-binding: t; -*-
;;
;; Copyright (C) 2020-2020 Free Software Foundation, Inc.
;;
;; Author: Ihor Radchenko <yantar92 at gmail dot com>
;; Keywords: folding, invisible text
;; Homepage: https://orgmode.org
;;
;; This file is part of GNU Emacs.
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
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;;; Commentary:

;; This file contains code handling temporary invisibility (folding
;; and unfolding) of text in buffers.

;; The file implements the following functionality:
;;
;; - Folding/unfolding regions of text
;; - Searching and examining boundaries of folded text
;; - Interactive searching in folded text (via isearch)
;; - Handling edits in folded text
;; - Killing/yanking (copying/pasting) of the folded text

;;; Folding/unfolding regions of text

;; User can temporarily hide/reveal (fold/unfold) arbitrary regions or
;; text.  The folds can be nested.

;; Internally, nested folds are marked with different folding specs
;; Overlapping folds marked with the same folding spec are
;; automatically merged, while folds with different folding specs can
;; coexist and be folded/unfolded independently.

;; When multiple folding specs are applied to the same region of text,
;; text visibility is decided according to the folding spec with
;; topmost priority.

;; By default, we define two types of folding specs:
;; - 'org-fold-visible :: the folded text is not hidden
;; - 'org-fold-hidden  :: the folded text is completely hidden
;;
;; The 'org-fold-visible spec has highest priority allowing parts of
;; text folded with 'org-fold-hidden to be shown unconditionally.

;; Consider the following org-mode link:
;; [[file:/path/to/file/file.ext][description]]
;; Only the word "description" is normally visible in this link.
;; 
;; The way this partial visibility is achieved is combining the two
;; folding specs.  The whole link is folded using 'org-fold-hidden
;; folding spec, but the visible part is additionally folded using
;; 'org-fold-visible:
;;
;; <begin org-fold-hidden>[[file:/path/to/file/file.ext][<begin org-fold-visible>description<end org-fold-visible>]]<end org-fold-hidden>
;; 
;; Because 'org-fold-visible hsa higher priority than
;; 'org-fold-hidden, it suppresses all the lower-priority specs and
;; thus reveal the description part of the link.

;; If necessary, one can add or remove folding specs using
;; `org-fold-add-folding-spec' and `org-fold-remove-folding-spec'.

;; FIXME: This could be automatically detected.
;; Because of details of implementation of the folding, it is not
;; recommended to set text visibility in buffer directly by
;; setting 'invisible text property to anything other than t.  While
;; this should usually work just fine, normal folding can be broken if
;; one sets 'invisible text property to a value not listed in
;; `buffer-invisibility-spec'.

;;; Searching and examining boundaries of folded text

;; It is possible to examine folding specs (there may be several) of
;; text at point or search for regions with the same folding spec.

;; If one wants to search invisible text without using functions
;; defined below, it is important to keep in mind that 'invisible text
;; property in org buffers may have multiple possible values (not just nil
;; and t). Hence, (next-single-char-property-change pos 'invisible) is
;; not guarantied to return the boundary of invisible/visible text.

;;; Interactive searching in folded text (via isearch)

;; The library provides a way to control if the folded text can be
;; searchable using isearch.  If the text is searchable, it is also
;; possible to control to unfold it temporarily during interactive
;; isearch session.

;; The isearch behaviour is controlled per- folding spec basis by
;; setting `isearch-open' and `isearch-ignore' folding spec
;; properties.

;;; Handling edits inside folded text

;; Accidental user edits inside invisible folded text may easily mess
;; up buffer.  Here, we provide a framework to catch such edits and
;; throw error if necessary.  This framework is used, for example, by
;; `org-self-insert-command' and `org-delete-backward-char', See
;; `org-fold-catch-invisible-edits' for available customisation.

;; Some edits inside folded text are not accidental.  In org-mode,
;; setting scheduled time, deadlines, properties, etc often involve
;; adding or changing text insided folded headlines or drawers.
;; Normally, such edits do not reveal the folded text.  However, the
;; edited text is revealed when document structure is disturbed by
;; edits.  Sensitive structural elements of the buffer should be
;; defined using `org-fold-define-element'.

;; Another common situation is appending/prepending text at the edges
;; of a folded region.  The added text can be added or not added to
;; the fold according to `rear-sticky' and `front-stiky' folding spec
;; properties.

;;; Code:

(require 'org-macs)

(declare-function isearch-filter-visible "isearch" (beg end))

;;; Customization

(defvar-local org-fold-core-isearch-open-function #'org-fold-core--isearch-reveal
  "Function used to reveal hidden text found by isearch.
The function is called with a single argument - point where text is to
be revealed.")

;;; Core functionality

;;;; Buffer-local folding specs

(defvar-local org-fold-core--specs '((org-fold-visible
		         (:visible . t)
                         (:alias . (visible)))
                        (org-fold-hidden
			 (:ellipsis . "...")
                         (:isearch-open . t)
                         (:alias . (hidden))))
  "Folding specs defined in current buffer.

Each spec is a list (SPEC-SYMBOL SPEC-PROPERTIES).
SPEC-SYMBOL is the symbol respresenting the folding spec.
SPEC-PROPERTIES is an alist defining folding spec properties.

If a text region is folded using multiple specs, only the folding spec
listed earlier is used.

The following properties are known:
- :ellipsis         :: must be nil or string to show when text is folded
                      using this spec.
- :isearch-ignore   :: non-nil means that folded text is not searchable
                      using isearch.
- :isearch-open     :: non-nil means that isearch can reveal text hidden
                      using this spec.  This property does nothing
                      when 'isearch-ignore property is non-nil.
- :front-sticky     :: non-nil means that text prepended to the folded text
                      is automatically folded.
- :rear-sticky      :: non-nil means that text appended to the folded text
                      is folded.
- :visible          :: non-nil means that folding spec visibility is not
                       managed.  Instead, visibility settings in
                       `buffer-invisibility-spec' will be used as is.
                       Note that changing this property from nil to t may
                       clear the setting in `buffer-invisibility-spec'.
- :alias            :: a list of aliases for the SPEC-SYMBOL.
- :fragile          :: Must be a function accepting a two arguments.
                       Non-nil means that changes in region may cause
                       the region to be revealed.  The region is
                       revealed after changes if the function returns
                       non-nil.
                       The function called after changes are made with
                       two arguments: cons (beg . end) representing the
                       folded region and spec.")

(defvar-local org-fold-core-extend-changed-region-functions nil
  "Special hook run just before handling changes in buffer.

This is used to account changes outside folded regions that still
affect the folded region visibility.  For example, removing all stars
at the beginning of a folded org-mode heading should trigger the
folded text to be revealed.
Each function is called with two arguments: beginning and the end of
the changed region.")

;;; Utility functions

(defsubst org-fold-core-folding-spec-list (&optional buffer)
  "Return list of all the folding specs in BUFFER."
  (with-current-buffer (or buffer (current-buffer))
    (mapcar #'car org-fold-core--specs)))

(defun org-fold-core-get-folding-spec-from-alias (spec-or-alias)
  "Return the folding spec symbol for SPEC-OR-ALIAS."
  (and spec-or-alias
       (or (and (memq spec-or-alias (org-fold-core-folding-spec-list)) spec-or-alias)
           (seq-some (lambda (spec) (and (memq spec-or-alias (alist-get :alias (alist-get spec org-fold-core--specs))) spec)) (org-fold-core-folding-spec-list)))))

(defun org-fold-core-folding-spec-p (spec-or-alias)
  "Check if SPEC-OR-ALIAS is a registered folding spec."
  (org-fold-core-get-folding-spec-from-alias spec-or-alias))

(defun org-fold-core--check-spec (spec-or-alias)
  "Throw an error if SPEC-OR-ALIAS is not present in `org-fold-core--spec-priority-list'."
  (unless (org-fold-core-folding-spec-p spec-or-alias)
    (error "%s is not a valid folding spec" spec-or-alias)))

(defun org-fold-core-get-folding-spec-property (spec-or-alias property)
  "Get PROPERTY of a folding SPEC-OR-ALIAS.
Possible properties can be found in `org-fold-core--specs' docstring."
  (org-fold-core--check-spec spec-or-alias)
  (alist-get property (alist-get (org-fold-core-get-folding-spec-from-alias spec-or-alias) org-fold-core--specs)))

(defconst org-fold-core--spec-property-prefix "org-fold--spec-"
  "Prefix used to create property symbol.")

(defsubst org-fold-core-get-folding-property-symbol (spec &optional buffer)
  "Get folding property for SPEC in current buffer or BUFFER."
  (intern (format (concat org-fold-core--spec-property-prefix "%s-%S")
		  (symbol-name spec)
		  ;; (sxhash buf) appears to be not constant over time.
		  ;; Using buffer-name is safe, since the only place where
		  ;; buffer-local text property actually matters is an indirect
		  ;; buffer, where the name cannot be same anyway.
		  (sxhash (buffer-name (or buffer (current-buffer)))))))

(defsubst org-fold-core-get-folding-spec-from-folding-prop (folding-prop)
  "Return folding spec symbol used for folding property with name FOLDING-PROP."
  (catch :exit
    (dolist (spec (org-fold-core-folding-spec-list))
      ;; We know that folding properties have
      ;; folding spec in their name.
      (when (string-match-p (symbol-name spec)
			    (symbol-name folding-prop))
        (throw :exit spec)))))

(defvar org-fold-core--property-symbol-cache (make-hash-table :test 'equal)
  "Saved values of folding properties for (buffer . spec) conses.")

;; This is the core function used to fold text in org buffers.  We use
;; text properties to hide folded text, however 'invisible property is
;; not directly used. Instead, we define unique text property (folding
;; property) for every possible folding spec and add the resulting
;; text properties into `char-property-alias-alist', so that
;; 'invisible text property is automatically defined if any of the
;; folding properties is non-nil.
;; This approach lets us maintain multiple folds for the same text
;; region - poor man's overlays (but much faster).
;; Additionally, folding properties are ensured to be unique for
;; different buffers (especially for indirect buffers). This is done
;; to allow different folding states in indirect org buffers.
;; If one changes folding state in a fresh indirect buffer, all the
;; folding properties carried from the base buffer are updated to
;; become unique in the new indirect buffer.
(defun org-fold-core--property-symbol-get-create (spec &optional buffer return-only)
  "Return a unique symbol suitable as folding text property.
Return value is unique for folding SPEC in BUFFER.
If the buffer already have buffer-local setup in `char-property-alias-alist'
and the setup appears to be created for different buffer,
copy the old invisibility state into new buffer-local text properties,
unless RETURN-ONLY is non-nil."
  (org-fold-core--check-spec spec)
  (let* ((buf (or buffer (current-buffer))))
    ;; Create unique property symbol for SPEC in BUFFER
    (let ((local-prop (or (gethash (cons buf spec) org-fold-core--property-symbol-cache)
			  (puthash (cons buf spec)
                                   (org-fold-core-get-folding-property-symbol spec buf)
                                   org-fold-core--property-symbol-cache))))
      (prog1
          local-prop
        (unless return-only
	  (with-current-buffer buf
            ;; Update folding properties carried over from other
            ;; buffer (implying that current buffer is indirect
            ;; buffer). Normally, `char-property-alias-alist' in new
            ;; indirect buffer is a copy of the same variable from
            ;; the base buffer. Then, `char-property-alias-alist'
            ;; would contain folding properties, which are not
            ;; matching the generated `local-prop'.
	    (unless (member local-prop (cdr (assq 'invisible char-property-alias-alist)))
              ;; Copy all the old folding properties to preserve the folding state
              (with-silent-modifications
                (dolist (old-prop (cdr (assq 'invisible char-property-alias-alist)))
                  (org-with-wide-buffer
                   (let* ((pos (point-min))
	                  (spec (org-fold-core-get-folding-spec-from-folding-prop old-prop))
                          ;; Generate new buffer-unique folding property
	                  (new-prop (org-fold-core--property-symbol-get-create spec nil 'return-only)))
                     ;; Copy the visibility state for `spec' from `old-prop' to `new-prop'
                     (while (< pos (point-max))
	               (let ((val (get-text-property pos old-prop)))
	                 (when val
	                   (put-text-property pos (next-single-char-property-change pos old-prop) new-prop val)))
	               (setq pos (next-single-char-property-change pos old-prop))))))
                ;; Update `char-property-alias-alist' with folding
                ;; properties unique for the current buffer.
                (setq-local char-property-alias-alist
	                    (cons (cons 'invisible
			                (mapcar (lambda (spec)
				                  (org-fold-core--property-symbol-get-create spec nil 'return-only))
				                (org-fold-core-folding-spec-list)))
		                  (remove (assq 'invisible char-property-alias-alist)
			                  char-property-alias-alist)))
                (setq-local text-property-default-nonsticky
                            (delete-dups (append text-property-default-nonsticky
                                                 (mapcar (lambda (spec)
                                                           (cons (org-fold-core--property-symbol-get-create spec nil 'return-only) t))
                                                         (org-fold-core-folding-spec-list)))))))))))))

(defun org-fold-core-decouple-indirect-buffer-folds ()
  "Copy and decouple folding state in a newly created indirect buffer."
  (when (buffer-base-buffer)
    (org-fold-core--property-symbol-get-create (car (org-fold-core-folding-spec-list)))))

;;; API

;;;; Modifying folding specs

(defun org-fold-core-set-folding-spec-property (spec property value &optional force)
  "Set PROPERTY of a folding SPEC to VALUE.
Possible properties and values can be found in `org-fold-core--specs' docstring.
Do not check previous value when FORCE is non-nil."
  (pcase property
    (:ellipsis
     (unless (and (not force) (equal value (org-fold-core-get-folding-spec-property spec :ellipsis)))
       (remove-from-invisibility-spec (cons spec (org-fold-core-get-folding-spec-property spec :ellipsis)))
       (unless (org-fold-core-get-folding-spec-property spec :visible)
         (add-to-invisibility-spec (cons spec value)))))
    (:visible
     (unless (and (not force) (equal value (org-fold-core-get-folding-spec-property spec :visible)))
       (if value
	   (remove-from-invisibility-spec (cons spec (org-fold-core-get-folding-spec-property spec :ellipsis)))
         (add-to-invisibility-spec (cons spec (org-fold-core-get-folding-spec-property spec :ellipsis))))))
    (:alias nil)
    ;; TODO
    (:isearch-open nil)
    ;; TODO
    (:isearch-ignore nil)
    ;; TODO
    (:front-sticky nil)
    ;; TODO
    (:rear-sticky nil)
    (_ nil))
  (setf (alist-get property (alist-get spec org-fold-core--specs)) value))

(defun org-fold-core-add-folding-spec (spec &optional properties buffer append)
  "Add a new folding SPEC with PROPERTIES in BUFFER.

SPEC must be a symbol.  BUFFER can be a buffer to set SPEC in or nil to
set SPEC in current buffer.

By default, the added SPEC will have highest priority among the
previously defined specs.  When optional APPEND argument is non-nil,
SPEC will have the lowest priority instead.  If SPEC was already
defined earlier, it will be redefined according to provided optional
arguments.
`
The folding spec properties will be set to PROPERTIES (see
`org-fold-core--specs' for details)."
  (when (eq spec 'all) (error "Cannot use reserved folding spec symbol 'all"))
  (with-current-buffer (or buffer (current-buffer))
    (let* ((full-properties (mapcar (lambda (prop) (cons prop (alist-get prop properties)))
                                    '( :visible :ellipsis :isearch-ignore
                                       :isearch-open :front-sticky :rear-sticky
                                       :fragile :alias)))
           (full-spec (cons spec full-properties)))
      (add-to-list 'org-fold-core--specs full-spec append)
      (mapc (lambda (prop-cons) (org-fold-core-set-folding-spec-property spec (car prop-cons) (cdr prop-cons) 'force)) full-properties))))

(defun org-fold-core-remove-folding-spec (spec &optional buffer)
  "Remove a folding SPEC in BUFFER.

SPEC must be a symbol.
BUFFER can be a buffer to remove SPEC in, nil to remove SPEC in current buffer,
or 'all to remove SPEC in all open `org-mode' buffers and all future org buffers."
  (org-fold-core--check-spec spec)
  (when (eq buffer 'all)
    (setq-default org-fold-core--specs (delete (alist-get spec org-fold-core--specs) org-fold-core--specs))
    (mapc (lambda (buf)
	    (org-fold-core-remove-folding-spec spec buf))
	  (buffer-list)))
  (let ((buffer (or buffer (current-buffer))))
    (with-current-buffer buffer
      (org-fold-core-set-folding-spec-property spec :visible t)
      (setq org-fold-core--specs (delete (alist-get spec org-fold-core--specs) org-fold-core--specs)))))

(defun org-fold-core-initialize (&optional specs)
  "Setup folding in current buffer using SPECS as value of `org-fold-core--specs'."
  ;; Preserve the priorities.
  (when specs (setq specs (nreverse specs)))
  (unless specs (setq specs org-fold-core--specs))
  (setq org-fold-core--specs nil)
  (dolist (spec (or specs org-fold-core--specs))
    (org-fold-core-add-folding-spec (car spec) (cdr spec)))
  (add-hook 'after-change-functions 'org-fold-core--fix-folded-region nil 'local)
  (add-hook 'clone-indirect-buffer-hook #'org-fold-core-decouple-indirect-buffer-folds)
  ;; Setup killing text
  (setq-local filter-buffer-substring-function #'org-fold-core--buffer-substring-filter)
  (require 'isearch)
  (if (boundp 'isearch-opened-regions)
      ;; Use new implementation of isearch allowing to search inside text
      ;; hidden via text properties.
      (org-fold-core--isearch-setup 'text-properties)
    (org-fold-core--isearch-setup 'overlays)))

;;;; Searching and examining folded text

(defun org-fold-core-folded-p (&optional pos spec-or-alias)
  "Non-nil if the character after POS is folded.
If POS is nil, use `point' instead.
If SPEC-OR-ALIAS is a folding spec, only check the given folding spec.
If SPEC-OR-ALIAS is a foldable element, only check folding spec for
the given element.  Note that multiple elements may have same folding
specs."
  (org-fold-core-get-folding-spec spec-or-alias pos))

(defun org-fold-core-region-folded-p (beg end &optional spec-or-alias)
  "Non-nil if the region between BEG and END is folded.
If SPEC-OR-ALIAS is a folding spec, only check the given folding spec."
  (org-with-point-at beg
    (catch :visible
      (while (< (point) end)
        (unless (org-fold-core-get-folding-spec spec-or-alias) (throw :visible nil))
        (goto-char (org-fold-core-next-folding-state-change spec-or-alias nil end)))
      t)))

(defun org-fold-core-get-folding-spec (&optional spec-or-alias pom)
  "Get folding state at `point' or POM.
Return nil if there is no folding at point or POM.
If SPEC-OR-ALIAS is nil, return a folding spec with highest priority
among present at `point' or POM.
If SPEC-OR-ALIAS is 'all, return the list of all present folding
specs.
If SPEC-OR-ALIAS is a valid folding spec, return the corresponding
folding spec (if the text is folded using that spec).
If SPEC-OR-ALIAS is a foldable org element, act as if the element's
folding spec was used as an argument.  Note that multiple elements may
have same folding specs."
  (let ((spec (if (eq spec-or-alias 'all)
                  'all
                (org-fold-core-get-folding-spec-from-alias spec-or-alias))))
    (when (and spec (not (eq spec 'all))) (org-fold-core--check-spec spec))
    (org-with-point-at (or pom (point))
      (if (and spec (not (eq spec 'all)))
	  (get-char-property (point) (org-fold-core--property-symbol-get-create spec nil t))
	(let ((result))
	  (dolist (spec (org-fold-core-folding-spec-list))
	    (let ((val (get-char-property (point) (org-fold-core--property-symbol-get-create spec nil t))))
	      (when val (push val result))))
          (if (eq spec 'all)
              result
            (car (last result))))))))

(defun org-fold-core-get-folding-specs-in-region (beg end)
  "Get all folding specs in region from BEG to END."
  (let ((pos beg)
	all-specs)
    (while (< pos end)
      (setq all-specs (append all-specs (org-fold-core-get-folding-spec nil pos)))
      (setq pos (org-fold-core-next-folding-state-change nil pos end)))
    (unless (listp all-specs) (setq all-specs (list all-specs)))
    (delete-dups all-specs)))

(defun org-fold-core-get-region-at-point (&optional spec-or-alias pom)
  "Return region folded using SPEC-OR-ALIAS at POM.
If SPEC is nil, return the largest possible folded region.
The return value is a cons of beginning and the end of the region.
Return nil when no fold is present at point of POM."
  (let ((spec (org-fold-core-get-folding-spec-from-alias spec-or-alias)))
    (org-with-point-at (or pom (point))
      (if spec
	  (org-find-text-property-region (point) (org-fold-core--property-symbol-get-create spec nil t))
        (let ((region (cons (point) (point))))
	  (dolist (spec (org-fold-core-get-folding-spec 'all))
            (let ((local-region (org-fold-core-get-region-at-point spec)))
              (when (< (car local-region) (car region))
                (setcar region (car local-region)))
              (when (> (cdr local-region) (cdr region))
                (setcdr region (cdr local-region)))))
	  (unless (eq (car region) (cdr region)) region))))))

;; FIXME: Optimize performance
(defun org-fold-core-next-visibility-change (&optional pos limit ignore-hidden-p previous-p)
  "Return next point from POS up to LIMIT where text becomes visible/invisible.
By default, text hidden by any means (i.e. not only by folding, but
also via fontification) will be considered.
If IGNORE-HIDDEN-P is non-nil, consider only folded text.
If PREVIOUS-P is non-nil, search backwards."
  (let* ((pos (or pos (point)))
	 (invisible-p (if ignore-hidden-p
			  #'org-fold-core-folded-p
			#'invisible-p))
         (invisible-initially? (funcall invisible-p pos))
	 (limit (or limit (if previous-p
			      (point-min)
			    (point-max))))
         (cmp (if previous-p #'> #'<))
	 (next-change (if previous-p
			  (if ignore-hidden-p
                              (lambda (p) (org-fold-core-previous-folding-state-change (org-fold-core-get-folding-spec nil p) p limit))
			    (lambda (p) (max limit (1- (previous-single-char-property-change p 'invisible nil limit)))))
                        (if ignore-hidden-p
                            (lambda (p) (org-fold-core-next-folding-state-change (org-fold-core-get-folding-spec nil p) p limit))
			  (lambda (p) (next-single-char-property-change p 'invisible nil limit)))))
	 (next pos))
    (while (and (funcall cmp next limit)
		(not (xor invisible-initially? (funcall invisible-p next))))
      (setq next (funcall next-change next)))
    next))

(defun org-fold-core-previous-visibility-change (&optional pos limit ignore-hidden-p)
  "Call `org-fold-core-next-visibility-change' searching backwards."
  (org-fold-core-next-visibility-change pos limit ignore-hidden-p 'previous))

(defun org-fold-core-next-folding-state-change (&optional spec-or-alias pos limit previous-p)
  "Return next point where folding state changes relative to POS up to LIMIT.
If SPEC-OR-ALIAS is nil, return next point where _any_ single folding
type changes.
For example, (org-fold-core-next-folding-state-change nil) with point
somewhere in the below structure will return the nearest <...> point.

* Headline <begin outline fold>
:PROPERTIES:<begin drawer fold>
:ID: test
:END:<end drawer fold>

Fusce suscipit, wisi nec facilisis facilisis, est dui fermentum leo, quis tempor ligula erat quis odio.

** Another headline
:DRAWER:<begin drawer fold>
:END:<end drawer fold>
** Yet another headline
<end of outline fold>

If SPEC-OR-ALIAS is a folding spec symbol, only consider that folded spec.

If SPEC-OR-ALIAS is a list, only consider changes of folding states
from the list.

Search backwards when PREVIOUS-P is non-nil."
  (when (and spec-or-alias (symbolp spec-or-alias))
    (setq spec-or-alias (list spec-or-alias)))
  (when spec-or-alias
    (setq spec-or-alias
	  (mapcar (lambda (spec-or-alias)
		    (or (org-fold-core-get-folding-spec-from-alias spec-or-alias)
			spec-or-alias))
                  spec-or-alias))
    (mapc #'org-fold-core--check-spec spec-or-alias))
  (unless spec-or-alias
    (setq spec-or-alias (org-fold-core-folding-spec-list)))
  (let* ((pos (or pos (point)))
	 (props (mapcar (lambda (el) (org-fold-core--property-symbol-get-create el nil t))
			spec-or-alias))
         (cmp (if previous-p
		  #'max
		#'min))
         (next-change (if previous-p
			  (lambda (prop) (max (or limit (point-min)) (previous-single-char-property-change pos prop nil (or limit (point-min)))))
			(lambda (prop) (next-single-char-property-change pos prop nil (or limit (point-max)))))))
    (apply cmp (mapcar next-change props))))

(defun org-fold-core-previous-folding-state-change (&optional spec-or-alias pos limit)
  "Call `org-fold-core-next-folding-state-change' searching backwards."
  (org-fold-core-next-folding-state-change spec-or-alias pos limit 'previous))

(defun org-fold-core-search-forward (spec-or-alias &optional limit)
  "Search next region folded via folding SPEC-OR-ALIAS up to LIMIT.
Move point right after the end of the region, to LIMIT, or
`point-max'.  The `match-data' will contain the region."
  (let ((spec (org-fold-core-get-folding-spec-from-alias spec-or-alias)))
    (let ((prop-symbol (org-fold-core--property-symbol-get-create spec nil t)))
      (goto-char (or (next-single-char-property-change (point) prop-symbol nil limit) limit (point-max)))
      (when (and (< (point) (or limit (point-max)))
	         (not (org-fold-core-get-folding-spec spec)))
        (goto-char (next-single-char-property-change (point) prop-symbol nil limit)))
      (when (org-fold-core-get-folding-spec spec)
        (let ((region (org-fold-core-get-region-at-point spec)))
	  (when (< (cdr region) (or limit (point-max)))
	    (goto-char (1+ (cdr region)))
            (set-match-data (list (set-marker (make-marker) (car region) (current-buffer))
				  (set-marker (make-marker) (cdr region) (current-buffer))))))))))

;;;; Changing visibility (regions, blocks, drawers, headlines)

;;;;; Region visibility

;; This is the core function performing actual folding/unfolding.  The
;; folding state is stored in text property (folding property)
;; returned by `org-fold-core--property-symbol-get-create'.  The value of the
;; folding property is folding spec symbol.
(defun org-fold-core-region (from to flag &optional spec-or-alias)
  "Hide or show lines from FROM to TO, according to FLAG.
SPEC-OR-ALIAS is the folding spec or foldable element, as a symbol.
If SPEC-OR-ALIAS is omitted and FLAG is nil, unfold everything in the region."
  (let ((spec (org-fold-core-get-folding-spec-from-alias spec-or-alias)))
    (when spec (org-fold-core--check-spec spec))
    (with-silent-modifications
      (org-with-wide-buffer
       (if flag
	   (if (not spec)
               (error "Calling `org-fold-core-region' with missing SPEC")
	     (put-text-property from to
				(org-fold-core--property-symbol-get-create spec)
				spec)
	     (put-text-property from to
				'isearch-open-invisible
				#'org-fold-core--isearch-show)
	     (put-text-property from to
				'isearch-open-invisible-temporary
				#'org-fold-core--isearch-show-temporary))
	 (if (not spec)
             (dolist (spec (org-fold-core-folding-spec-list))
               (remove-text-properties from to
				       (list (org-fold-core--property-symbol-get-create spec) nil)))
	   (remove-text-properties from to
				   (list (org-fold-core--property-symbol-get-create spec) nil))))))))

;;; Make isearch search in some text hidden via text propertoes

(defvar org-fold-core--isearch-overlays nil
  "List of overlays temporarily created during isearch.
This is used to allow searching in regions hidden via text properties.
As for [2020-05-09 Sat], Isearch only has special handling of hidden overlays.
Any text hidden via text properties is not revealed even if `search-invisible'
is set to 't.")

(defvar-local org-fold-core--isearch-local-regions (make-hash-table :test 'equal)
  "Hash table storing temporarily shown folds from isearch matches.")

(defun org-fold-core--isearch-reveal (pos)
  "Reveal hidden text at POS for isearch."
  (let ((region (org-fold-core-get-region-at-point pos)))
    (org-fold-core-region (car region) (cdr region) nil)))

(defun org-fold-core--isearch-setup (type)
  "Initialize isearch in org buffer.
TYPE can be either `text-properties' or `overlays'."
  (pcase type
    (`text-properties
     (setq-local search-invisible 'open-all)
     (add-hook 'isearch-mode-end-hook #'org-fold-core--clear-isearch-state nil 'local)
     (add-hook 'isearch-mode-hook #'org-fold-core--clear-isearch-state nil 'local)
     (setq-local isearch-filter-predicate #'org-fold-core--isearch-filter-predicate-text-properties))
    (`overlays
     (setq-local isearch-filter-predicate #'org-fold-core--isearch-filter-predicate-overlays)
     (add-hook 'isearch-mode-end-hook #'org-fold-core--clear-isearch-overlays nil 'local))
    (_ (error "%s: Unknown type of setup for `org-fold-core--isearch-setup'" type))))

(defun org-fold-core--isearch-filter-predicate-text-properties (beg end)
  "Make sure that folded text is searchable when user whant so.
This function is intended to be used as `isearch-filter-predicate'."
  (and
   ;; Check folding specs that cannot be searched
   (seq-every-p (lambda (spec) (not (org-fold-core-get-folding-spec-property spec :isearch-ignore)))
                (org-fold-core-get-folding-specs-in-region beg end))
   ;; Check 'invisible properties that are not folding specs
   (or (eq search-invisible t) ; User wants to search, allow it
       (let ((pos beg)
	     unknown-invisible-property)
	 (while (and (< pos end)
		     (not unknown-invisible-property))
	   (when (and (get-text-property pos 'invisible)
                      (not (org-fold-core-folding-spec-p (get-text-property pos 'invisible))))
	     (setq unknown-invisible-property t))
	   (setq pos (next-single-char-property-change pos 'invisible)))
	 (not unknown-invisible-property)))
   (or (and (eq search-invisible t)
	    ;; FIXME: this opens regions permanenly for now.
            ;; I also tried to force search-invisible 'open-all around
            ;; `isearch-range-invisible', but that somehow causes
            ;; infinite loop in `isearch-lazy-highlight'.
            (prog1 t
	      ;; We still need to reveal the folded location
	      (org-fold-core--isearch-show-temporary (cons beg end) nil)))
       (not (isearch-range-invisible beg end)))))

(defun org-fold-core--clear-isearch-state ()
  "Clear `org-fold-core--isearch-local-regions'."
  (clrhash org-fold-core--isearch-local-regions))

(defun org-fold-core--isearch-show (region)
  "Reveal text in REGION found by isearch."
  (org-with-point-at (car region)
    (while (< (point) (cdr region))
      (funcall org-fold-core-isearch-open-function (car region))
      (goto-char (org-fold-core-next-visibility-change (point) (cdr region) 'ignore-hidden)))))

(defun org-fold-core--isearch-show-temporary (region hide-p)
  "Temporarily reveal text in REGION.
Hide text instead if HIDE-P is non-nil."
  (if (not hide-p)
      (let ((pos (car region)))
	(while (< pos (cdr region))
          (let ((spec-no-open (seq-find (lambda (spec) (not (org-fold-core-get-folding-spec-property spec :isearch-open))) (org-fold-core-get-folding-spec 'all pos))))
            (if spec-no-open
                ;; Skip regions folded with folding specs that cannot be opened.
                (setq pos (org-fold-core-next-folding-state-change spec-no-open pos (cdr region)))
	      (dolist (spec (org-fold-core-get-folding-spec 'all pos))
	        (push (cons spec (org-fold-core-get-region-at-point spec pos)) (gethash region org-fold-core--isearch-local-regions)))
              (org-fold-core--isearch-show region)
	      (setq pos (org-fold-core-next-folding-state-change nil pos (cdr region)))))))
    (mapc (lambda (val) (org-fold-core-region (cadr val) (cddr val) t (car val))) (gethash region org-fold-core--isearch-local-regions))
    (remhash region org-fold-core--isearch-local-regions)))

(defun org-fold-core--create-isearch-overlays (beg end)
  "Replace text property invisibility spec by overlays between BEG and END.
All the searcheable folded regions will be changed to use overlays
instead of text properties.  The created overlays will be stored in
`org-fold-core--isearch-overlays'."
  (let ((pos beg))
    (while (< pos end)
      ;; We need loop below to make sure that we clean all invisible
      ;; properties, which may be nested.
      (while (memq (get-text-property pos 'invisible) (org-fold-core-folding-spec-list))
	(let* ((spec (get-text-property pos 'invisible))
               (region (org-fold-core-get-region-at-point spec pos)))
	  ;; Changing text properties is considered buffer modification.
	  ;; We do not want it here.
	  (with-silent-modifications
            (org-fold-core-region (car region) (cdr region) nil spec)
	    ;; The overlay is modelled after `outline-flag-region'
	    ;; [2020-05-09 Sat] overlay for 'outline blocks.
	    (let ((o (make-overlay (car region) (cdr region) nil 'front-advance)))
	      (overlay-put o 'evaporate t)
	      (overlay-put o 'invisible spec)
              ;; Make sure that overlays are applied in the same order
              ;; with the folding specs.
              ;; Note: `memq` returns cdr with car equal to the first
              ;; found matching element.
              (overlay-put o 'priority (length (memq spec (org-fold-core-folding-spec-list))))
	      ;; `delete-overlay' here means that spec information will be lost
	      ;; for the region. The region will remain visible.
              (if (org-fold-core-get-folding-spec-property spec :isearch-open)
	          (overlay-put o 'isearch-open-invisible #'delete-overlay)
                (overlay-put o 'isearch-open-invisible #'ignore)
                (overlay-put o 'isearch-open-invisible-temporary #'ignore))
	      (push o org-fold-core--isearch-overlays)))))
      (setq pos (next-single-property-change pos 'invisible nil end)))))

(defun org-fold-core--isearch-filter-predicate-overlays (beg end)
  "Return non-nil if text between BEG and END is deemed visible by isearch.
This function is intended to be used as `isearch-filter-predicate'."
  (org-fold-core--create-isearch-overlays beg end) ;; trick isearch by creating overlays in place of invisible text
  (isearch-filter-visible beg end))

(defun org-fold-core--clear-isearch-overlay (ov)
  "Convert OV region back into using text properties."
  (let ((spec (overlay-get ov 'invisible)))
    ;; Ignore deleted overlays.
    (when (and spec
	       (overlay-buffer ov))
      ;; Changing text properties is considered buffer modification.
      ;; We do not want it here.
      (with-silent-modifications
	(when (<= (overlay-end ov) (point-max))
	  (org-fold-core-region (overlay-start ov) (overlay-end ov) t spec)))))
  (when (member ov isearch-opened-overlays)
    (setq isearch-opened-overlays (delete ov isearch-opened-overlays)))
  (delete-overlay ov))

(defun org-fold-core--clear-isearch-overlays ()
  "Convert overlays from `org-fold-core--isearch-overlays' back into using text properties."
  (when org-fold-core--isearch-overlays
    (mapc #'org-fold-core--clear-isearch-overlay org-fold-core--isearch-overlays)
    (setq org-fold-core--isearch-overlays nil)))

;;; Handling changes in folded elements

(defvar org-fold-core--ignore-modifications nil
  "Non-nil: skip processing modifications in `org-fold-core--fix-folded-region'.")

(defmacro org-fold-core-ignore-modifications (&rest body)
  "Run BODY ignoring buffer modifications in `org-fold-core--fix-folded-region'."
  (declare (debug (form body)) (indent 1))
  `(let ((org-fold-core--ignore-modifications t))
     (unwind-protect (progn ,@body)
       (setq org-fold-core--last-buffer-chars-modified-tick (buffer-chars-modified-tick)))))

(defvar-local org-fold-core--last-buffer-chars-modified-tick nil
  "Variable storing the last return value of `buffer-chars-modified-tick'.")

(defun org-fold-core--fix-folded-region (from to _)
  "Process modifications in folded elements within FROM . TO region.
This function intended to be used as one of `after-change-functions'.

This function does nothing if text the only modification was changing
text properties (for the sake of reducing overheads).

If a text was inserted into invisible region, hide the inserted text.
If a text was insert in front/back of the region, hide it according to
:font-sticky/:rear-sticky folding spec property.

If the folded region is folded with a spec with non-nil :fragile
property, unfold the region if the :fragile function returns non-nil."
  ;; If no insertions or deletions in buffer, skip all the checks.
  (unless (or (eq org-fold-core--last-buffer-chars-modified-tick (buffer-chars-modified-tick))
              org-fold-core--ignore-modifications)
    (save-match-data
      ;; Store the new buffer modification state.
      (setq org-fold-core--last-buffer-chars-modified-tick (buffer-chars-modified-tick))
      ;; Re-hide text inserted in the middle/font/back of a folded
      ;; region.
      (unless (equal from to) ; Ignore deletions.
	(dolist (spec (org-fold-core-folding-spec-list))
          ;; Reveal fully invisible text.  This is needed, for
          ;; example, when there was a deletion in a folded heading,
          ;; the heading was unfolded, end `undo' was called.  The
          ;; `undo' would insert the folded text.
          (when (org-fold-core-region-folded-p from to spec) (org-fold-core-region from to nil spec))
          ;; Look around and fold the new text if the nearby folds are
          ;; sticky.
	  (let ((spec-to (org-fold-core-get-folding-spec spec (min to (1- (point-max)))))
		(spec-from (org-fold-core-get-folding-spec spec (max (point-min) (1- from)))))
            ;; Hide text inserted in the middle of a fold.
	    (when (and spec-from spec-to (eq spec-to spec-from)
                       (or (org-fold-core-get-folding-spec-property spec :front-sticky)
                           (org-fold-core-get-folding-spec-property spec :rear-sticky)))
	      (org-fold-core-region from to t (or spec-from spec-to)))
            ;; Hide text inserted at the end of a fold.
            (when (and spec-from (org-fold-core-get-folding-spec-property spec-from :rear-sticky))
              (org-fold-core-region from to t spec-from))
            ;; Hide text inserted in front of a fold.
            (when (and spec-to (org-fold-core-get-folding-spec-property spec-to :front-sticky))
              (org-fold-core-region from to t spec-to)))))
      ;; Process all the folded text between `from' and `to'.
      (dolist (func org-fold-core-extend-changed-region-functions)
        (let ((new-region (funcall func from to)))
          (setq from (car new-region))
          (setq to (cdr new-region))))
      (dolist (spec (org-fold-core-folding-spec-list))
        ;; No action is needed when :fragile is nil for the spec.
        (when (org-fold-core-get-folding-spec-property spec :fragile)
          (org-with-wide-buffer
           ;; Expand the considered region to include partially present fold.
           ;; Note: It is important to do this inside loop ovre all
           ;; specs.  Otherwise, the region may be expanded to huge
           ;; outline fold, potentially involving majority of the
           ;; buffer.  That would cause the below code to loop over
           ;; almost all the folds in buffer, which would be too slow.
           (let ((region-from (org-fold-core-get-region-at-point spec (max (point-min) (1- from))))
                 (region-to (org-fold-core-get-region-at-point spec (min to (1- (point-max))))))
             (when region-from (setq from (car region-from)))
             (when region-to (setq to (cdr region-to))))
           (let ((pos from))
	     ;; Move to the first hidden region.
	     (unless (org-fold-core-get-folding-spec spec pos)
	       (setq pos (org-fold-core-next-folding-state-change spec pos to)))
	     ;; Cycle over all the folds.
	     (while (< pos to)
	       (save-match-data ; we should not clobber match-data in after-change-functions
	         (let ((fold-begin (and (org-fold-core-get-folding-spec spec pos)
				        pos))
		       (fold-end (org-fold-core-next-folding-state-change spec pos to)))
	           (when (and fold-begin fold-end)
		     (when (save-excursion
                             (funcall (org-fold-core-get-folding-spec-property spec :fragile)
                                      (cons fold-begin fold-end)
                                      spec))
                       (org-fold-core-region fold-begin fold-end nil spec)))))
	       ;; Move to next fold.
	       (setq pos (org-fold-core-next-folding-state-change spec pos to))))))))))

;;; Hanlding killing/yanking of folded text

;; By default, all the text properties of the killed text are
;; preserved, including the folding text properties.  This can be
;; awkward when we copy a text from an indirect buffer to another
;; indirect buffer (or the base buffer).  The copied text might be
;; visible in the source buffer, but might disappear if we yank it in
;; another buffer.  This happens in the following situation:
;; ---- base buffer ----
;; * Headline<begin fold>
;; Some text hidden in the base buffer, but revealed in the indirect
;; buffer.<end fold>
;; * Another headline
;;
;; ---- end of base buffer ----
;; ---- indirect buffer ----
;; * Headline
;; Some text hidden in the base buffer, but revealed in the indirect
;; buffer.
;; * Another headline
;;
;; ---- end of indirect buffer ----
;; If we copy the text under "Headline" from the indirect buffer and
;; insert it under "Another headline" in the base buffer, the inserted
;; text will be hidden since it's folding text properties are copyed.
;; Basically, the copied text would have two sets of folding text
;; properties: (1) Properties for base buffer telling that the text is
;; hidden; (2) Properties for the indirect buffer telling that the
;; text is visible.  The first set of the text properties in inactive
;; in the indirect buffer, but will become active once we yank the
;; text back into the base buffer.
;;
;; To avoid the above situation, we simply clear all the properties,
;; unrealated to current buffer when a text is copied.
;; FIXME: Ideally, we may want to carry the folding state of copied
;; text between buffer (probably via user customisation).
(defun org-fold-core--buffer-substring-filter (beg end &optional delete)
  "Clear folding state in killed text.
This function is intended to be used as `filter-buffer-substring-function'.
The arguments and return value are as specified for `filter-buffer-substring'."
  (let ((return-string (buffer-substring--filter beg end delete))
	;; The list will be used as an argument to `remove-text-properties'.
	props-list)
    ;; There is no easy way to examine all the text properties of a
    ;; string, so we utilise the fact that printed string
    ;; representation lists all its properties.
    ;; Loop over the elements of string representation.
    (unless (string-empty-p return-string)
      ;; Collect all the text properties the string is completely
      ;; hidden with.
      (dolist (spec (org-fold-core-folding-spec-list))
        (when (org-fold-core-region-folded-p beg end spec)
          (push (org-fold-core--property-symbol-get-create spec nil t) props-list)))
      (dolist (plist (mapcar #'caddr (object-intervals return-string)))
	;; Only lists contain text properties.
	(when (listp plist)
          ;; Collect all the relevant text properties.
	  (while plist
            (let* ((prop (car plist))
		   (prop-name (symbol-name prop)))
              ;; We do not care about values.
              (setq plist (cddr plist))
              (when (string-match-p org-fold-core--spec-property-prefix prop-name)
		;; Leave folding specs from current buffer.  See
		;; comments in `org-fold-core--property-symbol-get-create' to
		;; understand why it works.
		(unless (member prop (alist-get 'invisible char-property-alias-alist))
		  (push prop props-list)))))))
      (remove-text-properties 0 (length return-string) props-list return-string))
    return-string))

(provide 'org-fold-core)

;;; org-fold-core.el ends here