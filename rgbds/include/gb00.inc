; ---- GB00 authentication: constants shared across translation units ----
;
; These live in a header rather than in gb00_auth.asm because rgbasm
; assembles each file independently: `EXPORT DEF` makes a symbol
; resolvable by the LINKER, but a constant used in an ASSERT, a `ds`
; size or any other compile-time expression has to be known while the
; including file is being assembled. big_buffer.asm needs exactly that
; (its request-buffer size assertions are computed from
; GB00_AUTHORIZATION_LEN), so the definitions belong here and
; gb00_auth.asm includes them like everyone else.
;
; See gbdk/include/gb00_auth.h for what these mean and where the values
; came from; the derivation itself is in gbdk/docs/protocol-notes.md,
; "GB00 HTTP authentication".

IF !DEF(GB00_INC)
DEF GB00_INC EQU 1

; The WWW-Authenticate "name" value is always exactly this many base64
; characters (36 raw bytes; 36 % 3 == 0, so no "=" padding).
DEF GB00_CHALLENGE_LEN EQU 48

; The Authorization "name" value built in response (44 + 48 characters).
DEF GB00_AUTHORIZATION_LEN EQU 92

; Sized against a real nginx 401 challenge response measured from a BGB
; link-log capture -- see gb00_auth.asm's own note before changing it.
DEF GB00_RESP_BUF_SIZE EQU 360

DEF GB00_MAX_EMPTY_POLLS EQU 5

ENDC
