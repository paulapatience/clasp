(in-package :cmp)

;; A function of two arguments, an LLVM Value and a variable.
;; The "variable" is just whatever is provided to this code
;; (so that it can work with either b or c clasp).
;; The function should put the Value into the variable, possibly generating code to do so.
;; In order to work with cclasp's SSA stuff, it must be called exactly once for each variable.
(defvar *argument-out*)

(defun compile-wrong-number-arguments-block (closure nargs min max)
  ;; make a new irbuilder, so as to not disturb anything
  (with-irbuilder ((llvm-sys:make-irbuilder (thread-local-llvm-context)))
    (let ((errorb (irc-basic-block-create "wrong-num-args")))
      (irc-begin-block errorb)
      (irc-intrinsic-call-or-invoke "cc_wrong_number_of_arguments"
                                    ;; We use low max to indicate no upper limit.
                                    (list closure nargs min (or max (irc-size_t 0))))
      (irc-unreachable)
      errorb)))

;; Generate code to signal an error iff there weren't enough arguments provided.
(defun compile-error-if-not-enough-arguments (error-block cmin nargs)
  (let* ((cont-block (irc-basic-block-create "enough-arguments"))
         (cmp (irc-icmp-ult nargs cmin)))
    (irc-cond-br cmp error-block cont-block)
    (irc-begin-block cont-block)))

;; Ditto but with too many.
(defun compile-error-if-too-many-arguments (error-block cmax nargs)
  (let* ((cont-block (irc-basic-block-create "enough-arguments"))
         (cmp (irc-icmp-ugt nargs cmax)))
    (irc-cond-br cmp error-block cont-block)
    (irc-begin-block cont-block)))

;; Generate code to bind the required arguments.
(defun compile-required-arguments (reqargs cc)
  ;; reqargs is as returned from process-lambda-list- (# ...) where # is the count.
  ;; cc is the calling-convention object.
  (dolist (req (cdr reqargs))
    (let ((arg (calling-convention-vaslist.va-arg cc)))
      (cmp-log "(calling-convention-vaslist.va-arg cc) -> {}%N" arg)
      (funcall *argument-out* arg req))))

;;; Unlike the other compile-*-arguments, this one returns a value-
;;; an LLVM Value for the number of arguments remaining.
(defun compile-optional-arguments (optargs nreq calling-conv false true)
  ;; optargs is (# var suppliedp default ...)
  ;; We basically generate a switch, but also return the number of arguments remaining
  ;; (or zero if that's negative).
  ;; For (&optional a b) for example,
  #|
size_t nargs_remaining;
switch (nargs) {
  case 0: nargs_remaining = 0; a = [nil]; a_p = [nil]; b = [nil]; b_p = [nil]; break;
  case 1: nargs_remaining = 0; a = va_arg(); a_p = [t]; b = [nil]; b_p = [nil]; break;
  default: nargs_remaining = nargs - 2; a = va_arg(); a_p = [t]; b = va_arg(); b_p = [t]; break;
}
  |#
  ;; All these assignments are done with phi so it's a bit more confusing to follow, unfortunately.
  (let* ((nargs (calling-convention-nargs calling-conv))
         (nopt (first optargs))
         (nfixed (+ nopt nreq))
         (opts (rest optargs))
         (enough (irc-basic-block-create "enough-for-optional"))
         (undef (irc-undef-value-get %t*%))
         (sw (irc-switch nargs enough nopt))
         (assn (irc-basic-block-create "optional-assignments"))
         (final (irc-basic-block-create "done-parsing-optionals"))
         (zero (irc-size_t 0)))
    ;; We generate the assignments first, although they occur last.
    ;; It's just a bit more convenient to do that way.
    (irc-begin-block assn)
    (let* ((npreds (1+ nopt))
           (nremaining (irc-phi %size_t% npreds "nargs-remaining"))
           (var-phis nil) (suppliedp-phis nil))
      ;; We have to do this in two loops to ensure the PHIs come before any code
      ;; generated by *argument-out*.
      (dotimes (i nopt)
        (push (irc-phi %t*% npreds) suppliedp-phis)
        (push (irc-phi %t*% npreds) var-phis))
      ;; OK _now_ argument-out
      (do* ((cur-opt opts (cdddr cur-opt))
            (var (car cur-opt) (car cur-opt))
            (suppliedp (cadr cur-opt) (cadr cur-opt))
            (var-phis var-phis (cdr var-phis))
            (var-phi (car var-phis) (car var-phis))
            (suppliedp-phis suppliedp-phis (cdr suppliedp-phis))
            (suppliedp-phi (car suppliedp-phis) (car suppliedp-phis)))
           ((endp cur-opt))
        (funcall *argument-out* suppliedp-phi suppliedp)
        (funcall *argument-out* var-phi var))
      (irc-br final)
      ;; Generate a block for each case.
      (do ((i nreq (1+ i)))
          ((= i nfixed))
        (let ((new (irc-basic-block-create (core:fmt nil "supplied-{}-arguments" i))))
          (llvm-sys:add-case sw (irc-size_t i) new)
          (irc-phi-add-incoming nremaining zero new)
          (irc-begin-block new)
          ;; Assign each optional parameter accordingly.
          (do* ((var-phis var-phis (cdr var-phis))
                (var-phi (car var-phis) (car var-phis))
                (suppliedp-phis suppliedp-phis (cdr suppliedp-phis))
                (suppliedp-phi (car suppliedp-phis) (car suppliedp-phis))
                (j nreq (1+ j))
                (enough (< j i) (< j i)))
               ((endp var-phis))
            (irc-phi-add-incoming suppliedp-phi (if enough true false) new)
            (irc-phi-add-incoming var-phi (if enough (calling-convention-vaslist.va-arg calling-conv) undef) new))
          (irc-br assn)))
      ;; Default case: everything gets a value and a suppliedp=T.
      (irc-begin-block enough)
      (irc-phi-add-incoming nremaining (irc-sub nargs (irc-size_t nfixed)) enough)
      (dolist (suppliedp-phi suppliedp-phis)
        (irc-phi-add-incoming suppliedp-phi true enough))
      (dolist (var-phi var-phis)
        (irc-phi-add-incoming var-phi (calling-convention-vaslist.va-arg calling-conv) enough))
      (irc-br assn)
      ;; ready to generate more code
      (irc-begin-block final)
      nremaining)))

(defun compile-rest-argument (rest-var varest-p nremaining calling-conv)
  (cmp:irc-branch-to-and-begin-block (cmp:irc-basic-block-create "process-rest-argument"))
  (when rest-var
    (let* ((rest-alloc (calling-convention-rest-alloc calling-conv))
	   (rest (cond
                   ((eq rest-alloc 'ignore)
                    ;; &rest variable is ignored- allocate nothing
                    (irc-undef-value-get %t*%))
                   ((eq rest-alloc 'dynamic-extent)
                    ;; Do the dynamic extent thing- alloca, then an intrinsic to initialize it.
                    (let ((rrest (alloca-dx-list :length nremaining :label "rrest")))
                      (irc-intrinsic-call "cc_gatherDynamicExtentRestArguments"
                                          (list (cmp:calling-convention-vaslist* calling-conv)
                                                nremaining
                                                (irc-bit-cast rrest %t**%)))))
                   (varest-p
                    #+(or)
                    (irc-tag-vaslist (cmp:calling-convention-vaslist* calling-conv)
                                     "rest")
                    ;;#+(or)
                    (let ((temp-vaslist (alloca-vaslist :label "rest")))
                      (irc-intrinsic-call "cc_gatherVaRestArguments" 
                                          (list (cmp:calling-convention-vaslist* calling-conv)
                                                nremaining
                                                temp-vaslist))))
                   (t
                    ;; general case- heap allocation
                    (irc-intrinsic-call "cc_gatherRestArguments" 
                                        (list (cmp:calling-convention-vaslist* calling-conv)
                                              nremaining))))))
      (funcall *argument-out* rest rest-var))))

;;; Keyword processing is the most complicated part, unsurprisingly.
#|
Here is pseudo-C for the parser for (&key a). [foo] indicates an inserted constant.
Having to write with phi nodes unfortunately makes things rather more confusing.

if ((remaining_nargs % 2) == 1)
  cc_oddKeywordException([*current-function-description*]);
tstar bad_keyword = undef;
bool seen_bad_keyword = false;
t_star a_temp = undef, a_p_temp = [nil], allow_other_keys_temp = [nil], allow_other_keys_p_temp = [nil];
for (; remaining_nargs != 0; remaining_nargs -= 2) {
  tstar key = va_arg(valist), value = va_arg(valist);
  if (key == [:a]) {
    if (a_p_temp == [nil]) {
      a_p_temp = [t]; a_temp = value; continue;
    } else continue;
  }
  if (key == [:allow-other-keys]) {
    if (allow_other_keys_p_temp == [nil]) {
      allow_other_keys_p_temp = [t]; allow_other_keys_temp = value; continue;
    } else continue;
  }
  seen_bad_keyword = true; bad_keyword = key;
}
if (seen_bad_keyword)
  cc_ifBadKeywordArgumentException(allow_other_keys_temp, bad_keyword, [*current-function-description*]);
a_p = a_p_temp; a = a_temp;
|#

(defun compile-one-key-test (keyword key-arg suppliedp-phi cont-block false)
  (let* ((keystring (string keyword))
         ;; NOTE: We might save a bit of time by moving this out of the loop.
         ;; Or maybe LLVM can handle it. I don't know.
         (key-const (irc-literal keyword keystring))
         (match (irc-basic-block-create (core:fmt nil "matched-{}" keystring)))
         (mismatch (irc-basic-block-create (core:fmt nil "not-{}" keystring))))
    (let ((test (irc-icmp-eq key-arg key-const)))
      (irc-cond-br test match mismatch))
    (irc-begin-block match)
    (let* ((new (irc-basic-block-create (core:fmt nil "new-{}" keystring)))
           (old (irc-basic-block-create (core:fmt nil "old-{}" keystring))))
      (let ((test (irc-icmp-eq suppliedp-phi false)))
        (irc-cond-br test new old))
      (irc-begin-block new) (irc-br cont-block)
      (irc-begin-block old) (irc-br cont-block)
      (irc-begin-block mismatch)
      (values new old))))
  
(defun compile-key-arguments (keyargs lambda-list-aokp nremaining calling-conv false true)
  (macrolet ((do-keys ((keyword) &body body)
               `(do* ((cur-key (cdr keyargs) (cddddr cur-key))
                      (,keyword (car cur-key) (car cur-key)))
                     ((endp cur-key))
                  ,@body)))
    (let ((aok-parameter-p nil)
          allow-other-keys
          (nkeys (car keyargs))
          (undef (irc-undef-value-get %t*%))
          (start (irc-basic-block-create "parse-key-arguments"))
          (matching (irc-basic-block-create "match-keywords"))
          (after (irc-basic-block-create "after-kw-loop"))
          (unknown-kw (irc-basic-block-create "unknown-kw"))
          (kw-loop (irc-basic-block-create "kw-loop"))
          (kw-loop-continue (irc-basic-block-create "kw-loop-continue")))
      ;; Prepare for :allow-other-keys.
      (unless lambda-list-aokp
        ;; Is there an allow-other-keys argument?
        (do-keys (key)
          (when (eq key :allow-other-keys) (setf aok-parameter-p t) (return)))
        ;; If there's no allow-other-keys argument, add one.
        (unless aok-parameter-p
          (setf keyargs (list* (1+ (car keyargs))
                               ;; default, var, and suppliedp are of course dummies.
                               ;; At the end we can check aok-parameter-p to avoid
                               ;; actually assigning to them.
                               :allow-other-keys nil nil nil
                               (cdr keyargs)))))
      (irc-branch-to-and-begin-block start)
      ;; If the number of arguments remaining is odd, the call is invalid- error.
      (let* ((odd-kw (irc-basic-block-create "odd-kw"))
             (rem (irc-srem nremaining (irc-size_t 2))) ; parity
             (evenp (irc-icmp-eq rem (irc-size_t 0)))) ; is parity zero (is SUB even)?
        (irc-cond-br evenp kw-loop odd-kw)
        ;; There have been an odd number of arguments, so signal an error.
        (irc-begin-block odd-kw)
        (unless (calling-convention-closure calling-conv)
          (error "The calling-conv ~s does not have a closure" calling-conv))
        (irc-intrinsic-invoke-if-landing-pad-or-call "cc_oddKeywordException"
                                                     (list (calling-convention-closure calling-conv)))
        (irc-unreachable))
      ;; Loop starts; welcome hell
      (irc-begin-block kw-loop)
      (let ((top-param-phis nil) (top-suppliedp-phis nil)
            (new-blocks nil) (old-blocks nil)
            (nargs-remaining (irc-phi %size_t% 2 "nargs-remaining"))
            (sbkw (irc-phi %i1% 2 "seen-bad-keyword"))
            (bad-keyword (irc-phi %t*% 2 "bad-keyword")))
        (irc-phi-add-incoming nargs-remaining nremaining start)
        (irc-phi-add-incoming sbkw (jit-constant-false) start)
        (irc-phi-add-incoming bad-keyword undef start)
        (do-keys (key)
          (let ((var-phi (irc-phi %t*% 2 (core:fmt nil "{}-top" (string key)))))
            (push var-phi top-param-phis)
            ;; If we're paying attention to :allow-other-keys, track it specially
            ;; and initialize it to NIL.
            (cond ((and (not lambda-list-aokp) (eq key :allow-other-keys))
                   (irc-phi-add-incoming var-phi false start)
                   (setf allow-other-keys var-phi))
                  (t (irc-phi-add-incoming var-phi undef start))))
          (let ((suppliedp-phi (irc-phi %t*% 2 (core:fmt nil "{}-suppliedp-top" (string key)))))
            (push suppliedp-phi top-suppliedp-phis)
            (irc-phi-add-incoming suppliedp-phi false start)))
        (setf top-param-phis (nreverse top-param-phis)
              top-suppliedp-phis (nreverse top-suppliedp-phis))
        ;; Are we done?
        (let ((zerop (irc-icmp-eq nargs-remaining (irc-size_t 0))))
          (irc-cond-br zerop after matching))
        (irc-begin-block matching)
        ;; Start matching keywords
        (let ((key-arg (calling-convention-vaslist.va-arg calling-conv))
              (value-arg (calling-convention-vaslist.va-arg calling-conv)))
          (do* ((cur-key (cdr keyargs) (cddddr cur-key))
                (key (car cur-key) (car cur-key))
                (suppliedp-phis top-suppliedp-phis (cdr suppliedp-phis))
                (suppliedp-phi (car suppliedp-phis) (car suppliedp-phis)))
               ((endp cur-key))
            (multiple-value-bind (new-block old-block)
                (compile-one-key-test key key-arg suppliedp-phi kw-loop-continue false)
              (push new-block new-blocks) (push old-block old-blocks)))
          (setf new-blocks (nreverse new-blocks) old-blocks (nreverse old-blocks))
          ;; match failure - as usual, works through phi
          (irc-branch-to-and-begin-block unknown-kw)
          (irc-br kw-loop-continue)
          ;; Go around again. And do most of the actual work in phis.
          (irc-begin-block kw-loop-continue)
          (let ((npreds (1+ (* 2 nkeys)))) ; two for each key, plus one for unknown-kw.
            (let ((bot-sbkw (irc-phi %i1% npreds "seen-bad-keyword-bottom"))
                  (bot-bad-keyword (irc-phi %t*% npreds "bad-keyword-bottom")))
              ;; Set up the top to use these.
              (irc-phi-add-incoming sbkw bot-sbkw kw-loop-continue)
              (irc-phi-add-incoming bad-keyword bot-bad-keyword kw-loop-continue)
              ;; If we're coming from unknown-kw, store that.
              (irc-phi-add-incoming bot-sbkw (jit-constant-true) unknown-kw)
              (irc-phi-add-incoming bot-bad-keyword key-arg unknown-kw)
              ;; If we're coming from a match block, don't change anything.
              (dolist (new-block new-blocks)
                (irc-phi-add-incoming bot-sbkw sbkw new-block)
                (irc-phi-add-incoming bot-bad-keyword bad-keyword new-block))
              (dolist (old-block old-blocks)
                (irc-phi-add-incoming bot-sbkw sbkw old-block)
                (irc-phi-add-incoming bot-bad-keyword bad-keyword old-block)))
            ;; OK now the actual keyword values.
            (do* ((var-new-blocks new-blocks (cdr var-new-blocks))
                  (var-new-block (car var-new-blocks) (car var-new-blocks))
                  (top-param-phis top-param-phis (cdr top-param-phis))
                  (top-param-phi (car top-param-phis) (car top-param-phis))
                  (top-suppliedp-phis top-suppliedp-phis (cdr top-suppliedp-phis))
                  (top-suppliedp-phi (car top-suppliedp-phis) (car top-suppliedp-phis)))
                 ((endp var-new-blocks))
              (let ((var-phi (irc-phi %t*% npreds))
                    (suppliedp-phi (irc-phi %t*% npreds)))
                ;; fix up the top part to take values from here
                (irc-phi-add-incoming top-param-phi var-phi kw-loop-continue)
                (irc-phi-add-incoming top-suppliedp-phi suppliedp-phi kw-loop-continue)
                ;; If coming from unknown-kw we keep our values the same.
                (irc-phi-add-incoming var-phi top-param-phi unknown-kw)
                (irc-phi-add-incoming suppliedp-phi top-suppliedp-phi unknown-kw)
                ;; All new-blocks other than this key's stick with what they have.
                (dolist (new-block new-blocks)
                  (cond ((eq var-new-block new-block)
                         ;; Here, however, we get the new values
                         (irc-phi-add-incoming var-phi value-arg new-block)
                         (irc-phi-add-incoming suppliedp-phi true new-block))
                        (t
                         (irc-phi-add-incoming var-phi top-param-phi new-block)
                         (irc-phi-add-incoming suppliedp-phi top-suppliedp-phi new-block))))
                ;; All old-blocks stick with what they have.
                (dolist (old-block old-blocks)
                  (irc-phi-add-incoming var-phi top-param-phi old-block)
                  (irc-phi-add-incoming suppliedp-phi top-suppliedp-phi old-block))))))
        (let ((dec (irc-sub nargs-remaining (irc-size_t 2))))
          (irc-phi-add-incoming nargs-remaining dec kw-loop-continue))
        (irc-br kw-loop)
        ;; Loop over.
        (irc-begin-block after)
        ;; If we hit a bad keyword, and care, signal an error.
        (unless lambda-list-aokp
          (let ((aok-check (irc-basic-block-create "aok-check"))
                (kw-assigns (irc-basic-block-create "kw-assigns")))
            (irc-cond-br sbkw aok-check kw-assigns)
            (irc-begin-block aok-check)
            (irc-intrinsic-invoke-if-landing-pad-or-call
             "cc_ifBadKeywordArgumentException"
             ;; aok was initialized to NIL, regardless of the suppliedp, so this is ok.
             (list allow-other-keys bad-keyword (calling-convention-closure calling-conv)))
            (irc-br kw-assigns)
            (irc-begin-block kw-assigns)))
        (do* ((top-param-phis top-param-phis (cdr top-param-phis))
              (top-param-phi (car top-param-phis) (car top-param-phis))
              (top-suppliedp-phis top-suppliedp-phis (cdr top-suppliedp-phis))
              (top-suppliedp-phi (car top-suppliedp-phis) (car top-suppliedp-phis))
              (cur-key (cdr keyargs) (cddddr cur-key))
              (key (car cur-key) (car cur-key))
              (var (caddr cur-key) (caddr cur-key))
              (suppliedp (cadddr cur-key) (cadddr cur-key)))
             ((endp cur-key))
          (when (or (not (eq key :allow-other-keys)) lambda-list-aokp aok-parameter-p)
            (funcall *argument-out* top-param-phi var)
            (funcall *argument-out* top-suppliedp-phi suppliedp)))))))

(defun compile-general-lambda-list-code (reqargs 
					 optargs 
					 rest-var
                                         varest-p
					 key-flag 
					 keyargs 
					 allow-other-keys
					 calling-conv
                                         &key argument-out (safep t))
  (cmp-log "Entered compile-general-lambda-list-code%N")
  (let* ((*argument-out* argument-out)
         (nargs (calling-convention-nargs calling-conv))
         (nreq (car reqargs))
         (nopt (car optargs))
         (nfixed (+ nreq nopt))
         (creq (irc-size_t nreq))
         (cmax (if (or rest-var key-flag)
                   nil
                   (irc-size_t nfixed)))
         (wrong-nargs-block
           ;; KLUDGE: BIND-VASLIST gets here with a calling-convention-closure of NIL,
           ;; which ends badly. But bind-vaslist also specifies safep nil.
           ;; Of course, without safep we won't use the block anyway, but still.
           (when safep
             (compile-wrong-number-arguments-block
              (calling-convention-closure calling-conv)
              nargs creq cmax))))
    (unless (zerop nreq)
      (when safep
        (compile-error-if-not-enough-arguments wrong-nargs-block creq nargs))
      (compile-required-arguments reqargs calling-conv))
    (let (;; NOTE: Sometimes we don't actually need these.
          ;; We could save miniscule time by not generating.
          (iNIL (irc-nil)) (iT (irc-t)))
      (if (or rest-var key-flag)
          ;; We have &key and/or &rest, so parse with that expectation.
          ;; Specifically, we have to get a variable for how many arguments are left after &optional.
          (let ((nremaining
                  (if (zerop nopt)
                      ;; With no optional arguments it's trivial.
                      (irc-sub nargs creq "nremaining")
                      ;; Otherwise
                      (compile-optional-arguments optargs nreq calling-conv iNIL iT))))
            ;; Note that we don't need to check for too many arguments here.
            (when rest-var
              (compile-rest-argument rest-var varest-p nremaining calling-conv))
            (when key-flag
              (compile-key-arguments keyargs (or allow-other-keys (not safep))
                                     nremaining calling-conv iNIL iT)))
          ;; We don't have &key or &rest, but we might still have &optional.
          (progn
            (unless (zerop nopt)
              ;; Return value of compile-optional-arguments is unneeded-
              ;; we could use it in the error check to save a subtraction, though.
              (compile-optional-arguments optargs nreq calling-conv iNIL iT))
            (when safep
              (cmp-log "Last if-too-many-arguments {} {}" cmax nargs)
              (compile-error-if-too-many-arguments wrong-nargs-block cmax nargs)))))))


        
  
(defun compile-only-req-and-opt-arguments (arity cleavir-lambda-list-analysis calling-conv &key argument-out (safep t))
  (multiple-value-bind (reqargs optargs)
      (process-cleavir-lambda-list-analysis cleavir-lambda-list-analysis)
    (let* ((register-args (calling-convention-register-args calling-conv))
           (nargs (calling-convention-nargs calling-conv))
           (nreq (car (cleavir-lambda-list-analysis-required cleavir-lambda-list-analysis)))
           (creq (irc-size_t nreq))
           (nopt (car (cleavir-lambda-list-analysis-optional cleavir-lambda-list-analysis)))
           (cmax (irc-size_t (+ nreq nopt)))
           (error-block
             ;; see kludge above
             (when safep
               (compile-wrong-number-arguments-block
                (calling-convention-closure calling-conv)
                nargs creq cmax))))
      ;; fixme: it would probably be nicer to generate one switch such that not-enough-arguments
      ;; goes to an error block and too-many goes to another. then we'll only have one test on
      ;; the argument count. llvm might reduce it to that anyway, though.
      (flet ((ensure-register (registers undef &optional name)
               (declare (ignore name))
               (let ((register (car registers)))
                 (if register
                     register
                     undef))))
        (unless (cmp:generate-function-for-arity-p arity cleavir-lambda-list-analysis)
          (let ((error-block (compile-wrong-number-arguments-block (calling-convention-closure calling-conv)
                                                                   (jit-constant-i64 (length register-args))
                                                                   (jit-constant-i64 nreq)
                                                                   (jit-constant-i64 (+ nreq nopt)))))
            (irc-br error-block)
            (return-from compile-only-req-and-opt-arguments nil)))
        ;; required arguments
        (when (> nreq 0)
          (when safep
            (compile-error-if-not-enough-arguments error-block creq nargs))
          (dolist (req (cdr reqargs))
            ;; we pop the register-args so that the optionals below won't use em.
            (funcall argument-out (pop register-args) req)))
        ;; optional arguments. code is mostly the same as compile-optional-arguments (fixme).
        (if (> nopt 0)
            (let* ((npreds (1+ nopt))
                   (undef (irc-undef-value-get %t*%))
                   (true (irc-t))
                   (false (irc-nil))
                   (default (irc-basic-block-create "enough-for-optional"))
                   (assn (irc-basic-block-create "optional-assignments"))
                   (after (irc-basic-block-create "argument-parsing-done"))
                   (sw (irc-switch nargs default nopt))
                   (var-phis nil) (suppliedp-phis nil))
              (irc-begin-block assn)
              (dotimes (i nopt)
                (push (irc-phi %t*% npreds) var-phis)
                (push (irc-phi %t*% npreds) suppliedp-phis))
              (do ((cur-opt (cdr optargs) (cdddr cur-opt))
                   (var-phis var-phis (cdr var-phis))
                   (suppliedp-phis suppliedp-phis (cdr suppliedp-phis)))
                  ((endp cur-opt))
                (funcall argument-out (car suppliedp-phis) (second cur-opt))
                (funcall argument-out (car var-phis) (first cur-opt)))
              (irc-br after)
              ;; each case
              (dotimes (i nopt)
                (let* ((opti (+ i nreq))
                       (blck (irc-basic-block-create (core:fmt nil "supplied-{}-arguments" opti))))
                  (llvm-sys:add-case sw (irc-size_t opti) blck)
                  (do ((var-phis var-phis (cdr var-phis))
                       (suppliedp-phis suppliedp-phis (cdr suppliedp-phis))
                       (registers register-args (cdr registers))
                       (optj nreq (1+ optj)))
                      ((endp var-phis))
                    (cond ((< optj opti) ; enough arguments
                           (irc-phi-add-incoming (car suppliedp-phis) true blck)
                           (irc-phi-add-incoming (car var-phis) (ensure-register registers undef :nopt) blck))
                          (t            ; nope
                           (irc-phi-add-incoming (car suppliedp-phis) false blck)
                           (irc-phi-add-incoming (car var-phis) undef blck))))
                  (irc-begin-block blck) (irc-br assn)))
              ;; default
              ;; just use a register for each argument
              ;; we have to use another block because compile-error-etc does an invoke
              ;; and generates more blocks.
              (let ((default-cont (irc-basic-block-create "enough-for-optional-continued")))
                (do ((var-phis var-phis (cdr var-phis))
                     (suppliedp-phis suppliedp-phis (cdr suppliedp-phis))
                     (registers register-args (cdr registers)))
                    ((endp var-phis))
                  (irc-phi-add-incoming (car suppliedp-phis) true default-cont)
                  (irc-phi-add-incoming (car var-phis) (ensure-register registers undef :var-phis) default-cont))
                (irc-begin-block default)
                ;; test for too many arguments
                (when safep
                  (compile-error-if-too-many-arguments error-block cmax nargs))
                (irc-branch-to-and-begin-block default-cont)
                (irc-br assn)
                ;; and, done.
                (irc-begin-block after)))
            ;; no optional arguments, so not much to do
            (when safep
              (compile-error-if-too-many-arguments error-block cmax nargs))))
      t)))

(defun req-opt-only-p (cleavir-lambda-list)
  (let ((nreq 0) (nopt 0) (req-opt-only t)
        (state nil))
    (dolist (item cleavir-lambda-list)
      (cond ((eq item '&optional)
             (if (eq state '&optional)
                 (progn (setf req-opt-only nil) ; dupe &optional; just mark as general
                        (return))
                 (setf state '&optional)))
            ((member item lambda-list-keywords)
             (setf req-opt-only nil)
             (return))
            (t (if (eq state '&optional)
                   (incf nopt)
                   (incf nreq)))))
    (values req-opt-only nreq nopt)))


(defun calculate-cleavir-lambda-list-analysis (lambda-list)
  ;; we assume that the lambda list is in its correct format:
  ;; 1) required arguments are lexical locations.
  ;; 2) optional arguments are (<lexical location> <lexical location>)
  ;; 3) keyword arguments are (<symbol> <lexical location> <lexical location>)
  ;; this lets us cheap out on parsing, except &rest and &allow-other-keys.
  (cmp-log "calculate-cleavir-lambda-list-analysis lambda-list -> {}%N" lambda-list)
  (let (required optional rest-type rest key aok-p key-flag
                 (required-count 0) (optional-count 0) (key-count 0))
    (dolist (item lambda-list)
      (case item
        ((&optional) #|ignore|#)
        ((&key) (setf key-flag t))
        ((&rest core:&va-rest) (setf rest-type item))
        ((&allow-other-keys) (setf aok-p t))
        (t (if (listp item)
               (cond ((= (length item) 2)
                      ;; optional
                      (incf optional-count)
                      ;; above, we expect (location -p whatever)
                      ;; though it's specified as (var init -p)
                      ;; fix me
                      (push (first item) optional)
                      (push (second item) optional)
                      (push nil optional))
                     (t ;; key, assumedly
                      (incf key-count)
                      (push (first item) key)
                      (push (first item) key)
                      ;; above, we treat this as being the location,
                      ;; even though from process-lambda-list it's
                      ;; the initform.
                      ;; this file needs work fixme.
                      (push (second item) key)
                      (push (third item) key)))
               ;; nonlist; we picked off lambda list keywords, so it's an argument.
               (cond (rest-type
                      ;; we've seen a &rest lambda list keyword, so this must be that
                      (setf rest item))
                     ;; haven't seen anything, it's required
                     (t (incf required-count)
                        (push item required)))))))
    (let* ((cleavir-lambda-list (ensure-cleavir-lambda-list lambda-list))
           (arguments (lambda-list-arguments cleavir-lambda-list)))
      (make-cleavir-lambda-list-analysis
       :cleavir-lambda-list (ensure-cleavir-lambda-list lambda-list) ; Is this correct?
       :req-opt-only-p (req-opt-only-p (ensure-cleavir-lambda-list lambda-list))
       :lambda-list-arguments arguments
       :required (cons required-count (nreverse required))
       :optional (cons optional-count (nreverse optional))
       :rest rest
       :key-flag key-flag
       :key-count (cons key-count (nreverse key))
       :aok-p aok-p
       :aux-p nil                       ; aux-p; unused here
       :va-rest-p (if (eq rest-type 'core:&va-rest) t nil)))))



(defun may-use-only-registers (cleavir-lambda-list-analysis)
  (multiple-value-bind (req-opt-only nreq nopt)
      (req-opt-only-p (cleavir-lambda-list-analysis-cleavir-lambda-list cleavir-lambda-list-analysis))
    (and req-opt-only
         (and (<= +entry-point-arity-begin+ (+ nreq nopt))
              (< (+ nreq nopt) +entry-point-arity-end+)))))

;;; compile-lambda-list-code
;;; you must provide the following lambdas
;;;   alloca-size_t (label) that allocas a size_t slot in the current function
;;;   alloca-vaslist (label) that allocas a vaslist slot in the current function
;;;   translate-datum (datum) that translates a datum into an alloca in the current function
;;;
(defun compile-lambda-list-code (cleavir-lambda-list-analysis calling-conv arity
                                 &key argument-out (safep t))
  "Return T if arguments were processed and NIL if they were not"
  (cmp-log "about to compile-lambda-list-code cleavir-lambda-list-analysis: {}%N" cleavir-lambda-list-analysis)
  (multiple-value-bind (reqargs optargs rest-var key-flag keyargs allow-other-keys unused-auxs varest-p)
      (process-cleavir-lambda-list-analysis cleavir-lambda-list-analysis)
    (declare (ignore unused-auxs))
    (cmp-log "    reqargs -> {}%N" reqargs)
    (cmp-log "    optargs -> {}%N" optargs)
    (cmp-log "    keyargs -> {}%N" keyargs)
    (cond
      ((eq arity :general-entry)
       (compile-general-lambda-list-code reqargs 
                                         optargs 
                                         rest-var
                                         varest-p
                                         key-flag 
                                         keyargs 
                                         allow-other-keys
                                         calling-conv
                                         :argument-out argument-out
                                         :safep safep)
       t ;; always successful for general lambda-list processing
       )
      ((and (fixnump arity)
            (may-use-only-registers cleavir-lambda-list-analysis))
       (let ((result (compile-only-req-and-opt-arguments arity cleavir-lambda-list-analysis #|reqargs optargs|#
                                                         calling-conv
                                                         :argument-out argument-out
                                                         :safep safep)))
         result                         ; may be nil or t
         ))
      (t (let* ((register-args (calling-convention-register-args calling-conv))
                (nargs (length register-args))
                (arg-buffer (if (= nargs 0)
                                nil
                                (alloca-arguments nargs "ll-args")))
                (vaslist* (alloca-vaslist))
                (idx 0))
           (dolist (arg register-args)
             (let ((arg-gep (irc-gep arg-buffer (list 0 idx))))
               (incf idx)
               (irc-store arg arg-gep)))
           (if (= nargs 0)
               (vaslist-start vaslist* (jit-constant-i64 nargs))
               (vaslist-start vaslist* (jit-constant-i64 nargs)
                              (irc-bit-cast arg-buffer %i8**%)))
           (setf (calling-convention-vaslist* calling-conv) vaslist*)
           (compile-general-lambda-list-code reqargs 
                                             optargs 
                                             rest-var
                                             varest-p
                                             key-flag 
                                             keyargs 
                                             allow-other-keys
                                             calling-conv
                                             :argument-out argument-out
                                             :safep safep)
           )
         t ;; always successful when using general lambda-list processing
         ))))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;; Setup the calling convention
;;
(defun setup-calling-convention (llvm-function arity
                                 &key debug-on rest-alloc cleavir-lambda-list-analysis)
    (initialize-calling-convention llvm-function
                                   arity
                                   :debug-on debug-on
                                   :rest-alloc rest-alloc
                                   :cleavir-lambda-list-analysis cleavir-lambda-list-analysis))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; bclasp 
;;;


(defun bclasp-map-lambda-list-symbols-to-indices (cleavir-lambda-list-analysis)
  (multiple-value-bind (reqs opts rest key-flag keys)
      (process-cleavir-lambda-list-analysis cleavir-lambda-list-analysis)
    (declare (ignore key-flag))
    ;; Create the register lexicals using allocas
    (let (bindings
          (index -1))
      (cmp-log "Processing reqs -> {}%N" reqs)
      (dolist (req (cdr reqs))
        (cmp-log "Add req {}%N" req)
        (push (cons req (incf index)) bindings))
      (cmp-log "Processing opts -> {}%N" opts)
      (do* ((cur (cdr opts) (cdddr cur))
            (opt (car cur) (car cur))
            (optp (cadr cur) (cadr cur)))
           ((null cur))
        (cmp-log "Add opt {} {}%N" opt optp)
        (push (cons opt (incf index)) bindings)
        (push (cons optp (incf index)) bindings))
      (cmp-log "Processing rest -> {}%N" rest)
      (when rest
        (push (cons rest (incf index)) bindings))
      (cmp-log "Processing keys -> {}%N" keys)
      (do* ((cur (cdr keys) (cddddr cur))
            (key (third cur) (third cur))
            (keyp (fourth cur) (fourth cur)))
           ((null cur))
        (push (cons key (incf index)) bindings)
        (push (cons keyp (incf index)) bindings))
      (nreverse bindings))))

(defun bclasp-compile-lambda-list-code (fn-env callconv arity &key (safep t))
  (let ((cleavir-lambda-list-analysis (calling-convention-cleavir-lambda-list-analysis callconv)))
    (cmp-log "Entered bclasp-compile-lambda-list-code%N")
    (let* ((output-bindings (bclasp-map-lambda-list-symbols-to-indices cleavir-lambda-list-analysis))
           (new-env (irc-new-unbound-value-environment-of-size
                     fn-env
                     :number-of-arguments (length output-bindings)
                     :label "arguments-env")))
      (irc-make-value-frame-set-parent new-env (length output-bindings) fn-env)
      (cmp-log "output-bindings: {}%N" output-bindings)
      (mapc (lambda (ob)
              (cmp-log "Adding to environment: {}%N" ob)
              (core:value-environment-define-lexical-binding new-env (car ob) (cdr ob)))
            output-bindings)
      (cmp-log "register-environment contents -> {}%N" new-env)
      (compile-lambda-list-code
       cleavir-lambda-list-analysis
       callconv
       arity
       :safep safep
       :argument-out (lambda (value datum)
                       (let* ((info (assoc datum output-bindings))
                              (symbol (car info))
                              (index (cdr info))
                              (ref (codegen-lexical-var-reference symbol 0 index new-env new-env)))
                         (irc-t*-result value ref))))
      new-env)))