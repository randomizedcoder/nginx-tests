#!/usr/bin/perl

# (C) Dave Seddon

# Tests for http proxy cache, millisecond freshness: requests that wait on
# proxy_cache_lock.  Stock nginx lets a waiting request look again every
# 500 ms, which is longer than a sub-second lifetime.  With
# proxy_cache_fine_time the first look is after 5 ms and the interval
# doubles.

###############################################################################

use warnings;
use strict;

use Test::More;

use IO::Select;
use Time::HiRes qw/ sleep time /;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx qw/ :DEFAULT http_end /;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

# Each row sends several requests for one new URI at the same time.  The
# origin answers after "delay" milliseconds, one request at a time, and
# numbers its responses for each URI.
#
# expected: origins is the number of origin requests; faster and slower
# bound the time in milliseconds until the last response.

my @cases = (
    { description => 'fine time, waiters are answered when the fetch ends',
      tags => ['10:positive'],
      uri => '/fine/a', delay => 100, clients => 5,
      expected => { origins => 1, faster => 400 } },
    { description => 'fine time, a fetch of 250 ms',
      tags => ['10:positive'],
      uri => '/fine/b', delay => 250, clients => 5,
      expected => { origins => 1, faster => 480 } },
    { description => 'stock location still looks again after 500 ms',
      tags => ['10:negative'],
      uri => '/stock/c', delay => 100, clients => 5,
      expected => { origins => 1, slower => 450 } },
    { description => 'fetch ends before the first look',
      tags => ['10:boundary'],
      uri => '/fine/d', delay => 0, clients => 5,
      expected => { origins => 1, faster => 300 } },
    { description => 'fetch ends just after the first look',
      tags => ['10:boundary'],
      uri => '/fine/e', delay => 8, clients => 5,
      expected => { origins => 1, faster => 300 } },
    { description => 'lock timeout still releases a waiter',
      tags => ['10:corner'],
      uri => '/timeout/f', delay => 200, clients => 3,
      expected => { origins => 3 } },
    { description => 'lifetime shorter than the fetch is not collapsed',
      tags => ['10:corner'],
      uri => '/short/g', delay => 100, clients => 3,
      expected => { origins => 3 } },
    { description => 'fine time without the lock',
      tags => ['10:corner'],
      uri => '/nolock/h', delay => 100, clients => 3,
      expected => { origins => 3 } },
);

my $t = Test::Nginx->new()->has(qw/http proxy cache/);

$t->write_file_expand('nginx.conf', <<'CONF');
%%TEST_GLOBALS%%
daemon off;
events {}
http {
    %%TEST_GLOBALS_HTTP%%
    proxy_cache_path %%TESTDIR%%/cache keys_zone=fine:1m;
    proxy_cache_path %%TESTDIR%%/stock keys_zone=stock:1m;

    server {
        listen 127.0.0.1:8080;

        location /fine/ {
            proxy_pass http://127.0.0.1:8081;
            proxy_cache fine;
            proxy_cache_fine_time origin;
            proxy_cache_lock on;
        }

        location /short/ {
            proxy_pass http://127.0.0.1:8081;
            proxy_cache fine;
            proxy_cache_fine_time origin;
            proxy_cache_lock on;
        }

        location /timeout/ {
            proxy_pass http://127.0.0.1:8081;
            proxy_cache fine;
            proxy_cache_fine_time origin;
            proxy_cache_lock on;
            proxy_cache_lock_timeout 50ms;
        }

        location /nolock/ {
            proxy_pass http://127.0.0.1:8081;
            proxy_cache fine;
            proxy_cache_fine_time origin;
        }

        location /stock/ {
            proxy_pass http://127.0.0.1:8081;
            proxy_cache stock;
            proxy_cache_lock on;
        }
    }
}
CONF

$t->run_daemon(\&origin);
$t->try_run('no proxy_cache_fine_time');

my $rows = 0;
$rows += 1 + grep { defined } @{ $_->{expected} }{qw/faster slower/}
    for @cases;
$t->plan($rows);

$t->waitforsocket('127.0.0.1:' . port(8081));

###############################################################################

for my $case (@cases) {
    my $start = time();
    my @sockets = map {
        http_get("$case->{uri}?delay=$case->{delay}", start => 1)
    } 1 .. $case->{clients};

    my %seen;
    for my $socket (@sockets) {
        my $response = http_end($socket);
        $seen{$1} = 1 if $response =~ /request (\d+)/;
    }
    my $elapsed = int((time() - $start) * 1000);
    my $expected = $case->{expected};

    is(scalar keys %seen, $expected->{origins},
        "$case->{description}: origin requests");

    if (defined $expected->{faster}) {
        cmp_ok($elapsed, '<', $expected->{faster},
            "$case->{description}: all answered in time");
    }

    if (defined $expected->{slower}) {
        cmp_ok($elapsed, '>=', $expected->{slower},
            "$case->{description}: a waiter waited for the stock interval");
    }
}

###############################################################################

sub origin {
    my $server = IO::Socket::INET->new(
        Proto => 'tcp',
        LocalAddr => '127.0.0.1:' . port(8081),
        Listen => 16,
        Reuse => 1
    )
        or die "Can't create listening socket: $!\n";

    my %count;

    while (my $client = $server->accept()) {
        $client->autoflush(1);

        my $uri = '';
        while (<$client>) {
            $uri = $1 if /^GET (\S+) HTTP/;
            last if /^\x0d?\x0a?$/;
        }
        next unless $uri;

        my ($path) = $uri =~ m{^([^?]+)};
        my ($delay) = $uri =~ /delay=(\d+)/;
        my $n = ++$count{$path};

        sleep($delay / 1000) if $delay;

        my $policy = $path =~ m{^/stock/} ? 'max-age=2'
            : $path =~ m{^/short/} ? 'max-age=0, max-age-ms=50'
            : 'max-age=0, max-age-ms=2000';

        my $body = "request $n";
        print $client "HTTP/1.1 200 OK\x0d\x0a"
            . "Cache-Control: $policy\x0d\x0a"
            . "Content-Length: " . length($body) . "\x0d\x0a"
            . "Connection: close\x0d\x0a\x0d\x0a$body";
        close $client;
    }
}

###############################################################################
