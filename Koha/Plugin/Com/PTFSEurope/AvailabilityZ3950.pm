package Koha::Plugin::Com::PTFSEurope::AvailabilityZ3950;

use Modern::Perl;

use base qw( Koha::Plugins::Base );
use Koha::DateUtils qw( dt_from_string );
use Koha::Database;
use C4::Breeding qw( Z3950Search );
use Koha::Plugin::Com::PTFSEurope::AvailabilityZ3950::Api;

use Cwd qw( abs_path );
use CGI;
use LWP::UserAgent;
use HTTP::Request;
use JSON qw( encode_json decode_json );
use Digest::MD5 qw( md5_hex );
use MIME::Base64 qw( decode_base64 );
use URI::Escape qw ( uri_unescape );

our $VERSION = "1.0.0";

our $metadata = {
    name            => 'ILL availability - z39.50',
    author          => 'Andrew Isherwood',
    date_authored   => '2019-06-24',
    date_updated    => "2019-06-24",
    minimum_version => '18.11.00.000',
    maximum_version => undef,
    version         => $VERSION,
    description     => 'This plugin provides ILL availability searching for z39.50 targets'
};

sub new {
    my ( $class, $args ) = @_;

    ## We need to add our metadata here so our base class can access it
    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    ## Here, we call the 'new' method for our base class
    ## This runs some additional magic and checking
    ## and returns our actual $self
    my $self = $class->SUPER::new($args);

    $self->{schema} = Koha::Database->new()->schema();

    return $self;
}

# Recieve a hashref containing the submitted metadata
# and, if we can work with it, return a hashref of our service definition
sub ill_availability_services {
    my ($self, $search_metadata) = @_;

    # A list of metadata properties we're interested in
    # NOTE: This list needs to be kept in sync with a similar list in
    # Api.pm
    my $properties = [
        'isbn',
        'issn',
        'article_title',
        'article_author',
        'title',
        'author'
    ];

    # Establish if we can service this item
    my $can_service = 0;
    foreach my $property(@{$properties}) {
        if (
            $search_metadata->{$property} &&
            length $search_metadata->{$property} > 0
        ) {
            $can_service++;
        }
    }

    # Check we have at least one Z target we can use
    my $ids = $self->get_selected_z_target_ids();
    my $targets = Koha::Plugin::Com::PTFSEurope::AvailabilityZ3950::Api::get_z_targets($ids);
    my $target_count = scalar @{$targets};
    $can_service++ if $target_count > 0;

    # Bail out if we can't do anything with this request
    return 0 if $can_service == 0;

    my $endpoint = '/api/v1/contrib/' . $self->api_namespace .
        '/ill_availability_search_z3950?metadata=';

    return {
        # Our service should have a reasonably unique ID
        # to differentiate it from other service that might be in use
        id => md5_hex(
            $self->{metadata}->{name}.$self->{metadata}->{version}
        ),
        plugin     => $self->{metadata}->{name},
        endpoint   => $endpoint,
        datatablesConfig => {
            serverSide   => 'true',
            processing   => 'true',
            pagingType   => 'simple',
            info         => 'false',
            lengthChange => 'false',
            ordering     => 'false',
            searching    => 'false'
        }
    };
}

sub get_selected_z_target_ids {
    my ($self) = @_;

    my $config = decode_json($self->retrieve_data('avail_config') || '{}');
    my @ids = ();
    foreach my $key(%{$config}) {
        if ($key=~/^target_select_/) {
            push @ids, $config->{$key};
        }
    }
    return \@ids;
}

sub api_routes {
    my ($self, $args) = @_;

    my $spec_str = $self->mbf_read('openapi.json');
    my $spec = decode_json($spec_str);

    return $spec;
}

sub api_namespace {
    my ($self) = @_;

    return 'ill_availability_z3950';
}

sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    unless ( $cgi->param('save') ) {

        my $template = $self->get_template({ file => 'configure.tt' });
        my $conf = $self->retrieve_data('avail_config') || '{}';
        $template->param(
            targets => scalar Koha::Plugin::Com::PTFSEurope::AvailabilityZ3950::Api::get_z_targets(),
            config => scalar decode_json($conf)
        );

        $self->output_html( $template->output() );
    }
    else {
		my %blacklist = ('save' => 1, 'class' => 1, 'method' => 1);
        my $hashed = { map { $_ => (scalar $cgi->param($_))[0] } $cgi->param };
        my $p = {};
		foreach my $key (keys %{$hashed}) {
           if (!exists $blacklist{$key}) {
               $p->{$key} = $hashed->{$key};
           }
		}
        $self->store_data({ avail_config => scalar encode_json($p) });
        print $cgi->redirect(-url => '/cgi-bin/koha/plugins/run.pl?class=Koha::Plugin::Com::PTFSEurope::AvailabilityZ3950&method=configure');
        exit;
    }
}

sub install() {
    return 1;
}

sub upgrade {
    my ( $self, $args ) = @_;

    my $dt = dt_from_string();
    $self->store_data(
        { last_upgraded => $dt->ymd('-') . ' ' . $dt->hms(':') }
    );

    return 1;
}

sub uninstall() {
    return 1;
}

1;
