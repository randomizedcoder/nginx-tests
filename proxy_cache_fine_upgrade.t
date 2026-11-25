#!/usr/bin/perl

# (C) Dave Seddon

# Tests for http proxy cache, millisecond freshness: a cache written by
# an nginx binary without proxy_cache_fine_time remains readable.
# Set TEST_NGINX_BASELINE to that binary.

###############################################################################

use warnings;
use strict;

use Test::More;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $baseline = $ENV{TEST_NGINX_BASELINE};
plan skip_all => 'set TEST_NGINX_BASELINE to the original nginx binary'
    unless defined($baseline) && -x $baseline;

my $t = Test::Nginx->new()->has(qw/http proxy cache rewrite/)->plan(3);
my $config = <<'CONF';
%%TEST_GLOBALS%%
daemon off;
events {}
http {
    %%TEST_GLOBALS_HTTP%%
    proxy_cache_path %%TESTDIR%%/cache keys_zone=fine:1m;
    server {
        listen 127.0.0.1:8080;
        location / {
            proxy_pass http://127.0.0.1:8081;
            proxy_cache fine;
            add_header X-Cache $upstream_cache_status;
            FINE
        }
    }
    server {
        listen 127.0.0.1:8081;
        add_header Cache-Control "max-age=60";
        return 200 'representation';
    }
}
CONF
my $original = $config;
$original =~ s/FINE//;
{
    local $Test::Nginx::NGINX = $baseline;
    $t->write_file_expand('nginx.conf', $original)->run();
    like(http_get('/upgrade'), qr/^X-Cache: MISS\r?$/mi, 'baseline fills v5 entry');
    like(http_get('/upgrade'), qr/^X-Cache: HIT\r?$/mi, 'baseline reads v5 entry');
    $t->stop();
}
$config =~ s/FINE/proxy_cache_fine_time origin;/;
$t->write_file_expand('nginx.conf', $config)->run();
like(http_get('/upgrade'), qr/^X-Cache: HIT\r?$/mi, 'patched cache reads baseline entry');

###############################################################################
