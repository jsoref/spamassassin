=head1 NAME

Mail::SpamAssassin::MIME::Parser - parse, decode, and render MIME body parts

=head1 SYNOPSIS

=head1 DESCRIPTION

This module will take a RFC2822-esque formatted message and create
an object with all of the MIME body parts included.  Those parts will
be decoded as necessary, and text/html parts will be rendered into a
standard text format, suitable for use in SpamAssassin.

=head1 METHODS

=over 4

=cut

package Mail::SpamAssassin::MIME::Parser;
use strict;

use Mail::SpamAssassin;
use Mail::SpamAssassin::MIME;
use Mail::SpamAssassin::HTML;
use MIME::Base64;
use MIME::QuotedPrint;

=item parse()

Unlike most modules, Mail::SpamAssassin::MIME::Parser will not return an
object of the same type, but rather a Mail::SpamAssassin::MIME object.
To use it, simply call C<Mail::SpamAssassin::MIME::Parser->parse($msg)>,
where $msg is a scalar with the entire contents of the mesage.

The procedure used to parse a message is recursive and ends up generating
a tree of M::SA::MIME objects.  parse() will generate the parent node
of the tree, then pass the body of the message to _parse_body() which begins
the recursive process.

This is the only public method available!

=cut

sub parse {
  my($self,$message) = @_;

  # protect it from abuse ...
  local $_;

  # Split the scalar into an array of lines
  my @message = split ( /^/m, $message );

  # trim mbox seperator if it exists
  shift @message if ( scalar @message > 0 && $message[0] =~ /^From\s/ );

  # Generate the main object and parse the appropriate MIME-related headers into it.
  my $msg = Mail::SpamAssassin::MIME->new();
  my $header = '';

  while ( my $last = shift @message ) {
    $last =~ s/\r\n/\n/;
    chomp($last);

    # NB: Really need to figure out special folding rules here!
    if ( $last =~ s/^[ \t]+// ) {                    # if its a continuation
      $header .= " $last";                           # fold continuations
      next;
    }

    if ($header) {
      my ( $key, $value ) = split ( /:\s*/, $header, 2 );
      if ( $key =~ /^(?:MIME-Version|Lines|X-MIME|Content-)/i ) {
        $msg->header( $key, $self->_decode_header($value), $value );
      }
    }

    # not a continuation...
    $header = $last;

    last if ( $last =~ /^$/m );
  }

  my ($boundary);
  ($msg->{'type'}, $boundary) = Mail::SpamAssassin::Util::parse_content_type($msg->header('content-type'));
  $self->_parse_body( $msg, $msg, $boundary, \@message, 1 );

  return $msg;
}

=item _parse_body()

_parse_body() passes the body part that was passed in onto the
correct part parser, either _parse_multipart() for multipart/* parts,
or _parse_normal() for everything else.  Multipart sections become the
root of sub-trees, while everything else becomes a leaf in the tree.

For multipart messages, the first call to _parse_body() doesn't create a
new sub-tree and just uses the parent node to contain children.  All other
calls to _parse_body() will cause a new sub-tree root to be created and
children will exist underneath that root.  (this is just so the tree
doesn't have a root node which points at the actual root node ...)

=cut

sub _parse_body {
  my($self, $msg, $_msg, $boundary, $body, $initial) = @_;

  # CRLF -> LF
  for ( @{$body} ) {
    s/\r\n/\n/;
  }

  # Figure out the simple content-type, or set it to text/plain
  my $type = $_msg->header('Content-Type') || 'text/plain; charset=us-ascii';

  if ( $type =~ /^multipart\//i ) {
    # Treat an initial multipart parse differently.  This will keep the tree:
    # obj(multipart->[ part1, part2 ]) instead of
    # obj(obj(multipart ...))
    #
    if ( $initial ) {
      $self->_parse_multipart( $msg, $_msg, $boundary, $body );
    }
    else {
      $self->_parse_multipart( $_msg, $_msg, $boundary, $body );
      $msg->add_body_part( $_msg );
    }
  }
  else {
    # If it's not multipart, go ahead and just deal with it.
    $self->_parse_normal( $msg, $_msg, $boundary, $body );
  }

  if ( !$msg->body() ) {
    dbg("No message body found. Reparsing as blank.");
    my $part_msg = Mail::SpamAssassin::MIME->new();
    $self->_parse_normal( $msg, $part_msg, $boundary, [] );
  }
}

=item _parse_multipart()

Generate a root node, and for each child part call _parse_body().

=cut

sub _parse_multipart {
  my($self, $msg, $_msg, $boundary, $body) = @_;

  $boundary ||= '';
  dbg("parsing multipart, got boundary: $boundary");

  # ignore preamble per RFC 1521, unless there's no boundary ...
  if ( $boundary ) {
    my $line;
    my $tmp_line = @{$body};
    for ($line=0; $line < $tmp_line; $line++) {
      last if $body->[$line] =~ /^\-\-\Q$boundary\E$/;
    }

    # Found a boundary, ignore the preamble
    if ( $line < $tmp_line ) {
      splice @{$body}, 0, $line+1;
    }

    # Else, there's no boundary, so leave the whole part...
  }

  my $part_msg =
    Mail::SpamAssassin::MIME->new();    # just used for headers storage
  my $in_body = 0;

  my $header;
  my $part_array;

  my $line_count = @{$body};
  foreach ( @{$body} ) {
    if ( --$line_count == 0 || ($boundary && /^\-\-\Q$boundary\E/) ) {

      # end of part
      my $line = $_;
      chomp;
      dbg("Got end of MIME section: $_");

      # per rfc 1521, the CRLF before the boundary is part of the boundary ...
      # NOTE: The CRLF preceding the encapsulation line is conceptually
      # attached to the boundary so that it is possible to have a part
      # that does not end with a CRLF (line break). Body parts that must
      # be considered to end with line breaks, therefore, must have two
      # CRLFs preceding the encapsulation line, the first of which is part
      # of the preceding body part, and the second of which is part of the
      # encapsulation boundary.
      if ($part_array) {
        chomp( $part_array->[ scalar @{$part_array} - 1 ] );
        splice @{$part_array}, -1
          if ( $part_array->[ scalar @{$part_array} - 1 ] eq '' );

        my($p_boundary);
	($part_msg->{'type'}, $p_boundary) = Mail::SpamAssassin::Util::parse_content_type($part_msg->header('content-type'));
        $p_boundary ||= $boundary;
        $self->_parse_body( $msg, $part_msg, $p_boundary, $part_array, 0 );
      }

      last if ($boundary && $line =~ /^\-\-\Q${boundary}\E\-\-$/);
      $in_body  = 0;
      $part_msg = Mail::SpamAssassin::MIME->new();
      undef $part_array;
      undef $header;
      next;
    }

    if ($in_body) {
      push ( @{$part_array}, $_ );
    }
    else {
      s/\s+$//;
      if (m/^\S/) {
        if ($header) {
          my ( $key, $value ) = split ( /:\s*/, $header, 2 );
          $part_msg->header( $key, $value );
        }
        $header = $_;
      }
      elsif (/^$/) {
        if ($header) {
          my ( $key, $value ) = split ( /:\s*/, $header, 2 );
          $part_msg->header( $key, $value );
        }
        $in_body = 1;
      }
      else {
        $_ =~ s/^\s*//;
        $header .= $_;
      }
    }
  }

}

=item _parse_normal()

Generate a leaf node and add it to the parent.

=cut

sub _parse_normal {
  my ($self, $msg, $part_msg, $boundary, $body) = @_;

  dbg("parsing normal".(defined $boundary ? ", got boundary: $boundary":""));
  delete $part_msg->{body_parts}; # single parts don't need a body_parts piece ...

  dbg("decoding attachment");
  my ($type, $decoded, $name) = $self->_decode($part_msg, $body);
  dbg("decoded $type");

  $part_msg->{'type'} = $type;
  $part_msg->{'decoded'} = $decoded;
  $part_msg->{'raw'} = $body;
  $part_msg->{'boundary'} = $boundary;
  $part_msg->{'name'} = $name if $name;

  # If the message is a text/* type, then try rendering it...
  if ( $type =~ /^text\b/i ) {
    ($part_msg->{'rendered'}, $part_msg->{'rendered_type'}) = _render_text($type, $decoded);
  }

  $msg->add_body_part($part_msg);
}

sub __decode_header {
  my ( $encoding, $cte, $data ) = @_;

  if ( $cte eq 'B' ) {
    # base 64 encoded
    return Mail::SpamAssassin::Util::base64_decode($data);
  }
  elsif ( $cte eq 'Q' ) {
    # quoted printable
    return Mail::SpamAssassin::Util::qp_decode($data);
  }
  else {
    die "Unknown encoding type '$cte' in RFC2047 header";
  }
}

=item _decode_header()

Decode base64 and quoted-printable in headers according to RFC2047.

=cut

sub _decode_header {
  my($self, $header) = @_;

  return '' unless $header;
  return $header unless $header =~ /=\?/;

  $header =~
    s/=\?([\w_-]+)\?([bqBQ])\?(.*?)\?=/__decode_header($1, uc($2), $3)/ge;
  return $header;
}

=item _decode()

Decode base64 and quoted-printable parts.

=cut

sub _decode {
  my($self, $msg, $body ) = @_;

  my($type) = Mail::SpamAssassin::Util::parse_content_type($msg->header('content-type'));
  my ($filename) =
    ( $msg->header('content-disposition') =~ /name="?([^\";]+)"?/i );
  if ( !$filename ) {
    ($filename) = ( $type =~ /name="?([^\";]+)"?/i );
  }

  if ( lc( $msg->header('content-transfer-encoding') ) eq 'quoted-printable' ) {
    dbg("decoding QP file");
    my @output =
      map { s/\r\n/\n/; $_; } split ( /^/m, Mail::SpamAssassin::Util::qp_decode( join ( "", @{$body} ) ) );

    return $type, \@output, $filename;
  }
  elsif ( lc( $msg->header('content-transfer-encoding') ) eq 'base64' ) {
    dbg("decoding B64 file");

    # Generate the decoded output
    my $output = [ Mail::SpamAssassin::Util::base64_decode(join("", @{$body})) ];

    # If it's a type text or message, split it into an array of lines
    $output = [ map { s/\r\n/\n/; $_; } split(/^/m, $output->[0]) ] if ( $type =~ m@^(?:text|message)/@ );

    return $type, $output, $filename;
  }
  else {
    # Encoding is one of 7bit, 8bit, binary or x-something
    dbg("decoding other encoding");

    # No encoding, so just point to the raw data ...
    return $type, $body, $filename;
  }
}

=item _html_near_start()

Look at a text scalar and determine whether it should be rendered
as text/html.  Based on a heuristic which simulates a certain common
mail client.

=cut

sub _html_near_start {
  my ($pad) = @_;

  my $count = 0;
  $count += ($pad =~ tr/\n//d) * 2;
  $count += ($pad =~ tr/\n//cd);
  return ($count < 24);
}

=item _render_text()

_render_text() takes the given text/* type MIME part, and attempt
to render it into a text scalar.  It will always render text/html,
and will use a heuristic to determine if other text/* parts should be
considered text/html.

Pass in the content-type and the decoded part array.  Returns a scalar
with the rendered data and the "rendered_as" content-type (same as passed
in for no rendering, "text/html" for HTML).

=cut

sub _render_text {
  my ($type, $decoded) = @_;

  my $text = join('', @{ $decoded });

  # render text/html always, or any other text part as text/html based
  # on a heuristic which simulates a certain common mail client
  if ( $type =~ m@^text/html\b@i ||
      ($text =~ m/^(.{0,18}?<(?:$Mail::SpamAssassin::HTML::re_start)(?:\s.{0,18}?)?>)/ois &&
	_html_near_start($1)
      )
     ) {
    my $html = Mail::SpamAssassin::HTML->new();		# object
    my $html_rendered = $html->html_render($text);	# rendered text
    my $html_results = $html->get_results();		# needed in eval tests
    return ( join('', @{ $html_rendered }), 'text/html' );
  }
  else {
    return ( $text, $type );
  }
}

sub dbg { Mail::SpamAssassin::dbg (@_); }

1;
__END__

=back

=head1 SEE ALSO

C<Mail::SpamAssassin>
C<spamassassin>

