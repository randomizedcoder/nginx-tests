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
# absent has the value undef.
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

$t->try_run('no proxy_cache_fine_age_header')->plan(4 * @cases + 8);

###############################################################################

for my $case (@cases) {
    my $response = http_get($case->{uri});
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

# The time the cache was not running is unaccounted for.  The stored entry
# is refused, and the variable says why.

$t->stop();
$t->run();

$response = http_get('/on/b');

is(field($response, 'X-Cache'), 'EXPIRED', 'entry refused after a restart');
is(field($response, 'X-Fine'), 'clock', 'refusal is reported as clock');
is(field(http_get('/on/b'), 'X-Fine'), 'used',
    'refetched entry uses fine age');

###############################################################################
