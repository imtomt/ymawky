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

.global file_des
.global buf
.global header_len
.global clientfd
.global filename_str
.global filename_len
.global docroot_len
.global query_str
.global query_len
.global request_id

.data
file_des:     .quad -1 // file descriptor for GET/HEAD and stuff. should be
                       // initialized to -1 so we can check if it's set.
.bss
// + 1 so we can NULL terminate, even if content is BUF_SIZE bytes long
buf:          .skip BUF_SIZE + 1
.balign 8 // + 1 breaks alignment
header_len:   .skip 8
clientfd:     .skip 8
filename_str: .skip 8
filename_len: .skip 8
query_str:    .skip 8
query_len:    .skip 8
docroot_len:  .skip 8
request_id:   .skip 8
