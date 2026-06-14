#include "defs.S"

.global check_cgi_path
.global get_cgi_header_field
.global parse_cgi_header_end
.global get_script_path_elements

.global script_name_buf
.global script_path_buf

.data
cgi_dir: .ascii DOCROOT
         .ascii CGI_DIR
.equ cgi_dir_len, . - cgi_dir

// Various linefeeds and such
crlf: .ascii "\r\n"
.equ crlf_len, . - crlf

header_end_crlf: .ascii "\r\n\r\n"
.equ header_end_crlf_len, . - header_end_crlf
header_end_lflf: .ascii "\n\n"
.equ header_end_lflf_len, . - header_end_lflf


.bss
.balign 8
.equ script_name_buf_size, 256
script_name_buf: .skip script_name_buf_size
script_name_buf_len: .skip 8
.balign 8
.equ script_path_buf_size, 4096
script_path_buf: .skip script_path_buf_size
script_path_buf_len: .skip 8


.text
.balign 4
// is filename_str a file within CGI_DIR?
// input
// none -- uses global data
//
// output
// clears carry if path IS in CGI_DIR. clears carry if path is NOT in CGI_DIR.
check_cgi_path:
    stp x29, x30, [sp, #-16]!

    // if filename len is shorter than cgi_dir_len - 1, it's definitely not
    // in cgi_dir/.
    // -1 to account for the possible missing /, if the request is for
    // "GET /cgi-bin", we want that to be treated as a CGI request, rather than
    // standard GET. we don't allow directory listing on cgi-bin/.
    ldr_l x0, filename_len
    mov x1, #(cgi_dir_len - 1)
    cmp x0, x1
    b.lo Lnot_cgi_file
bp1:
    // check if it matches CGI_DIR/, with the slash
    ldr_l x0, filename_str
    adr_l x1, cgi_dir
    mov x2, cgi_dir_len
    bl streqn_i
    cbnz x0, Lcgi_file
bp2:
    // if we're here, x0 was zero, so it wasn't a match... yet.
    // check if it matches CGI_DIR, without the slash
    ldr_l x0, filename_str
    adr_l x1, cgi_dir
    mov x2, #(cgi_dir_len - 1) // account for possible missing /
    bl streqn_i
    cbz x0, Lnot_cgi_file // ok, it wasnt CGI_DIR/ or CGI_DIR, so its not a match
bp3:
    // if they DO match, check the length. we want it to be the exact length of
    // CGI_DIR - 1, otherwise GET /cgi-binfoo would "match"
    ldr_l x0, filename_len
    mov x1, #(cgi_dir_len - 1)
    cmp x0, x1
    b.ne Lnot_cgi_file
    // fallthrough
Lcgi_file:
    mov x0, #0 // OK
    b Lccp_epilogue

Lnot_cgi_file:
    mov x0, #-1 // error :(
    // fallthrough
Lccp_epilogue:
    ldp x29, x30, [sp], #16
    ret

// find cgi header end, since cgi headers can use either \r\n\r\n or \n\n
// NOTE for CGI response parsing ONLY. DONT USE ON CLIENT REQUESTS. for
// parsing the original header from the client, use parse_header_end (parse.S)
// inputs
// x0 -> buffer (header, possibly has body trailing)
// x1 -> length of buffer
//
// returns
// x1 -> index of the first byte AFTER the terminator, or 0 if none found
// x2 -> length of half of the terminator, 2 (\r\n\r\n) or 1 (\n\n)
parse_cgi_header_end:
    mov x5, #0
    mov x6, #0
    mov x7, #0

    adr_l x2, header_end_crlf
    adr_l x16, header_end_lflf

Lpche_loop:
    cmp x5, x1
    b.hs Lpche_no_end_found

    ldrb w3, [x0, x5] // current input byte
    ldrb w4, [x2, x6]
    cmp w3, w4
    b.eq Lpche_crlf_correct
    b Lpche_crlf_incorrect

Lpche_crlf_correct:
    add x6, x6, #1 // increment local index into \r\n\r\n
    cmp x6, #4 // length of \r\n\r\n
    b.lo Lpche_check_lflf // it could be \n\n instead of \r\n\r\n, so check

    mov x2, #2 // matched \r\n\r\n. we want to trim the second half, so ret 2
    b Lpche_end_found

Lpche_crlf_incorrect:
    mov x6, #0 // reset index into header_end_crlf
    cmp w3, #'\r'
    b.ne Lpche_check_lflf
    mov x6, #1
    // fallthrough
Lpche_check_lflf:
    ldrb w4, [x16, x7]
    cmp w3, w4
    b.eq Lpche_lflf_correct
    b Lpche_lflf_incorrect

Lpche_lflf_correct:
    add x7, x7, #1
    cmp x7, #2 // length of \n\n
    b.lo Lpche_advance

    mov x2, #1 // matched \n\n. we want to trim the second half, so ret 2
    b Lpche_end_found

Lpche_lflf_incorrect:
    mov x7, #0 // reset index into header_end_lflf
    // fallthrough

Lpche_advance:
    add x5, x5, #1
    b Lpche_loop

Lpche_end_found:
    add x1, x5, #1 // skip past the final \n
    ret

Lpche_no_end_found:
    mov x1, #0
    ret

// same deal. checks for \n instead of \r\n, since cgi is different.
// input
// x0 -> header buffer
// x1 -> length of header
// x2 -> field to search for
// x3 -> length of x2
//
// return
// x0 -> pointer to the beginning of the header value, or NULL on error
// x1 -> length in said value
get_cgi_header_field:
    stp x29, x30, [sp, #-64]!
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    str x23, [sp, #48]

    mov x19, x0 // header
    mov x20, x1 // length
    mov x21, #0 // index
    mov x22, x2 // field string
    mov x23, x3 // field string length

gchf_check:
    add x0, x19, x21
    mov x1, x22
    mov x2, x23
    bl streqn_i
    cbz x0, gchf_scan

    // if we're here, it was a match!
    add x21, x21, x23
    // but if the header literally ends at "Field:" with nothing following, it's
    // malformed as shit
    cmp x21, x20
    b.hs L502 // tbh i dont even know if this 502 will write to the client lol
    // fallthrough
gchf_skip_ws:
    ldrb w2, [x19, x21]
    cmp w2, #' '
    b.eq gchf_skip_ws_next
    cmp w2, #'\t'
    b.eq gchf_skip_ws_next

    // once we're here, we've skipped all the whitespace!
    // now we've got to find the length of the value
    add x0, x19, x21 // save pointer to start of value
    mov x1, #0
1:
    ldrb w2, [x0, x1]
    cmp w2, #'\n'
    b.eq 2f
    cmp w2, #'\r'
    b.eq 2f

    add x1, x1, #1
    add x21, x21, #1
    cmp x21, x20
    b.lo 1b
    // fallthrough
2:
    // now x0 points to start of value,
    // x1 is length of value.
    b gchf_epilogue

gchf_skip_ws_next:
    add x21, x21, #1
    cmp x21, x20
    b.hs L502
    b gchf_skip_ws

gchf_scan:
    // check your boundaries!
    cmp x21, x20
    b.hs gchf_not_found

    ldrb w2, [x19, x21]
    add x21, x21, #1
    cmp w2, #'\n'
    b.ne gchf_scan

    // if we're here, start of a new line. check and the party starts again
    b gchf_check

gchf_not_found:
    mov x0, #0
    mov x1, #0
    // fallthrough
gchf_epilogue:
1:
    ldr x23, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #64
    ret

L502:
    mov x0, #502
    mov x1, #0
    b reply_status


// read filename_str, and break "/www/cgi-bin/foobar" into "/www/cgi-bin/" in
// script_path_buf, and "foobar" in script_name_buff. doesnt modify
// filename_str.
// input
// none, reads from globals
//
// returns
// nothing, writes to memory
get_script_path_elements:
    stp x29, x30, [sp, #-32]!
    stp x19, x20, [sp, #16]

    ldr_l x19, filename_str
    ldr_l x20, filename_len

    // find the index of the last /
    mov x0, x20
1:
    cmp x0, #0
    b.eq Lgspe_error
    ldrb w1, [x19, x0]
    cmp w1, #'/'
    b.eq 2f
    sub x0, x0, #1
    b 1b
2:
    // the index of the last slash is now in x0
    // add one to it so we dont copy /name_with_slash to script_name_buf, and
    // instead copy path/with/slash/ to script_path_buf
    add x0, x0, #1
    // if the very last char was a /, it's a directory being requested, and
    // that's no good.
    cmp x0, x20
    b.hs Lgspe_error

    mov x3, x0 // and in x3 lol
    mov x4, #0 // offset into script_name_buf
    adr_l x1, script_name_buf

    // copy from / to the end of string into script_name_buf
1:
    cmp x0, x20
    b.eq 2f
    cmp x4, script_name_buf_size
    b.eq 2f
    ldrb w2, [x19, x0]
    strb w2, [x1, x4]
    add x0, x0, #1
    add x4, x4, #1
    b 1b
2:
    // make sure script_name_buf is null terminated
    strb wzr, [x1, x4]
    str_l x4, script_name_buf_len // save the length of the script name

    mov x4, #0
    adr_l x1, script_path_buf
    // now we copy from the start of filename_len up to the first /, into
    // script_path_buf
1:
    cmp x4, x3
    b.eq 2f
    cmp x4, script_path_buf_size
    b.eq 2f
    ldrb w2, [x19, x4]
    strb w2, [x1, x4]
    add x4, x4, #1
    b 1b
2:
    // and make sure script_path_buf is NULL terminated too!
    strb wzr, [x1, x4]
    str_l x4, script_path_buf_len // save the length of script_path_buf too

    b Lgspe_epilogue

Lgspe_error:
    mov x0, #-1
    b 1f

Lgspe_epilogue:
    mov x0, #0
1:
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret
