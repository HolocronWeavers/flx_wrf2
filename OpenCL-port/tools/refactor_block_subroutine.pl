#!/usr/bin/perl
use warnings;
use strict;

=TODOs
- Create intermediate directories for converted files
- Determine if a subroutine argument is I, O or I/O
- Determine variables with same name as functions. F2C-ACC doesn't remove those, although it should.
- Refactor FUNCTIONS!!
- copy noop.f into the source tree if NOOP
- add a flag to swich NOOP on/off, use proper option parsing
=cut

=pod
Draft Outline  

0.2 Get rid of "common" variables, move them into function arguments 
		This is refactoring, and there is really only one proper way to do this:
		- parse the FORTRAN source in a labeled-block-aware way
		- check which variables from the common block are used
		- put them in the function signature
		- for variables declared outside the block in question, find the ones that are used within the block
		and add them to the function signature as well

Now, I don't have a full FORTRAN parser, but let's see what we can do with some limiting assumptions:
- assume the block is simply identified with a comment "C BEGIN blockname" and "C END blockname"
- assume any line starting with /^\s[\+\&]/ is a continuation line, deal with these first
- assume that _all_ variables in includecom are common, and _all_ variable in includepar are parameters?
That won't do. No, we read the includes, and parse the "common" blocks
- we're only really interested in a few specific intrinsic types: 
/(integer|real|double\s+precision|character\*?(?:\d+|\(\*\)))\s+(.+)\s*$/ 

The most difficult bit is finding the variables, I guess \W$varname\W should do?

With these assumptions, we can write a crude parser and function arg identifier as follows:
0. Slurp the source; strip the comments
1. Join up the continuation lines (maybe split lines with ; )
2. Parse the type declarations in the source, create a table %vars
3. Parse includes, recursively doing 0/1/2
4. For includes, parse common blocks, create %commons
5. Split the source based on the block markers
6. Identify which vars are used
	- in both => these become function arguments
	- only in "outer" => do nothing for those
	- only in "inner" => can be removed from outer variable declarations
7. Identify which commons are used in inner, make them function arguments

Not necessarily in this order:
8. When encountering a CALL, recurse and resolve globals (but only that)
9. When encountering a  function call, idem; although I'd prefer it if functions would be pure!
10. F2C-ACC is a bit buggy, so help it a bit: identify which CONTINUE statements are actually END DO
and replace them accordingly; for the other CONTINUE statements, it might be better to 
ensure that instead of CONTINUE, they do nothing in a different way. 
The only reliable way I found is to replace the continue with call noop, where noop is a subroutine that does nothing

How do we replace the args in a subroutine call?

- Find a subroutine call
- first check if we now about it by looking in a list of subroutine calls => We use 'IsSub'
- if we know it, it means we have resolved the globals, the list should be added to the node;
then just add the globals to the call
- otherwise, add the index in the list of source lines to a hash of subs 
- in fact, this can be a hash of "anythings", i.e.
 
    $stref->{'Nodes'}{$filename}{'SubroutineCall'}{$name}={'Pos'=>[$index,...],'Globals'=>[],...};
    
    As this is a "global", I need to pass it around between calls.
- recurse and figure out globals used. also, store the signature in the node hash
- add the globals to the end of the signature, and emit the new code.
- it would be nice to emit the code in a hash 

    $refactored_sources{$filename}=\@lines;
    
- return the list of all the globals to be added to the call
- update the call in %refactored_sources

    'Subroutines' => { 
                    $name => {
                       'Source' => $src,
                       'Lines' =>[$line],
                       'Blocks'=>{},
                       'HasBlocks'=>0|1
                       'Signature'=>{'Pos'=>[$index,...],'Globals'=>[],...};
                       'VarDecls'=>
                       'RefactoredCode' => {},    
                       'Status' => 0|1|2|3        
                     }
    }

Status: for programs, subroutines, functions and includes 
    0: after find_subroutines_and_includes() 
    1: after read_fortran_src()
    2: after parse_fortran_src()
    3: after create_subroutine_source_from_block()
After building this structure, what we need is to go through it an revert it so it becomes index => information

とにかく, コード　は:

=cut

use File::Find;
use File::Copy;
use Digest::MD5;
our $V = 0;
use Data::Dumper;

&main();

# -----------------------------------------------------------------------------
sub main {
	die "Please specifiy FORTRAN subroutine or program to refactor\n"
	  if not @ARGV;
	my $subname = $ARGV[0];

	my $stateref = {
		'Top'         => $subname,
		'Includes'    => {},
		'Subroutines' => {},
		'Indents'     => 0
	};

	# Find all subroutines in the source code tree
	$stateref = find_subroutines_and_includes($stateref);

# First we analyse the code for use of globals and blocks to be transformed into subroutines
	$stateref = parse_fortran_src( $subname, $stateref );

	#	show_info($stateref);

	# Refactor the source
	$stateref = refactor_all_subroutines($stateref);

	# Emit the refactored source
	emit_all($stateref);
	exit(0);

}    # END of main()

# -----------------------------------------------------------------------------
# -----------------------------------------------------------------------------
# This is the most important routine
# It parses the FORTRAN source as discussed above
# Identification of
# Signature
# VarDecl
# InBlock etc
# Includes

sub parse_fortran_src {
	( my $f, my $stref ) = @_;

	# Read the source and do some minimal processsing
	$stref = read_fortran_src( $f, $stref );

	my $is_incl = exists $stref->{'Includes'}{$f} ? 1 : 0;

	# 2. Parse the type declarations in the source, create a table %vars
	$stref = get_var_decls( $f, $stref );

	# 3. Parse includes, recursively doing 0/1/2
	if ( not $is_incl ) {

		#		die if $f eq 'timemanager';
		$stref = detect_blocks( $f, $stref );

		#		die Dumper($stref->{'Subroutines'}{'llij_lc'}) if $f=~/latlon_to_ij/;
		$stref = parse_includes( $f, $stref );

		$stref = parse_subroutine_calls( $f, $stref );
		$stref = identify_globals_used_in_subroutine( $f, $stref );

# 5. Split the source based on the block markers
# As there could be several blocks (later), use a hash per block
# This could happen in any file except includes; but include processing never comes here
		if ( $stref->{'Subroutines'}{$f}{'HasBlocks'} == 1 ) {
			$stref = separate_blocks( $f, $stref );
		}
		$stref = identify_loops_breaks( $f, $stref );
		$stref->{'Subroutines'}{$f}{'Status'} = 2;
	} else {    # includes
		 # 4. For includes, parse common blocks and parameters, create $stref->{'Commons'}
		$stref = get_commons_params_from_includes( $f, $stref );
	}

	#	for my $i ( keys %{ $stref->{'Subroutines'}{$f}{'Includes'} } ) {
	#		if ( $stref->{'Includes'}{$i}{'Type'} eq 'Common' ) {
	#			$stref->{'Subroutines'}{$f}{'HasCommons'} = 1;
	#			last;
	#		}
	#	}

	return $stref;

}    # END of parse_fortran_src()

# -----------------------------------------------------------------------------
sub refactor_globals {
	( my $stref, my $f, my $annlines ) = @_;
	my $rlines = [];
	my @globs  = ();
	for my $inc ( keys %{ $stref->{'Subroutines'}{$f}{'Globals'} } ) {
		@globs = ( @globs, @{ $stref->{'Subroutines'}{$f}{'Globals'}{$inc} } );
	}
	my %globals            = map { $_ => 1 } @globs;
	my %args               = ();
	my %conflicting_locals = ();
	for my $annline ( @{$annlines} ) {
		my $line      = $annline->[0] || '';
		my $tags_lref = $annline->[1];
		my %tags      = ( defined $tags_lref ) ? %{$tags_lref} : ();
		print '*** ' . join( ',', keys(%tags) ) . "\n" if $V;
		print '*** ' . $line . "\n" if $V;
		my $skip = 0;

		if ( exists $tags{'Signature'} ) {
			my $name = $tags{'Signature'}{'Name'};

			#                @orig_args = @{ $tags{'Signature'}{'Args'} };
			%args = map { $_ => 1 } @{ $tags{'Signature'}{'Args'} };

#                print STDERR "ARGS for $f: ",join(',',keys %args),"\n" if $f=~/particles_/;
			my @exglobs = ();
			for my $inc ( keys %{ $stref->{'Subroutines'}{$f}{'Globals'} } ) {
				print "INFO: INC $inc in $f\n" if $V;
				if ( not exists $stref->{'Includes'}{$inc}{'Root'} ) {
					die "$inc has no Root in $f";
				}
				if ( $stref->{'Includes'}{$inc}{'Root'} eq $f ) {
					print "INFO: $f is root for $inc\n" if $V;
					next;
				}
				@exglobs = (
					@exglobs, @{ $stref->{'Subroutines'}{$f}{'Globals'}{$inc} }
				);
			}
			print join( ',', @exglobs ), "\n" if $V;
			my $args_ref =
			  ordered_union( $tags{'Signature'}{'Args'}, \@exglobs );
			my $args_str = join( ',', @{$args_ref} );

			#                  die $args_str if $f =~/particles_main/;
			my $rline = '';
			if ( $stref->{'Subroutines'}{$f}{'Program'} ) {
				$rline = '      program ' . $name;
			} else {
				$rline = '      subroutine ' . $name . '(' . $args_str . ')';
			}

			#                my $rline =
			#                    '      subroutine '
			#                  . $name . '('
			#                  . join( ',', ( @orig_args, @exglobs ) ) . ')';
			$tags{'Refactored'} = 1;
			push @${rlines}, [ $rline, $tags_lref ];
			$skip = 1;
		}

		if ( exists $tags{'Include'} ) {
			my $inc = $tags{'Include'}{'Name'};
			print "INFO: INC $inc in $f\n" if $V;
			if (
				$stref->{'Includes'}{$inc}{'Type'} eq 'Common' and (
					$stref->{'Includes'}{$inc}{'Root'} ne $f

#                or ( ($stref->{'Includes'}{$inc}{'Root'} eq $f) and ($f eq $stref->{'Top'}))
				)
			  )
			{
				if ($V) {
					print "SKIPPED $inc: Root: ",
					  ( $stref->{'Includes'}{$inc}{'Root'} ne $f ) ? 0 : 1,
					  "\tTop:",
					  (       ( $stref->{'Includes'}{$inc}{'Root'} eq $f )
						  and ( $f eq $stref->{'Top'} ) ) ? 1 : 0, "\n";
				}
				$skip = 1;
			}
		}

		if ( exists $tags{'ExGlobVarDecls'} ) {

			# We abuse ExGlobVarDecls as a hook for the addional includes
			for my $inc ( keys %{ $stref->{'Subroutines'}{$f}{'Globals'} } ) {
				print "INC: $inc, root: $stref->{'Includes'}{$inc}{'Root'} \n"
				  if $V;
				if (    $stref->{'Subroutines'}{$f}{'Includes'}{$inc} < 0
					and $f eq $stref->{'Includes'}{$inc}{'Root'} )
				{   # and $f ne $stref->{'Top'}) { # FIXME: not sure about this!
					my $rline = "      include '$inc'";
					$tags_lref->{'Include'}{'Name'} = $inc;
					push @{$rlines}, [ $rline, $tags_lref ];
				}
			}

			for my $inc ( keys %{ $stref->{'Subroutines'}{$f}{'Globals'} } ) {
				print "INFO: GLOBALS from INC $inc in $f\n" if $V;
				for
				  my $var ( @{ $stref->{'Subroutines'}{$f}{'Globals'}{$inc} } )
				{
					if ( exists $args{$var} ) {
						my $rline = "*** ARG MASKS GLOB $var in $f!";
						push @{$rlines}, [ $rline, $tags_lref ];
					} else {
						if (
							exists $stref->{'Subroutines'}{$f}{'Commons'}
							{$inc} )
						{
							if ( $f ne $stref->{'Includes'}{$inc}{'Root'} ) {
								print "\tGLOBAL $var from $inc in $f\n" if $V;
								my $rline =
								  $stref->{'Subroutines'}{$f}{'Commons'}{$inc}
								  {$var}{'Decl'};
								if ( not defined $rline ) {
									print "*** NO DECL for $var in $f!\n" if $V;
									$rline = "*** NO DECL for $var in $f!";
								}
								push @{$rlines}, [ $rline, $tags_lref ];
							} elsif ($V) {
								print
"*** NO COMMONS from $inc because $f is Root\n";
								last;
							}
						} elsif ($V) {
							print "*** NO COMMONS for $inc in $f ";
							if ( $f eq $stref->{'Includes'}{$inc}{'Root'} ) {
								print '(Root)' . "\n";
							} else {
								print 'BUT NOT ROOT!' . "\n";
							}
							last;
						}
					}
				}    # for
			}
		}
		if ( exists $tags{'VarDecl'} ) {
			my @vars  = @{ $tags{'VarDecl'} };
			my $rline = $line;
			for my $var (@vars) {
				if ( exists $globals{$var} and not exists $args{$var} ) {
					print STDERR
"WARNING: local $var in $f ($stref->{'Subroutines'}{$f}{'Source'}) conflicts with global of same name, will be renamed to $var\_LOCAL\n";

# We should actually rename these conflicting vars, rather than removing them.
# The complication is that the global of the same name might have to be passed to a subroutine call
# So in each call we must check first for the local, then for the global
					my $nvar = $var . '_LOCAL';
					$conflicting_locals{$var} = $nvar;

					$rline =~ s/\b$var\b/$nvar/;
				}
			}
			$rline =~ s/,\s*$//;
			push @{$rlines}, [ $rline, $tags_lref ];
			$skip = 1;
		}
		if ( exists $tags{'SubroutineCall'} ) {

			#               print "SUBCALL: $line\n";
			# simply tag the common vars onto the arguments
			my $name    = $tags{'SubroutineCall'}{'Name'};
			my @globals = ();
			for my $inc ( keys %{ $stref->{'Subroutines'}{$name}{'Globals'} } )
			{
				next if $stref->{'Includes'}{$inc}{'Root'} eq $name;
				@globals = (
					@globals,
					@{ $stref->{'Subroutines'}{$name}{'Globals'}{$inc} }
				);
			}
			my $orig_args = [];
			for my $arg ( @{ $tags{'SubroutineCall'}{'Args'} } ) {
				if ( exists $conflicting_locals{$arg} ) {
					push @{$orig_args}, $conflicting_locals{$arg};
				} else {
					push @{$orig_args}, $arg;
				}
			}

			#                my @orig_args=@{$tags{'SubroutineCall'}{'Args'}};
			my $args_ref = ordered_union( $orig_args, \@globals );

			#                if (@globals && @orig_args) {unshift @globals,''}
			#                my $global_args_str = join(',',@globals);
			#                my $orig_args_str = join(',',@orig_args);
			my $args_str = join( ',', @{$args_ref} );
			$line =~ s/call\s.*$//;

   #                my $rline = "call $name($orig_args_str $global_args_str)\n";
			my $rline = "call $name($args_str)\n";
			push @{$rlines}, [ $line . $rline, $tags_lref ];
			$skip = 1;
		}
		if ( not exists $tags{'Comments'} and $skip == 0 ) {
			my $rline = $line;
			for my $lvar ( keys %conflicting_locals ) {
				if ( $rline =~ /\b$lvar\b/ ) {

#                   print  "REPLACING $lvar with $conflicting_locals{$lvar} in $f LINE '$line'\n";
					$rline =~ s/\b$lvar\b/$conflicting_locals{$lvar}/g;

					#                     print "NEW LINE: '$rline'\n";
				}
			}

#                if ($rline ne $line) {
#                   print STDERR "WARNING: renamed conflicting locals in $f, LINE $rline\n";
#                }
			push @{$rlines}, [ $rline, $tags_lref ];
			$skip = 1;
		}
		push @{$rlines}, $annline unless $skip;
	}
	return $rlines;
}    # END of refactor_globals()

# -----------------------------------------------------------------------------
sub refactor_blocks {
	( my $stref, my $f, my $annlines ) = @_;
	my $rlines = [];
	print "REFACTORING BLOCKS in $f\n" if $V;
	my @blocks = ();
	my $name   = 'NONE';
	for my $annline ( @{$annlines} ) {
		my $line      = $annline->[0];
		my $tags_lref = $annline->[1];
		my %tags =
		  ( defined $tags_lref )
		  ? %{$tags_lref}
		  : ( 'Nil' => [] );    # FIXME: needed?
		my $skip = 0;
		if ( exists $tags{'RefactoredSubroutineCall'} ) {
			$name = $tags{'RefactoredSubroutineCall'}{'Name'};
			$tags{'RefactoredSubroutineCall'}{'Args'} =
			  [ @{ $stref->{'Subroutines'}{$f}{'Blocks'}{$name}{'Args'} } ];
			push @blocks, $name;

			#we should refactor the block here to get the correct args
			#                $stref=$refactor_block_->($name,$f,$stref);
			my @args = @{ $stref->{'Subroutines'}{$name}{'Args'} };
			my $rline = 'C     call ' . $name . '(' . join( ',', @args ) . ')';
			$tags_lref = {%tags};
			delete $tags_lref->{'Comments'};
			push @{$rlines}, [ $rline, $tags_lref ];
			$skip = 1;
		}
		if ( exists $tags{'InBlock'} or exists $tags{'EndBlock'} ) {
			if ( $name ne 'NONE' ) {
				push @{ $stref->{'Subroutines'}{$f}{'Blocks'}{$name}{'Info'} },
				  $tags_lref;
			}
			$skip = 1;
		}
		push @{$rlines}, $annline unless $skip;
	}

	for my $name (@blocks) {
		$stref = create_subroutine_source_from_block( $name, $f, $stref );

		# Now we must parse this source
		$stref = get_var_decls( $name, $stref );

		#           $stref = detect_blocks( $name, $stref );
		$stref = parse_includes( $name, $stref );
		$stref = parse_subroutine_calls( $name, $stref );
		$stref = identify_globals_used_in_subroutine( $name, $stref );

		# Now we're ready to refactor this source
		$stref = refactor_subroutine( $name, $stref );    # shiver!
	}

	# Now go through the lines again and create the proper call
	#        $annlines=$rlines;
	for my $annline ( @{$rlines} ) {
		my $line      = $annline->[0];
		my $tags_lref = $annline->[1];
		my %tags =
		  ( defined $tags_lref )
		  ? %{$tags_lref}
		  : ( 'Nil' => [] );                              # FIXME: needed?
		if ( exists $tags{'RefactoredSubroutineCall'} ) {

			# simply tag the common vars onto the arguments
			my $name    = $tags{'RefactoredSubroutineCall'}{'Name'};
			my @globals = ();
			for my $inc ( keys %{ $stref->{'Subroutines'}{$name}{'Globals'} } )
			{
				next if $stref->{'Includes'}{$inc}{'Root'} eq $name;
				@globals = (
					@globals,
					@{ $stref->{'Subroutines'}{$name}{'Globals'}{$inc} }
				);
			}
			my $orig_args = [];

			# FIXME: do I need to check for conflicting locals?
			for my $arg ( @{ $tags{'RefactoredSubroutineCall'}{'Args'} } ) {

		  #                    if (exists $conflicting_locals{$arg}) {
		  #                        push @{$orig_args},$conflicting_locals{$arg};
		  #                    } else {
				push @{$orig_args}, $arg;

				#                    }
			}
			my $args_ref = ordered_union( $orig_args, \@globals );
			my $args_str = join( ',', @{$args_ref} );
			my $rline = "      call $name($args_str)";
			$annline->[0] = $rline;
		}
	}

	return ( $stref, $rlines );
}    # END of refactor_blocks()

# -----------------------------------------------------------------------------

#* BeginDo: just remove the label
#* EndDo: replace label CONTINUE by END DO
#* Break: keep as is; add a comment to identify it as a break
#* Goto: Do nothing        
#* GotoTarget: Do nothing
#* NoopBreakTarget: replace CONTINUE with "call noop"       
#* BreakTarget: Do nothing  
sub create_refactored_source {
	( my $stref, my $f, my $annlines ) = @_;
	print "CREATING FINAL $f CODE\n" if $V;
	my $rlines      = [];
	my @extra_lines = ();
	for my $annline ( @{$annlines} ) {
		my $line = $annline->[0] || '';    # FIXME: why would line be undefined?
		my $tags_lref = $annline->[1] || {};
		my %tags = %{$tags_lref};

		# BeginDo: just remove the label
		if ( exists $tags{'BeginDo'} ) {
			$line =~ s/do\s+\d+\s+/do /;
		}

# EndDo: replace label CONTINUE by END DO; if no continue, remove label & add end do on next line
		if ( exists $tags{'EndDo'} ) {
			my $is_goto_target = 0;
			if ( $stref->{'Subroutines'}{$f}{'Gotos'}
				{ $tags{'EndDo'}{'Label'} } )
			{
				# this is an end do which serves as a goto target
				$is_goto_target = 1;
			}
			my $count = $tags{'EndDo'}{'Count'};
			if ( $line =~ /^\s{0,4}\d+\s+continue/ ) {
				if ( $is_goto_target == 0 ) {
					$line = '      end do';
					$count--;
				} else {
					$line=~s/continue/call noop/;
				}
			} elsif ( $line =~ /^\d+\s+\w/ ) {
				if ( $is_goto_target == 0 ) {
					$line =~ s/^\d+//;
				}
			}
			while ( $count > 0 ) {
				push @extra_lines, '      end do';
				$count--;
			}
		}
        if ( exists $tags{'NoopBreakTarget'} ) {
        	$line=~s/continue/call noop/;
        }
        if ( exists $tags{'Break'} ) {
            $line.='  !Break';
        }
        
		if ( exists $tags{'PlaceHolders'} ) {
			my @phs = @{ $tags{'PlaceHolders'} };
			for my $ph (@phs) {
				my $str = $stref->{'Subroutines'}{$f}{'StringConsts'}{$ph};
				$line =~ s/$ph/$str/;
			}
		}
		if ( not exists $tags{'Comments'} ) {
			print $line, "\n" if $V;
			my @split_lines = split_long_line($line);
			for my $sline (@split_lines) {
				push @{ $stref->{'Subroutines'}{$f}{'RefactoredCode'} }, $sline;
			}
			if (@extra_lines) {
				for my $extra_line (@extra_lines) {
					push @{ $stref->{'Subroutines'}{$f}{'RefactoredCode'} },
					  $extra_line;
				}
				@extra_lines = ();
			}
		} else {
			push @{ $stref->{'Subroutines'}{$f}{'RefactoredCode'} }, $line;
		}
	}
	return $stref;
}    # END of create_refactored_source()

# -----------------------------------------------------------------------------

=info_refactoring

for every line
- check if it needs changing:
- need to mark the insert points for subroutine calls that replace the refactored blocks! 
This is a node called 'RefactoredSubroutineCall'
- we also need the "entry point" for adding the declarations for the localized global variables 'ExGlobVarDecls'

* Signature: add the globals to the signature
(* VarDecls: keep as is)
* ExGlobVarDecls: add new var decls
* SubroutineCall: add globals for that subroutine to the call
* RefactoredSubroutineCall: insert a new subroutine call instead of the "begin of block" comment. 
* InBlock: skip; we need to handle the blocks separately
* BeginBlock: insert the new subroutine signature and variable declarations
* EndBlock: insert END
                      

=cut

sub refactor_subroutine {
	( my $f, my $stref ) = @_;
	if ($V) {
		print "\n\n";
		print "#" x 80, "\n";
		print "Refactoring $f\n";
		print "#" x 80, "\n";
	}

	#    print STDERR "REFACTORING $f\n";
	#print Dumper($stref->{'Subroutines'}{$f}{'Info'}) if $f eq 'llij_lc';
	my @lines = @{ $stref->{'Subroutines'}{$f}{'Lines'} };
	my @info =
	  defined $stref->{'Subroutines'}{$f}{'Info'}
	  ? @{ $stref->{'Subroutines'}{$f}{'Info'} }
	  : ();
	my $annlines = [];
	for my $line (@lines) {
		my $tags = shift @info;
		push @{$annlines}, [ $line, $tags ];
	}

	my $rlines = $annlines;

	if ( $stref->{'Subroutines'}{$f}{'HasCommons'} ) {
		$rlines = refactor_globals( $stref, $f, $annlines );
	}

	if ( $stref->{'Subroutines'}{$f}{'HasBlocks'} == 1 ) {
		( $stref, $rlines ) = refactor_blocks( $stref, $f, $rlines );
	}    # HasBlocks

	if ( not exists $stref->{'Subroutines'}{$f}{'RefactoredCode'}
		or $stref->{'Subroutines'}{$f}{'RefactoredCode'} == [] )
	{
		$stref = create_refactored_source( $stref, $f, $rlines );

#    $annlines = $rlines;
#    $rlines   = [];
#    my @extra_lines=();
#    for my $annline ( @{$annlines} ) {
#        my $line      = $annline->[0] || ''; # FIXME: why would line be undefined?
#        my $tags_lref = $annline->[1] || {};
#        my %tags      = %{$tags_lref};
## BeginDo: just remove the label
		#        if (exists $tags{'BeginDo'}) {
		#        	$line=~s/do\s+\d+\s+/do /;
		#        }
## EndDo: replace label CONTINUE by END DO; if no continue, remove label & add end do on next line
#        if (exists $tags{'EndDo'}) {
#        	my $is_goto_target=0;
#        	if ($stref->{'Subroutines'}{$f}{'Gotos'}{$tags{'EndDo'}{'Label'}}) {
#        		# this is an end do which serves as a goto target
#        		$is_goto_target=1;
#        	}
#        	my $count =$tags{'EndDo'}{'Count'};
#        	if ($line=~/^\d+\s+continue/) {
#        		if ($is_goto_target==0) {
#                $line='      end do';
#                $count--;
#        		}
#        	} elsif ($line=~/^\d+\s+\w/) {
#        		if ($is_goto_target==0) {
#        		$line=~s/^\d+//;
#        		}
#        	}
#            while($count>0) {
#            	push @extra_lines,'      end do';
#            	$count--;
#            }
#        }
#
#        if (exists $tags{'PlaceHolders'}) {
#            my @phs=@{$tags{'PlaceHolders'}};
#            for my $ph (@phs) {
#                my $str=$stref->{'Subroutines'}{$f}{'StringConsts'}{$ph};
#                $line=~s/$ph/$str/;
#            }
#        }
#        if ( not exists $tags{'Comments'} ) {
#            print $line,"\n" if $V;
#            my @split_lines = split_long_line($line);
#            for my $sline (@split_lines) {
#                push @{ $stref->{'Subroutines'}{$f}{'RefactoredCode'} }, $sline;
#            }
#            if (@extra_lines) {
#                for my $extra_line (@extra_lines) {
#                	push @{ $stref->{'Subroutines'}{$f}{'RefactoredCode'} }, $extra_line;
#                }
#                @extra_lines=();
#            }
#        } else {
#            push @{ $stref->{'Subroutines'}{$f}{'RefactoredCode'} }, $line;
#        }
#    }
	}

#    print STDERR "REFACTORED $f\n";
#    print STDERR Dumper($stref->{'Subroutines'}{$f}{'RefactoredCode'}) if $f eq 'particles_main_loop';
	return $stref;
}    # END of refactor_subroutine()

# -----------------------------------------------------------------------------
sub refactor_all_subroutines {
	( my $stref ) = @_;

	#	print Dumper(keys %{ $stref->{'Subroutines'} });
	for my $f ( keys %{ $stref->{'Subroutines'} } ) {

		if ( not defined $stref->{'Subroutines'}{$f}{'Status'} ) {
			$stref->{'Subroutines'}{$f}{'Status'} = 0;
			print STDERR "WARNING: no Status for $f\n";
			print "WARNING: no Status for $f\n";
		}
		next                    if $stref->{'Subroutines'}{$f}{'Status'} == 0;
		warn "Not parsed: $f\n" if $stref->{'Subroutines'}{$f}{'Status'} == 1;
		next                    if $stref->{'Subroutines'}{$f}{'Status'} == 3;
		$stref = refactor_subroutine( $f, $stref );
	}

	return $stref;
}    # END of refactor_all_subroutines()

# -----------------------------------------------------------------------------
sub emit_refactored_subroutine {
	( my $f, my $dir, my $stref ) = @_;
	my $srcref = $stref->{'Subroutines'}{$f}{'RefactoredCode'};
	my $s      = $stref->{'Subroutines'}{$f}{'Source'};
	print "INFO: emitting refactored code for $f in $s\n" if $V;
	my $mode = '>';
	if ( -e "$dir/$s" ) {
		$mode = '>>';
	}
	open my $SRC, $mode, "$dir/$s" or die $!;
	if ( $mode eq '>>' ) {
		print $SRC "\n*** SUBROUTINE $f ***\n";
	}
	for my $line ( @{$srcref} ) {
		print $SRC "$line\n";
		print "$line\n" if $V;
	}
	close $SRC;
}    # END of emit_refactored_subroutine()

# -----------------------------------------------------------------------------
sub emit_all {
	( my $stref ) = @_;
	my $dir = '../RefactoredSources';
	if ( not -e $dir ) {
		mkdir $dir;
		my @incs = glob('include*');
		map { copy( $_, "$dir/$_" ) } @incs; # Perl::Critic wants a for-loop, drat it
	} elsif ( not -d $dir ) {
		die "$dir exists but is not a directory!\n";
	} else {
		my @oldsrcs = glob("$dir/*.f");
		map { unlink $_ } @oldsrcs;

		# Check if includes have changed
		my @incs = glob('include*');
		for my $inc (@incs) {
			open( my $OLD, $inc );
			binmode($OLD);
			open( my $NEW, $inc );
			binmode($NEW);
			if ( Digest::MD5->new->addfile($OLD)->hexdigest ne
				Digest::MD5->new->addfile($NEW)->hexdigest )
			{
				copy( $inc, "$dir/$inc" );
			}
			close $OLD;
			close $NEW;
		}
	}
	for my $f ( keys %{ $stref->{'Subroutines'} } ) {
		emit_refactored_subroutine( $f, $dir, $stref );
	}

	# copy functions
	my %funcsrcs = ();
	for my $func ( keys %{ $stref->{'Functions'} } ) {
		$funcsrcs{ $stref->{'Functions'}{$func}{'Source'} } = 1;
	}
	for my $funcsrc ( keys %funcsrcs ) {
		copy( $funcsrc, "$dir/$funcsrc" );
	}
}    # END of emit_all()

# -----------------------------------------------------------------------------

sub parse_subroutine_calls {
	( my $f, my $stref ) = @_;
	print "PARSING SUBROUTINE CALLS in $f\n" if $V;
	my $src     = $stref->{'Subroutines'}{$f}{'Source'};
	my $nspaces = 64 - $stref->{'Indents'} - length($f);    # -length($src) -2;
	print ' ' x $stref->{'Indents'}, $f, ' ' x $nspaces, $src, "\n";
	my $srcref = $stref->{'Subroutines'}{$f}{'Lines'};
	if ( defined $srcref ) {
		my %child_include_count = ();
		my %called_subs         = ();
		for my $index ( 0 .. scalar( @{$srcref} ) - 1 ) {
			my $line = $srcref->[$index];
			next if $line =~ /^C\s+/;

			#			warn "$line\n" if $f eq 'readwind';
			if ( $line =~ /call\s(\w+)\((.*)\)/ || $line =~ /call\s(\w+)\s*$/ )
			{
				my $name = $1;

				#				warn "\tCALLING $name\n";
				my $argstr = $2 || '';
				if ( $argstr =~ /^\s*$/ ) {
					$argstr = '';
				}
				$called_subs{$name} = $name;
				$stref->{'Subroutines'}{$f}{'Info'}
				  ->[$index]{'SubroutineCall'}{'Args'} = $argstr;

# auxgrid,wetgridn(ix,jy,k,nage), wetgridsigman(ix,jy,k,nage),nclassunc,itime,idt(j),uap(j),ucp(j),uzp(j), us(j),vs(j),ws(j),xtra1(j),ytra1(j),ztra1(j),cbt(j)
				my $tvarlst = $argstr;
				if ( $tvarlst =~ /\(((?:[^\(\),]*?,)+[^\(]*?)\)/ ) {
					while ( $tvarlst =~ /\(((?:[^\(\),]*?,)+[^\(]*?)\)/ ) {
						my $chunk  = $1;
						my $chunkr = $chunk;
						$chunkr =~ s/,/;/g;
						my $pos = index( $tvarlst, $chunk );
						substr( $tvarlst, $pos, length($chunk), $chunkr );
					}
				}

				my @tvars   = split( /\s*\,\s*/, $tvarlst );
				my $p       = '';
				my @argvars = ();
				for my $var (@tvars) {
					$var =~ s/^\s+//;
					$var =~ s/\s+$//;
					$var =~ s/;/,/g;
					push @argvars, $var;
				}

				$stref->{'Subroutines'}{$f}{'Info'}
				  ->[$index]{'SubroutineCall'}{'Args'} = \@argvars;
				$stref->{'Subroutines'}{$f}{'Info'}
				  ->[$index]{'SubroutineCall'}{'Name'} = $name;
				if ( $stref->{'Subroutines'}{$name}{'Status'} < 2 ) {
					print "\tCALL $name\n" if $V;

					# Propagating down includes
					for my $inc (
						keys %{ $stref->{'Subroutines'}{$f}{'Includes'} } )
					{
						if (
							not
							exists $stref->{'Subroutines'}{$name}{'Includes'}
							{$inc} )
						{
							print "Propagating DOWN $inc from $f to $name\n"
							  if $V;
							$stref->{'Subroutines'}{$name}{'Includes'}{$inc} =
							  -3;
						} else {
							print
"NO NEED TO propagate DOWN $inc from $f to $name\n"
							  if $V;
						}
					}

					#					print "Processing SUBROUTINE $name\n" if $V;
					$stref->{'Indents'} += 4;
					$stref = parse_fortran_src( $name, $stref );
					$stref->{'Indents'} -= 4;

					#					$stref->{'Subroutines'}{$name}{'Status'}=2;
					print "Postprocessing INCLUDES for $name\n" if $V;
					for my $inc (
						keys %{ $stref->{'Subroutines'}{$name}{'Includes'} } )
					{
						if ( $stref->{'Includes'}{$inc}{'Type'} eq 'Common' ) {
							$child_include_count{$f}{$inc}++;

#                    	   print $child_include_count{$f}{$inc};
#                    	   print '<>',join(',',keys %{ $stref->{'Subroutines'}{$f}{'Includes'} })," in $f\n";
						}
					}

				}
			}
		}
		print "ANALYZING called subs in $f\n" if $V;
		my %globs         = ();
		my @child_is_root = ();
		for my $inc ( keys %{ $child_include_count{$f} } ) {
			if ( not exists $stref->{'Subroutines'}{$f}{'Includes'}{$inc} ) {
				if ( $child_include_count{$f}{$inc} == 1 ) {
					push @child_is_root, $inc;
				} elsif ( $child_include_count{$f}{$inc} > 1 ) {
					print
"INFO: $inc occurs in more than one child, not present in parent => make parent $f root\n"
					  if $V;
					$stref->{'Includes'}{$inc}{'Root'} = $f;
					$stref->{'Subroutines'}{$f}{'Includes'}{$inc} = -1;
				}
			}
		}

		for my $name ( keys %called_subs ) {
			my $root_inc = '';
			for my $inc (@child_is_root) {
				if ( exists $stref->{'Subroutines'}{$name}{'Includes'}{$inc} ) {
					$stref->{'Includes'}{$inc}{'Root'} = $name;
					$root_inc = $inc;
					print "INFO: $name is root for $inc\n" if $V;
				}
			}
			for my $inc ( keys %{ $stref->{'Subroutines'}{$name}{'Globals'} } )
			{
				next if $inc eq $root_inc;
				$globs{$inc} =
				  union( $globs{$inc},
					$stref->{'Subroutines'}{$name}{'Globals'}{$inc} );
			}
		}
		for my $inc ( keys %{ $stref->{'Subroutines'}{$f}{'Includes'} } ) {
			print "INFO: $inc in $f\n" if $V;
			next unless $stref->{'Includes'}{$inc}{'Type'} eq 'Common';
			if ( exists $stref->{'Subroutines'}{$f}{'Globals'}{$inc} ) {
				$stref->{'Subroutines'}{$f}{'Globals'}{$inc} =
				  union( $stref->{'Subroutines'}{$f}{'Globals'}{$inc},
					$globs{$inc} );
			} else {
				$stref->{'Subroutines'}{$f}{'Globals'}{$inc} = $globs{$inc};
			}
		}
	}

	#	die if $f eq 'readwind';
	return $stref;
}    # END of parse_subroutine_calls()

# -----------------------------------------------------------------------------
# Identify which globals from the includes are used in the subroutine
sub identify_globals_used_in_subroutine {
	( my $f, my $stref ) = @_;
	my $srcref = $stref->{'Subroutines'}{$f}{'Lines'};
	if ( defined $srcref ) {
		my %commons = ();
		print "COMMONS ANALYSIS in $f\n" if $V;
		if ( not exists $stref->{'Subroutines'}{$f}{'Commons'} ) {
			for my $inc ( keys %{ $stref->{'Subroutines'}{$f}{'Includes'} } ) {

				if ( $stref->{'Includes'}{$inc}{'Type'} eq 'Common' ) {
					print "COMMONS from $inc in $f? " if $V;

# WRONG: The 'Root' here is a guess, I should not rely on it!
#	            if ($stref->{'Includes'}{$inc}{'Root'} ne $f or
#	            ($stref->{'Includes'}{$inc}{'Root'} eq $f and $f eq $stref->{'Top'})
#	            ) {
#	            	print "YES\n" if $V;
					$commons{$inc} = $stref->{'Includes'}{$inc}{'Commons'};

#	            } elsif ($V) {
#	            	print "NO:";
#                    print  "\tRoot: ",($stref->{'Includes'}{$inc}{'Root'} eq $f)?1:0 ;
#                    print  "\tTop: ",($f eq $stref->{'Top'})?1:0,"\n";
#	            }
				}
			}
			$stref->{'Subroutines'}{$f}{'Commons'}    = \%commons;
			$stref->{'Subroutines'}{$f}{'HasCommons'} = 1;
		} else {
			print "already done\n" if $V;
			%commons = %{ $stref->{'Subroutines'}{$f}{'Commons'} };
		}
		my $first = 1;
		for my $inc ( keys %commons ) {
			print "\nGLOBAL VAR ANALYSIS for $inc in $f\n" if $V;
			my @inherited_globs =
			  ( defined $stref->{'Subroutines'}{$f}{'Globals'}{$inc} )
			  ? @{ $stref->{'Subroutines'}{$f}{'Globals'}{$inc} }
			  : ();
			my @globs = ();
			my %tvars = %{ $commons{$inc} };
			for my $index ( 0 .. scalar( @{$srcref} ) - 1 ) {
				my $line = $srcref->[$index];
				if ( $line =~ /^C\s+/ ) {
					next;
				}

				# We shouldn't look for globals in the declarations, silly!
				if ( $line =~
/(logical|integer|real|double\s+precision|character|character\*?(?:\d+|\(\*\)))\s+(.+)\s*$/
				  )
				{
					next;
				}

				# FIXME: Not sure why this is done here?
				if ( $first && $line =~ /^\s+subroutine\s+(\w+)\((.*)\)/ ) {
					my $name   = $1;
					my $argstr = $2;
					$argstr =~ s/^\s+//;
					$argstr =~ s/\s+$//;
					my @args = split( /\s*,\s*/, $argstr );

#					print "ARGS FOR $f ($inc): <",join(',',@args),">\n" if $V and $f=~/particles_/;
#	                print STDERR "ARGS for $f ($inc): <",join(',',@args),">\n" if $V and $f=~/particles_/;
					$stref->{'Subroutines'}{$f}{'Info'}
					  ->[$index]{'Signature'}{'Args'} = \@args;
					$stref->{'Subroutines'}{$f}{'Info'}
					  ->[$index]{'Signature'}{'Name'} = $name;
				}
				if ( $first && $line =~ /^\s+program\s+(\w+)\s*$/ ) {
					my $name = $1;
					$stref->{'Subroutines'}{$f}{'Info'}
					  ->[$index]{'Signature'}{'Args'} = [];
					$stref->{'Subroutines'}{$f}{'Info'}
					  ->[$index]{'Signature'}{'Name'} = $name;
				}

				#	            # Need to skip literal strings and formats!
				#	            my $tline=$line;
				#	            while ($tline=~/\'.+?\'/) {
				#	                $tline=~s/\'.*?\'//;
				#	            }
				my @chunks = split( /\W+/, $line );
				for my $mvar (@chunks) {

#				next if $mvar =~/\b(?:if|then|do|goto|integer|real|call|\d+)\b/; # is slower!
# if a var on a line is declared locally, it is obviously not a global!
					if ( exists $tvars{$mvar}
						and not $stref->{'Subroutines'}{$f}{'Vars'}{$mvar} )
					{
						print "FOUND global $mvar in $line\n" if $V;
						push @globs, $mvar;
						delete $tvars{$mvar};
					}
				}
			}    # for each line
			@globs = @{ union( \@globs, \@inherited_globs ) };
			if ($V) {
				print "\nALL GLOBAL VARS from $inc in subroutine $f:\n\n";
				for my $var (@globs) {
					print "$var\n";
				}
				print "\n";
			}
			$stref->{'Subroutines'}{$f}{'Globals'}{$inc} = \@globs;
			$first = 0;
		}
	}
	return $stref;
}    # END of identify_globals_used_in_subroutine()

# -----------------------------------------------------------------------------
sub detect_blocks {
	( my $s, my $stref ) = @_;
	print "CHECKING BLOCKS in $s\n" if $V;
	$stref->{'Subroutines'}{$s}{'HasBlocks'} = 0;
	my $srcref = $stref->{'Subroutines'}{$s}{'Lines'};
	for my $line ( @{$srcref} ) {
		if ( $line =~ /^C\s/i ) {
			if ( $line =~ /^C\s+BEGIN\sSUBROUTINE\s(\w+)/ ) {
				$stref->{'Subroutines'}{$s}{'HasBlocks'} = 1;
				print "SUB $s HAS BLOCK: $1\n" if $V;
				last;
			}
		}
	}
	return $stref;
}    # END of detect_blocks()

# -----------------------------------------------------------------------------
sub create_subroutine_source_from_block {
	( my $f, my $p, my $stref ) = @_;
	print "CREATING SOURCE for $f\n" if $V;

	#        print STDERR "KEYS in $p\n";
	#        for my $k (sort keys %{$stref->{'Subroutines'}{$p}}) {
	#        	print STDERR "$k\n";
	#        };

	my @lines = @{ $stref->{'Subroutines'}{$p}{'Blocks'}{$f}{'Lines'} };
	my @info  = @{ $stref->{'Subroutines'}{$p}{'Blocks'}{$f}{'Info'} };

	#	    my $annlines = [];
	my $index = 0;

	my $rlines = [];
	push @{$rlines}, $stref->{'Subroutines'}{$p}{'Blocks'}{$f}{'Sig'};
	$stref->{'Subroutines'}{$f}{'Info'}->[$index]{'Signature'}{'Name'} = $f;
	$stref->{'Subroutines'}{$f}{'Info'}->[$index]{'Signature'}{'Args'} =
	  $stref->{'Subroutines'}{$p}{'Blocks'}{$f}{'Args'};
	$index++;
	for my $inc (
		keys %{ $stref->{'Subroutines'}{$p}{'Blocks'}{$f}{'Includes'} } )
	{
		push @{$rlines}, "        include '$inc'";
		$stref->{'Subroutines'}{$f}{'Info'}->[$index]{'Include'}{'Name'} = $inc;
		$index++;
	}
	my $first = 1;
	for my $decl ( @{ $stref->{'Subroutines'}{$p}{'Blocks'}{$f}{'Decls'} } ) {
		my $var = shift @{ $stref->{'Subroutines'}{$p}{'Blocks'}{$f}{'Args'} };
		push @{$rlines}, "  $decl";
		if ( $first == 1 ) {
			$stref->{'Subroutines'}{$f}{'Info'}->[$index]{'ExGlobVarDecls'} =
			  {};
			$first = 0;
		}
		$stref->{'Subroutines'}{$f}{'Info'}->[$index]{'VarDecl'} = [$var];
		$index++;
	}
	for my $line (@lines) {
		push @{$rlines}, $line;
		my $tags_lref = shift @info;
		$stref->{'Subroutines'}{$f}{'Info'}->[$index] = $tags_lref;
		$index++;
	}
	push @{$rlines}, '      end';
	$stref->{'Subroutines'}{$f}{'Lines'} = $rlines;

	#        $stref->{'Subroutines'}{$f}{'Info'} =[];
	$stref->{'Subroutines'}{$f}{'Status'}    = 3;
	$stref->{'Subroutines'}{$f}{'HasBlocks'} = 0;
	$stref->{'Subroutines'}{$f}{'Program'}   = 0;
	$stref->{'Subroutines'}{$f}{'StringConsts'} =
	  $stref->{'Subroutines'}{$p}{'StringConsts'};
	$stref->{'Subroutines'}{$f}{'Source'} =
	  $stref->{'Subroutines'}{$p}{'Source'};
	if ($V) {
		@lines = @{ $stref->{'Subroutines'}{$f}{'Lines'} };
		@info  = @{ $stref->{'Subroutines'}{$f}{'Info'} };
		my $annlines = [];
		for my $line (@lines) {
			my $tags = shift @info;
			push @{$annlines}, [ $line, $tags ];
		}
		for my $annline ( @{$annlines} ) {
			my $line      = $annline->[0] || '';
			my $tags_lref = $annline->[1];
			my %tags      = ( defined $tags_lref ) ? %{$tags_lref} : ();
			print '*** ' . join( ',', keys(%tags) ) . "\n" if $V;
			print '*** ' . $line . "\n" if $V;
		}
	}

	#         print STDERR "KEYS in $f\n";
	#        for my $k (sort keys %{$stref->{'Subroutines'}{$f}}) {
	#            print STDERR "$k\n";
	#        };

	return $stref;
}    # END of create_subroutine_source_from_block()

# -----------------------------------------------------------------------------

sub parse_includes {
	( my $f, my $stref ) = @_;
	print "PARSING INCLUDES for $f\n" if $V;
	my $srcref = $stref->{'Subroutines'}{$f}{'Lines'};
	for my $index ( 0 .. scalar( @{$srcref} ) - 1 ) {
		my $line = $srcref->[$index];
		if ( $line =~ /^C\s+/ or $line =~ /^\!\s/ ) {
			next;
		}

		if ( $line =~ /^\s*include\s+\'(\w+)\'/ )
		{    # TODO: nested includes not supported!

			my $name = $1;
			print "FOUND include $name in $f\n" if $V;
			$stref->{'Subroutines'}{$f}{'Includes'}{$name} = $index;
			$stref->{'Subroutines'}{$f}{'Info'}->[$index]{'Include'}{'Name'} =
			  $name;
			if ( $stref->{'Includes'}{$name}{'Status'} == 0 ) {
				print $line, "\n" if $V;

				# Initial guess for Root
				$stref->{'Includes'}{$name}{'Root'}      = $f;
				$stref->{'Includes'}{$name}{'HasBlocks'} = 0;
				$stref = parse_fortran_src( $name, $stref );
			} else {
				print $line, " already processed\n" if $V;
			}
		}
	}

	return $stref;
}    # END of parse_includes()

# -----------------------------------------------------------------------------

sub get_var_decls {
	( my $f, my $stref ) = @_;

	my $is_incl = exists $stref->{'Includes'}{$f} ? 1 : 0;
	my $sub_or_incl = $is_incl ? 'Includes' : 'Subroutines';

	my $srcref = $stref->{$sub_or_incl}{$f}{'Lines'};
	if ( defined $srcref ) {
		print "\nVAR DECLS in $f:\n" if $V;
		my %vars  = ();
		my $first = 1;
		for my $index ( 0 .. scalar( @{$srcref} ) - 1 ) {
			my $line = $srcref->[$index];

			#			print $line,"\n";
			#            $stref->{$sub_or_incl}{$f}{'Info'}->[$index]={};
			if ( $line =~ /^C\s+/ ) {
				next;
			}
			if ( $line =~ /^\!\s/ ) {
				$stref->{$sub_or_incl}{$f}{'Info'}
				  ->[$index]{'TrailingComments'} = {};
				next;
			}

			# real surfstrn(0:nxmaxn-1,0:nymaxn-1,1,2,maxnests)
			if ( $line =~
/(logical|integer|real|double\s+precision|character|character\*?(?:\d+|\(\*\)))\s+(.+)\s*$/
			  )
			{
				my $type    = $1;
				my $varlst  = $2;
				my $tvarlst = $varlst;

				if ( $tvarlst =~ /\(((?:[^\(\),]*?,)+[^\(]*?)\)/ ) {
					while ( $tvarlst =~ /\(((?:[^\(\),]*?,)+[^\(]*?)\)/ ) {
						my $chunk  = $1;
						my $chunkr = $chunk;
						$chunkr =~ s/,/;/g;
						my $pos = index( $tvarlst, $chunk );
						substr( $tvarlst, $pos, length($chunk), $chunkr );
					}
				}

				my @tvars    = split( /\s*\,\s*/, $tvarlst );
				my $p        = '';
				my @varnames = ();
				for my $var (@tvars) {
					$var =~ s/^\s+//;
					$var =~ s/\s+$//;
					my $tvar = $var;
					$tvar =~ s/\(.*?\)/(0)/g;
					if ( $tvar =~ s/\(.*?\)// ) {
						$tvar =~ s/\*\d+//
						  ;    # FIXME: char string handling is not correct!
						$vars{$tvar}{'Kind'} = 'Array';
						$p = '()';
					} else {
						$vars{$tvar}{'Kind'} = 'Scalar';
					}
					$vars{$tvar}{'Type'} = $type;
					$var =~ s/;/,/g;
					$vars{$tvar}{'Decl'} = "        $type $var"
					  ; # TODO: this should maybe not be a textual representation
					push @varnames, $tvar;
				}
				print "\t", join( ',', @varnames ), "\n" if $V;

				#              print "$f : $sub_or_incl; $index\n" if $V;
				$stref->{$sub_or_incl}{$f}{'Info'}->[$index]{'VarDecl'} =
				  \@varnames;
				if ($first) {
					$first = 0;
					$stref->{$sub_or_incl}{$f}{'Info'}
					  ->[$index]{'ExGlobVarDecls'} = {};
				}
			}

		}

		$stref->{$sub_or_incl}{$f}{'Vars'} = \%vars;
	}

	return $stref;
}    # END of get_var_decls()

# -----------------------------------------------------------------------------

sub get_commons_params_from_includes {
	( my $f, my $stref ) = @_;
	my $srcref = $stref->{'Includes'}{$f}{'Lines'};
	if ( defined $srcref ) {
		my %vars        = %{ $stref->{'Includes'}{$f}{'Vars'} };
		my $has_pars    = 0;
		my $has_commons = 0;

		for my $index ( 0 .. scalar( @{$srcref} ) - 1 ) {
			my $line = $srcref->[$index];
			if ( $line =~ /^C\s+/ ) {
				next;
			}
			if ( $line =~ /^\s*common\s+\/[\w\d]+\/\s+(.+)$/ ) {
				my $commonlst = $1;
				$has_commons = 1;
				my @tcommons = split( /\s*\,\s*/, $commonlst );
				for my $var (@tcommons) {
					if ( not defined $vars{$var} ) {
						print STDERR "MISSING: <", $var, ">\n";
					} else {
						print $var, "\t", $vars{$var}{'Type'}, "\n" if $V;
						$stref->{'Includes'}{$f}{'Commons'}{$var} = $vars{$var};
					}
				}
				$stref->{'Includes'}{$f}{'Info'}->[$index]{'Common'} = {};
			}

			if ( $line =~ /parameter\s*\(\s*(.*)\s*\)/ ) {

				my $parliststr = $1;
				$has_pars = 1;
				my @partups = split( /\s*,\s*/, $parliststr );
				my @pvars =
				  map { s/\s*=.+//; $_ } @partups;    # Perl::Critic, EYHO

				for my $var (@pvars) {
					if ( not defined $vars{$var} ) {
						print STDERR "NOT A PARAMETER: <", $var, ">\n";
					} else {
						$stref->{'Includes'}{$f}{'Parameters'}{$var} =
						  $vars{$var};
					}
				}
				$stref->{'Includes'}{$f}{'Info'}->[$index]{'Parameter'} = {};
			}
		}

		if ($V) {
			print "\nCOMMONS for $f:\n\n";
			for my $v ( sort keys %{ $stref->{'Includes'}{$f}{'Commons'} } ) {
				print $v, "\n";
			}
		}

		# FIXME!
		# An include file should basically only contain parameters and commons.
		# If it contains commons, we should remove them!
		if ( $has_commons && $has_pars ) {
			die
"The include file $f contains both parameters and commons, this is not yet supported.\n";
		} elsif ($has_commons) {
			$stref->{'Includes'}{$f}{'Type'} = 'Common';
		} elsif ($has_pars) {
			$stref->{'Includes'}{$f}{'Type'} = 'Parameter';
		} else {
			$stref->{'Includes'}{$f}{'Type'} = 'None';
		}
		for my $var ( keys %vars ) {
			if (
				(
					$has_pars
					and not
					exists( $stref->{'Includes'}{$f}{'Parameters'}{$var} )
				)
				or ( $has_commons
					and not exists( $stref->{'Includes'}{$f}{'Commons'}{$var} )
				)
			  )
			{
				warn Dumper( $stref->{'Includes'}{$f}{'Lines'} );
				die
"The include $f contains a variable $var that is neither a parameter nor a common variable, this is not supported\n";
			}
		}
	}
	return $stref;
}    # END of get_commons_params_from_includes()

# -----------------------------------------------------------------------------

sub separate_blocks {
	( my $f, my $stref ) = @_;

	my $srcref   = $stref->{'Subroutines'}{$f}{'Lines'};
	my %vars     = %{ $stref->{'Subroutines'}{$f}{'Vars'} };
	my %occs     = ();
	my %blocks   = ();
	my $in_block = 0;
	my $block    = 'OUTER';
	for my $index ( 0 .. scalar( @{$srcref} ) - 1 ) {
		my $line = $srcref->[$index];

		if ( $line =~ /^C\s+BEGIN\sSUBROUTINE\s(\w+)/ ) {
			$in_block = 1;
			$block    = $1;
			push @{ $blocks{'OUTER'} }, $line;
			$stref->{'Subroutines'}{$f}{'Info'}
			  ->[$index]{'RefactoredSubroutineCall'}{'Name'} = $block;
			$stref->{'Subroutines'}{$f}{'Info'}
			  ->[$index]{'BeginBlock'}{'Name'} = $block;
			next;
		}
		if ( $line =~ /^C\s+END\sSUBROUTINE\s(\w+)/ ) {
			$in_block = 0;
			$block    = $1;
			push @{ $blocks{$block} }, $line;
			$stref->{'Subroutines'}{$f}{'Info'}->[$index]{'EndBlock'}{'Name'} =
			  $block;
			next;
		}
		if ($in_block) {
			push @{ $blocks{$block} }, $line;
			$stref->{'Subroutines'}{$f}{'Info'}->[$index]{'InBlock'}{'Name'} =
			  $block;
		} else {
			push @{ $blocks{'OUTER'} }, $line;
		}
	}

	for my $block ( keys %blocks ) {
		next if $block eq 'OUTER';
		$stref->{'Subroutines'}{$f}{'Blocks'}{$block}{'Lines'} =
		  $blocks{$block};
		$stref->{'Subroutines'}{$f}{'Blocks'}{$block}{'Source'} =
		  $stref->{'Subroutines'}{$f}{'Source'};
	}

  # So now we have split the file in blocks, we have identified the common vars.

# 6. Identify which vars are used
#   - in both => these become function arguments
#   - only in "outer" => do nothing for those
#   - only in "inner" => can be removed from outer variable declarations
# Find all vars used in each block, starting with the outer block
# It is best to loop over all vars per line per block, because we can remove the encountered vars
	for my $block ( keys %blocks ) {
		my @lines = @{ $blocks{$block} };
		my %tvars = %vars;                  # Hurray for pass-by-value!
		print "\nVARS in $block:\n\n" if $V;

		# FIXME: rework as in identify_globals_used_in_subroutine()
		for my $line (@lines) {
			my $tline = $line;
			$tline =~ s/\'.+?\'//;
			for my $var ( keys %tvars ) {
				if ( $tline =~ /\W$var\W/ or $tline =~ /\W$var\s*$/ ) {
					print "FOUND $var\n" if $V;
					$occs{$block}{$var} = $var;
					delete $tvars{$var};
				}
			}
		}

		#		$stref->{'Subroutines'}{$block}{'Occs'} = $occs{$block};
	}

 #	my %args = ();
 #	for my $block ( keys %occs ) {
 #		next if $block eq 'OUTER';
 #		print "\nARGS for $block:\n" if $V;
 #		for my $var ( keys %{ $occs{$block} } ) {
 #			if ( exists $occs{'OUTER'}{$var} ) {
 #				print "$var\n" if $V;
 #				push @{ $args{$block} }, $var;
 #			}
 #		}
 #	}
 # WV: we do this later
 #	# 7. Identify which commons are used in inner, make them function arguments
 #	# This is the same as in remove_globals
 #       my %commons=();
 #        for my $i ( keys %{ $stref->{'Subroutines'}{$f}{'Includes'} } ) {
 #            if ( $stref->{'Includes'}{$i}{'Type'} eq 'Common' ) {
 #                %commons=(%commons, %{ $stref->{'Includes'}{$i}{'Commons'} });
 #            }
 #        }
 #	   $stref->{'Subroutines'}{$f}{'Commons'}=\%commons;
 #	# This is almost the same as above
 #	for my $block ( keys %blocks ) {
 #		next if $block eq 'OUTER';
 #		my @lines = @{ $blocks{$block} };
 #        my @tvars=keys %commons;
 #		for my $line (@lines) {
 #			for my $var ( @tvars ) {
 #				next if not defined $var;
 #				if ( $line =~ /\W$var\W/ ) {
 #					push @{ $args{$block} }, $var;
 #					undef $var;
 #				}
 #			}
 #		}
 #		if ($V) {
 #			print "\nCOMMON VARS in block $block:\n\n";
 #			for my $var ( @{ $args{$block} } ) {
 #				print "$var\n";
 #			}
 #		}
 #		$stref->{'Subroutines'}{$block}{'Args'} = $args{$block};
 #	}

	# Construct the subroutine signatures
	my %args = ();
	for my $block ( keys %blocks ) {
		next if $block eq 'OUTER';

		print "\nARGS for BLOCK $block:\n" if $V;
		for my $var ( keys %{ $occs{$block} } ) {
			if ( exists $occs{'OUTER'}{$var} ) {
				print "$var\n" if $V;
				push @{ $args{$block} }, $var;
			}
		}
		$stref->{'Subroutines'}{$block}{'Args'} = $args{$block};
		my $sig   = "      subroutine $block(";
		my $decls = [];
		for my $argv ( @{ $args{$block} } ) {
			$sig .= "$argv,";
			my $decl = $vars{$argv}{'Decl'};    #|| $commons{$argv}{'Decl'};
			push @{$decls}, $decl;
		}
		$sig =~ s/\,$/)\n/s;
		$stref->{'Subroutines'}{$f}{'Blocks'}{$block}{'Args'}  = $args{$block};
		$stref->{'Subroutines'}{$f}{'Blocks'}{$block}{'Sig'}   = $sig;
		$stref->{'Subroutines'}{$f}{'Blocks'}{$block}{'Decls'} = $decls;

#        $stref->{'Subroutines'}{$f}{'Blocks'}{$block}{'Lines'} = $blocks{$block};
#        $stref->{'Subroutines'}{$f}{'Blocks'}{$block}{'Source'} = $stref->{'Subroutines'}{$f}{'Source'};
		for my $inc ( keys %{ $stref->{'Subroutines'}{$f}{'Includes'} } ) {

			#        	if($stref->{'Subroutines'}{$f}{'Includes'}{$inc}!=-1) {
			$stref->{'Subroutines'}{$f}{'Blocks'}{$block}{'Includes'}{$inc} =
			  -2;

			#        	}
		}
		if ($V) {
			print $sig, "\n";
			print join( "\n", @{$decls} ), "\n";
		}
	}

	return $stref;
}    # END of separate_blocks()

# -----------------------------------------------------------------------------
sub identify_loops_breaks {
	( my $f, my $stref ) = @_;

	my $srcref = $stref->{'Subroutines'}{$f}{'Lines'};

	my %do_loops = ();
	my %gotos    = ();
	my $nest     = 0;
	for my $index ( 0 .. scalar( @{$srcref} ) - 1 ) {
		my $line = $srcref->[$index];
		next if $line =~ /^C\s+/;

		# BeginDo:
		$line =~ /^\s+do\s+(\d+)\s+\w/ && do {
			my $label = $1;
			$stref->{'Subroutines'}{$f}{'Info'}->[$index]{'BeginDo'}{'Label'} =
			  $label;
			if ( not exists $do_loops{$label} ) {
				@{ $do_loops{$label} } = ( [$index], $nest );
				$nest++;
			} else {
				push @{ $do_loops{$label}[0] }, $index;

#        		print STDERR "WARNING: $f: Found duplicate label $label at: ".join(',',@{ $do_loops{$label}[0] })."\n";
			}
			next;
		};

		# Goto
		$line =~ /^\s+.*?[\)\ ]\s*goto\s+(\d+)\s*$/ && do {
			my $label = $1;
			$stref->{'Subroutines'}{$f}{'Info'}->[$index]{'Goto'}{'Label'} =
			  $label;
			$stref->{'Subroutines'}{$f}{'Gotos'}{$label} = 1;
			@{ $gotos{$label} } = ( $index, $nest );
			next;
		};

		# continue can be end of do loop or break target (amongs others?)
		$line =~ /^\s{0,4}(\d+)\s+(continue|\w)/ && do {
			my $label = $1;
			my $is_cont = $2 eq 'continue' ? 1 : 0;
			if ( exists $do_loops{$label} ) {
				if ( $nest == $do_loops{$label}[1] + 1 ) {
					$stref->{'Subroutines'}{$f}{'Info'}
					  ->[$index]{'EndDo'}{'Label'} = $label;
					$stref->{'Subroutines'}{$f}{'Info'}
					  ->[$index]{'EndDo'}{'Count'} =
					  scalar @{ $do_loops{$label}[0] };
					delete $do_loops{$label};
					$nest--;
				} else {
					print STDERR
"WARNING: $f: Found continue for label $label but nesting level is wrong: $nest<>$do_loops{$label}[1]\n";
				}
			} elsif ( exists $gotos{$label} ) {
				my $target = 'GotoTarget';
				if ( $nest <= $gotos{$label}[1] ) {
					if ($is_cont) {
						$target = 'NoopBreakTarget';
						$stref->{'Subroutines'}{$f}{'Info'}
						  ->[ $gotos{$label}[0] ]{'Break'}{'Label'} = $label;
					} else {
						$target = 'BreakTarget';
						$stref->{'Subroutines'}{$f}{'Info'}
						  ->[ $gotos{$label}[0] ]{'Break'}{'Label'} = $label;

#                    	print STDERR "WARNING: $f: Found BREAK target not NOOP for label $label\n";
					}
				} else {
					print STDERR
"WARNING: $f: Found GOTO target not BREAK for label $label: wrong nesting $nest<>$gotos{$label}[1]\n";
				}
				$stref->{'Subroutines'}{$f}{'Info'}
				  ->[$index]{$target}{'Label'} = $label;
				delete $gotos{$label};

			}
			next;
		};

   # When an open() fails, you can pass a label to some place for error handling
   # Some evil code combines this end-of-do-block labels
		$line =~ /^\s+open.*?\,\s*err\s*=\s*(\d+)\s*\)/ && do {
			my $label = $1;
			$stref->{'Subroutines'}{$f}{'Gotos'}{$label} = 1;
			next;
		};
	}
	return $stref;
}    # END of identify_loops_breaks()

# -----------------------------------------------------------------------------
# This subroutine reads the FORTRAN source and does very little else:
# - it combines continuation lines in a single line
# - it lowercases everything
# - it detects and normalises comments
# - it detects block markers (for factoring blocks out into subs)
# The routine is called by parse_fortran_src()
# A better way is to extract all subs in a single pass
# I guess the best wat is to first join the lines, then separate the subs
sub read_fortran_src {
	( my $s, my $stref ) = @_;

	my $is_incl = exists $stref->{'Includes'}{$s} ? 1 : 0;
	my $sub_or_incl = $is_incl ? 'Includes' : 'Subroutines';
	my $f = $is_incl ? $s : $stref->{'Subroutines'}{$s}{'Source'};

	#    warn "$s: $f,",$stref->{$sub_or_incl}{$s}{'Status'},"\n";
	#    die "$f: $sub_or_incl $s" if $f=~/map_proj_wrf_subaa/;
	if ( $stref->{$sub_or_incl}{$s}{'Status'} == 0 ) {
		my $ok = 1;
		open my $SRC, '<', $f or do {
			print STDERR "Can't find '$f' ($s)\n";
			$ok = 0;
		};
		if ($ok) {
			print "READING SOURCE for $f\n" if $V;
			local $V = 0;
			my $lines    = [];
			my $prevline = '';

			# 0. Slurp the source; standardise the comments
			# 1. Join up the continuation lines
			# TODO: split lines with ;
			# TODO: Special case: comments in continuation lines.
			# For now, I just throw them away.
			my $cont = 0;

			my %strconsts             = ();
			my @phs                   = ();
			my @placeholders_per_line = ();
			my $ct                    = 0;

			my $line = '';
			while (<$SRC>) {
				$line = $_;
				chomp $line;

				# Skip blanks
				$line =~ /^\s*$/ && next;

				# Detect and standardise comments
				if ( $line =~ /^[CD\*\!]/i or $line =~ /^\ {6}\s*\!/i ) {
					$line =~ s/^\s*[CcDd\*\!]/C /;
				} elsif ( $line =~ /\s+\!.*$/ )
				{    # FIXME: trailing comments are discarded!
					my $tline = $line;
					$tline =~ s/\'.+?\'//;
					if ( $tline =~ /\s+\!.*$/ ) {

				  # convert trailing comments into comments on the previous line
						( $line, my $comment ) = split( /\s+\!/, $line );
					}
				}

				if ( $line =~ /^\ {5}[^0\s]/ ) {    # continuation line
					$line =~ s/^\s{5}.\s*/ /;
					$prevline .= $line;
					$cont = 1;
				} elsif ( $line =~ /^\&/ ) {
					$line =~ s/^\&\t*/ /;
					$prevline .= $line;
					$cont = 1;
				} elsif ( $line =~ /^\t[1-9]/ ) {
					$line =~ s/^\t[0-9]/ /;
					$prevline .= $line;
					$cont = 1;
				} elsif ( $prevline =~ /\&\s&$/ ) {
					$prevline =~ s/\&\s&$//;
					$prevline .= $line;
					$cont = 1;
				} elsif ( $line =~ /^C\ / && ( $cont == 1 ) ) {

					# A comment occuring after a continuation line. Skip!
					next;
				} else {

 #                    warn "TAB FORMAT for $prevline ?\n" if $prevline =~/9100/;
 #                    ($prevline=~/^\t/ || $prevline=~/^\d+\t/ ) && do {
 #                        warn "TAB FORMAT for $prevline\n" ;
 #                    };
					my $sixspaces = ' ' x 6;
					$prevline =~ s/^\t/$sixspaces/;
					$prevline =~ /^(\d+)\t/ && do {
						my $label  = $1;
						my $ndig   = length($label);
						my $spaces = ' ' x ( 6 - $ndig );
						my $str    = $label . $spaces;
						$prevline =~ s/^(\d+)\t/$str/;
					};
					if ( substr( $prevline, 0, 2 ) ne 'C ' ) {
						if ( $prevline !~ /^\s+include\s+\'/i ) {

							# replace string constants by placeholders
							while ( $prevline =~ /(\'.*?\')/ ) {
								my $strconst = $1;
								my $ph       = '__PH' . $ct . '__';
								push @phs, $ph;
								$strconsts{$ph} = $strconst;
								$prevline =~ s/\'.*?\'/$ph/;
								$ct++;
							}
						}

	 # remove trailing comments
	 #	               	( $prevline, my $comment ) = split( /\s+\!/, $prevline );
					}
					my $lcprevline =
					  ( substr( $prevline, 0, 2 ) eq 'C ' )
					  ? $prevline
					  : lc($prevline);
					$lcprevline =~ s/__ph(\d+)__/__PH$1__/g;

					#	                  warn "$lcprevline\n";
					push @{$lines}, $lcprevline;
					push @placeholders_per_line, [@phs];
					@phs      = ();
					$prevline = $line;
					$cont     = 0;
				}
			}

			# There can't be strings on the last line (except in a include?)
			if ( $line ne $prevline )
			{    # Too weak, if there are comments in between it breaks!
				my $lcprevline =
				  ( substr( $prevline, 0, 2 ) eq 'C ' )
				  ? $prevline
				  : lc($prevline);
				push @{$lines}, $lcprevline;
			}
			my $lcline = ( substr( $line, 0, 2 ) eq 'C ' ) ? $line : lc($line);
			push @{$lines}, $lcline;
			push @placeholders_per_line, [];
			push @placeholders_per_line, [];
			close $SRC;

			#	        die if $f =~ /coordtrafo/;
			#	        die Dumper($lines) if $f =~ /coordtrafo/;
			my $name = 'NONE';
			my $ok   = 0;
			if ($is_incl) {
				$ok                                  = 1;
				$name                                = $s;
				$stref->{$sub_or_incl}{$s}{'Status'} = 1;
			}
			my $index = 0;
			for my $line ( @{$lines} ) {
				my $phs_ref = shift @placeholders_per_line;

#	        	print STDERR '[',join(',',@{$phs_ref}),"]\n";
# If it's a subroutine source, skip all lines before the matching subroutine signature
#and all lines from (and including) the next non-matching subroutine signature
				if (   $is_incl == 0
					&& $line =~ /^\s+(?:program|subroutine)\s+(\w+)/ )
				{
					$name = $1;

					#	            	warn "\t$name\n";
					$ok                                           = 1;
					$index                                        = 0;
					$stref->{$sub_or_incl}{$name}{'Status'}       = 1;
					$stref->{$sub_or_incl}{$name}{'HasBlocks'}    = 0;
					$stref->{$sub_or_incl}{$name}{'StringConsts'} = \%strconsts
					  ; # Means we have all consts in the file, not just the sub, but who cares?
				}
				if ( $ok == 1 ) {
					push @{ $stref->{$sub_or_incl}{$name}{'Lines'} }, $line;
					if ( $line =~ /^C/ ) {
						$stref->{$sub_or_incl}{$name}{'Info'}
						  ->[$index]{'Comments'} = {};
					}
					$stref->{$sub_or_incl}{$name}{'Info'}->[$index] =
					  { 'PlaceHolders' => $phs_ref }
					  if @{$phs_ref};
					$index++;
				}

			}
		}    # if OK
	}    # if Status==0

#    die Dumper($stref->{$sub_or_incl}{'xymeter_to_ll_wrf'}) if $f=~/map_proj_wrf.f/;
	return $stref;
}    # END of read_fortran_src()

# -----------------------------------------------------------------------------
# Find all source files in the current directory
sub find_subroutines_and_includes {
	my $stref = shift;
	my $dir   = '.';
	my $ext   = '.f';

	# find sources (borrowed from PerlMonks)
	my %src_files = ();
	my $tf_finder = sub {
		return if !-f;
		return if !/\.f$/;
		$src_files{$File::Find::name} = 1;
	};
	find( $tf_finder, $dir );

	for my $src ( keys %src_files ) {
		open my $SRC, '<', $src;
		while ( my $line = <$SRC> ) {

			# Skip blanks
			$line =~ /^\s*$/ && next;

			# Detect and standardise comments
			$line =~ /^[C\*\!]/i && next;
			$line =~ /^\s+(subroutine|program)\s+(\w+)/i && do {
				my $is_prog = $1 eq 'program' ? 1 : 0;
				if ( $is_prog == 1 ) {
					print "Found program $2 in $src\n" if $V;
				}
				my $sub = lc($2);
				if (
					not exists $stref->{'Subroutines'}{$sub}{'Source'}
					or (    $src =~ /$sub\.f/
						and $stref->{'Subroutines'}{$sub}{'Source'} !~
						/$sub\.f/ )
				  )
				{
					if (    exists $stref->{'Subroutines'}{$sub}{'Source'}
						and $src =~ /$sub\.f/
						and $stref->{'Subroutines'}{$sub}{'Source'} !~
						/$sub\.f/ )
					{
						print STDERR "WARNING: Ignoring source "
						  . $stref->{'Subroutines'}{$sub}{'Source'}
						  . " because source $src matches subroutine name $sub.\n";
					}
					$stref->{'Subroutines'}{$sub}{'Source'}  = $src;
					$stref->{'Subroutines'}{$sub}{'Status'}  = 0;
					$stref->{'Subroutines'}{$sub}{'Program'} = $is_prog;
				} else {
					print STDERR
"WARNING: Ignoring source $src for $sub because another source, "
					  . $stref->{'Subroutines'}{$sub}{'Source'}
					  . " exists.\n";
				}
			};
			$line =~ /^\s*include\s+\'(\w+)\'/ && do {
				my $inc = $1;
				if ( not exists $stref->{'Includes'}{$inc} ) {
					$stref->{'Includes'}{$inc}{'Status'} = 0;
				}
			};
			$line =~ /^\s*\w*\s+function\s+(\w+)/i && do {
				my $func = $1;
				$stref->{'Functions'}{$func}{'Source'} = $src;
			};

		}
		close $SRC;
	}
	return $stref;
}    # END of find_subroutines_and_includes()

# -----------------------------------------------------------------------------
# -----------------------------------------------------------------------------
sub show_info {
	( my $stref ) = @_;
	if ($V) {
		print "\n\n";
		print "#" x 80, "\n";
		print "Info\n";
		print "#" x 80, "\n\n";
	}

	for my $f ( keys %{ $stref->{'Subroutines'} } ) {

		if (    exists $stref->{'Subroutines'}{$f}{'Lines'}
			and exists $stref->{'Subroutines'}{$f}{'Info'} )
		{
			print "\nSUBROUTINE: $f\n\n";

			#           die Dumper($stref->{'Subroutines'}{$f}{'Info'});
			my @lines = @{ $stref->{'Subroutines'}{$f}{'Lines'} };
			my @info  = @{ $stref->{'Subroutines'}{$f}{'Info'} };
			if ( scalar(@lines) != scalar(@info) ) {
				die scalar(@lines) . '!=' . scalar(@info) . " for $f";
			} else {

				for my $i ( 0 .. @lines - 1 ) {
					my $line = $lines[$i];
					my $item = $info[$i];
					if ( defined $item ) {
						print $line, "\t\t**** ";
						print join( ',', keys %{$item} ), "\n";
					}
				}
				print "\n";
			}
		} else {
			print "WARNING: No info for $f\n";
		}

	}

}

# -----------------------------------------------------------------------------
sub insert_lines {
	( my $lref, my $srcref, my $idx ) = @_;    # \@lines, \@src_lines, $idx;
	my $nsrc = [ @{$srcref} ];
	splice( @{$nsrc}, $idx, 0, @{$lref} );
	return $nsrc;
}    # END of insert_lines()

# -----------------------------------------------------------------------------

=info2
We also need a convenience function to split long lines.
- count the number of characters, i.e. length()
- find the last comma before we exceed 64 characters (I guess it's really 72-5?):
=cut

sub split_long_line {
	my $line=shift;
	my @chunks = @_;

	my $nchars = 64;
	if ( scalar(@chunks) == 0 ) {
		print "\nLINE: \n$line\n" if $V;
		$nchars = 72;
	}
	my $split_on  = ',';
	my $split_on2 = ' ';
	my $split_on3 = '.ro.';
	my $split_on4 = '.dna.';

	my $smart = 0;
	if ( length($line) > $nchars ) {
		my $patt  = '';
		my $ll    = length($line);
		my $rline = join( '', reverse( split( '', $line ) ) );

		#		print $rline,"\n";
		#		print "$ll - $nchars = ",$ll - $nchars,"\n";
		my $idx  = index( $rline, $split_on,  $ll - $nchars );
		my $idx2 = index( $rline, $split_on2, $ll - $nchars );
		my $idx3 = index( $rline, $split_on3, $ll - $nchars );
		my $idx4 = index( $rline, $split_on4, $ll - $nchars );
		if ( $idx < 0 && $idx2 < 0 && $idx3 < 0 && $idx4 < 0 ) {
			warn "WARNING: Can't split line \n$line\n" if $V;
		} elsif ( $idx >= 0 ) {
			print "Split line on ", $ll - $idx, ", '$split_on'\n" if $V;
		} elsif ( $idx < 0 && $idx2 >= 0 ) {
			$idx = $idx2;
			print "Split line on ", $ll - $idx2, ", '$split_on2'\n" if $V;
		} elsif ( $idx < 0 && $idx2 < 0 && $idx3 >= 0 ) {
			$idx = $idx3;
			print "SPLIT line on ", $ll - $idx, ", '$split_on3'\n" if $V;

			# Need smarter split
			$smart = 1;
			$patt = join( '', reverse( split( '', $split_on3 ) ) );
		} elsif ( $idx < 0 && $idx2 < 0 && $idx4 >= 0 ) {
			$idx = $idx4;
			print "SPLIT line on ", $ll - $idx, ", '$split_on4'\n" if $V;

			# Need smarter split
			$smart = 1;
			$patt = join( '', reverse( split( '', $split_on4 ) ) );
		}

#		if ($smart==1) {
#			die substr( $line, 0, $ll - $idx3, '' ) if length(substr( $line, 0, $ll - $idx3, '' ))>$nchars;
#		}
		push @chunks, substr( $line, 0, $ll - $idx, '' );
		print "CHUNKS:\n", join( "\n", @chunks ), "\n" if $V;
		print "REST:\n", $line, "\n" if $V;
		&split_long_line( $line, @chunks );
	} else {
		push @chunks, $line;

		my @split_lines = ();
		if ( @chunks > 1 ) {
			my $fst = 1;
			for my $chunk (@chunks) {
				if ($fst) {
					$fst = 0;
				} else {
					if ( $chunk =~ /^\s*$/ ) {
						$chunk = '';
					} else {

						#						$chunk = '     &  ' . $chunk;
						$chunk = '     &' . $chunk;
					}
				}
				push @split_lines, $chunk;
			}
		} else {
			@split_lines = @chunks;
		}
		return @split_lines;
	}	
}

# -----------------------------------------------------------------------------
sub union {
	( my $aref, my $bref ) = @_;
	my %as = map { $_ => 1 } @{$aref};
	for my $elt ( @{$bref} ) {
		$as{$elt} = 1;
	}
	my @us = sort keys %as;
	return \@us;
}    # END of union()

# -----------------------------------------------------------------------------
# This union is obtained by removing duplicates from @b. It is a bit slower but preserves the order
sub ordered_union {
	( my $aref, my $bref ) = @_;
	my @us = @{$aref};
	my %as = map { $_ => 1 } @{$aref};
	for my $elt ( @{$bref} ) {
		if ( not exists $as{$elt} ) {
			push @us, $elt;
		}
	}
	return \@us;
}    # END of ordered_union()

# -----------------------------------------------------------------------------
