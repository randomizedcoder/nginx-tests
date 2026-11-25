#!/usr/bin/perl

# (C) Dave Seddon

# Tests for http proxy cache, millisecond freshness with
# proxy_cache_fine_time: max-age-ms, s-maxage-ms and Age-Ms.

###############################################################################

use warnings;
use strict;

use Test::More;

use Time::HiRes qw/ time sleep /;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my @cases = (
    ['paired',       'max-age=0, max-age-ms=60000',                 'HIT'],
    ['reverse',      'max-age-ms=60000, max-age=0',                 'HIT'],
    ['split',        ['max-age=0', 'max-age-ms=60000'],             'HIT'],
    ['case',         'MAX-AGE=0, Max-Age-Ms=60000',                 'HIT'],
    ['zero',         'max-age=0, max-age-ms=0',                     'EXPIRED'],
    ['negative',     'max-age=0, max-age-ms=-200',                  'MISS'],
    ['fraction',     'max-age=0, max-age-ms=0.2',                   'MISS'],
    ['overflow',     'max-age=0, max-age-ms=99999999999999999999',  'MISS'],
    ['duplicate',    'max-age=0, max-age-ms=3, max-age-ms=60000',   'MISS'],
    ['unpaired',     'max-age-ms=60000',                            'MISS'],
    ['private',      'private, max-age=0, max-age-ms=60000',        'MISS'],
    ['no_store',     'max-age=0, max-age-ms=60000, no-store',       'MISS'],
    ['quoted',       'max-age=0, ext="abc,max-age-ms=60000"',       'MISS'],
    ['shared',       's-maxage=0, max-age=60, max-age-ms=60000',    'MISS'],
    ['legacy',       'max-age=60',                                  'HIT'],
);

my $t = Test::Nginx->new()->has(qw/http proxy cache rewrite/);
my $locations = '';
for my $case (@cases) {
    my ($name, $policy) = @$case;
    my @lines = ref($policy) ? @$policy : ($policy);
    $locations .= "location = /$name {\n";
    $locations .= "add_header Cache-Control '$_';\n" for @lines;
    $locations .= "return 200 'manifest';\n}\n";
}
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
            proxy_cache_revalidate on;
            proxy_cache_fine_time origin;
            add_header X-Cache $upstream_cache_status;
        }
    }
    server {
        listen 127.0.0.1:8081;
        location = /validate {
            root %%TESTDIR%%;
            add_header Cache-Control "max-age=0, max-age-ms=200" always;
        }
        LOCATIONS
    }
}
CONF
$config =~ s/LOCATIONS/$locations/;
$t->write_file_expand('nginx.conf', $config);
$t->write_file('validate', 'stable representation');
$t->try_run('no proxy_cache_fine_time')->plan(2 * @cases + 6);

###############################################################################

for my $case (@cases) {
    my ($name, undef, $status) = @$case;
    like(http_get("/$name"), qr/^X-Cache: MISS\r?$/mi, "$name first fetch");
    like(http_get("/$name"), qr/^X-Cache: $status\r?$/mi, "$name reuse");
}

$t->stop();
$t->run();
my $restored = http_get('/paired');
like($restored, qr/^X-Cache: HIT\r?$/mi, 'fine cache entry survives restart');
like($restored, qr/^Age-Ms: \d+\r?$/mi, 'restored entry reports total age');

like(http_get('/validate'), qr/^X-Cache: MISS\r?$/mi, 'fill conditional entry');
my $deadline = time() + 5;
my $validated = '';
while (time() < $deadline) {
    $validated = http_get('/validate');
    last if $validated =~ /^X-Cache: REVALIDATED\r?$/mi;
    sleep 0.025;
}
like($validated, qr/^X-Cache: REVALIDATED\r?$/mi, 'origin validated cached body');
like($validated, qr/stable representation\z/, '304 retains the representation');
like(http_get('/validate'), qr/^X-Cache: MISS\r?$/mi, 'refill after fine 304');

###############################################################################
