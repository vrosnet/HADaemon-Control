package HADaemon::Control;

use strict;
use warnings;

use POSIX ();
use Cwd qw(abs_path);
use File::Path qw(make_path);
use Scalar::Util qw(weaken);
use IPC::ConcurrencyLimit::WithStandby;

# Accessor building
my @accessors = qw(
    pid_dir quiet color_map name kill_timeout program program_args
    stdout_file stderr_file umask directory ipc_cl_options
    standby_stop_file uid gid log_file process_name_change
    path init_config init_code lsb_start lsb_stop lsb_sdesc lsb_desc
);

foreach my $method (@accessors) {
    no strict 'refs';
    *$method = sub {
        my $self = shift;
        $self->{$method} = shift if @_;
        return $self->{$method};
    }
}

sub new {
    my ($class, @in) = @_;
    my $args = ref $in[0] eq 'HASH' ? $in[0] : { @in };

    my $self = bless {
        color_map     => { red => 31, green => 32 },
        quiet         => 0,
    }, $class;

    foreach my $accessor (@accessors) {
        if (exists $args->{$accessor}) {
            $self->{$accessor} = delete $args->{$accessor};
        }
    }

    $self->user(delete $args->{user}) if exists $args->{user};
    $self->group(delete $args->{group}) if exists $args->{group};

    die "Unknown arguments to the constructor: " . join(' ' , keys %$args)
        if keys %$args;

    return $self;
}

sub run {
    my ($self) = @_;
    return $self->run_command(@ARGV);
}

sub run_command {
    my ($self, $arg) = @_;

    # Error Checking.
    $self->ipc_cl_options
        or die "Error: ipc_cl_options must be defined\n";
    $self->program && ref $self->program eq 'CODE'
        or die "Error: program must be defined and must be coderef\n";
    $self->name
        or die "Error: name must be defined\n";
    $self->pid_dir
        or die "Error: pid_dir must be defined\n";

    defined($self->kill_timeout)
        or $self->kill_timeout(1);

    $self->standby_stop_file
        or $self->standby_stop_file($self->pid_dir . '/standby-stop-file');

    $self->{ipc_cl_options}->{standby_max_procs}
        and not defined $self->{ipc_cl_options}->{retries}
            and warn "ipc_cl_options: 'standby_max_procs' defined but 'retries' not";

    ($self->{ipc_cl_options}->{type} //= 'Flock') eq 'Flock'
        or die "can work only with Flock backend\n";

    $self->{ipc_cl_options}->{path}
        or $self->{ipc_cl_options}->{path} = $self->pid_dir . '/lock/';
    $self->{ipc_cl_options}->{standby_path}
        or $self->{ipc_cl_options}->{standby_path} = $self->pid_dir . '/lock-standby/';
    $self->{process_name_change}
        and $self->{ipc_cl_options}->{process_name_change} = 1;

    if ($self->uid) {
        my @uiddata = getpwuid($self->uid);
        @uiddata or die "failed to get info about " . $self->uid . "\n";

        if (!$self->gid) {
            $self->gid($uiddata[3]);
            $self->trace("Implicit GID => " . $uiddata[3]);
        }

        $self->user
            or $self->{user} = $uiddata[0];

        $self->{user_home_dir} = $uiddata[7];
    }

    if ($self->log_file) {
        open(my $fh, '>>', $self->log_file)
            or die "failed to open logfile '" . $self->log_file . "': $!\n";

        $self->{log_fh} = $fh;
        chown $self->uid, $self->gid, $self->{log_fh} if $self->uid;
    }

    my $called_with = $arg // '';
    $called_with =~ s/^[-]+//g;

    my $allowed_actions = join('|', reverse sort $self->_all_actions());
    $called_with
        or die "Must be called with an action: [$allowed_actions]\n";

    my $action = "do_$called_with";
    if ($self->can($action)) {
        $self->_create_dir($self->pid_dir);
        return $self->$action() // 0;
    }

    die "Error: unknown action $called_with. [$allowed_actions]\n";
}

#####################################
# commands
#####################################
sub do_start {
    my ($self) = @_;
    $self->info('do_start()');

    my $expected_main = $self->_expected_main_processes();
    my $expected_standby = $self->_expected_standby_processes();
    if (   $self->_main_running() == $expected_main
        && $self->_standby_running() == $expected_standby)
    {
        $self->pretty_print('starting main + standby processes', 'Already Running');
        $self->trace("do_start(): all processes are already running");
        return 0;
    }

    $self->_unlink_file($self->standby_stop_file);

    if ($self->_fork_mains() && $self->_fork_standbys()) {
        $self->pretty_print('starting main + standby processes', 'OK');
        return 0;
    }

    $self->pretty_print('starting main + standby processes', 'Failed', 'red');
    $self->do_status();
    $self->detect_stolen_lock();

    return 1;
}

sub do_stop {
    my ($self) = @_;
    $self->info('do_stop()');

    if (!$self->_main_running() && !$self->_standby_running()) {
        $self->pretty_print('stopping main + standby processes', 'Not Running', 'red');
        $self->trace("do_stop(): all processes are not running");
        return 0;
    }

    $self->_write_file($self->standby_stop_file);
    $self->_wait_standbys_to_complete();

    foreach my $type ($self->_expected_main_processes()) {
        my $pid = $self->_pid_of_process_type($type);
        if ($pid && $self->_kill_pid($pid)) {
            $self->_unlink_file($self->_build_pid_file($type));
        }
    }

    if ($self->_main_running() == 0 && $self->_standby_running() == 0) {
        $self->pretty_print('stopping main + standby processes', 'OK');
        return 0;
    }

    $self->pretty_print('stopping main + standby processes', 'Failed', 'red');
    $self->do_status();
    return 1;
}

sub do_restart {
    my ($self) = @_;
    $self->info('do_restart()');

    # shortcut
    if (!$self->_main_running() && !$self->_standby_running()) {
        return $self->do_start();
    }

    # another shortcut
    if ($self->{ipc_cl_options}->{standby_max_procs} <= 0) {
        return $self->do_hard_restart();
    }

    # stoping standby
    $self->_write_file($self->standby_stop_file);
    if (not $self->_wait_standbys_to_complete()) {
        $self->pretty_print('stopping standby processes', 'Failed', 'red');
        $self->warn("all standby processes should be stopped at this moment. Can't move forward");
        return 1;
    }

    $self->pretty_print('stopping standby processes', 'OK');

    # starting standby
    $self->_unlink_file($self->standby_stop_file);

    if (!$self->_fork_standbys()) {
        $self->pretty_print('starting standby', 'Failed', 'red');
        $self->warn("all standby processes should be running at this moment. Can't move forward");
        return 1;
    }

    $self->pretty_print('starting standby processes', 'OK');

    # restarting mains and standbys
    foreach my $type ($self->_expected_main_processes()) {
        $self->_restart_main($type)
            or $self->pretty_print($type, 'Failed to restart', 'red');
    }

    # starting mains
    if (!$self->_fork_mains() || !$self->_fork_standbys()) {
        $self->pretty_print('restarting main + standby processes', 'Failed', 'red');
        $self->warn("all main + standby processes should be running at this moment");

        $self->do_status();
        $self->detect_stolen_lock();
        return 1;
    }

    $self->pretty_print('restarting main processes', 'OK');
    return 0;
}

sub do_hard_restart {
    my ($self) = @_;
    $self->info('do_hard_restart()');

    $self->do_stop();
    return $self->do_start();
}

sub do_status {
    my ($self) = @_;
    $self->info('do_status()');

    my $exit_code = 0;
    foreach my $type ($self->_expected_main_processes(), $self->_expected_standby_processes()) {
        if ($self->_pid_of_process_type($type)) {
            $self->pretty_print("$type status", 'Running');
        } else {
            $exit_code = 1;
            $self->pretty_print("$type status", 'Not Running', 'red');
        }
    }

    return $exit_code;
}

sub do_fork {
    my ($self) = @_;
    $self->info('do_fork()');
    return 1 if $self->_check_stop_file();

    $self->_fork_mains();
    $self->_fork_standbys();
    return 0;
}

sub do_reload {
    my ($self) = @_;
    $self->info('do_reload()');

    foreach my $type ($self->_expected_main_processes()) {
        my $pid = $self->_pid_of_process_type($type);
        if ($pid) {
            $self->_kill_or_die('HUP', $pid);
            $self->pretty_print($type, 'Reloaded');
        } else {
            $self->pretty_print("$type status", 'Not Running', 'red');
        }
    }
}

sub do_get_init_file {
    my ($self) = @_;
    $self->info('do_get_init_file()');
    return $self->_dump_init_script();
}

#####################################
# routines to work with processes
#####################################
sub _fork_mains {
    my ($self) = @_;
    my $expected_main = $self->_expected_main_processes();

    for (1..3) {
        my $to_start = $expected_main - $self->_main_running();
        $self->_fork() foreach (1 .. $to_start);

        for (1 .. $self->_standby_timeout) {
            return 1 if $self->_main_running() == $expected_main;
            sleep(1);
        }
    }

    return 0;
}

sub _fork_standbys {
    my ($self) = @_;
    my $expected_standby = $self->_expected_standby_processes();

    for (1..3) {
        my $to_start = $expected_standby - $self->_standby_running();
        $self->_fork() foreach (1 .. $to_start);

        for (1 .. $self->_standby_timeout) {
            return 1 if $self->_standby_running() == $expected_standby;
            sleep(1);
        }
    }

    return 0;
}

sub _main_running {
    my ($self) = @_;
    my @running = grep { $self->_pid_of_process_type($_) } $self->_expected_main_processes();
    return wantarray ? @running : scalar @running;
}

sub _standby_running {
    my ($self) = @_;
    my @running = grep { $self->_pid_of_process_type($_) } $self->_expected_standby_processes();
    return wantarray ? @running : scalar @running;
}

sub _pid_running {
    my ($self, $pid) = @_;

    if (not $pid) {
        $self->trace("_pid_running: invalid pid"),
        return 0;
    }

    my $res = $self->_kill_or_die(0, $pid);
    $self->trace("pid $pid is " . ($res ? 'running' : 'not running'));
    return $res;
}

sub _pid_of_process_type {
    my ($self, $type) = @_;
    my $pidfile = $self->_build_pid_file($type);
    my $pid = $self->_read_file($pidfile);
    return $pid && $self->_pid_running($pid) ? $pid : undef;
}

sub _kill_pid {
    my ($self, $pid) = @_;
    $self->trace("_kill_pid(): $pid");

    foreach my $signal (qw(TERM TERM INT KILL)) {
        $self->trace("Sending $signal signal to pid $pid...");
        $self->_kill_or_die($signal, $pid);

        for (1 .. $self->kill_timeout) {
            if (not $self->_pid_running($pid)) {
                $self->trace("Successfully killed $pid");
                return 1;
            }

            sleep 1;
        }
    }

    $self->trace("Failed to kill $pid");
    return 0;
}

sub _restart_main {
    my ($self, $type) = @_;
    $self->trace("_restart_main(): $type");

    my $pid = $self->_pid_of_process_type($type);
    if (not $pid) {
        $self->trace("Main process $type is not running");
        return 1;
    }

    foreach my $signal (qw(TERM TERM INT KILL)) {
        $self->trace("Sending $signal signal to pid $pid...");
        $self->_kill_or_die($signal, $pid);

        # wait until pid change
        for (1 .. $self->kill_timeout) {
            my $new_pid = $self->_pid_of_process_type($type);
            if ($new_pid && $pid != $new_pid) {
                $self->trace("Successfully restarted main $type");
                return 1;
            }

            sleep 1;
        }
    }

    $self->trace("Failed to restart main $type");
    return 0;
}

sub _kill_or_die {
    my ($self, $signal, $pid) = @_;

    my $res = kill($signal, $pid);
    if (!$res && $! != POSIX::ESRCH) {
        # don't want to die if proccess simply doesn't exists
        my $msg = "failed to send signal to pid $pid: $!" . ($! == POSIX::EPERM ? ' (not enough permissions, probably should run as root)' : '');
        $self->die($msg);
    }

    return $res;
}

sub _wait_standbys_to_complete {
    my ($self) = @_;
    $self->trace('_wait_all_standbys_to_complete()');

    for (1 .. $self->_standby_timeout) {
        return 1 if $self->_standby_running() == 0;
        sleep(1);
    }

    return 0;
}

sub _fork {
    my ($self) = @_;
    $self->trace("_double_fork()");
    my $parent_pid = $$;

    my $pid = fork();
    $pid and $self->trace("forked $pid");

    if ($pid == 0) { # Child, launch the process here
        # Become session leader
        POSIX::setsid() or $self->die("failed to setsid: $!");

        my $pid2 = fork();
        $pid2 and $self->trace("forked $pid2");

        if ($pid2 == 0) { # Our double fork.
            if ($self->gid) {
                $self->trace("setgid(" . $self->gid . ")");
                POSIX::setgid($self->gid) or $self->die("failed to setgid: $!");
            }

            if ($self->uid) {
                $self->trace("setuid(" . $self->uid . ")");
                POSIX::setuid($self->uid) or $self->die("failed to setuid: $!");

                $ENV{USER} = $self->{user};
                $ENV{HOME} = $self->{user_home_dir};
                $self->trace("\$ENV{USER} => " . $ENV{USER});
                $self->trace("\$ENV{HOME} => " . $ENV{HOME});
            }

            if ($self->umask) {
                umask($self->umask);
                $self->trace("umask(" . $self->umask . ")");
            }

            if ($self->directory) {
                chdir($self->directory);
                $self->trace("chdir(" . $self->directory . ")");
            }

            # close all file handlers but logging one
            my $log_fd = $self->{log_fh} ? fileno($self->{log_fh}) : -1;
            my $max_fd = POSIX::sysconf( &POSIX::_SC_OPEN_MAX );
            $max_fd = 64 if !defined $max_fd or $max_fd < 0;
            $log_fd != $_ and POSIX::close($_) foreach (3 .. $max_fd);

            # reopen stad descriptors
            $self->_open_std_filehandles();

            my $res = $self->_launch_program();
            exit($res // 0);
        } elsif (not defined $pid2) {
            $self->warn("cannot fork: $!");
            POSIX::_exit(1);
        } else {
            $self->info("parent process ($parent_pid) forked child ($pid2)");
            POSIX::_exit(0);
        }
    } elsif (not defined $pid) { # We couldn't fork =(
        $self->die("cannot fork: $!");
    } else {
        # Wait until first kid terminates
        $self->trace("waitpid()");
        waitpid($pid, 0);
    }
}

sub _open_std_filehandles {
    my ($self) = @_;

    # reopening STDIN, STDOUT, STDERR
    open(STDIN, '<', '/dev/null') or $self->die("Failed to open STDIN: $!");

    my $stdout = $self->stdout_file;
    my $stderr = $self->stderr_file;

    if ($stdout) {
        open(STDOUT, '>>', $stdout) or $self->die("Failed to open STDOUT to $stdout: $!");
        $self->trace("STDOUT redirected to $stdout");
    }

    if ($stderr) {
        open(STDERR, '>>', $stderr) or $self->die("Failed to open STDERR to $stderr: $!");
        $self->trace("STDERR redirected to $stderr");
    }
}

sub _launch_program {
    my ($self) = @_;
    $self->trace("_launch_program()");
    return if $self->_check_stop_file();

    $self->process_name_change
        and $0 = $self->name;

    my $pid_file = $self->_build_pid_file("unknown-$$");
    $self->_write_file($pid_file, $$);
    $self->{pid_file} = $pid_file;

    my $ipc = IPC::ConcurrencyLimit::WithStandby->new(%{ $self->ipc_cl_options });

    # have to duplicate this logic from IPC::CL:WS
    my $retries_classback = $ipc->{retries};
    if (ref $retries_classback ne 'CODE') {
        my $max_retries = $retries_classback;
        $retries_classback = sub { return $_[0] != $max_retries + 1 };
    }

    my $ipc_weak = $ipc;
    weaken($ipc_weak);

    $ipc->{retries} = sub {
        if ($_[0] == 1) { # run code on first attempt
            my $id = $ipc_weak->{standby_lock}->lock_id();
            $self->info("acquired standby lock $id");

            # adjusting name of pidfile
            my $pid_file = $self->_build_pid_file("standby-$id");
            $self->_rename_file($self->{pid_file}, $pid_file);
            $self->{pid_file} = $pid_file;
        }

        return 0 if $self->_check_stop_file();
        return $retries_classback->(@_);
    };

    my $id = $ipc->get_lock();
    if (not $id) {
        $self->_unlink_file($self->{pid_file});
        $self->info('failed to acquire both locks, exiting...');
        return 1;
    }

    $self->info("acquired main lock id: " . $ipc->lock_id());
    
    # now pid file should be 'main-$id'
    $pid_file = $self->_build_pid_file("main-$id");
    $self->_rename_file($self->{pid_file}, $pid_file);
    $self->{pid_file} = $pid_file;

    my $res = 0;
    if (not $self->_check_stop_file()) {
        my $lock_fd = $self->_main_lock_fd($ipc);
        $lock_fd and $ENV{HADC_lock_fd} = $lock_fd;
        $self->{log_fh} and close($self->{log_fh});

        my @args = @{ $self->program_args // [] };
        $res = $self->program->($self, @args);
    }

    $self->_unlink_file($self->{pid_file});
    return $res // 0;
}

sub _expected_main_processes {
    my ($self) = @_;
    my $num = $self->{ipc_cl_options}->{max_procs} // 0;
    my @expected = map { "main-$_" } ( 1 .. $num );
    return wantarray ? @expected : scalar @expected;
}

sub _expected_standby_processes {
    my ($self) = @_;
    my $num = $self->{ipc_cl_options}->{standby_max_procs} // 0;
    my @expected = map { "standby-$_" } ( 1 .. $num );
    return wantarray ? @expected : scalar @expected;
}

#####################################
# file routines
#####################################
sub _build_pid_file {
    my ($self, $type) = @_;
    return $self->pid_dir . "/$type.pid";
}

sub _read_file {
    my ($self, $file) = @_;
    return undef unless -f $file;

    open(my $fh, '<', $file) or $self->die("failed to read $file: $!");
    my $content = do { local $/; <$fh> };
    close($fh);

    $self->trace("read '$content' from file ($file)");
    return $content;
}

sub _write_file {
    my ($self, $file, $content) = @_;
    $content //= '';

    open(my $fh, '>', $file) or $self->die("failed to write $file: $!");
    print $fh $content;
    close($fh);

    $self->trace("wrote '$content' to file ($file)");
}

sub _rename_file {
    my ($self, $old_file, $new_file) = @_;
    rename($old_file, $new_file) or $self->die("failed to rename '$old_file' to '$new_file': $!");
    $self->trace("rename pid file ($old_file) to ($new_file)");
}

sub _unlink_file {
    my ($self, $file) = @_;
    return unless -f $file;
    unlink($file) or $self->die("failed to unlink file '$file': $!");
    $self->trace("unlink file ($file)");
}

sub _create_dir {
    my ($self, $dir) = @_;
    if (-d $dir) {
        $self->trace("Dir exists ($dir) - no need to create");
    } else {
        make_path($dir, { uid => $self->uid, group => $self->gid, error => \my $errors });
        @$errors and $self->die("failed make_path: " . join(' ', map { keys $_, values $_ } @$errors));
        $self->trace("Created dir ($dir)");
    }
}

sub _check_stop_file {
    my $self = shift;
    if (-f $self->standby_stop_file()) {
        $self->info('stop file detected');
        return 1;
    } else {
        return 0;
    }
}

#####################################
# uid/gid routines
#####################################
sub user {
    my ($self, $user) = @_;

    if ($user) {
        my $uid = getpwnam($user)
          or die "Error: Couldn't get uid for non-existent user $user";

        $self->{uid} = $uid;
        $self->{user} = $user;
        $self->trace("Set UID => $uid");
    }

    return $self->{user};
}

sub group {
    my ($self, $group) = @_;

    if ($group) {
        my $gid = getgrnam($group)
          or die "Error: Couldn't get gid for non-existent group $group";

        $self->{gid} = $gid;
        $self->{group} = $group;
        $self->trace("Set GID => $gid");
    }

    return $self->{group};
}

#####################################
# lock detection logic
#####################################
sub detect_stolen_lock {
    my ($self) = @_;
    $self->_main_running() != $self->_expected_main_processes() && $self->_standby_running() == $self->_expected_standby_processes()
        and $self->warn("one of main processes failed to acquire main lock, something is possibly holding it!!!");
}

sub _main_lock_fd {
    my ($self, $ipc) = @_;
    if (   exists $ipc->{main_lock}
        && exists $ipc->{main_lock}->{lock_obj}
        && exists $ipc->{main_lock}->{lock_obj}->{lock_fh})
    {
        my $fd = fileno($ipc->{main_lock}->{lock_obj}->{lock_fh});
        $self->trace("detected lock fd: $fd");
        return $fd;
    }

    $self->warn("failed to detect lock fd");
    return undef;
}

#####################################
# misc
#####################################
sub pretty_print {
    my ($self, $process_type, $message, $color) = @_;
    return if $self->quiet;

    $color //= "green"; # Green is no color.
    my $code = $self->color_map->{$color} //= 32; # Green is invalid.

    local $| = 1;
    $process_type =~ s/-/ #/;

    if ($ENV{HADC_NO_COLORS}) {
        printf("%s: %-40s %40s\n", $self->name, $process_type, "[$message]");
    } else {
        printf("%s: %-40s %40s\n", $self->name, $process_type, "\033[$code" ."m[$message]\033[0m");
    }
}

sub info { $_[0]->_log('INFO', $_[1]); }
sub trace { $ENV{HADC_TRACE} and $_[0]->_log('TRACE', $_[1]); }
sub warn { $_[0]->_log('WARN', $_[1]); warn $_[1] . "\n"; }
sub die  { $_[0]->_log('CRIT', $_[1]); die $_[1] . "\n"; }

sub _log {
    my ($self, $level, $message) = @_;
    if ($self->{log_fh} && defined fileno($self->{log_fh})) {
        my $date = POSIX::strftime("%Y-%m-%d %H:%M:%S", localtime(time()));
        printf { $self->{log_fh} } "[%s][%d][%s] %s\n", $date, $$, $level, $message;
        $self->{log_fh}->flush();
    }
}

sub _all_actions {
    my ($self) = @_; 
    no strict 'refs';
    return map { m/^do_(.+)/ ? $1 : () } keys %{ ref($self) . '::' };
}

sub _standby_timeout {
    return int(shift->{ipc_cl_options}->{interval} // 0) + 3;
}

#####################################
# init script logic
#####################################
sub _dump_init_script {
    my ( $self ) = @_;

    my $data;
    while ( my $line = <DATA> ) {
        last if $line =~ /^__END__$/;
        $data .= $line;
    }

    # So, instead of expanding run_template to use a real DSL
    # or making TT a dependancy, I'm just going to fake template
    # IF logic.
    my $init_source_file = $self->init_config
        ? $self->run_template(
            '[ -r [% FILE %] ] && . [% FILE %]',
            { FILE => $self->init_config } )
        : "";

    print $self->_run_template(
        $data,
        {
            HEADER            => 'Generated at ' . scalar(localtime) . ' with HADaemon::Control ' . ($self->VERSION // 'DEV'),
            NAME              => $self->name      // '',
            REQUIRED_START    => $self->lsb_start // '',
            REQUIRED_STOP     => $self->lsb_stop  // '',
            SHORT_DESCRIPTION => $self->lsb_sdesc // '',
            DESCRIPTION       => $self->lsb_desc  // '',
            SCRIPT            => $self->path      // abs_path($0),
            INIT_SOURCE_FILE  => $init_source_file,
            INIT_CODE_BLOCK   => $self->init_code // '',
        }
    );

    return 0;
}

sub _run_template {
    my ($self, $content, $config) = @_;
    $content =~ s/\[% (.*?) %\]/$config->{$1}/g;
    return $content;
}

1;

__DATA__
#!/bin/sh

# [% HEADER %]

### BEGIN INIT INFO
# Provides:          [% NAME %]
# Required-Start:    [% REQUIRED_START %]
# Required-Stop:     [% REQUIRED_STOP %]
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: [% SHORT_DESCRIPTION %]
# Description:       [% DESCRIPTION %]
### END INIT INFO

[% INIT_SOURCE_FILE %]

[% INIT_CODE_BLOCK %]

if [ -x [% SCRIPT %] ];
then
    [% SCRIPT %] $1
else
    echo "Required program [% SCRIPT %] not found!"
    exit 1;
fi

__END__

=encoding utf8

=head1 NAME

HADaemon::Control - Create init scripts for Perl high-available (HA) daemons

=head1 DESCRIPTION

HADaemon::Control provides a library for creating init scripts for HA daemons in perl.
It allows you to run one or more main processes accompanied by a set of standby processes.
Standby processes constantly check presence of main ones and if later exits or dies
promote themselves and replace gone main processes. By doing so, HADaemon::Control
achieves high-availability and fault tolerance for a service provided by the deamon.
Your perl script just needs to set the accessors for what and how you
want something to run and the library takes care of the rest.

The library takes idea and interface from L<Daemon::Control> and combine them
with facilities of L<IPC::ConcurrencyLimit::WithStandby>. L<IPC::ConcurrencyLimit::WithStandby>
implements a mechanism to limit the number of concurrent processes in a cooperative
multiprocessing environment. For more information refer to the documentation
of L<IPC::ConcurrencyLimit> and L<IPC::ConcurrencyLimit::WithStandby>

=head1 SYNOPSIS

    #!/usr/bin/env perl

    use strict;
    use warnings;
    use HADaemon::Control;

    my $dc = HADaemon::Control->new({
        name => 'test.pl',
        user => 'nobody',
        pid_dir => '/tmp/test',
        program => sub { sleep 10; },
        ipc_cl_options => {
            max_procs => 1,
            standby_max_procs => 2,
            retries => sub { 1 },
        },
    });

    exit $dc->run();

You can then call the program:

    /usr/bin/my_program_launcher.pl start

By default C<run> will use @ARGV for the action, and exit with an LSB compatible
exit code. For finer control, you can use C<run_command>, which will return
the exit code, and accepts the action as an argument.  This enables more programatic
control, as well as running multiple instances of L<HADaemon::Control> from one script.

    my $dc = HADaemon::Control->new({
        ...
    });

    my $exit = $daemon->run_command(“start”);

=head1 CONSTRUCTOR

The constructor takes the following arguments.

=head2 name

The name of the program the daemon is controlling.  This will be used in
status messages "name [Started]"

=head2 program

This should be a coderef of actual programm to run.

    $daemon->program( sub { ... } );

=head2 program_args

This is an array ref of the arguments for the program. Args will be given to the program
coderef as @_, the HADaemon::Control instance that called the coderef will be passed
as the first arguments.  Your arguments start at $_[1].

    $daemon->program_args( [ 'foo', 'bar' ] );

=head2 pid_dir

=head2 ipc_cl_options

=head2 standby_stop_file

=head2 log_file

If set, HADaemon::Control will print its own log to given file. You can also set C<HADC_TRACE> environment variable to get more verbose logs.

=head2 process_name_change

=head2 user

When set, the username supplied to this accessor will be used to set
the UID attribute. When this is used, C<uid> will be changed from
its initial settings if you set it (which you shouldn't, since you're
using usernames instead of UIDs). See L</uid> for setting numerical
user ids.

    $daemon->user('www-data');

=head2 group

When set, the groupname supplied to this accessor will be used to set
the GID attribute. When this is used, C<gid> will be changed from
its initial settings if you set it (which you shouldn't, since you're
using groupnames instead of GIDs). See L</gid> for setting numerical
group ids.

    $daemon->group('www-data');

=head2 uid

If provided, the UID that the program will drop to when forked. This will
only work if you are running as root. Accepts numeric UID. For usernames
please see L</user>.

    $daemon->uid( 1001 );

=head2 gid

If provided, the GID that the program will drop to when forked. This will
only work if you are running as root. Accepts numeric GID, for groupnames
please see L</group>.

    $daemon->gid( 1001 );

=head2 umask

If provided, the umask of the daemon will be set to the umask provided,
note that the umask must be in oct. By default the umask will not be
changed.

    $daemon->umask( 022 );

    Or:

    $daemon->umask( oct("022") );

=head2 directory

If provided, chdir to this directory before execution.

=head2 stdout_file

If provided stdout will be redirected to the given file.

    $daemon->stdout_file( "/tmp/mydaemon.stdout" );

=head2 stderr_file

If provided stderr will be redirected to the given file.

    $daemon->stderr_file( "/tmp/mydaemon.stderr" );

=head2 kill_timeout

This provides an amount of time in seconds between kill signals being
sent to the daemon. This value should be increased if your daemon has
a longer shutdown period. By default 1 second is used.

    $daemon->kill_timeout( 7 );

=head2 quiet

If this boolean flag is set to a true value all output from the init script
(NOT your daemon) to STDOUT will be suppressed.

    $daemon->quiet( 1 );

=head1 INIT FILE CONSTRUCTOR OPTIONS

The constructor also takes the following arguments to generate init file. See L</do_get_init_file>.

=head2 path

The path of the script you are using HADaemon::Control in. This will be used in
the LSB file generation to point it to the location of the script. If this is
not provided, the absolute path of $0 will be used.

=head2 init_config

The name of the init config file to load. When provided your init script will
source this file to include the environment variables. This is useful for setting
a C<PERL5LIB> and such things.

    $daemon->init_config( "/etc/default/my_program" );

    If you are using perlbrew, you probably want to set your init_config to
    C<$ENV{PERLBREW_ROOT} . '/etc/bashrc'>.

=head2 init_code

When given, whatever text is in this field will be dumped directly into
the generated init file.

    $daemon->init_code( "Arbitrary code goes here." )

=head2 lsb_start

The value of this string is used for the 'Required-Start' value of
the generated LSB init script. See L<http://wiki.debian.org/LSBInitScripts>
for more information.

    $daemon->lsb_start( '$remote_fs $syslog' );

=head2 lsb_stop

The value of this string is used for the 'Required-Stop' value of
the generated LSB init script. See L<http://wiki.debian.org/LSBInitScripts>
for more information.

    $daemon->lsb_stop( '$remote_fs $syslog' );

=head2 lsb_sdesc

The value of this string is used for the 'Short-Description' value of
the generated LSB init script. See L<http://wiki.debian.org/LSBInitScripts>
for more information.

    $daemon->lsb_sdesc( 'My program...' );

=head2 lsb_desc

The value of this string is used for the 'Description' value of
the generated LSB init script. See L<http://wiki.debian.org/LSBInitScripts>
for more information.

    $daemon->lsb_desc( 'My program controls a thing that does a thing.' );

=head1 METHODS

=head2 run_command

This function will process an action on the HADaemon::Control instance.
Valid arguments are those which a C<do_> method exists for, such as 
B<start>, B<stop>, B<restart>. Returns the LSB exit code for the
action processed.

=head2 run

This will make your program act as an init file, accepting input from
the command line. Run will exit with 0 for success and uses LSB exit
codes. As such no code should be used after ->run is called. Any code
in your file should be before this. This is a shortcut for 

    exit HADaemon::Control->new(...)->run_command( @ARGV );

=head2 do_start

Is called when start is given as an argument. Starts the forking and
exits. Called by:

    /usr/bin/my_program_launcher.pl start

=head2 do_stop

Is called when stop is given as an argument. Stops the running program
if it can. Called by:

    /usr/bin/my_program_launcher.pl stop

=head2 do_restart

Is called when restart is given as an argument. Calls do_stop and do_start.
Called by:

    /usr/bin/my_program_launcher.pl restart

=head2 do_reload

Is called when reload is given as an argument. Sends a HUP signal to the
daemon.

    /usr/bin/my_program_launcher.pl reload

=head2 do_status

Is called when status is given as an argument. Displays the status of the
program, basic on the PID file. Called by:

    /usr/bin/my_program_launcher.pl status

=head2 pretty_print

This is used to display status to the user. It accepts a message and a color.
It will default to green text, if no color is explicitly given. Only supports
red and green. If C<HADC_NO_COLORS> environment variable is set no colors are used.

    $daemon->pretty_print( "My Status", "red" );

=head1 AUTHOR

Ivan Kruglov, C<ivan.kruglov@yahoo.com>

=head1 ACKNOWLEDGMENT

This module was inspired by module Daemon::Control.

This module was originally developed for Booking.com.
With approval from Booking.com, this module was generalized
and put on CPAN, for which the authors would like to express
their gratitude.

=head1 COPYRIGHT AND LICENSE

(C) 2013, 2014 Ivan Kruglov. All rights reserved.

This code is available under the same license as Perl version
5.8.1 or higher.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

=head2 AVAILABILITY

The most current version of HADaemon::Control can be found at L<https://github.com/ikruglov/HADaemon-Control>
