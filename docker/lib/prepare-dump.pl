# Read only dump header statements into memory. INSERT data passes through
# in chunks, even when an extended INSERT occupies an entire line.
use strict;
use warnings;
use re '/aa';

my $compact = "SET SESSION sql_mode = CONCAT_WS(',', NULLIF(\@\@SESSION.sql_mode, ''), 'ALLOW_INVALID_DATES');\n";
my $mode_warning = "WARNING: Unrecognized header SQL_MODE assignment. Invalid dates may be stored as zero.\n";
my $later_mode_warning = "WARNING: An SQL_MODE assignment after the dump header is ambiguous under different SQL modes and stays unchanged. Invalid dates may be stored as zero.\n";

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

# Return one token and advance the cursor. In a table value a single string
# may span megabytes. Body callers can consume such a quote in pieces.
sub sql_token {
    my ($in, $s, $split, $delimiter) = @_;
    my $start = $s->{at};
    my $offset = $start - $in->{base};
    return unless available($in, $start, 4);
    my $lead = substr($in->{buf}, $offset, 3);
    my $c = substr($lead, 0, 1);
    my $end = $offset;
    my $kind = 'symbol';
    if ($s->{quote} || $c =~ /['"\x60]/) {
        my $quote = $s->{quote} || $c;
        my $escapes = !$s->{no_backslash} && $quote ne chr(96) && !($quote eq '"' && $s->{ansi});
        ++$end unless $s->{quote};
        $kind = 'quoted';
        while (available($in, $in->{base} + $end, 2)) {
            pos($in->{buf}) = $end;
            if ($escapes) {
                $in->{buf} =~ /\G[^\Q$quote\E\\]*/gc;
            } else {
                $in->{buf} =~ /\G[^\Q$quote\E]*/gc;
            }
            $end = pos($in->{buf});
            if ($split && $end - $offset >= 65536) {
                $s->{quote} = $quote;
                last;
            }
            last unless available($in, $in->{base} + $end, 2);
            my $ch = substr($in->{buf}, $end, 1);
            if ($ch eq $quote) {
                ++$end;
                if (substr($in->{buf}, $end, 1) ne $quote) {
                    delete $s->{quote};
                    last;
                }
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
        if ($kind eq 'word' && defined $delimiter && $delimiter ne ';') {
            # A client delimiter can begin inside a word, as in END$$.
            my $span = peek_bytes($in, $start, $end - $offset + length($delimiter) - 1);
            my $cut = index($span, $delimiter);
            $end = $offset + $cut if $cut > 0 && $cut < $end - $offset;
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
# except the insertion inside a recognized session SQL_MODE literal: in the
# header ($header is 1, with its warnings) and in a later statement of the
# body ($header is 2), where a second dump appended to the first sets its
# own mode after the first one restored the saved mode.
sub setting {
    my ($in, $s, $delimiter, $header) = @_;
    my %lexer = %$s;
    my ($out, $raw, $lhs, @rhs) = ('', '', '');
    my ($depth, $assigned, $value_end) = (0, 0, 0);
    my $flush = sub {
        if ($header == 1 && $lhs =~ /^(?:GLOBAL |\@\@GLOBAL\.|PERSIST(?:_ONLY)? )SQL_MODE$/i) {
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
                warn $mode_warning if $header == 1;
                my $saved = $s->{saved}{lc(join('', @rhs))};
                $s->{no_backslash} = ($saved && $saved->[0]) // $s->{inherited};
                $s->{ansi} = ($saved && $saved->[1]) // $s->{guess_ansi};
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
        my ($kind, $word) = sql_token($in, \%lexer, 0, $delimiter || undef);
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
    # The dump tools save and set a routine's creation mode under 50003: it
    # ends the header, and stays as it is in the body.
    return if $header == 1 && $version eq '50003' && $sql =~ /^\s*(?:SQL_MODE|\@saved_sql_mode)\b/i;
    $header = 0 if $header == 2 && $version eq '50003';
    my %inner = (%$s, at => 0);
    my $tail = setting({buf => $sql, base => 0, eof => 1}, \%inner, '', $header);
    %$s = (%inner, at => $s->{at});
    return $prefix . $tail . $end;
}

my $in = {buf => '', base => 0};
my $state = {at => 0, ansi => 0};
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
# Recognize only the outer definition list. A comma inside an expression or
# a list of indexed columns cannot begin a new FULLTEXT definition.
sub ddl_token {
    my ($s, $token) = @_;
    my $phase = $s->{phase};
    if ($phase eq 'start') {
        $s->{operation} = $token;
        $s->{phase} = $token eq 'CREATE' || $token eq 'ALTER' ? 'verb' : 'other';
    } elsif ($phase eq 'verb') {
        return if $s->{operation} eq 'CREATE' && $token eq 'TEMPORARY';
        $s->{phase} = $token eq 'TABLE' ? 'name' : 'other';
    } elsif ($phase eq 'name') {
        return if $token eq 'IF' || $token eq 'NOT' || $token eq 'EXISTS';
        $s->{phase} = 'after_name';
    } elsif ($phase eq 'after_name') {
        if ($token eq '.') {
            $s->{phase} = 'name';
        } elsif ($s->{operation} eq 'CREATE' && $token eq '(') {
            $s->{depth} = $s->{list_depth} = 1;
            $s->{phase} = 'item';
        } elsif ($s->{operation} eq 'ALTER') {
            $s->{depth} = $s->{list_depth} = 0;
            $s->{phase} = $token eq 'ADD' ? 'add' : 'other_item';
        } else {
            $s->{phase} = 'other';
        }
    } elsif ($token eq '(') {
        $s->{phase} = 'columns' if $phase eq 'fulltext' && $s->{depth} == $s->{list_depth};
        ++$s->{depth};
    } elsif ($token eq ')') {
        --$s->{depth};
        $s->{phase} = 'options' if $phase eq 'columns' && $s->{depth} == $s->{list_depth};
        $s->{phase} = 'other' if $s->{depth} < $s->{list_depth};
    } elsif ($token eq ',' && $s->{depth} == $s->{list_depth}) {
        $s->{phase} = 'item';
    } elsif ($phase eq 'item' || $phase eq 'add') {
        if ($phase eq 'item' && $s->{operation} eq 'ALTER') {
            $s->{phase} = $token eq 'ADD' ? 'add' : 'other_item';
        } else {
            $s->{phase} = $token eq 'FULLTEXT' ? 'fulltext' : 'other_item';
        }
    }
}

# Probe on a copy of the cursor. A different parser, quoted example or
# incomplete option leaves every byte in the input stream.
sub option_word {
    my ($in, $s) = @_;
    while (1) {
        my $delimiter = $s->{delimiter};
        return '' if $delimiter && peek_bytes($in, $s->{at}, length($delimiter)) eq $delimiter;
        my ($kind, $word) = sql_token($in, $s, 1, $delimiter);
        return '' unless defined $kind;
        next if $kind eq 'space' || ($kind eq 'comment' && $word !~ m{^/\*M?!}i);
        return $word;
    }
    return '';
}

sub parser_option {
    my ($in, $s) = @_;
    return unless uc(option_word($in, $s)) eq 'WITH';
    return unless uc(option_word($in, $s)) eq 'PARSER';
    my $name = lc(option_word($in, $s));
    return $name eq 'ngram' || $name eq '`ngram`' || $s->{ansi} && $name eq '"ngram"';
}

sub option_end {
    my ($in, $s) = @_;
    my %probe = %$s;
    my $prefix = peek_bytes($in, $probe{at}, 8);
    if ($prefix =~ m{^/\*!50100}i) {
        my (undef, $wrapped) = sql_token($in, \%probe);
        return unless $wrapped =~ m{^/\*!50100\s+(.*?)\*/$}s;
        my $inside = {buf => $1, base => 0, eof => 1};
        my %inner = (%probe, at => 0, delimiter => undef);
        return unless parser_option($inside, \%inner) && option_word($inside, \%inner) eq '';
    } else {
        return unless $prefix =~ /^WITH(?![\w\$\x80-\xff])/i && parser_option($in, \%probe);
    }
    return $probe{at};
}

sub scan_step {
    my ($in, $s) = @_;
    my $start = $s->{at};
    my $delimiter = $s->{delimiter};
    if (!$s->{quote} && peek_bytes($in, $start, length($delimiter)) eq $delimiter) {
        $s->{at} += length($delimiter);
        $s->{phase} = 'start';
        return;
    }
    # Skip runs of ordinary bytes in INSERTs and routine bodies without
    # materializing their tokens (a hex literal can span many input chunks).
    if ($s->{phase} eq 'other' && !$s->{quote} && available($in, $start, 1)) {
        my $first = substr($delimiter, 0, 1);
        pos($in->{buf}) = $start - $in->{base};
        if ($in->{buf} =~ m{\G[^'"\x60/\#\-\Q$first\E]+}gc) {
            $s->{at} = $in->{base} + pos($in->{buf});
            return;
        }
    }
    my ($kind, $word) = sql_token($in, $s, 1, $delimiter);
    if (!defined $kind) { $s->{done} = 1; return; }
    if ($s->{phase} eq 'options' && $s->{depth} == $s->{list_depth} && $kind ne 'quoted') {
        my $from = $start;
        my %probe = %$s;
        if ($kind eq 'space') {
            $word =~ /([ \t]*)\z/;
            $from = $s->{at} - length($1);
        } else { $probe{at} = $start; }
        if (defined(my $end = option_end($in, \%probe))) {
            my $next = peek_bytes($in, $end, 1);
            my $join = $next =~ /[^\s,);]/ && peek_bytes($in, $end, length($delimiter)) ne $delimiter ? ' ' : '';
            push @{$s->{edits}}, [$from, $end, $join];
            $s->{at} = $end;
            return;
        }
    }
    return if $kind eq 'space';
    if ($kind eq 'comment') {
        if ($word =~ m{^/\*M?!}i && $s->{phase} eq 'start') {
            my $rewritten = version_setting($s, $word, 2);
            push @{$s->{edits}}, [$start, $s->{at}, $rewritten, 'mode'] if defined $rewritten && $rewritten ne $word;
            $s->{phase} = 'other';
        }
        return;
    }
    if ($s->{phase} eq 'start' && uc($word) eq 'DELIMITER') {
        my $at = $s->{at};
        my $line = '';
        while (length(my $part = peek_bytes($in, $at, 256))) {
            $part =~ s/(?<=\n).*//s;
            $line .= $part;
            $at += length($part);
            last if $part =~ /\n\z/;
        }
        if ($line =~ /^[ \t]+(?:'([^']+)'|"([^"]+)"|(\S+))/) {
            $s->{delimiter} = $1 // $2 // $3;
            $s->{at} = $at;
            return;
        }
    }
    if ($s->{phase} eq 'start' && uc($word) eq 'SET') {
        my $from = $s->{at};
        my $rewritten = setting($in, $s, $delimiter, 2);
        push @{$s->{edits}}, [$from, $s->{at}, $rewritten, 'mode']
            if $rewritten ne peek_bytes($in, $from, $s->{at} - $from);
        return;
    }
    ddl_token($s, $kind eq 'quoted' ? 'identifier' : uc($word)) unless $s->{phase} eq 'other';
}

# The bundled server's default has neither ANSI_QUOTES nor NO_BACKSLASH_ESCAPES.
# A compact dump inherits its session's backslash handling. Walk the cursors
# over the same input buffer. Emit a change only once all cursors agree on
# the exact byte range and replacement. Storage stays independent of dump size.
my @scans;
for my $backslash (0, 1) {
    # Also cover an expression whose resulting ANSI_QUOTES setting is unknown.
    # For an inherited compact mode ANSI_QUOTES starts at the bundled default.
    for my $ansi (0, 1) {
        push @scans, {%$state, phase => 'start', delimiter => ';', edits => [],
            no_backslash => $state->{no_backslash} // $backslash, inherited => $backslash,
            ansi => $state->{ansi} // $ansi, guess_ansi => $ansi,
            saved => {%{$state->{saved} // {}}}};
    }
}
my $written = $state->{at};
my $converted = 0;
my $later_mode_warned = 0;
while (1) {
    my $until = $written + 65536;
    for my $scan (@scans) {
        scan_step($in, $scan) while !$scan->{done} && $scan->{at} < $until;
    }
    my ($safe) = sort { $a <=> $b } map { $_->{at} } @scans;
    while (1) {
        my ($edit) = sort { $a->[0] <=> $b->[0] }
            map { @{$_->{edits}} ? $_->{edits}[0] : () } @scans;
        last if !$edit || $edit->[0] >= $safe;
        my @agree = grep {
            my $other = $_->{edits}[0];
            $other && $edit->[0] == $other->[0] && $edit->[1] == $other->[1] && $edit->[2] eq $other->[2]
        } @scans;
        shift @{$_->{edits}} for @agree;
        if (@agree < @scans) {
            die "ERROR: SQL parser conversion is ambiguous under different SQL modes. Set SQL_MODE explicitly in the dump before importing.\n"
                unless $edit->[3];
            # Only some readings of a compact dump see this mode assignment
            # as a statement: its bytes stay, as before it was looked for.
            warn $later_mode_warning unless $later_mode_warned++;
            next;
        }
        print substr($in->{buf}, $written - $in->{base}, $edit->[0] - $written), $edit->[2];
        $written = $edit->[1];
        $converted = 1 unless $edit->[3];
    }
    print substr($in->{buf}, $written - $in->{base}, $safe - $written);
    $written = $safe;
    release_before($in, $written);
    last unless grep { !$_->{done} } @scans;
}
warn "WARNING: MySQL ngram FULLTEXT indexes will use the default MariaDB parser. Search results may differ.\n" if $converted;
close STDOUT or die "write dump: $!";
