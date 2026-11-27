#!/usr/bin/perl

# (C) Dave Seddon

# Tests for http proxy cache, millisecond freshness: a stored entry after a
# 304.  Where the 304 leaves the stored header block the same length, the
# entry is updated in place and the next request is served from it.
# Otherwise the entry is retired and the next request fetches it in full.

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

# Each row stores a response with a 200 ms lifetime, waits until it is
# stale, and sends a request that the origin answers with a 304.  "fields"
# are the fields of that 304, where "same" stands for the stored value.
# The stored response has Cache-Control "max-age=0, max-age-ms=200", ETag
# "v1" and a Date ending in 10:00:00.
#
# expected: cache is the status of the next request, origin the number of
# origin requests it causes, date the seconds of the Date it carries ("now"
# for this server's own time), and later the status of a request 400 ms
# after that.

my $policy = 'max-age=0, max-age-ms=200';

my @cases = (
    { description => '304 repeats the stored fields',
      tags => ['11:positive'],
      uri => '/fine/same',
      fields => { cc => $policy, etag => '"v1"', date => '07' },
      expected => { cache => 'HIT', origin => 0, date => '07',
                    later => 'REVALIDATED' } },
    { description => '304 with only a Date',
      tags => ['11:positive'],
      uri => '/fine/dateonly',
      fields => { date => '07' },
      expected => { cache => 'HIT', origin => 0, date => '07',
                    later => 'REVALIDATED' } },
    { description => '304 with a longer Cache-Control retires the entry',
      tags => ['11:negative'],
      uri => '/fine/longer',
      fields => { cc => 'max-age=0, max-age-ms=20000', etag => '"v1"',
                  date => '07' },
      expected => { cache => 'MISS', origin => 1, date => '00',
                    later => 'REVALIDATED' } },
    { description => '304 with a new ETag retires the entry',
      tags => ['11:negative'],
      uri => '/fine/etag',
      fields => { cc => $policy, etag => '"v2-longer"', date => '07' },
      expected => { cache => 'MISS', origin => 1, date => '00',
                    later => 'REVALIDATED' } },
    { description => 'Cache-Control of the same length is applied in place',
      tags => ['11:boundary'],
      uri => '/fine/samelen',
      fields => { cc => 'max-age=0, max-age-ms=900', etag => '"v1"',
                  date => '07' },
      expected => { cache => 'HIT', origin => 0, date => '07',
                    later => 'HIT' } },
    { description => 'Cache-Control one byte shorter retires the entry',
      tags => ['11:boundary'],
      uri => '/fine/shorter',
      fields => { cc => 'max-age=0, max-age-ms=90', etag => '"v1"',
                  date => '07' },
      expected => { cache => 'MISS', origin => 1, date => '00',
                    later => 'REVALIDATED' } },
    { description => 'new ETag of the same length retires the entry',
      tags => ['11:corner'],
      uri => '/fine/etaglen',
      fields => { cc => $policy, etag => '"v2"', date => '07' },
      expected => { cache => 'MISS', origin => 1, date => '00',
                    later => 'REVALIDATED' } },
    { description => '304 without Date or Cache-Control',
      tags => ['11:corner'],
      uri => '/fine/bare',
      fields => { etag => '"v1"' },
      expected => { cache => 'HIT', origin => 0, date => 'now',
                    later => 'REVALIDATED' } },
    { description => '304 that drops fine time retires the entry',
      tags => ['11:corner'],
      uri => '/fine/coarse',
      fields => { cc => 'max-age=0, max-age-xx=200', etag => '"v1"',
                  date => '07' },
      expected => { cache => 'MISS', origin => 1, date => '00',
                    later => 'REVALIDATED' } },
    { description => 'location without fine time, stock behaviour',
      tags => ['11:corner'],
      uri => '/stock/same',
      fields => { cc => 'max-age=1', etag => '"v1"', date => '07' },
      expected => { cache => 'HIT', origin => 0, date => '00',
                    later => 'HIT' } },
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
    proxy_cache_revalidate on;
    proxy_pass_header Date;
    add_header X-Cache $upstream_cache_status always;

    server {
        listen 127.0.0.1:8080;

        location /fine/ {
            proxy_pass http://127.0.0.1:8081;
            proxy_cache fine;
            proxy_cache_fine_time origin;
        }

        location /stock/ {
            proxy_pass http://127.0.0.1:8081;
            proxy_cache stock;
        }
    }
}
CONF

my $log = $t->testdir() . '/origin.log';
my %fields = map { $_->{uri} => $_->{fields} } @cases;

$t->run_daemon(\&origin, $log, \%fields, $policy);
$t->try_run('no proxy_cache_fine_time')->plan(6 * @cases);
$t->waitforsocket('127.0.0.1:' . port(8081));

###############################################################################

sub cache { $_[0] =~ /^X-Cache: (\w+)/mi ? $1 : 'none' }
sub seconds {
    return 'none' unless $_[0] =~ /^Date: (.*)\r?$/mi;
    return $1 =~ /^Thu, 26 Nov 2026 10:00:(\d\d) GMT/ ? $1 : 'now';
}

sub origins {
    my ($uri) = @_;
    open my $in, '<', $log or return 0;
    return scalar grep { /^\Q$uri\E$/ } <$in>;
}

for my $case (@cases) {
    my ($uri, $expected) = @$case{qw/uri expected/};
    my $stale = $uri =~ m{^/stock/} ? 2.1 : 0.25;

    is(cache(http_get($uri)), 'MISS', "$case->{description}: fill");
    sleep $stale;
    is(cache(http_get($uri)), 'REVALIDATED',
        "$case->{description}: validated with a 304");

    my $before = origins($uri);
    my $next = http_get($uri);

    is(cache($next), $expected->{cache}, "$case->{description}: next request");
    is(origins($uri) - $before, $expected->{origin},
        "$case->{description}: origin requests");
    is(seconds($next), $expected->{date}, "$case->{description}: Date");

    sleep 0.4;
    is(cache(http_get($uri)), $expected->{later},
        "$case->{description}: 400 ms later");
}

###############################################################################

sub origin {
    my ($log, $fields, $policy) = @_;

    my $server = IO::Socket::INET->new(
        Proto => 'tcp',
        LocalAddr => '127.0.0.1:' . port(8081),
        Listen => 16,
        Reuse => 1
    )
        or die "Can't create listening socket: $!\n";

    while (my $client = $server->accept()) {
        $client->autoflush(1);

        my ($uri, $conditional) = ('', 0);
        while (<$client>) {
            $uri = $1 if /^GET (\S+) HTTP/;
            $conditional = 1 if /^If-None-Match:/i;
            last if /^\x0d?\x0a?$/;
        }
        next unless $uri;

        open my $out, '>>', $log or die "Can't write $log: $!\n";
        print $out "$uri\n";
        close $out;

        my $date = 'Thu, 26 Nov 2026 10:00:';
        my $stock = $uri =~ m{^/stock/};

        if ($conditional) {
            my $f = $fields->{$uri} // {};
            my $head = "HTTP/1.1 304 Not Modified\x0d\x0a";
            $head .= "Date: $date$f->{date} GMT\x0d\x0a" if $f->{date};
            $head .= "Cache-Control: $f->{cc}\x0d\x0a" if $f->{cc};
            $head .= "ETag: $f->{etag}\x0d\x0a" if $f->{etag};
            print $client $head . "Connection: close\x0d\x0a\x0d\x0a";

        } else {
            my $body = 'manifest';
            print $client "HTTP/1.1 200 OK\x0d\x0a"
                . "Date: ${date}00 GMT\x0d\x0a"
                . 'Cache-Control: ' . ($stock ? 'max-age=1' : $policy)
                . "\x0d\x0a"
                . "ETag: \"v1\"\x0d\x0a"
                . "Content-Length: " . length($body) . "\x0d\x0a"
                . "Connection: close\x0d\x0a\x0d\x0a$body";
        }
        close $client;
    }
}

###############################################################################
