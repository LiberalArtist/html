;; copyright by Paul Graunke June 2000 AD
;; warning - this was copied from the XML collection.
;; It needs to be abstracted back in.

(unit/sig sgml-reader^
  (import xml-structs^ mzlib:function^)
  
  ;; Start-tag ::= (make-start-tag Location Location Symbol (listof Attribute))
  (define-struct (start-tag struct:source) (name attrs))
  
  ;; End-tag ::= (make-end-tag Location Location Symbol)
  (define-struct (end-tag struct:source) (name))
  
  ;; Token ::= Contents | Start-tag | End-tag | Eof
  
  (define read-comments (make-parameter #f))
  (define trim-whitespace (make-parameter #f))
  
  ;; Kid-lister : (Symbol -> (U (listof Symbol) #f))
  
  ;; gen-may-contain : Spec -> Kid-lister
  (define (gen-may-contain spec)
    (let ([table (make-hash-table)])
      (for-each (lambda (def)
                  (let ([rhs (cdr def)])
                    (for-each (lambda (name) (hash-table-put! table name rhs))
                              (car def))))
                spec)
      (lambda (name)
        (hash-table-get table name (lambda () #f)))))
  
  ;; gen-read-sgml : Kid-lister -> [Input-port] -> (listof Content)
  (define (gen-read-sgml may-contain)
    (case-lambda
     [(in) (read-from-port may-contain in)]
     [() (read-from-port may-contain (current-input-port))]))
  
  ;; read-from-port : Kid-lister Input-port -> (listof Content)
  (define (read-from-port may-contain in)
    (let loop ([tokens (let read-tokens ()
                         (let ([tok (lex in)])
                           (cond
                             [(eof-object? tok) null]
                             [else (cons tok (read-tokens))])))])
      (cond
        [(null? tokens) null]
        [else
         (let ([tok (car tokens)] [rest-tokens (cdr tokens)])
           (cond
             [(eof-object? tok) null]
             [(start-tag? tok)
              (let-values ([(el more-tokens) (read-element tok may-contain rest-tokens)])
                (cons el (loop more-tokens)))]
             [(end-tag? tok) (loop rest-tokens)]
             [else (let ([rest-contents (loop rest-tokens)])
                     (expand-content tok rest-contents))]))])))
  
  ;; read-element : Start-tag Kid-lister (listof Token) -> Element (listof Token)
  ;; Note: How elements nest depends on their content model.
  ;;   If a kind of element can't contain anything, then its start tags are implicitly ended, and
  ;;   end tags are implicitly started.
  ;;   Unknown elements can contain anything and can go inside anything.
  ;;   Otherwise, only the subelements listed in the content model can go inside an element.
  ;; more here - may-contain shouldn't be used to decide if an element is known or not.
  ;;             The edgar dtd puts tags in may-contain's range that aren't in its domain.
  (define (read-element start-tag may-contain tokens)
    (let* ([start-name (start-tag-name start-tag)]
           [ok-kids (may-contain start-name)])
      (let-values ([(content remaining)
                    (cond
                      [(null? ok-kids) (values null tokens)]
                      [else 
                       ;; read-content : (listof Token) -> (listof Content) (listof Token)
                       (let read-content ([tokens tokens])
                         (cond
                           [(null? tokens) (values null tokens)]
                           [else
                            (let ([tok (car tokens)] [next-tokens (cdr tokens)])
                              (cond
                                [(start-tag? tok)
                                 (if (and ok-kids
                                          (not (memq (start-tag-name tok) ok-kids))
                                          (may-contain (start-tag-name tok)))
                                     (values null tokens)
                                     (let*-values ([(element post-element) (read-element tok may-contain next-tokens)]
                                                   [(more-contents left-overs) (read-content post-element)])
                                       (values (cons element more-contents) left-overs)))]
                                [(end-tag? tok)
                                 (if (null? (may-contain tok))
                                     (let-values ([(more-contents left-overs) (read-content next-tokens)])
                                       (values (make-element (source-start tok)
                                                             (source-stop tok)
                                                             (end-tag-name tok)
                                                             null null)
                                               left-overs))
                                     (if (eq? (end-tag-name tok) start-name)
                                         (values null next-tokens)
                                         (values null tokens)))]
                                [else ;; content
                                 (let-values ([(more-contents left-overs) (read-content next-tokens)])
                                   (values
                                    (expand-content tok more-contents)
                                    left-overs))]))]))])])
        (values (make-element (source-start start-tag)
                              (source-stop start-tag)
                              start-name
                              (start-tag-attrs start-tag)
                              content)
                remaining))))
  
  ;; expand-content : Content (listof Content) -> (listof Content)
  (define (expand-content x lst)
    (cond
      [(entity? x) (cons (expand-entity x) lst)]
      [(comment? x) (if (read-comments)
                        (cons x lst)
                        lst)]
      [else (cons x lst)]))
  
  ;; expand-entity : Entity -> (U Entity Pcdata)
  ;; more here - allow expansion of user defined entities
  (define (expand-entity x)
    (let ([expanded (default-entity-table (entity-text x))])
      (if expanded
          (make-pcdata (source-start x) (source-stop x) expanded)
          x)))
  
  ;; default-entity-table : Symbol -> (U #f String)
  (define (default-entity-table name)
    (case name
      [(amp) "&"]
      [(lt) "<"]
      [(gt) ">"]
      [(quot) "\""]
      [(apos) "'"]
      [else #f]))
  
  ;; lex : Input-port -> Token
  (define (lex in)
    (when (trim-whitespace)
      (skip-space in))
    (let ([c (peek-char in)])
      (cond
        [(eof-object? c) c]
        [(eq? c #\&) (lex-entity in)]
        [(eq? c #\<) (lex-tag-cdata-pi-comment in)]
        [else (lex-pcdata in)])))
  
  ;; lex-entity : Input-port -> Token
  ;; This might not return an entity if it doesn't look like one afterall.
  (define (lex-entity in)
    (let ([start (file-position in)])
      (read-char in)
      (case (peek-char in)
        ;; more here - read while it's numeric (or hex) not until #\;
        [(#\#)
         (read-char in)
         (let* ([str (read-until #\; in)]
                [n (case (peek-char in)
                     [(#\x) (read-char in)
                      (string->number str 16)]
                     [else (string->number str)])])
           (if (number? n)
               (make-entity start (file-position in) n)
               (make-pcdata start (file-position in) (string-append "&#" str))))]
        [else
         (let ([name (lex-name in)]
               [c (peek-char in)])
           (if (eq? c #\;)
               (begin (read-char in) (make-entity start (file-position in) name))
               (make-pcdata start (file-position in) (format "&~a" name))))])))
  
  ;; lex-tag-cdata-pi-comment : Input-port -> Start-tag | Element | End-tag | Pcdata | Pi | Comment
  (define (lex-tag-cdata-pi-comment in)
    (let ([start (file-position in)])
      (read-char in)
      (case (non-eof peek-char in)
        [(#\!)
         (read-char in)
         (case (non-eof peek-char in)
           [(#\-) (read-char in)
            (let ([c (read-char in)])
              (cond
                [(eq? c #\-)
                 (let ([data (lex-comment-contents in)])
                   (make-comment data))]
                [else (make-pcdata start (file-position in) (format "<!-~a" c))]))]
           [(#\[) (read-char in)
            (let ([s (read-string 6 in)])
              (if (string=? s "CDATA[")
                  (let ([data (lex-cdata-contents in)])
                    (make-pcdata start (file-position in) data))
                  (make-pcdata start (file-position in) (format "<[~a" s))))]
           [else (skip-dtd in) (lex in)])]
        [(#\?) (read-char in)
         (let ([name (lex-name in)])
           (skip-space in)
           (let ([data (lex-pi-data in)])
             (make-pi start (file-position in) name data)))]
        [(#\/) (read-char in)
         (let ([name (lex-name in)])
           (skip-space in)
           (read-char in) ;; skip #\> or whatever else is there
           (make-end-tag start (file-position in) name))]
        [else
         (let ([name (lex-name in)]
               [attrs (lex-attributes in)])
           (skip-space in)
           (case (read-char in)
             [(#\/)
              (read-char in) ;; skip #\> or something
              (make-element start (file-position in) name attrs null)]
             [else (make-start-tag start (file-position in) name attrs)]))])))
  
  
  ;; lex-attributes : Input-port -> (listof Attribute)
  (define (lex-attributes in)
    (quicksort (let loop ()
                 (skip-space in)
                 (cond
                   [(name-start? (peek-char in))
                    (cons (lex-attribute in) (loop))]
                   [else null]))
               (lambda (a b)
                 (string<? (symbol->string (attribute-name a))
                           (symbol->string (attribute-name b))))))
  
  ;; lex-attribute : Input-port -> Attribute
  ;; Note: entities in attributes are ignored, since defacto html uses & in them for URL syntax
  (define (lex-attribute in)
    (let ([start (file-position in)]
          [name (lex-name in)])
      (skip-space in)
      (cond
        [(eq? (peek-char in) #\=)
         (read-char in)
         (skip-space in)
         (let* ([delimiter (read-char in)]
                [value (case delimiter
                         [(#\' #\")
                          (list->string
                           (let read-more ()
                             (let ([c (non-eof peek-char in)])
                               (cond
                                 [(eq? c delimiter) (read-char in) null]
                                 [else (read-char in) (cons c (read-more))]))))]
                         [else (read-up-to (lambda (c) (or (char-whitespace? c) (eq? c #\>))) in)])])
           (make-attribute start (file-position in) name value))]
        [else (make-attribute start (file-position in) name (symbol->string name))])))
  
  ;; skip-space : Input-port -> Void
  ;; deviation - should sometimes insist on at least one space
  (define (skip-space in)
    (let loop ()
      (let ([c (peek-char in)])
        (when (and (not (eof-object? c)) (char-whitespace? c))
          (read-char in)
          (loop)))))
  
  ;; lex-pcdata : Input-port -> Pcdata
  ;; deviation - disallow ]]> "for compatability" with SGML, sec 2.4 XML spec 
  (define (lex-pcdata in)
    (let ([start (file-position in)]
          [data (let loop ([c (read-char in)])
                  (let ([next (peek-char in)])
                    (cond
                      [(or (eof-object? next) (eq? next #\&) (eq? next #\<))
                       (list c)]
                      [(and (char-whitespace? next) (trim-whitespace))
                       (skip-space in)
                       (let ([lst (loop #\space)])
                         (cond
                           [(null? (cdr lst)) (list c)]
                           [else (cons c lst)]))]
                      [else (cons c (loop (read-char in)))])))])
      (make-pcdata start
                   (file-position in)
                   (list->string data))))
  
  ;; lex-name : Input-port -> Symbol
  (define (lex-name in)
    (string->symbol
     (list->string
      (let lex-rest ()
        (cond
          [(name-char? (peek-char in))
           (cons (char-downcase (read-char in)) (lex-rest))]
          [else null])))))
  
  ;; skip-dtd : Input-port -> Void
  (define (skip-dtd in)
    (let skip ()
      (case (non-eof read-char in)
        [(#\') (read-until #\' in) (skip)]
        [(#\") (read-until #\" in) (skip)]
        [(#\<)
         (case (non-eof read-char in)
           [(#\!) (case (non-eof read-char in)
                    [(#\-) (read-char in) (lex-comment-contents in) (skip)]
                    [else (skip) (skip)])]
           [(#\?) (lex-pi-data in) (skip)]
           [else (skip) (skip)])]
        [(#\>) (void)]
        [else (skip)])))
  
  ;; name-start? : Char -> Bool
  (define (name-start? ch)
    (or (char-alphabetic? ch) 
        (eq? ch #\_)
        (eq? ch #\:)))
  
  ;; name-char? : Char -> Bool
  (define (name-char? ch)
    (or (name-start? ch)
        (char-numeric? ch)
        (eq? ch #\&) ; ugly illegal junk for SEC's EDGAR database
        (eq? ch #\.)
        (eq? ch #\-)))
  
  ;; read-up-to : (Char -> Bool) Input-port
  ;; abstract this with read-until
  (define (read-up-to p? in)
    (list->string
     (let loop ()
       (let ([c (peek-char in)])
         (cond
           [(or (eof-object? c) (p? c)) null]
           [else (cons (read-char in) (loop))])))))
  
  ;; read-until : Char Input-port -> String
  ;; discards the stop character, too
  (define (read-until char in)
    (list->string
     (let read-more ()
       (let ([c (read-char in)])
         (cond
           [(or (eof-object? c) (eq? c char)) null]
           [else (cons c (read-more))])))))
  
  ;; non-eof : (Input-port -> (U Char Eof)) Input-port -> Char
  (define (non-eof f in)
    (let ([c (f in)])
      (cond
        [(eof-object? c) (lex-error in "unexpected eof")]
        [else c])))
  
  ;; gen-read-until-string : String -> Input-port -> String
  ;; uses Knuth-Morris-Pratt from
  ;; Introduction to Algorithms, Cormen, Leiserson, and Rivest, pages 869-876
  ;; discards stop from input
  (define (gen-read-until-string stop)
    (let* ([len (string-length stop)]
           [prefix (make-vector len 0)]
           [fall-back
            (lambda (k c)
              (let ([k (let loop ([k k])
                         (cond
                           [(and (> k 0) (not (eq? (string-ref stop k) c)))
                            (loop (vector-ref prefix (sub1 k)))]
                           [else k]))])
                (if (eq? (string-ref stop k) c)
                    (add1 k)
                    k)))])
      (let init ([k 0] [q 1])
        (when (< q len)
          (let ([k (fall-back k (string-ref stop q))])
            (vector-set! prefix q k)
            (init k (add1 q)))))
      ;; (vector-ref prefix x) = the longest suffix that matches a prefix of stop
      (lambda (in)
        (list->string
         (let/ec out
           (let loop ([matched 0] [out out])
             (let* ([c (read-char in)]
                    [matched (fall-back matched c)])
               (cond
                 [(= matched len) (out null)]
                 [(zero? matched) (cons c (let/ec out (loop matched out)))]
                 [else (cons c (loop matched out))]))))))))
  
  ;; "-->" makes more sense, but "--" follows the spec, but this isn't XML anymore.
  (define lex-comment-contents (gen-read-until-string "-->"))
  (define lex-pi-data (gen-read-until-string "?>"))
  (define lex-cdata-contents (gen-read-until-string "]]>"))
  
  ;; lex-error : Input-port String TST* -> alpha
  (define (lex-error in str . rest)
    (error 'lex-error " at positon ~a: ~a" (file-position in)
           (apply format str rest))))