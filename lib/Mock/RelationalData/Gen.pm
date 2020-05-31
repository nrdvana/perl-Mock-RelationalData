package Mock::RelationalData::Gen;
use Exporter::Extensible -exporter_setup => 1;
use Mock::RelationalData::SetPicker;
use Carp;

=head1 EXPORTS

=head2 compile_generator

  my $gen_or_scalar= compile_generator($specification);

This interprets a generator specification and either returns a coderef or returns
a plain scalar (constant).

Generator specifications are handled as follows:

=over

=item Plain Scalar

If the string contains a C<< {...} >> notation, the template is converted into a coderef.
Else the sclaar is returned as-is.

=item SCALAR ref

The referenced scalar is returned as-is. (no template substitutions)

=item CODE ref

The code ref is assumed to be a generator and is returned as-is.

=item ARRAY ref

The array is assumed to be equal-weighted items, and are converted to a
L<Mock::RelationalData::SetPicker>.  Each item is recursively processed.

=back

=cut

sub compile_generator($) :Export {
	my $spec= shift;
	if (!ref $spec) {
		return compile_template($spec);
	} elsif (ref $spec eq 'SCALAR') {
		return $$spec;
	} elsif (ref $spec eq 'CODE' or ref($spec)->can('evaluate')) {
		return $spec;
	} elsif (ref $spec eq 'ARRAY') {
		return Mock::RelationalData::SetPicker->new_uniform($spec);
	} else {
		croak "Don't know how to compile $spec";
	}
}

=head2 weighted_set

Shortcut for L<Mock::RelationalData::SetPicker/new_weighted>.

=cut

sub weighted_set :Export {
	return Mock::RelationalData::SetPicker->new_weighted(@_);
}

=head2 compile_template

Convert a template into a generator coderef, unless the scalar lacks any calls
to other generators in which case this returns the scalar.

=cut

sub compile_template :Export {
	my ($tpl, $flags)= @_;
	# Split the template on each occurrence of "{...}" but respect nested {}
	my @parts= split /(
		\{\}                # empty braces
		|
		\{ \w               # or braces that begin with word char
			(?:
				(?> [^{}]+ )    # span of non-brace (no backtracking)
				|
				(?1)            # or recursive match of whole pattern
			)*
		\}
		)/x, $tpl;
	# Convert the odd-indexed elements (contents of {...}) into calls to generators
	for (my $i= 1; $i < @parts; $i += 2) {
		if ($parts[$i] eq '{}') {
			$parts[$i]= '';
			next;
		}
		my ($gen_name, $named_args, @list_args)= _parse_template_call(substr $parts[$i], 1, -1);
		# Replace the template notation with a coderef
		$parts[$i]= sub {
			# $_[0] is $reldata.   $_[1] is \%named_args from caller of generator.
			my $generator= $_[0]->generators->{$gen_name} || croak "No such generator $gen_name";
			# The @args we parsed get added to the \%args passed to the function on each call
			$generator->($_[0], $named_args? { %{$_[1]}, %$named_args } : $_[1], @list_args);
		};
	}
	# Remove any empty strings from @parts
	@parts = grep ref || length, @parts;
	return
		# No parts? generate empty string.
		!@parts? ''
		# One part of plain scalar? return it.
		: @parts == 1 && !ref $parts[0]? $parts[0]
		# Error context requested?
		: ($flags && $flags->{add_err_context})? sub {
			my $ret;
			local $@;
			eval {
				$ret= join '', map +(ref $_? $_->(@_) : $_), @parts;
				1;
			} or do {
				$@ =~ s/$/ for template '$tpl'/m;
				croak "$@";
			};
			$ret;
		}
		# One part which is already a generator?
		: @parts == 1? $parts[0]
		# Multiple parts get concatenated, while calling nested generators
		: sub { join '', map +(ref $_? $_->(@_) : $_), @parts };
}

sub _parse_template_call {
	my $spec= shift;
	(my $gen_name, $spec)= split / +/, $spec, 2;
	my (%named_args, @list_args);
	for (split / +/, $spec) {
		if ($_ =~ /^([^=]+)=(.*)/) {
			$named_args{$1}= $2;
		} else {
			push @list_args, $_;
		}
	}
	return $gen_name, \%named_args, @list_args;
}

1;