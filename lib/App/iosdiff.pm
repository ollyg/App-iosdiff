package App::iosdiff;

use strict;
use warnings FATAL => 'all';

use File::Slurp;
use Algorithm::Diff;
use File::Temp; # core
use List::Util 'max'; # core

use base 'Exporter';
our @EXPORT_OK = qw/ diff /;

sub diff {
    my ($left_file, $right_file) = @_;
    die "two args: left and right files\n"
        unless defined $left_file and -r $left_file
               and defined $right_file and -r $right_file;

    # load up two files to be diffed
    my $left_lines  = slurp_config( $left_file );
    my $right_lines = slurp_config( $right_file );

    # get indexes into left and right configs
    my ($left_stanzas,  $left_backref)  = generate_lookups( @$left_lines );
    my ($right_stanzas, $right_backref) = generate_lookups( @$right_lines );

    # ============================================================================

    # must have indexes for lines, as there are dupes, so use this module
    # rather than other list comparing tools (which refer to line content not idx)
    my $diff = Algorithm::Diff->new( $left_lines, $right_lines );

    my %seen_stanza;  # might have multiple hunks in one stanza
    my @total_output; # build up result

    # work through hunks in config, diff each stanza once only
    while ($diff->Next) {
        next if $diff->Same;
        my %affected_stanza;

        map { ++$affected_stanza{ $left_stanzas->[$_]  } } ($diff->Range(1));
        map { ++$affected_stanza{ $right_stanzas->[$_] } } ($diff->Range(2));

        foreach my $stanza (keys %affected_stanza) {
            next if exists $seen_stanza{$stanza};
            $left_backref->{$stanza}  ||= [];
            $right_backref->{$stanza} ||= [];

            my $lfh = File::Temp->new;
            my $rfh = File::Temp->new;

            write_file( $lfh, $left_backref->{$stanza} );
            write_file( $rfh, $right_backref->{$stanza} );

            my $size = (max (scalar @{$left_backref->{$stanza}},
                scalar @{$right_backref->{$stanza}})) + 1;

            # run the real diff command here, gather output
            my $command = "diff -U $size ". $lfh->filename .' '. $rfh->filename;
            my @output = `$command`;

            # strip diff command header, and store
            push @total_output, @output[3 .. $#output], "\n";
        }

        map { ++$seen_stanza{$_} } (keys %affected_stanza);
    }

    return @total_output;
}

# load a config from a file, removing uninteresting lines
# also where rancid might have commented a secret line, uncomment it
sub slurp_config {
    my $file = shift;
    my @lines;

    # skip comments and blank lines
    foreach ( read_file( $file ) ) {
        s/^!// if m/<removed>/;
        next if m/^!/;
        chomp;
        next if m/^$/;
        push @lines, $_;
    }

    return \@lines;
}

# provides indexes into the config
# find the stanza which a line is in, and all the lines in a stanza.
# that way when we're told a line changes, we can diff its parent stanza
sub generate_lookups {
    my @lines = @_;
    my $stanza = '';
    my (@stanzas, %backref);

    for (my $i = 0; $i <= $#lines; $i++) {
        my $line = $lines[$i];

        if ($i < $#lines and $line !~ m/^\s+/ and $lines[$i+1] =~ m/^\s+/) {
            # start of new indented stanza
            $stanza = $line;
            $backref{$line} ||= [];
            push @{$backref{$line}}, "$line\n";
            $stanzas[$i] = $line;
            next;
        }

        if ($line =~ m/^\s+/) {
            # continuation of indented stanza
            push @{$backref{$stanza}}, "$line\n";
            $stanzas[$i] = $stanza;
            next;
        }

        # new stanza, or continuation of unindented stanza
        # stanza are based on first two words in line, so they are not large
        $line =~ s/^\s*(no\s+)?//;
        my ($no) = $1 || '';

        my ($key1, $key2, undef) = split (/\s+/, $line, 3);
        $key2 ||= '';

        if ("$key1 $key2" ne $stanza and $i < $#lines) {
            $stanza = $key1;
            $stanza = "$key1 $key2" if $lines[$i+1] =~ m/^$key1 $key2/;
        }
        else {
            # last line special case
            $stanza = "$key1 $key2";
        }

        $backref{$stanza} ||= [];
        push @{$backref{$stanza}}, "$no$line\n";
        $stanzas[$i] = $stanza;
    }

    return (\@stanzas, \%backref);
}

1;

# ABSTRACT: Cisco IOS Config Diff
