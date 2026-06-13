#include "defs.S"

// this file is ugly and long as fuck. TODO: clean it up, split into multiple
// different files.

/*
 * TODO
 * use pipe2, put some stuff in .bss, 2 variables stdout_pipe and stdin_pipe
 * instead of the 4 currently, since pipe2() takes an array of 2 ints.
 * use dup3 instead of dup2.
 * use CLOEXEC (0x80000) for pipe2()
 * parent still closes stdin read (first 4 bytes of stdin_pipe) and stdout write
 * (last 4 bytes of stdout_pipe, so [stdout_pipe, #4]).
 * child can just use dup3([stdin_pipe], 0, 0) and dup3([stdout_pipe, #4], 1, 0)
 * instead of needing to close their pipes manually. thanks, CLOEXEC!
 */

.global cgi

.global script_ct
.global script_ct_len_val

.data
.balign 8
cgi_read_timer:
    .quad 0
    .long 0
    .long 0

    .quad 0
    .long 0
    .long 0

.balign 16
cgi_dir: .ascii DOCROOT
         .ascii CGI_DIR
.equ cgi_dir_len, . - cgi_dir
cgi_dir_len_val: .quad cgi_dir_len

.balign 16
argv: .quad 0
      .quad 0

crlf: .ascii "\r\n"
.equ crlf_len, . - crlf

// Stuff for the HTTP header
cgi_server_headers: .ascii "Server: ymawky\r\n"
                    .ascii "Connection: close\r\n"
                    .ascii "X-Content-Type-Options: nosniff\r\n"
.equ cgi_server_headers_len, . - cgi_server_headers

cgi_status: .ascii "HTTP/1.1 "
.equ cgi_status_len, . - cgi_status

// CGI script should send it's own status, but just in case it dooesn't
cgi_200: .ascii "200 OK\r\n"
.equ cgi_200_len, . - cgi_200

// Header fields from the CGI script to not forward in our response
// we check with streqn_i,
script_status: .ascii "status:"
.equ script_status_len, . - script_status

script_conn: .ascii "connection:"
.equ script_conn_len, . - script_conn

script_ct: .ascii "content-type:"
.equ script_ct_len, . - script_ct
.balign 8
script_ct_len_val: .quad script_ct_len // we need this so we can use it in
                                       // cgi_env.S ugh

.balign 4
peer_addr_len:.quad 16

.bss
.balign 8
child_pid:    .skip 8
peer_addr:    .skip 16
stdin_pipe:   .skip 8
stdout_pipe:  .skip 8
status:       .skip 4
cgi_buf:      .skip BUF_SIZE

.text
// main CGI function
// inputs
// none -- uses global data
//
// returns
// nothing -- sends reply to client and exits
cgi:
    ldr_l x0, filename_str
    bl stat_path
    cbnz x0, Lhfs_error

    // cgi is only files. shouldn't be directories. no dir listing on cgi-bin,
    // sorry :(
    cmp w1, #S_IFREG
    b.ne L403

    // x3 is a boolean, is file executable? 0 means no. file isn't executable,
    // that's a problem on the servers end. why the HELL do you have
    // nonexecutable files in the CGI script directory, huh?! go fix that.
    cbz x3, L500

    // populate query_string and script_name variables
    bl get_script_path_elements
    b.cs L500
    adr_l x0, script_name_buf // save em
    str_l x0, argv

    // set env variables... this function just Does it, doesn't need any args.
    bl set_env_vars
    b.cs L500

    // SYS_pipe()
    mov x8, #SYS_pipe2
    adr_l x0, stdin_pipe
    mov x1, O_CLOEXEC
    svc #0
    b.cs L500
    str_l w0, cgi_stdin_r
    str_l w1, cgi_stdin_w

    mov x8, #SYS_pipe2
    mov x0, stdout_pipe
    mov x1, O_CLOEXEC
    svc #0
    b.cs L500
    str_l w0, cgi_stdout_r
    str_l w1, cgi_stdout_w

about_to_fork:
    // SYS_clone()
    mov x8, SYS_fork
    mov x0, SIGCHLD
    mov x1, #0
    mov x2, #0
    mov x3, #0
    mov x4, #0
    svc #0
    cmn x0, #4095
    b.hi L500 // just bail if fork fails

    // are we the child?
    cbz x0, child

    // if not, then we're the...
cgi_parent:
    str_l x0, child_pid // store the pid of the child process XXX
    // we can close() the unused fds
    // close stdin_r
    mov x8, SYS_close
    ldr w0, stdin_pipe // offset 0 = read end
    svc #0
    b.cs L500
    // close stdout_w
    mov x8, SYS_close
    adr_l x1, stdout_pipe
    ldr w0, [x1, #4] // offset 4 = write end
    svc #0
    b.cs L500

    ldr_l x0, request_id
    cb eq, x0, #PUT_ID, 1f
    cb eq, x0, #POST_ID, 1f
    b Lnothing_to_forward // skip this whole mess if it's not PUT or POST
1:
    // ok, if we're here, it's a PUT or POST request. those require a body.
    // bodies require content length. we need to forward the body from the orig
    // request to the cgi script's stdin

    // make sure we actually have a valid header.
    adr_l x0, buf
    ldr_l x1, header_len
    bl parse_header_end
    cbz x1, L400
    mov x20, x1

    // get content length
    adr_l x0, buf
    ldr_l x1, header_len
    bl parse_content_length
    b.cc 2f // if there is content-length, just continue and skip the next check

    // if we're here, there's no content length. that's fine for POST. ymawky
    // requires content length for PUT, however, so let's check that.
    ldr_l x0, request_id
    cb eq, x0, #PUT_ID, L411 // 411 if it's a PUT request
    cb eq, x0, #POST_ID, Lforward_done // just skip this bit if it's post

    // we genuinely should never be here, request_id should be only PUT_ID or
    // POST_ID, based on our check ~25 lines up. but you know what they say
    // when you assume? you make an Ass out of U and Me. don't make an ass out
    // of me. let's just 500 if we're in this supposedly unreachable code.
    b L500

2:
    ldr_l x1, header_len
    mov x2, x20
    // x0 = Content-Length header field
    // x1 = total read from client in ymawky.S
    // x2 = index at end of header, everything after is body
    mov x23, x0 // x23 = content length, total body expected
    sub x24, x1, x2 // x24 = body bytes already in buf

    cmp x24, x23
    csel x24, x23, x24, hi // if x24 > x23, x24 = x23

    // we're gonna set up a PUT-like sigalarm handler for slowloris-like attack
    // mitigation for CGI scripts. note that this only detects reads from the
    // client to the server -- it won't catch hangs in the CGI scripts
    // themselves.
    // setup sigalarm handler
    adr_l x0, Lcgi_sigalrm_handler
    sub sp, sp, #32
    str x0, [sp, #0]
    str wzr, [sp, #8]
    str wzr, [sp, #16]

    mov x8, SYS_rt_sigaction
    mov w0, #SIGALRM
    mov x1, sp
    mov x2, #0
    mov x3, #8
    svc #0
    add sp, sp, #32
    b.cs L500

    // gonna calculate it the same way as PUT.
    mov x1, #PUT_MIN_BPS
    udiv x2, x23, x1
    add x2, x2, #PUT_GRACE_SECS

    adr_l x0, cgi_read_timer
    str x2, [x0, #16]

    // set the actual timer
    mov x8, SYS_setitimer
    mov x0, #0
    adr_l x1, cgi_read_timer
    mov x2, #0
    svc #0
    b.cs L500

    // nothing in buf, so skip to the loop
    cbz x24, Lforward_loop

    // write whatever body is already present in buf, to cgi_stdin_w
    ldr_l w0, cgi_stdin_w
    adr_l x1, buf
    add x1, x1, x20
    mov x2, x24
    bl write_all
    b.cs Lhfs_error

Lforward_loop:
    // remaining = content_length - bytes_so_far
    sub x25, x23, x24
    //cbz x25, Lcgi_read_zero // nothin more to forward!
    cbz x25, Lforward_done

    // read min(remaining, BUF_SIZE) bytes from clientfd
    mov x8, SYS_read
    ldr_l w0, clientfd
    adr_l x1, cgi_buf
    mov x2, BUF_SIZE
    cmp x2, x25
    csel x2, x2, x25, lo
    svc #0
    b.cs Lforward_read_failed
    //b.cs Lread_failed
    b.cs Lhfs_error
    cbz x0, Lerror // client closed? before sending full body? dumb. error.
    mov x26, x0 // x26 = bytes just read

    // now forward those bytes to cgi_stdin_w
    ldr_l w0, cgi_stdin_w
    adr_l x1, cgi_buf
    mov x2, x26
    bl write_all
    b.cs Lhfs_error

    add x24, x24, x26
    b Lforward_loop

Lforward_read_failed:
    cmp x0, #EINTR
    b.eq Lforward_loop
    b Lerror

Lcgi_read_zero:
    // disarm the timer
    mov x8, SYS_setitimer
    mov x0, #0
    adr_l x1, cgi_read_timer
    str xzr, [x1, #16]
    mov x2, #0
    svc #0
    // fallthrough
Lforward_done:
    // close cgi_stdin_w to signal EOF
    mov x8, SYS_close
    ldr_l w0, cgi_stdin_w
    svc #0
    b.cs Lhfs_error

Lnothing_to_forward:
    // this is a boolean. have we already output a header? 0 = no, 1 = yes
    mov x19, #0
    mov x20, #0
Lread_loop:
    // read loop will send us to either Lheader_read_loop or Lbody_read_loop,
    // depending on the value of x19. since both functions call read(), and
    // b.cs Lread_failed if read fails, and Lread_failed might branch *back*
    // to Lread_loop, we have to know which path we're currently at. that's
    // why we track x19
    cbz x19, Lheader_read_loop
    b Lbody_read_loop

Lheader_read_loop:
    mov x8, SYS_read
    ldr_l w0, cgi_stdout_r
    adr_l x1, cgi_buf
    add x1, x1, x20 // append to cgi_buf, rather than overwriting
    mov x2, BUF_SIZE
    sub x2, x2, x20 // reduce buf_size by bytes already read
    cbz x2, L502 // if we've filled the whole buffer, gotta give a 502.
                 // BAD gateway!
    svc #0
    b.cs Lread_failed
    cbz x0, L502 // EOF before terminator also gives 502.

    mov x22, x0
    add x20, x20, x0

    adr_l x0, cgi_buf
    mov x1, x20
    bl parse_cgi_header_end
    cbz x1, Lread_loop

    // if we got here, then we've found a header block. gotta output that.
    mov x22, x1 // x22 = body start offset. save it!
    mov x21, x2

    // check for Status:
    adr_l x0, cgi_buf
    mov x1, x22 // header length
    adr_l x2, script_status
    mov x3, script_status_len
    bl get_cgi_header_field
    // now x0/x1 contain pointer/length of value, or carry set if not found
    b.cs Ldefault_status
    mov x23, x0 // save pointer
    mov x24, x1 // save length

    // "HTTP/1.1 "
    ldr_l x0, clientfd
    adr_l x1, cgi_status
    mov x2, cgi_status_len
    bl write_all
    b.cs Lerror

    // value from cgi header
    ldr_l x0, clientfd
    mov x1, x23
    mov x2, x24
    bl write_all
    b.cs Lerror

    // "\r\n"
    ldr_l x0, clientfd
    adr_l x1, crlf
    mov x2, crlf_len
    bl write_all
    b.cs Lerror

    b Lstatus_done

Ldefault_status:
    // "HTTP/1.1 "
    ldr_l x0, clientfd
    adr_l x1, cgi_status
    mov x2, cgi_status_len
    bl write_all
    b.cs Lerror

    // "200 OK\r\n"
    ldr_l x0, clientfd
    adr_l x1, cgi_200
    mov x2, cgi_200_len
    bl write_all
    b.cs Lerror
    // fallthrough
Lstatus_done:
    // phew. ok. now we gotta check for Content-Type
    adr_l x0, cgi_buf
    mov x1, x22
    adr_l x2, script_ct
    mov x3, script_ct_len
    bl get_cgi_header_field
    b.cc Lgot_ct
    // not found... if there's a body, that's bad. Content-Type is required
    // if there's a body! so we gotta check.
    sub x3, x20, x22
    cbnz x3, L502

Lgot_ct:
    // first, we gotta print our constant server header fields...
    ldr_l x0, clientfd
    adr_l x1, cgi_server_headers
    mov x2, cgi_server_headers_len
    bl write_all
    b.cs Lerror

    // now, we forward all of the script's headers, minus a couple:
    // the function here doesn't send Status: or Connection: header fields,
    // we do that on our own above.
    sub x1, x22, x21
    adr_l x0, cgi_buf
    ldr_l x2, clientfd
    bl forward_headers_from_script

    // finally we can send an \r\n and be done with it.
    ldr_l x0, clientfd
    adr_l x1, crlf
    mov x2, #2
    bl write_all
    b.cs Lerror

    // if we have any leftover bytes from the body, write em out now
    sub x2, x20, x22 // leftover length = total - header length
    cbz x2, 1f // if there's nothing leftover, skip this
    ldr_l x0, clientfd
    adr_l x1, cgi_buf
    add x1, x1, x22 // cgi_buff + header length offset
    bl write_all
    b.cs Lerror

1:
    mov x19, #1
Lbody_read_loop:
    // stream any remaining body content from cgi script's stdout, to clientfd
    mov x8, SYS_read
    ldr_l w0, cgi_stdout_r
    adr_l x1, cgi_buf
    mov x2, BUF_SIZE
    svc #0
    b.cs Lread_failed
    cbz x0, Lloop_end // hit EOF? we're donezo (in a good way)

    mov x2, x0
    ldr_l x0, clientfd
    adr_l x1, cgi_buf
    bl write_all
    b.cs Lerror

    b Lbody_read_loop

Lread_failed:
    cmp x0, #EINTR
    b.eq Lread_loop

    // otherwise, it's an error :(
    b Lerror

Lloop_end:
    mov x8, SYS_wait4
    mov x0, #-1 // any child
    adr_l x1, status // where to store wstatus
    mov x2, #0 // options
    mov x3, #0 // rusage = NULL
    svc #0

    b child_end


// ok fine we're a kid! yay! *plays on a swingset*
cgi_child:
    //[cgi_stdin_pipe] (offset 0) = read end, [cgi_stdin_pipe, #4] (offset 4) = write end.
    // we've gotta close() unused fds
    // close stdin_w
    mov x8, SYS_close
    ldr_l w0, cgi_stdin_w
    svc #0
    b.cs Lchild_error

    // close stdout_r
    mov x8, SYS_close
    ldr_l w0, cgi_stdout_r
    svc #0
    b.cs Lchild_error

    // duplicate the file descriptors to be actually stdin/out
    mov x8, SYS_dup3
    ldr w0, stdin_pipe
    mov w1, #0
    mov w2, #0
    svc #0

    mov x8, SYS_dup3
    adr_l x1, stdout_pipe
    ldr w0, [x1, #4]
    mov w1, #1
    mov w2, #0
    svc #0

    // we gotta chdir into the right directory
    mov x8, #12 // SYS_chdir
    adr_l x0, script_path_buf
    svc #0
    b.cs Lchild_error

    // FINALLY we can FUCKING EXECVE
    mov x8, SYS_execve
    adr_l x0, script_name_buf
    adr_l x1, argv
    adr_l x2, env_var_ptr_buf
    svc #0

    // execve() is supposed to replace this child process with that one. if we
    // return here after execve, something has gone horribly wrong... so just
    // consider it an error
    b Lchild_error

Lchild_error:
    mov x8, SYS_exit
    // x0 is usually errno now
    svc #0

Lerror:
    b child_end


// input
// x0 -> header buffer
// x1 -> header length
// x2 -> clientfd
//
// returns
// nothing...?
forward_headers_from_script:
    stp x29, x30, [sp, #-64]!
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    str x23, [sp, #48]

    mov x19, x0     // current = start
    add x20, x0, x1 // end = start + length
    mov x21, x2     // clientfd

fhfs_next_line:
    // bounds check! everybody show me your bounds!
    cmp x19, x20
    b.hs fhfs_done

    mov x22, x19 // store line start

    // if the first byte is a ' ' or '\t', we've got to reject that. it's
    // obsolete line folding which is deprecated because of security risks.
    // id hope any scripts dont do this, but you never know. reject with 502
    ldrb w3, [x19]
    cmp w3, #' '
    b.eq fhfs_malformed
    cmp w3, #'\t'
    b.eq fhfs_malformed

    // look for the end of the line. scan for \n
fhfs_scan:
    // if we hit the end of the buffer with no \n, something's broken
    cmp x19, x20
    b.hs fhfs_malformed

    ldrb w3, [x19]
    cmp w3, #'\n'
    b.eq fhfs_found_nl
    add x19, x19, #1
    b fhfs_scan

fhfs_found_nl:
    // compute content length
    sub x23, x19, x22
    // line length shouldn't possibly be 0, so something mustve gone horribly
    // wrong. bail.
    cbz x23, fhfs_malformed

    // strip trailing \r if present
    sub x4, x19, #1
    ldrb w5, [x4]
    cmp w5, #'\r'
    b.ne 1f
    sub x23, x23, #1
1:
    add x19, x19, #1 // advance past the current \n, for next iteration
    // fallthrough
fhfs_check_status:
    // check if line starts with "status:"
    // oblig bounds check
    mov x2, script_status_len
    cmp x23, x2           //>> hii
    b.lo fhfs_check_conn

    mov x0, x22
    adr_l x1, script_status
    // x2 was set up there ^^
    bl streqn_i
    cbnz x0, fhfs_skip_line

fhfs_check_conn:
    // check if line starts with "connection:"
    mov x2, script_conn_len
    cmp x23, x2
    b.lo fhfs_write_line

    mov x0, x22
    adr_l x1, script_conn
    // x2 was already set
    bl streqn_i
    cbnz x0, fhfs_skip_line
    // fallthrough
fhfs_write_line:
    // write the line + \r\n
    mov x0, x21 // clientfd
    mov x1, x22 // line start
    mov x2, x23 // line length, without the newlines
    bl write_all
    b.cs fhfs_write_error

    mov x0, x21
    adr_l x1, crlf
    mov x2, crlf_len
    bl write_all
    b.cs fhfs_write_error

    b fhfs_next_line

fhfs_skip_line:
    // x19 already advanced past the \n, so we can just loop
    b fhfs_next_line

fhfs_done:
    cmn xzr, xzr // clear carry
    b fhfs_epilogue

fhfs_malformed:
    mov x0, #0 // set x0 to #0 to differentiate between write failing and
               // malformed headers.
    // fallthrough
fhfs_write_error:
    // if we failed due to write, x0 should now be errno.
    cmp xzr, xzr // set carry
    // fallthrough
fhfs_epilogue:
    ldr x23, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #64
    ret

// if we branch to L40... whatever *after* the CGI script is already execve'd,
// we want to terminate it.
kill_kid:
    ldr_l x1, child_pid
    cbz x1, 1f // if child_pid is 0, it hasn't set yet. skip the kill. we don't
               // want to kill PID 0, since that would kill ymawky. lol

//[cgi_stdin_pipe] (offset 0) = read end, [cgi_stdin_pipe, #4] (offset 4) = write end.
    mov x8, SYS_close
    ldr w0, stdout_pipe
    svc #0

    mov x8, SYS_close
    adr_l x1, stdin_pipe
    mov w0, [x1, #4]
    svc #0

    mov x8, SYS_kill
    ldr_l x0, child_pid
    mov x1, #15 // SIGTERM the child
    svc #0

    mov x8, SYS_wait4
    mov x0, #-1
    adr_l x1, status
    mov x2, #0
    mov x3, #0
    svc #0
1:
    ret

Lcgi_sigalrm_handler:
    bl kill_kid

    mov x0, #408
    mov x1, #0
    b reply_status

Lhfs_error: b handle_fs_error
L400:
    bl kill_kid
    mov x0, #400
    mov x1, #0
    b reply_status
L403:
    bl kill_kid
    mov x0, #403
    mov x1, #0
    b reply_status
L411:
    bl kill_kid
    mov x0, #411
    mov x1, #0
    b reply_status
L500:
    bl kill_kid
    mov x0, #500
    mov x1, #0
    b reply_status
L502:
    bl kill_kid
    mov x0, #502
    mov x1, #0
    b reply_status
