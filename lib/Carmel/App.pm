package Carmel::App;
use strict;
use warnings;

use Carmel;
use Carp ();
use Carmel::Repository;
use Config qw(%Config);
use CPAN::Meta::Requirements;
use File::Temp;
use File::Basename;
use File::Copy::Recursive;
use Module::CoreList;

sub new {
    my $class = shift;
    bless {
        perl_arch => "$]-$Config{archname}",
    }, $class;
}

sub run {
    my($self, @args) = @_;

    my $cmd = shift @args || 'install';
    my $call = $self->can("cmd_$cmd")
      or die "Could not find command '$cmd'";

    $self->$call(@args);
}

sub base_dir {
    # It just needs to be a temporary location to make re-installation faster
    my $self = shift;
    "$ENV{HOME}/.perl-carmel/cache/$self->{perl_arch}";
}

sub repository_path {
    my $self = shift;
    $ENV{PERL_CARMEL_REPO} || "$ENV{HOME}/.perl-carmel/builds/$self->{perl_arch}";
}

sub build_repo {
    my $self = shift;
    my $repo = Carmel::Repository->new;
    $repo->load($self->repository_path);
    $repo;
}

sub cmd_install {
    my($self, @args) = @_;

    if (@args) {
        $self->install(@args);
    } else {
        $self->install("--installdeps", ".");
    }

    my @artifacts;
    $self->resolve(sub { push @artifacts, $_[0] });

    print "---> Complete! @{[scalar @artifacts]} artifacts resolved and installed.\n";
}

sub is_core {
    my($self, $module, $want_version) = @_;

    unless (exists $Module::CoreList::version{$]+0}{$module}) {
        return;
    }

    CPAN::Meta::Requirements->from_string_hash({ $module => $want_version })
        ->accepts_module($module, $Module::CoreList::version{$]+0}{$module} || '0');
}

sub install {
    my($self, @args) = @_;

    my $dir = File::Temp::tempdir(CLEANUP => 1);
    local $ENV{PERL_CPANM_HOME} = $dir;
    system $^X, "-S", "cpanm", "--notest", "-L", $self->base_dir, @args if @args;

    for my $ent (glob "$dir/latest-build/*") {
        next unless -d $ent;
        next unless -e "$ent/blib/meta/install.json";
        File::Copy::Recursive::dircopy($ent, $self->repository_path . "/" . File::Basename::basename($ent));
    }
}

sub cmd_export {
    my($self) = @_;
    my %env = $self->env;
    print "export PATH=$env{PATH} PERL5LIB=$env{PERL5LIB}\n";
}

sub cmd_env {
    my($self) = @_;
    my %env = $self->env;
    print "PATH=$env{PATH}\nPERL5LIB=$env{PERL5LIB}\n";
}

sub cmd_exec {
    my($self, @args) = @_;
    my %env = $self->env;
    %ENV = (%env, %ENV);
    exec @args;
}

sub cmd_find {
    my($self, $module, $requirement) = @_;

    my @artifacts = $self->build_repo->find_all($module, $requirement || '0');
    for my $artifact (@artifacts) {
        printf "%s (%s) in %s\n", $artifact->package, $artifact->version || '0', $artifact->path;
    }
}

sub cmd_list {
    my($self) = @_;

    my @artifacts;
    $self->resolve(sub { push @artifacts, $_[0] });

    for my $artifact (sort { $a->package cmp $b->package } @artifacts) {
        printf "%s (%s) in %s\n", $artifact->package, $artifact->version || '0', $artifact->path;
    }
}

sub cmd_tree {
    my($self) = @_;

    $self->resolve(sub {
        my($artifact, $depth) = @_;
        printf "%s%s (%s) in %s\n", (" " x $depth), $artifact->package, $artifact->version || '0', $artifact->path;
    });

}

sub cmd_index {
    my $self = shift;
    $self->write_index(*STDOUT);
}

sub write_index {
    my($self, $fh) = @_;

    my @packages;
    $self->resolve(sub {
        my $artifact = shift;
        while (my($package, $data) = each %{$artifact->install->{provides}}) {
            push @packages, {
                package => $package,
                version => $data->{version} || 'undef',
                pathname => $artifact->install->{pathname},
            }
        }
    });

    print $fh <<EOF;
File:         02packages.details.txt
URL:          http://www.perl.com/CPAN/modules/02packages.details.txt
Description:  Package names found in Carmel build artifacts
Columns:      package name, version, path
Intended-For: Automated fetch routines, namespace documentation.
Written-By:   Carmel $Carmel::VERSION
Line-Count:   @{[ $#packages + 1 ]}
Last-Updated: @{[ scalar localtime ]}

EOF

    for my $p (@packages) {
        print $fh sprintf "%s %s  %s\n", pad($p->{package}, 32), pad($p->{version}, 10, 1), $p->{pathname};
    }
}

sub pad {
    my($str, $len, $left) = @_;

    my $howmany = $len - length($str);
    return $str if $howmany <= 0;

    my $pad = " " x $howmany;
    return $left ? "$pad$str" : "$str$pad";
}

sub try_snapshot {
    my $self = shift;

    # TODO loading snapshot without install causes artifacts not found
    return;

    if (my $cpanfile = $self->try_cpanfile) {
        return "$cpanfile.snapshot" if -e "$cpanfile.snapshot";
    }
    return;
}

sub try_cpanfile {
    my $self = shift;
    return $ENV{PERL_CARMEL_CPANFILE} if $ENV{PERL_CARMEL_CPANFILE};
    return 'cpanfile' if -e 'cpanfile';
    return;
}

sub build_requirements {
    my($self, @args) = @_;

    # TODO support more explicit way to load the list of modules

    if (my $snapshot = $self->try_snapshot) {
        require Carton::Snapshot;
        my $snapshot = Carton::Snapshot->new(path => $snapshot);
        return $self->snapshot_to_requirements($snapshot);
    }

    if (my $cpanfile = $self->try_cpanfile) {
        require Module::CPANfile;
        return Module::CPANfile->load($cpanfile)->prereqs->merged_requirements(['runtime'],['requires']);
    }

    return;
}

sub snapshot_to_requirements {
    my($self, $snapshot) = @_;

    $snapshot->load;

    my $requirements = CPAN::Meta::Requirements->new;
    for my $package ($snapshot->packages) {
        if ($package->version && $package->version ne 'undef') {
            $requirements->exact_version($package->name, $package->version);
        } else {
            $requirements->add_minimum($package->name, '0');
        }
    }

    $requirements;
}

sub resolve_recursive {
    my($self, $root_reqs, $requirements, $seen, $cb, $depth) = @_;

    my $repo = $self->build_repo;

    for my $module (sort $requirements->required_modules) {
        next if $module eq 'perl';

        my $want_version = $requirements->requirements_for_module($module);
        next if $self->is_core($module, $want_version);

        my $artifact = $repo->find($module, $want_version)
          or die "Could not find an artifact for $module => $want_version\nYou need to run `carmel install` first to get the modules installed and artifacts built.\n";

        next if $seen->{$artifact->path}++;
        $cb->($artifact, $depth);

        my $reqs = $artifact->requirements;
        $root_reqs->add_requirements($reqs);

        $self->resolve_recursive($root_reqs, $reqs, $seen, $cb, $depth + 1);
    }
}

sub resolve {
    my($self, $cb) = @_;

    my $requirements = $self->build_requirements
      or Carp::croak "Could not locate 'cpanfile' to load module list.";

    my @artifacts;
    $self->resolve_recursive($requirements, $requirements, {}, $cb, 0);

    @artifacts;
}

sub env {
    my($self) = @_;

    my @artifacts;
    $self->resolve(sub { push @artifacts, $_[0] });
    return (
        _join(PATH => map $_->paths, @artifacts),
        _join(PERL5LIB => map $_->libs, @artifacts),
    );
}

sub _join {
    my($env, @list) = @_;
    push @list, $ENV{$env} if $ENV{$env};
    return ($env => join(":", @list));
}

1;
