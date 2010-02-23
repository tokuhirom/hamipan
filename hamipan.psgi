use strict;
use warnings;
use Plack::Request;
use File::Spec;
use Plack::App::File;
use Plack::Builder;
use File::Copy;
use File::Path qw/mkpath/;
use File::Basename;
use DBD::SQLite;

use GDBM_File;
use Gearman::Client;

# configuration
our $ROOT          = '/path/to/root';
our $AUTH_DATABASE = 'hamipan-auth.db';
our $PKG_DATABASE  = 'hamipan-pkg.db';

# global vars
tie my %auth_db, 'GDBM_File', $AUTH_DATABASE, &GDBM_WRCREAT, 0640 or die "Cannot tie to $AUTH_DATABASE";
tie my %pkg_db, 'GDBM_File', $PKG_DATABASE, &GDBM_WRCREAT, 0640 or die "Cannot tie to $PKG_DATABASE";
my $gearman = Gearman::Client->new();
$gearman->job_servers('127.0.0.1');

builder {
    mount '/q/' => sub {
        my $env = shift;
        my $pkg = $env->{PATH_INFO} || '';
        $pkg =~ s!/q/!!;
        if (my $path = $pkg_db{$pkg}) {
            my $url = "http://$env->{HTTP_HOST}/$path";
            [302, ['Location' => $url], []];
        } else {
            [404, [], ['unknown package']];
        }
    };
    mount '/download/' => Plack::App::File->new({root => $ROOT});
    mount '/register/' => sub {
        my $req = Plack::Request->new(shift);
        my $user = $req->param('user');
        my $password = $req->param('password');
        if ($user && $password) {
            if (!($user =~ /^[a-z0-9]+$/)) {
                return [200, [], ['invalid user name.use /^[a-z0-9]+/']];
            } elsif (exists $auth_db{$user}) {
                return [200, [], ['already registered account']];
            } else {
                $auth_db{$user} = $password;
                return [200, [], ["registered $user"]];
            }
        } else {
            return [200, [], ["usage: user=dankogai&password=kogaidan"]];
        }
    };
    mount '/upload/' => builder {
        enable 'Auth::Basic', authenticator => sub {
            my ($username, $password) = @_;
            return 0 unless $username && $password;
            my $valid_pw = $auth_db{$username};
            return 0 unless $valid_pw && $valid_pw eq $password;
            return 1;
        };
        sub {
            my $req = Plack::Request->new(shift);

            my ($user, $password) = split /:/, ($req->headers->authorization_basic||'');
            $user = uc $user;

            # copy file to dist dir
            my $upload = $req->upload('file');
            my $basename = File::Basename::basename($upload->filename);
            my $destdir = File::Spec->catdir(
                $ROOT,
                substr( $user, 0, 1 ),
                substr( $user, 0, 2 ),
                $user
            );
            mkpath($destdir) unless -d $destdir;
            my $destname = File::Spec->catfile($destdir, $basename);
            copy($upload->filename, $destname) or die "cannot copy : $!";

            # run indexer
            $gearman->dispatch_background('index' => { filename => $destname });

            return [200, ['Content-Length' => 2], ['OK']];
        };
    };
    mount '/' => sub {
        [200, [], ['This is hamipan']];
    };
};

