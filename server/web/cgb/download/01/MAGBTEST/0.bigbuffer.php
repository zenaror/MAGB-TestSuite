<?php
// SPDX-License-Identifier: MIT
// MAGB TestSuite fixture: the "BIG BUFFER" download.
//
// 8192 bytes of body[i] == i & 0xFF, with the 16-bit additive sum over
// the body in X-Test-Checksum. That sum is F000 and is derivable by
// hand: the body is 32 complete 0..255 ramps, and
// 32 * (255*256/2) = 1044480, which is 0xF000 mod 65536. If this ever
// serves anything else, that number is the first thing to check.
//
// Reached as /cgb/download?name=/01/MAGBTEST/0.bigbuffer.cgb -- the
// .cgb -> .php fallback lives in core.php. See ../../../../README.md.
$size = 8192;
$buffer = '';
$checksum = 0;
for ($i = 0; $i < $size; $i++) {
    $byte = $i & 0xFF;
    $buffer .= chr($byte);
    $checksum = ($checksum + $byte) & 0xFFFF;
}
header('Content-Type: application/octet-stream');
header(sprintf('X-Test-Checksum: %04X', $checksum));
echo $buffer;
