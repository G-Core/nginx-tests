#!/usr/bin/perl

# (C) Gabriel Clima
# (C) Gcore

# Tests for gcdn_posted_request_loop_break (CDP-1755).  The fork's
# ngx_http_run_posted_requests reads $gcdn_posted_request_loop_break
# (milliseconds) before running each posted request; once the worker is
# more than that many milliseconds into the current event-loop iteration
# it marks the write event delayed, arms a 1 ms timer and returns to the
# event loop, logging "trigger an additional event loop iteration" at
# debug level.  A whole-object request over a sliced, fully cached file
# walks every slice subrequest inside that loop, so a 1 ms threshold must
# yield at least once; no variable and a value starting with '-' must
# never yield.  Every variant must deliver a byte-exact body.

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

my $t = Test::Nginx->new()
	->has(qw/http proxy cache slice rewrite --with-debug/)
	->plan(21);

$t->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    proxy_cache_path   %%TESTDIR%%/cache  keys_zone=NAME:10m;
    proxy_cache_key    $uri$slice_range;

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        slice  32k;

        proxy_cache         NAME;
        proxy_cache_valid   200 206  1h;
        proxy_set_header    Range  $slice_range;

        add_header  X-Cache-Status  $upstream_cache_status;

        location /on/ {
            set  $gcdn_posted_request_loop_break  1;
            error_log  %%TESTDIR%%/on.log  debug;
            proxy_pass  http://127.0.0.1:8081/;
        }

        location /off/ {
            error_log  %%TESTDIR%%/off.log  debug;
            proxy_pass  http://127.0.0.1:8081/;
        }

        location /dash/ {
            set  $gcdn_posted_request_loop_break  -;
            error_log  %%TESTDIR%%/dash.log  debug;
            proxy_pass  http://127.0.0.1:8081/;
        }
    }

    server {
        listen       127.0.0.1:8081;
        server_name  localhost;

        location / {
        }
    }
}

EOF

# 256 full slices, each a distinct letter so a dropped or reordered slice
# changes the body, plus a partial 257th slice

my $slice = 32 * 1024;
my $content = join '', map { chr(65 + $_ % 26) x $slice } 0 .. 255;
$content .= '#' x 12345;

$t->write_file('t', $content);
$t->run();

###############################################################################

for my $variant (qw/on off dash/) {
	my ($r, $body);

	($r, $body) = get("/$variant/t");
	like($r, qr/ 200 /, "$variant miss - status");
	ok($body eq $content, "$variant miss - body");

	($r, $body) = get("/$variant/t");
	like($r, qr/ 200 /, "$variant hit - status");
	like($r, qr/X-Cache-Status: HIT/, "$variant hit - cache status");
	ok($body eq $content, "$variant hit - body");
}

$t->stop();

my $trigger = qr/trigger an additional event loop iteration/;

my @yields = $t->read_file('on.log') =~ /$trigger/g;
cmp_ok(scalar @yields, '>', 0, 'threshold 1ms - loop broken');

unlike($t->read_file('off.log'), $trigger, 'no variable - loop not broken');
unlike($t->read_file('dash.log'), $trigger, 'dash - loop not broken');

# the first CDP-1755 iterations terminated connections and leaked sockets
# on graceful shutdown; the worker logs those to the location log

for my $variant (qw/on off dash/) {
	unlike($t->read_file("$variant.log"), qr/\[(alert|crit|emerg)\]/,
		"$variant - log clean");
}

###############################################################################

sub get {
	my ($url) = @_;
	my $r = http(<<EOF);
GET $url HTTP/1.0
Host: localhost

EOF
	my ($headers, $body) = split /\x0d\x0a\x0d\x0a/, $r, 2;
	return ($headers, defined $body ? $body : '');
}

###############################################################################
