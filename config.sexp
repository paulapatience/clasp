;;;; config.sexp — Local, Guix-compatible Clasp configuration
;;;;
;;;; SPDX-FileCopyrightText: Copyright (c) 2024 Paul A. Patience <paul@apatience.com>
;;;; SPDX-License-Identifier: MIT

#+(or)
(progn
  (defun store-path (package)
    (destructuring-bind (package &optional output)
        (if (listp package) package (list package))
      (let ((paths (uiop:split-string
                    (uiop:run-program (list "guix" "build" package)
                                      :output '(:string :stripped t))
                    :separator #(#\Newline))))
        (loop for path in paths
              for suffix = (subseq path (1+ (position #\- path :from-end t)))
              do (when (if (digit-char-p (char suffix 0))
                           (null output)
                           (equal suffix output))
                   (return path))))))
  `(:cc "clang"
    :cxx "clang++"
    :ld "lld"
    :ldflags
    ,(format nil "~{-Wl,-rpath,~A/lib~^ ~}"
             (mapcar #'store-path
                     '("clang-toolchain@18"
                       ("--expression=(@@ (gnu packages gcc) gcc)" "lib")
                       "fmt@9"
                       "gmp"
                       "libelf")))
    ;; --skip-sync=nil to enable
    :skip-sync t))

(:cc "clang"
 :cxx "clang++"
 :ld "lld"
 :ldflags "-Wl,-rpath,/gnu/store/qnlj9dwffdqjz5j36f3gx6y6j0c9fg54-clang-toolchain-18.1.4/lib -Wl,-rpath,/gnu/store/k9q9jxsqldxz0yl65rcgpnnncqwha2qi-gcc-11.3.0-lib/lib -Wl,-rpath,/gnu/store/wqczqp9gvrbmz7m65z1gjnbgf0qq3hnl-fmt-9.1.0/lib -Wl,-rpath,/gnu/store/blls5q6cahn8p555kavqpi1flswkzvgg-gmp-6.2.1/lib -Wl,-rpath,/gnu/store/b6kjcpgzd6qcqn1cdcbn6k2pnr7gz7i4-libelf-0.8.13/lib"
 :skip-sync t)
