#!/usr/bin/env perl

use strict;
use warnings;
use HADaemon::Control;

HADaemon::Control->new({
    name => 'test.pl',
    pid_dir => '/tmp/test',
    limit_options => {
        max_procs => 1,
        standby_max_procs => 1,
        path => '/tmp/test/',
        standby_path => '/tmp/test/standby',
    },
})->run();

