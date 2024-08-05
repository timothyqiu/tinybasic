# Tiny BASIC interpreter in Zig

A simple [Tiny BASIC](https://en.wikipedia.org/wiki/Tiny_BASIC) interpreter in Zig 0.13.0.

Implemented most [grammar](https://archive.org/details/dr_dobbs_journal_vol_01/page/n9/mode/2up) except for keywords `CLEAR`, `LIST`, and `RUN`.

- Added support for lower case characters in string literals.
- Added `REM` statement for comments.
- Added functions `ABS(N)`, `RND(N)`, and `MOD(N,D)`.

## Usage

Build with `zig build`.

Example programs can be found in the `examples` folder.

```
$ cat examples/hello.bas
PRINT "HELLO WORLD!"
$ ./zig-out/bin/tinybasic examples/hello.bas
HELLO WORLD!
```
