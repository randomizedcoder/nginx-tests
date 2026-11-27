#!/usr/bin/perl

# (C) Dave Seddon

# Tests for http proxy cache, millisecond freshness with a coarse cached
# clock.  With timer_resolution, nginx updates its cached time only once per
# interval.  A fine entry must still not be reused past its lifetime, and
# the age reported must not be less than the time that has passed.

###############################################################################

use warnings;
use strict;

use Test::More;

use IO::Socket::INET;
use Time::HiRes qw/ time sleep /;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

# The cached clock is updated every 100 ms.  Each row polls one document for
# 1.5 seconds.  hits is whether any response is expected from the cache.

my @cases = (
    { description => 'lifetime of zero',
      tags => ['1:boundary'],
      lifetime => 0, expected => { hits => 0 } },
    { description => 'lifetime of one millisecond',
      tags => ['1:negative'],
      lifetime => 1, expected => { hits => 0 } },
    { description => 'lifetime below the timer resolution',
      tags => ['1:corner'],
      lifetime => 50, expected => { hits => 1 } },
    { description => 'lifetime equal to the timer resolution',
      tags => ['1:boundary'],
      lifetime => 100, expected => { hits => 1 } },
    { description => 'lifetime above the timer resolution',
      tags => ['1:positive'],
      lifetime => 250, expected => { hits => 1 } },
    { description => 'lifetime across a second boundary',
      tags => ['1:corner'],
      lifetime => 1100, expected => { hits => 1 } },
);

# The origin time is read with a different clock call from nginx, and the
# request delay is counted in whole milliseconds at both ends.

my $slack = 2;

my $t = Test::Nginx->new()->has(qw/http proxy cache/);

$t->write_file_expand('nginx.conf', <<'CONF');
%%TEST_GLOBALS%%
daemon off;
timer_resolution 100ms;
events {}
http {
    %%TEST_GLOBALS_HTTP%%
    proxy_cache_path %%TESTDIR%%/cache keys_zone=fine:1m;
    server {
        listen 127.0.0.1:8080;
        location / {
            proxy_pass http://127.0.0.1:8081;
            proxy_cache fine;
            proxy_cache_fine_time origin;
            proxy_cache_fine_age_header on;
            add_header X-Cache $upstream_cache_status;
        }
    }
}
CONF

$t->run_daemon(\&origin, port(8081));
$t->try_run('no proxy_cache_fine_age_header')->plan(4 * @cases);
$t->waitforsocket('127.0.0.1:' . port(8081));

###############################################################################

for my $case (@cases) {
    my $lifetime = $case->{lifetime};
    my ($hits, $late, $understated, $unpaired) = (0, 0, 0, 0);
    my $stop = time() + 1.5;

    while (time() < $stop) {
        my $sent = time();
        my $response = http_get("/$lifetime");

        my ($created) = $response =~ /^X-Origin-Time: ([\d.]+)/mi;
        my ($age) = $response =~ /^Age: (\d+)\r?$/mi;
        my ($fine) = $response =~ /^Age-Ms: (\d+)\r?$/mi;
        my ($status) = $response =~ /^X-Cache: (\w+)/mi;

        if (!defined $created || !defined $age || !defined $fine) {
            $unpaired++;
            next;
        }

        # The request was sent before nginx decided, so the response was
        # at least this old when it was chosen and when its age was written.
        my $elapsed = int(($sent - $created) * 1000);

        if ($status eq 'HIT') {
            $hits++;
            $late++ if $elapsed >= $lifetime + $slack;
        }

        $understated++ if $fine < $elapsed - $slack;
        $unpaired++ if $age != int($fine / 1000);

        sleep 0.004;
    }

    is($hits > 0 ? 1 : 0, $case->{expected}{hits}, "$case->{description}: "
        . ($case->{expected}{hits} ? 'reused' : 'never reused'));
    is($late, 0, "$case->{description}: never reused past the lifetime");
    is($understated, 0, "$case->{description}: age is not understated");
    is($unpaired, 0, "$case->{description}: Age is Age-Ms in whole seconds");
}

###############################################################################

# Each response states when it was created.  The lifetime is the URI.

sub origin {
    my ($port) = @_;

    my $server = IO::Socket::INET->new(
        Proto => 'tcp',
        LocalAddr => "127.0.0.1:$port",
        Listen => 16,
        Reuse => 1
    )
        or die "Can't create listening socket: $!\n";

    local $SIG{PIPE} = 'IGNORE';

    while (my $client = $server->accept()) {
        $client->autoflush(1);

        my $uri = '';

        while (<$client>) {
            $uri = $1 if m{^GET /(\d+)};
            last if /^\x0d?\x0a?$/;
        }

        my $now = sprintf '%.6f', time();

        print $client "HTTP/1.1 200 OK\r\n"
            . "Connection: close\r\n"
            . "Cache-Control: max-age=0, max-age-ms=$uri\r\n"
            . "X-Origin-Time: $now\r\n"
            . "Content-Length: 8\r\n\r\nmanifest";

        close $client;
    }
}

###############################################################################
