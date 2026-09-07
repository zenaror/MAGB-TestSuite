<?php
// SPDX-License-Identifier: MIT
// MAGB TestSuite fixture: the "SMALL BUFFER" download AND upload.
//
// One URL, two legs, both under doAuth(2) ("utility" auth):
//
//   GET   128 bytes of body[i] == i & 0xFF, X-Test-Checksum 1FC0
//   POST  the same pattern back, verified the same way, answered with
//         0x01 / 0x00 -- to THIS url, not /cgb/upload
//
// The POST reuses the Authorization from the GET with no second
// challenge, which is the whole point of this fixture: auth.php caches
// utility_authed_user_id for 15 minutes precisely so the official
// client can do that, and nothing else in the TestSuite exercises it.
// Contrast with the big buffer, which goes through type-0 auth and its
// three-request Gb-Auth-ID handshake.
//
// X-Test-User reports the user utility auth resolved. The ROMs fail on
// a 0 there even when the body is correct -- otherwise an endpoint that
// stopped enforcing auth would still pass, which is the one thing this
// test must not do.
//
// REQUIRES the download.php $skipCostAuth change described in
// ../../../../README.md. Without it this script is never reached.

// Guarded: download.php defines CORE_PATH before including us, and
// redefining a constant is a warning today and an error in PHP 9.
if (!defined('CORE_PATH')) {
    define('CORE_PATH', dirname(dirname(dirname(dirname(__DIR__)))) . '/cgb');
}
require_once(CORE_PATH . '/auth.php');

$userId = doAuth(2);
$size = 128;

function magbtestChecksum($bytes) {
    $sum = 0;
    $len = strlen($bytes);
    for ($i = 0; $i < $len; $i++) {
        $sum = ($sum + ord($bytes[$i])) & 0xFFFF;
    }
    return $sum;
}

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $body = file_get_contents('php://input');
    $expected = sprintf('%04X', magbtestChecksum($body));
    // strtoupper() is required -- see the big buffer upload fixture.
    $client = isset($_SERVER['HTTP_X_TEST_CHECKSUM'])
        ? strtoupper(trim($_SERVER['HTTP_X_TEST_CHECKSUM'])) : null;
    header_remove();
    header('Content-Type: application/octet-stream');
    header('X-Test-Checksum: ' . $expected);
    header('X-Test-User: ' . (int)$userId);
    echo ($client === $expected) ? "\x01" : "\x00";
    return;
}

$buffer = '';
for ($i = 0; $i < $size; $i++) {
    $buffer .= chr($i & 0xFF);
}
header_remove();
header('Content-Type: application/octet-stream');
header(sprintf('X-Test-Checksum: %04X', magbtestChecksum($buffer)));
header('X-Test-User: ' . (int)$userId);
echo $buffer;
