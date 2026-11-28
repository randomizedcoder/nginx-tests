#!/usr/bin/perl

# (C) Dave Seddon

# Tests for http proxy cache, millisecond freshness: an entry stored with
# fine time and read by a location without it, as after
# proxy_cache_fine_time is turned off.  The entry is used in whole seconds,
# never past its millisecond deadline, and a 304 rewrites it in the
# whole-second format.

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

# Two locations share a cache zone and key: "fine" has
# proxy_cache_fine_time and "stock" does not.  Each row stores a document
# through the "fill" location, waits, and sends one request through each
# location in "requests", in order.
#
# Documents: "long" has a 60 s lifetime, "mid" 1500 ms with a base of 1 s,
# and "short" 200 ms with a base of 0.
#
# expected: cache is the status of each request, and origin the number of
# origin requests each one causes.

my @cases = (
    { description => 'fine entry is reused without fine time',
      tags => ['17:positive'],
      doc => 'long', fill => 'fine', wait => 0,
      requests => ['stock', 'stock', 'fine'],
      expected => { cache => ['HIT', 'HIT', 'HIT'], origin => [0, 0, 0] } },
    { description => 'fine entry past its deadline is not reused',
      tags => ['17:negative'],
      doc => 'mid', fill => 'fine', wait => 1.6,
      requests => ['stock'],
      expected => { cache => ['REVALIDATED'], origin => [1] } },
    { description => 'sub-second entry past its deadline is not reused',
      tags => ['17:boundary'],
      doc => 'short', fill => 'fine', wait => 0.25,
      requests => ['stock'],
      expected => { cache => ['REVALIDATED'], origin => [1] } },
    { description => 'a 304 without fine time rewrites the entry',
      tags => ['17:corner'],
      doc => 'mid', fill => 'fine', wait => 1.6,
      requests => ['stock', 'stock', 'fine'],
      expected => { cache => ['REVALIDATED', 'HIT', 'HIT'],
                    origin => [1, 0, 0] } },
    { description => 'whole-second entry is reused with fine time',
      tags => ['17:corner'],
      doc => 'long', fill => 'stock', wait => 0,
      requests => ['fine', 'stock'],
      expected => { cache => ['HIT', 'HIT'], origin => [0, 0] } },
    { description => 'fine entry within its lifetime, read both ways',
      tags => ['17:corner'],
      doc => 'long', fill => 'fine', wait => 1.1,
      requests => ['fine', 'stock', 'fine'],
      expected => { cache => ['HIT', 'HIT', 'HIT'], origin => [0, 0, 0] } },
);

my $t = Test::Nginx->new()->has(qw/http proxy cache/);

$t->write_file_expand('nginx.conf', <<'CONF');
%%TEST_GLOBALS%%
daemon off;
events {}
http {
    %%TEST_GLOBALS_HTTP%%
    proxy_cache_path %%TESTDIR%%/cache keys_zone=one:1m;
    proxy_cache one;
    proxy_cache_key $arg_k;
    proxy_cache_revalidate on;
    add_header X-Cache $upstream_cache_status always;

    server {
        listen 127.0.0.1:8080;

        location /fine/ {
            proxy_pass http://127.0.0.1:8081/;
            proxy_cache_fine_time origin;
        }

        location /stock/ {
            proxy_pass http://127.0.0.1:8081/;
        }
    }
}
CONF

my $log = $t->testdir() . '/origin.log';
my $requests = 0;
$requests += @{ $_->{requests} } for @cases;

$t->run_daemon(\&origin, $log);
$t->try_run('no proxy_cache_fine_time')->plan(@cases + 2 * $requests);
$t->waitforsocket('127.0.0.1:' . port(8081));

###############################################################################

sub cache { $_[0] =~ /^X-Cache: (\w+)/mi ? $1 : 'none' }

sub origins {
    open my $in, '<', $log or return 0;
    my @lines = <$in>;
    return scalar @lines;
}

my $key = 0;

for my $case (@cases) {
    my $expected = $case->{expected};
    my $query = "$case->{doc}?k=" . ++$key;

    is(cache(http_get("/$case->{fill}/$query")), 'MISS',
        "$case->{description}: fill");
    sleep $case->{wait};

    for my $i (0 .. $#{ $case->{requests} }) {
        my $location = $case->{requests}[$i];
        my $before = origins();
        my $response = http_get("/$location/$query");

        is(cache($response), $expected->{cache}[$i],
            "$case->{description}: request $i, $location");
        is(origins() - $before, $expected->{origin}[$i],
            "$case->{description}: request $i, origin requests");
    }
}

###############################################################################

sub origin {
    my ($log) = @_;

    my %policy = (
        long => 'max-age=60, max-age-ms=60000',
        mid => 'max-age=1, max-age-ms=1500',
        short => 'max-age=0, max-age-ms=200',
    );

    my $server = IO::Socket::INET->new(
        Proto => 'tcp',
        LocalAddr => '127.0.0.1:' . port(8081),
        Listen => 16,
        Reuse => 1
    )
        or die "Can't create listening socket: $!\n";

    while (my $client = $server->accept()) {
        $client->autoflush(1);

        my ($doc, $conditional) = ('', 0);
        while (<$client>) {
            $doc = $1 if m{^GET /(\w+)};
            $conditional = 1 if /^If-None-Match:/i;
            last if /^\x0d?\x0a?$/;
        }
        next unless $doc;

        open my $out, '>>', $log or die "Can't write $log: $!\n";
        print $out "$doc\n";
        close $out;

        my $fields = "Cache-Control: $policy{$doc}\x0d\x0a"
            . "ETag: \"v1\"\x0d\x0a";

        if ($conditional) {
            print $client "HTTP/1.1 304 Not Modified\x0d\x0a" . $fields
                . "Connection: close\x0d\x0a\x0d\x0a";

        } else {
            my $body = 'manifest';
            print $client "HTTP/1.1 200 OK\x0d\x0a" . $fields
                . "Content-Length: " . length($body) . "\x0d\x0a"
                . "Connection: close\x0d\x0a\x0d\x0a$body";
        }
        close $client;
    }
}

###############################################################################
