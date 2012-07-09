#!/usr/bin/perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use List::Util            (qw(first sum min));
use Games::Lacuna::Client ();
use Getopt::Long          (qw(GetOptions));
use POSIX                 (qw(floor));
my $cfg_file;

if ( @ARGV && $ARGV[0] !~ /^--/) {
	$cfg_file = shift @ARGV;
}
else {
	$cfg_file = 'lacuna.yml';
}

unless ( $cfg_file and -e $cfg_file ) {
  $cfg_file = eval{
    require File::HomeDir;
    require File::Spec;
    my $dist = File::HomeDir->my_dist_config('Games-Lacuna-Client');
    File::Spec->catfile(
      $dist,
      'login.yml'
    ) if $dist;
  };
  unless ( $cfg_file and -e $cfg_file ) {
    die "Did not provide a config file";
  }
}

my $from;
my $to;
my $ship_name;
my $match_glyph;
my $max;

GetOptions(
    'from=s'  => \$from,
    'to=s'    => \$to,
    'ship=s'  => \$ship_name,
    'glyph=s' => \$match_glyph,
    'max=i'   => \$max,
);

usage() if !$from || !$to;


my $client = Games::Lacuna::Client->new(
	cfg_file => $cfg_file,
	 #debug    => 1,
);

my $empire  = $client->empire->get_status->{empire};
my $planets = $empire->{planets};

# reverse hash, to key by name instead of id
my %planets_by_name = reverse %$planets;

my $to_id = $planets_by_name{$to}
    or die "--to planet not found";

# Load planet data
my $body      = $client->body( id => $planets_by_name{$from} );
my $buildings = $body->get_buildings->{buildings};

# Find the TradeMin
my $trade_min_id = first {
        $buildings->{$_}->{name} eq 'Trade Ministry'
} keys %$buildings;

my $trade_min = $client->building( id => $trade_min_id, type => 'Trade' );

my $glyphs_result = $trade_min->get_glyph_summary;
my @glyph_types   = @{ $glyphs_result->{glyphs} };

if ( $match_glyph ) {
    @glyph_types =
        grep {
            $_->{type} =~ /$match_glyph/i
        } @glyph_types;
}

if ( !@glyph_types ) {
    print "No glyphs available to push\n";
    exit;
}


sub limit_glyphs {

    my ( $glyph_types, $count ) = @_;

    my $running = 0;
    foreach my $n ( 0..scalar(@$glyph_types) ) {
	my $num = $glyph_types->[$n]->{quantity};
	my $diff = $num + $running - $count;
	if ( $diff > 0 ) {
	    $glyph_types->[$n]->{quantity} = $num - $diff;
	    $glyph_types = [ @{ $glyph_types[0..$n] } ];
	    last;
	}
	else {
	    $running += $num;
	}
    }

    return $glyph_types;
  }

if ( $max ) {
    @glyph_types = @{ limit_glyphs( \@glyph_types, $max ) };
}

my $ship_id;

if ( $ship_name ) {
    my $ships = $trade_min->get_trade_ships->{ships};

    my ($ship) =
        sort {
            $b->{speed} <=> $a->{speed}
        }
        grep {
            $_->{name} =~ /\Q$ship_name/i
        } @$ships;

    if ( $ship ) {
        my $cargo_each = $glyphs_result->{cargo_space_used_each};
        my $cargo_req  = $cargo_each * sum map { $_->{quantity} } @glyph_types;

        if ( $ship->{hold_size} < $cargo_req ) {
            my $count = floor( $ship->{hold_size} / $cargo_each );

	    @glyph_types = @{ limit_glyphs( \@glyph_types, $count ) };

            warn sprintf "Specified ship cannot hold all plans - only pushing %d plans\n", $count;
        }

        $ship_id = $ship->{id};
    }
    else {
        print "No ship matching '$ship_name' found\n";
        print "will attempt to push without specifying a ship\n";
    }
}

my @items = map { $_->{type} = 'glyph'; $_ } @glyph_types;

my $return = $trade_min->push_items(
    $to_id,
    \@items,
    $ship_id ? { ship_id => $ship_id }
             : ()
);

printf "Pushed %d glyphs\n", sum map { $_->{quantity} } @glyph_types;
printf "Arriving %s\n", $return->{ship}{date_arrives};

exit;

sub usage {
  die <<END_USAGE;
Usage: $0 CONFIG_FILE
       --from      PLANET_NAME    (REQUIRED)
       --to        PLANET_NAME    (REQUIRED)
       --ship      SHIP NAME REGEX
       --glyph     GLYPH NAME REGEX
       --max       MAX No. GLYPHS TO PUSH (currently inactivated)

CONFIG_FILE  defaults to 'lacuna.yml'

Pushes glyphs between your own planets.

END_USAGE

}

