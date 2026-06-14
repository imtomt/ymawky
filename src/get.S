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

.global get
.global head

.data
.balign 8

head_200:
    .ascii "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: "
.equ head_200_len, . - head_200

head_206:
    .ascii "HTTP/1.1 206 Partial Content\r\nConnection: close\r\nContent-Length: "
.equ head_206_len, . - head_206

head_content_range:
    .ascii "\r\nContent-Range: bytes "
.equ head_content_range_len, . - head_content_range

head_content_type:
    .ascii "\r\nContent-Type: "
.equ head_content_type_len, . - head_content_type

good_response_tail:
    .ascii "\r\nAllow: GET, HEAD, OPTIONS, DELETE, PUT\r\nAccept-Ranges: bytes\r\nServer: ymawky\r\n\r\n"
.equ good_response_tail_len, . - good_response_tail

.text
.balign 4

// setup for the "GET" and "HEAD" methods. pretty much just writes the header
// after getting content length and such.
// none, uses .bss data
//
// output
// x0 -> length of file
// x1 -> file type, w1 can be S_IFREG or S_IFDIR
// NOTE this function opens a file and doesn't close it -- it saves the open
// file descriptor in file_des, which is in data.S's .data. child_end should
// close it, but be aware!
get_setup:
    stp x29, x30, [sp, #-32]!
    stp x19, x20, [sp, #16]

    mov x0, #1 // yes, default to index.html if no file is given
    bl do_path_checks
    ldr_l x0, filename_str

    ldrb w1, [x0]
    cmp w1, #'*'
    b.eq L400

    // check if the path requested is in CGI_DIR
    bl check_cgi_path
    cbz x0, Lcgi // branch to cgi handler if so

    mov x8, SYS_openat
    mov x0, AT_FDCWD
    ldr_l x1, filename_str
    mov x2, #0 // RDONLY
    orr x2, x2, #O_NOFOLLOW
    svc #0
    b_err Lhfs_err // if the carry flag is set, open() failed so handle it

    // save the file descriptor
    str_l x0, file_des

    bl stat_fd
    cbnz x0, Lhfs_err

    cmp w1, #S_IFREG
    b.eq Lgs_epilogue
    cmp w1, #S_IFDIR
    b.eq Lgs_epilogue

    b L403

Lgs_epilogue:
    mov x0, x2

    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

Lcgi:
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    b cgi


// for HEAD, reply with just the header. pretty short n sweet.
head:
    bl get_setup // this does basically everything we want.

    // x0 is already set from get_setup
    mov x1, #-1
    mov x2, #-1
    mov x3, #200 // 200 OK
    bl build_header
    b_err L500

    ldr_l x0, clientfd
    adr_l x1, header_buf
    ldr_l x2, header_len
    bl write_all
    // it's ok to ignore write errors here, since if we get an error the way to
    // handle it would be to close the file descriptor and b child_end, which
    // is what we're doing here anyway. can't write 500 Internal Server Error
    // in the middle of another header, lol.

    // child_end will close the file descriptor
    b child_end


// do the "GET /" stuff."
// input
// x0 -> header received
// x1 -> length of header
//
// returns
// nothing ! :)
get:
    mov x20, x0
    mov x21, x1

    bl get_setup
    cmp w1, #S_IFDIR
    b.eq Ldir_list

    // let's save file length into x19! please? we need to use it but only in
    // this func -- i really don't wanna do more stack shit here...
    mov x19, x0

    mov x0, x20
    mov x1, x21
    bl parse_range
    b_err Lno_range

    mov x22, x0
    mov x23, x1

    cmn x22, #1
    b.eq Lsuffix_range

    // non-suffix ranges on empty files are unsatisfiable
    cbz x19, L416

    cmn x23, #1
    b.eq Lopen_range

    // if we're here, both are concrete.
    // bytes=X-N
    cmp x22, x19
    b.hs L416

    // if x23 > filesize - 1, set it to filesize - 1 so we don't read other
    // memory.
    sub x1, x19, #1
    cmp x23, x1
    csel x23, x1, x23, hi
    b Lbuild_ranged_header

Lsuffix_range:
    // bytes=-X
    // Range: bytes=-0 is unsatisfiable.
    cbz x23, L416

    // bytes=-X on an empty file should be 200, not 206. just serve the whole
    // file :)
    cbz x19, Lno_range

    // if range is less than file length, handle it at 1f
    cmp x23, x19
    b.lo 1f

    // if range is bigger than or equal to the file size, just return the
    // whole file.
    mov x22, #0
    sub x23, x19, #1
    b Lbuild_ranged_header

1:
    // Range: bytes=-50 means file_len - 50
    sub x22, x19, x23 // start = len - range
    sub x23, x19, #1 // end = fiolesize - 1 (inclusive)
    b Lbuild_ranged_header

Lopen_range:
    // bytes=X-
    // if X >= filesize, it's not satisfiable :(
    cmp x22, x19
    b.hs L416

    // if it's bytes=N-, start range remains unchanged, but end becomes
    // file_len - 1
    sub x23, x19, #1
    b Lbuild_ranged_header

Lno_range:
    // just pretend start = 0, end = file_length.
    mov x22, #0
    sub x23, x19, #1

    mov x0, x19
    mov x1, #-1
    mov x2, #-1
    mov x3, #200 // 200 OK
    bl build_header
    b_err L500

    b Lmmap_start

Lbuild_ranged_header:
    // if start range >= filesize, that's unsatisfiable
    cmp x22, x19
    b.hs L416

    mov x0, x19
    mov x1, x22
    mov x2, x23
    mov x3, #206 // 206 Partial Content
    bl build_header
    b_err L500
    // fallthrough

Lmmap_start:
    // if filesize is 0, just print the header, hehe, skip the mmap
    cbz x19, 1f

    // mmap(NULL, size, PROT_READ, MAP_PRIVATE, fd, 0)
    mov x8, SYS_mmap
    mov x0, #0
    mov x1, x19
    mov x2, #1 // PROT_READ
    mov x3, #2 // MAP_PRIVATE
    ldr_l x4, file_des // file descriptor
    mov x5, #0 // offset
    svc #0
    b_err L500
    // x0 is now the pointer to memory for the file

    // stash the pointer somewhere safe
    mov x12, x0

1:
    ldr_l x0, clientfd
    adr_l x1, header_buf
    ldr_l x2, header_len
    bl write_all
    b_err 2f // if header write failed, don't bother writing the body

    // if filesize is 0, the mmap'd registers are unitialized, and the file is
    // empty! so just skip this write
    cbz x19, 2f

    // x12 -> pointer to mmap'd memory
    // x19 -> total length of file
    // x22 -> start range
    // x23 -> end range
    ldr_l x0, clientfd
    add x1, x12, x22
    sub x2, x23, x22
    add x2, x2, #1
    bl write_all
2:
    // likewise if filesize is 0, we don't need to munmap. just close!
    cbz x19, Lget_end
    b Lwrite_done

Lwrite_done:
    mov x8, SYS_munmap
    mov x0, x12
    mov x1, x19
    svc #0
    // if munmap fails, we would just branch to Lget_end anyway. so just fall
    // through either way.
Lget_end:
    // child_end will close the file descriptor
    b child_end


// trampolines for conditional branches to reply_* / handle_fs_error in other
// files (b.cond / cbz can't reach across files// unconditional b can).
L400:
    mov x0, #400
    mov x1, #0
    b reply_status
L403:
    mov x0, #403
    mov x1, #0
    b reply_status
L416:
    mov x0, #416
    mov x1, #0
    b reply_status
L500:
    mov x0, #500
    mov x1, #0
    b reply_status

Ldir_list:
    ldr_l x0, file_des
    ldr_l x1, filename_str
    ldr_l x2, filename_len
    b dir_listing

Lhfs_err: b handle_fs_error
