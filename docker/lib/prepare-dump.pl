# Read only dump header statements into memory. INSERT data passes through
# in chunks, even when an extended INSERT occupies an entire line.
use strict;
use warnings;
use re '/aa';

my $compact = "SET SESSION sql_mode = CONCAT_WS(',', NULLIF(\@\@SESSION.sql_mode, ''), 'ALLOW_INVALID_DATES');\n";
my $mode_warning = "WARNING: Unrecognized header SQL_MODE assignment. Invalid dates may be stored as zero.\n";

# Cursors use absolute byte offsets. Peeking may refill the buffer but never
# consumes input. Release bytes once the caller has finished with them.
sub available {
    my ($in, $at, $need) = @_;
    my $offset = $at - $in->{base};
    while (!$in->{eof} && length($in->{buf}) - $offset < $need) {
        my $n = read STDIN, $in->{buf}, 65536, length($in->{buf});
        defined $n or die "read dump: $!";
        $in->{eof} = 1 unless $n;
    }
    return length($in->{buf}) - $offset;
}

sub release_before {
    my ($in, $at) = @_;
    if ($at - $in->{base} >= 65536) {
        substr($in->{buf}, 0, $at - $in->{base}, '');
        $in->{base} = $at;
    }
}

sub peek_bytes {
    my ($in, $at, $n) = @_;
    available($in, $at, $n);
    return substr($in->{buf}, $at - $in->{base}, $n);
}

# Return one header token and advance the cursor.
sub sql_token {
    my ($in, $s) = @_;
    my $start = $s->{at};
    my $offset = $start - $in->{base};
    return unless available($in, $start, 4);
    my $lead = substr($in->{buf}, $offset, 3);
    my $c = substr($lead, 0, 1);
    my $end = $offset;
    my $kind = 'symbol';
    if ($c =~ /['"\x60]/) {
        my $quote = $c;
        my $escapes = !$s->{no_backslash} && $quote ne chr(96) && !($quote eq '"' && $s->{ansi});
        ++$end;
        $kind = 'quoted';
        while (available($in, $in->{base} + $end, 2)) {
            pos($in->{buf}) = $end;
            if ($escapes) {
                $in->{buf} =~ /\G[^\Q$quote\E\\]*/gc;
            } else {
                $in->{buf} =~ /\G[^\Q$quote\E]*/gc;
            }
            $end = pos($in->{buf});
            last unless available($in, $in->{base} + $end, 2);
            my $ch = substr($in->{buf}, $end, 1);
            if ($ch eq $quote) {
                ++$end;
                last if substr($in->{buf}, $end, 1) ne $quote;
                ++$end;
            } elsif ($escapes && $ch eq '\\') {
                $end += length(substr($in->{buf}, $end, 2));
            }
        }
    } elsif ($lead =~ m{^/\*} || $lead =~ /^(?:\#|--(?=\s))/) {
        $kind = 'comment';
        my $block = substr($lead, 0, 2) eq '/*';
        my $stop = $block ? '*/' : "\n";
        my $search = $offset + ($block ? 2 : 1);
        while (1) {
            my $found = index($in->{buf}, $stop, $search);
            if ($found >= 0) { $end = $found + length($stop); last; }
            $end = length($in->{buf});
            last if $in->{eof};
            $search = $end - length($stop) + 1;
            available($in, $in->{base} + $end, 1);
        }
    } elsif ($c =~ /[\s\w\$\x80-\xff]/) {
        $kind = $c =~ /\s/ ? 'space' : 'word';
        while (1) {
            pos($in->{buf}) = $end;
            if ($kind eq 'space') { $in->{buf} =~ /\G\s+/gc; }
            else { $in->{buf} =~ /\G[\w\$\x80-\xff]+/gc; }
            $end = pos($in->{buf});
            last if $end < length($in->{buf}) || !available($in, $in->{base} + $end, 1);
        }
    } else {
        ++$end;
    }
    $s->{at} = $in->{base} + $end;
    return ($kind, substr($in->{buf}, $offset, $end - $offset));
}

sub set_modes {
    my ($s, $modes) = @_;
    $s->{no_backslash} = $modes =~ /(?:^|,)\s*NO_BACKSLASH_ESCAPES\s*(?:,|$)/i;
    $s->{ansi} = $modes =~ /(?:^|,)\s*(?:ANSI_QUOTES|ANSI|DB2|MAXDB|MSSQL|ORACLE|POSTGRESQL)\s*(?:,|$)/i;
}

# Consume SET assignments up to the client delimiter. Preserve everything
# except the insertion inside a recognized session SQL_MODE literal.
sub setting {
    my ($in, $s, $delimiter, $header) = @_;
    my %lexer = %$s;
    my ($out, $raw, $lhs, @rhs) = ('', '', '');
    my ($depth, $assigned, $value_end) = (0, 0, 0);
    my $flush = sub {
        if ($header && $lhs =~ /^(?:GLOBAL |\@\@GLOBAL\.|PERSIST(?:_ONLY)? )SQL_MODE$/i) {
            warn $mode_warning;
            $s->{saw_mode} = 1;
        } elsif ($lhs =~ /^(?:(?:SESSION|LOCAL) |\@\@(?:(?:SESSION|LOCAL)\.)?)?SQL_MODE$/i) {
            $s->{saw_mode} = 1;
            if (@rhs == 1 && $rhs[0] =~ /^(['"])([A-Z0-9_, \t]*)\1$/i && !($1 eq '"' && $lexer{ansi})) {
                my $modes = $2;
                set_modes($s, $modes);
                if ($header && $modes !~ /(?:^|,)\s*ALLOW_INVALID_DATES\s*(?:,|$)/i) {
                    substr($raw, $value_end - 1, 0) = ($modes eq '' ? '' : ',') . 'ALLOW_INVALID_DATES';
                }
            } elsif ("SET$raw;\n" ne $compact) {
                warn $mode_warning if $header;
                my $saved = $s->{saved}{lc(join('', @rhs))};
                $s->{no_backslash} = ($saved && $saved->[0]) // 0;
                $s->{ansi} = ($saved && $saved->[1]) // 0;
            }
        }
        if ($lhs =~ /^\@[a-z_0-9]+$/i && join('', @rhs) =~ /^\@\@(?:SESSION\.)?SQL_MODE$/i) {
            $s->{saved}{lc $lhs} = [@$s{qw(no_backslash ansi)}];
        } elsif ($lhs =~ /^\@[^\@]/) {
            if (@rhs == 1 && $rhs[0] =~ /^'([A-Z0-9_, \t]*)'$/i) {
                my %value;
                set_modes(\%value, $1);
                $s->{saved}{lc $lhs} = [@value{qw(no_backslash ansi)}];
            } else {
                delete $s->{saved}{lc $lhs};
            }
        }
        $out .= $raw;
        ($raw, $lhs, @rhs) = ('', '');
        $assigned = 0;
    };
    while (1) {
        if ($delimiter ne '' && peek_bytes($in, $s->{at}, length($delimiter)) eq $delimiter) {
            $s->{at} += length($delimiter);
            $flush->();
            return $out . $delimiter;
        }
        my ($kind, $word) = sql_token($in, \%lexer);
        $s->{at} = $lexer{at};
        if (!defined $kind) { $flush->(); return $out; }
        if ($word eq ',' && !$depth) { $flush->(); $out .= ','; next; }
        $raw .= $word;
        next if $kind eq 'space' || $kind eq 'comment';
        if (!$assigned) {
            if ($word eq '=') { $assigned = 1; }
            elsif ($word ne ':') {
                $word =~ s/^\x60(.*)\x60$/$1/s;
                $word =~ s/^"(.*)"$/$1/s if $lexer{ansi};
                $lhs .= ' ' if $lhs =~ /[\w\$]\z/ && $word =~ /^[\w\$]/;
                $lhs .= $word;
            }
        } else {
            push @rhs, $word;
            $value_end = length($raw);
        }
        ++$depth if $word eq '(';
        --$depth if $word eq ')';
    }
}

sub version_setting {
    my ($s, $token, $header) = @_;
    return unless $token =~ m{\A(/\*M?!([0-9]*)\s*SET(?![\w\$\x80-\xff]))(.*)(\*/)\z}is;
    my ($prefix, $version, $sql, $end) = ($1, $2, $3, $4);
    # The dump tools save and set a routine's creation mode under 50003.
    return if $header && $version eq '50003' && $sql =~ /^\s*(?:SQL_MODE|\@saved_sql_mode)\b/i;
    my %inner = (%$s, at => 0);
    my $tail = setting({buf => $sql, base => 0, eof => 1}, \%inner, '', $header);
    delete $inner{at};
    @$s{keys %inner} = values %inner;
    return $prefix . $tail . $end;
}

my $in = {buf => '', base => 0};
my $state = {at => 0};
while (length(my $prefix = peek_bytes($in, $state->{at}, 4))) {
    if ($prefix =~ /^SET(?![\w\$\x80-\xff])/i) {
        my (undef, $set) = sql_token($in, $state);
        print $set, setting($in, $state, ';', 1);
    } elsif ($prefix =~ m{^(?:\s|;|/\*|\#|--(?=\s))}) {
        my $start = $state->{at};
        my (undef, $token) = sql_token($in, $state);
        if ($token =~ m{^/\*M?!}i && $token !~ m{^/\*M?!\d*\s*\\-}i) {
            my $rewritten = version_setting($state, $token, 1);
            if (!defined $rewritten) { $state->{at} = $start; last; }
            $token = $rewritten;
        }
        print $token;
    } else { last; }
    release_before($in, $state->{at});
}
print $compact if !$state->{saw_mode} && available($in, $state->{at}, 1);
while (my $n = available($in, $state->{at}, 1)) {
    print substr($in->{buf}, $state->{at} - $in->{base}, $n);
    $state->{at} += $n;
    release_before($in, $state->{at});
}
close STDOUT or die "write dump: $!";
