package Canto::Track::OntologyLoad;

=head1 NAME

Canto::Track::OntologyLoad - Code for loading ontology information into a
                              TrackDB

=head1 SYNOPSIS

=head1 AUTHOR

Kim Rutherford C<< <kmr44@cam.ac.uk> >>

=head1 BUGS

Please report any bugs or feature requests to C<kmr44@cam.ac.uk>.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Canto::Track::OntologyLoad

=over 4

=back

=head1 COPYRIGHT & LICENSE

Copyright 2009 Kim Rutherford, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=head1 FUNCTIONS

=cut

use Moose;
use Carp;
use feature qw(state);

use Try::Tiny;

use GO::Parser;
use LWP::Simple;
use File::Temp qw(tempfile);

use Canto::Track::LoadUtil;

has 'schema' => (
  is => 'ro',
  isa => 'Canto::TrackDB',
  required => 1,
);

has 'default_db_name' => (
  is => 'ro',
  required => 1,
);

sub _delete_term_by_cv
{
  my $schema = shift;
  my $cv_name = shift;
  my $delete_relations = shift;

  my $cv_cvterms = $schema->resultset('Cv')->search({ 'me.name' => $cv_name })
    ->search_related('cvterms');

  if ($delete_relations) {
    $cv_cvterms = $cv_cvterms->search({ 'cvterms.is_relationshiptype' => 1 });
  } else {
    $cv_cvterms = $cv_cvterms->search({ 'cvterms.is_relationshiptype' => 0 });
  }

  for my $related (qw(cvtermprop_cvterms cvtermsynonym_cvterms
                      cvterm_relationship_objects cvterm_relationship_subjects)) {
    $cv_cvterms->search_related($related)->delete();
  }

  my $delete_me = "DELETE_ME";
  $cv_cvterms->search_related('cvterm_dbxrefs')->search_related('dbxref')
    ->update({ description => $delete_me });
  $cv_cvterms->search_related('cvterm_dbxrefs')->delete();
  $schema->resultset('Dbxref')->search({ description => $delete_me })->delete();

  $cv_cvterms->delete();
}

=head2 load

 Usage   : my $ont_load = Canto::Track::OntologyLoad->new(schema => $schema);
           $ont_load->load($file_name, $index, [qw(exact related)]);
 Function: Load the contents an OBO file into the schema
 Args    : $source - the file name or URL of an obo format file
           $index - the index to add the terms to (optional)
           $synonym_types_ref - a array ref of synonym types that should be added
                                to the index
 Returns : Nothing

=cut

sub load
{
  my $self = shift;
  my $source = shift;
  my $index = shift;
  my $synonym_types_ref = shift;

  if (!defined $source) {
    croak "no source passed to OntologyLoad::load()";
  }

  if (!defined $synonym_types_ref) {
    croak "no synonym_types passed to OntologyLoad::load()";
  }

  my $schema = $self->schema();

  my $comment_cvterm = $schema->find_with_type('Cvterm', { name => 'comment' });
  my $parser = GO::Parser->new({ handler=>'obj' });

  my $file_name;
  my $fh;

  if ($source =~ m|http://|) {
    ($fh, $file_name) = tempfile('/tmp/downloaded_ontology_file_XXXXX',
                                 SUFFIX => '.obo');
    my $rc = getstore($source, $file_name);
    if (is_error($rc)) {
      die "failed to download source OBO file: $rc\n";
    }
  } else {
    $file_name = $source;
  }

  $parser->parse($file_name);

  my $graph = $parser->handler->graph;
  my %cvterms = ();

  my @synonym_types_to_load = @$synonym_types_ref;
  my %synonym_type_ids = ();

  for my $synonym_type (@synonym_types_to_load) {
    $synonym_type_ids{$synonym_type} =
      $schema->find_with_type('Cvterm', { name => $synonym_type })->cvterm_id();
  }

  my %relationship_cvterms = ();

  my $relationship_cv =
    $schema->resultset('Cv')->find({ name => 'relationship' });
  my $isa_cvterm = undef;

  if (defined $relationship_cv) {
    $isa_cvterm =
      $schema->resultset('Cvterm')->find({ name => 'is_a',
                                           cv_id => $relationship_cv->cv_id() });

    $relationship_cvterms{is_a} = $isa_cvterm;
  }

  my %cvs = ();

  my $collect_cvs_handler =
    sub {
      my $ni = shift;
      my $term = $ni->term;

      my $cv_name = $term->namespace();

      if (!defined $cv_name) {
        die "no namespace in $source";
      }

      $cvs{$cv_name} = 1;
    };

  $graph->iterate($collect_cvs_handler);

  # find cvs referenced by relation cvterms
  my $cvs_terms_rels_rs =
    $schema->resultset('Cv')->search({ 'me.name' => { -in => [keys %cvs]} })
           ->search_related('cvterms')
           ->search_related('cvterm_relationship_types');

  my $rel_object_cvs =
    $cvs_terms_rels_rs->search_related('object')
                      ->search_related('cv', {}, { distinct => 1 });

  while (defined (my $rel_cv = $rel_object_cvs->next())) {
    $cvs{$rel_cv->name()} = 1;
  }

  my $rel_subject_cvs =
    $cvs_terms_rels_rs->search_related('subject')
                      ->search_related('cv', {}, { distinct => 1 });

  while (defined (my $rel_cv = $rel_subject_cvs->next())) {
    $cvs{$rel_cv->name()} = 1;
  }

  # delete existing terms
  map {
    _delete_term_by_cv($schema, $_, 0);
  } keys %cvs;

  # delete relations
  map {
    _delete_term_by_cv($schema, $_, 1);
  } keys %cvs;

  my $db_rs = $schema->resultset('Db');

  my %db_ids = map { ($_->name(), $_->db_id()) } $db_rs->all();

  # create this object after deleting as LoadUtil has a dbxref cache (that
  # is a bit ugly ...)
  my $load_util = Canto::Track::LoadUtil->new(schema => $self->schema(),
                                              default_db_name => $self->default_db_name());
  my $store_term_handler =
    sub {
      my $ni = shift;
      my $term = $ni->term;

      my $cv_name = $term->namespace();

      if (!defined $cv_name) {
        die "no namespace in $source";
      }

      my $comment = $term->comment();

      my $xrefs = $term->dbxref_list();

      for my $xref (@$xrefs) {
        my $x_db_name = $xref->xref_dbname();
        my $x_acc = $xref->xref_key();

        my $x_db_id = $db_ids{$x_db_name};

       if (defined $x_db_id) {
         my $x_dbxref = undef;

         try {
           $x_dbxref = $load_util->find_dbxref("OBO_REL:$x_acc");
         } catch {
           # dbxref not found
         };

         if (defined $x_dbxref) {
            # no need to add it as it's already there, loaded from another
            # ontology
            if ($term->is_relationship_type()) {
              my $x_dbxref_id = $x_dbxref->dbxref_id();
              my $cvterm_rs = $schema->resultset('Cvterm');
              my ($cvterm) = $cvterm_rs->search({dbxref_id => $x_dbxref_id});
              $relationship_cvterms{$term->name()} = $cvterm;
            }

            return;
          }
        }
      }

      if (!$term->is_obsolete()) {
        my $term_name = $term->name();

        my $cvterm = $load_util->get_cvterm(cv_name => $cv_name,
                                            term_name => $term_name,
                                            ontologyid => $term->acc(),
                                            definition => $term->definition(),
                                            alt_ids => $term->alt_id_list(),
                                            is_relationshiptype =>
                                              $term->is_relationship_type());

        if ($term->is_relationship_type()) {
          (my $term_acc = $term->acc()) =~ s/OBO_REL://;
          $relationship_cvterms{$term_acc} = $cvterm;
        }

        my $cvterm_id = $cvterm->cvterm_id();

        if (defined $comment) {
          my $cvtermprop =
            $schema->create_with_type('Cvtermprop',
                                      {
                                        cvterm_id => $cvterm_id,
                                        type_id =>
                                          $comment_cvterm->cvterm_id(),
                                        value => $comment,
                                        rank => 0,
                                      });
        }

        my @synonyms_for_index = ();

        for my $synonym_type (@synonym_types_to_load) {
          my $synonyms = $term->synonyms_by_type($synonym_type);

          my $type_id = $synonym_type_ids{$synonym_type};

          for my $synonym (@$synonyms) {
            $schema->create_with_type('Cvtermsynonym',
                                      {
                                        cvterm_id => $cvterm_id,
                                        synonym => $synonym,
                                        type_id => $type_id,
                                      });

            push @synonyms_for_index, { synonym => $synonym, type => $synonym_type };
          }
        }

        if (!$term->is_relationship_type()) {
          $cvterms{$term->acc()} = $cvterm;

          if (defined $index) {
            $index->add_to_index($cv_name, $term_name, $cvterm_id,
                                 $term->acc(), \@synonyms_for_index);
          }
        }
      }
    };

  $graph->iterate($store_term_handler);

  my $rels = $graph->get_all_relationships();

  for my $rel (@$rels) {
    my $subject_term_acc = $rel->subject_acc();
    my $object_term_acc = $rel->object_acc();

    next if $rel->type() eq 'has_part' ||
      $rel->type() eq 'has_functional_part' ||
      $rel->type() eq 'has_functional_parent' ||
      $rel->type() eq 'derives_from' ||
      $rel->type() eq 'contains' ||
      $rel->type() eq 'includes_cells_with_phenotype' ||
      $rel->type() eq 'comprises_cells_with_phenotype';

    my $rel_type = $rel->type();
    my $rel_type_cvterm = $relationship_cvterms{$rel_type};

    die "can't find relationship cvterm for: $rel_type"
      unless defined $rel_type_cvterm;

    # don't store relations between relation terms
    my $subject_cvterm = $cvterms{$subject_term_acc};
    next unless defined $subject_cvterm;

    my $object_cvterm = $cvterms{$object_term_acc};
    next unless defined $object_cvterm;

    $schema->create_with_type('CvtermRelationship',
                              {
                                subject => $subject_cvterm,
                                object => $object_cvterm,
                                type => $rel_type_cvterm
                              });
  }
}

1;
