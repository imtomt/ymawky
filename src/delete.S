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

.global delete

.text
.align 2

// handle "DELETE /" method.
// input
// none, uses .bss data
//
// output
// none, replies either 204 or some error code and quits.
delete:
    mov x0, #0 // do not default to index.html. do_paths_check argument
    bl do_path_checks
    ldr_l x0, filename_str

    ldrb w1, [x0]
    cmp w1, #'*'
    b.eq L400

    // at this point you know the drill. if it's a request within CGI_DIR,
    // treat it as a CGI script.
    bl check_cgi_path
    cbz x0, Lcgi

    ldr_l x0, filename_str
    bl stat_path
    cbnz x0, Ldelete_stat_failed
    cb ne, w1, #S_IFREG, L403

    mov x8, SYS_unlinkat
    mov x0, #AT_FDCWD
    ldr_l x1, filename_str
    mov x2, #AT_SYMLINK_NOFOLLOW
    svc #0
    b_err Lunlink_failed

    b L204

// these are really the same case, tbqh. the errno checks are the same. i use
// different label names for clarity when reading hehe
Ldelete_stat_failed:
Lunlink_failed:
    neg x0, x0 // errno gets returned as a negative, so make it positive

    // if the file doesn't exist (or was previously deleted), just reply 204
    // since DELETE is idempotent.
    cb eq, x0, #ENOENT, L204

    // if it's a dir, say it's not allowed. this could be 405, but i don't
    // want to build Allow: headers properly, lol. at least yet.
    cb eq, x0, #EISDIR, L403
    // other various 403s.
    cb eq, x0, #EACCES, L403
    cb eq, x0, #EPERM, L403
    cb eq, x0, #EROFS, L403
    // file is busy/conflict
    cb eq, x0, #EBUSY, L409
    // symlink
    cb eq, x0, #ELOOP, L403

    // just default to 500
    b L500


// trampolines for conditional branches across files.
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
L409:
    mov x0, #409
    mov x1, #0
    b reply_status
L500:
    mov x0, #500
    mov x1, #0
    b reply_status
Lcgi: b cgi
