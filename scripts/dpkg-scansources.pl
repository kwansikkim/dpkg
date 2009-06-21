#!/usr/bin/perl
#
# Copyright © 1999 Roderick Schertler
# Copyright © 2002 Wichert Akkerman <wakkerma@debian.org>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or (at
# your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# For a copy of the GNU General Public License write to the Free Software
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307 USA


# Errors with a single package are warned about but don't affect the
# exit code.  Only errors which affect everything cause a non-zero exit.
#
# Dependencies are by request non-existant.  I used to use the MD5 and
# Proc::WaitStat modules.


use strict;
use warnings;

use Dpkg;
use Dpkg::Gettext;
use Dpkg::ErrorHandling;
use Dpkg::Checksums;

textdomain("dpkg-dev");

use Getopt::Long ();

my $Exit = 0;

# %Override is a hash of lists.  The subs following describe what's in
# the lists.

my %Override;
sub O_PRIORITY		() { 0 }
sub O_SECTION		() { 1 }
sub O_MAINT_FROM	() { 2 } # undef for non-specific, else listref
sub O_MAINT_TO		() { 3 } # undef if there's no maint override

my %Priority = (
     'extra'		=> 1,
     'optional'		=> 2,
     'standard'		=> 3,
     'important'	=> 4,
     'required'		=> 5,
);

# Switches

my $Debug	= 0;
my $No_sort	= 0;
my $Src_override = undef;

my @Option_spec = (
    'debug!'		=> \$Debug,
    'help!'		=> \&usage,
    'no-sort|n'		=> \$No_sort,
    'source-override|s=s' => \$Src_override,
    'version'		=> \&version,
);

sub debug {
    print @_, "\n" if $Debug;
}

sub version {
    printf _g("Debian %s version %s.\n"), $progname, $version;
    exit;
}

sub usage {
    printf _g(
"Usage: %s [<option> ...] <binarypath> [<overridefile> [<pathprefix>]] > Sources

Options:
  -n, --no-sort            don't sort by package before outputting.
  -s, --source-override <file>
                           use file for additional source overrides, default
                           is regular override file with .src appended.
      --debug              turn debugging on.
      --help               show this help message.
      --version            show the version.

See the man page for the full documentation.
"), $progname;

    exit;
}

# Getopt::Long has some really awful defaults.  This function loads it
# then configures it to use more sane settings.

sub getopt(@);
sub configure_getopt {
    Getopt::Long->import(2.11);
    *getopt = \&Getopt::Long::GetOptions;

    # I'm setting this environment variable lest he sneaks more bad
    # defaults into the module.
    local $ENV{POSIXLY_CORRECT} = 1;
    Getopt::Long::config qw(
	default
	no_autoabbrev
	no_getopt_compat
	require_order
	bundling
	no_ignorecase
    );
}

sub close_msg {
    my $name = shift;
    return sprintf(_g("error closing %s (\$? %d, \$! `%s')"),
                   $name, $?, $!)."\n";
}

sub init {
    configure_getopt;
    getopt @Option_spec or usage;
}

sub load_override {
    my $file = shift;
    local $_;

    open OVERRIDE, $file or syserr(_g("can't read override file %s"), $file);
    while (<OVERRIDE>) {
    	s/#.*//;
	next if /^\s*$/;
	s/\s+$//;

	my @data = split ' ', $_, 4;
	unless (@data == 3 || @data == 4) {
	    warning(_g("invalid override entry at line %d (%d fields)"),
	            $., 0 + @data);
	    next;
	}
	my ($package, $priority, $section, $maintainer) = @data;
	if (exists $Override{$package}) {
	    warning(_g("ignoring duplicate override entry for %s at line %d"),
	            $package, $.);
	    next;
	}
	if (!$Priority{$priority}) {
	    warning(_g("ignoring override entry for %s, invalid priority %s"),
	            $package, $priority);
	    next;
	}

	$Override{$package} = [];
	$Override{$package}[O_PRIORITY] = $priority;
	$Override{$package}[O_SECTION] = $section;
	if (!defined $maintainer) {
	    # do nothing
	}
	elsif ($maintainer =~ /^(.*\S)\s*=>\s*(.*)$/) {
	    $Override{$package}[O_MAINT_FROM] = [split m-\s*//\s*-, $1];
	    $Override{$package}[O_MAINT_TO] = $2;
	}
	else {
	    $Override{$package}[O_MAINT_TO] = $maintainer;
	}
    }
    close OVERRIDE or syserr(_g("error closing override file"));
}

sub load_src_override {
    my ($user_file, $regular_file) = @_;
    my ($file);
    local $_;

    if (defined $user_file) {
	$file = $user_file;
    }
    elsif (defined $regular_file) {
	$file = "$regular_file.src";
    }
    else {
	return;
    }

    debug "source override file $file";
    unless (open SRC_OVERRIDE, $file) {
	return if !defined $user_file;
	syserr(_g("can't read source override file %s"), $file);
    }
    while (<SRC_OVERRIDE>) {
    	s/#.*//;
	next if /^\s*$/;
	s/\s+$//;

	my @data = split ' ', $_;
	unless (@data == 2) {
	    warning(_g("invalid source override entry at line %d (%d fields)"),
	            $., 0 + @data);
	    next;
	}

	my ($package, $section) = @data;
	my $key = "source/$package";
	if (exists $Override{$key}) {
	    warning(_g("ignoring duplicate source override entry for %s at line %d"),
	            $package, $.);
	    next;
	}
	$Override{$key} = [];
	$Override{$key}[O_SECTION] = $section;
    }
    close SRC_OVERRIDE or syserr(_g("error closing source override file"));
}

# Given FILENAME (for error reporting) and STRING, drop the PGP info
# from the string and undo the encoding (if present) and return it.

sub de_pgp {
    my ($file, $s) = @_;
    if ($s =~ s/^-----BEGIN PGP SIGNED MESSAGE-----.*?\n\n//s) {
	unless ($s =~ s/\n
			-----BEGIN\040PGP\040SIGNATURE-----\n
			.*?\n
			-----END\040PGP\040SIGNATURE-----\n
		    //xs) {
	    warning(_g("%s has PGP start token but not end token"), $file);
	    return;
	}
	$s =~ s/^- //mg;
    }
    return $s;
}

# Load DSC-FILE and return its size, MD5 and translated (de-PGPed)
# contents.

sub read_dsc {
    my $file = shift;
    my ($size, $nread, $contents);

    unless (open FILE, $file) {
	warning(_g("can't read %s: %s"), $file, $!);
	return;
    }

    $contents = '';
    do {
	$nread = read FILE, $contents, 16*1024, length $contents;
	unless (defined $nread) {
	    warning(_g("error reading from %s: %s"), $file, $!);
	    return;
	}
    } while $nread > 0;

    # Get checksums
    my $sums = {};
    getchecksums($file, $sums, \$size);

    unless (close FILE) {
	warning(_g("error closing %s: %s"), $file, $!);
	return;
    }

    $contents = de_pgp $file, $contents;
    return unless defined $contents;

    return $size, $sums, $contents;
}

# Given PREFIX and DSC-FILE, process the file and returning the source
# package name and index record.

sub process_dsc {
    my ($prefix, $file) = @_;
    my ($source, @binary, $priority, $section, $maintainer_override,
	$dir, $dir_field, $dsc_field_start);

    my ($size, $sums, $contents) = read_dsc $file or return;

    # Allow blank lines at the end of a file, because the other programs
    # do.
    $contents =~ s/\n\n+\Z/\n/;

    if ($contents =~ /^\n/ || $contents =~ /\n\n/) {
	warning(_g("%s invalid (contains blank line)"), $file);
	return;
    }

    # Take the $contents and create a list of (possibly multi-line)
    # fields.  Fields can be continued by starting the next line with
    # white space.  The tricky part is I don't want to modify the data
    # at all, so I can't just collapse continued fields.
    #
    # Implementation is to start from the last line and work backwards
    # to the second.  If this line starts with space, append it to the
    # previous line and undef it.  When done drop the undef entries.
    my @line = split /\n/, $contents;
    for (my $i = $#line; $i > 0; $i--) {
    	if ($line[$i] =~ /^\s/) {
	    $line[$i-1] .= "\n$line[$i]";
	    $line[$i] = undef;
	}
    }
    my @field = map { "$_\n" } grep { defined } @line;

    # Extract information from the record.
    for my $orig_field (@field) {
	my $s = $orig_field;
	$s =~ s/\s+$//;
	$s =~ s/\n\s+/ /g;
	unless ($s =~ s/^([^:\s]+):\s*//) {
	    warning(_g("invalid field in %s: %s"), $file, $orig_field);
	    return;
	}
	my ($key, $val) = (lc $1, $s);

	# $source
	if ($key eq 'source') {
	    if (defined $source) {
		warning(_g("duplicate source field in %s"), $file);
		return;
	    }
	    if ($val =~ /\s/) {
		warning(_g("invalid source field in %s"), $file);
		return;
	    }
	    $source = $val;
	    next;
	}

	# @binary
	if ($key eq 'binary') {
	    if (@binary) {
		warning(_g("duplicate binary field in %s"), $file);
		return;
	    }
	    @binary = split /\s*,\s*/, $val;
	    unless (@binary) {
		warning(_g("no binary packages specified in %s"), $file);
		return;
	    }
	}
    }

    # The priority for the source package is the highest priority of the
    # binary packages it produces.
    my @binary_by_priority = sort {
	    ($Override{$a} ? $Priority{$Override{$a}[O_PRIORITY]} : 0)
		<=>
	    ($Override{$b} ? $Priority{$Override{$b}[O_PRIORITY]} : 0)
	} @binary;
    my $priority_override = $Override{$binary_by_priority[-1]};
    $priority = $priority_override
			? $priority_override->[O_PRIORITY]
			: undef;

    # For the section override, first check for a record from the source
    # override file, else use the regular override file.
    my $section_override = $Override{"source/$source"} || $Override{$source};
    $section = $section_override
			? $section_override->[O_SECTION]
			: undef;

    # For the maintainer override, use the override record for the first
    # binary.
    $maintainer_override = $Override{$binary[0]};

    # A directory field will be inserted just before the files field.
    $dir = ($file =~ s-(.*)/--) ? $1 : '';
    $dir = "$prefix$dir";
    $dir =~ s-/+$--;
    $dir = '.' if $dir eq '';
    $dir_field .= "Directory: $dir\n";

    # The files field will get an entry for the .dsc file itself.
    my %listing;
    foreach my $alg (@check_supported) {
        if ($alg eq "md5") {
            $listing{$alg} = "Files:\n $sums->{$alg} $size $file\n";
        } else {
            $listing{$alg} = "Checksum-" . ucfirst($alg) .
                             ":\n $sums->{$alg} $size $file\n";
        }
    }

    # Loop through @field, doing nececessary processing and building up
    # @new_field.
    my @new_field;
    for (@field) {
	# Rename the source field to package.
    	s/^Source:/Package:/i;

	# Override the user's priority field.
	if (/^Priority:/i && defined $priority) {
	    $_ = "Priority: $priority\n";
	    undef $priority;
	}

	# Override the user's section field.
	if (/^Section:/i && defined $section) {
	    $_ = "Section: $section\n";
	    undef $section;
	}

    	# Insert the directory line just before the files entry, and add
	# the dsc file to the files list.
    	if (defined $dir_field && s/^Files:\s*//i) {
	    push @new_field, $dir_field;
	    $dir_field = undef;
	    $_ = " $_" if length;
	    $_ = "$listing{md5}$_";
	}

        if (/Checksums-(.*):/i) {
            my $alg = lc($1);
            s/Checksums-([^:]*):\s*//i;
            $_ = " $_" if length;
            $_ = "$listing{$alg}$_";
        }

	# Modify the maintainer if necessary.
	if ($maintainer_override
		&& defined $maintainer_override->[O_MAINT_TO]
		&& /^Maintainer:\s*(.*)\n/is) {
	    my $maintainer = $1;
	    $maintainer =~ s/\n\s+/ /g;
	    if (!defined $maintainer_override->[O_MAINT_FROM]
	    	    || grep { $maintainer eq $_ }
			    @{ $maintainer_override->[O_MAINT_FROM] }){
		$_ = "Maintainer: $maintainer_override->[O_MAINT_TO]\n";
	    }
	}
    }
    continue {
	push @new_field, $_ if defined $_;
    }

    # If there was no files entry, add one.
    if (defined $dir_field) {
	push @new_field, $dir_field;
	push @new_field, $dsc_field_start;
    }

    # Add the section field if it didn't override one the user supplied.
    if (defined $section) {
	# If the record starts with a package field put it after that,
	# otherwise put it first.
	my $pos = $new_field[0] =~ /^Package:/i ? 1 : 0;
	splice @new_field, $pos, 0, "Section: $section\n";
    }

    # Add the priority field if it didn't override one the user supplied.
    if (defined $priority) {
	# If the record starts with a package field put it after that,
	# otherwise put it first.
	my $pos = $new_field[0] =~ /^Package:/i ? 1 : 0;
	splice @new_field, $pos, 0, "Priority: $priority\n";
    }

    return $source, join '', @new_field, "\n";
}

sub main {
    my (@out);

    init;
    @ARGV >= 1 && @ARGV <= 3 or usageerr(_g("1 to 3 args expected\n"));

    push @ARGV, undef		if @ARGV < 2;
    push @ARGV, ''		if @ARGV < 3;
    my ($dir, $override, $prefix) = @ARGV;

    load_override $override if defined $override;
    load_src_override $Src_override, $override;

    open FIND, "find \Q$dir\E -follow -name '*.dsc' -print |"
	or syserr(_g("can't fork"));
    while (<FIND>) {
    	chomp;
	s-^\./+--;
    	my ($source, $out) = process_dsc $prefix, $_ or next;
	if ($No_sort) {
	    print $out;
	}
	else {
	    push @out, [$source, $out];
	}
    }
    close FIND or error(close_msg, 'find');

    if (@out) {
	print map { $_->[1] } sort { $a->[0] cmp $b->[0] } @out;
    }

    return 0;
}

$Exit = main || $Exit;
$Exit = 1 if $Exit and not $Exit % 256;
exit $Exit;
