package MetaCPAN::Script::Release;

use strict;
use warnings;

BEGIN {
    $ENV{PERL_JSON_BACKEND} = 'JSON::XS';
}

use CPAN::DistnameInfo ();
use File::Find::Rule;
use File::stat ();
use LWP::UserAgent;
use Log::Contextual qw( :log :dlog );
use MetaCPAN::Util;
use MetaCPAN::Model::Release;
use MetaCPAN::Types qw( Bool Dir HashRef Int Str );
use Moose;
use PerlIO::gzip;
use Try::Tiny qw( catch try );

with 'MetaCPAN::Role::Script', 'MooseX::Getopt';

has latest => (
    is            => 'ro',
    isa           => Bool,
    default       => 0,
    documentation => q{run 'latest' script after each release},
);

has age => (
    is            => 'ro',
    isa           => Int,
    documentation => 'index releases no older than x hours (undef)',
);

has skip => (
    is            => 'ro',
    isa           => Bool,
    default       => 0,
    documentation => 'skip already indexed modules (0)',
);

has status => (
    is            => 'ro',
    isa           => Str,
    default       => 'cpan',
    documentation => 'status of the indexed releases (cpan)',
);

has detect_backpan => (
    is            => 'ro',
    isa           => Bool,
    default       => 0,
    documentation => 'enable when indexing from a backpan',
);

has backpan_index => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_backpan_index',
);

has perms => (
    is      => 'ro',
    isa     => HashRef,
    lazy    => 1,
    builder => '_build_perms',
    traits  => ['NoGetopt'],
);

has _bulk_size => (
    is       => 'ro',
    isa      => Int,
    init_arg => 'bulk_size',
    default  => 10,
);

sub run {
    my $self = shift;
    my ( undef, @args ) = @{ $self->extra_argv };
    my @files;
    for (@args) {
        if ( -d $_ ) {
            log_info {"Looking for archives in $_"};
            my $find = File::Find::Rule->new->file->name(
                qr/\.(tgz|tbz|tar[\._-]gz|tar\.bz2|tar\.Z|zip|7z)$/);
            $find = $find->mtime( ">" . ( time - $self->age * 3600 ) )
                if ( $self->age );
            push(
                @files,
                map { $_->{file} } sort { $a->{mtime} <=> $b->{mtime} } map {
                    +{ file => $_, mtime => File::stat::stat($_)->mtime }
                } $find->in($_)
            );
        }
        elsif ( -f $_ ) {
            push( @files, $_ );
        }
        elsif ( $_ =~ /^https?:\/\//
            && CPAN::DistnameInfo->new($_)->cpanid )
        {
            my $d = CPAN::DistnameInfo->new($_);

            # XXX move path to config file
            my $file = $self->home->file(
                (
                    'var', ( $ENV{HARNESS_ACTIVE} ? 't' : () ),
                    'tmp', 'http', 'authors'
                ),
                MetaCPAN::Util::author_dir( $d->cpanid ),
                $d->filename,
            );
            my $ua = LWP::UserAgent->new(
                parse_head => 0,
                env_proxy  => 1,
                agent      => 'metacpan',
                timeout    => 30,
            );
            $file->dir->mkpath;
            log_info {"Downloading $_"};
            $ua->mirror( $_, $file );
            if ( -e $file ) {
                push( @files, $file );
            }
            else {
                log_error {"Downloading $_ failed"};
            }
        }
        else {
            log_error {"Dunno what $_ is"};
        }
    }

    # Strip off any files in a Perl6 folder
    # e.g. http://www.cpan.org/authors/id/J/JD/JDV/Perl6/
    # As here we are indexing perl5 only
    @files = grep { $_ !~ m{/Perl6/} } @files;

    log_info { scalar @files, " archives found" } if ( @files > 1 );

    # build here before we fork

    # Going to purge everything as not sure about the 'skip' or fork
    # logic - feel free to clean up so the CP::DistInfo isn't
    my @module_to_purge_dists = map { CPAN::DistnameInfo->new($_) } @files;

    $self->index;
    $self->backpan_index if ( $self->detect_backpan );
    $self->perms;
    my @pid;

    eval { DB::enable_profile() };
    while ( my $file = shift @files ) {

        if ( $self->skip ) {
            my $d     = CPAN::DistnameInfo->new($file);
            my $count = $self->index->type('release')->filter(
                {
                    and => [
                        { term => { archive => $d->filename } },
                        { term => { author  => $d->cpanid } },
                    ]
                }
            )->inflate(0)->count;
            if ($count) {
                log_info {"Skipping $file"};
                next;
            }
        }

        try { $self->import_archive($file) }
        catch {
            $self->handle_error("$file $_[0]");
        };
    }
    $self->index->refresh;

    # Call Fastly to purge
    $self->cdn_purge_cpan_distnameinfos( \@module_to_purge_dists );
}

sub _get_release_model {
    my ( $self, $archive_path, $bulk ) = @_;

    my $d = CPAN::DistnameInfo->new($archive_path);

    my $model = MetaCPAN::Model::Release->new(
        bulk     => $bulk,
        distinfo => $d,
        file     => $archive_path,
        index    => $self->index,
        level    => $self->level,
        logger   => $self->logger,
        status   => $self->detect_status( $d->cpanid, $d->filename ),
    );

    $model->run;

    return $model;
}

sub import_archive {
    my $self         = shift;
    my $archive_path = shift;

    my $bulk = $self->index->bulk( size => $self->_bulk_size );
    my $model = $self->_get_release_model( $archive_path, $bulk );

    log_debug {'Gathering modules'};

    my $files    = $model->files;
    my $modules  = $model->modules;
    my $meta     = $model->metadata;
    my $document = $model->document;

    foreach my $file (@$files) {
        $file->set_indexed($meta);
    }

    my %associated_pod;
    for ( grep { $_->indexed && $_->documentation } @$files ) {

        # $file->clear_documentation to force a rebuild
        my $documentation = $_->clear_documentation;
        $associated_pod{$documentation}
            = [ @{ $associated_pod{$documentation} || [] }, $_ ];
    }

    log_debug { 'Indexing ', scalar @$modules, ' modules' };
    my $perms = $self->perms;
    my @release_unauthorized;
    my @provides;
    foreach my $file (@$files) {
        $_->set_associated_pod( \%associated_pod ) for ( @{ $file->module } );

     # NOTE: "The method returns a list of unauthorized, but indexed modules."
        push( @release_unauthorized, $file->set_authorized($perms) )
            if ( keys %$perms );

        for ( @{ $file->module } ) {
            push( @provides, $_->name ) if $_->indexed && $_->authorized;
        }
        $file->clear_module if ( $file->is_pod_file );
        log_trace {"reindexing file $file->{path}"};
        $bulk->put($file);
        if ( !$document->has_abstract && $file->abstract ) {
            ( my $module = $document->distribution ) =~ s/-/::/g;
            $document->_set_abstract( $file->abstract );
            $document->put;
        }
    }
    if (@provides) {
        $document->_set_provides( [ sort @provides ] );
        $document->put;
    }
    $bulk->commit;

    if (@release_unauthorized) {
        log_info {
            "release "
                . $document->name
                . " contains unauthorized modules: "
                . join( ",", map { $_->name } @release_unauthorized );
        };
        $document->_set_authorized(0);
        $document->put;
    }

    if ( $self->latest ) {
        local @ARGV = ( qw(latest --distribution), $document->distribution );
        MetaCPAN::Script::Runner->run;
    }

    # update 'first' value
    $document->set_first;
    $document->put;

    sleep 2 if $ENV{'METACPAN_SERVER_CONFIG_LOCAL_SUFFIX'} eq 'testing';
}

sub _build_backpan_index {
    my $self = shift;
    my $ls   = $self->cpan->file(qw(indices find-ls.gz));
    unless ( -e $ls ) {
        log_error {"File $ls does not exist"};
        exit;
    }
    log_info {"Reading $ls"};
    my $cpan = {};
    open my $fh, "<:gzip", $ls;
    while (<$fh>) {
        my $path = ( split(/\s+/) )[-1];
        next unless ( $path =~ /^authors\/id\/\w+\/\w+\/(.*)$/ );
        $cpan->{$1} = 1;
    }
    close $fh;
    return $cpan;
}

sub detect_status {
    my ( $self, $author, $archive ) = @_;
    return $self->status unless ( $self->detect_backpan );
    if ( $self->backpan_index->{ join( '/', $author, $archive ) } ) {
        return 'cpan';
    }
    else {
        log_debug {'BackPAN detected'};
        return 'backpan';
    }
}

sub _build_perms {
    my $self = shift;
    my $file = $self->cpan->file(qw(modules 06perms.txt));
    my %authors;
    if ( -e $file ) {
        log_debug { "parsing ", $file };
        my $fh = $file->openr;
        while ( my $line = <$fh> ) {
            my ( $module, $author, $type ) = split( /,/, $line );
            next unless ($type);
            $authors{$module} ||= [];
            push( @{ $authors{$module} }, $author );
        }
        close $fh;
    }
    else {
        log_warn {"$file could not be found."};
    }

    my $packages = $self->cpan->file(qw(modules 02packages.details.txt.gz));
    if ( -e $packages ) {
        log_debug { "parsing ", $packages };
        open my $fh, "<:gzip", $packages;
        while ( my $line = <$fh> ) {
            if ( $line =~ /^(.+?)\s+.+?\s+\S\/\S+\/(\S+)\// ) {
                $authors{$1} ||= [];
                push( @{ $authors{$1} }, $2 );
            }
        }
        close $fh;
    }
    return \%authors;
}

$SIG{__WARN__} = sub {
    my $msg = shift;
    warn $msg unless $msg =~ m{Invalid header block at offset unknown at};
};

__PACKAGE__->meta->make_immutable;
1;

__END__

=head1 SYNOPSIS

 # bin/metacpan ~/cpan/authors/id/A
 # bin/metacpan ~/cpan/authors/id/A/AB/ABRAXXA/DBIx-Class-0.08127.tar.gz
 # bin/metacpan http://cpan.cpantesters.org/authors/id/D/DA/DAGOLDEN/CPAN-Meta-2.110580.tar.gz

 # bin/metacpan ~/cpan --age 24 --latest

=head1 DESCRIPTION

This is the workhorse of MetaCPAN. It accepts a list of folders, files or urls
and indexes the releases. Adding C<--latest> will set the status to C<latest>
for the indexed releases If you are indexing more than one release, running
L<MetaCPAN::Script::Latest> afterwards is probably faster.

C<--age> sets the maximum age of the file in hours. Will be ignored when processing
individual files or an url.

If an url is specified the file is downloaded to C<var/tmp/http/>. This folder is not
cleaned up since L<MetaCPAN::Plack::Source> depends on it to extract the source of
a file. If the archive cannot be find in the cpan mirror, it tries the temporary
folder. After a rsync this folder can be purged.

=cut
