(lambda (sym fail)
  (let ([signatures (list "dtds.ss" "htmls.ss" "sgmls.ss")])
    (case sym
      [(name) "HTML"]
      [(compile-prefix) `(begin ,@(map (lambda (sig) `(require-library ,sig "html")) signatures))]
      [(compile-omit-files) signatures]
      [(compile-elaboration-zos) signatures]
      [else (fail)])))