package Statocles::Theme;
# ABSTRACT: Templates, headers, footers, and navigation

use Statocles::Class;
use File::Find qw( find );
use File::Slurp qw( read_file );

has source_dir => (
    is => 'ro',
    isa => Str,
);

has templates => (
    is => 'ro',
    isa => HashRef[HashRef[InstanceOf['Statocles::Template']]],
    lazy => 1,
    builder => 'read',
);

sub read {
    my ( $self ) = @_;
    my %tmpl;
    find(
        sub {
            if ( /[.]tmpl$/ ) {
                my ( $vol, $dirs, $name ) = splitpath( $File::Find::name );
                $name =~ s/[.]tmpl$//;
                my @dirs = splitdir( $dirs );
                # $dirs will end with a slash, so the last item in @dirs is ''
                my $group = $dirs[-2];
                $tmpl{ $group }{ $name } = Statocles::Template->new(
                    path => $File::Find::name,
                );
            }
        },
        $self->source_dir,
    );
    return \%tmpl;
}

sub template {
    my ( $self, $app, $template ) = @_;
    return $self->templates->{ $app }{ $template };
}

1;
__END__

=head1 DESCRIPTION

A Theme contains all the templates that applications need.


