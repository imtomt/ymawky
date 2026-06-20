// ymawky.S -- Web server in ARM64 assembly
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
// along with this program. If not, see <https://www.gnu.org/licenses/>.

#include "defs.S"

.global _start
.global child_end
.global addr // we use the addr struct in cgi_env.S to get server ip/port
             // we *could* hardcode 127.0.0.1, but where's the fun in that?
             // what if google dot com ends up running on ymawky huh?

.data
.balign 8

rcv_timeout:
    .quad RECV_TIMEOUT // tv_sec
    .quad 0            // tv_usec

// timer for total header -- prevent slowloris-like attackers from opening a
// connection and sending <1 byte/min or something, hogging resources.
// configured in config.S, HEADER_REQ_TIMEOUT_SECS.
read_timer:
    .quad 0   // it_interval.tv_sec
    .long 0   // it_interval.tv_usec
    .long 0   // -- padding --

    .quad 0   // it_value.tv_sec
    .long 0   // it_value.tv_usec
    .long 0   // -- padding --

.balign 8
ignore_signal:
    .quad 1   // sa_handler = SIG_IGN
    .quad 0x3 // sa_flags = SA_NOCLDWAIT | SA_NOCLDSTOP
    .quad 0   // sa_mask = nothin

.balign 4 // one is a .word (4 bytes)
one: .word 1

addr:
    .byte 0x02, 0x00             // AF_INET (2) + padding byte
    .byte 0x1f, 0x90             // Port 8080, big-endian
    .byte 0x7F, 0x00, 0x00, 0x01 // 127.0.0.1
    .byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 // padding

get_req:
    .ascii "GET "
.equ get_req_len, . - get_req

put_req:
    .ascii "PUT "
.equ put_req_len, . - put_req

head_req:
    .ascii "HEAD "
.equ head_req_len, . - head_req

options_req:
    .ascii "OPTIONS "
.equ options_req_len, . - options_req

delete_req:
    .ascii "DELETE "
.equ delete_req_len, . - delete_req

post_req:
    .ascii "POST "
.equ post_req_len, . - post_req

brew_req:
    .ascii "BREW "
.equ brew_req_len, . - brew_req

http_: .ascii "HTTP/"
.equ http_len, . - http_

http_1_0: .ascii "HTTP/1.0"
.equ http_1_0_len, . - http_1_0

http_1_1: .ascii "HTTP/1.1"
.equ http_1_1_len, . - http_1_1

host_str: .ascii "Host"
.equ host_str_len, . - host_str

arrows_in: .ascii "\n\n<<<\n"
.equ arrows_in_len, . - arrows_in

ymawky_connecting: .asciz "ymawky is connecting... "
.equ ymawky_connecting_len, . - ymawky_connecting

ymawky_connected: .asciz "connected!\n"
.equ ymawky_connected_len, . - ymawky_connected

ymawky_shutdown: .asciz "ymawky is shutting down :(\n"
.equ ymawky_shutdown_len, . - ymawky_shutdown


.bss
.balign 8
sockfd:             .skip 8
active_children:    .skip 8

.text
.balign 4

_start:
    // did we get an argument
    ldr x0, [sp]
    cmp x0, #1
    b.le skip_argv

    ldr x0, [sp, #8]
    // if it's less than 'A' (0x41), it's probably a number. so if it is, just
    // treat it as a port. otherwise, if it's > A (so any letter), let's treat
    // it as a debug option. pretty hack-y, but supes helpful for debugging, so
    // we can automatically not fork().
    cmp x0, #'A'
    b.lt 2f

    mov x28, #1
    b skip_argv

2:
    // x0 is already argv[1]
    bl atoi
    b_err fatal_exit

    // now x0 contains the integer representation of argv[1]
    mov x2, #65535
    cmp x0, x2
    b.gt fatal_exit

    // overwrite the address struct's port with the custom port.
    rev16 w0, w0 // make x0 big-endian, which the port needs to be
    adr_l x1, addr
    strh w0, [x1, #2]

skip_argv:
    mov x8, SYS_write
    mov x0, #1
    adr_l x1, ymawky_connecting
    mov x2, ymawky_connecting_len
    svc #0

    // socket(AF_INET, SOCK_STREAM, 0)
    mov x8, SYS_socket
    mov x0, #2 // AF_INET
    mov x1, #1 // SOCK_STREAM
    mov x2, #0 // nothin, TCP
    svc #0
    b_err fatal_exit

    str_l x0, sockfd

    // setsockopt(serverfd, SOL_SOCKET, SO_REUSEADDR, &value, 4)
    mov x8, SYS_setsockopt
    ldr_l x0, sockfd
    mov x1, #SOL_SOCKET
    mov x2, #SO_REUSEADDR
    adr_l x3, one
    mov x4, #4 // sizeof int
    svc #0
    b_err exit

    // bind(sockfd, &addr, 16)
    mov x8, SYS_bind
    ldr_l x0, sockfd
    adr_l x1, addr
    mov x2, #16 // the struct is 16 bytes
    svc #0
    b_err exit

    // listen(sockfd, 5)
    mov x8, SYS_listen
    ldr_l x0, sockfd
    mov x1, #5
    svc #0
    b_err exit

    mov x8, SYS_write
    mov x0, #1
    adr_l x1, ymawky_connected
    mov x2, ymawky_connected_len
    svc #0

    // ignore SIGPIPE so write() returns EPIPE instead of killing us
    mov x8, SYS_rt_sigaction
    mov w0, #SIGPIPE
    adr_l x1, ignore_signal
    mov x2, #0
    mov x3, #8
    svc #0
    b_err exit

    // set up our custom child signal handler thingy. whenever we receive
    // SIGCHLD, call our sighandler function, which calls wait4 to reap the
    // children, and modify the counter of active children. that way we can
    // refuse connections if the server is at it's configured max.
    sub sp, sp, #32
    adr_l x0, sighandler
    str x0, [sp, #0]
    mov x0, #SA_RESTORER
    str x0, [sp, #8]
    adr_l x0, sigret
    str x0, [sp, #16]

    mov x8, SYS_rt_sigaction
    mov w0, #SIGCHLD
    mov x1, sp
    mov x2, #0
    mov x3, #8
    svc #0
    add sp, sp, #32
    b_err exit

    // skip straight to the loop.
    b loop

// just some labels for signal handling. we do NOT fall through to here.
sighandler:
    mov x8, SYS_wait4
    mov x0, #-1
    mov x1, #0
    mov x2, #WNOHANG
    mov x3, #0
    svc #0

    cmp x0, #0
    b.gt 1f
    b.eq sigret // if it returned 0 we're done
    cnb eq, x0, #ECHILD, 2f
    b exit // if we're here, wait4 returned some errno other than ECHILD. die

1:
    ldr_l x0, active_children
    sub x0, x0, #1

    // if x0 >= 0, keep x0 as x0. otherwise, if x0 is negative, set it to 0.
    // we shouldn't ever go negative here, but you can never be too safe...
    cmp x0, #0
    csel x0, x0, xzr, ge
    str_l x0, active_children
    b sighandler

2:
    str_l xzr, active_children
    b sigret
    // i guess i could just have it fall through here... but this is just more
    // readable. sorry i'm not quirky enough :(

sigret:
    mov x8, SYS_rt_sigreturn
    svc #0

// now that THAT'S outta the way.... here's the continuation of our actual code
loop:
    // accept(sockfd, NULL, NULL)
    mov x8, SYS_accept
    ldr_l x0, sockfd
    mov x1, #0
    mov x2, #0
    svc #0
    b_err loop // loop if accept() failed.

    // store x0 (return of accept) in clientfd
    str_l x0, clientfd

    // we check if x28 is set, indicated "d" was passed to cli. if it was, skip
    // fork -- it's much easier to debug with lldb if there's no forking :(
    cbnz x28, child

    // gotta check if number of processes is > MAX_PROCS and fail if it is.
    ldr_l x0, active_children
    cmp x0, #MAX_PROCS
    b.lt 8f

    // uh-oh, we're at the max processes. let's give a nice, kind, smart, cute,
    // lil, friendly 503 :3
    mov x0, #503
    mov x1, #1 // we DO want to return here!
    bl reply_status
    b 2f // close n loop!

8:
    // update our child counter
    ldr_l x0, active_children
    add x0, x0, #1
    str_l x0, active_children

    // clone()
    mov x8, SYS_clone
    mov x0, SIGCHLD
    mov x1, #0
    mov x2, #0
    mov x3, #0
    mov x4, #0
    svc #0
    b_err 2f // clone failed :( fuck :( close and loop again :(

    // if we're in the child, go there
    cbz x0, child
2:
    // otherwise close clientfd and loop
    mov x8, SYS_close
    ldr_l x0, clientfd
    svc #0

    b loop


child:
    // close sockfd
    mov x8, SYS_close
    ldr_l x0, sockfd
    svc #0

    // setsockopt() with a SO_RCVTIMEO timeout from config.S, to prevent
    // connections from staying open indefinitely
    mov x8, SYS_setsockopt
    ldr_l x0, clientfd
    mov x1, #SOL_SOCKET
    mov x2, #SO_RCVTIMEO
    adr_l x3, rcv_timeout
    mov x4, #16 // struct timeval is 16 bytes
    svc #0
    b_err child_end

    // arm timer before reading
    mov x8, SYS_setitimer
    mov x0, #0 // ITIMER_REAL
    adr_l x1, read_timer
    mov x2, #HEADER_REQ_TIMEOUT_SECS
    str x2, [x1, #16] // offset 16 = it_value.tv_sec
    mov x2, #0
    svc #0

    // set a signal handler for SIGALRM, so we can respond with 408 if the
    // connection times out during the header.
    // i was right this is actually much much simpler in linux than macos lol
    sub sp, sp, #32
    adr_l x0, L408
    str x0, [sp, #0]   // sa_handler
    str wzr, [sp, #8]  // sa_flags
    str wzr, [sp, #16] // sa_mask

    mov x8, SYS_rt_sigaction
    mov w0, #SIGALRM
    mov x1, sp
    mov x2, #0
    mov x3, #8
    svc #0
    add sp, sp, #32
    b_err L500

    // read(client_fd, buffer, buffer_size)
    mov x7, #0
read_loop:
    mov x8, SYS_read
    ldr_l x0, clientfd
    adr_l x1, buf
    add x1, x1, x7 // account for buffer being partially filled
    mov x22, #BUF_SIZE
    sub x2, x22, x7 // BUF_SIZE - bytes_read
    svc #0
    b_err read_failed
    mov x22, x0 // stash number of bytes read() got in x22

    add x7, x7, x0 // save x0 because parse_header_end clobbers it. cumulatively

    adr_l x0, buf
    mov x1, x7
    bl parse_header_end
    cmp x1, #0
    b.eq Lno_header

    // header end was found, break out of the karmic cycle of reading
    b Lheader_found

Lheader_found:
    mov x23, x1 // end of header index (one byte after \r\n\r\n)
    mov x24, x7 // total bytes
    str_l x24, header_len
    b 2f // break from the hell of reading

Lno_header:
    cmp x22, #0 // x22 is number of bytes from read() now
    b.ne 1f // if nonzero, check buffer fill state
    cmp x7, #0 // if we read nothing,
    b.eq child_end // go to child_end and silently exit

    // otherwise if we're done reading but still no header, send 400
    b L400

1:
    cmp x7, #BUF_SIZE
    b.ge L431

    b read_loop

read_failed:
    // if read was interrupted by a signal, retry instead of exiting. doesn't
    // affect x7/buf offset.
    cnb eq, x0, #EINTR, read_loop

    // check if errno is ECONNRESET, ECONNABORTED, ETIMEDOUT, then just
    // silently exit if so. otherwise, return server error.
    cnb eq, x0, #ECONNRESET, child_end
    cnb eq, x0, #ETIMEDOUT, child_end
    cnb eq, x0, #ECONNABORTED, child_end
    cnb eq, x0, #EPIPE, child_end
    cnb eq, x0, #ENETDOWN, child_end
    cnb eq, x0, #ENETUNREACH, child_end
    cnb eq, x0, #ENETRESET, child_end
    cnb eq, x0, #EHOSTDOWN, child_end
    cnb eq, x0, #EHOSTUNREACH, child_end

    b L500

2:
    // disarm timer
    mov x8, SYS_setitimer
    mov x0, #0
    adr_l x1, read_timer
    str xzr, [x1, #16] // offset 16 = it_value.tv_sec
    mov x2, #0
    svc #0

    // let's make sure buf is NULL terminated
    adr_l x1, buf
    strb wzr, [x1, x24] // x24 -> length of bytes read

    // write \n\n<<<\n to stdout to mark a header we're receiving
    mov x8, SYS_write
    mov x0, #1
    adr_l x1, arrows_in
    mov x2, arrows_in_len
    svc #0

    // this just writes the request to stdout
    mov x8, SYS_write
    mov x0, #1
    adr_l x1, buf
    mov x2, x23
    svc #0

    adr_l x0, buf
    mov x1, x23
    bl verify_http_version

    // check if we got a GET request. if so, jump to get!
    adr_l x0, buf
    adr_l x1, get_req
    mov x2, get_req_len
    bl streqn
    cmp x0, #1
    b.eq Lget_method

    // check if maybe we got a HEAD request instead.
    adr_l x0, buf
    adr_l x1, head_req
    mov x2, head_req_len
    bl streqn
    cmp x0, #1
    b.eq Lhead_method

    // hm. maybe it was an OPTIONS request?
    adr_l x0, buf
    adr_l x1, options_req
    mov x2, options_req_len
    bl streqn
    cmp x0, #1
    b.eq Loptions_method

    // could be a DELETE request, i *guess*...
    adr_l x0, buf
    adr_l x1, delete_req
    mov x2, delete_req_len
    bl streqn
    cmp x0, #1
    b.eq Ldelete_method

    // oh i know! PUT!
    adr_l x0, buf
    adr_l x1, put_req
    mov x2, put_req_len
    bl streqn
    cmp x0, #1
    b.eq Lput_method

    // oohhh, could it be a POST? that's a fancy one!
    adr_l x0, buf
    adr_l x1, post_req
    mov x2, post_req_len
    bl streqn
    cmp x0, #1
    b.eq Lpost_method

    // oh god. it's probably BREW. unfortunately, I'm a teapot, so we can't
    // support that method.
    adr_l x0, buf
    adr_l x1, brew_req
    mov x2, brew_req_len
    bl streqn
    cmp x0, #1
    b.eq L418

    // if it was none of the above, reply 501
    b L501

Lget_method:
    mov x0, GET_ID
    str_l x0, request_id

    adr_l x0, buf
    mov x1, x23
    b get

Lput_method:
    mov x0, PUT_ID
    str_l x0, request_id

    adr_l x0, buf
    mov x1, x23
    mov x2, x24
    b put

Lhead_method:
    mov x0, HEAD_ID
    str_l x0, request_id
    b head

Loptions_method:
    mov x0, OPTIONS_ID
    str_l x0, request_id
    b options

Ldelete_method:
    mov x0, DELETE_ID
    str_l x0, request_id
    b delete

Lpost_method:
    mov x0, POST_ID
    str_l x0, request_id
    b put


child_end:
    // close(clientfd)
    mov x8, SYS_close
    ldr_l x0, clientfd
    svc #0

    ldr_l x0, file_des
    cmn x0, #1
    b.eq 1f
    mov x8, SYS_close
    // x0 is set
    svc #0
1:
    // This is always for children, so let's exit. the parent will loop
    mov x8, SYS_exit
    mov x0, #0
    svc #0


exit:
    mov x8, SYS_write
    mov x0, #1
    adr_l x1, ymawky_shutdown
    mov x2, ymawky_shutdown_len
    svc #0

    // shutdown(sockfd, SHUT_RDRW)
    mov x8, SYS_shutdown
    ldr_l x0, sockfd
    mov x1, #2 // SHUT_RDRW
    svc #0

    // close(sockfd)
    mov x8, SYS_close
    ldr_l x0, sockfd
    svc #0
    // fallthrough
fatal_exit:
    // exit(1)
    mov x8, SYS_exit
    mov x0, #1
    svc #0


// verify the header has an HTTP version and that it's 1.1 or 1.0
// if it's 1.1, ensure we have a Host: field.
// input
// x0 -> header buffer
// x1 -> header length
//
// returns
// nothing, kills process on failure
verify_http_version:
    stp x29, x30, [sp, #-32]!
    stp x20, x21, [sp, #16]

    mov x20, x0
    mov x21, x1

    mov x0, #0
1:
    ldrb w1, [x20, x0]
    cmp w1, #'\r'
    b.ne 2f

    add x0, x0, #1
    cmp x0, x21
    b.ge L400

    ldrb w1, [x20, x0]
    cmp w1, #'\n'
    b.eq 3f

2:
    add x0, x0, #1
    cmp x0, x21
    b.ge L400
    b 1b

3:
    // gotta have at least 9 bytes to hold HTTP/1.1\r
    cmp x0, #9
    b.lt L400

    // x0 points to the index of the \n in \r\n.
    sub x9, x0, #9
    // now it should point to where the "H" would be.

    // HTTP/1.1
    add x0, x20, x9
    adr_l x1, http_1_1
    mov x2, http_1_1_len
    bl streqn
    cmp x0, #1
    b.eq Lhttp11

    // HTTP/1.0
    add x0, x20, x9
    adr_l x1, http_1_0
    mov x2, http_1_0_len
    bl streqn
    cmp x0, #1
    b.eq Lhttp10

    // some other http version?
    add x0, x20, x9
    adr_l x1, http_
    mov x2, http_len
    bl streqn
    cmp x0, #1
    b.eq L505

    // oops. none.
    b L400

Lhttp11:
    // if it's 1.1, we need a Host: field.
    mov x0, x20
    mov x1, x21
    adr_l x2, host_str
    mov x3, host_str_len
    bl get_header_field
    b_err L400

    b vh_epilogue

Lhttp10:
    // HTTP/1.0 doesn't need Host:
    b vh_epilogue

vh_epilogue:
    ldp x20, x21, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

L400:
    mov x0, #400
    mov x1, #0
    b reply_status
L408:
    mov x0, #408
    mov x1, #0
    b reply_status
L418:
    mov x0, #418
    mov x1, #0
    b reply_status
L431:
    mov x0, #431
    mov x1, #0
    b reply_status
L500:
    mov x0, #500
    mov x1, #0
    b reply_status
L501:
    mov x0, #501
    mov x1, #0
    b reply_status
L505:
    mov x0, #505
    mov x1, #0
    b reply_status
