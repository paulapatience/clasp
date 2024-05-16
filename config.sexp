;;;; config.sexp — Local, Guix-compatible Clasp configuration
;;;;
;;;; SPDX-FileCopyrightText: Copyright (c) 2024 Paul A. Patience <paul@apatience.com>
;;;; SPDX-License-Identifier: MIT

(:cc "clang"
 :cxx "clang++"
 :ld "lld"
 :ldflags "-Wl,-rpath,/gnu/store/hy7iygx3y6p79fn5c21spr1j8bxn9mmn-llvm-18.1.4/lib -Wl,-rpath,/gnu/store/cn0vmkz3h0wz0wz6hbdnjv4zphzr8z06-fmt-10.2.1/lib -Wl,-rpath,/gnu/store/blls5q6cahn8p555kavqpi1flswkzvgg-gmp-6.2.1/lib -Wl,-rpath,/gnu/store/b6kjcpgzd6qcqn1cdcbn6k2pnr7gz7i4-libelf-0.8.13/lib -Wl,-rpath,/gnu/store/86d2d281hflnq05834xav1kdz3riaw70-clang-18.1.4/lib -Wl,-rpath,/gnu/store/k9q9jxsqldxz0yl65rcgpnnncqwha2qi-gcc-11.3.0-lib/lib"
 :skip-sync t) ; --skip-sync=nil to enable
