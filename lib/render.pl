#!/usr/bin/perl
# Render a template from stdin to stdout using exported environment variables.
#
#   {{TOKEN}}              value of $ENV{TOKEN}; a missing variable is a hard error
#   a line of only a token expands multi-line values at that indent, and vanishes if empty
#   @@if NAME / @@if !NAME / @@endif on their own lines keep a block when NAME is "true"
#
# GitHub's ${{ expressions }} are left alone because they contain spaces.
use strict;
use warnings;

my $file = $ARGV[0] // 'stdin';
my @keep = (1);
my $line = 0;

sub token {
    my ($name) = @_;
    die "render: unresolved token {{$name}} in $file line $line\n" unless exists $ENV{$name};
    return $ENV{$name};
}

while (my $text = <STDIN>) {
    $line++;
    if ($text =~ /^\s*\@\@if\s+(!?)(\w+)\s*$/) {
        my ($negate, $name) = ($1, $2);
        my $on = token($name) eq 'true';
        $on = !$on if $negate;
        push @keep, ($keep[-1] && $on) ? 1 : 0;
        next;
    }
    if ($text =~ /^\s*\@\@endif\s*$/) {
        die "render: stray \@\@endif in $file line $line\n" if @keep == 1;
        pop @keep;
        next;
    }
    next unless $keep[-1];

    if ($text =~ /^(\s*)\{\{([A-Z][A-Z0-9_]*)\}\}\s*$/) {
        my ($indent, $value) = ($1, token($2));
        next if $value eq '';
        chomp $value;
        print map { "$indent$_\n" } split /\n/, $value, -1;
        next;
    }
    $text =~ s/\{\{([A-Z][A-Z0-9_]*)\}\}/token($1)/ge;
    print $text;
}
die "render: unclosed \@\@if in $file\n" if @keep != 1;
