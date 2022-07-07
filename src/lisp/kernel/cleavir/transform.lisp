(in-package #:clasp-cleavir)

#+(or)
(eval-when (:execute)
  (format t "Setting core:*echo-repl-read* to T~%")
  (setq core:*echo-repl-read* t))

;;;; TRANSFORMS are like compiler macros, but use the context (environment)
;;;; more heavily. They can access inferred types and other information about
;;;; their parameters (mostly just types so far).
;;;; Syntax is as follows:
;;;; deftransform (op-name (&rest lambda-list) &body body)
;;;; op-name is the name of a function.
;;;; lambda-list is a typed lambda list, kind of like defmethod, but with
;;;;  types allowed as "specializers". Currently the lambda list can only have
;;;;  required parameters.
;;;; Semantics are as follows:
;;;; When the compiler sees a call to op-name, it will determine the types
;;;; of the argument forms as best it can. Then it will try to find a
;;;; transform such that the argument types are subtypes of the types of the
;;;; transform's lambda list. If it finds one, it calls the transform function
;;;; with the given argument forms. If the transform returns NIL, the compiler
;;;; tries another valid transform if there is one, or else gives up.
;;;; Otherwise, the compiler substitutes the result for the original op-name.
;;;; Here's a simple example:
;;;; (deftransform eql ((x symbol) y) 'eq)
;;;; Now when the compiler sees (eql 'foo x), this transform might be used
;;;; because it's easy to see 'FOO is a symbol. The transform unconditionally
;;;; returns EQ, so the compiler replaces the form with (eq 'foo x) and
;;;; compiles that instead.
;;;; More complicated examples return a lambda expression.
;;;; Transforms are tried most-specific first. A transform is more specific
;;;; than another if they work on calls with the same number of arguments, and
;;;; all types of the first are recognizable subtypes of the second.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defvar *bir-transformers* (make-hash-table :test #'equal)))

(defun asserted-ctype (datum)
  (ctype:values-conjoin *clasp-system*
                        (bir:ctype datum) (bir:asserted-type datum)))

(defun arg-subtypep (arg ctype)
  (ctype:subtypep (ctype:primary (asserted-ctype arg) *clasp-system*)
                  ctype *clasp-system*))

(defun lambda->birfun (module lambda-expression-cst)
  (let* (;; FIXME: We should be harsher with errors than cst->ast is here,
         ;; since deftransforms are part of the compiler, and not the
         ;; user's fault.
         (ast (cst->ast lambda-expression-cst))
         (bir (cleavir-ast-to-bir:compile-into-module ast module
                                                      *clasp-system*)))
    ;; Run the first few transformations.
    ;; FIXME: Use a pass manager/reoptimize flags/something smarter.
    (bir-transformations:eliminate-come-froms bir)
    (bir-transformations:find-module-local-calls module)
    (bir-transformations:function-optimize-variables bir)
    bir))

(defun replace-callee-with-lambda (call lambda-expression-cst)
  (let ((bir (lambda->birfun (bir:module (bir:function call))
                             lambda-expression-cst)))
    ;; Now properly insert it.
    (change-class call 'bir:local-call
                  :inputs (list* bir (rest (bir:inputs call))))
    ;; KLUDGEish: maybe-interpolate misbehaves when the flow order is invalid.
    ;; See #1260.
    (bir:compute-iblock-flow-order (bir:function call))
    (bir-transformations:maybe-interpolate bir)))

;;; We can't ever inline mv local calls (yet! TODO, should be possible sometimes)
;;; so this is a bit simpler than the above.
(defun replace-mvcallee-with-lambda (call lambda-expression-cst)
  (let ((bir (lambda->birfun (bir:module (bir:function call))
                             lambda-expression-cst)))
    ;; Now properly insert it.
    (change-class call 'bir:mv-local-call
                  :inputs (list* bir (rest (bir:inputs call))))))

(defmacro with-transform-declining (&body body)
  `(catch '%decline-transform ,@body))

(defmacro decline-transform (reason &rest arguments)
  (declare (ignore reason arguments)) ; maybe later
  `(throw '%decline-transform nil))

(defun maybe-transform (call transforms)
  (flet ((arg-primary (arg)
           (ctype:primary (asserted-ctype arg) *clasp-system*)))
    (loop with args = (rest (bir:inputs call))
          with argstype
            = (ctype:values (mapcar #'arg-primary args) nil
                            (ctype:bottom *clasp-system*) *clasp-system*)
          for (transform . vtype) in transforms
          when (ctype:values-subtypep argstype vtype *clasp-system*)
            do (with-transform-declining
                   (replace-callee-with-lambda
                    call (funcall transform :origin (bir:origin call)
                                  :argstype argstype))
                 (return t)))))

(defmethod cleavir-bir-transformations:transform-call
    ((system clasp) key (call bir:call))
  (let ((trans (gethash key *bir-transformers*)))
    (if trans
        (maybe-transform call trans)
        nil)))

(defmethod cleavir-bir-transformations:transform-call
    ((system clasp) key (call bir:mv-call))
  (let ((transforms (gethash key *bir-transformers*)))
    (if transforms
        (loop with argstype = (bir:ctype (second (bir:inputs call)))
              for (transform . vtype) in transforms
              when (ctype:values-subtypep argstype vtype *clasp-system*)
                do (with-transform-declining
                       (replace-mvcallee-with-lambda
                        call (funcall transform :origin (bir:origin call)
                                      :argstype argstype))
                     (return t)))
        nil)))

(define-condition failed-transform (ext:compiler-note)
  ((%call :initarg :call :reader failed-transform-call)
   (%opname :initarg :opname :reader failed-transform-opname)
   ;; A list of transform "criteria". For now, a criterion is just the list
   ;; of types a transform can require. In the future there may be other
   ;; criteria, such as being a constant.
   (%available :initarg :available :reader failed-transform-available))
  (:report (lambda (condition stream)
             (format stream "Unable to optimize call to ~s:
The compiler only knows the arguments to be of types ~a.
Optimizations are available for any of:
~{~s~%~}"
                     (failed-transform-opname condition)
                     (loop with call = (failed-transform-call condition)
                           with sys = *clasp-system*
                           for arg in (rest (bir:inputs call))
                           for vtype = (asserted-ctype arg)
                           for svtype = (ctype:primary vtype sys)
                           collect svtype)
                     (mapcar #'cdr (failed-transform-available condition))))))

;;; Note a missed optimization to the programmer.
;;; called in translate, not here, since transform-call may be called
;;; multiple times during meta-evaluation.
(defun maybe-note-failed-transforms (call)
  (when (policy:policy-value (bir:policy call) 'note-untransformed-calls)
    (let ((identities (cleavir-attributes:identities (bir:attributes call))))
      (dolist (id identities)
        (let ((trans (gethash id *bir-transformers*)))
          (when trans
            (cmp:note 'failed-transform
                      :call call :opname id :available trans
                      :origin (origin-source (bir:origin call)))))))))

(defmacro %deftransformation (name)
  `(eval-when (:compile-toplevel :load-toplevel :execute)
     (setf (gethash ',name *bir-transformers*) nil)
     (setf (gethash ',name *fn-transforms*) '(,name))
     ',name))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun vtype= (vtype1 vtype2)
    (and (ctype:values-subtypep vtype1 vtype2 *clasp-system*)
         (ctype:values-subtypep vtype2 vtype1 *clasp-system*)))
  (defun vtype< (vtype1 vtype2)
    (and (ctype:values-subtypep vtype1 vtype2 *clasp-system*)
         ;; This also includes NIL NIL, but that probably won't happen
         ;; if the first subtypep returns true
         (not (ctype:values-subtypep vtype2 vtype1 *clasp-system*))))
  (defun %def-bir-transformer (name function argstype)
    ;; We just use a reverse alist (function . argstype).
    (let* ((transformers (gethash name *bir-transformers*))
           (existing (rassoc argstype transformers :test #'vtype=)))
      (if existing
          ;; replace
          (setf (car existing) function)
          ;; Merge in, respecting subtypep
          (setf (gethash name *bir-transformers*)
                (merge 'list (list (cons function argstype))
                       (gethash name *bir-transformers*)
                        #'vtype< :key #'cdr))))))

(defmacro %deftransform (name lambda-list argstype
                         &body body)
  (let ((argstype (env:parse-values-type-specifier argstype nil *clasp-system*)))
    `(eval-when (:compile-toplevel :load-toplevel :execute)
       (unless (nth-value 1 (gethash ',name *bir-transformers*))
         (%deftransformation ,name))
       (%def-bir-transformer ',name (lambda ,lambda-list ,@body) ',argstype)
       ',name)))

;;; Given an expression, make a CST for it.
;;; FIXME: This should be more sophisticated. I'm thinking the source info
;;; should be as for an inlined function.
(defun cstify-transformer (origin expression)
  (cst:cst-from-expression expression :source origin))

;; Useful below for inserting checks on arguments.
(defmacro ensure-the (type form)
  `(cleavir-primop:ensure-the (values ,type &rest t)
                              (lambda (&optional value &rest ign)
                                ;; This is going right into a primop,
                                ;; so the other values can be ignored
                                (declare (ignore ign))
                                (unless (typep value ',type)
                                  (error 'type-error :datum value
                                                     :expected-type ',type))
                                value)
                              ,form))

;; Also useful, for laziness reasons.
(defmacro truly-the (type form)
  `(cleavir-primop:truly-the (values ,type &rest nil) ,form))

(defmacro with-transformer-types (lambda-list argstype &body body)
  `(with-types ,lambda-list ,argstype
     (:default (decline-transform "type mismatch"))
     ,@body))

;;; A deftransform lambda list is like a method lambda list, except with
;;; types instead of specializers, and &optional and &rest can have types.
;;; &optional parameters can be specified as ((var type) default var-p).
;;; This function returns six values: Three for the required, optional, and
;;; rest parts of the lambda list, and three for the corresponding types.
;;; This function returns two values: An ordinary lambda list and an
;;; unparsed values type representing the arguments.
(defun process-deftransform-lambda-list (lambda-list)
  (loop with state = :required
        with sys = *clasp-system*
        with reqparams = nil
        with optparams = nil
        with restparam = nil
        with reqtypes = nil
        with opttypes = nil
        with resttype = nil
        for item in lambda-list
        do (cond ((member item '(&optional &rest))
                  (assert (or (eq state :required)
                              (and (eq item '&rest) (eq state '&optional))))
                  (setf state item))
                 ((eq state :required)
                  (cond ((listp item)
                         (push (first item) reqparams)
                         (push (second item) reqtypes))
                        (t (push item reqparams)
                           (push 't reqtypes))))
                 ((eq state '&optional)
                  (cond ((and (listp item) (listp (first item)))
                         (push (list (caar item) (second item) (third item))
                               optparams)
                         (push (cadar item) opttypes))
                        (t (push item optparams)
                           (push t opttypes))))
                 ((eq state '&rest)
                  (cond ((listp item)
                         (setf restparam (first item))
                         (setf resttype (second item)))
                        (t (setf restparam item) (setf resttype 't)))
                  (setf state :done))
                 ((eq state :done) (error "Bad deftransform ll ~a" lambda-list)))
        finally (return (values (nreverse reqparams) (nreverse optparams)
                                restparam
                                (nreverse reqtypes) (nreverse opttypes)
                                resttype))))

(defmacro deftransform (name (typed-lambda-list
                              &key (argstype (gensym "ARGSTYPE") argstypep))
                        &body body)
  (multiple-value-bind (req opt rest reqt optt restt)
      (process-deftransform-lambda-list typed-lambda-list)
    (assert (or (null restt) (eq restt t))) ; we're limitd at the moment.
    (let* ((ignorable (append req opt (when rest (list rest))))
           (ll `(,@req &optional ,@opt ,@(when rest `(&rest ,rest))))
           (vt `(values ,@reqt &optional ,@optt &rest ,restt))
           (osym (gensym "ORIGIN")) (bodysym (gensym "BODY")))
      `(%deftransform ,name (&key ((:origin ,osym)) ((:argstype ,argstype))) ,vt
         ,@(unless argstypep `((declare (ignore ,argstype))))
         (let ((,bodysym (progn ,@body)))
           (cstify-transformer
            ,osym
            ;; double backquotes carefully designed piece by piece
            `(lambda (,@',ll)
               (declare (ignorable ,@',ignorable))
               ,,bodysym)))))))

;;;

(defmethod cleavir-bir-transformations:generate-type-check-function
    ((module bir:module) origin ctype (system clasp))
  (lambda->birfun module
                  (cstify-transformer origin
                                      `(lambda (&optional v &rest ign)
                                         (declare (ignore ign))
                                         (if (typep v ',(discrimination-type
                                                         ctype))
                                             v
                                             (error 'type-error
                                                    :datum v
                                                    :expected-type ',ctype))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; (5) DATA AND CONTROL FLOW

(deftransform equal (((x number) (y t))) '(eql x y))
(deftransform equal (((x t) (y number))) '(eql x y))
(deftransform equalp (((x number) (y number))) '(= x y))

(deftransform equal (((x character) (y character))) '(char= x y))
(deftransform equalp (((x character) (y character))) '(char-equal x y))

#+(or) ; string= is actually slower atm due to keyword etc processing
(deftransform equal ((x string) (y string)) '(string= x y))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; (12) NUMBERS

(macrolet ((define-two-arg-f (name)
             `(progn
                (deftransform ,name (((a1 single-float) (a2 double-float)))
                  '(,name (float a1 0d0) a2))
                (deftransform ,name (((a1 double-float) (a2 single-float)))
                  '(,name a1 (float a2 0d0)))))
           (define-two-arg-ff (name)
             `(progn
                (define-two-arg-f ,name)
                (deftransform ,name (((x rational) (y single-float)))
                  '(,name (float x 0f0) y))
                (deftransform ,name (((x single-float) (y rational)))
                  '(,name x (float y 0f0)))
                (deftransform ,name (((x rational) (y double-float)))
                  '(,name (float x 0d0) y))
                (deftransform ,name (((x double-float) (y rational)))
                  '(,name x (float y 0d0))))))
  (define-two-arg-ff core:two-arg-+)
  (define-two-arg-ff core:two-arg--)
  (define-two-arg-ff core:two-arg-*)
  (define-two-arg-ff core:two-arg-/)
  (define-two-arg-f  expt))

;; FIXME: i think our FTRUNCATE function has a bug: it should return doubles in
;; this case, by my reading.
(deftransform ftruncate (((dividend single-float) (divisor double-float)))
  '(ftruncate (float dividend 0d0) divisor))
(deftransform ftruncate (((dividend double-float) (divisor single-float)))
  '(ftruncate dividend (float divisor 0d0)))

(macrolet ((define-float-conditional (name sf-primop df-primop)
             `(progn
                (deftransform ,name (((x single-float) (y single-float)))
                  '(if (core::primop ,sf-primop x y) t nil))
                (deftransform ,name (((x double-float) (y double-float)))
                  '(if (core::primop ,df-primop x y) t nil))
                (deftransform ,name (((x single-float) (y double-float)))
                  '(if (core::primop ,df-primop
                        (core::primop core::single-to-double x) y)
                    t nil))
                (deftransform ,name (((x double-float) (y single-float)))
                  '(if (core::primop ,df-primop
                        x (core::primop core::single-to-double y))
                    t nil)))))
  (define-float-conditional core:two-arg-=
    core::two-arg-sf-= core::two-arg-df-=)
  (define-float-conditional core:two-arg-<
    core::two-arg-sf-< core::two-arg-df-<)
  (define-float-conditional core:two-arg-<=
    core::two-arg-sf-<= core::two-arg-df-<=)
  (define-float-conditional core:two-arg->
    core::two-arg-sf-> core::two-arg-df->)
  (define-float-conditional core:two-arg->=
    core::two-arg-sf->= core::two-arg-df->=))

(deftransform zerop (((n single-float)))
  '(if (core::primop core::two-arg-sf-= n 0f0) t nil))
(deftransform plusp (((n single-float)))
  '(if (core::primop core::two-arg-sf-> n 0f0) t nil))
(deftransform minusp (((n single-float)))
  '(if (core::primop core::two-arg-sf-< n 0f0) t nil))

(deftransform zerop (((n double-float)))
  '(if (core::primop core::two-arg-df-= n 0d0) t nil))
(deftransform plusp (((n double-float)))
  '(if (core::primop core::two-arg-df-> n 0d0) t nil))
(deftransform minusp (((n double-float)))
  '(if (core::primop core::two-arg-df-< n 0d0) t nil))

(macrolet ((define-irratf (name)
             `(deftransform ,name (((arg rational)))
                '(,name (float arg 0f0))))
           (define-irratfs (&rest names)
             `(progn ,@(loop for name in names collect `(define-irratf ,name)))))
  (define-irratfs exp cos sin tan cosh sinh tanh asinh sqrt
    ;; Only transform the one-argument case.
    ;; The compiler macro in opt-number.lisp should reduce two-arg to one-arg.
    log
    acos asin acosh atanh))

(deftransform core:reciprocal (((v single-float))) '(/ 1f0 v))
(deftransform core:reciprocal (((v double-float))) '(/ 1d0 v))

(deftransform float (((v float))) 'v)
(deftransform float (((v (not float)))) '(core:to-single-float v))
(deftransform float (((v single-float) (proto single-float))) 'v)
(deftransform float ((v (proto single-float))) '(core:to-single-float v))
(deftransform core:to-single-float (((v single-float))) 'v)
(deftransform float (((v double-float) (proto double-float))) 'v)
(deftransform float ((v (proto double-float))) '(core:to-double-float v))
(deftransform core:to-double-float (((v double-float))) 'v)

;;;

(deftransform realpart (((r real))) 'r)
(deftransform imagpart (((r rational))) 0)
;; imagpart of a float is slightly complicated with negative zero
(deftransform conjugate (((r real))) 'r)
(deftransform numerator (((r integer))) 'r)
(deftransform denominator (((r integer))) 1)
(deftransform rational (((r rational))) 'r)
(deftransform rationalize (((r rational))) 'r)

;;; FIXME: Maybe should be a compiler macro not specializing on fixnum.
;;;        And maybe should use LOGTEST, but I'm not sure what the best way
;;;        to optimize that is yet.
(deftransform evenp (((f fixnum)))
  '(zerop (logand f 1)))
(deftransform oddp (((f fixnum)))
  '(not (zerop (logand f 1))))

(deftransform logandc1 (((n fixnum) (b fixnum))) '(logand (lognot n) b))
(deftransform logandc2 (((a fixnum) (n fixnum))) '(logand a (lognot n)))
(deftransform logorc1 (((n fixnum) (b fixnum))) '(logior (lognot n) b))
(deftransform logorc2 (((a fixnum) (n fixnum))) '(logior a (lognot n)))

(macrolet ((deflog2r (name neg)
             `(deftransform ,name (((a fixnum) (b fixnum))) '(lognot (,neg a b)))))
  (deflog2r core:logeqv-2op core:logxor-2op)
  (deflog2r lognand core:logand-2op)
  (deflog2r lognor core:logior-2op))

(deftransform core:negate (((n fixnum))) '(- 0 n))

(macrolet ((define-fixnum-conditional (name primop)
             `(deftransform ,name (((x fixnum) (y fixnum)))
                '(if (core::primop ,primop x y) t nil))))
  (define-fixnum-conditional core:two-arg-=  core::two-arg-fixnum-=)
  (define-fixnum-conditional core:two-arg-<  core::two-arg-fixnum-<)
  (define-fixnum-conditional core:two-arg-<= core::two-arg-fixnum-<=)
  (define-fixnum-conditional core:two-arg->  core::two-arg-fixnum->)
  (define-fixnum-conditional core:two-arg->= core::two-arg-fixnum->=))

(deftransform zerop (((n fixnum)))
  '(if (core::primop core::two-arg-fixnum-= n 0) t nil))
(deftransform plusp (((n fixnum)))
  '(if (core::primop core::two-arg-fixnum-> n 0) t nil))
(deftransform minusp (((n fixnum)))
  '(if (core::primop core::two-arg-fixnum-< n 0) t nil))

;; right shift of a fixnum
(deftransform ash (((int fixnum) (count (integer * 0))))
  '(core::primop core::fixnum-ashr int (min (- count) 63)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; (14) CONSES

(deftransform length (((x null))) 0)
(deftransform length (((x cons))) '(core:cons-length x))
(deftransform length (((x list)))
  `(if (null x)
       0
       (core:cons-length x)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; (15) ARRAYS

;;; FIXME: The &key stuff should be integrated into deftransform itself. Easier.
(deftransform make-array (((dimensions (integer 0 #.array-dimension-limit)) &rest keys)
                          :argstype args)
  (with-transformer-types (dimensions &key (element-type (eql t))
                                      (initial-element null iesp)
                                      (initial-contents null icsp)
                                      (adjustable null)
                                      (fill-pointer null)
                                      (displaced-to null)
                                      (displaced-index-offset (eql 0) diosp))
    args
    (declare (ignore dimensions displaced-index-offset
                     initial-element initial-contents))
    (let* ((sys *clasp-system*) (null (ctype:member sys nil)))
      (if (and (ctype:member-p sys element-type)
               (= (length (ctype:member-members sys element-type)) 1)
               (ctype:subtypep adjustable null sys)
               (ctype:subtypep fill-pointer null sys)
               (ctype:subtypep displaced-to null sys)
               (not diosp)
               ;; Handle these later. TODO. For efficiency,
               ;; this will probably mean inlining lambdas with &key.
               (and (null iesp) (null icsp)))
          (let* ((uaet (upgraded-array-element-type
                        (first (ctype:member-members sys element-type))))
                 (make-sv (cmp::uaet-info uaet)))
            `(,make-sv dimensions nil nil))
          (decline-transform "making a complex array")))))

(deftransform core:row-major-aset (((arr (simple-array single-float (*)))
                                    idx value))
  '(core::primop core::sf-vset value arr idx))
(deftransform core:row-major-aset (((arr (simple-array double-float (*)))
                                    idx value))
  '(core::primop core::df-vset value arr idx))

(deftransform aref (((arr vector) (index t))) '(row-major-aref arr index))
(deftransform (setf aref) (((val t) (arr vector) (index t)))
  '(setf (row-major-aref arr index) val))

(deftransform array-rank (((arr (array * (*))))) 1)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; (16) STRINGS

(deftransform string (((x symbol))) '(symbol-name x))
(deftransform string (((x string))) '(progn x))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; (17) SEQUENCES

;; These transforms are unsafe, as NTH does not signal out-of-bounds.
#+(or)
(progn
(deftransform elt ((seq list) n) '(nth n seq))
(deftransform core:setf-elt ((seq list) n value) '(setf (nth n seq) value))
)

(deftransform reverse (((x list))) '(core:list-reverse x))
(deftransform nreverse (((x list))) '(core:list-nreverse x))
