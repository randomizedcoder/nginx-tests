#!/usr/bin/perl

# (C) Dave Seddon

# Tests for http proxy cache, millisecond freshness: stale-if-error-ms,
# request max-age-ms and min-fresh-ms with proxy_cache_fine_request,
# and the upstream_cache_ttl variables.

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

my $short = 'max-age=0, max-age-ms=100';

# Each entry is 500 ms old when the origin starts to fail.
my @errors = (
    { description => 'companion opens a window the base denies',
      policy => "$short, stale-if-error=0, stale-if-error-ms=60000",
      expected => 'STALE' },
    { description => 'companion closes a window the base allows',
      policy => "$short, stale-if-error=60, stale-if-error-ms=100",
      expected => '502' },
    { description => 'window ends exactly at the lifetime',
      policy => "$short, stale-if-error=60, stale-if-error-ms=0",
      expected => '502' },
    { description => 'invalid companion falls back to seconds',
      policy => "$short, stale-if-error=60, stale-if-error-ms=1e3",
      expected => 'STALE' },
    { description => 'repeated companion falls back to seconds',
      policy => "$short, stale-if-error=60, stale-if-error-ms=1, "
                . 'stale-if-error-ms=1',
      expected => 'STALE' },
    { description => 'unpaired companion is ignored',
      policy => "$short, stale-if-error-ms=60000",
      expected => '502' },
    { description => 'error pair alone gives a fine entry',
      policy => 'max-age=0, stale-if-error=60, stale-if-error-ms=100',
      expected => '502' },
    { description => 'must-revalidate forbids stale reuse',
      policy => "$short, must-revalidate, stale-if-error=0, "
                . 'stale-if-error-ms=60000',
      expected => '502' },
    { description => 'no error window',
      policy => $short,
      expected => '502' },
);

# Each entry has a 60000 ms lifetime and is at least 300 ms old.
my @requests = (
    { description => 'no request directives',
      lines => [], expected => { cache => 'HIT', origin => 0 } },
    { description => 'limit above the age',
      lines => ['max-age=60, max-age-ms=60000'], expected => { cache => 'HIT', origin => 0 } },
    { description => 'companion tightens the base',
      lines => ['max-age=60, max-age-ms=100'], expected => { cache => 'EXPIRED', origin => 1 } },
    { description => 'companion relaxes the base',
      lines => ['max-age=0, max-age-ms=60000'], expected => { cache => 'HIT', origin => 0 } },
    { description => 'base alone, in milliseconds',
      lines => ['max-age=0'], expected => { cache => 'EXPIRED', origin => 1 } },
    { description => 'invalid companion falls back to a base that passes',
      lines => ['max-age=60, max-age-ms=0.1'], expected => { cache => 'HIT', origin => 0 } },
    { description => 'invalid companion falls back to a base that fails',
      lines => ['max-age=0, max-age-ms=-1'], expected => { cache => 'EXPIRED', origin => 1 } },
    { description => 'oversized companion falls back to the base',
      lines => ['max-age=60, max-age-ms=9999999999999999'],
      expected => { cache => 'HIT', origin => 0 } },
    { description => 'repeated companion falls back to the base',
      lines => ['max-age=60, max-age-ms=1, max-age-ms=1'],
      expected => { cache => 'HIT', origin => 0 } },
    { description => 'unpaired companion is ignored',
      lines => ['max-age-ms=100'], expected => { cache => 'HIT', origin => 0 } },
    { description => 'names are case-insensitive',
      lines => ['MAX-AGE=60, Max-Age-Ms=100'], expected => { cache => 'EXPIRED', origin => 1 } },
    { description => 'pair split across field lines',
      lines => ['max-age-ms=100', 'max-age=60'], expected => { cache => 'EXPIRED', origin => 1 } },
    { description => 'directive inside a quoted string',
      lines => ['ext="a,max-age=0"'], expected => { cache => 'HIT', origin => 0 } },
    { description => 'unterminated quoted string',
      lines => ['max-age=0, ext="a'], expected => { cache => 'HIT', origin => 0 } },
    { description => 'min-fresh below the remaining lifetime',
      lines => ['min-fresh=0, min-fresh-ms=1000'], expected => { cache => 'HIT', origin => 0 } },
    { description => 'min-fresh companion above the remaining lifetime',
      lines => ['min-fresh=0, min-fresh-ms=59900'], expected => { cache => 'EXPIRED', origin => 1 } },
    { description => 'min-fresh base alone above the lifetime',
      lines => ['min-fresh=61'], expected => { cache => 'EXPIRED', origin => 1 } },
    { description => 'unpaired min-fresh companion is ignored',
      lines => ['min-fresh-ms=59900'], expected => { cache => 'HIT', origin => 0 } },
    { description => 'max-age passes, min-fresh fails',
      lines => ['max-age=60, min-fresh=0, min-fresh-ms=59900'],
      expected => { cache => 'EXPIRED', origin => 1 } },
    { description => 'request directives disabled',
      prefix => 'off', lines => ['max-age=0, max-age-ms=0'],
      expected => { cache => 'HIT', origin => 0 } },
    { description => 'whole-second entry is left to stock behaviour',
      prefix => 'coarse', lines => ['max-age=0, max-age-ms=0'],
      expected => { cache => 'HIT', origin => 0 } },
    { description => 'location without fine time ignores max-age=0',
      prefix => 'stock', lines => ['max-age=0'],
      expected => { cache => 'HIT', origin => 0 } },
    { description => 'location without fine time ignores min-fresh',
      prefix => 'stock',
      lines => ['min-fresh=999999, min-fresh-ms=999999999999'],
      expected => { cache => 'HIT', origin => 0 } },
    { description => 'min-fresh that no response can meet',
      lines => ['min-fresh=999999, min-fresh-ms=999999999999'],
      expected => { cache => 'EXPIRED', origin => 1 } },
    { description => 'largest max-age companion, fifteen digits',
      lines => ['max-age=0, max-age-ms=999999999999999'],
      expected => { cache => 'HIT', origin => 0 } },
    { description => 'directives disabled, min-fresh that cannot be met',
      prefix => 'off',
      lines => ['min-fresh=999999, min-fresh-ms=999999999999'],
      expected => { cache => 'HIT', origin => 0 } },
);

my @ttl = (
    { description => 'fresh fine entry',
      uri => '/req/ttl', expected => qr{59/59\d\d\d} },
    { description => 'whole-second entry has no ttl',
      uri => '/coarse/ttl', expected => qr{/} },
);

my $t = Test::Nginx->new()->has(qw/http proxy cache rewrite/);

my $locations = '';
for my $i (0 .. $#errors) {
    $locations .= <<"CONF";
location = /sie/$i {
    if (-f %%TESTDIR%%/fail) { return 444; }
    add_header Cache-Control '$errors[$i]{policy}';
    return 200 'manifest';
}
CONF
}

my $config = <<'CONF';
%%TEST_GLOBALS%%
daemon off;
events {}
http {
    %%TEST_GLOBALS_HTTP%%
    proxy_cache_path %%TESTDIR%%/cache keys_zone=fine:1m;
    proxy_cache_path %%TESTDIR%%/stock keys_zone=stock:1m;
    proxy_cache fine;
    proxy_cache_fine_time origin;
    add_header X-Cache $upstream_cache_status;
    add_header X-TTL $upstream_cache_ttl/$upstream_cache_ttl_ms;
    server {
        listen 127.0.0.1:8080;
        location / {
            proxy_pass http://127.0.0.1:8081;
        }
        location /req/ {
            proxy_pass http://127.0.0.1:8081;
            proxy_cache_fine_request on;
        }
        location /coarse/ {
            proxy_pass http://127.0.0.1:8081;
            proxy_cache_fine_request on;
        }
        location /stock/ {
            proxy_pass http://127.0.0.1:8081;
            proxy_cache stock;
            proxy_cache_fine_time off;
        }
    }
    server {
        listen 127.0.0.1:8081;
        access_log %%TESTDIR%%/origin.log;
        add_header X-Cache "";
        add_header X-TTL "";
        location /req/ {
            add_header Cache-Control 'max-age=60, max-age-ms=60000';
            return 200 'manifest';
        }
        location /off/ {
            add_header Cache-Control 'max-age=60, max-age-ms=60000';
            return 200 'manifest';
        }
        location /coarse/ {
            add_header Cache-Control 'max-age=60';
            return 200 'manifest';
        }
        location /stock/ {
            add_header Cache-Control 'max-age=60';
            return 200 'manifest';
        }
        LOCATIONS
    }
}
CONF
$config =~ s/LOCATIONS/$locations/;

sub fetch {
    my ($uri, @lines) = @_;
    my $fields = join '', map { "Cache-Control: $_\r\n" } @lines;
    return http("GET $uri HTTP/1.0\r\nHost: localhost\r\n$fields\r\n");
}

sub outcome {
    my ($response) = @_;
    return $1 if $response =~ /^X-Cache: (\w+)\r?$/mi;
    return $1 if $response =~ m{^HTTP/1\.\d (\d+)};
    return 'none';
}

# Origin requests so far for one URI.  The path is copied, because a named
# sub that used $t would keep the test object alive past its final checks.
my $origin_log = $t->testdir() . '/origin.log';

sub origins {
    my ($uri) = @_;
    open my $log, '<', $origin_log or return 0;
    return scalar grep { m{"GET \Q$uri\E HTTP} } <$log>;
}

$t->write_file_expand('nginx.conf', $config);
$t->try_run('no proxy_cache_fine_request')
    ->plan(2 * @errors + 3 * @requests + 2 * @ttl + 1);

###############################################################################

for my $i (0 .. $#requests) {
    my $case = $requests[$i];
    $case->{uri} = '/' . ($case->{prefix} // 'req') . "/$i";
    is(outcome(fetch($case->{uri})), 'MISS', "$case->{description}: fill");
}
for my $i (0 .. $#errors) {
    is(outcome(fetch("/sie/$i")), 'MISS', "$errors[$i]{description}: fill");
}
for my $case (@ttl) {
    is(outcome(fetch($case->{uri})), 'MISS', "$case->{description}: fill");
}

$t->write_file('fail', '');
sleep 0.5;

for my $case (@requests) {
    my $before = origins($case->{uri});
    is(outcome(fetch($case->{uri}, @{ $case->{lines} })),
       $case->{expected}{cache}, $case->{description});
    is(origins($case->{uri}) - $before, $case->{expected}{origin},
       "$case->{description}: origin requests");
}

my $stale = '';
for my $i (0 .. $#errors) {
    my $response = fetch("/sie/$i");
    $stale = $response if $i == 0;
    is(outcome($response), $errors[$i]{expected}, $errors[$i]{description});
}
like($stale, qr{^X-TTL: -1/-\d\d\d\r?$}mi, 'stale entry has a negative ttl');

for my $case (@ttl) {
    like(fetch($case->{uri}), qr{^X-TTL: $case->{expected}\r?$}mi,
         $case->{description});
}

###############################################################################
