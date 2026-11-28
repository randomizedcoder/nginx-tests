#!/usr/bin/perl

# (C) Dave Seddon

# Tests for http proxy cache, millisecond freshness: which responses carry
# Age-Ms, controlled by proxy_cache_fine_age_header, and the
# upstream_cache_fine_status variable.

###############################################################################

use warnings;
use strict;

use Test::More;

use Time::HiRes qw/ sleep /;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

# Each row is one request.  Rows for the same URI run in order, so a second
# row sees the entry the first one stored.  A field that is expected to be
# absent has the value undef.  "want" is sent as the X-Want request field,
# which the /var/ location uses for proxy_cache_fine_age_header.
#
# The cache key is the proxied URI, so each scenario uses its own document.

my $ms = qr/^\d{1,3}$/;

my @cases = (
    { description => 'Age-Ms is withheld by default, new entry',
      tags => ['6:negative'],
      uri => '/default/a',
      expected => { cache => 'MISS', fine => 'used',
                    age => qr/^0$/, age_ms => undef } },
    { description => 'Age-Ms is withheld by default, stored entry',
      tags => ['6:negative'],
      uri => '/default/a',
      expected => { cache => 'HIT', fine => 'used',
                    age => qr/^0$/, age_ms => undef } },
    { description => 'Age-Ms is sent when enabled, new entry',
      tags => ['6:positive'],
      uri => '/on/b',
      expected => { cache => 'MISS', fine => 'used',
                    age => qr/^0$/, age_ms => $ms } },
    { description => 'Age-Ms is sent when enabled, stored entry',
      tags => ['6:positive'],
      uri => '/on/b',
      expected => { cache => 'HIT', fine => 'used',
                    age => qr/^0$/, age_ms => $ms } },
    { description => 'proxy_hide_header removes an enabled Age-Ms',
      tags => ['6:corner'],
      uri => '/hidden/c',
      expected => { cache => 'MISS', fine => 'used',
                    age => qr/^0$/, age_ms => undef } },
    { description => 'variable set to 1 sends Age-Ms, new entry',
      tags => ['18:positive'],
      uri => '/var/h', want => '1',
      expected => { cache => 'MISS', fine => 'used',
                    age => qr/^0$/, age_ms => $ms } },
    { description => 'variable empty withholds Age-Ms from the same entry',
      tags => ['18:negative', '18:corner'],
      uri => '/var/h',
      expected => { cache => 'HIT', fine => 'used',
                    age => qr/^0$/, age_ms => undef } },
    { description => 'variable set to 0 withholds Age-Ms',
      tags => ['18:negative'],
      uri => '/var/h', want => '0',
      expected => { cache => 'HIT', fine => 'used',
                    age => qr/^0$/, age_ms => undef } },
    { description => 'variable set to off withholds Age-Ms',
      tags => ['18:negative'],
      uri => '/var/h', want => 'off',
      expected => { cache => 'HIT', fine => 'used',
                    age => qr/^0$/, age_ms => undef } },
    { description => 'variable set to on sends Age-Ms',
      tags => ['18:boundary'],
      uri => '/var/h', want => 'on',
      expected => { cache => 'HIT', fine => 'used',
                    age => qr/^0$/, age_ms => $ms } },
    { description => 'any other value sends Age-Ms',
      tags => ['18:corner'],
      uri => '/var/h', want => 'cache-7',
      expected => { cache => 'HIT', fine => 'used',
                    age => qr/^0$/, age_ms => $ms } },
    { description => 'whole-second response, new entry',
      uri => '/on/coarse',
      expected => { cache => 'MISS', fine => 'coarse',
                    age => undef, age_ms => undef } },
    { description => 'whole-second response, stored entry reports its age',
      tags => ['8:positive'],
      uri => '/on/coarse',
      expected => { cache => 'HIT', fine => 'coarse',
                    age => qr/^[01]$/, age_ms => undef } },
    { description => 'unpaired companion falls back',
      tags => ['9:negative'],
      uri => '/on/unpaired',
      expected => { cache => 'MISS', fine => 'fallback:companion',
                    age => undef, age_ms => undef } },
    { description => 'invalid companion falls back',
      tags => ['9:negative'],
      uri => '/on/invalid',
      expected => { cache => 'MISS', fine => 'fallback:companion',
                    age => undef, age_ms => undef } },
    { description => 'Age from an origin falls back and is forwarded',
      tags => ['9:negative'],
      uri => '/on/aged',
      expected => { cache => 'MISS', fine => 'fallback:age',
                    age => qr/^3$/, age_ms => undef } },
    { description => 'Age-Ms from an origin falls back and is removed',
      uri => '/on/agedms',
      expected => { cache => 'MISS', fine => 'fallback:age',
                    age => qr/^0$/, age_ms => undef } },
    { description => 'X-Accel-Expires falls back',
      tags => ['9:negative'],
      uri => '/on/xae',
      expected => { cache => 'MISS', fine => 'fallback:policy',
                    age => undef, age_ms => undef } },
    { description => 'a 404 with a pair falls back',
      tags => ['9:corner'],
      uri => '/on/missing',
      expected => { cache => 'MISS', fine => 'fallback:policy',
                    age => undef, age_ms => undef } },
    { description => 'private response is not a fallback',
      tags => ['9:corner'],
      uri => '/on/private',
      expected => { cache => 'MISS', fine => 'coarse',
                    age => undef, age_ms => undef } },
    { description => 'fine time off leaves the response alone',
      tags => ['6:corner', '9:boundary'],
      uri => '/off/agedms',
      expected => { cache => 'MISS', fine => undef,
                    age => qr/^0$/, age_ms => qr/^175$/ } },
    { description => 'trusted cache behind a cache that sends Age-Ms',
      tags => ['6:positive', '9:positive'],
      uri => '/viaon/f',
      expected => { cache => 'MISS', fine => 'used',
                    age => qr/^0$/, age_ms => $ms } },
    { description => 'trusted cache behind a cache that withholds Age-Ms',
      tags => ['6:corner', '9:negative'],
      uri => '/viaoff/g',
      expected => { cache => 'MISS', fine => 'fallback:age',
                    age => qr/^0$/, age_ms => undef } },
);

# Each row sends its requests after the start of a new second and counts
# the lines written to the error log for one reason.  A fallback is logged
# at most once a second for each reason; the run can cross into the next
# second, so two lines are allowed.

my @logged = (
    { description => 'one fallback is logged',
      tags => ['12:positive'],
      uris => ['/on/unpaired'], requests => 1,
      reason => 'companion directive is unpaired or invalid',
      expected => { min => 1, max => 1 } },
    { description => 'twenty fallbacks in a second are not all logged',
      tags => ['12:negative'],
      uris => ['/on/unpaired'], requests => 20,
      reason => 'companion directive is unpaired or invalid',
      expected => { min => 1, max => 2 } },
    { description => 'a second reason in the same second has its own line',
      tags => ['12:boundary'],
      uris => ['/on/unpaired', '/on/missing'], requests => 20,
      reason => 'response policy excludes it',
      expected => { min => 1, max => 2 } },
    { description => 'a response with fine age logs nothing',
      tags => ['12:corner'],
      uris => ['/on/b'], requests => 20,
      reason => '',
      expected => { min => 0, max => 0 } },
);

# Each row stores an entry, and the server is then stopped and started.
# "change" is made to the offset kept in the cache file while the server is
# stopped: a number of milliseconds added to it, or "zero" for a file
# written before the offset was kept.

my @restart = (
    { description => 'entry is reused after a restart',
      tags => ['16:positive'],
      uri => '/on/restart/kept', change => undef,
      expected => { cache => 'HIT', fine => 'used' } },
    { description => 'offset 5 ms away is within the limit',
      tags => ['16:boundary'],
      uri => '/on/restart/near', change => 5,
      expected => { cache => 'HIT', fine => 'used' } },
    { description => 'offset 50 ms away is refused',
      tags => ['16:negative'],
      uri => '/on/restart/step', change => 50,
      expected => { cache => 'EXPIRED', fine => 'clock' } },
    { description => 'offset 50 ms behind is refused',
      tags => ['16:negative'],
      uri => '/on/restart/back', change => -50,
      expected => { cache => 'EXPIRED', fine => 'clock' } },
    { description => 'file without an offset is refused',
      tags => ['16:corner'],
      uri => '/on/restart/none', change => 'zero',
      expected => { cache => 'EXPIRED', fine => 'clock' } },
    { description => 'entry past its lifetime at the restart is only expired',
      tags => ['16:corner'],
      uri => '/on/brief', change => undef,
      expected => { cache => 'EXPIRED', fine => 'used' } },
);

my $t = Test::Nginx->new()->has(qw/http proxy cache rewrite/);

$t->write_file_expand('nginx.conf', <<'CONF');
%%TEST_GLOBALS%%
daemon off;
events {}
http {
    %%TEST_GLOBALS_HTTP%%
    proxy_cache_path %%TESTDIR%%/cache keys_zone=fine:1m;
    proxy_cache fine;
    proxy_hide_header X-Cache;
    proxy_hide_header X-Fine;
    add_header X-Cache $upstream_cache_status always;
    add_header X-Fine $upstream_cache_fine_status always;

    server {
        listen 127.0.0.1:8080;

        location /default/ {
            proxy_pass http://127.0.0.1:8081/;
            proxy_cache_fine_time origin;
        }
        location /on/ {
            proxy_pass http://127.0.0.1:8081/;
            proxy_cache_fine_time origin;
            proxy_cache_fine_age_header on;
        }
        location /hidden/ {
            proxy_pass http://127.0.0.1:8081/;
            proxy_cache_fine_time origin;
            proxy_cache_fine_age_header on;
            proxy_hide_header Age-Ms;
        }
        location /var/ {
            proxy_pass http://127.0.0.1:8081/;
            proxy_cache_fine_time origin;
            proxy_cache_fine_age_header $http_x_want;
        }
        location /off/ {
            proxy_pass http://127.0.0.1:8081/;
        }
        location /viaon/ {
            proxy_pass http://127.0.0.1:8080/on/via/;
            proxy_cache_fine_time trusted;
            proxy_cache_fine_age_header on;
        }
        location /viaoff/ {
            proxy_pass http://127.0.0.1:8080/default/via/;
            proxy_cache_fine_time trusted;
            proxy_cache_fine_age_header on;
        }
    }

    server {
        listen 127.0.0.1:8081;

        location / {
            add_header Cache-Control 'max-age=0, max-age-ms=60000';
            return 200 'manifest';
        }
        location = /brief {
            add_header Cache-Control 'max-age=0, max-age-ms=200';
            return 200 'manifest';
        }
        location = /coarse {
            add_header Cache-Control 'max-age=60';
            return 200 'manifest';
        }
        location = /unpaired {
            add_header Cache-Control 'max-age-ms=60000';
            return 200 'manifest';
        }
        location = /invalid {
            add_header Cache-Control 'max-age=0, max-age-ms=0.2';
            return 200 'manifest';
        }
        location = /aged {
            add_header Cache-Control 'max-age=0, max-age-ms=60000';
            add_header Age 3;
            return 200 'manifest';
        }
        location = /agedms {
            add_header Cache-Control 'max-age=0, max-age-ms=60000';
            add_header Age 0;
            add_header Age-Ms 175;
            return 200 'manifest';
        }
        location = /xae {
            add_header Cache-Control 'max-age=0, max-age-ms=60000';
            add_header X-Accel-Expires 60;
            return 200 'manifest';
        }
        location = /missing {
            add_header Cache-Control 'max-age=0, max-age-ms=60000' always;
            return 404;
        }
        location = /private {
            add_header Cache-Control 'private, max-age=0, max-age-ms=60000';
            return 200 'manifest';
        }
    }
}
CONF

sub field {
    my ($response, $name) = @_;
    return $response =~ /^\Q$name\E: (.*?)\r?$/mi ? $1 : undef;
}

sub check {
    my ($response, $name, $expected, $description) = @_;
    my $value = field($response, $name);

    if (!defined $expected) {
        is($value, undef, "$description: no $name");

    } elsif (ref $expected) {
        like($value // '(absent)', $expected, "$description: $name");

    } else {
        is($value, $expected, "$description: $name");
    }
}

my $error_log = $t->testdir() . '/error.log';

sub log_lines {
    my ($reason) = @_;
    open my $in, '<', $error_log or return 0;
    return scalar grep { /fine cache time not used: \Q$reason\E/ } <$in>;
}

# Change the offset kept in the cache file of a URI.  It is the last four
# bytes of the fixed header, which is 336 bytes long.

my $cache_dir = $t->testdir() . '/cache';

sub offset_change {
    my ($uri, $change) = @_;
    my ($name) = $uri =~ m{^/on(/.*)$};

    for my $file (glob("$cache_dir/*")) {
        open my $fh, '+<:raw', $file or die "Open $file: $!";
        read($fh, my $head, 1024);
        next unless $head =~ /\nKEY: \S+\Q$name\E\n/;

        my $offset = unpack('L', substr($head, 332, 4));
        $offset = $change eq 'zero' ? 0 : ($offset + $change) % 2 ** 32;

        seek($fh, 332, 0);
        print $fh pack('L', $offset);
        close $fh;
        return;
    }

    die "No cache file for $uri";
}

$t->try_run('no proxy_cache_fine_age_header')
    ->plan(4 * @cases + 5 + @logged + 3 * @restart);

###############################################################################

for my $case (@cases) {
    my $response = defined $case->{want}
        ? http("GET $case->{uri} HTTP/1.0\nHost: localhost\n"
            . "X-Want: $case->{want}\n\n")
        : http_get($case->{uri});
    my $expected = $case->{expected};

    check($response, 'X-Cache', $expected->{cache}, $case->{description});
    check($response, 'X-Fine', $expected->{fine}, $case->{description});
    check($response, 'Age', $expected->{age}, $case->{description});
    check($response, 'Age-Ms', $expected->{age_ms}, $case->{description});
}

# Age is the floor of the same estimate that Age-Ms reports.

http_get('/on/d');
sleep 1.2;

my $response = http_get('/on/d');
my ($age, $fine) = (field($response, 'Age'), field($response, 'Age-Ms'));

is(field($response, 'X-Cache'), 'HIT', 'entry reused after a second');
cmp_ok($fine // 0, '>=', 1200, 'Age-Ms covers the time stored');
is($age, int(($fine // 0) / 1000), 'Age is Age-Ms in whole seconds');

http_get('/default/e');
sleep 1.2;
$response = http_get('/default/e');

is(field($response, 'Age'), 1, 'Age is still reported without Age-Ms');
is(field($response, 'Age-Ms'), undef, 'Age-Ms stays withheld when stored');

for my $case (@logged) {
    sleep 1.1;
    my $before = log_lines($case->{reason});

    for my $i (1 .. $case->{requests}) {
        http_get($_) for @{ $case->{uris} };
    }

    my $lines = log_lines($case->{reason}) - $before;
    my $expected = $case->{expected};

    ok($lines >= $expected->{min} && $lines <= $expected->{max},
        "$case->{description}: log lines")
        or diag("$lines lines");
}

# The cache file keeps the difference between the wall clock and the
# monotonic clock when the entry was stored.  It is the same after a restart
# of this server, so the entry is reused and its age carries on.  Where it
# differs, as after a clock step or a reboot, the entry is refused.

my %stored;

for my $case (@restart) {
    $stored{$case->{uri}} = Time::HiRes::time();
    http_get($case->{uri});
}

sleep 0.3;
$t->stop();

for my $case (@restart) {
    offset_change($case->{uri}, $case->{change}) if defined $case->{change};
}

$t->run();

for my $case (@restart) {
    my $expected = $case->{expected};
    $response = http_get($case->{uri});
    my $elapsed = int((Time::HiRes::time() - $stored{$case->{uri}}) * 1000);

    check($response, 'X-Cache', $expected->{cache}, $case->{description});
    check($response, 'X-Fine', $expected->{fine}, $case->{description});

    my $age_ms = field($response, 'Age-Ms') // -1;

    if ($expected->{cache} eq 'HIT') {
        ok($age_ms >= 300 && $age_ms <= $elapsed + 20,
            "$case->{description}: age carries on")
            or diag("Age-Ms $age_ms, elapsed $elapsed");

    } else {
        cmp_ok($age_ms, '<', 300, "$case->{description}: age starts again");
    }
}

###############################################################################
