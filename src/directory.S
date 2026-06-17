// This file is part of ymawky.
// Copyright (C) 2026 imtomt
//
// ymawky is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 3.
//
// ymawky is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with ymawky. If not, see <https://www.gnu.org/licenses/>.

#include "defs.S"

.global dir_listing
.global write_with_chunk_length

.data
// This is used to build the Directory Listing html page:
// <!DOCTYPE html>
// <html><head><title>DIRECTORY</title><head>
// <body><h1>Index of DIRECTORY</h1>
// <p><a href="ELEMENT1">ELEMENT1</a></p>
// <p><a href="ELEMENT2">ELEMENT2</a></p>
// ...
// </body></html>
// (although there aren't newlines in the actual data to save space)
listing_head_p1: .ascii "<!DOCTYPE html><html><head><style>body{background:#1a1a2e;color:#c9b0ff;font-family:\"Arial Rounded MT Bold\",\"Helvetica Rounded\",system-ui,sans-serif;font-weight:400;margin:0;height:100vh;overflow:hidden}.heading{position:absolute;top:0;left:0;right:15px;width:100vw;height:50vh;display:flex;flex-direction:column;justify-content:center;align-items:center;text-align:center}.heading h1{font-size:6em;margin:0;font-weight:400}a{margin-left:20px;font-weight:400;color:#c9b0ff;top:0;left:15px}a:visited{color:#666}.footer{position:absolute;bottom:5px;left:0;width:100vw;text-align:center;color:#666;font-size:.8em}</style><title>"
.equ listing_head_p1_len, . - listing_head_p1
// current dir goes here
listing_base_p1: .ascii "</title><base href=\"/"
.equ listing_base_p1_len, . - listing_base_p1
// current dir goes here also
listing_base_p2: .ascii "/\">"
.equ listing_base_p2_len, . - listing_base_p2

listing_head_p2: .ascii "</head><body><h1>Index of "
.equ listing_head_p2_len, . - listing_head_p2
// current dir goes here too
listing_head_p3: .ascii "/</h1>"
.equ listing_head_p3_len, . - listing_head_p3

// this is the reused part for each line
listing_chunk_p1: .ascii "<a href=\""
.equ listing_chunk_p1_len, . - listing_chunk_p1
// newdir goes here
listing_chunk_p2: .ascii "\">"
.equ listing_chunk_p2_len, . - listing_chunk_p2
// newdir goes here too
listing_chunk_p3: .ascii "</a><br>"
.equ listing_chunk_p3_len, . - listing_chunk_p3

// this is at the end
listing_tail: .ascii "</body><div class=\"footer\"><small>ymawky :: hand-rolled aarch64</small></div></html>"
.equ listing_tail_len, . - listing_tail

// stuff for chunked encoding
crlf: .ascii "\r\n"
.equ crlf_len, . - crlf
// end of the message
chunked_content_end: .ascii "0\r\n\r\n"
.equ chunked_content_end_len, . - chunked_content_end

encoded_quote: .ascii "&quot;"
.equ encoded_quote_len, . - encoded_quote
encoded_apost: .ascii "&#39;"
.equ encoded_apost_len, . - encoded_apost
encoded_amp: .ascii "&amp;"
.equ encoded_amp_len, . - encoded_amp
encoded_gt: .ascii "&gt;"
.equ encoded_gt_len, . - encoded_gt
encoded_lt: .ascii "&lt;"
.equ encoded_lt_len, . - encoded_lt

// chunked encoding header. TODO refactor build_header to incorporate this
// and other potential header fields
header: .ascii "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nTransfer-Encoding: chunked\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\nAllow: GET, HEAD, OPTIONS, DELETE, PUT\r\nAccept-Ranges: bytes\r\nServer: ymawky\r\n\r\n"
.equ header_len, . - header

hex_digits: .ascii "0123456789ABCDEF"

.bss
.balign 8
hex_itoa_buf: .skip 16
.equ chunk_buf_size, 4096 // 4kb buffer for each chunk
chunk_buf: .skip chunk_buf_size

.text
.balign 8
// x0 -> dest current
// x1 -> source literal
// x2 -> source length
//
// returns
// x0 -> destination offset to new current, or -1 on error
append_literal:
    stp x29, x30, [sp, #-32]!
    stp x19, x20, [sp, #16]

    mov x19, x0
    mov x20, x1

    // bounds check stuff
    adr_l x3, chunk_buf
    sub x4, x19, x3
    mov x5, chunk_buf_size
    sub x4, x5, x4 // x4 is remaining bytes

    cmp x4, x2
    b.lo 1f

    mov x0, x19
    mov x1, x20
    // x2 is already set by caller
    bl memcpy

    b 2f
1:
    mov x0, #-1
    // fallthrough
2:
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32

    ret

// x0 -> destination
// x1 -> source
// x2 -> dest length
// x3 -> source length
// x4 -> allow /? 0 -> no, turn / into %2F// 1 -> yes, keep / as /
//
// returns
// x0 -> destination with pointer offset, or -1 on error
// x1 -> bytes written
href_encode:
    stp x29, x30, [sp, #-80]!
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    str x25, [sp, #64]

    mov x19, x0      // dst current
    mov x23, x0      // dst start
    mov x20, x1      // src current
    mov x21, x2      // dst remaining
    mov x22, x3      // src remaining
    mov x25, x4      // encode /?

href_encode_loop:
    cbz x22, href_done
    cbz x21, href_overflow

    ldrb w24, [x20], #1
    sub x22, x22, #1

    cmp w24, #'A'
    b.lo href_check_lower
    cmp w24, #'Z'
    b.ls href_raw

href_check_lower:
    // a-z
    cmp w24, #'a'
    b.lo href_check_digit
    cmp w24, #'z'
    b.ls href_raw

href_check_digit:
    // 0-9
    cmp w24, #'0'
    b.lo href_check_punct
    cmp w24, #'9'
    b.ls href_raw

href_check_punct:
    cmp w24, #'-'
    b.eq href_raw
    cmp w24, #'.'
    b.eq href_raw
    cmp w24, #'_'
    b.eq href_raw
    cmp w24, #'~'
    b.eq href_raw

    cmp x25, #0 // if we want to encode / anyway, just check now and go.
    b.eq href_percent

    cmp w24, #'/' // otherwise, check if the current char is //
    b.eq href_raw // and treat it as literal if so

    b href_percent // otherwise percent encode it

href_raw:
    // byte is safe to copy as-is. A-Za-z0-9 .-_~
    strb w24, [x19], #1
    sub x21, x21, #1
    b href_encode_loop

href_percent:
    // need 3 bytes for output: %xx
    cmp x21, #3
    b.lo href_overflow

    mov w0, #'%'
    strb w0, [x19], #1

    adr_l x10, hex_digits

    // high nibble
    lsr w0, w24, #4
    and w0, w0, #0xf
    ldrb w0, [x10, x0]
    strb w0, [x19], #1

    // low nibble
    and w0, w24, #0xf
    ldrb w0, [x10, x0]
    strb w0, [x19], #1

    sub x21, x21, #3
    b href_encode_loop

href_overflow:
    mov x0, #-1
    sub x1, x19, x23
    b href_epilogue

href_done:
    mov x0, x19
    sub x1, x19, x23
    // fallthrough
href_epilogue:
    ldr x25, [sp, #64]
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #80
    ret


// input
// x0 -> destination
// x1 -> source
// x2 -> destination length
// x3 -> source length
//
// return:
body_encode:
    stp x29, x30, [sp, #-64]!
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    str x23, [sp, #48]

    mov x19, x0 // dest
    mov x23, x0
    mov x20, x1 // source
    mov x21, x2 // dest length
    mov x22, x3 // source length

body_encode_loop:
    cbz x22, Ldone // source fully consumed? success
    cbz x21, Loverflow // overflow if there's more source but dst is full

    ldrb w0, [x20], #1
    cmp w0, #'&'
    b.eq Lamp
    cmp w0, #'"'
    b.eq Lquot
    cmp w0, #'>'
    b.eq Lgt
    cmp w0, #'<'
    b.eq Llt
    cmp w0, #0x27 // apostrophe '
    b.eq Lapost

    strb w0, [x19], #1

    sub x21, x21, #1 // consumed 1 byte to dest
1:
    sub x22, x22, #1 // only consumed 1 byte from source
    b body_encode_loop

Lamp:
    mov x0, encoded_amp_len
    adr_l x1, encoded_amp
    b Lcopy_encoding

Lquot:
    mov x0, encoded_quote_len
    adr_l x1, encoded_quote
    b Lcopy_encoding

Lgt:
    mov x0, encoded_gt_len
    adr_l x1, encoded_gt
    b Lcopy_encoding

Llt:
    mov x0, encoded_lt_len
    adr_l x1, encoded_lt
    b Lcopy_encoding

Lapost:
    mov x0, encoded_apost_len
    adr_l x1, encoded_apost
    b Lcopy_encoding

Lcopy_encoding:
    cmp x21, x0
    b.lo Loverflow

    sub x21, x21, x0 // consumed multiple bytes to dest

    mov x2, x0
    // x1 is already set
    mov x0, x19
    bl memcpy
    mov x19, x0

    b 1b

Loverflow:
    mov x0, #-1
    sub x1, x19, x23 // bytes written
    b 2f

Ldone:
    mov x0, x19 // pointer to destination, offset
    sub x1, x19, x23 // bytes written
    // fallthrough
2:
    ldr x23, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #64

    ret

// input
// x0 -> filedes to write to
// x1 -> content
// x2 -> length
write_with_chunk_length:
    stp x29, x30, [sp, #-48]!
    stp x19, x20, [sp, #16]
    str x21, [sp, #32]

    mov x19, x0 // file descriptor
    mov x20, x1 // content
    mov x21, x2 // length

    // encode chunk length to hex
    mov x0, x21
    adr_l x1, hex_itoa_buf
    bl hex_itoa
    // x0 -> number of digits
    // x1 -> pointer to start of string

    // write content length in hex
    mov x2, x0
    // x1 should already be set by hex_itoa
    mov x0, x19
    bl write_all

    // write \r\n
    mov x0, x19
    adr_l x1, crlf
    mov x2, crlf_len
    bl write_all

    // write content
    mov x0, x19
    mov x1, x20
    mov x2, x21
    bl write_all

    // write \r\n again
    mov x0, x19
    adr_l x1, crlf
    mov x2, crlf_len
    bl write_all

    ldr x21, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48

    ret

// input
// x0 -> filename
// x1 -> filename length
// x2 -> file type (directory?)
//
// returns
// nothing?
write_chunk:
    stp x29, x30, [sp, #-48]!
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]

    mov x19, x0
    mov x20, x1
    mov x21, x2

    // copy <p><a href="
    adr_l x0, chunk_buf
    adr_l x1, listing_chunk_p1
    mov x2, listing_chunk_p1_len
    bl append_literal
    b_err wc_overflow
    mov x22, x0 // save offset

    // copy filename, again
    adr_l x0, chunk_buf
    sub x2, x22, x0 // bytes already used
    mov x1, chunk_buf_size
    sub x2, x1, x2 // remaining dest space

    mov x0, x22
    mov x1, x19
    // x2 is already set
    mov x3, x20
    mov x4, #0
    bl href_encode
    b_err wc_overflow
    mov x22, x0

    // copy the / if it's a dir
    cmp x21, #DT_DIR
    b.ne 1f

    adr_l x0, chunk_buf
    sub x1, x22, x0 // bytes used so far
    mov x2, chunk_buf_size
    sub x2, x2, x1 // remaining space
    cbz x2, wc_overflow // oh :( so tiny :( no room for even 1 a single byte :(

    mov w3, #'/'
    strb w3, [x22], #1 // append the / and advance the pointer
1:
    // copy "\">"
    mov x0, x22
    adr_l x1, listing_chunk_p2
    mov x2, listing_chunk_p2_len
    bl append_literal
    b_err wc_overflow
    mov x22, x0

    // copy filename, again
    adr_l x16, chunk_buf
    sub x2, x22, x16 // bytes already used
    mov x7, chunk_buf_size
    sub x2, x7, x2 // x2 = remaining destination space

    mov x0, x22
    mov x1, x19
    mov x3, x20
    bl body_encode
    b_err wc_overflow
    mov x22, x0

    // append '/' to directories in the list
    cmp x21, #DT_DIR
    b.ne 1f // not a dir, skip the slash

    adr_l x0, chunk_buf
    sub x1, x22, x0 // bytes used so far
    mov x2, chunk_buf_size
    sub x2, x2, x1 // remaining
    cbz x2, wc_overflow // so tiny :( no room for even 1 byte :(

    mov w3, #'/'
    strb w3, [x22], #1 // append slash and advance the pointer
1:
    // copy "</a></p>"
    mov x0, x22
    adr_l x1, listing_chunk_p3
    mov x2, listing_chunk_p3_len
    bl append_literal
    b_err wc_overflow
    mov x22, x0

wc_done:
    ldr_l x0, clientfd
    adr_l x1, chunk_buf
    sub x2, x22, x1
    bl write_with_chunk_length

    b wc_epilogue
wc_overflow:
    // fallthrough
    // don't write the chunk

wc_epilogue:
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48

    ret

// input
// x0 -> filename
// x1 -> filename length
//
// returns
// nothing?
write_chunk_head:
    stp x29, x30, [sp, #-48]!
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]

    mov x19, x0 // filename
    mov x20, x1 // filename length

    // copy it
    adr_l x0, chunk_buf
    adr_l x1, listing_head_p1
    mov x2, listing_head_p1_len
    bl append_literal
    mov x22, x0

    // copy filename
    adr_l x16, chunk_buf
    sub x2, x22, x16 // bytes already used
    mov x7, chunk_buf_size
    sub x2, x7, x2 // x2 = remaining destination space

    mov x0, x22
    mov x1, x19
    // x2 is set
    mov x3, x20
    bl body_encode
    b_err wch_overflow
    mov x22, x0

    // copy the base part
    mov x0, x22
    adr_l x1, listing_base_p1
    mov x2, listing_base_p1_len
    bl append_literal
    b_err wch_overflow
    mov x22, x0

    // filename again
    adr_l x16, chunk_buf
    sub x2, x22, x16 // bytes already used
    mov x7, chunk_buf_size
    sub x2, x7, x2 // x2 = remaining destination space

    mov x0, x22
    mov x1, x19
    // x2 is set
    mov x3, x20
    mov x4, #1 // treat / as literal in href_encode
    bl href_encode
    b_err wch_overflow
    mov x22, x0

    // copy the end of the base thing
    mov x0, x22
    adr_l x1, listing_base_p2
    mov x2, listing_base_p2_len
    bl append_literal
    b_err wch_overflow
    mov x22, x0

    // copy part 2
    mov x0, x22
    adr_l x1, listing_head_p2
    mov x2, listing_head_p2_len
    bl append_literal
    b_err wch_overflow
    mov x22, x0

    // copy filename, again
    adr_l x16, chunk_buf
    sub x2, x22, x16 // bytes already used
    mov x7, chunk_buf_size
    sub x2, x7, x2 // x2 = remaining destination space

    mov x0, x22
    mov x1, x19
    // x2 is set
    mov x3, x20
    bl body_encode
    b_err wch_overflow
    mov x22, x0

    mov x0, x22
    adr_l x1, listing_head_p3
    mov x2, listing_head_p3_len
    bl append_literal
    b_err wch_overflow
    mov x22, x0

    ldr_l x0, clientfd
    adr_l x1, chunk_buf
    sub x2, x22, x1 // actual length = current - base
    bl write_with_chunk_length

wch_overflow:
    mov x0, #-1
    // fallthrough
wch_epilogue:
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48

    ret


// input
// x0 -> open file descriptor
// x1 -> filename string
// x2 -> filename length
//
// returns
// nothing
dir_listing:
    mov x20, x0 // file descriptor
    mov x21, x1 // filename
    mov x22, x2 // filename len

    mov x0, ALLOW_DIR_LISTING
    cbz x0, L403

    ldr_l x0, docroot_len
    add x21, x21, x0 // skip past the docroot
    sub x22, x22, x0 // decrement filename size to account for it

    // strip a trailing slash if present. write_chunk_head and listing_base_p1
    // and listing_base_p2 will always add a / and we don't want double-doodie
    cbz x22, Lno_strip
    add x1, x21, x22
    sub x1, x1, #1 // pointer to last byte

    ldrb w2, [x1]
    cmp w2, #'/'
    b.ne Lno_strip
    sub x22, x22, #1 // remove the trailing slash from length

Lno_strip:
    ldr_l x0, clientfd
    adr_l x1, header
    mov x2, header_len
    bl write_all

    mov x0, x21
    mov x1, x22
    bl write_chunk_head

    // 8KB + 8 bytes for basep + align stack to 16 bytes
    mov x0, #8208
    sub sp, sp, x0
    str xzr, [sp, #8192] // initialize *basep to 0

gde_loop:
    // #8192 is too big for add (0-4096), so we gotta load it into a register
    // first, and do add xN, xN, x0.
    mov x8, SYS_getdents64
    mov x0, #8192
    mov x1, sp
    mov x2, x0 // 8kb buffer
    add x3, sp, x0 // basep
    mov x0, x20
    svc #0
    b_err gde_err
    // x0 = bytes written to buffer. if x0 == 0, we're done.
    cbz x0, gde_done

    // load up the relevant stuff from the buffer
    mov x19, sp // x19 is current dirent walk
    add x23, sp, x0 // x23 is the end of valid data

gde_entry:
    // if we're at the end of the dir walk, but gdtdirentries() didn't return 0
    // then we should go back up to the loop
    cmp x19, x23
    b.hs gde_loop

    // write the entry
    add x1, x19, #OFF_D_NAME
    bl strlen
    mov x1, x0 // no name length member of the struct, so we gotta use strlen
    add x0, x19, #OFF_D_NAME
    ldrb w2, [x19, #OFF_D_TYPE]
    bl write_chunk

    ldrh w0, [x19, #OFF_D_RECLEN] // load d_reclen, length of current record
    add x19, x19, x0 // skip to the next record
    b gde_entry // process the next entry

gde_err:
    mov x19, x0
    bl close
    mov x0, x19
    mov x8, SYS_exit
    svc #0

gde_done:
    // restore stack space
    mov x0, #8208
    add sp, sp, x0

    ldr_l x0, clientfd
    adr_l x1, listing_tail
    mov x2, listing_tail_len
    bl write_with_chunk_length

    // write 0\r\n\r\n
    ldr_l x0, clientfd
    adr_l x1, chunked_content_end
    mov x2, chunked_content_end_len
    bl write_all

    bl close

close:
    mov x0, x20
    mov x8, SYS_close
    svc #0

    b child_end

// input
// x0 -> number to convert
// x1 -> pointer to memory to write the string
//
// returns
// x0 -> number of digits written
// x1 -> start of string
hex_itoa:
    mov w2, #8 // max digits
    add x1, x1, #8 // write right-to-left
    mov w3, #0 // digit count

Lhex_loop:
    and w4, w0, #0xf // low nibble
    cmp w4, #10
    b.lo Ldigit
    add w4, w4, #('a' - 10) // 10-15 -> "a"-"f"
    b Lstore
Ldigit:
    add w4, w4, #'0' // 0-9 -> "0"->"9"
Lstore:
    sub x1, x1, #1
    strb w4, [x1]
    add w3, w3, #1
    lsr w0, w0, #4 // shift down one nibble
    cbnz w0, Lhex_loop

    // we're done
    mov x0, x3
    ret

L403:
    mov x0, #403
    mov x1, #0
    b reply_status
