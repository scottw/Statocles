package Statocles::App::Blog;
# ABSTRACT: A blog application

use Statocles::Base 'Class';
use Getopt::Long qw( GetOptionsFromArray );
use Statocles::Store::File;
use Statocles::Page::Document;
use Statocles::Page::List;
use Statocles::Page::Feed;

with 'Statocles::App';

=attr store

The L<store|Statocles::Store> to read for documents.

=cut

has store => (
    is => 'ro',
    isa => Store,
    coerce => Store->coercion,
    required => 1,
);

=attr page_size

The number of posts to put in a page (the main page and the tag pages). Defaults
to 5.

=cut

has page_size => (
    is => 'ro',
    isa => Int,
    default => sub { 5 },
);

=attr index_tags

Filter the tags shown in the index page. An array of tags prefixed with either
a + or a -. By prefixing the tag with a "-", it will be removed from the index,
unless a later tag prefixed with a "+" also matches.

By default, all tags are shown on the index page.

So, given a document with tags "foo", and "bar":

    index_tags => [ ];                  # document will be included
    index_tags => [ '-foo' ];           # document will not be included
    index_tags => [ '-foo', '+bar' ];   # document will be included

=cut

has index_tags => (
    is => 'ro',
    isa => ArrayRef[Str],
    default => sub { [] },
);

# A cache of the last set of post pages we have
# XXX: We need to allow apps to have a "clear" the way that Store and Theme do
has _post_pages => (
    is => 'rw',
    isa => ArrayRef,
    default => sub { [] },
);

=method command( app_name, args )

Run a command on this app. The app name is used to build the help, so
users get exactly what they need to run.

=cut

our $default_post = {
    tags => undef,
    content => <<'ENDCONTENT',
Markdown content goes here.
ENDCONTENT
};

my $USAGE_INFO = <<'ENDHELP';
Usage:
    $name help -- This help file
    $name post [--date YYYY-MM-DD] <title> -- Create a new blog post with the given title
ENDHELP

sub command {
    my ( $self, $name, @argv ) = @_;

    if ( !$argv[0] ) {
        say STDERR "ERROR: Missing command";
        say STDERR eval "qq{$USAGE_INFO}";
        return 1;
    }

    if ( $argv[0] eq 'help' ) {
        say eval "qq{$USAGE_INFO}";
    }
    elsif ( $argv[0] eq 'post' ) {
        my %opt;
        GetOptionsFromArray( \@argv, \%opt,
            'date:s',
        );

        my %doc = (
            %$default_post,
            title => join " ", @argv[1..$#argv],
        );

        # Read post content on STDIN
        if ( !-t *STDIN ) {
            my $content = do { local $/; <STDIN> };
            %doc = (
                %doc,
                $self->store->parse_frontmatter( "<STDIN>", $content ),
            );

            # Re-open STDIN as the TTY so that the editor (vim) can use it
            # XXX Is this also a problem on Windows?
            if ( -e '/dev/tty' ) {
                close STDIN;
                open STDIN, '/dev/tty';
            }
        }

        if ( !$ENV{EDITOR} && !$doc{title} ) {
            say STDERR <<"ENDHELP";
Title is required when \$EDITOR is not set.

Usage: $name post <title>
ENDHELP
            return 1;
        }

        my ( $year, $mon, $day );
        if ( $opt{ date } ) {
            ( $year, $mon, $day ) = split /-/, $opt{date};
        }
        else {
            ( undef, undef, undef, $day, $mon, $year ) = localtime;
            $year += 1900;
            $mon += 1;
        }

        my @date_parts = (
            sprintf( '%04i', $year ),
            sprintf( '%02i', $mon ),
            sprintf( '%02i', $day ),
        );

        if ( $ENV{EDITOR} ) {
            # I can see no good way to test this automatically
            my $slug = $self->make_slug( $doc{title} || "new post" );
            my $path = Path::Tiny->new( @date_parts, $slug, "index.markdown" );
            my $tmp_path = $self->store->write_document( $path => \%doc );
            system $ENV{EDITOR}, $tmp_path;
            %doc = %{ $self->store->read_document( $path ) };
            $self->store->path->child( $path )->remove;
        }

        my $slug = $self->make_slug( $doc{title} );
        my $path = Path::Tiny->new( @date_parts, $slug, "index.markdown" );
        my $full_path = $self->store->write_document( $path => \%doc );
        say "New post at: $full_path";

    }
    else {
        say STDERR qq{ERROR: Unknown command "$argv[0]"};
        say STDERR eval "qq{$USAGE_INFO}";
        return 1;
    }

    return 0;
}

=method make_slug( $title )

Given a post title, remove special characters to create a slug.

=cut

sub make_slug {
    my ( $self, $slug ) = @_;
    $slug =~ s/[\W]+/-/g;
    return lc $slug;
}

=method post_pages()

Get the individual post Statocles::Page objects.

=cut

sub post_pages {
    my ( $self ) = @_;
    my @pages = map { $self->_make_post_page( $_ ) } $self->_sorted_docs;
    $self->_post_pages( [ @pages ] );
    return @pages;
}

=method post_files()

Get all the post collateral files.

=cut

sub post_files {
    my ( $self ) = @_;
    my @pages;

    my $iter = $self->store->find_files;
    while ( my $path = $iter->() ) {
        next unless $path =~ m{^/(\d{4})/(\d{2})/(\d{2})/[^/]+/};
        next if $path =~ /[.]markdown$/;

        push @pages, Statocles::Page::File->new(
            path => $path,
            fh => $self->store->open_file( $path ),
        );
    }

    return @pages;
}

# Return the post docs sorted by date, pruning any docs that are after
# the current date
sub _sorted_docs {
    my ( $self ) = @_;

    my $today = Time::Piece->new->ymd;
    my @doc_dates;
    for my $doc ( @{ $self->store->documents } ) {
        my @date_parts = $doc->path =~ m{/(\d{4})/(\d{2})/(\d{2})/[^/]+(?:/index[.]markdown)?$};
        next unless @date_parts;
        my $date = join "-", @date_parts;

        next if $date gt $today;

        push @doc_dates, [ $doc, $date ];
    }

    return map { $_->[0] } sort { $b->[1] cmp $a->[1] } @doc_dates;
}

sub _make_post_page {
    my ( $self, $doc ) = @_;

    my $path = $doc->path;
    $path =~ s{/{2,}}{/}g;
    $path =~ s{[.]\w+$}{.html};

    my @date_parts = $doc->path =~ m{/(\d{4})/(\d{2})/(\d{2})/[^/]+(?:/index[.]markdown)?$};
    my $date = join "-", @date_parts;

    my @tags;
    for my $tag ( @{ $doc->tags } ) {
        push @tags, $self->link(
            text => $tag,
            href => join( "/", 'tag', $self->_tag_url( $tag ), '' ),
        );
    }

    return Statocles::Page::Document->new(
        app => $self,
        layout => $self->site->theme->template( site => 'layout.html' ),
        template => $self->site->theme->template( blog => 'post.html' ),
        document => $doc,
        path => $path,
        date => $doc->has_date ? $doc->date : Time::Piece->strptime( $date, '%Y-%m-%d' ),
        tags => \@tags,
    );
}

=method index()

Get the index page (a L<list page|Statocles::Page::List>) for this application.
This includes all the relevant L<feed pages|Statocles::Page::Feed>.

=cut

my %FEEDS = (
    rss => {
        text => 'RSS',
        type => 'application/rss+xml',
        template => 'index.rss',
    },
    atom => {
        text => 'Atom',
        type => 'application/atom+xml',
        template => 'index.atom',
    },
);

sub index {
    my ( $self, @all_post_pages ) = @_;

    # Filter the index_tags
    my @index_post_pages;
    PAGE: for my $page ( @all_post_pages ) {
        my $add = 1;
        for my $tag_spec ( @{ $self->index_tags } ) {
            my $flag = substr $tag_spec, 0, 1;
            my $tag = substr $tag_spec, 1;
            if ( grep { $_ eq $tag } @{ $page->document->tags } ) {
                $add = $flag eq '-' ? 0 : 1;
            }
        }
        push @index_post_pages, $page if $add;
    }

    my @pages = Statocles::Page::List->paginate(
        after => $self->page_size,
        path => 'page/%i/index.html',
        index => 'index.html',
        # Sorting by path just happens to also sort by date
        pages => [ sort { $b->path cmp $a->path } @index_post_pages ],
        app => $self,
        template => $self->site->theme->template( blog => 'index.html' ),
        layout => $self->site->theme->template( site => 'layout.html' ),
    );

    return unless @pages; # Only build feeds if we have pages

    my $index = $pages[0];
    my @feed_pages;
    my @feed_links;
    for my $feed ( sort keys %FEEDS ) {
        my $page = Statocles::Page::Feed->new(
            app => $self,
            type => $FEEDS{ $feed }{ type },
            page => $index,
            path => 'index.' . $feed,
            template => $self->site->theme->template( blog => $FEEDS{$feed}{template} ),
        );
        push @feed_pages, $page;
        push @feed_links, $self->link(
            text => $FEEDS{ $feed }{ text },
            href => $page->path->stringify,
            type => $page->type,
        );
    }

    # Add the feeds to all the pages
    for my $page ( @pages ) {
        $page->_links->{feed} = \@feed_links;
    }

    return ( @pages, @feed_pages );
}

=method tag_pages()

Get L<pages|Statocles::Page> for the tags in the blog post documents.

=cut

sub tag_pages {
    my ( $self, @post_pages ) = @_;

    my %tagged_docs = $self->_tag_docs( @post_pages );

    my @pages;
    for my $tag ( keys %tagged_docs ) {
        my @tag_pages = Statocles::Page::List->paginate(
            after => $self->page_size,
            path => join( "/", 'tag', $self->_tag_url( $tag ), 'page/%i/index.html' ),
            index => join( "/", 'tag', $self->_tag_url( $tag ), 'index.html' ),
            # Sorting by path just happens to also sort by date
            pages => [ sort { $b->path cmp $a->path } @{ $tagged_docs{ $tag } } ],
            app => $self,
            template => $self->site->theme->template( blog => 'index.html' ),
            layout => $self->site->theme->template( site => 'layout.html' ),
        );

        my $index = $tag_pages[0];
        my @feed_pages;
        my @feed_links;
        for my $feed ( sort keys %FEEDS ) {
            my $tag_file = $self->_tag_url( $tag ) . '.' . $feed;

            my $page = Statocles::Page::Feed->new(
                type => $FEEDS{ $feed }{ type },
                app => $self,
                page => $index,
                path => join( "/", 'tag', $tag_file ),
                template => $self->site->theme->template( blog => $FEEDS{$feed}{template} ),
            );
            push @feed_pages, $page;
            push @feed_links, $self->link(
                text => $FEEDS{ $feed }{ text },
                href => $page->path->stringify,
                type => $page->type,
            );
        }

        # Add the feeds to all the pages
        for my $page ( @tag_pages ) {
            $page->_links->{feed} = \@feed_links;
        }

        push @pages, @tag_pages, @feed_pages;
    }

    return @pages;
}

=method pages()

Get all the L<pages|Statocles::Page> for this application.

=cut

sub pages {
    my ( $self ) = @_;
    my @post_pages = $self->post_pages;
    return (
        ( map { $self->$_( @post_pages ) } qw( index tag_pages ) ),
        $self->post_files,
        @post_pages,
    );
}

=method tags()

Get a set of L<link objects|Statocles::Link> suitable for creating a list of
tag links. The common attributes are:

    text => 'The tag text'
    href => 'The URL to the tag page'

=cut

sub tags {
    my ( $self ) = @_;
    my %tagged_docs = $self->_tag_docs( @{ $self->_post_pages } );
    return map {; $self->link( text => $_, href => join( "/", 'tag', $self->_tag_url( $_ ), '' ) ) }
        sort keys %tagged_docs
}

sub _tag_docs {
    my ( $self, @post_pages ) = @_;
    my %tagged_docs;
    for my $page ( @post_pages ) {
        for my $tag ( @{ $page->document->tags } ) {
            push @{ $tagged_docs{ $tag } }, $page;
        }
    }
    return %tagged_docs;
}

sub _tag_url {
    my ( $self, $tag ) = @_;
    $tag =~ s/\s+/-/g;
    return $tag;
}

=method recent_posts( $count, %filter )

Get the last $count recent posts for this blog. Useful for templates and site
index pages.

%filter is an optional set of filters to apply to only show recent posts
matching the given criteria. The following filters are available:

    tags        -> (string) Only show posts with the given tag

=cut

sub recent_posts {
    my ( $self, $count, %filter ) = @_;

    my $today = Time::Piece->new->ymd;
    my @pages;
    my @docs = $self->_sorted_docs;
    DOC: for my $doc ( @docs ) {
        QUERY: for my $attr ( keys %filter ) {
            my $value = $filter{ $attr };
            if ( $attr eq 'tags' ) {
                next DOC unless grep { $_ eq $value } @{ $doc->tags };
            }
        }

        my $page = $self->_make_post_page( $doc );
        $page->path( join "/", $self->url_root, $page->path );
        push @pages, $page;
        last if @pages >= $count;
    }

    return @pages;
}

=method page_url( page )

Return the absolute URL to this page, removing the "/index.html" if necessary.

=cut

# XXX This is TERRIBLE. We need to do this better. Perhaps a "url()" helper in the
# template? And a full_url() helper? Or perhaps the template knows whether it should
# use absolute (/whatever) or full (http://www.example.com/whatever) URLs?

sub page_url {
    my ( $self, $page ) = @_;
    my $url = "".$page->path;
    $url =~ s{/index[.]html$}{/};
    return $url;
}

1;
__END__

=head1 DESCRIPTION

This is a simple blog application for Statocles.

=head2 FEATURES

=over

=item *

Content dividers. By dividing your main content with "---", you create
sections. Only the first section will show up on the index page or in RSS
feeds.

=item *

RSS and Atom syndication feeds.

=item *

Tags to organize blog posts. Tags have their own custom feeds so users can
subscribe to only those posts they care about.

=item *

Crosspost links to redirect users to a syndicated blog. Useful when you
participate in many blogs and want to drive traffic to them.

=item *

Post-dated blog posts to appear automatically when the date is passed. If a
blog post is set in the future, it will not be added to the site when running
C<build> or C<deploy>.

In order to ensure that post-dated blogs get added, you may want to run
C<deploy> in a nightly cron job.

=back

=head1 THEME

=over

=item blog => index

The index page template. Gets the following template variables:

=over

=item site

The L<Statocles::Site> object.

=item pages

An array reference containing all the blog post pages. Each page is a hash reference with the following keys:

=over

=item content

The post content

=item title

The post title

=item author

The post author

=back

=item blog => post

The main post page template. Gets the following template variables:

=over

=item site

The L<Statocles::Site> object

=item content

The post content

=item title

The post title

=item author

The post author

=back

=back

=back

=head1 SEE ALSO

=over 4

=item L<Statocles::App>

=back

