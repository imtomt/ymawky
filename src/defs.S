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

#include "config.S"

// macros
// turn adrp ... add ... into one call, adrl_l
.macro adr_l, reg, sym
    adrp \reg, \sym
    add \reg, \reg, :lo12:\sym
.endm

// same with adrp ... (add ...) ldr ...
.macro ldr_l reg, sym, scratch=x9
    adrp \scratch, \sym
    ldr \reg, [\scratch, :lo12:\sym]
.endm

// and adrp ... (add ...) str ...
.macro str_l src, sym, scratch=x9
    adrp \scratch, \sym
    str \src, [\scratch, :lo12:\sym]
.endm

// (c)ompare and (b)ranch, (eq/ne/gt/etc), x0, x1, label
.macro cb cond, r1, r2, l
    cmp \r1, \r2
    b.\cond \l
.endm

// (c)ompare (n)egative and (b)ranch, (eq/ne ONLY), x0, x1, label
.macro cnb cond, r1, r2, l
    cmn \r1, \r2
    b.\cond \l
.endm


// since Linux syscalls return -value instead of just setting the carry bit, we
// can't just use b.cs after syscalls to check for errors. this macro just
// makes it easier
.macro b_err label, reg=x0
    cmn \reg, #4095
    b.hi \label
.endm


.equ SYS_chdir,         49
.equ SYS_exit,          93
.equ SYS_clone,         220
.equ SYS_read,          63
.equ SYS_write,         64
.equ SYS_openat,        56
.equ SYS_close,         57
.equ SYS_wait4,         260
.equ SYS_getpid,        172
.equ SYS_accept,        202
.equ SYS_getpeername,   205
.equ SYS_kill,          129
.equ SYS_pipe2,         59
.equ SYS_rt_sigaction,  134
.equ SYS_rt_sigreturn,  139
.equ SYS_execve,        221
.equ SYS_munmap,        215
.equ SYS_setitimer,     103
.equ SYS_dup3,          24
.equ SYS_socket,        198
.equ SYS_bind,          200
.equ SYS_setsockopt,    208
.equ SYS_listen,        201
.equ SYS_shutdown,      210
.equ SYS_mmap,          222
.equ SYS_getppid,       173
.equ SYS_newfstatat,    79
.equ SYS_fstat,         80
.equ SYS_getdents64,    61
.equ SYS_unlinkat,      35
.equ SYS_renameat2,     276

// getdents64 struct layout
.equ OFF_D_INO,     0   // u64  d_ino
.equ OFF_D_OFF,     8   // s64  d_off
.equ OFF_D_RECLEN,  16  // u16  d_reclen
.equ OFF_D_TYPE,    18  // u8   d_type
.equ OFF_D_NAME,    19  // char d_name[]
.equ DT_DIR,        4

.equ BUF_SIZE,       16384

// constants for setsockopt
.equ SOL_SOCKET,     1
.equ SO_REUSEADDR,   2
.equ SO_RCVTIMEO,    20 // this is technically SO_RCVTIMEO_OLD, but that's what
                        // we want

// stat struct layout
.equ OFF_ST_MODE,    16
.equ OFF_ST_SIZE,    48
.equ S_IFREG,        0x8000
.equ S_IFDIR,        0x4000
.equ S_IXUSR,        0x40
.equ S_IXGRP,        0x08
.equ S_IXOTH,        0x01
.equ S_IXANY,        0x49

.equ EPERM,          1
.equ ENOENT,         2
.equ EINTR,          4
.equ ECHILD,         10
.equ EACCES,         13
.equ EFAULT,         14
.equ EBUSY,          16
.equ ENOTDIR,        20
.equ EISDIR,         21
.equ EINVAL,         22
.equ EFBIG,          27
.equ ENOSPC,         28
.equ EROFS,          30
.equ EPIPE,          32
.equ EAGAIN,         11
.equ ENAMETOOLONG,   36
.equ ENOTEMPTY,      39
.equ ELOOP,          40
.equ ENETDOWN,       100
.equ ENETUNREACH,    101
.equ ENETRESET,      102
.equ ECONNABORTED,   103
.equ ECONNRESET,     104
.equ ETIMEDOUT,      110
.equ EHOSTDOWN,      112
.equ EHOSTUNREACH,   113
.equ EDQUOT,         122

.equ SIGPIPE,        13
.equ SIGALRM,        14
.equ SIGCHLD,        17
.equ SIG_IGN,        1
.equ SA_RESTORER,    0x04000000
.equ SA_NOCLDWAIT,   0x00000002
.equ WNOHANG,        0x00000001

.equ O_RDONLY,       0x0000
.equ O_WRONLY,       0x0001
.equ O_CREAT,        0x40
.equ O_TRUNC,        0x200
.equ O_NOFOLLOW,     0x20000
.equ O_CLOEXEC,      0x80000

.equ AT_SYMLINK_NOFOLLOW, 0x100
.equ AT_REMOVEDIR,        0x200
.equ AT_FDCWD,           -100

// request type ids
.equ GET_ID,     0
.equ HEAD_ID,    1
.equ OPTIONS_ID, 2
.equ DELETE_ID,  3
.equ PUT_ID,     4
.equ POST_ID,    5
