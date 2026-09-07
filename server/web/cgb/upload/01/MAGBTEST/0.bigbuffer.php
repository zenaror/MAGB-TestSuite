<?php
// SPDX-License-Identifier: MIT
// MAGB TestSuite fixture: the "BIG BUFFER" upload.
//
// Recomputes the same 16-bit additive sum over whatever was POSTed and
// compares it against the client's X-Test-Checksum header. Answers with
// a single byte: 0x01 accepted, 0x00 rejected.
//
// It also echoes the checksum IT computed, so a rejection says what the
// server actually received rather than only that it disagreed -- a
// truncated body lands on a recognisably smaller sum. Both ROMs display
// that value next to their own.
//
// strtoupper() on the client header is REQUIRED, not cosmetic: the two
// TestSuite ROMs send different case (see README.md). Dropping it makes
// the GBDK ROM fail and the RGBDS one pass.
$body = file_get_contents('php://input');
$checksum = 0;
$len = strlen($body);
for ($i = 0; $i < $len; $i++) {
    $checksum = ($checksum + ord($body[$i])) & 0xFFFF;
}
$expected = sprintf('%04X', $checksum);
$clientChecksum = isset($_SERVER['HTTP_X_TEST_CHECKSUM'])
    ? strtoupper(trim($_SERVER['HTTP_X_TEST_CHECKSUM'])) : null;
$match = ($clientChecksum === $expected);
header('Content-Type: application/octet-stream');
header('X-Test-Checksum: ' . $expected);
echo $match ? "\x01" : "\x00";
