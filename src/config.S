// Default docroot, relative to ymawky's current working environment.
// Note that this needs the trailing /.
// Default: www/
#define DOCROOT "www/"

// Default directory where CGI scripts will be stored.
// This is inside DOCROOT. Set this to a nonexistent directory if you don't
// want CGI.
// Default: cgi-bin/
#define CGI_DIR "cgi-bin/"

// Directory to search for custom error HTML pages, so a page can be displayed
// on 404 rather than just the browser's boring stuff.
// Note that this needs the trailing /.
// Default: err/
#define ERR_DIR "err/"

// When receiving a "GET /" request with no filename, what file should be GOT?
// Default: index.html
#define DEFAULT_FILE "index.html"

// Maximum size, in bytes, for a response header. Will usually be less.
// Default: 512 bytes
.equ RESPONSE_HEADER_SIZE, 512

// Maximum time, in seconds, without receiving any data before closing the
// connection.
// Default: 10 seconds
.equ RECV_TIMEOUT, 10

// Maximum time, in seconds, to receive the full header before timing out.
// Default: 10 seconds
.equ HEADER_REQ_TIMEOUT_SECS, 10

// The timeout for PUT is calculated by:
// timeout (secs) = PUT_GRACE_SECS + Content-Length / MIN_BPS. So for very small
// files, it will basically just be the grace period.
// How many seconds of grace time should be added to the PUT read timeout?
// Default: 5 seconds
.equ PUT_GRACE_SECS, 5
// What should the minimum number of bytes per second be for the PUT timeout?
// Default: 16KB/s
.equ PUT_MIN_BPS, 1024 * 16

// Maximum file size, in bytes, for PUT to receive.
// Default: 1GB
.equ MAX_BODY_SIZE, 1024 * 1024 * 1024

// Maximum number of active, concurrent processes allowed.
// This is entirely up to you and how many processes your computer can handle.
// Note that currently, proc_info() will fail to recognize greater than 512
// processes. This is because proc_info has to write into a buffer, we gave it
// 2048 bytes. 2048 / 4 = 512 max procs. If you want more, you gotta increase
// the buffer in ymawky.S. I'll leave that as an exercise to the reader.
// Default: 256
.equ MAX_PROCS, 256

// Allow GET /dir to list the directory's contents, or just 403?
// 0: Do not allow directory contents to be listed.
// 1 (or anything non-zero): Yes, allow directory contents to be listed
// Default: 1
.equ ALLOW_DIR_LISTING, 1
