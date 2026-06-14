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

.global parse_header_end
.global parse_range
.global parse_content_length
.global make_tmp_file
.global do_path_checks
.global get_header_field

// this is PATH_MAX
.equ filename_buf_size, 4096
// (PATH_MAX + some extra bytes for tmp stuff)
.equ filename_buf_tmp_size, filename_buf_size + 64
// max size for query string (everything after ? in, eg, GET /index?f=u&c=k
.equ query_buf_size, 4096

.data
header_end: .ascii "\r\n\r\n"
.equ header_end_len, . - header_end

content_len_match_str: .ascii "content-length"
.equ content_len_match_len, 14

range_match_str: .ascii "range"
.equ range_match_len, 5

bytes_match_str: .ascii "bytes"
.equ bytes_match_len, 5


www_prefix: .ascii DOCROOT // DOCROOT from config.S
.equ www_prefix_len, . - www_prefix

default_file: .ascii DEFAULT_FILE // also from config.S
.equ default_file_len, . - default_file

tmp_prefix: .ascii DOCROOT
            .ascii ".ymawky_tmp_"
.equ tmp_prefix_len, . - tmp_prefix
.balign 8 // tmp_prefix length is odd, realign for the .quad below
tmp_prefix_len_val: .quad tmp_prefix_len

.bss
// probably way too defensive, but can't hurt, eh?
filename_buf: .skip filename_buf_size + 1
.balign 8 // fix broken alignment again
filename_buf_tmp: .skip filename_buf_tmp_size + 1
.balign 8
range_buf: .skip 19
.balign 8
query_buf: .skip query_buf_size

.text
.balign 4

// take a filename, and create a temporary file for PUT.
// eg, "test.txt" -> ".ymawky_tmp_<pid>", then that temp file gets written to,
// and on success, renamed to "test.txt", or unlinked on fail.
// input
// none
//
// return
// x0 -> generated temporary filename
// x1 -> length of generated temporary filename
make_tmp_file:
    stp x29, x30, [sp, #-64]!
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]

    mov x23, #0
    movz x24, #filename_buf_tmp_size

    // preemptively increment the counter to account for the prefix
    mov x22, #tmp_prefix_len
    add x23, x23, x22
    // quit if it's too big. we don't want to accidentally write into other
    // memory
    cmp x23, x24
    b.hi mtf_err 

    // copy tmp_prefix to filename_buf_tmp
    adr_l x0, filename_buf_tmp
    adr_l x1, tmp_prefix
    mov x2, #tmp_prefix_len
    bl memcpy
    mov x21, x0 // save pointer with offset from memcpy

    // getpid()
    mov x8, SYS_getpid
    svc #0
    // now x0 contains the pid

    // itoa() on getpid()
    bl itoa
    // x0 -> string, x1 -> length of string
    mov x22, x1

    // preemptively increment the counter, and bounds check, for return once
    // more
    add x23, x23, x22
    cmp x23, x24
    b.hi mtf_err

    // copy string of pid to the end of filename_buf_tmp
    mov x2, x1
    mov x1, x0
    mov x0, x21 // load pointer with offset
    bl memcpy

    // one last bounds check, preemptively, for the NULL terminator. then add
    // it.
    add x23, x23, #1
    cmp x23, x24
    b.hi mtf_err
    strb wzr, [x0]

    // load data for returning. make x0 a pointer to the start of
    // filename_buf_tmp, and x1 the total length of the file (-1 to get rid of
    // the NULL byte from length).
    adr_l x0, filename_buf_tmp
    sub x1, x23, #1

    b mtf_epilogue

mtf_err:
    mov x0, #-1
    mov x1, #0
    // fallthrough

mtf_epilogue:
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #64
    ret


// find header field
// x0 -> HTTP header from client
// x1 -> length of header
// x2 -> field to search for
// x3 -> length of x2
//
// return
// x0 -> pointer to the beginning of the header contents
// x1 -> remaining length in the header
// carry -> set if not found
get_header_field:
    stp x29, x30, [sp, #-64]!
    stp x19, x20, [sp, #16]
    stp x21, x23, [sp, #32]
    str x24, [sp, #48]

    mov x19, x0  // headers
    mov x20, x1  // length
    mov x21, #0  // index
    mov x23, x2  // field string
    mov x24, x3  // field string length

ghf_scan:
    cmp x21, x20
    b.ge ghf_not_found

    ldrb w2, [x19, x21]
    cmp w2, #'\r'
    b.ne ghf_scan_again

    add x21, x21, #1
    cmp x21, x20
    b.ge ghf_not_found

    ldrb w2, [x19, x21]
    cmp w2, #'\n'
    b.ne ghf_scan // x21 already advanced. lone \r, so keep scanning.

    // we're at \r\n, next line begins at x21+1
    add x21, x21, #1
    cmp x21, x20
    b.ge ghf_not_found

    // lines can't begin with whitespace
    ldrb w2, [x19, x21]
    cmp w2, #' '
    b.eq L400
    cmp w2, #'\t'
    b.eq L400

    // if (length - index) < strlen(field), end of header is too
    // soon.
    sub x3, x20, x21
    cmp x3, x24
    b.lt ghf_not_found

    add x0, x19, x21
    mov x1, x23
    mov x2, x24
    bl streqn_i

    cmp x0, #0
    b.eq ghf_scan_again

    // if we're here, it was a match!
    add x21, x21, x24
    // but if the header ends here, before even the :, it's malformed.
    cmp x21, x20
    b.ge L400

    // make sure the field is followed immediately by a ":", otherwise reject
    // it.
    ldrb w2, [x19, x21]
    cmp w2, #':'
    b.ne L400

ghf_skip_ws:
    // gotta bounds check on every byte. got i hate string parsing!
    add x21, x21, #1
    cmp x21, x20
    b.ge L400

    ldrb w2, [x19, x21]
    cmp w2, #' '
    b.eq ghf_skip_ws
    cmp w2, #'\t'
    b.eq ghf_skip_ws
    // got past the whitespace

    // return x0 -> header+offset, start of content
    mov x0, x19
    add x0, x0, x21

    // return x1 -> length-x21 = remaining length
    sub x1, x20, x21
    b ghf_epilogue

ghf_scan_again:
    add x21, x21, #1
    b ghf_scan

ghf_not_found:
    mov x0, #0
    // fallthrough
ghf_epilogue:
    ldr x24, [sp, #48]
    ldp x21, x23, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #64
    ret


// parse Range: header line
// input
// x0 -> HTTP header from client
// x1 -> length of header
//
// return
// x0 -> start range (or -1)
// x1 -> end range (or -1).
// sets carry on error
parse_range:
    stp x29, x30, [sp, #-80]!
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    stp x25, x26, [sp, #64]

    mov x19, x0
    mov x20, x1
    mov x21, #0 // index

    // x0 is already set
    // x1 is already set
    adr_l x2, range_match_str
    mov x3, range_match_len
    bl get_header_field
    cbz x0, pr_no_range // wasn't found, oh well!

    mov x22, x0 // pointer to beginning of data
    mov x23, x1 // remaining length in header field

    mov x0, bytes_match_len
    cmp x0, x23
    b.ge pr_no_range

    mov x21, x0 // save this as offset now

    // check if the next content is bytes
    mov x2, x0
    mov x0, x22
    adr_l x1, bytes_match_str
    bl streqn_i
    cbz x0, pr_no_range

    ldrb w0, [x22, x21]
    cmp w0, #'='
    b.ne pr_no_range

    add x21, x21, #1
    cmp x21, x23
    b.ge pr_no_range

    // now we know it's Range: bytes=
    adr_l x2, range_buf
    mov x24, #0
pr_get_start_range:
    ldrb w0, [x22, x21]
    cmp w0, #'-'
    b.eq Lpr_start_next
    cmp w0, #'0'
    b.lt pr_no_range
    cmp w0, #'9'
    b.gt pr_no_range

    strb w0, [x2, x24]
    add x24, x24, #1
    cmp x24, #19
    b.ge pr_no_range

    add x21, x21, #1
    cmp x21, x23
    b.ge pr_no_range

    b pr_get_start_range
Lpr_start_next:
    // check if the range was 0 bytes long, ie, immediately a '-'.
    cmp x24, #0
    b.eq 1f

    mov x0, x2
    mov x1, x24
    bl atoi_n
    b_err pr_no_range
    mov x25, x0
    b pr_got_start
1:
    mov x25, #-1
pr_got_start:
    adr_l x2, range_buf
    mov x24, #0

pr_get_end_range:
    add x21, x21, #1
    cmp x21, x23
    b.ge pr_no_range

    ldrb w0, [x22, x21]
    cmp w0, #'\r'
    b.eq Lpr_end_next
    cmp w0, #'0'
    b.lt pr_no_range
    cmp w0, #'9'
    b.gt pr_no_range

    strb w0, [x2, x24]
    add x24, x24, #1
    cmp x24, #19
    b.ge pr_no_range

    b pr_get_end_range
Lpr_end_next:
    // check if the range was 0 bytes long, ie, immediately a newline.
    cmp x24, #0
    b.eq 1f

    mov x0, x2
    mov x1, x24
    bl atoi_n
    b_err pr_no_range
    mov x26, x0
    b pr_got_range
1:
    mov x26, #-1
pr_got_range:
    // both -1 is invalid (like Range: bytes=-)
    cmn x25, #1
    b.ne 1f
    cmn x26, #1
    b.eq pr_no_range

1:
    // if they're negative, don't compare if x25 > x26
    cmn x25, #1
    b.eq 2f
    cmn x26, #1
    b.eq 2f

    // if end < start, it's invalid. ignored! blocked! loser!
    cmp x25, x26
    b.gt pr_no_range

2:
    // if we're here, the ranges are good!
    mov x0, x25
    mov x1, x26
    //cmn xzr, xzr
    b pr_epilogue

pr_no_range:
    mov x0, #-1
    b pr_epilogue

pr_epilogue:
    ldp x25, x26, [sp, #64]
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #80
    ret
// parse Content-Length: header line
// input
// x0 -> HTTP header from client
// x1 -> length of header
//
// return
// x0 -> content length as an integer
parse_content_length:
    stp x29, x30, [sp, #-48]!
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]

    mov x19, x0  // headers
    mov x20, x1  // length
    mov x21, #0  // index
    mov x22, #-1 // value, sentinel -1 = not found yet

    // x0 is already set
    // x1 is already set
    adr_l x2, content_len_match_str
    mov x3, content_len_match_len
    bl get_header_field
    cbz x0, pcl_err

    mov x19, x0
    mov x20, x1

    // check if there's duplicate content-length fields... if there are, it's
    // a malformed request. oops!
    mov x0, x19
    mov x1, x20
    adr_l x2, content_len_match_str
    mov x3, content_len_match_len
    bl get_header_field
    cbnz x0, pcl_malformed

Lskip_leading_zeroes:
    ldrb w2, [x19, x21]
    cmp w2, #'0'
    b.ne 1f // not a zero so lets get the content length for real!

    // hm it is a zero. is it the last zero? peak at da next char
    add x3, x21, #1
    cmp x3, x20
    b.ge 1f // if it's the end of the string, don't skip this zero

    ldrb w3, [x19, x3]
    cmp w3, #'0'
    b.lt 1f // if the next char is < 0, like \r, keep it and count
    cmp w3, #'9'
    b.gt 1f // likewise if the char is > 9

    // if we're here, the current char is 0 and the next char is also a digit.
    // skip it to skip leading zeroes!
    add x21, x21, #1
    b Lskip_leading_zeroes

1:
    mov x0, x21 // x21 points to the true start of the number, after leading 0s
    mov x1, #0

Lget_cl_len:
    ldrb w2, [x19, x0]
    cmp w2, #'0'
    b.lt Lgot_cl_len
    cmp w2, #'9'
    b.gt Lgot_cl_len

    add x1, x1, #1
    add x0, x0, #1
    cmp x0, x20
    b.ge pcl_done

    b Lget_cl_len

Lgot_cl_len:
    // now x1 is the number of digits following "content-length:", after
    // whitespace. if it's 0, that means empty content length. bad!
    cbz x1, pcl_malformed
    // but first, if the next character is *not* \r, then it means content
    // length has some string like "124afoo", which is invalid.
    cmp w2, #'\r'
    b.ne pcl_malformed

    // if the header ends like "content-length: foo" with nothing after, like
    // no \r\n\r\n, it's malformed. this isn't a strict check -- just makes
    // sure the end of content-length is not the last byte of the header.
    cmp x0, x20
    b.ge pcl_malformed

    // ensure x1 has a reasonable size to prevent overflows. 18 characters
    cmp x1, #18
    b.ge pcl_body_too_large

    // load the string + pointer index into x0
    mov x0, x19
    add x0, x0, x21
    // x1 is still set
    bl atoi_n
    b_err pcl_malformed

    // let's also cap it at 1GB (by default). change MAX_BODY_SIZE at the top
    // of the file to customize.
    mov x1, #MAX_BODY_SIZE
    cmp x0, x1
    b.hi pcl_body_too_large

    // now x0 should be the length!
    mov x22, x0

pcl_done:
    cmp x22, #-1
    b.eq pcl_err

    mov x0, x22
    b pcl_epilogue

pcl_body_too_large:
    mov x0, #-2 // -2 means Content-Length: X value is too large
    b pcl_epilogue

pcl_malformed:
    mov x0, #-1 // 1 means malformed header
    b pcl_epilogue

pcl_err:
    mov x0, #-3 // 0 means other error, like no content-length found
    // fall through

pcl_epilogue:
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret


// input
// x0 -> HTTP header from client ("GET /...")
// x1 -> length of header
// x2 -> boolean, if 1/true, default to "index.html" default filename. if
//       0/false, do not give a default filename.
// 
// return
// x0 -> string containing requested file name
// x1 -> length of said file name
//
// clobbers x0, x1, x2, x3
parse_path:
    // preserve link register so we can bl to other functions properly
    stp x29, x30, [sp, #-64]!
    stp x20, x21, [sp, #16]
    stp x22, x23, [sp, #32]
    stp x24, x25, [sp, #48]

    mov x22, x1 // save header length in x22
    mov x20, x2 // save bool option in x20.

    // length of the docroot string needs to be accessible to directory.S.
    // shove that shit in .bss NOW
    mov x2, www_prefix_len
    str_l x2, docroot_len

    cmp x22, #16 // make sure the header is at least 16 bytes long
    b.lo L400

    mov x25, #0
    mov x23, #0
    mov x2, #1 // just has to be non-null, previous byte to make sure a space
               // precedes the '/'

// this is basically strchr
Lstrchr_loop:
    // load the current byte at the string pointer, and check if it's /
    ldrb w3, [x0]
    cmp w3, #'/'
    b.eq Lchar_found
    cmp w3, #'*'
    b.eq Lchar_found

    // if we haven't reached a / in the first 16 bytes, we'll fail
    cmp x23, #16
    b.eq Lno_match

    // if we reached a NULL byte in the first 16 bytes, it's definitely a
    // weird request header. so, let's just fail.
    cmp w3, #0
    b.eq Lno_match

    // if we got here, we gotta loop again. < 16 bytes in, no / reached, and no
    // NULL byte reached. increment string index and loop
    add x0, x0, #1 // increment the string pointer
    add x23, x23, #1 // increment the byte counter so we can quit at 16 bytes
    
    // save previous byte so we can check for preceding ' '
    mov w2, w3
    b Lstrchr_loop

// If we got here, we found a '/' or '*'. let's make sure the preceding byte,
// stored in x2, is a ' ' so we only match ' /' or ' *'. that way we avoid
// 'HTTP/1.1' "matching".
Lchar_found:
    cmp w2, #' '
    b.ne Lno_match

    // if / is the last char in the header, it's deffo malformed.
    add x23, x23, #1
    cmp x23, x22
    b.hi Lno_match

    cmp w3, #'*'
    b.eq Lasterisk

    add x0, x0, #1 // skip past the '/' which we're currently on

    // load in filename_buf to x1
    adr_l x1, filename_buf

    // gotta save x0 and x1, since memcpy changes the pointers
    stp x0, x1, [sp, #-16]!
    mov x0, x1
    adr_l x1, www_prefix
    mov x2, www_prefix_len
    bl memcpy
    ldp x0, x1, [sp], #16

    // zero out x2, which is used as both an index into filename_buf and as a
    // relative index (x2 + 4, to skip the starting "GET ") into the header
    mov x2, #0
    mov x4, www_prefix_len
    mov x24, #1 // x24 = is the last processed a slash? here, it is
Lfilename_loop:
    cmp x4, filename_buf_size // bounds check
    b.ge L414

    ldrb w3, [x0, x2] // load byte from header+index
    cbz w3, Lno_match // is it NULL? go to 4f if it is

    cmp w3, #' ' // is it a space?
    b.eq Lfilename_done // we're done once we reach a space

    cmp w3, #'\r'
    b.eq Lno_match

    cmp w3, #'\n'
    b.eq Lno_match

    // if x25 is set, that indicates that we've reached a ?. if we reached a ?,
    // we want to copy the rest of the URL exactly -- don't collapse multiple
    // slashes into a single slash. so just skip this block if x25 is set.
    cbnz x25, 1f
    cmp w3, #'/'
    b.eq Lslash
    mov x24, #0 // 0 means last char was not a slash, 1 means last char was
1:

    cmp w3, #'?' // is it a ? ?? we'll use that for query string.
    b.ne 1f
    cbnz x25, 1f // if x25 is already set, ignore it. query can have multiple ?
    // set x25 to the index immediately after the ?. we don't want the literal
    // first ? to appear in query_buf, so we add 1 to x4 to skip it
    add x25, x4, #1
1:
    // ok, we're not done
    strb w3, [x1, x4] // copy byte to filename_buf+index
    add x4, x4, #1 // increment the filename index
    add x2, x2, #1 // increment the header index
    add x23, x23, #1 // increment the total index

2:
    // bounds check!
    cmp x23, x22
    b.hi Lno_match

    b Lfilename_loop

// strip multiple /'s into a single /
Lslash:
    cmp x24, #0
    b.eq 3f

    // if the previous char was a slash, just skip this one
    mov x24, #1 // set x24 to mark we processed a slash
    add x2, x2, #1 // advance header index
    add x23, x23, #1 // advance total counter
    b 2b
3:
    // if the last char was not a slash, mark this char as being one, and copy
    // anyway.
    mov x24, #1
    b 1b

Lfilename_done:
    // is the length the same as the www/ prefix? if it is, we didn't actually
    // get a file.
    mov x5, www_prefix_len
    cmp x4, x5
    b.eq Lempty_filename

    strb wzr, [x1, x4] // null-terminate filename_buf
    mov x0, x1 // we want x0 to point to the filename string
    mov x1, x4 // x1 is the length of the filename
    b Lparse_end

Lempty_filename:
    mov x5, x1 // save filename_buf in x5
    mov x2, www_prefix_len

    // the default file name, "index.html", is only for GET requests. if it's a
    // DELETE/PUT/POST/anything else, just "www/" is enough. we'll let the
    // system handle the error elsewhere if it causes problems.
    cbz x20, Lno_default_file

    adr_l x0, filename_buf
    // skip past the www/
    add x0, x0, x2

    adr_l x1, default_file
    mov x2, default_file_len
    bl memcpy

    strb wzr, [x0] // null terminate

    mov x0, x5
    mov x1, www_prefix_len
    mov x2, default_file_len
    add x1, x1, x2

    b Lparse_end
Lno_default_file:
    mov x0, x5
    mov x1, www_prefix_len
    b Lparse_end

Lasterisk:
    // bounds check yuck
    add x23, x23, #1
    cmp x23, x22
    b.hi L400

    // make sure the next char is a space -- "OPTIONS *foo" is invalid"
    ldrb w2, [x0, #1]
    cmp w2, #' '
    b.ne L400

   // store * as the filename
    adr_l x0, filename_buf
    str w3, [x0]
    strb wzr, [x0, #1]

    // x0 is already set
    mov x1, #1 // filename is just one byte
    b Lparse_end

// no match was when we were parsing the header for request type. since we cant
// find a file without a /, just return NULL
Lno_match:
    mov x0, #-1
    mov x1, #0
    mov x2, #0
    mov x3, #0
    b Lparse_epilogue

Lparse_end:
    // set query string/len to 0 by default, but may be overwritten
    mov x2, #0
    mov x3, #0

    cbz x25, 9f // if x25 is NULL, just skip straight to the end

    // otherwise, we have to extract the parse string now.
    mov x20, x0 // save x0
    mov x21, x1 // and x1
    // x22 points at the index that contains the ?, rather than one-past it
    //mov x22, x25
    sub x22, x25, #1

    adr_l x0, filename_buf
    adr_l x2, query_buf
1:
    // x25 is index into filename where ? appears, from earlier in parse_path
    cmp x25, x21 // x21 is length of filename from parse_path
    b.hs 2f

    cmp x3, query_buf_size
    b.hs L414

    ldrb w1, [x0, x25]
    strb w1, [x2, x3]
    strb wzr, [x0, x25] // now make that NULL in filename_str

    add x25, x25, #1
    add x3, x3, #1
    b 1b

2:
    mov x0, x20 // restore x0
    strb wzr, [x0, x22] // NULL the ? in filename
    //mov x1, x21 // and x1
    //sub x1, x21, x25 // filename length = total length - query string offset
    mov x1, x22
9:
qsrchdone:
    //cmn xzr, xzr // clear carry in case. it gets set in the other error paths.
Lparse_epilogue:
    // restore the link register and ret
    ldp x24, x25, [sp, #48]
    ldp x22, x23, [sp, #32]
    ldp x20, x21, [sp, #16]
    ldp x29, x30, [sp], #64
    ret

// input
// x0 -> string
// x1 -> length
//
// return
// x1 -> index of the first byte after the header
parse_header_end:
    adr_l x2, header_end
    mov x5, #0
    mov x6, #0
Lheader_end_loop:
    cmp x5, x1
    b.ge Lno_end_found

    ldrb w3, [x0, x5]
    ldrb w4, [x2, x6]

    cmp w3, w4
    b.eq Lcorrect_char

    b Lincorrect_char

Lcorrect_char:
    add x6, x6, #1

    cmp x6, #4 // length of \r\n\r\n
    b.ge Lend_found

    add x5, x5, #1
    b Lheader_end_loop

Lincorrect_char:
    mov x6, #0
    cmp w3, #'\r' // this \r starts a new potential match, eg, \r\n\r>\r<\n\r\n
    b.ne 2f
    mov x6, #1
2:
    add x5, x5, #1
    b Lheader_end_loop

Lend_found:
    add x1, x5, #1
    ret

Lno_end_found:
    mov x1, #0
    ret


// decode hex/safety check/traversal check for a given path.
// input
// x0 -> boolean for parse_path, should a default file be provided if none is
//       given? 0/false, no default (PUT, DELETE). 1/true, yes default to
//       index.html (GET, HEAD)
//
// output
// none -- responds with 400 or other error codes if needed.
do_path_checks:
    stp x29, x30, [sp, #-16]!

    mov x2, x0
    adr_l x0, buf
    ldr_l x1, header_len
    bl parse_path
    b_err L400

    str_l x2, query_str
    str_l x3, query_len

    // x0 is already path, x1 is already path length
    bl decode_url
    cbz x0, L400

    str_l x0, filename_str
    str_l x1, filename_len

    bl check_path_safety
    cbz x0, L400

    ldr_l x0, filename_str
    ldr_l x1, filename_len
    bl check_path_traversal
    cbz x0, L400

    ldr_l x0, filename_len
    ldr_l x1, tmp_prefix_len_val
    cmp x0, x1
    b.lt 2f

    ldr_l x0, filename_str
    adr_l x1, tmp_prefix
    ldr_l x2, tmp_prefix_len_val
    bl streqn_i
    cbnz x0, L403
2:
    ldp x29, x30, [sp], #16
    ret


// trampolines for conditional branches to reply_* in errors.S (which is too
// far for b.cond / cbz to reach directly).
L400:
    mov x0, #400
    mov x1, #0
    b reply_status
L403:
    mov x0, #403
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
