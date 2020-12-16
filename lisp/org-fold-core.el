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

(defcustom org-fold-catch-invisible-edits nil
  "Check if in invisible region before inserting or deleting a character.
Valid values are:

nil              Do not check, so just do invisible edits.
error            Throw an error and do nothing.
show             Make point visible, and do the requested edit.
show-and-error   Make point visible, then throw an error and abort the edit.
smart            Make point visible, and do insertion/deletion if it is
                 adjacent to visible text and the change feels predictable.
                 Never delete a previously invisible character or add in the
                 middle or right after an invisible region.  Basically, this
                 allows insertion and backward-delete right before ellipses.
                 FIXME: maybe in this case we should not even show?"
  :group 'org-edit-structure
  :version "24.1"
  :type '(choice
	  (const :tag "Do not check" nil)
	  (const :tag "Throw error when trying to edit" error)
	  (const :tag "Unhide, but do not do the edit" show-and-error)
	  (const :tag "Show invisible part and do the edit" show)
	  (const :tag "Be smart and do the right thing" smart)))

;;; Core functionality

;;;; Buffer-local folding specs

(defvar-local org-fold--specs nil
  "Folding specs defined in current buffer.

Each spec is a list (SPEC-SYMBOL SPEC-PROPERTIES).
SPEC-SYMBOL is the symbol respresenting the folding spec.
SPEC-PROPERTIES is an alist defining folding spec properties.

If a text region is folded using multiple specs, only the folding spec
listed earlier is used.

The following properties are known:
- ellipsis         :: must be nil or string to show when text is folded
                      using this spec.
- isearch-ignore   :: non-nil means that folded text is not searchable
                      using isearch.
- isearch-open     :: non-nil means that isearch can reveal text hidden
                      using this spec.  This property does nothing
                      when 'isearch-ignore property is non-nil.
- front-sticky     :: non-nil means that text prepended to the folded text
                      is automatically folded.
- rear-sticky      :: non-nil means that text appended to the folded text
                      is folded.
- visible          :: non-nil means that folding spec visibility is not managed.
                      Instead, visibility settings in `buffer-invisibility-spec'
                      will be used as is.")

(defvar-local org-fold--spec-priority-list '(org-fold-outline
					     org-fold-drawer
					     org-fold-block)
  "Priority of folding specs.
If a region has multiple folding specs at the same time, only the
first property from this list will be considered.")

(defvar-local org-fold--spec-with-ellipsis '(org-fold-outline
					     org-fold-drawer
					     org-fold-block)
  "A list of folding specs, which should be indicated by `org-ellipsis'.")

(defvar-local org-fold--isearch-specs '(org-fold-block
					org-fold-drawer
					org-fold-outline)
  "List of text invisibility specs to be searched by isearch.
By default ([2020-05-09 Sat]), isearch does not search in hidden text,
which was made invisible using text properties.  Isearch will be forced
to search in hidden text with any of the listed 'invisible property value.")

(defsubst org-fold-get-folding-spec-for-element (type)
  "Return name of folding spec for element TYPE."
  (pcase type
    (`headline 'org-fold-outline)
    (`inlinetask 'org-fold-outline)
    (`plain-list 'org-fold-outline)
    (`block 'org-fold-block)
    (`center-block 'org-fold-block)
    (`comment-block 'org-fold-block)
    (`dynamic-block 'org-fold-block)
    (`example-block 'org-fold-block)
    (`export-block 'org-fold-block)
    (`quote-block 'org-fold-block)
    (`special-block 'org-fold-block)
    (`src-block 'org-fold-block)
    (`verse-block 'org-fold-block)
    (`drawer 'org-fold-drawer)
    (`property-drawer 'org-fold-drawer)
    (_ nil)))

(defvar org-fold--property-symbol-cache (make-hash-table :test 'equal)
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
(defun org-fold--property-symbol-get-create (spec &optional buffer return-only)
  "Return a unique symbol suitable as folding text property.
Return value is unique for folding SPEC in BUFFER.
If the buffer already have buffer-local setup in `char-property-alias-alist'
and the setup appears to be created for different buffer,
copy the old invisibility state into new buffer-local text properties,
unless RETURN-ONLY is non-nil."
  (org-fold--check-spec spec)
  (let* ((buf (or buffer (current-buffer))))
    ;; Create unique property symbol for SPEC in BUFFER
    (let ((local-prop (or (gethash (cons buf spec) org-fold--property-symbol-cache)
			  (puthash (cons buf spec)
				   (intern (format "org-fold--spec-%s-%S"
						   (symbol-name spec)
						   ;; (sxhash buf) appears to be not constant over time.
						   ;; Using buffer-name is safe, since the only place where
						   ;; buffer-local text property actually matters is an indirect
						   ;; buffer, where the name cannot be same anyway.
						   (sxhash (buffer-name buf))))
                                   org-fold--property-symbol-cache))))
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
	      (dolist (old-prop (cdr (assq 'invisible char-property-alias-alist)))
		(org-with-wide-buffer
		 (let* ((pos (point-min))
			;; We know that folding properties have
			;; folding spec in their name. Extract that
			;; spec.
			(spec (catch :exit
				(dolist (spec org-fold--spec-priority-list)
                                  (when (string-match-p (symbol-name spec)
							(symbol-name old-prop))
                                    (throw :exit spec)))))
                        ;; Generate new buffer-unique folding property
			(new-prop (org-fold--property-symbol-get-create spec nil 'return-only)))
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
						(org-fold--property-symbol-get-create spec nil 'return-only))
					      org-fold--spec-priority-list))
				(remove (assq 'invisible char-property-alias-alist)
					char-property-alias-alist))))))))))

;;; API

;;;; Modifying folding specs

(defun org-fold-folding-spec-p (spec)
  "Check if SPEC is a registered folding spec."
  (and spec (memq spec org-fold--spec-priority-list)))

(defun org-fold-add-folding-spec (spec &optional buffer no-ellipsis-p no-isearch-open-p append visible)
  "Add a new folding SPEC in BUFFER.

If VISIBLE is non-nil, visibility of text folded using SPEC will be
controlled by `buffer-invisibility-spec'.  The folded text will have
'invisible property set to SPEC (with lowest possible priority).

SPEC must be a symbol.  BUFFER can be a buffer to set SPEC in, nil to
set SPEC in current buffer, or 'all to set SPEC in all open `org-mode'
buffers and all future org buffers.  Non-nil optional argument
NO-ELLIPSIS-P means that folded text will not be indicated by
`org-ellipsis'.  Non-nil optional argument NO-ISEARCH-OPEN-P means
that folded text cannot be searched by isearch.  By default, the added
SPEC will have highest priority among the previously defined specs.
When optional APPEND argument is non-nil, SPEC will have the lowest
priority instead.  If SPEC was already defined earlier, it will be
redefined according to provided optional arguments."
  (when (eq spec 'all) (user-error "Folding spec name 'all is not allowed"))
  (when (eq buffer 'all)
    (mapc (lambda (buf)
	    (org-fold-add-folding-spec spec buf no-ellipsis-p no-isearch-open-p append visible))
	  (org-buffer-list))
    (setq-default org-fold--spec-priority-list (delq spec org-fold--spec-priority-list))
    (add-to-list 'org-fold--spec-priority-list spec append)
    (setq-default org-fold--spec-priority-list org-fold--spec-priority-list)
    (when no-ellipsis-p (setq-default org-fold--spec-with-ellipsis (delq spec org-fold--spec-with-ellipsis)))
    (unless no-ellipsis-p
      (add-to-list 'org-fold--spec-with-ellipsis spec)
      (setq-default org-fold--spec-with-ellipsis org-fold--spec-with-ellipsis))
    (when no-isearch-open-p (setq-default org-fold--isearch-specs (delq spec org-fold--isearch-specs)))
    (unless no-isearch-open-p
      (add-to-list 'org-fold--isearch-specs spec)
      (setq-default org-fold--isearch-specs org-fold--isearch-specs)))
  (let ((buffer (or buffer (current-buffer))))
    (with-current-buffer buffer
      (unless (or visible
		  (member (cons spec (not no-ellipsis-p)) buffer-invisibility-spec))
	(add-to-invisibility-spec (cons spec (not no-ellipsis-p))))
      (setq org-fold--spec-priority-list (delq spec org-fold--spec-priority-list))
      (add-to-list 'org-fold--spec-priority-list spec append)
      (when no-ellipsis-p (setq org-fold--spec-with-ellipsis (delq spec org-fold--spec-with-ellipsis)))
      (unless no-ellipsis-p (add-to-list 'org-fold--spec-with-ellipsis spec))
      (when no-isearch-open-p (setq org-fold--isearch-specs (delq spec org-fold--isearch-specs)))
      (unless no-isearch-open-p (add-to-list 'org-fold--isearch-specs spec)))))

(defun org-fold-remove-folding-spec (spec &optional buffer)
  "Remove a folding SPEC in BUFFER.

SPEC must be a symbol.
BUFFER can be a buffer to remove SPEC in, nil to remove SPEC in current buffer,
or 'all to remove SPEC in all open `org-mode' buffers and all future org buffers."
  (org-fold--check-spec spec)
  (when (eq buffer 'all)
    (mapc (lambda (buf)
	    (org-fold-remove-folding-spec spec buf))
	  (org-buffer-list))
    (setq-default org-fold--spec-priority-list (delq spec org-fold--spec-priority-list))
    (setq-default org-fold--spec-with-ellipsis (delq spec org-fold--spec-with-ellipsis))
    (setq-default org-fold--isearch-specs (delq spec org-fold--isearch-specs)))
  (let ((buffer (or buffer (current-buffer))))
    (with-current-buffer buffer
      (remove-from-invisibility-spec (cons spec t))
      (remove-from-invisibility-spec spec)
      (remove-from-invisibility-spec (list spec))
      (setq org-fold--spec-priority-list (delq spec org-fold--spec-priority-list))
      (setq org-fold--spec-with-ellipsis (delq spec org-fold--spec-with-ellipsis))
      (setq org-fold--isearch-specs (delq spec org-fold--isearch-specs)))))

(defun org-fold-initialize ()
  "Setup org-fold in current buffer."
  (dolist (spec org-fold--spec-priority-list)
    (org-fold-add-folding-spec spec nil (not (memq spec org-fold--spec-with-ellipsis)) (not (memq spec org-fold--isearch-specs))))
  (add-hook 'after-change-functions 'org-fold--fix-folded-region nil 'local)
  ;; Setup killing text
  (setq-local filter-buffer-substring-function #'org-fold--buffer-substring-filter)
  ;; Make isearch reveal context
  (setq-local outline-isearch-open-invisible-function
	      (lambda (&rest _) (org-fold-show-context 'isearch)))
  (require 'isearch)
  (if (boundp 'isearch-opened-regions)
      ;; Use new implementation of isearch allowing to search inside text
      ;; hidden via text properties.
      (org-fold--isearch-setup 'text-properties)
    (org-fold--isearch-setup 'overlays)))

;;;; Searching and examining folded text

(defun org-fold-folded-p (&optional pos spec-or-element)
  "Non-nil if the character after POS is folded.
If POS is nil, use `point' instead.
If SPEC-OR-ELEMENT is a folding spec, only check the given folding spec.
If SPEC-OR-ELEMENT is a foldable element (see
`org-fold-get-folding-spec-for-element'), only check folding spec for
the given element.  Note that multiple elements may have same folding
specs."
  (org-fold-get-folding-spec (or (org-fold-get-folding-spec spec-or-element) spec-or-element) pos))

(defun org-fold-get-folding-spec (&optional spec-or-element pom)
  "Get folding state at `point' or POM.
Return nil if there is no folding at point or POM.
If SPEC-OR-ELEMENT is nil, return a folding spec with highest priority
among present at `point' or POM.
If SPEC-OR-ELEMENT is 'all, return the list of all present folding
specs.
If SPEC-OR-ELEMENT is a valid folding spec, return the corresponding
folding spec (if the text is folded using that spec).
If SPEC-OR-ELEMENT is a foldable org element (see
`org-fold-get-folding-spec-for-element'), act as if the element's
folding spec was used as an argument.  Note that multiple elements may
have same folding specs."
  (let ((spec (or (org-fold-get-folding-spec-for-element spec-or-element)
		  spec-or-element)))
    (when (and spec (not (eq spec 'all))) (org-fold--check-spec spec))
    (org-with-point-at (or pom (point))
      (if (and spec (not (eq spec 'all)))
	  (get-char-property (point) (org-fold--property-symbol-get-create spec nil t))
	(let ((result))
	  (dolist (spec org-fold--spec-priority-list)
	    (let ((val (get-char-property (point) (org-fold--property-symbol-get-create spec nil t))))
	      (when val
		(push val result))))
          (if (eq spec 'all)
              result
            (car (last result))))))))

(defun org-fold-get-folding-specs-in-region (beg end)
  "Get all folding specs in region from BEG to END."
  (let ((pos beg)
	all-specs)
    (while (< pos end)
      (setq all-specs (append all-specs (org-fold-get-folding-spec nil pos)))
      (setq pos (org-fold-next-folding-state-change nil pos end)))
    (unless (listp all-specs) (setq all-specs (list all-specs)))
    (delete-dups all-specs)))

(defun org-fold-get-region-at-point (&optional spec pom)
  "Return region folded using SPEC at POM.
If SPEC is nil, return the largest possible folded region.
The return value is a cons of beginning and the end of the region.
Return nil when no fold is present at point of POM."
  (when spec (org-fold--check-spec spec))
  (org-with-point-at (or pom (point))
    (if spec
	(org-find-text-property-region (point) (org-fold--property-symbol-get-create spec nil t))
      (let ((region (cons (point) (point))))
	(dolist (spec (org-fold-get-folding-spec 'all))
          (let ((local-region (org-fold-get-region-at-point spec)))
            (when (< (car local-region) (car region))
              (setcar region (car local-region)))
            (when (> (cdr local-region) (cdr region))
              (setcdr region (cdr local-region)))))
	(unless (eq (car region) (cdr region)) region)))))

;; FIXME: Optimize performance
(defun org-fold-next-visibility-change (&optional pos limit ignore-hidden-p previous-p)
  "Return next point from POS up to LIMIT where text becomes visible/invisible.
By default, text hidden by any means (i.e. not only by folding, but
also via fontification) will be considered.
If IGNORE-HIDDEN-P is non-nil, consider only folded text.
If PREVIOUS-P is non-nil, search backwards."
  (let* ((pos (or pos (point)))
	 (invisible-p (if ignore-hidden-p
			  #'org-fold-folded-p
			#'invisible-p))
         (invisible-initially? (funcall invisible-p pos))
	 (limit (or limit (if previous-p
			      (point-min)
			    (point-max))))
         (cmp (if previous-p #'> #'<))
	 (next-change (if previous-p
			  (if ignore-hidden-p
                              (lambda (p) (org-fold-previous-folding-state-change (org-fold-get-folding-spec nil p) p limit))
			    (lambda (p) (max limit (1- (previous-single-char-property-change p 'invisible nil limit)))))
                        (if ignore-hidden-p
                            (lambda (p) (org-fold-next-folding-state-change (org-fold-get-folding-spec nil p) p limit))
			  (lambda (p) (next-single-char-property-change p 'invisible nil limit)))))
	 (next pos))
    (while (and (funcall cmp next limit)
		(not (xor invisible-initially? (funcall invisible-p next))))
      (setq next (funcall next-change next)))
    next))

(defun org-fold-previous-visibility-change (&optional pos limit ignore-hidden-p)
  "Call `org-fold-next-visibility-change' searching backwards."
  (org-fold-next-visibility-change pos limit ignore-hidden-p 'previous))

(defun org-fold-next-folding-state-change (&optional spec-or-element pos limit previous-p)
  "Return next point where folding state changes relative to POS up to LIMIT.
If SPEC-OR-ELEMENT is nil, return next point where _any_ single folding
type changes.
For example, (org-fold-next-folding-state-change nil) with point
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

If SPEC-OR-ELEMENT is a folding spec symbol, only consider that folded spec.
If SPEC-OR-ELEMENT is a foldable element, consider that element's
folding spec (see `org-fold-get-folding-spec-for-element').  Note that
multiple elements may have the same folding spec.

If SPEC-OR-ELEMENT is a list, only consider changes of folding states
from the list.

Search backwards when PREVIOUS-P is non-nil."
  (when (and spec-or-element (symbolp spec-or-element))
    (setq spec-or-element (list spec-or-element)))
  (when spec-or-element
    (setq spec-or-element
	  (mapcar (lambda (spec-or-element)
		    (or (org-fold-get-folding-spec-for-element spec-or-element)
			spec-or-element))
                  spec-or-element))
    (mapc #'org-fold--check-spec spec-or-element))
  (unless spec-or-element
    (setq spec-or-element org-fold--spec-priority-list))
  (let* ((pos (or pos (point)))
	 (props (mapcar (lambda (el) (org-fold--property-symbol-get-create el nil t))
			spec-or-element))
         (cmp (if previous-p
		  #'max
		#'min))
         (next-change (if previous-p
			  (lambda (prop) (max (or limit (point-min)) (previous-single-char-property-change pos prop nil (or limit (point-min)))))
			(lambda (prop) (next-single-char-property-change pos prop nil (or limit (point-max)))))))
    (apply cmp (mapcar next-change props))))

(defun org-fold-previous-folding-state-change (&optional spec-or-element pos limit)
  "Call `org-fold-next-folding-state-change' searching backwards."
  (org-fold-next-folding-state-change spec-or-element pos limit 'previous))

(defun org-fold-search-forward (spec &optional limit)
  "Search next region folded via folding SPEC up to LIMIT.
Move point right after the end of the region, to LIMIT, or
`point-max'.  The `match-data' will contain the region."
  (org-fold--check-spec spec)
  (let ((prop-symbol (org-fold--property-symbol-get-create spec nil t)))
    (goto-char (or (next-single-char-property-change (point) prop-symbol nil limit) limit (point-max)))
    (when (and (< (point) (or limit (point-max)))
	       (not (org-fold-get-folding-spec spec)))
      (goto-char (next-single-char-property-change (point) prop-symbol nil limit)))
    (when (org-fold-get-folding-spec spec)
      (let ((region (org-fold-get-region-at-point spec)))
	(when (< (cdr region) (or limit (point-max)))
	  (goto-char (1+ (cdr region)))
          (set-match-data (list (set-marker (make-marker) (car region) (current-buffer))
				(set-marker (make-marker) (cdr region) (current-buffer)))))))))

;;;; Changing visibility (regions, blocks, drawers, headlines)

;;;;; Region visibility

;; This is the core function performing actual folding/unfolding.  The
;; folding state is stored in text property (folding property)
;; returned by `org-fold--property-symbol-get-create'.  The value of the
;; folding property is folding spec symbol.
(defun org-fold-region (from to flag &optional spec-or-element)
  "Hide or show lines from FROM to TO, according to FLAG.
SPEC-OR-ELEMENT is the folding spec or foldable element, as a symbol.
If SPEC-OR-ELEMENT is omitted and FLAG is nil, unfold everything in the region."
  (let ((spec (or (org-fold-get-folding-spec-for-element spec-or-element)
		  spec-or-element)))
    (when spec (org-fold--check-spec spec))
    (with-silent-modifications
      (org-with-wide-buffer
       (if flag
	   (if (not spec)
               (error "Calling `org-fold-region' with missing SPEC")
	     (put-text-property from to
				(org-fold--property-symbol-get-create spec)
				spec)
	     (put-text-property from to
				'isearch-open-invisible
				#'org-fold--isearch-show)
	     (put-text-property from to
				'isearch-open-invisible-temporary
				#'org-fold--isearch-show-temporary))
	 (if (not spec)
             (dolist (spec org-fold--spec-priority-list)
               (remove-text-properties from to
				       (list (org-fold--property-symbol-get-create spec) nil)))
	   (remove-text-properties from to
				   (list (org-fold--property-symbol-get-create spec) nil))))))))

(defun org-fold-show-all (&optional types)
  "Show all contents in the visible part of the buffer.
By default, the function expands headings, blocks and drawers.
When optional argument TYPES is a list of symbols among `blocks',
`drawers' and `headings', to only expand one specific type."
  (interactive)
  (dolist (type (or types '(blocks drawers headings)))
    (org-fold-region (point-min) (point-max) nil
		     (pcase type
		       (`blocks 'block)
		       (`drawers 'drawer)
		       (`headings 'headline)
		       (_ (error "Invalid type: %S" type))))))

;;;;; Reveal point location

(defun org-fold-show-context (&optional key)
  "Make sure point and context are visible.
Optional argument KEY, when non-nil, is a symbol.  See
`org-fold-show-context-detail' for allowed values and how much is to
be shown."
  (org-fold-show-set-visibility
   (cond ((symbolp org-fold-show-context-detail) org-fold-show-context-detail)
	 ((cdr (assq key org-fold-show-context-detail)))
	 (t (cdr (assq 'default org-fold-show-context-detail))))))

(defun org-fold-show-set-visibility (detail)
  "Set visibility around point according to DETAIL.
DETAIL is either nil, `minimal', `local', `ancestors', `lineage',
`tree', `canonical' or t.  See `org-fold-show-context-detail' for more
information."
  ;; Show current heading and possibly its entry, following headline
  ;; or all children.
  (if (and (org-at-heading-p) (not (eq detail 'local)))
      (org-fold-heading nil)
    (org-fold-show-entry)
    ;; If point is hidden make sure to expose it.
    (when (org-fold-folded-p)
      (let ((region (org-fold-get-region-at-point)))
	(org-fold-region (car region) (cdr region) nil)))
    (unless (org-before-first-heading-p)
      (org-with-limited-levels
       (cl-case detail
	 ((tree canonical t) (org-fold-show-children))
	 ((nil minimal ancestors))
	 (t (save-excursion
	      (outline-next-heading)
	      (org-fold-heading nil)))))))
  ;; Show all siblings.
  (when (eq detail 'lineage) (org-fold-show-siblings))
  ;; Show ancestors, possibly with their children.
  (when (memq detail '(ancestors lineage tree canonical t))
    (save-excursion
      (while (org-up-heading-safe)
	(org-fold-heading nil)
	(when (memq detail '(canonical t)) (org-fold-show-entry))
	(when (memq detail '(tree canonical t)) (org-fold-show-children))))))

(defun org-fold-reveal (&optional siblings)
  "Show current entry, hierarchy above it, and the following headline.

This can be used to show a consistent set of context around
locations exposed with `org-fold-show-context'.

With optional argument SIBLINGS, on each level of the hierarchy all
siblings are shown.  This repairs the tree structure to what it would
look like when opened with hierarchical calls to `org-cycle'.

With a \\[universal-argument] \\[universal-argument] prefix, \
go to the parent and show the entire tree."
  (interactive "P")
  (run-hooks 'org-fold-reveal-start-hook)
  (cond ((equal siblings '(4)) (org-fold-show-set-visibility 'canonical))
	((equal siblings '(16))
	 (save-excursion
	   (when (org-up-heading-safe)
	     (org-fold-show-subtree)
	     (run-hook-with-args 'org-cycle-hook 'subtree))))
	(t (org-fold-show-set-visibility 'lineage))))

;;; Internal functions

(defun org-fold--check-spec (spec)
  "Throw an error if SPEC is not present in `org-fold--spec-priority-list'."
  (unless (and spec (memq spec org-fold--spec-priority-list))
    (error "%s is not a valid folding spec" spec)))

;;; Make isearch search in some text hidden via text propertoes

(defvar org-fold--isearch-overlays nil
  "List of overlays temporarily created during isearch.
This is used to allow searching in regions hidden via text properties.
As for [2020-05-09 Sat], Isearch only has special handling of hidden overlays.
Any text hidden via text properties is not revealed even if `search-invisible'
is set to 't.")

(defvar-local org-fold--isearch-local-regions (make-hash-table :test 'equal)
  "Hash table storing temporarily shown folds from isearch matches.")

(defun org-fold--isearch-setup (type)
  "Initialize isearch in org buffer.
TYPE can be either `text-properties' or `overlays'."
  (pcase type
    (`text-properties
     (setq-local search-invisible 'open-all)
     (add-hook 'isearch-mode-end-hook #'org-fold--clear-isearch-state nil 'local)
     (add-hook 'isearch-mode-hook #'org-fold--clear-isearch-state nil 'local)
     (setq-local isearch-filter-predicate #'org-fold--isearch-filter-predicate-text-properties))
    (`overlays
     (setq-local isearch-filter-predicate #'org-fold--isearch-filter-predicate-overlays)
     (add-hook 'isearch-mode-end-hook #'org-fold--clear-isearch-overlays nil 'local))
    (_ (error "%s: Unknown type of setup for `org-fold--isearch-setup'" type))))

(defun org-fold--isearch-filter-predicate-text-properties (beg end)
  "Make sure that text hidden by any means other than `org-fold--isearch-specs' is not searchable.
This function is intended to be used as `isearch-filter-predicate'."
  (and
   ;; Check folding specs that cannot be searched
   (seq-every-p (lambda (spec) (member spec org-fold--isearch-specs)) (org-fold-get-folding-specs-in-region beg end))
   ;; Check 'invisible properties that are not folding specs
   (or (eq search-invisible t) ; User wants to search, allow it
       (let ((pos beg)
	     unknown-invisible-property)
	 (while (and (< pos end)
		     (not unknown-invisible-property))
	   (when (and (get-text-property pos 'invisible)
		      (not (member (get-text-property pos 'invisible) org-fold--isearch-specs)))
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
	      (org-fold--isearch-show-temporary (cons beg end) nil)))
       (not (isearch-range-invisible beg end)))))

(defun org-fold--clear-isearch-state ()
  "Clear `org-fold--isearch-local-regions'."
  (clrhash org-fold--isearch-local-regions))

(defun org-fold--isearch-show (region)
  "Reveal text in REGION found by isearch."
  (org-with-point-at (car region)
    (while (< (point) (cdr region))
      (org-fold-show-set-visibility 'isearch)
      (goto-char (org-fold-next-visibility-change (point) (cdr region) 'ignore-hidden)))))

(defun org-fold--isearch-show-temporary (region hide-p)
  "Temporarily reveal text in REGION.
Hide text instead if HIDE-P is non-nil."
  (if (not hide-p)
      (let ((pos (car region)))
	(while (< pos (cdr region))
	  (dolist (spec (org-fold-get-folding-spec 'all pos))
	    (push (cons spec (org-fold-get-region-at-point spec pos)) (gethash region org-fold--isearch-local-regions)))
          (org-fold--isearch-show region)
	  (setq pos (org-fold-next-folding-state-change nil pos (cdr region)))))
    (mapc (lambda (val) (org-fold-region (cadr val) (cddr val) t (car val))) (gethash region org-fold--isearch-local-regions))
    (remhash region org-fold--isearch-local-regions)))

(defun org-fold--create-isearch-overlays (beg end)
  "Replace text property invisibility spec by overlays between BEG and END.
All the regions with invisibility text property spec from
`org-fold--isearch-specs' will be changed to use overlays instead
of text properties.  The created overlays will be stored in
`org-fold--isearch-overlays'."
  (let ((pos beg))
    (while (< pos end)
      ;; We need loop below to make sure that we clean all invisible
      ;; properties, which may be nested.
      (while (memq (get-text-property pos 'invisible) org-fold--isearch-specs)
	(let* ((spec (get-text-property pos 'invisible))
               (region (org-find-text-property-region pos (org-fold--property-symbol-get-create spec nil t))))
	  ;; Changing text properties is considered buffer modification.
	  ;; We do not want it here.
	  (with-silent-modifications
            (org-fold-region (car region) (cdr region) nil spec)
	    ;; The overlay is modelled after `outline-flag-region'
	    ;; [2020-05-09 Sat] overlay for 'outline blocks.
	    (let ((o (make-overlay (car region) (cdr region) nil 'front-advance)))
	      (overlay-put o 'evaporate t)
	      (overlay-put o 'invisible spec)
	      ;; `delete-overlay' here means that spec information will be lost
	      ;; for the region. The region will remain visible.
	      (overlay-put o 'isearch-open-invisible #'delete-overlay)
	      (push o org-fold--isearch-overlays)))))
      (setq pos (next-single-property-change pos 'invisible nil end)))))

(defun org-fold--isearch-filter-predicate-overlays (beg end)
  "Return non-nil if text between BEG and END is deemed visible by isearch.
This function is intended to be used as `isearch-filter-predicate'.
Unlike `isearch-filter-visible', make text with `invisible' text property
value listed in `org-fold--isearch-specs'."
  (org-fold--create-isearch-overlays beg end) ;; trick isearch by creating overlays in place of invisible text
  (isearch-filter-visible beg end))

(defun org-fold--clear-isearch-overlay (ov)
  "Convert OV region back into using text properties."
  (let ((spec (overlay-get ov 'invisible)))
    ;; Ignore deleted overlays.
    (when (and spec
	       (overlay-buffer ov))
      ;; Changing text properties is considered buffer modification.
      ;; We do not want it here.
      (with-silent-modifications
	(when (< (overlay-end ov) (point-max))
	  (org-fold-region (overlay-start ov) (overlay-end ov) t spec)))))
  (when (member ov isearch-opened-overlays)
    (setq isearch-opened-overlays (delete ov isearch-opened-overlays)))
  (delete-overlay ov))

(defun org-fold--clear-isearch-overlays ()
  "Convert overlays from `org--isearch-overlays' back into using text properties."
  (when org-fold--isearch-overlays
    (mapc #'org-fold--clear-isearch-overlay org-fold--isearch-overlays)
    (setq org-fold--isearch-overlays nil)))

;;; Handling changes in folded elements

(defvar-local org-fold--last-buffer-chars-modified-tick nil
  "Variable storing the last return value of `buffer-chars-modified-tick'.")

(defun org-fold--fix-folded-region (from to _)
  "Process modifications in folded elements within FROM . TO region.
This function intended to be used as one of `after-change-functions'.

This function does nothing if text the only modification was changing
text properties (for the sake of reducing overheads).

If a text was inserted into invisible region, hide the inserted text.
If the beginning/end line of a folded drawer/block was changed, unfold it.
If a valid end line was inserted in the middle of the folded drawer/block, unfold it."
  ;; If no insertions or deletions in buffer, skip all the checks.
  (unless (eq org-fold--last-buffer-chars-modified-tick (buffer-chars-modified-tick))
    (save-match-data
      ;; Store the new buffer modification state.
      (setq org-fold--last-buffer-chars-modified-tick (buffer-chars-modified-tick))
      ;; Re-hide text inserted in the middle of a folded region.
      (unless (equal from to) ; Ignore deletions.
	(dolist (spec org-fold--spec-priority-list)
	  (let ((spec-to (org-fold-get-folding-spec spec (min to (1- (point-max)))))
		(spec-from (org-fold-get-folding-spec spec (max (point-min) (1- from)))))
	    (when (and spec-from spec-to (eq spec-to spec-from))
	      (org-fold-region from to t (or spec-from spec-to))))))
      ;; Re-hide text inserted right in front (but not at the back) of a
      ;; folded region.
      ;; Examples: beginning of a folded drawer, first line of folded
      ;; headline (schedule).  However, do not hide headline text.
      (unless (equal from to)
	(when (or
	       ;; Prepending to folded headline, block, or drawer.
	       (and (not (org-fold-folded-p (max (point-min) (1- from))))
		    (org-fold-folded-p to)
		    (not (org-at-heading-p)))
	       ;; Appending to folded headline. We cannot append to
	       ;; folded block or drawer though.
               (and (org-fold-folded-p (max (point-min) (1- from)) 'headline)
		    (not (org-fold-folded-p to))))
	  (org-fold-region from to t (or
				      ;; Only headline spec for appended text.
				      (org-fold-get-folding-spec 'headline (max (point-min) (1- from)))
				      (org-fold-get-folding-spec nil to)))))
      ;; Reveal the whole region if inserted in the middle of
      ;; visible text. This is needed, for example, when one is
      ;; trying to copy text from indirect buffer to main buffer. If
      ;; the text is unfolded in the indirect buffer, but folded in
      ;; the main buffer, the text properties responsible for
      ;; folding will be activated as soon as the text is pasted
      ;; into the main buffer. Thus, we need to unfold the inserted
      ;; text to make org-mode behave as expected (the inserted text
      ;; is visible).
      ;; FIXME: this breaks when replacing buffer/region contents - we do not need to unfold in that case
      ;; (unless (equal from to)
      ;;   (when (and (not (org-fold-folded-p (max (point-min) (1- from)))) (not (org-fold-folded-p to)))
      ;;     (org-fold-region from to nil)))
      ;; Process all the folded text between `from' and `to'.
      (org-with-wide-buffer
       ;; If the edit is done in the first line of a folded drawer/block,
       ;; the folded text is only starting from the next line and needs to
       ;; be checked.
       (setq to (save-excursion (goto-char to) (line-beginning-position 2)))
       ;; If the ":END:" line of the drawer is deleted, the folded text is
       ;; only ending at the previous line and needs to be checked.
       (setq from (save-excursion (goto-char from) (line-beginning-position 0)))
       ;; Expand the considered region to include partially present folded
       ;; drawer/block.
       (when (org-fold-get-folding-spec (org-fold-get-folding-spec-for-element 'drawer) from)
	 (setq from (org-fold-previous-folding-state-change (org-fold-get-folding-spec-for-element 'drawer) from)))
       (when (org-fold-get-folding-spec (org-fold-get-folding-spec-for-element 'block) from)
	 (setq from (org-fold-previous-folding-state-change (org-fold-get-folding-spec-for-element 'block) from)))
       (when (org-fold-get-folding-spec (org-fold-get-folding-spec-for-element 'drawer) to)
	 (setq to (org-fold-next-folding-state-change (org-fold-get-folding-spec-for-element 'drawer) to)))
       (when (org-fold-get-folding-spec (org-fold-get-folding-spec-for-element 'block) to)
	 (setq from (org-fold-next-folding-state-change (org-fold-get-folding-spec-for-element 'block) to)))
       ;; Check folded drawers and blocks.
       (dolist (spec (list (org-fold-get-folding-spec-for-element 'drawer) (org-fold-get-folding-spec-for-element 'block)))
	 (let ((pos from)
	       (begin-re (cond
			  ((eq spec (org-fold-get-folding-spec-for-element 'drawer))
			   org-drawer-regexp)
			  ;; Group one below contains the type of the block.
			  ((eq spec (org-fold-get-folding-spec-for-element 'block))
			   (rx bol (zero-or-more (any " " "\t"))
			       "#+begin"
			       (or ":"
				   (seq "_"
					(group (one-or-more (not (syntax whitespace))))))))))
               ;; To be determined later. May depend on `begin-re' match (i.e. for blocks).
               end-re)
	   ;; Move to the first hidden drawer/block.
	   (unless (org-fold-get-folding-spec spec pos)
	     (setq pos (org-fold-next-folding-state-change spec pos to)))
	   ;; Cycle over all the hidden drawers/blocks.
	   (while (< pos to)
	     (save-match-data ; we should not clobber match-data in after-change-functions
	       (let ((fold-begin (and (org-fold-get-folding-spec spec pos)
				      pos))
		     (fold-end (org-fold-next-folding-state-change spec pos to)))
		 (when (and fold-begin fold-end)
		   (let (unfold?)
		     (catch :exit
		       ;; The line before folded text should be beginning of
		       ;; the drawer/block.
		       (save-excursion
			 (goto-char fold-begin)
			 ;; The line before beginning of the fold should be the
			 ;; first line of the drawer/block.
			 (backward-char)
			 (beginning-of-line)
			 (unless (let ((case-fold-search t))
				   (looking-at begin-re)) ; the match-data will be used later
			   (throw :exit (setq unfold? t))))
                       ;; Set `end-re' for the current drawer/block.
                       (setq end-re
			     (cond
			      ((eq spec (org-fold-get-folding-spec-for-element 'drawer))
                               org-property-end-re)
			      ((eq spec (org-fold-get-folding-spec-for-element 'block))
			       (let ((block-type (match-string 1))) ; the last match is from `begin-re'
				 (concat (rx bol (zero-or-more (any " " "\t")) "#+end")
					 (if block-type
					     (concat "_"
						     (regexp-quote block-type)
						     (rx (zero-or-more (any " " "\t")) eol))
					   (rx (opt ":") (zero-or-more (any " " "\t")) eol)))))))
		       ;; The last line of the folded text should match `end-re'.
		       (save-excursion
			 (goto-char fold-end)
			 (beginning-of-line)
			 (unless (let ((case-fold-search t))
				   (looking-at end-re))
			   (throw :exit (setq unfold? t))))
		       ;; there should be no `end-re' or
		       ;; `org-outline-regexp-bol' anywhere in the
		       ;; drawer/block body.
		       (save-excursion
			 (goto-char fold-begin)
			 (when (save-excursion
				 (let ((case-fold-search t))
				   (re-search-forward (rx (or (regex end-re)
							      (regex org-outline-regexp-bol)))
						      (max (point)
							   (1- (save-excursion
								 (goto-char fold-end)
								 (line-beginning-position))))
						      't)))
			   (throw :exit (setq unfold? t)))))
		     (when unfold?
		       (org-fold-region fold-begin fold-end nil spec)))
		   (goto-char fold-end))))
	     ;; Move to next hidden drawer/block.
	     (setq pos
		   (org-fold-next-folding-state-change spec to)))))))))

;; Catching user edits inside invisible text
(defun org-fold-check-before-invisible-edit (kind)
  "Check is editing if kind KIND would be dangerous with invisible text around.
The detailed reaction depends on the user option `org-fold-catch-invisible-edits'."
  ;; First, try to get out of here as quickly as possible, to reduce overhead
  (when (and org-fold-catch-invisible-edits
	     (or (not (boundp 'visible-mode)) (not visible-mode))
	     (or (org-invisible-p)
		 (org-invisible-p (max (point-min) (1- (point))))))
    ;; OK, we need to take a closer look.  Only consider invisibility
    ;; caused by folding.
    (let* ((invisible-at-point (org-fold-folded-p))
	   ;; Assume that point cannot land in the middle of an
	   ;; overlay, or between two overlays.
	   (invisible-before-point
	    (and (not invisible-at-point)
		 (not (bobp))
		 (org-fold-folded-p (1- (point)))))
	   (border-and-ok-direction
	    (or
	     ;; Check if we are acting predictably before invisible
	     ;; text.
	     (and invisible-at-point
		  (memq kind '(insert delete-backward)))
	     ;; Check if we are acting predictably after invisible text
	     ;; This works not well, and I have turned it off.  It seems
	     ;; better to always show and stop after invisible text.
	     (and (not invisible-at-point) invisible-before-point
		  (memq kind '(insert delete)))
	     )))
      (when (or invisible-at-point invisible-before-point)
	(when (eq org-fold-catch-invisible-edits 'error)
	  (user-error "Editing in invisible areas is prohibited, make them visible first"))
	(if (and org-custom-properties-hidden-p
		 (y-or-n-p "Display invisible properties in this buffer? "))
	    (org-toggle-custom-properties-visibility)
	  ;; Make the area visible
          (save-excursion
	    (org-fold-show-set-visibility 'local))
          (when invisible-before-point
            (org-with-point-at (1- (point)) (org-fold-show-set-visibility 'local)))
	  (cond
	   ((eq org-fold-catch-invisible-edits 'show)
	    ;; That's it, we do the edit after showing
	    (message
	     "Unfolding invisible region around point before editing")
	    (sit-for 1))
	   ((and (eq org-fold-catch-invisible-edits 'smart)
		 border-and-ok-direction)
	    (message "Unfolding invisible region around point before editing"))
	   (t
	    ;; Don't do the edit, make the user repeat it in full visibility
	    (user-error "Edit in invisible region aborted, repeat to confirm with text visible"))))))))

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
(defun org-fold--buffer-substring-filter (beg end &optional delete)
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
      (dolist (plist
	       ;; Yes, it is a hack.
               ;; The below gives us string representation as a list.
               (let ((data (read (replace-regexp-in-string "#" "" (format "%S" return-string)))))
		 (if (listp data) data (list data))))
	;; Only lists contain text properties.
	(when (listp plist)
	  ;; Collect all the relevant text properties.
	  (while plist
            (let* ((prop (car plist))
		   (prop-name (symbol-name prop)))
              ;; We do not care about values.
              (setq plist (cddr plist))
              (when (string-match-p "org-fold--spec" prop-name)
		;; Leave folding specs from current buffer.  See comments
		;; in `org-fold--property-symbol-get-create' to understand why it
		;; works.
		(unless (member prop (alist-get 'invisible char-property-alias-alist))
		  (push t props-list)
		  (push prop props-list)))))))
      (remove-text-properties 0 (length return-string) props-list return-string))
    return-string))

(provide 'org-fold)

;;; org-fold.el ends here