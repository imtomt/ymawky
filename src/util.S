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

.global write_all
.global itoa
.global atoi
.global atoi_n
.global strlen
.global memcpy
.global streqn_i
.global streqn

.bss
// itoa_buf is byte-addressed (strb/ldrb), so no special alignment needed.
itoa_buf: .skip 20

.text
.balign 4 // instructions need 4-byte alignment

// write content to a file descriptor, retrying in case of partial-writes.
// input (same as write() syscall)
// x0 -> file descriptor
// x1 -> buffer
// x2 -> nbytes
//
// output
// x0 -> number of bytes written, total, or -ERRNO on fail
write_all:
    stp x25, x26, [sp, #-16]!
    mov x25, x0 // save x0 into x20
    mov x26, #0
    mov x0, #0
1:
    cbz x2, 2f

    mov x8, SYS_write
    mov x0, x25
    // x1 is set by caller
    // x2 is also set by caller
    svc #0
    b_err Lwrite_fail

    sub x2, x2, x0 // subtract written bytes
    add x26, x26, x0 // increment total bytes written
    add x1, x1, x0 // increment pointer
    b 1b

2:
    mov x0, x26 // return total bytes written

3:
    ldp x25, x26, [sp], #16
    ret

Lwrite_fail:
    cnb eq, x0, #EINTR, 1b

    // x0 is already errno
    b 3b


// convert integer into non-NULL-terminated string.
// input
// x0 -> number to convert
//
// returns
// x0 -> pointer to start of string
// x1 -> length of string
//
// clobbers x0, x1, x2, x3, x4, x5
itoa:
    adr_l x1, itoa_buf
    add x1, x1, #20 // Start at the END of the buffer and write backwards
    mov x2, #0      // length counter
    mov x3, #10     // divisor
1:
    udiv x4, x0, x3     // x4 = x0 / 10
    msub x5, x4, x3, x0 // x5 = x0 - (x4 * x10) = remainder
    add x5, x5, #'0'    // converts to ascii
    sub x1, x1, #1      // move pointer back
    strb w5, [x1]       // stores the digit
    add x2, x2, #1      // length++
    mov x0, x4          // quotient becomes new number
    cbnz x0, 1b         // jump back to 1 if not 0

    mov x0, x1 // x0 = pointer to start
    mov x1, x2 // x1 = length
    ret


// convert NULL-terminated string to integer
// input
// x0 -> pointer to string
//
// returns
// x0 -> integer representation of string
atoi:
    mov x1, #0
    mov x3, #10
    mov x4, #0
1:
    // bounds check so we don't try to atoi a massive integer and overflow the
    // register.
    cmp x4, #19
    b.hs Latoi_error

    ldrb w2, [x0]
    cbz w2, 2f

    // make sure we actually have a number
    cmp w2, #'0'
    b.lo Latoi_error
    cmp w2, #'9'
    b.hi Latoi_error

    mul x1, x1, x3
    sub w2, w2, #'0'
    add x1, x1, x2
    add x0, x0, #1
    add x4, x4, #1 // increment counter for bounds check

    b 1b
2:
    mov x0, x1
    ret

Latoi_error:
    mov x0, #-1
    ret


// convert string representation of number into an integer. read up to N bytes
// from string, does not need to be NULL terminated.
// input
// x0 -> pointer to string
// x1 -> length of string
//
// returns
// x0 -> integer representation of string
atoi_n:
    // try to protect against overflowers. a 19+ digit number will overflow
    // the register.
    cmp x1, #19
    b.hs Latoi_n_error

    mov x2, #0
    mov x4, #10
2:
    cbz x1, 3f

    ldrb w3, [x0]

    // make sure we actually have a number
    cmp w3, #'0'
    b.lo Latoi_n_error
    cmp w3, #'9'
    b.hi Latoi_n_error

    mul x2, x2, x4
    sub w3, w3, #'0'
    add x2, x2, x3
    add x0, x0, #1

    sub x1, x1, #1
    b 2b
3:
    mov x0, x2
    ret

Latoi_n_error:
    mov x0, #-1
    ret


// copies N bytes from x1 into x0
// input
// x0 -> destination
// x1 -> source
// x2 -> length
//
// clobbers x0, x1, and x3
memcpy:
    cbz x2, 1f

    ldrb w3, [x1], #1
    strb w3, [x0], #1

    sub x2, x2, #1
    b memcpy

1:
    ret


// gets the length of a NULL-terminated string.
// input
// x1 -> string whose length to check
//
// return
// x0 -> length of string
strlen:
    mov x0, #0
1:
    ldrb w3, [x1, x0]
    cbz w3, 2f
    add x0, x0, #1
    b 1b

2:
    ret


// case insensitive streqn
// input
// x0 -> str1
// x1 -> str2
// x2 -> max length
//
// returns
// x0 -> 1 if match, 0 if doesn't match
streqn_i:
    cbz x2, Lstreqn_i_match
1:
    // load bytes
    ldrb w3, [x0]
    ldrb w4, [x1]

    cmp w3, #0
    ccmp w4, #0, #0, eq  // if w3 == NULL, check if w4 is also NULL
    b.eq Lstreqn_i_match // if they're both NULL, it's a match!
    // if we're here, they're not *both* NULL. but if *ONE* is NULL, we should
    // exit - not a match :(
    cbz w3, Lstreqn_i_no_match
    cbz w4, Lstreqn_i_no_match

    // make them both lowercase by OR'ing with 0x20, doesn't affect other
    // characters than alphabetical.
    orr w3, w3, #0x20
    orr w4, w4, #0x20
    cmp w3, w4
    b.ne Lstreqn_i_no_match

    // if we've reached the end, it's a match yeah? fuck yeah.
    subs x2, x2, #1
    b.eq Lstreqn_i_match

    add x0, x0, #1
    add x1, x1, #1
    b 1b

Lstreqn_i_match:
    mov x0, #1
    ret

Lstreqn_i_no_match:
    mov x0, #0
    ret


// input
// x0 -> str1
// x1 -> str2
// x2 -> max length
//
// returns
// x0 -> 1 if match, 0 if doesn't match
streqn:
    ldrb w3, [x0]
    ldrb w4, [x1]
    cmp w3, w4
    b.ne Lstreqn_no_match

    cbz w3, Lstreqn_match // both equal and both NULL = end of string = match

    // if we've reached the end, it's a match yeah?
    subs x2, x2, #1
    b.eq Lstreqn_match

    add x0, x0, #1
    add x1, x1, #1
    b streqn

Lstreqn_match:
    mov x0, #1
    ret

Lstreqn_no_match:
    mov x0, #0
    ret
