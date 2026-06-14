#include "defs.S"

.global options

.text
options:
    // do not default to index.html
    mov x0, #0
    bl do_path_checks

    ldr_l x0, filename_str
    ldrb w1, [x0]
    cmp w1, #'*'
    b.eq L204

    // is this a request for a file in CGI_DIR?
    bl check_cgi_path
    cbz x0, Lcgi

    ldr_l x0, filename_str
    bl stat_path
    cbnz x0, Lhfs_err
    cmp w1, #S_IFREG
    b.ne L403

    b L204

Lhfs_err: b handle_fs_error
Lcgi: b cgi
L204:
    mov x0, #204
    mov x1, #0
    b reply_status
L403:
    mov x0, #403
    mov x1, #0
    b reply_status
