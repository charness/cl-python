;; -*- package: clpython; readtable: py-user-readtable -*-
;; 
;; This software is Copyright (c) Franz Inc. and Willem Broekema.
;; Franz Inc. and Willem Broekema grant you the rights to
;; distribute and use this software as governed by the terms
;; of the Lisp Lesser GNU Public License
;; (http://opensource.franz.com/preamble.html),
;; known as the LLGPL.

(in-package :clpython)
(in-syntax *user-readtable*)

(defvar *py-compiled-file-type* "FASL"
  "File types of compiled Python files, in :common pathname case")

(defvar *py-source-file-types* '("PY" "LISP" "CL")
  "File types of source Python files, in :common pathname case")

(defvar *package-indicator-filename* "__INIT__"
  "File that indicates a directory is a package, in :common pathname case")

;; Pathname handling is as suggested by Kent Pitman on comp.lang.lisp
;; <sfwzo21um0k.fsf@shell01.TheWorld.com>

(defun derive-pathname (pathname &key (type      (pathname-type pathname      :case :common))
                                      (name      (pathname-name pathname      :case :common))
                                      (host      (pathname-host pathname      :case :common))
                                      (device    (pathname-device pathname    :case :common))
                                      (directory (pathname-directory pathname :case :common))
                                      (version   (pathname-version pathname)))
  (make-pathname :type type :name name :host host :device device
                 :directory directory :version version :case :common))

(defun source-file-names (kind modname filepath)
  (check-type modname string)
  (loop for file-type in *py-source-file-types*
      collect (ecase kind
                (:module (derive-pathname
                          filepath
                          :name (pathname-name modname :case :common) :type file-type))
                (:package (merge-pathnames
                           (make-pathname :directory `(:relative ,(pathname-name modname :case :common))
                                          :case :common)
                           (derive-pathname filepath
                                            :type file-type
                                            :name *package-indicator-filename*))))))

(defparameter *use-asdf-binary-locations* t
  "Whether to store fasl files in directory determined by asdf-binary-locations.")

(defgeneric compiled-file-name (kind modname filepath &key include-dir create-dir)
  (:method :around (kind modname filepath &key include-dir create-dir)
           (declare (ignore include-dir filepath kind))
           (check-type modname string)
           (let ((bin-path (call-next-method))
                 bin-path-2)
             (when *use-asdf-binary-locations*
               (setf bin-path-2 
                 (ignore-errors
                  (let ((new-path (car (asdf:output-files
                                        (make-instance 'asdf:compile-op)
                                        (make-instance 'asdf:cl-source-file
                                          :parent (asdf:find-system :clpython)
                                          :pathname bin-path)))))
                    (when (and new-path create-dir)
                      (setf new-path (ensure-directories-exist new-path)))))))
             (or bin-path-2 bin-path)))
  
  (:method ((kind (eql :module)) modname filepath &key include-dir create-dir)
           (declare (ignore include-dir create-dir))
           (derive-pathname filepath
                            :name (pathname-name modname :case :common)
                            :type *py-compiled-file-type* ))
  
  (:method ((kind (eql :package)) modname filepath &key (include-dir t) create-dir)
           (declare (ignore create-dir))
           (merge-pathnames
            (if include-dir
                (make-pathname :directory `(:relative ,(pathname-name modname :case :common))
                               :case :common)
              modname)
            (derive-pathname filepath
                             :type *py-compiled-file-type* 
                             :name *package-indicator-filename*))))
  
(defun lisp-package-as-py-module (modname)
  "Return Lisp package with given name.
First a package with that name as subpackage of CLPYTHON.MODULE is searched.
Otherwise a package with MODNAME as regular name.
As for case: both MODNAME's own name its upper-case variant are tried."
  (check-type modname symbol)
  (let ((variants (list (symbol-name modname) (string-upcase modname))))
    (dolist (v variants)
      (whereas ((pkg (or (find-package (concatenate 'string
                                         (string (package-name :clpython.module)) "." v))
                         (find-package v))))
        (return-from lisp-package-as-py-module pkg)))))

(defun find-py-file (name search-paths &key must-be-package)
  "Finds for source or fasl file in SEARCH-PATHS, returning earliest match.
Returns values KIND SRC-PATH BIN-PATH FIND-PATH, or NIL if not found,
with KIND one of :module, :package
      SRC-PATH, BIN-PATH the truenames of the existing files."
  (loop for path in search-paths
      for src-path = (find-if #'probe-file (source-file-names :module name path))
      for bin-path = (find-if #'probe-file (list (compiled-file-name :module name path)))
      for pkg-src-path = (find-if #'probe-file (source-file-names :package name path))
      for pkg-bin-path = (find-if #'probe-file (list (compiled-file-name :package name path)))
			 
      if (and (not must-be-package)
              (or src-path bin-path))
      return (values :module
                     (when src-path (probe-file src-path))
                     (when bin-path (probe-file bin-path))
                     path)
      else if (or pkg-src-path pkg-bin-path)
      return (values :package
                     (when pkg-src-path (probe-file pkg-src-path))
                     (when pkg-bin-path (probe-file pkg-bin-path))
                     path)))

(defparameter *import-force-recompile* nil)
(defparameter *import-force-reload*    nil)
(defparameter *import-compile-verbose* #+sbcl nil #-sbcl t)
(defparameter *import-load-verbose*    t)

(defmacro with-python-code-reader (() &body body)
  ;; The Python parser handles all reading.
  `(handler-bind
       ((error (lambda (c)
                 (signal c)
                 ;; ERROR with normal *readtable*, otherwise interactive
                 ;; debugging becomes impossible.
                 (with-standard-io-syntax (error c)))))
     (let ((*readtable* (load-time-value 
                         (setup-omnivore-readmacro :function #'clpython.parser:parse
                                                   :package (find-package :clpython)
                                                   :readtable (copy-readtable nil)))))
       ,@body)))

(defun %compile-py-file (filename &key (mod-name (error ":mod-name required"))
                                       (output-file (error ":output-file required")))
  "Compile Python source file into FASL. Source file must exist.
Caller is responsible for deciding if recompiling is really necessary."
  (check-type filename pathname)
  (assert (probe-file filename) (filename)
    "Python source file ~A does not exist" filename)
  (let ((*current-module-path* filename) ;; used by compiler
        (*current-module-name* mod-name))
    (with-auto-mode-recompile (:verbose *import-compile-verbose*)
      (with-python-code-reader ()
        (handler-bind (#+sbcl(sb-int:simple-compiler-note #'muffle-warning))
          (compile-file filename
                        :output-file output-file
                        :verbose *import-compile-verbose*))))))

(defun %load-compiled-python-file (bin-filename
                                   &key (mod-name (error ":mod-name required"))
                                        (context-mod-name mod-name)
                                        (habitat (error "habitat required"))
                                        (update-existing-mod t))
  "Loads and registers given compiled Python file.
Returns the loaded module, or NIL on error."
  (check-type bin-filename pathname)
  (check-type mod-name (or symbol string))
  (check-type context-mod-name (or symbol string))
  (assert (probe-file bin-filename))
  (let* ((old-module (when habitat (get-loaded-module :bin-pathname bin-filename :habitat habitat))))
    (flet ((do-loading ()
	     (let* (new-module
                    module-function
                    (*module-function-hook* (lambda (f) (setf module-function f)))
		    (*module-preload-hook* (lambda (mod)
                                             (setf new-module mod)
                                             ;; Need to register module before it is fully loaded,
                                             ;; otherwise infinite recursion if two modules import
                                             ;; each other.
                                             (add-loaded-module mod habitat))))
               (with-auto-mode-recompile (:verbose *import-load-verbose*)
		   (unless (load bin-filename :verbose *import-load-verbose*)
                     ;; Might happen if loading fails and there is a restart that lets LOAD return NIL.
                     (return-from %load-compiled-python-file)))
               (if module-function
                   (progn (let ((*current-module-name* mod-name))
                            (declare (special *current-module-name*))
                            (loop named execute-toplevel
                                do (with-simple-restart
                                       (continue "Retry evaluating top-level forms in module `~A'" mod-name)
                                     (funcall module-function)
                                     (return-from execute-toplevel))))
                          ;; XXX call module-function with :%module-globals if updating existing mod
                          (unless new-module
                            (break "CLPython bug: module ~A did not call *module-preload-hook* upon loading"
                                   mod-name))
                          (when (and old-module update-existing-mod)
                            (copy-module-contents :from new-module :to old-module)
                            (setf new-module old-module))
                          (values new-module t))
                 (progn (warn "The FASL of module ~A was not produced by CLPython ~
                               (or CLPython bug: module did not call *module-function-hook*)." mod-name)
                        (values (make-instance 'module :name "non-Python fasl" :bin-pathname bin-filename)
                                t))))))
      (let (new-module success)
        (unwind-protect
            (progn (multiple-value-setq (new-module success)
                     (do-loading))
                   (assert success) ;; Second value is sanity check
                   new-module)
          (unless success
            ;; Remove exactly this version of the module from the list of loaded modules.
            ;; If there was an other (older) version of the module, it's still there.
            (remove-loaded-module :bin-pathname bin-filename
                                  :bin-file-write-date (file-write-date bin-filename)
                                  :habitat habitat)))))))

(defun module-dotted-name (list-name)
  (format nil "~{~A~^.~}" list-name))

(defvar #1=cl-user::*clpython-module-search-paths* (when (boundp '#1#) #1#)
  "Default search paths for imported modules. Should at least contain the location
of the Python stanard libraries. (This variable is in the CL-USER package to allow
it being set before CLPython is loaded, e.g. in a Lisp configuration file.)")

(defun maybe-warn-set-search-paths (at-error)
  (cond ((or (not (boundp 'cl-user::*clpython-module-search-paths*))
             (not cl-user::*clpython-module-search-paths*))
         (format t "~%;; Consider customizing variable ~S
;; to be a list of paths that are tried when locating a module in order to import it
;; (in addition to the current directory and `sys.path'). Typically it should at least
;; contain the path to the Python (2.5) standard libraries, as those are not
;; distributed with CLPython.
"
               'cl-user::*clpython-module-search-paths*))
        ((not at-error)
         (format t "Using ~A default module search paths set in ~S~%"
                 (length cl-user::*clpython-module-search-paths*)
                 'cl-user::*clpython-module-search-paths*))))

(defun calc-import-search-paths ()
  ;; Use current directory and `sys.path' as search paths (in that order)
  ;; XXX sys.path is now shared between all habitats; should perhaps be habitat-specific
  (append (py-iterate->lisp-list (habitat-search-paths *habitat*))
          cl-user::*clpython-module-search-paths*))

(defvar *import-recompiled-files* nil
  "The fasl files created by the current (parent) import action.
Used to avoid infinite recompilation/reloading loops.")

(defun py-import (mod-name-as-list 
		  &rest options
		  &key must-be-package
                       (habitat (or *habitat* (error "PY-IMPORT called without habitat")))
		       (force-reload *import-force-reload*)
                       (force-recompile *import-force-recompile*)
                       within-mod-path
                       within-mod-name
		       (search-paths (calc-import-search-paths))
                       (%outer-mod-name-as-list mod-name-as-list)
                       (*import-recompiled-files* (or *import-recompiled-files*
                                                      (make-hash-table :test 'equal))))
  "Returns the (sub)module, which may have been freshly imported, or raises ImportError."
  (declare (special *habitat*)
           (optimize (debug 3)))
  (check-type mod-name-as-list list)
  (check-type habitat habitat)
  ;; Builtin modules are represented by Lisp module child packages of clpython.module
  ;; (e.g. clpython.module.sys).
  (when (= (length mod-name-as-list) 1)
    (whereas ((pkg (lisp-package-as-py-module (car mod-name-as-list))))
      (return-from py-import pkg)))
  
  (let* ((just-mod-name (string (car (last mod-name-as-list))))
         (dotted-name (module-dotted-name mod-name-as-list)))

    ;; In case of a dotted import ("import a.b.c"), recursively import the parent "a.b"
    ;; and set the search path to only the location of that package.
    (when (> (length mod-name-as-list) 1)
      (let (parent)
        (unwind-protect
            (setf parent (apply #'py-import (butlast mod-name-as-list)
                                :must-be-package t
                                :%outer-mod-name-as-list %outer-mod-name-as-list
                                options))
          (unless parent
            ;; PY-IMPORT did not import successfully, and we are unwinding.
            ;; No need for an additional ImportError.
            (warn "Could not import module `~A' as importing package `~A' failed.~@[~:@_Import attempted by: ~A~]"
                  dotted-name (module-dotted-name (butlast mod-name-as-list))
                  within-mod-path)))
        (unless (module-package-p parent)
          (py-raise '{ImportError}
                    "Cannot import '~A', as parent '~A' is not a package (it is: ~S)."
                    (module-dotted-name mod-name-as-list)
                    (module-dotted-name (butlast mod-name-as-list))
                    parent))
        (let ((parent-path (module-src-pathname parent)))
          (check-type parent-path pathname)
          (assert (string= (pathname-name parent-path :case :common)
                           *package-indicator-filename*) ()
            "Package ~A should have filepath pointing to the ~A file, but ~
             it is pointing somewhere else: ~A." parent *package-indicator-filename* parent-path)
          (setf search-paths
            (list (derive-pathname parent-path))))))
    
    (let ((find-paths search-paths))
      (when within-mod-path
        (push (truename within-mod-path) find-paths))
      (setf find-paths (remove-duplicates find-paths :test 'equal))
      
      ;; Find the source or fasl file somewhere in the collection of search paths
      (multiple-value-bind (kind src-file bin-file find-path)
          (find-py-file just-mod-name find-paths :must-be-package must-be-package)
        (unless kind
          (maybe-warn-set-search-paths t)
          (py-raise '{ImportError}
                    "Could not find ~A `~A'.~:@_Search paths tried: ~{~S~^, ~_~}~@[~:@_Import ~
                     of `~A' attempted by: ~A~]"
                    (if must-be-package "package" "module/package")
                    just-mod-name search-paths
                    (when within-mod-path (module-dotted-name %outer-mod-name-as-list))
                    within-mod-path))
        
        (assert (member kind '(:module :package)))
        (assert (or src-file bin-file))
        (assert find-path)
        
        ;; If we have a source file, then recompile fasl if outdated.
        (when (and force-recompile (not src-file))
          (warn "Requested recompilation of ~A can not be performed: no source file available."
                bin-file))
        (when src-file
          (setf bin-file (compiled-file-name kind just-mod-name src-file
                                             :include-dir nil :create-dir t))
          (unless (gethash bin-file *import-recompiled-files*)
            (when (or force-recompile
                      (not (probe-file bin-file))
                      (< (file-write-date bin-file)
                         (file-write-date src-file)))
              ;; This would be a good place for a "try recompiling" restart,
              ;; but implementations tend to provide that already.
              (%compile-py-file src-file :mod-name dotted-name :output-file bin-file)
              (setf (gethash bin-file *import-recompiled-files*) t))))
        
        ;; Now we have an up-to-date fasl file.
        (assert (and bin-file (probe-file bin-file)))
        (when src-file (assert (>= (file-write-date bin-file) (file-write-date src-file))))
        
        ;; If current fasl file was already imported, then return its module.
        (unless force-reload
          (whereas ((m (get-loaded-module :bin-pathname bin-file
                                          :bin-file-write-date (file-write-date bin-file)
                                          :habitat habitat)))
            (return-from py-import m)))
        
        (let ((new-mod-dotted-name (if (and within-mod-path (eq find-path within-mod-path))
                                       (progn (assert (not (default-module-name-p within-mod-name)))
                                              (concatenate 'string within-mod-name "." dotted-name))
                                     dotted-name))
              (new-module 'uninitialized))
          (unwind-protect
              (restart-case
                  (setf new-module (%load-compiled-python-file bin-file
                                                               :mod-name new-mod-dotted-name
                                                               :habitat habitat))
                (delete-fasl-try-again ()
                    :test (lambda (c)
                            (declare (ignore c))
                            (and (probe-file src-file) (probe-file bin-file)))
                    :report (lambda (s) (format s "Recompile and re-import module `~A' ~
                                                   from file ~A" dotted-name src-file))
                  (delete-file bin-file)
                  (return-from py-import ;; Restart the py-import call
                    (apply #'py-import mod-name-as-list options))))
            
            (flet ((log-abort (error-p)
                     (let ((args (list "Loading of module `~A' was aborted.~
                                        ~@[~:@_Source: ~A~]~@[~:@_Binary: ~A~]~@[~:@_Imported by: ~A~]"
                                       new-mod-dotted-name src-file bin-file within-mod-path)))
                       (if error-p
                           (apply #'py-raise '{ImportError} args)
                         (apply #'warn args)))))
              (cond ((eq new-module 'uninitialized)
                     ;; An unwinding restart was invoked from within the LOAD.
                     (log-abort nil))
                    ((null new-module)
                     ;; LOAD returned nil, probably due to the user invoking "skip loading" restart.
                     ;; The contract of this function requires raising an error.
                     (log-abort t))
                    (t
                     ;; Imported successfully
                     (return-from py-import new-module))))))))))

(defun builtin-module-attribute (module attr)
  (check-type module symbol)
  (check-type attr string)
  (symbol-value (find-symbol attr (find-package (concatenate 'string (package-name :clpython.module) "." (symbol-name module))))))
  
(defun directory-p (pathname)
  (check-type pathname pathname)
  #+allegro (excl:file-directory-p pathname)
  #+lispworks (lispworks:file-directory-p pathname)
  #+(or cmu sbcl) (null (pathname-type pathname))
  #-(or allegro cmu lispworks sbcl) (error "TODO: No DIRECTORY-P for this implementation."))

(defun path-kind (path)
  "The file kind, which is either :FILE, :DIRECTORY or NIL"
  (check-type path string)
  (whereas ((pathname (probe-file path)))
    (if (directory-p pathname) :directory :file)))
