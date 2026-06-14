#include "defs.S"

.global set_env_vars
.global get_remote_addr

// we don't actually need the string buffer global, we never use the strings
// themselves, just the pointers to them.
.global env_var_ptr_buf


// i only have a macro for add_const_var because, unfortunately, sev_add_kv_var
// is called much more inconsistantly. sometimes x3 is ldr_l'd, sometime's it's
// mov'd, once it's even add'd. so i can't have a cute little macro for it :(
.macro add_const_var sym, len
    adr_l x1, \sym
    mov x2, \len
    bl sev_add_const_var
    b_err sev_failure
.endm


.data
// constant env vars
gateway_interface: .asciz "GATEWAY_INTERFACE=CGI/1.1"
.equ gateway_interface_len, . - gateway_interface

server_protocol: .asciz "SERVER_PROTOCOL=HTTP/1.1"
.equ server_protocol_len, . - server_protocol

server_software: .asciz "SERVER_SOFTWARE=ymawky"
.equ server_software_len, . - server_software

// so that CGI scripts can use things like mv, id, grep, zcat, etc -- things in
// /usr/bin or /bin.
path: .asciz "PATH=/usr/bin:/bin"
.equ path_len, . - path

path_info: .asciz "PATH_INFO=\0"
.equ path_info_len, . - path_info

// variable env vars
request_method: .ascii "REQUEST_METHOD="
.equ request_method_len, . - request_method

get_str:     .ascii "GET"
.equ get_len,     . - get_str
head_str:    .ascii "HEAD"
.equ head_len,    . - head_str
options_str: .ascii "OPTIONS"
.equ options_len, . - options_str
delete_str:  .ascii "DELETE"
.equ delete_len,  . - delete_str
put_str:     .ascii "PUT"
.equ put_len,     . - put_str
post_str:    .ascii "POST"
.equ post_len,    . - post_str

.balign 8
method_table:
    .quad get_str,     get_len
    .quad head_str,    head_len
    .quad options_str, options_len
    .quad delete_str,  delete_len
    .quad put_str,     put_len
    .quad post_str,    post_len

remote_addr: .ascii "REMOTE_ADDR="
.equ remote_addr_len, . - remote_addr

remote_host: .ascii "REMOTE_HOST="
.equ remote_host_len, . - remote_host

script_name: .ascii "SCRIPT_NAME="
.equ script_name_len, . - script_name

query_string: .ascii "QUERY_STRING="
.equ query_string_len, . - query_string

content_length: .ascii "CONTENT_LENGTH="
.equ content_length_len, . - content_length

content_type: .ascii "CONTENT_TYPE="
.equ content_type_len, . - content_type

server_name: .ascii "SERVER_NAME="
.equ server_name_len, . - server_name

server_port: .ascii "SERVER_PORT="
.equ server_port_len, . - server_port

http_host: .ascii "HTTP_HOST="
.equ http_host_len, . - http_host

host_header_str: .ascii "host:"
.equ host_header_str_len, . - host_header_str

peer_addr_len: .quad 16


.bss
.equ env_var_str_buf_size, 4096
env_var_str_buf: .skip env_var_str_buf_size

.equ env_var_ptr_buf_size, 512
env_var_ptr_buf: .skip env_var_ptr_buf_size

peer_addr: .skip 16
remote_addr_ip_buf: .skip 16
remote_addr_port_buf: .skip 8

server_addr_ip_buf: .skip 16
server_addr_port_buf: .skip 8


.text
.balign 4
// set the environmental vars used for CGI scripts
// input
// x0 -> env_var_str_buf
// x1 -> env_var_ptr_buf
//
// output
// nothing -- modifies env_var_[str/ptr]_buf
set_env_vars:
    stp x29, x30, [sp, #-80]!
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    stp x25, x26, [sp, #64]

    // populate peer_addr struct with the client's information
    mov x8, SYS_getpeername
    ldr_l w0, clientfd
    adr_l x1, peer_addr
    adr_l x2, peer_addr_len
    svc #0
    b_err L500

    adr_l x19, env_var_str_buf
    adr_l x20, env_var_ptr_buf
    mov x0, x19

    mov x21, #0 // index into string buffer
    mov x22, #0 // index into pointer buffer

    // GATEWAY_INTERFACE=CGI/1.1
    add_const_var gateway_interface, gateway_interface_len

    // SERVER_PROTOCOL=HTTP/1.1
    add_const_var server_protocol, server_protocol_len

    // SERVER_SOFTWARE=ymawky
    add_const_var server_software, server_software_len

    // PATH=/bin:/usr/bin (so CGI scripts can execute things)
    add_const_var path, path_len

    // PATH_INFO=(null)
    add_const_var path_info, path_info_len

    // get the remote connections IP (don't really need the port) for the CGI
    // script
    mov x25, x0 // save current pointer
    adr_l x0, peer_addr
    adr_l x1, remote_addr_port_buf
    adr_l x2, remote_addr_ip_buf
    bl get_remote_addr
    mov x26, x1 // save ip length in x26, we'll need it for REMOTE_HOST

    // REMOTE_ADDR=remote_addr_str_buf
    mov x0, x25 // restore pointer
    adr_l x1, remote_addr
    mov x2, remote_addr_len
    adr_l x3, remote_addr_ip_buf
    mov x4, x26 // ip length
    bl sev_add_kv_var
    b_err sev_failure

    // REMOTE_HOST=remote_addr_ip_buf
    adr_l x1, remote_host
    mov x2, remote_host_len
    adr_l x3, remote_addr_ip_buf
    mov x4, x26 // same ip, same ip length we saved above
    bl sev_add_kv_var
    b_err sev_failure

    // get our server's IP and port for the CGI script
    mov x25, x0 // save current pointer
    adr_l x0, addr // this is the address struct from ymawky.S
    adr_l x1, server_addr_port_buf
    adr_l x2, server_addr_ip_buf
    bl get_remote_addr
    mov x26, x0 // save port length in x26, we need it for SERVER_PORT

    // SERVER_NAME=server_addr_ip_buf
    mov x4, x1 // ip length from get_remote_addr
    mov x0, x25 // restore pointer
    adr_l x1, server_name
    mov x2, server_name_len
    adr_l x3, server_addr_ip_buf
    bl sev_add_kv_var
    b_err sev_failure

    // SERVER_PORT=server_addr_port_buf
    adr_l x1, server_port
    mov x2, server_port_len
    adr_l x3, server_addr_port_buf
    mov x4, x26 // port length we saved above
    bl sev_add_kv_var
    b_err sev_failure

    // HTTP_HOST=hostname
    // gotta save x0... it's the pointer for sev_add_*_var
    mov x25, x0

    // first, we look for a Host: header field
    adr_l x0, buf
    ldr_l x1, header_len
    adr_l x2, host_header_str
    mov x3, host_header_str_len
    bl get_cgi_header_field
    b_err 2f // if the Host: field doesn't exist, just skip this bit

    // now actually set the HTTP_HOST= envvar
    mov x3, x0 // x0 -> pointer to the beginning of the value
    mov x4, x1 // x1 -> length of said value
    mov x2, http_host_len
    adr_l x1, http_host
    mov x0, x25 // restore it
    bl sev_add_kv_var
    b_err sev_failure
    b 3f // skip the restore, since we already restored. that's only for no
         // header being found.
2:
    mov x0, x25 // gotta restore if the host header field didn't exist, too...
3:
    // SCRIPT_NAME=script_name_buf
    adr_l x1, script_name
    mov x2, script_name_len

    // This is pretty hack-y but i love it
    // skip past the docroot so SCRIPT_NAME=/cgi-bin/whatever instead of
    // www/cgi-bin/whatever.
    ldr_l x5, docroot_len
    // but we actually want the final / of docroot, so it's /cgi-bin/whatever
    // instead of cgi-bin/whatever
    sub x5, x5, #1
    ldr_l x3, filename_str
    add x3, x3, x5

    ldr_l x4, filename_len
    sub x4, x4, x5
    bl sev_add_kv_var
    b_err sev_failure

    // QUERY_STRING=query_str
    adr_l x1, query_string
    mov x2, query_string_len
    ldr_l x3, query_str // from data.S. TODO get better names
    ldr_l x4, query_len
    bl sev_add_kv_var
    b_err sev_failure

    // content length and content type are only for PUT/POST
    ldr_l x3, request_id
    cmp x3, #PUT_ID
    b.eq 1f
    cmp x3, #POST_ID
    b.eq 1f
    // if it's not PUT or POST, skip these
    b 3f
1:
    mov x25, x0 // save current pointer

    adr_l x0, buf // this is the header from the clients req. i've gotta rename
    ldr_l x1, header_len
    bl parse_content_length
    b_err 2f // restore pointer and go to the next one. if there's not content
            // length, there'll be no content type either. just dont set these

    // x0 should be content length from parse_content_length now.
    bl itoa
    // now x0 -> pointer to start of itoa'd string,
    //     x1 -> length of said string
    // CONTENT_LENGTH=(content-length from header)

    mov x3, x0
    mov x4, x1
    mov x0, x25 // NOW we restore the previously-saved pointer for memcpy
    adr_l x1, content_length
    mov x2, content_length_len
    bl sev_add_kv_var
    b_err sev_failure

    // now we gotta do content-type
    mov x25, x0 // save that shit
    // first, we look for a Content-Type: header field
    adr_l x0, buf
    ldr_l x1, header_len
    adr_l x2, script_ct
    ldr_l x3, script_ct_len_val
    bl get_cgi_header_field
    b_err 2f // if the Host: field doesn't exist

    // now actually set the CONTENT_TYPE= envvar
    mov x3, x0 // x0 -> pointer to the beginning of the value
    mov x4, x1 // x1 -> length of said value
    mov x2, content_type_len
    adr_l x1, content_type
    mov x0, x25 // restore it
    bl sev_add_kv_var
    b_err sev_failure
    b 3f // skip the restore
2:
    mov x0, x25 // gotta restore if the host header field didn't exist, too...
3:
    // get the request_id string from the method_table lookup table
    ldr_l x3, request_id
    cmp x3, #6
    b.hs sev_failure // if, for some reason, request_id is >= 6, that's... bad

    adr_l x5, method_table
    add x5, x5, x3, lsl #4 // make x5 point to the pair in the method table
    ldp x3, x4, [x5] // x3 -> string pointer, x4 -> string length
    adr_l x1, request_method
    mov x2, request_method_len
    bl sev_add_kv_var
    b_err sev_failure

    str xzr, [x20, x22]
    b sev_epilogue

// x0 -> destination for memcpy
// x1 -> key string
// x2 -> key string length
// x3 -> value string
// x4 -> value string length
sev_add_kv_var:
    stp x29, x30, [sp, #-32]!
    stp x25, x26, [sp, #16]

    mov x25, x3
    mov x26, x4

    cmp x22, env_var_ptr_buf_size
    b.hs 2f

    // bounds check
    add x21, x21, x2
    cmp x21, env_var_str_buf_size
    b.hs 2f

    // store pointer to current location in env_var_ptr_buf
    str x0, [x20, x22]
    add x22, x22, #8

    // store KEY= string in env_var_str_buf
    bl memcpy
    // memcpy advances x0

    // bounds check again
    add x21, x21, x26
    cmp x21, env_var_str_buf_size
    b.hs 2f

    // store value string in env_var_str_buf
    mov x1, x25
    mov x2, x26
    bl memcpy

    // bounds check and NULL terminate string
    add x21, x21, #1
    cmp x21, env_var_str_buf_size
    b.hs 2f
    strb wzr, [x0], #1

1:
    b 3f
2:
    mov x0, #-1
3:
    ldp x25, x26, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

sev_add_const_var:
    stp x29, x30, [sp, #-16]!
    cmp x22, env_var_ptr_buf_size
    b.hs 2f

    // bounds check
    add x21, x21, x2
    cmp x21, env_var_str_buf_size
    b.hs 2f

    // store pointer in env_var_ptr_buf
    str x0, [x20, x22]
    add x22, x22, #8

    // x0, x1, and x2 are set by the caller
    // store string in env_var_str_buf
    bl memcpy
1:
    b 3f
2:
    mov x0, #-1
3:
    ldp x29, x30, [sp], #16
    ret

// yup... that was all part of set_env_vars. that's why sev_add_kv_var used
// the callee-saved registers without me worrying about it :)
sev_failure:
    mov x0, #-1
sev_epilogue:
    ldp x25, x26, [sp, #64]
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #80
    ret


// given an addr struct, extract the port and ip address as a string.
// input
// x0 -> addr struct
// x1 -> buffer for port
// x2 -> buffer for ip address
//
// returns
// x0 -> number of bytes written to port buffer
// x1 -> number of bytes written to ip buffer
get_remote_addr:
    stp x29, x30, [sp, #-64]!
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]

    mov x19, x0
    mov x20, x1
    mov x23, x2

Lport:
    mov x24, #0 // index into port buffer
    add x19, x19, #2 // offset for sin_port in addr struct
    ldrh w0, [x19] // loads port as little endian
    rev16 w0, w0 // converts to big-endian
    bl itoa // convert to decimal
    // x0 -> ptr, x1 -> len

    // copy the bytes
    mov x2, #0
1:
    cmp x2, x1
    b.hs 2f
    ldrb w3, [x0, x2]
    strb w3, [x20, x24]
    add x24, x24, #1
    add x2, x2, #1
    b 1b
2:
    // fallthrough to Lip. x24 now contains bytes written into port buffer

    add x19, x19, #2 // offset for sin_addr in addr struct (+4 total, +2+2)
    mov x20, x23
    mov x21, #0
    mov x22, #0
Lip:
    cmp x22, #4
    b.hs Ldone

    ldrb w0, [x19, x22]
    bl itoa
    // x0 -> ptr, x1 -> len

    // copy x1 bytes into remote_addr_str_buf + offset
    mov x2, #0
1:
    cmp x2, x1
    b.hs 2f
    ldrb w3, [x0, x2]
    strb w3, [x20, x21]
    add x21, x21, #1
    add x2, x2, #1
    b 1b
2:
    // append a '.' if it's not the last octet
    add x22, x22, #1
    cmp x22, #4
    b.hs Ldone

    mov w3, #'.'
    strb w3, [x20, x21]
    add x21, x21, #1
    b Lip

Ldone:
    strb wzr, [x20, x21] // null terminate

    mov x0, x24 // return number of bytes written to port buf
    mov x1, x21 // return number of bytes written to ip buf

    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #64
    ret

L500:
    mov x0, #500
    mov x1, #0
    b reply_status
