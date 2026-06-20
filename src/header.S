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

.global handle_fs_error
.global build_header
.global reply_status
.global header_buf

.data
header_200: .ascii "HTTP/1.1 200 OK"
.equ header_200_len, . - header_200

header_201: .ascii "HTTP/1.1 201 Created"
.equ header_201_len, . - header_201

header_204: .ascii "HTTP/1.1 204 No Content"
.equ header_204_len, . - header_204

header_206: .ascii "HTTP/1.1 206 Partial Content"
.equ header_206_len, . - header_206

header_400: .ascii "HTTP/1.1 400 Bad Request"
.equ header_400_len, . - header_400

header_403: .ascii "HTTP/1.1 403 Forbidden"
.equ header_403_len, . - header_403

header_404: .ascii "HTTP/1.1 404 Not Found"
.equ header_404_len, . - header_404

header_405: .ascii "HTTP/1.1 405 Method Not Allowed"
.equ header_405_len, . - header_405

header_408: .ascii "HTTP/1.1 408 Request Timeout"
.equ header_408_len, . - header_408

header_409: .ascii "HTTP/1.1 409 Conflict"
.equ header_409_len, . - header_409

header_411: .ascii "HTTP/1.1 411 Length Required"
.equ header_411_len, . - header_411

header_413: .ascii "HTTP/1.1 413 Content Too Large"
.equ header_413_len, . - header_413

header_414: .ascii "HTTP/1.1 414 URI Too Long"
.equ header_414_len, . - header_414

header_416: .ascii "HTTP/1.1 416 Range Not Satisfiable"
.equ header_416_len, . - header_416

header_418: .ascii "HTTP/1.1 418 I'm a teapot"
.equ header_418_len, . - header_418

header_431: .ascii "HTTP/1.1 431 Request Header Fields Too Large"
.equ header_431_len, . - header_431

header_500: .ascii "HTTP/1.1 500 Internal Server Error"
.equ header_500_len, . - header_500

header_501: .ascii "HTTP/1.1 501 Not Implemented"
.equ header_501_len, . - header_501

header_502: .ascii "HTTP/1.1 502 Bad Gateway"
.equ header_502_len, . - header_502

header_503: .ascii "HTTP/1.1 503 Service Unavailable"
.equ header_503_len, . - header_503

header_505: .ascii "HTTP/1.1 505 HTTP Version Not Supported"
.equ header_505_len, . - header_505

header_507: .ascii "HTTP/1.1 507 Insufficient Storage"
.equ header_507_len, . - header_507

header_content_length: .ascii "\r\nContent-Length: "
.equ header_content_length_len, . - header_content_length

header_content_type: .ascii "\r\nContent-Type: "
.equ header_content_type_len, . - header_content_type

header_content_range: .ascii "\r\nContent-Range: bytes "
.equ header_content_range_len, . - header_content_range

header_tail:
    .ascii "\r\nConnection: close\r\nAllow: GET, HEAD, OPTIONS, DELETE, PUT\r\nAccept-Ranges: bytes\r\nServer: ymawky\r\n\r\n"
.equ header_tail_len, . - header_tail

err_dir: .ascii ERR_DIR
.equ err_dir_len, . - err_dir
err_ext: .ascii ".html"
.equ err_ext_len, . - err_ext

arrows_out: .asciz "\n\n>>>\n"
.equ arrows_out_len, . - arrows_out

.balign 8
// lookup table, like the MIME one, for headers. 24 bytes per entry, 8 bytes
// per each element
status_table:
    //    status, str pointer, length
    .quad 200,    header_200,  header_200_len
    .quad 201,    header_201,  header_201_len
    .quad 204,    header_204,  header_204_len
    .quad 206,    header_206,  header_206_len
    .quad 400,    header_400,  header_400_len
    .quad 403,    header_403,  header_403_len
    .quad 404,    header_404,  header_404_len
    .quad 405,    header_405,  header_405_len
    .quad 408,    header_408,  header_408_len
    .quad 409,    header_409,  header_409_len
    .quad 411,    header_411,  header_411_len
    .quad 413,    header_413,  header_413_len
    .quad 414,    header_414,  header_414_len
    .quad 416,    header_416,  header_416_len
    .quad 418,    header_418,  header_418_len
    .quad 431,    header_431,  header_431_len
    .quad 500,    header_500,  header_500_len
    .quad 501,    header_501,  header_501_len
    .quad 502,    header_502,  header_502_len
    .quad 503,    header_503,  header_503_len
    .quad 505,    header_505,  header_505_len
    .quad 507,    header_507,  header_507_len

    .quad 0 // mark the end

.bss
.equ err_page_buf_size, 64
.balign 8
err_page_buf: .skip err_page_buf_size
.balign 8
.equ header_buf_size, RESPONSE_HEADER_SIZE
header_buf:   .skip header_buf_size

.text
.balign 4
// input
// x0 -> status code
//
// returns
// x1 -> string pointer
// x2 -> length
find_http_code:
    adr_l x3, status_table
1:
    // load the first element
    ldr x4, [x3]
    cbz x4, 3f

    // found the matching entry
    cmp x4, x0
    b.eq 2f

    // jump to the next entry
    add x3, x3, #24
    b 1b

2:
    ldr x1, [x3, #8]
    ldr x2, [x3, #16]
    ret

3:
    mov x1, #0
    mov x2, #0
    ret

.balign 4
// build a header, store it into header_buf, and then write it to the socket
// in a loop, accounting for partial-writes.
// input
// x0 -> file length
// x1 -> start range (or -1 if no range)
// x2 -> end range
// x3 -> header type (#200, #404, #431, etc. literal number)
//
// output
// x0 -> header buffer
// x1 -> header length
build_header:
    stp x29, x30, [sp, #-64]!
    stp x20, x21, [sp, #16]
    stp x22, x23, [sp, #32]
    str x24, [sp, #48]

    mov x20, x0
    mov x22, x1 // start range
    mov x23, x2 // end range
    mov x24, x3 // header type

    adr_l x13, header_buf
    mov x14, #0 // counter of bytes writteen to header_buf

    mov x0, x24
    bl find_http_code
    cmp x1, #0
    b.ne 1f

    // if we're here, find header returned 0, which is... odd.
    // let's actually reply with 500, since that shouldn't happen - it means
    // build_header was called with an inaccurate HTTP statusl, which is our
    // fault.
    adr_l x1, header_500
    mov x2, #header_500_len

1:
    mov x0, x13
    // x1 is set by find_http_code
    // so is x2!
    // make sure we don't write past header_buf's memory!
    add x14, x14, x2
    cb gt, x14, header_buf_size, Lheader_too_big
    bl memcpy
    mov x13, x0 // store header_buf + offset, memcpy increments the pointer

    b Lbh_content_length

Lbh_content_length:
    // we don't want to write a content-length or content-type on a 204.
    cmp x24, #204
    b.eq Lheader_tail

    mov x2, header_content_length_len
    add x14, x14, x2
    cb gt, x14, header_buf_size, Lheader_too_big

    mov x0, x13
    adr_l x1, header_content_length
    // x2 is already set
    bl memcpy
    mov x13, x0

    cmn x22, #1
    b.eq 1f

    // if we're sending a range, content-length should be end - start instead
    sub x0, x23, x22
    add x0, x0, #1
    b 2f

1:
    // but if it's just a file, just grab the total file length.
    mov x0, x20

2:
    bl itoa
    // copy content-length string into header_buf
    mov x2, x1  // content_length_len (length of string)
    mov x1, x0  // content_length_str
    mov x0, x13 // header_buf + offset
    add x14, x14, x2
    cb gt, x14, header_buf_size, Lheader_too_big
    bl memcpy

    // skip all this stuff for no range
    cmn x22, #1
    b.eq Lbh_content_type

    // 206 path
    // write Content-Range: bytes
    adr_l x1, header_content_range
    mov x2, header_content_range_len
    add x14, x14, x2
    cb gt, x14, header_buf_size, Lheader_too_big
    bl memcpy
    mov x13, x0

    // start range
    mov x0, x22
    bl itoa

    mov x2, x1
    mov x1, x0
    mov x0, x13
    add x14, x14, x2
    cb gt, x14, header_buf_size, Lheader_too_big
    bl memcpy
    mov x13, x0

    // -
    add x14, x14, #1
    cb gt, x14, header_buf_size, Lheader_too_big
    mov w0, #'-'
    strb w0, [x13]
    add x13, x13, #1

    // end range
    mov x0, x23
    bl itoa

    mov x2, x1
    mov x1, x0
    mov x0, x13
    add x14, x14, x2
    cb gt, x14, header_buf_size, Lheader_too_big
    bl memcpy
    mov x13, x0

    // /
    add x14, x14, #1
    cb gt, x14, header_buf_size, Lheader_too_big
    mov w0, #'/'
    strb w0, [x13]
    add x13, x13, #1

    // total size
    mov x0, x20
    bl itoa

    mov x2, x1  // content_length_len (length of string)
    mov x1, x0  // content_length_str
    mov x0, x13 // header_buf + offset
    add x14, x14, x2
    cb gt, x14, header_buf_size, Lheader_too_big
    bl memcpy

Lbh_content_type:
    // if it's an empty file, don't bother with Content-Type.
    cmp x20, #0
    b.eq Lheader_tail

    // copy "\r\nContent-Type:" to buffer
    // x0 is already set from previous memcpy
    adr_l x1, header_content_type
    mov x2, header_content_type_len
    add x14, x14, x2
    cb gt, x14, header_buf_size, Lheader_too_big
    bl memcpy
    mov x13, x0

    ldr_l x0, filename_str
    ldr_l x1, filename_len
    bl get_filetype

    // write filename to header_buf
    mov x2, x1 // filename_len
    mov x1, x0 // source string, filename_str
    mov x0, x13 // destination, header_buf
    add x14, x14, x2
    cb gt, x14, header_buf_size, Lheader_too_big
    bl memcpy

Lheader_tail:
    // write the \r\n\r\n
    // x0 is still set from memcpy
    adr_l x1, header_tail
    mov x2, header_tail_len
    add x14, x14, x2
    cb gt, x14, header_buf_size, Lheader_too_big
    bl memcpy

    b Lbh_done
Lheader_too_big:
    mov x0, #-1
    str_l x0, header_len
    b Lbh_epilogue

Lbh_done:
    str_l x14, header_len
    b Lbh_epilogue

Lbh_epilogue:
    ldr x24, [sp, #48]
    ldp x22, x23, [sp, #32]
    ldp x20, x21, [sp, #16]
    ldp x29, x30, [sp], #64
    ret

.balign 4
// input
// x0 -> http code
// x1 -> boolean, if 0 -> go to child_end// if nonzero -> ret
//
// returns
// nothing
reply_status:
    cbz x1, 1f // skip the stack pushing shit if we're just gonna b child_end

    stp x29, x30, [sp, #-96]!
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    stp x25, x26, [sp, #64]
    str x27, [sp, #80]
1:
    mov x19, x0

    // this is used to check if we should "b child_end", or "ret".
    mov x27, x1

    // this will eventually be open()'d file descriptor. gonna save it so we can
    // check if a file has been opened, and close it, in sc_err.
    mov x23, #-1

    // make sure the error code is valid: not an error below 400, and we don't
    // support anything above 507 (currently).
    cmp x0, #400
    b.hs 1f
    cmp x0, #507
    b.ls 1f

    // if we get here, we were given an http code that's not an error exactly.
    // so, don't try to treat is as an error. just write the header. it's
    // probably PUT doing 201/204, or DELETE doing 204.
    // x0 is already set, so is x19.

    b sc_err // ironically called sc_err. prob should rename.

1:
    mov x20, #0 // how many bytes have we written to err_page_buf?
    mov x26, err_page_buf_size
    // do some bounds checks
    mov x21, #err_dir_len
    add x20, x20, x21
    cmp x20, x26

    b.hi sc_err

    // copy "err/" or whatever err_dir is set to, to err_page_buf
    adr_l x0, err_page_buf
    adr_l x1, err_dir
    mov x2, #err_dir_len
    bl memcpy
    mov x22, x0 // save pointer with offset from mempcy

    // itoa the error code
    mov x0, x19
    bl itoa

    // bounds check
    add x20, x20, x1 // x1 is length of itoa'd string from itoa
    cmp x20, x26

    b.hi sc_err

    // copy the itoa'd shit
    mov x2, x1
    mov x1, x0
    mov x0, x22
    bl memcpy
    mov x22, x0 // save it again

    // one last bounds check. gotta copy the ".html".
    mov x21, err_ext_len
    add x20, x20, x21
    cmp x20, x26

    b.hi sc_err

    // now copy it
    mov x0, x22
    adr_l x1, err_ext
    mov x2, err_ext_len
    bl memcpy
    mov x22, x0 // save that shit! yes! i FUCKIN G LOVE SAVING POINTERS

    // we also gotta save it to filename_str so build_header can work with it
    adr_l x0, err_page_buf
    str_l x0, filename_str
    str_l x20, filename_len

    // ok now err_page_buf should be something like "err/404.html". now we
    // gotta basically GET that shit. theoretically err_page_buf should be
    // guaranteed to be safe, BUT! what if it's not? can't be too careful. and
    // it's not really that much more intensive to use, so...
    mov x0, #AT_FDCWD
    ldr_l x1, filename_str
    mov x2, #O_RDONLY
    mov x3, #0
    open_no_symlink
    b_err sc_err
    mov x23, x0 // save the fd

    // x0 is still set tho so we don't need to mov it again
    bl stat_fd
    cbnz x0, sc_err

    cmp w1, #S_IFREG
    b.ne sc_err

    cmp x2, #0
    b.eq sc_err // empty file, just do the http code alone

    mov x24, x2 // save the file size

    mov x0, x24
    mov x1, #-1
    mov x3, x19
    bl build_header

    // mmap(NULL, size, PROT_READ, MAP_PRIVATE, fd, 0)
    mov x8, SYS_mmap
    mov x0, #0
    mov x1, x24
    mov x2, #1 // PROT_READ
    mov x3, #2 // MAP_PRIVATE
    mov x4, x23 // from open()
    mov x5, #0 // offset
    svc #0
    b_err sc_err

    // x0 is now the pointer to memory for the file. save it for now.
    mov x25, x0

    ldr_l x0, clientfd
    adr_l x1, header_buf
    ldr_l x2, header_len
    bl write_all

    ldr_l x0, clientfd
    mov x1, x25
    mov x2, x24
    bl write_all
    // munmap the file now
    mov x8, SYS_munmap
    mov x0, x25
    mov x1, x24
    svc #0
    b sc_epilogue

sc_err:
    // if something went wrong during this function, just send the header by
    // itself -- with no body. no custom pages if opening the custom page
    // didn't work :(
    mov x0, #0
    mov x1, #-1
    mov x2, #-1
    mov x3, x19
    bl build_header

    ldr_l x0, clientfd
    adr_l x1, header_buf
    ldr_l x2, header_len
    bl write_all

sc_epilogue:
    // write the \n\n>>>\n to indicate data we're sending
    mov x8, SYS_write
    mov x0, #1
    adr_l x1, arrows_out
    mov x2, arrows_out_len
    svc #0

    // write the header to stdout
    mov x8, SYS_write
    mov x0, #1
    adr_l x1, header_buf
    ldr_l x2, header_len
    svc #0

    cmn x23, #1
    b.eq 1f

    mov x8, SYS_close
    mov x0, x23
    svc #0
1:
    cbnz x27, 3f // if x27 (x1) is nonzero, ret instead of branching to child_end
2:
    b child_end
3:
    ldr x27, [sp, #80]
    ldp x25, x26, [sp, #64]
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #96
    ret


// handler function for fstat64() failing. route to the proper HTTP reponse
// based on errno.
// TODO this should probably go in file.S?
// input
// x0 -> errno
//
// output
// none, branches to reply_status and quits.
handle_fs_error:
    cnb eq, x0, #ENAMETOOLONG, L414
    cnb eq, x0, #EINVAL, L400
    // 403 since it's caused by O_NOFOLLOW_ANY most likely. if we ever allow
    // symlinks, note that this should be 508.
    cnb eq, x0, #ELOOP, L403
    cnb eq, x0, #ENOTDIR, L404
    cnb eq, x0, #ENOENT, L404
    cnb eq, x0, #EACCES, L403
    cnb eq, x0, #EPERM, L403
    cnb eq, x0, #EROFS, L403
    cnb eq, x0, #EISDIR, L403
    cnb eq, x0, #EFAULT, L500
    cnb eq, x0, #EBUSY, L409
    cnb eq, x0, #ENOTEMPTY, L409
    cnb eq, x0, #ENOSPC, L507
    cnb eq, x0, #EDQUOT, L507
    cnb eq, x0, #EFBIG, L413

    b L500

L400:
    mov x0, #400
    mov x1, #0
    b reply_status
L403:
    mov x0, #403
    mov x1, #0
    b reply_status
L404:
    mov x0, #404
    mov x1, #0
    b reply_status
L409:
    mov x0, #409
    mov x1, #0
    b reply_status
L413:
    mov x0, #413
    mov x1, #0
    b reply_status
L414:
    mov x0, #414
    mov x1, #0
    b reply_status
L500:
    mov x0, #500
    mov x1, #0
    b reply_status
L507:
    mov x0, #507
    mov x1, #0
    b reply_status
