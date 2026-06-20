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

.global put

.data
.balign 8
// struct itimerval for setitimer()
put_read_timer:
    .quad 0 // it_interval.tv_sec
    .long 0 // it_interval.tv_usec
    .long 0 // -- padding --

    .quad 0 // it_value.tv_sec
    .long 0 // it_value.tv_usec
    .long 0 // -- padding --

.bss
.balign 8
filename_tmp_str:     .skip 8
filename_tmp_len:     .skip 8
tmp_fd:               .skip 8

.text
.balign 4


// handle "PUT /" method.
// input
// x0 -> header
// x1 -> length of header
// x2 -> total bytes read
//
// output
// none, proc quits after handling.
put:
    mov x19, #0 // was file created? #0 = no, file existed, #1 = yes, new file
    mov x21, x1
    mov x22, x0
    mov x23, x1
    mov x24, x2

    mov x0, #0 // do not default to index.html
    bl do_path_checks

    ldr_l x0, filename_str
    ldrb w1, [x0]
    cmp w1, #'*'
    b.eq L400

    // if it's a request within CGI_DIR, just assume it's a cgi script.
    bl check_cgi_path
    cbz x0, Lcgi

    // if it's not a CGI script, and the request is POST, we should give a 405
    ldr_l x0, request_id
    cmp x0, POST_ID
    b.eq L405

    ldr_l x0, filename_str
    bl stat_path
    cbz x0, Ltarget_exists

    cnb eq, x0, #ENOENT, Ltarget_missing

    b handle_fs_error

Ltarget_exists:
    cb ne, w1, #S_IFREG, L403

    mov x19, #0
    b 0f

Ltarget_missing:
    mov x19, #1
    // fallthrough
0:
    mov x0, x22
    mov x1, x21
    bl parse_content_length
    b_err Lpcl_error
    mov x21, x0 // save content-length in x21

1:
    bl make_tmp_file
    b_err L500

    str_l x0, filename_tmp_str
    str_l x1, filename_tmp_len

    // openat2() requires a fuckass `struct open_how` for mode/flags/resolve
    sub sp, sp, #32
    mov x0, #O_CREAT      //
    orr x0, x0, #O_TRUNC  // open_how.flags
    orr x0, x0, #O_WRONLY //
    mov x1, #0644 // open_how.mode
    mov x2, #RESOLVE_NO_XDEV         //
    orr x2, x2, #RESOLVE_NO_SYMLINKS // open_how.resolve
    stp x0, x1, [sp] // x0, x1 -> [sp], [sp, #8]
    str x2, [sp, #16]

    mov x8, SYS_openat2
    mov x0, AT_FDCWD
    ldr_l x1, filename_tmp_str
    mov x2, sp
    mov x3, #24 // sizeof(struct open_how)
    svc #0
    add sp, sp, #32
    b_err Lhfs_err
    mov x25, x0 // save fd into x25
    str_l x0, tmp_fd

    // x0 is already set
    bl stat_fd
    cbnz x0, Lput_stat_failed

    sub x22, x24, x23 // x22 = x24 - x23, body bytes sitting in buf after header

    // write remaining body from buffer.
    mov x0, x25
    adr_l x1, buf
    add x1, x1, x23
    // get min(x22, x21). store in x2.
    cmp x22, x21
    csel x2, x22, x21, lo
    bl write_all
    b_err Lput_close_and_500
    sub x21, x21, x0
    cbz x21, Lput_done

    // calculate a timeout for read to try and prevent slowloris-like attacks
    // from slowly drip-drip-dripping content into a PUT and taking up
    // resources.
    // number of seconds = grace_period + content_length / min_bps
    // 5s + content_length / 16kb/s
    mov x1, #PUT_MIN_BPS // from config.S
    udiv x2, x21, x1 // x2 = content_length / min_bps
    add x2, x2, #PUT_GRACE_SECS // ditto

    // write the number of seconds calculated to the itimerval struct in the
    // it_value.tv_sec member
    adr_l x0, put_read_timer
    str x2, [x0, #16] // offset 16 = it_value.tv_sec

    // call setitimer
    mov x8, SYS_setitimer
    mov x0, #0 // ITIMER_REAL
    adr_l x1, put_read_timer
    mov x2, #0
    svc #0

    // set up the stack for rt_sigaction
    adr_l x0, Lput_sigalrm_handler
    sub sp, sp, #32
    str x0, [sp, #0]   // sa_handler
    str xzr, [sp, #8]  // sa_flags
    str wzr, [sp, #16] // sa_mask

    // rt_sigaction syscall is slightly different than the libc sigaction() func
    mov x8, SYS_rt_sigaction
    mov w0, #SIGALRM
    mov x1, sp
    mov x2, #0 // old action, we don't give a shit so it's null
    mov x3, #8 // this is sizeof(sigset_t), which is 8 on arm64
    svc #0
    add sp, sp, #32
    // if sigaction fails, it's due to some memory issue. that should always
    // be a 500. i don't want to just silently fail and let any connections go
    // un-timedout, so just throw a 500 and take the shit.
    b_err Lput_close_and_500

    mov x22, #BUF_SIZE // from defs.S, 16KB
Lput_readwrite_loop:
    cbz x21, Lput_done

    mov x8, SYS_read
    ldr_l x0, clientfd
    adr_l x1, buf
    cmp x22, x21
    csel x2, x22, x21, lo
    svc #0
    b_err Lput_read_failed

    // now x0 contains bytes read
    mov x26, x0
    sub x21, x21, x0

    mov x2, x0
    adr_l x1, buf
    mov x0, x25
    bl write_all
    b_err Lput_close_and_500

    // did we read 0 bytes? we're done if so. should this be b.lo? i'd like it
    // to be less than or equal, but i believe lo is just less-than. maybe 2
    // cmps? like cmp #0, b.eq, and b.lo?
    cbz x26, Lput_read_zero

    b Lput_readwrite_loop

Lput_read_failed:
    cnb eq, x0, #EINTR, Lput_readwrite_loop

    mov x20, x0 // save errno
    bl Lput_cleanup_tmp_file
    mov x0, x20 // restore

    cnb eq, x0, #EAGAIN, L408
    // all of these should just silently exit
    cnb eq, x0, #ECONNRESET, Lchild_end
    cnb eq, x0, #ETIMEDOUT, Lchild_end
    cnb eq, x0, #ECONNABORTED, Lchild_end
    cnb eq, x0, #EPIPE, Lchild_end
    cnb eq, x0, #ENETDOWN, Lchild_end
    cnb eq, x0, #ENETUNREACH, Lchild_end
    cnb eq, x0, #ENETRESET, Lchild_end
    cnb eq, x0, #EHOSTDOWN, Lchild_end
    cnb eq, x0, #EHOSTUNREACH, Lchild_end

    // none of those, so something weird's going on. just 500.
    b L500

Lput_close_and_500:
    bl Lput_cleanup_tmp_file
    b L500

// close and delete the temporary file
Lput_cleanup_tmp_file:
    mov x8, SYS_close
    mov x0, x25
    svc #0

    mov x8, SYS_unlinkat
    mov x0, AT_FDCWD
    ldr_l x1, filename_tmp_str
    svc #0

    ret

Lput_sigalrm_handler:
    mov x8, SYS_close
    // since Lput_sigalrm_handler is technically sa_tramp for __sigaction,
    // registers like x25 don't actually get preserved. all registers x5-x29
    // are unspecified within sa_tramp, so we can't reliably close() it. that's
    // why we str_l'd it when we opened it.
    ldr_l x0, tmp_fd
    svc #0

    mov x8, SYS_unlinkat
    mov x0, AT_FDCWD
    ldr_l x1, filename_tmp_str
    svc #0

    b L408

// if we read 0 bytes, check if we were actually done reading. if
// content-length bytes had not been read total, the client hung up in the
// middle. if that happens, check if we created a new file. if we did, unlink
// it so we don't have half-written garbage.
Lput_read_zero:
    cbnz x21, 3f

    // yeah if content-length is actually 0 now, we're all good.
    b Lput_done
3:
    mov x8, SYS_close
    mov x0, x25
    svc #0

    mov x8, SYS_unlinkat
    mov x0, AT_FDCWD
    ldr_l x1, filename_tmp_str
    svc #0

    b L400

Lput_done:
    // disarm the timer
    mov x8, SYS_setitimer
    mov x0, #0
    adr_l x1, put_read_timer
    str xzr, [x1, #16] // offset 16 = it_value.tv_sec
    mov x2, #0
    svc #0

    mov x8, SYS_close
    mov x0, x25
    svc #0

    mov x8, SYS_renameat2
    mov x0, #AT_FDCWD
    ldr_l x1, filename_tmp_str
    mov x2, #AT_FDCWD
    ldr_l x3, filename_str
    mov x4, #0
    svc #0
    b_err 2f

    cbnz x19, L201
    b L204

2:
    mov x20, x0
    mov x8, SYS_unlinkat
    mov x0, AT_FDCWD
    ldr_l x1, filename_tmp_str
    svc #0
    mov x0, x20
    b handle_fs_error

// if stat failed, let's close the temp file (if opened) and then branch to
// handle_fs_error(errors.S) which will give the relevant HTTP code.
Lput_stat_failed:
    cbz x25, 3f

    // save errno from fstat64() in x1.
    mov x20, x0
    bl Lput_cleanup_tmp_file
    // restore fstat64()'s errno, in case close() also had an error lol
    mov x0, x20
3:
    b handle_fs_error

// couldn't parse content length. if x0 is 1, it's a bad request. if x0 is 0,
// no content length was actually provided.
Lpcl_error:
    cmp x0, #1
    b.eq L400
    cmp x0, #0
    b.eq L411
    cmp x0, #2
    b.eq L413

    // should never reach here. but just in case!
    b L500


// trampolines for conditional branches across files.
Lchild_end: b child_end
Lhfs_err: b handle_fs_error
Lcgi: b cgi
L201:
    mov x0, #201
    mov x1, #0
    b reply_status
L204:
    mov x0, #204
    mov x1, #0
    b reply_status
L400:
    mov x0, #400
    mov x1, #0
    b reply_status
L403:
    mov x0, #403
    mov x1, #0
    b reply_status
L405:
    mov x0, #405
    mov x1, #0
    b reply_status
L408:
    mov x0, #408
    mov x1, #0
    b reply_status
L411:
    mov x0, #411
    mov x1, #0
    b reply_status
L413:
    mov x0, #413
    mov x1, #0
    b reply_status
L500:
    mov x0, #500
    mov x1, #0
    b reply_status
