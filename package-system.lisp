;;;; -------------------------------------------------------------------------
;;;; Package systems in the style of quick-build or faslpath

(uiop:define-package :asdf/package-system
  (:recycle :asdf/package-system :asdf)
  (:use :uiop/common-lisp :uiop
        :asdf/defsystem ;; Using the old name of :asdf/parse-defsystem for compatibility
        :asdf/upgrade :asdf/component :asdf/system :asdf/find-system :asdf/lisp-action)
  (:export
   #:package-system #:register-system-packages #:sysdef-package-system-search
   #:*defpackage-forms* #:*package-systems*))
(in-package :asdf/package-system)

(with-upgradability ()
  (defparameter *defpackage-forms* '(cl:defpackage uiop:define-package))

  (defun initial-package-systems-table ()
    (let ((h (make-hash-table :test 'equal)))
      (dolist (p (list-all-packages))
        (dolist (n (package-names p))
          (setf (gethash n h) t)))
      h))

  (defvar *package-systems* (initial-package-systems-table))

  (defclass package-system (system)
    ())

  (defun defpackage-form-p (form)
    (and (consp form)
         (member (car form) *defpackage-forms*)))

  (defun stream-defpackage-form (stream)
    (loop :for form = (read stream)
          :when (defpackage-form-p form)
            :return form))

  (defun file-defpackage-form (file)
    (with-input-file (f file)
      (stream-defpackage-form f)))

  (defun package-dependencies (defpackage-form)
    (assert (defpackage-form-p defpackage-form))
    (remove-duplicates
     (while-collecting (dep)
       (loop* :for (option . arguments) :in (cddr defpackage-form) :do
              (ecase option
                ((:use :mix :reexport :use-reexport :mix-reexport)
                 (dolist (p arguments) (dep (string p))))
                ((:import-from :shadowing-import-from)
                 (dep (string (first arguments))))
                ((:nicknames :documentation :shadow :export :intern :unintern :recycle)))))
     :from-end t :test 'equal))

  (defun package-designator-name (package)
    (etypecase package
      (package (package-name package))
      (string package)
      (symbol (string package))))

  (defun register-system-packages (system packages)
    (let ((name (or (eq system t) (coerce-name system))))
      (dolist (p (ensure-list packages))
        (setf (gethash (package-designator-name p) *package-systems*) name))))

  (defun package-name-system (package-name)
    (check-type package-name string)
    (if-let ((system-name (gethash package-name *package-systems*)))
      system-name
      (string-downcase package-name)))

  (defun package-system-file-dependencies (file)
    (let* ((defpackage-form (file-defpackage-form file))
           (package-dependencies (package-dependencies defpackage-form)))
      (remove t (mapcar 'package-name-system package-dependencies))))

  (defun same-package-system-p (system name directory subpath dependencies)
    (and (eq (type-of system) 'package-system)
         (equal (component-name system) name)
         (pathname-equal directory (component-pathname system))
         (equal dependencies (component-sideway-dependencies system))
         (let ((children (component-children system)))
           (and (length=n-p children 1)
                (let ((child (first children)))
                  (and (eq (type-of child) 'cl-source-file)
                       (equal (component-name child) "lisp")
                       (and (slot-boundp child 'relative-pathname)
                            (equal (slot-value child 'relative-pathname) subpath))))))))

  (defun sysdef-package-system-search (system)
    (let ((primary (primary-system-name system)))
      (unless (equal primary system)
        (let ((top (find-system primary nil)))
          (when (typep top 'package-system)
            (if-let (dir (system-source-directory top))
              (let* ((sub (subseq system (1+ (length primary))))
                     (f (probe-file* (subpathname dir sub :type "lisp")
                                     :truename *resolve-symlinks*)))
                (when (file-pathname-p f)
                  (let ((dependencies (package-system-file-dependencies f))
                        (previous (cdr (system-registered-p system))))
                    (if (same-package-system-p previous system dir sub dependencies)
                        previous
                        (eval `(defsystem ,system
                                 :class package-system
                                 :source-file nil
                                 :pathname ,dir
                                 :depends-on ,dependencies
                                 :components ((cl-source-file "lisp" :pathname ,sub)))))))))))))))

(with-upgradability ()
  (pushnew 'sysdef-package-system-search *system-definition-search-functions*))
