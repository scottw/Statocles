
use Statocles::Base 'Test';
use Mojo::DOM;
use Time::Piece;
my $SHARE_DIR = path( __DIR__, '..', 'share' );

my ( $site, $build_dir, $deploy_dir ) = build_test_site_apps(
    $SHARE_DIR,
    index => 'blog',
    base_url => 'http://example.com',
);

my @pages = map { $_->pages } values %{ $site->apps };
my $today = Time::Piece->new->strftime( '%Y-%m-%d' );
my $to_href = sub {
    my $lastmod = $_->at('lastmod');
    return {
        loc => $_->at('loc')->text,
        changefreq => $_->at('changefreq')->text,
        priority => $_->at('priority')->text,
        ( $lastmod ? ( lastmod => $lastmod->text ) : () ),
    };
};

my %page_mod = (
    '/blog/2014/04/23/slug/' => '2014-04-30',
    '/blog/2014/04/30/plug/' => '2014-04-30',
    '/blog/2014/05/22/(regex)[name].file.html' => '2014-05-22',
    '/blog/2014/06/02/more_tags.html' => '2014-06-02',
    '/' => '2014-06-02',
    '/blog/page/2/' => '2014-06-02',
    '/blog/tag/more/' => '2014-06-02',
    '/blog/tag/better/' => '2014-06-02',
    '/blog/tag/better/page/2/' => '2014-06-02',
    '/blog/tag/error-message/' => '2014-05-22',
    '/blog/tag/even-more-tags/' => '2014-06-02',
);

my @posts = qw(
    /blog/2014/04/23/slug/
    /blog/2014/04/30/plug/
    /blog/2014/05/22/(regex)[name].file.html
    /blog/2014/06/02/more_tags.html
);

my @lists = qw(
    /
    /blog/page/2/
    /blog/tag/more/
    /blog/tag/better/
    /blog/tag/better/page/2/
    /blog/tag/error-message/
    /blog/tag/even-more-tags/
);

my @expect = (
    ( # List pages
        map {;
            {
                loc => "http://example.com$_",
                priority => '0.3',
                changefreq => 'daily',
                lastmod => $page_mod{ $_ },
            }
        }
        @lists
    ),
    ( # Post pages
        map {
            {
                loc => "http://example.com$_",
                priority => '0.5',
                changefreq => 'weekly',
                lastmod => $page_mod{ $_ },
            }
        }
        @posts
    )
);

subtest 'build' => sub {
    $site->build;
    my $dom = Mojo::DOM->new( $build_dir->child( 'sitemap.xml' )->slurp );
    if ( ok my $elem = $dom->at('urlset'), 'urlset exists' ) {;
        my @urls = $dom->at('urlset')->children->map( $to_href )->each;
        cmp_deeply \@urls, bag( @expect ) or diag explain \@urls, \@expect;
    }

    cmp_deeply
        [ grep { /\S/ } $build_dir->child( 'robots.txt' )->lines ],
        [
            "Sitemap: http://example.com/sitemap.xml\n",
            "User-Agent: *\n",
            "Disallow:\n",
        ] or diag explain [ $build_dir->child( 'robots.txt' )->lines ];
    ok !$deploy_dir->child( 'sitemap.xml' )->exists, 'not deployed yet';
    ok !$deploy_dir->child( 'robots.txt' )->exists, 'not deployed yet';
};

subtest 'deploy' => sub {
    $site->deploy;
    my $dom = Mojo::DOM->new( $deploy_dir->child( 'sitemap.xml' )->slurp );
    if ( ok my $elem = $dom->at('urlset'), 'urlset exists' ) {;
        my @urls = $dom->at('urlset')->children->map( $to_href )->each;
        cmp_deeply \@urls, bag( @expect ) or diag explain \@urls, \@expect;
    }

    cmp_deeply
        [ grep { /\S/ } $deploy_dir->child( 'robots.txt' )->lines ],
        [
            "Sitemap: http://example.com/sitemap.xml\n",
            "User-Agent: *\n",
            "Disallow:\n",
        ] or diag explain [ $deploy_dir->child( 'robots.txt' )->lines ];
};

done_testing;
