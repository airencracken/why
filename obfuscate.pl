#!/usr/bin/env perl
use v5.14;
use strict;
use warnings;
no warnings 'experimental';

# obfuscate.pl — replace bash function/variable names with invisible characters
#
# Modes:
#   --mode=control   ASCII control chars 0x01-0x1F (default)
#   --mode=unicode   Unicode non-printing chars (zero-width, format, combining)
#   --mode=both      Mix of control and unicode
#
# Strategy (based on empirical testing):
#   Function defs: use raw bytes in output    —  raw_bytes() { ... }
#   Function calls: use raw bytes in output   —  raw_bytes args
#   Variable store: associative array ___     —  ___[$'\xHH']=value
#   Variable read:  indirect expansion        —  ${___[$'\xHH']}
#
# Why raw bytes for functions: bash rejects $'\xNN'(){} syntax at parse time
# because expansion happens after the parser checks for valid identifier names.
# Raw bytes embedded in the source file pass the parser's identifier check.

use Getopt::Long;

# ── configuration ──────────────────────────────────────────────────────────────

my $mode   = 'control';
my $quiet  = 0;
GetOptions(
	'mode=s'  => \$mode,
	'quiet|q' => \$quiet,
) or die "Usage: $0 [--mode=control|unicode|both] [-q|--quiet]\n";
die "Invalid mode: $mode\n" unless $mode =~ /^(control|unicode|both)$/;

# ── character pools ────────────────────────────────────────────────────────────

# ASCII control chars usable as identifier bytes (stored as single-byte strings)
# Excluded: 0x00 NUL  0x09 TAB  0x0A LF  0x0D CR  0x20 SP
my @CTRL = map { chr($_) } ( 1 .. 8, 11, 12, 14 .. 31, 127 );

# Unicode non-printing characters (all empirically tested to work in bash func names)
my @UNI_CODEPOINTS = (
	0x00AD,   0x034F,  0x061C,  0x1680,  0x180E,
	0x200B,   0x200C,  0x200D,  0x200E,  0x200F,
	0x202A,   0x202B,  0x202C,  0x202D,  0x202E,
	0x2060,   0x2061,  0x2062,  0x2063,  0x2064,
	0x20E0,   0x3164,  0xFE00,  0xFEFF,
);

# Pre-encode as UTF-8 byte strings
my @UNI;
for my $cp (@UNI_CODEPOINTS) {
	my $char = chr($cp);
	utf8::encode($char);
	push @UNI, $char;
}

# Combined pool for 'both' mode
my @BOTH = ( @CTRL, @UNI );

sub char_pool {
	return \@CTRL  if $mode eq 'control';
	return \@UNI   if $mode eq 'unicode';
	return \@BOTH;
}

# ── helpers ────────────────────────────────────────────────────────────────────

# Convert a raw byte string to $'...' escape notation (for array keys, stderr output)
sub bytes_to_escape {
	my ($bytes) = @_;
	my $decoded = $bytes;
	utf8::decode($decoded);
	my @codepoints = unpack( 'U*', $decoded );
	my @parts;
	for my $cp (@codepoints) {
		if ( $cp < 0x80 ) {
			push @parts, sprintf( '\\x%02x', $cp );
		} elsif ( $cp <= 0xFFFF ) {
			push @parts, sprintf( '\\u%04X', $cp );
		} else {
			push @parts, sprintf( '\\U%08X', $cp );
		}
	}
	return q{$'} . join( '', @parts ) . "'";
}

sub gen_name {
	my ($len, $pool) = @_;
	my $result = '';
	for ( 1 .. $len ) {
		$result .= $pool->[ rand @$pool ];
	}
	return $result;
}

# Names are opaque byte strings; base length on the num of codepoints they contain
sub name_codepoint_count {
	my ($name) = @_;
	my $decoded = $name;
	utf8::decode($decoded);
	return scalar( () = unpack( 'U*', $decoded ) );
}

sub read_all {
	local $/;
	my $fh = shift // \*STDIN;
	return scalar <$fh>;
}

# ── identifier collection ─────────────────────────────────────────────────────

sub collect_identifiers {
	my ($src) = @_;

	my %funcs;
	my %vars;

	my %builtins = map { $_ => 1 } qw(
		if then else elif fi case esac for while until do done
		in function select time coproc
		declare typeset local export readonly unset
		echo printf source . : true false
		break continue return exit shift
		set unset alias unalias
		let eval exec cd dirs popd pushd
		test [ [[
		trap type ulimit umask wait
		fg bg jobs disown kill
		read readarray mapfile
		enable disable compgen complete compopt
		getopts hash help history
		logout pwd suspend times
		bind caller command builtin shopt
	);

	# reserved variable names — never obfuscate
	my %reserved;
	$reserved{$_} = 1 for qw(
		BASH BASHOPTS BASHPID BASH_ALIASES BASH_ARGC BASH_ARGV
		BASH_CMDS BASH_COMMAND BASH_LINENO BASH_SOURCE BASH_SUBSHELL
		BASH_VERSINFO BASH_VERSION
		COMP_CWORD COMP_KEY COMP_LINE COMP_POINT COMP_TYPE
		COMP_WORDBREAKS COMP_WORDS
		COPROC DIRSTACK EUID FUNCNAME GROUPS HISTCMD HOSTNAME
		HOSTTYPE IFS LINENO LINES COLUMNS
		MACHTYPE MAPFILE OLDPWD OPTARG OPTIND OSTYPE
		PIPESTATUS PPID PS0 PS1 PS2 PS4 PWD RANDOM READLINE_LINE
		READLINE_MARK READLINE_POINT REPLY SECONDS SHELL SHELLOPTS
		SHLVL UID TERM USER HOME PATH LOGNAME
		0 1 2 3 4 5 6 7 8 9
		FUNCNEST GLOBIGNORE
	);
	$reserved{$_} = 1 for ( '_', '@', '?', '!', '#', q{$}, '-' );

	# function definitions: name() {
	while ( $src =~ /(?:^|;|&|\|\||&&|\n)[ \t]*(\w+)[ \t]*\([ \t]*\)[ \t]*\{/mg ) {
		my $name = $1;
		next if $builtins{$name};
		$funcs{$name} = 1;
	}

	# function definitions: function name {
	while ( $src =~ /(?:^|;|&|\|\||&&|\n)[ \t]*function[ \t]+(\w+)\b/mg ) {
		my $name = $1;
		next if $builtins{$name};
		$funcs{$name} = 1;
	}

	# variable references: ${var}
	while ( $src =~ /\$\{(\w+)/g ) {
		my $name = $1;
		next if $reserved{$name} || $name =~ /^\d+$/;
		$vars{$name} = 1;
	}

	# variable references: $var
	while ( $src =~ /\$(?![\{\(\'])([a-zA-Z_]\w*)/g ) {
		my $name = $1;
		next if $reserved{$name} || $funcs{$name};
		$vars{$name} = 1;
	}

	# variable assignments: var=  (but not ==)
	while ( $src =~ /
		(?:^|[;&\|\n]|(?<=\s))    # statement boundary
		[ \t]*
		(?:declare[ \t]+(?:-[a-zA-Z]+[ \t]+)*
		  |local[ \t]+(?:-[a-zA-Z]+[ \t]+)*
		  |export[ \t]+
		  |readonly[ \t]+
		  |typeset[ \t]+(?:-[a-zA-Z]+[ \t]+)*
		)?
		([a-zA-Z_]\w*)=          # name=
		(?!=)                     # but not ==
	/mgx ) {
		my $name = $1;
		next if $reserved{$name} || $builtins{$name};
		$vars{$name} = 1;
	}

	# var+= assignments
	while ( $src =~ /(?:^|[;&\|\n]|(?<=\s))[ \t]*([a-zA-Z_]\w*)\+=(?!=)/mg ) {
		my $name = $1;
		next if $reserved{$name} || $builtins{$name};
		$vars{$name} = 1;
	}

	# remove variables that share names with functions
	delete $vars{$_} for grep { $funcs{$_} } keys %vars;

	return ( \%funcs, \%vars );
}

# ── name generation ────────────────────────────────────────────────────────────

sub generate_names {
	my ( $funcs, $vars ) = @_;
	my $pool = char_pool();
	my %map;
	my %used;
	my @all_ids = ( keys %$funcs, keys %$vars );
	my $cp_len = 1;   # number of codepoints per name

	for my $id (@all_ids) {
		my $name;
		do {
			$name = gen_name( $cp_len, $pool );
		} while ( $used{$name} );
		$used{$name} = 1;
		$map{$id} = $name;

		# bump codepoint count once we've used ~80% of combinations at current length
		my $combos = scalar(@$pool) ** $cp_len;
		if ( scalar( keys %used ) >= int( $combos * 0.8 ) ) {
			$cp_len++;
		}
	}

	return \%map;
}

# ── transformation ─────────────────────────────────────────────────────────────

sub transform {
	my ( $src, $funcs, $vars, $map ) = @_;

	my $out = $src;

	# ── insert preamble (associative array for variable storage) ──
	if ( scalar keys %$vars ) {
		my $preamble = "declare -A ___=()\n";
		if ( $out =~ s/^(#!.*\n)/$1$preamble/ ) {
			# inserted after shebang
		} else {
			$out = $preamble . $out;
		}
	}

	# ── variable transformations ──
	# Process from longest name to shortest to avoid partial substitutions
	my @vnames = sort { length($b) <=> length($a) } keys %$vars;

	for my $vname (@vnames) {
		my $raw = $map->{$vname};
		my $esc = bytes_to_escape($raw);

		# 1a. ${#var} prefix-length → ${#___[$esc]}
		$out =~ s/\$\{#${vname}\}/\$\{#___\[${esc}\]\}/g;

		# 1b. ${var} with suffix → ${___[$esc]suffix}
		$out =~ s/\$\{${vname}([:#%\/\^,,\@\*\[][^}]*)\}/\$\{___\[${esc}\]$1\}/g;

		# 1c. ${var} without suffix → ${___[$esc]}
		$out =~ s/\$\{${vname}\}/\$\{___\[${esc}\]\}/g;

		# 2. $var → ${___[$esc]}  (exclude trailing word chars and { only)
		$out =~ s/(?<![\\\w])\$${vname}(?![\w\{])/\$\{___\[${esc}\]\}/g;

		# 3a.  local/declare/typeset/export/readonly var=value  →  ___[$esc]=value
		#      Strip the declaration keyword since ___ is already declared.
		$out =~ s/
			(                                      # $1: statement boundary
				(?:^|[;&\|\n])
				[ \t]*
			)
			(?:
				(?:declare|local|typeset)[ \t]+(?:-[a-zA-Z]+[ \t]+)*
				| export[ \t]+
				| readonly[ \t]+
			)
			[ \t]*
			${vname}=
		/${1}___\[${esc}\]=/gmx;

		# 3b. Plain var=value at statement boundary → ___[$esc]=value
		$out =~ s/
			(
				(?:^|[;&\|\n])
				[ \t]*
			)
			${vname}=
		/${1}___\[${esc}\]=/gmx;

		# 3c. Assignment inside subshell at statement boundary: ( var=value ... )
		$out =~ s/((?:^|[;&\|\n])\([ \t]*)${vname}=/${1}___\[${esc}\]=/gm;

		# 4. var+=value  →  ___[$esc]+=value
		$out =~ s/((?:^|[;&\|\n])[ \t]*)${vname}\+=/${1}___\[${esc}\]+=/gm;

		# 5. for varname in ...  →  for _ref in ... (handle separately since for-loop var
		#    receives values, we store with declare)
		#    We leave for-loop variables alone, they're part of bash syntax.

		# 6. bare var in $((arithmetic))  — not needed since $var already handled
		#    But inside ((...)) without $, like (( var++ ))
		$out =~ s/(?<=\(\([^\)]{0,120})\b${vname}\b(?![\w\[\'])/\$\{___\[${esc}\]\}/g;

		# 7. bare var in [[ test ]]
		$out =~ s/(?<=\[\[[^\]]{0,120})\b${vname}\b(?![\w\[\'])/\$\{___\[${esc}\]\}/g;
	}

	# ── function transformations ──
	my @fnames = sort { length($b) <=> length($a) } keys %$funcs;

	for my $fname (@fnames) {
		my $raw = $map->{$fname};

		# 1. name() {  →  raw_bytes() {
		$out =~ s/
			((?:^|;|&|\|\||\n)[ \t]*)
			${fname}
			([ \t]*\([ \t]*\)[ \t]*\{)
		/${1}${raw}${2}/gmx;

		# 2. function name {  →  function raw_bytes {
		$out =~ s/
			((?:^|;|&|\|\||\n)[ \t]*function[ \t]+)
			${fname}
			(\s*(?:\([ \t]*\))?[ \t]*\{)
		/${1}${raw}${2}/gmx;

		# 3. Function calls — raw_bytes at command position
		#    Match fname after statement separators
		$out =~ s/
			(
				(?:^|[;&\|\n])          # statement boundary
				[ \t]*
			|
				(?<=\b(?:do|then|else|if|while|until)\b)
				[ \t]+
			|
				(?<=\{)                 # after opening brace
				[ \t]+
			)
			\b${fname}\b
			(?=[ \t\n;&|)\]}])          # must be followed by space, newline, or statement end
		/${1}${raw}/gmx;

		# 4. Function calls inside $(...) command substitution
		$out =~ s/
			(?<=\$\([^)]{0,200})         # inside $(...), up to 200 chars
			(?<![_a-zA-Z0-9])
			${fname}
			(?=[ \t\n;&|)\]}'"])
		/${raw}/gx;

		# 5. Function calls inside `...` backtick substitution (if any remain)
		$out =~ s/
			(?<=`[^`]{0,200})
			(?<![_a-zA-Z0-9])
			${fname}
			(?=[ \t\n;&|)\]}'"])
		/${raw}/gx;
	}

	return $out;
}

# ── main ───────────────────────────────────────────────────────────────────────

binmode STDOUT, ':raw';
binmode STDERR, ':raw';

my $src = read_all();

my ( $funcs, $vars ) = collect_identifiers($src);

if ( !keys %$funcs && !keys %$vars ) {
	print $src;
	exit 0;
}

my $map = generate_names( $funcs, $vars );

# Report mapping to stderr in readable form (skip if -q)
if ( !$quiet ) {
	print STDERR "# obfuscated identifiers (mode=$mode):\n";
	for my $id ( sort keys %$map ) {
		my $kind = $funcs->{$id} ? "func" : "var ";
		printf STDERR "#   %s: %-20s -> %s\n", $kind, $id, bytes_to_escape( $map->{$id} );
	}
}

my $out = transform( $src, $funcs, $vars, $map );
print $out;
