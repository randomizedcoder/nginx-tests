#!/usr/bin/perl

# (C) Dave Seddon

# Tests for http proxy cache, millisecond freshness: requests that wait on
# proxy_cache_lock in a worker process other than the one that fetches.
# Nothing wakes them, so they look again on a timer: every 500 ms in stock
# nginx, and with proxy_cache_fine_time after 5 ms, then doubling.

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

# Four worker processes share the listening port with reuseport, so the
# sixteen requests of a row are spread over them and most wait in a worker
# that is not fetching.  The origin answers after "delay" milliseconds.
#
# expected: origins is the number of different origin responses the
# clients received; faster and slower bound the time in milliseconds until
# the last response.  A waiter in another worker looks again at 5, 15, 35,
# 75, 155 and 315 ms with fine time, and at 500 ms without.

my @cases = (
    { description => 'fine time, waiters in other workers, 100 ms fetch',
      tags => ['10:positive'],
      uri => '/fine/a', delay => 100, clients => 16,
      expected => { origins => 1, faster => 450 } },
    { description => 'fine time, waiters in other workers, 20 ms fetch',
      tags => ['10:boundary'],
      uri => '/fine/b', delay => 20, clients => 16,
      expected => { origins => 1, faster => 450 } },
    { description => 'stock location, waiters in other workers',
      tags => ['10:negative'],
      uri => '/stock/c', delay => 100, clients => 16,
      expected => { origins => 1, slower => 450 } },
    { description => 'fine time without the lock, every request fetches',
      tags => ['10:corner'],
      uri => '/nolock/d', delay => 20, clients => 4,
      expected => { origins => 4 } },
);

my $t = Test::Nginx->new()->has(qw/http proxy cache/);

plan(skip_all => 'no reuseport') if $^O ne 'linux';

$t->write_file_expand('nginx.conf', <<'CONF');
%%TEST_GLOBALS%%
daemon off;
worker_processes 4;
events {}
http {
    %%TEST_GLOBALS_HTTP%%
    proxy_cache_path %%TESTDIR%%/cache keys_zone=fine:1m;
    proxy_cache_path %%TESTDIR%%/stock keys_zone=stock:1m;

    server {
        listen 127.0.0.1:8080 reuseport;

        location /fine/ {
            proxy_pass http://127.0.0.1:8081;
            proxy_cache fine;
            proxy_cache_fine_time origin;
            proxy_cache_lock on;
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

    note("$case->{uri}: $elapsed ms, responses " . join(',', sort keys %seen));

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
            : $path =~ m{^/window/} ? 'max-age=0, max-age-ms=50, '
                . 'stale-while-revalidate=1, stale-while-revalidate-ms=1000'
            : $path =~ m{^/short/} ? 'max-age=0, max-age-ms=50'
            : 'max-age=0, max-age-ms=2000';

        my $body = "request $n";
        my $status = $path =~ m{/fail$} ? '502 Bad Gateway' : '200 OK';
        print $client "HTTP/1.1 $status\x0d\x0a"
            . "Cache-Control: $policy\x0d\x0a"
            . "Content-Length: " . length($body) . "\x0d\x0a"
            . "Connection: close\x0d\x0a\x0d\x0a$body";
        close $client;
    }
}

###############################################################################
