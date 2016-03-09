-- | Lexical tokens generated by the lexer and consumed by the parser.
--
-- Probably the most boring module in the compiler.
module Language.Futhark.Parser.Tokens
  ( Token(..)
  )
  where

import Language.Futhark.Core (Int8, Int16, Int32, Int64, Name)

-- | A lexical token.  It does not itself contain position
-- information, so in practice the parser will consume tokens tagged
-- with a source position.
data Token = IF
           | THEN
           | ELSE
           | LET
           | LOOP
           | IN
           | INT
           | I8
           | I16
           | I32
           | I64
           | U8
           | U16
           | U32
           | U64
           | BOOL
           | CHAR
           | FLOAT
           | F32
           | F64
           | ID Name
           | STRINGLIT String
           | DEFAULT
           | INTLIT Int64
           | I8LIT Int8
           | I16LIT Int16
           | I32LIT Int32
           | I64LIT Int64
           | U8LIT Int8
           | U16LIT Int16
           | U32LIT Int32
           | U64LIT Int64
           | REALLIT Double
           | F32LIT Float
           | F64LIT Double
           | CHARLIT Char
           | PLUS
           | MINUS
           | TIMES
           | DIVIDE
           | MOD
           | QUOT
           | REM
           | EQU
           | EQU2
           | NEQU
           | LTH
           | GTH
           | LEQ
           | GEQ
           | POW
           | SHIFTL
           | SHIFTR
           | ZSHIFTR
           | BOR
           | BAND
           | XOR
           | LPAR
           | RPAR
           | LBRACKET
           | RBRACKET
           | LCURLY
           | RCURLY
           | COMMA
           | UNDERSCORE
           | FUN
           | FN
           | ARROW
           | SETTO
           | FOR
           | DO
           | WITH
           | SIZE
           | IOTA
           | REPLICATE
           | MAP
           | REDUCE
           | REDUCECOMM
           | RESHAPE
           | REARRANGE
           | TRANSPOSE
           | ZIPWITH
           | ZIP
           | UNZIP
           | UNSAFE
           | SCAN
           | SPLIT
           | CONCAT
           | FILTER
           | PARTITION
           | TRUE
           | FALSE
           | TILDE
           | AND
           | OR
           | EMPTY
           | COPY
           | WHILE
           | STREAM_MAP
           | STREAM_MAPPER
           | STREAM_RED
           | STREAM_REDPER
           | STREAM_SEQ
           | BANG
           | ABS
           | SIGNUM
           | EOF
           | INCLUDE
             deriving (Show, Eq)
