package HTML::WikiConverter::MediaWiki;
use HTML::WikiConverter -dialect;

use warnings;
use strict;

use URI;
use File::Basename;
our $VERSION = '0.51';

=head1 NAME

HTML::WikiConverter::MediaWiki - Convert HTML to MediaWiki markup

=head1 SYNOPSIS

  use HTML::WikiConverter;
  my $wc = new HTML::WikiConverter( dialect => 'MediaWiki' );
  print $wc->html2wiki( $html );

=head1 DESCRIPTION

This module contains rules for converting HTML into MediaWiki
markup. See L<HTML::WikiConverter> for additional usage details.

=head1 ATTRIBUTES

In addition to the regular set of attributes recognized by the
L<HTML::WikiConverter> constructor, this dialect also accepts the
following attributes:

=head2 preserve_bold

Boolean indicating whether bold HTML elements should be preserved as
HTML in the wiki output rather than being converted into MediaWiki
markup.

By default, E<lt>bE<gt> and E<lt>strongE<gt> elements are converted to
wiki markup identically. But sometimes you may wish E<lt>bE<gt> tags
in the HTML to be preserved in the resulting MediaWiki markup. This
attribute allows this.

For example, if C<preserve_bold> is enabled, HTML like

  <ul>
    <li> <b>Bold</b>
    <li> <strong>Strong</strong>
  </ul>

will be converted to

  * <b>Bold</b>
  * '''Strong'''

When disabled (the default), the preceding HTML markup would be
converted into

  * '''Bold'''
  * '''Strong'''

=head2 preserve_italic

Boolean indicating whether italic HTML elements should be preserved as
HTML in the wiki output rather than being converted into MediaWiki
markup.

For example, if C<preserve_italic> is enabled, HTML like

  <ul>
    <li> <i>Italic</i>
    <li> <em>Emphasized</em>
  </ul>

will be converted to

  * <i>Italic</i>
  * ''Emphasized''

When disabled (the default), the preceding HTML markup would be
converted into

  * ''Italic''
  * ''Emphasized''

=cut

attribute preserve_bold => { default => 0 };
attribute preserve_italic => { default => 0 };

my @common_attrs = qw/ id class lang dir title style /;
my @block_attrs = ( @common_attrs, 'align' );
my @tablealign_attrs = qw/ align char charoff valign /;
my @tablecell_attrs = qw(
  abbr axis headers scope rowspan
  colspan nowrap width height bgcolor
);

# Fix for bug 14527
my $pre_prefix = '[jsmckaoqkjgbhazkfpwijhkixh]';

rule hr     => { replace => "\n----\n" };
rule br     => { preserve => 1, empty => 1, attributes => [ qw/id class title style clear/ ] };
rule p      => { block => 1, trim => 'both', line_format => 'multi' };
rule em     => { start => "''", end => "''", line_format => 'single' };
rule i      => { alias => 'em' };
rule strong => { start => "'''", end => "'''", line_format => 'single' };
rule b      => { alias => 'strong' };

rule pre    => { line_prefix => $pre_prefix, block => 1 };

rule table   => { start => \&_table_start, end => "|}", block => 1, line_format => 'blocks' };
rule tr      => { start => \&_tr_start };
rule td      => { start => \&_td_start, end => "\n", trim => 'both', line_format => 'blocks' };
rule th      => { start => \&_td_start, end => "\n", trim => 'both', line_format => 'single' };
rule caption => { start => \&_caption_start, end => "\n", line_format => 'single' };

rule img => { replace => \&_image };
rule a   => { replace => \&_link };

rule ul => { line_format => 'multi', block => 1 };
rule ol => { alias => 'ul' };
rule dl => { alias => 'ul' };

rule li => { start => \&_li_start, trim => 'leading' };
rule dt => { alias => 'li' };
rule dd => { alias => 'li' };

# Preserved elements, from MediaWiki's Sanitizer.php (http://tinyurl.com/dzj6o)
rule div        => { preserve => 1, attributes => \@block_attrs };
rule span       => { alias => 'div' };
rule blockquote => { preserve => 1, attributes => [ @common_attrs, qw/ cite / ] };
rule del        => { preserve => 1, attributes => [ @common_attrs, qw/ cite datetime / ] };
rule ins        => { alias => 'del' };
rule font       => { preserve => 1, attributes => [ @common_attrs, qw/ size color face / ] };

rule( $_ => { preserve => 1, attributes => \@common_attrs } )
  foreach qw/ center cite code var sup sub tt big small strike s u ruby rb rt rp /;

# Disallowed HTML tags
rule( $_ => { replace => '' } )
  foreach qw/ head title script style meta link object /;

# Headings (h1-h6)
foreach my $level ( 1..6 ) {
  my $affix = ( '=' ) x $level;
  rule "h$level" => { start => $affix.' ', end => ' '.$affix, block => 1, trim => 'both', line_format => 'single' };
}

sub _init {
  my $self = shift;
  # Preserve <i> and <b> instead of converting them to '' and ''', respectively
  rule( i => { preserve => 1, attributes => \@common_attrs } ) if $self->preserve_italic;
  rule( b => { preserve => 1, attributes => \@common_attrs } ) if $self->preserve_bold;
}

sub postprocess_output {
  my( $self, $outref ) = @_;
  $$outref =~ s/\Q$pre_prefix\E/ /g;
}

# Calculates the prefix that will be placed before each list item.
# Handles ordered, unordered, and definition list items.
sub _li_start {
  my( $self, $node, $rules ) = @_;
  my @parent_lists = $node->look_up( _tag => qr/ul|ol|dl/ );

  my $prefix = '';
  foreach my $parent ( @parent_lists ) {
    my $bullet = '';
    $bullet = '*' if $parent->tag eq 'ul';
    $bullet = '#' if $parent->tag eq 'ol';
    $bullet = ':' if $parent->tag eq 'dl';
    $bullet = ';' if $parent->tag eq 'dl' and $node->tag eq 'dt';
    $prefix = $bullet.$prefix;
  }

  return "\n$prefix ";
}

sub _link {
  my( $self, $node, $rules ) = @_;
  my $url = $node->attr('href') || '';
  my $text = $self->get_elem_contents($node) || '';

  # Handle internal links
  if( my $title = $self->get_wiki_page( $url ) ) {
    $title =~ s/_/ /g;
    return "[[$title]]" if $text eq $title;        # no difference between link text and page title
    return "[[$text]]" if $text eq lcfirst $title; # differ by 1st char. capitalization
    return "[[$title|$text]]";                     # completely different
  }

  # Treat them as external links
  return $url if $url eq $text;
  return "[$url $text]";
}

sub _image {
  my( $self, $node, $rules ) = @_;
  return '' unless $node->attr('src');
  return '[[Image:'.basename( URI->new($node->attr('src'))->path ).']]';
}

sub _table_start {
  my( $self, $node, $rules ) = @_;
  my $prefix = '{|';

  my @table_attrs = (
    @common_attrs, 
    qw/ summary width border frame rules cellspacing
        cellpadding align bgcolor frame rules /
  );

  my $attrs = $self->get_attr_str( $node, @table_attrs );
  $prefix .= ' '.$attrs if $attrs;

  return $prefix."\n";
}

sub _tr_start {
  my( $self, $node, $rules ) = @_;
  my $prefix = '|-';
  
  my @tr_attrs = ( @common_attrs, 'bgcolor', @tablealign_attrs );
  my $attrs = $self->get_attr_str( $node, @tr_attrs );
  $prefix .= ' '.$attrs if $attrs;

  return '' unless $node->left or $attrs;
  return $prefix."\n";
}

# List of tags (and pseudo-tags, in the case of '~text') that are
# considered phrasal elements. Any table cells that contain only these
# elements will be placed on a single line.
my @td_phrasals = qw/ i em b strong u tt code span font sup sub br hr ~text s strike del ins /;
my %td_phrasals = map { $_ => 1 } @td_phrasals;

sub _td_start {
  my( $self, $node, $rules ) = @_;
  my $prefix = $node->tag eq 'th' ? '!' : '|';

  my @td_attrs = ( @common_attrs, @tablecell_attrs, @tablealign_attrs );
  my $attrs = $self->get_attr_str( $node, @td_attrs );
  $prefix .= ' '.$attrs.' |' if $attrs;

  # If there are any non-text elements inside the cell, then the
  # cell's content should start on its own line
  my @non_text = grep !$td_phrasals{$_->tag}, $node->content_list;
  my $space = @non_text ? "\n" : ' ';

  return $prefix.$space;
}

sub _caption_start {
  my( $self, $node, $rules ) = @_;
  my $prefix = '|+ ';

  my @caption_attrs = ( @common_attrs, 'align' );
  my $attrs = $self->get_attr_str( $node, @caption_attrs );
  $prefix .= $attrs.' |' if $attrs;

  return $prefix;
}

sub preprocess_node {
  my( $self, $node ) = @_;
  my $tag = $node->tag || '';
  $self->strip_aname($node) if $tag eq 'a';
  $self->_strip_extra($node);
  $self->_nowiki_text($node) if $tag eq '~text';
}

my $URL_PROTOCOLS = 'http|https|ftp|irc|gopher|news|mailto';
my $EXT_LINK_URL_CLASS = '[^]<>"\\x00-\\x20\\x7F]';
my $EXT_LINK_TEXT_CLASS = '[^\]\\x00-\\x1F\\x7F]';

# Text nodes matching one or more of these patterns will be enveloped
# in <nowiki> and </nowiki>
my @wikitext_patterns = (
  qr/''/,
  qr/^(?:\*|\#|\;|\:|\=|\!|\|)/m,
  qr/^----/m,
  qr/^\{\|/m,
  qr/\[\[/m,
  qr/{{/m,
);

sub _nowiki_text {
  my( $self, $node ) = @_;
  my $text = $node->attr('text') || '';

  my $found_wikitext = 0;
  foreach my $pat ( @wikitext_patterns ) {
    $found_wikitext++, last if $text =~ $pat;
  }

  if( $found_wikitext ) {
    $text = "<nowiki>$text</nowiki>";
  } else {
    $text =~ s~(\[\b(?:$URL_PROTOCOLS):$EXT_LINK_URL_CLASS+ *$EXT_LINK_TEXT_CLASS*?\])~<nowiki>$1</nowiki>~go;
  }

  $node->attr( text => $text );
}

my %extra = (
 id => qr/catlinks/,
 class => qr/urlexpansion|printfooter|editsection/
);

# Delete <span class="urlexpansion">...</span> et al
sub _strip_extra {
  my( $self, $node ) = @_;
  my $tag = $node->tag || '';

  foreach my $att_name ( keys %extra ) {
    my $att_value = $node->attr($att_name) || '';
    if( $att_value =~ $extra{$att_name} ) {
      $node->detach();
      $node->delete();
      return;
    }
  }
}

=head1 AUTHOR

David J. Iberri, C<< <diberri at cpan.org> >>

=head1 BUGS

Please report any bugs or feature requests to
C<bug-html-wikiconverter-mediawiki at rt.cpan.org>, or through the web
interface at
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=HTML-WikiConverter-MediaWiki>.
I will be notified, and then you'll automatically be notified of
progress on your bug as I make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc HTML::WikiConverter::MediaWiki

You can also look for information at:

=over 4

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/HTML-WikiConverter-MediaWiki>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/HTML-WikiConverter-MediaWiki>

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=HTML-WikiConverter-MediaWiki>

=item * Search CPAN

L<http://search.cpan.org/dist/HTML-WikiConverter-MediaWiki>

=back

=head1 COPYRIGHT & LICENSE

Copyright 2006 David J. Iberri, all rights reserved.

This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

1;
