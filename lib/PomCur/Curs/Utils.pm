package PomCur::Curs::Utils;

=head1 NAME

PomCur::Curs::Utils - Utilities for Curs code

=head1 SYNOPSIS

=head1 AUTHOR

Kim Rutherford C<< <kmr44@cam.ac.uk> >>

=head1 BUGS

Please report any bugs or feature requests to C<kmr44@cam.ac.uk>.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc PomCur::Curs::Utils

=over 4

=back

=head1 COPYRIGHT & LICENSE

Copyright 2009 Kim Rutherford, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=head1 FUNCTIONS

=cut

use strict;
use warnings;
use Carp;
use Moose;

use PomCur::Curs::GeneProxy;

sub _make_ontology_annotation
{
  my $config = shift;
  my $schema = shift;
  my $annotation = shift;
  my $ontology_lookup = shift;
  my $gene_proxy = shift;
  my $gene_synonyms_string = shift;

  my $data = $annotation->data();
  my $term_ontid = $data->{term_ontid};
  die "no term_ontid for annotation"
    unless defined $term_ontid and length $term_ontid > 0;

  my $annotation_type = $annotation->type();

  my %annotation_types_config = %{$config->{annotation_types}};
  my $annotation_type_config = $annotation_types_config{$annotation_type};
  my $annotation_type_display_name = $annotation_type_config->{display_name};
  my $annotation_type_abbreviation = $annotation_type_config->{abbreviation};
  my $annotation_type_namespace = $annotation_type_config->{namespace};

  my %evidence_types = %{$config->{evidence_types}};

  my $uniquename = $annotation->pub()->uniquename();

  my $result =
    $ontology_lookup->lookup(ontology_name => $annotation_type_namespace,
                             search_string => $term_ontid);

  if (!@$result) {
    die qq(internal error: can't find details for "$term_ontid" in "$annotation_type");
  }

  my $term_name = $result->[0]->{name};

  my $evidence_code = $data->{evidence_code};
  my $with_gene_identifier = $data->{with_gene};

  my $needs_with;
  if (defined $evidence_code) {
    $needs_with = $evidence_types{$evidence_code}->{with_gene};
  } else {
    $needs_with = 0;
  }

  my $with_gene;
  my $with_gene_display_name;

  if ($with_gene_identifier) {
    my $gene_lookup = PomCur::Track::get_adaptor($config, 'gene');
    $with_gene = $schema->find_with_type('Gene',
                                         { primary_identifier =>
                                             $with_gene_identifier });
    my $gene_proxy = PomCur::Curs::GeneProxy->new(config => $config,
                                                  cursdb_gene => $with_gene,
                                                  gene_lookup => $gene_lookup);
    $with_gene_display_name = $gene_proxy->display_name()
  }

  my $allele_display_name = undef;

  if ($annotation_type_config->{needs_allele}) {
    my @alleles = $annotation->alleles();

    if (@alleles == 0) {
      die "no alleles for annotation ", $annotation->annotation_id();
    }

    if (@alleles > 1) {
      die "more than one allele for annotation ", $annotation->annotation_id();
    }

    $allele_display_name = $alleles[0]->display_name();
 }

  (my $short_date = $annotation->creation_date()) =~ s/-//g;

  my $completed = defined $evidence_code &&
    (!$needs_with || defined $with_gene_identifier);

  return {
    gene_identifier => $gene_proxy->primary_identifier(),
    gene_name => $gene_proxy->primary_name() || '',
    gene_name_or_identifier =>
      $gene_proxy->primary_name() || $gene_proxy->primary_identifier(),
    gene_product => $gene_proxy->product() // '',
    gene_synonyms_string => $gene_synonyms_string,
    allele_display_name => $allele_display_name,
    qualifier => '',
    annotation_type => $annotation_type,
    annotation_type_display_name => $annotation_type_display_name,
    annotation_type_abbreviation => $annotation_type_abbreviation // '',
    annotation_id => $annotation->annotation_id(),
    publication_uniquename => $uniquename,
    term_ontid => $term_ontid,
    term_name => $term_name,
    evidence_code => $evidence_code,
    creation_date => $annotation->creation_date(),
    creation_date_short => $short_date,
    term_suggestion => $data->{term_suggestion},
    needs_with => $needs_with,
    with_or_from_identifier => $with_gene_identifier,
    with_or_from_display_name => $with_gene_display_name // '',
    taxonid => $gene_proxy->organism()->taxonid(),
    completed => $completed,
    annotation_extension => $data->{annotation_extension} // '',
    status => $annotation->status(),
    is_not => 0,
  };
}

sub _make_interaction_annotation
{
  my $config = shift;
  my $schema = shift;
  my $annotation = shift;
  my $gene_proxy = shift;

  my $data = $annotation->data();
  my $evidence_code = $data->{evidence_code};
  my $annotation_type = $annotation->type();

  my %annotation_types_config = %{$config->{annotation_types}};
  my $annotation_type_config = $annotation_types_config{$annotation_type};
  my $annotation_type_display_name = $annotation_type_config->{display_name};

  my $pub_uniquename = $annotation->pub()->uniquename();

  my @interacting_genes = @{$data->{interacting_genes}};

  my $gene_lookup = PomCur::Track::get_adaptor($config, 'gene');

  return map {
    my $interacting_gene_info = $_;
    my $interacting_gene_primary_identifier =
      $interacting_gene_info->{primary_identifier};
    my $interacting_gene =
      $schema->find_with_type('Gene',
                              { primary_identifier =>
                                $interacting_gene_primary_identifier});
    my $interacting_gene_proxy =
      PomCur::Curs::GeneProxy->new(config => $config,
                                   cursdb_gene => $interacting_gene,
                                   gene_lookup => $gene_lookup);

    my $interacting_gene_display_name =
      $interacting_gene_proxy->display_name();

    my $entry =
          {
            gene_identifier => $gene_proxy->primary_identifier(),
            gene_display_name => $gene_proxy->display_name(),
            gene_taxonid => $gene_proxy->organism()->taxonid(),
            publication_uniquename => $pub_uniquename,
            evidence_code => $evidence_code,
            interacting_gene_identifier =>
              $interacting_gene_primary_identifier,
            interacting_gene_display_name =>
              $interacting_gene_display_name,
            interacting_gene_taxonid =>
              $interacting_gene_info->{organism_taxon}
                // $gene_proxy->organism()->taxonid(),
            score => '',  # for biogrid format output
            phenotypes => '',
            comment => '',
            completed => 1,
            annotation_id => $annotation->annotation_id(),
            annotation_type => $annotation_type,
            status => $annotation->status(),
          };
    $entry;
  } @interacting_genes;
};

=head2 get_annotation_table

 Usage   : my @annotations =
             PomCur::Curs::Utils::get_annotation_table($config, $schema,
                                                       $annotation_type_name);
 Function: Return a table of the current annotations
 Args    : $config - the PomCur::Config object
           $schema - a PomCur::CursDB object
           $annotation_type_name - the type of annotation to show (eg.
                                   biological_process, phenotype)
           $annotation - the annotation to show; if set only the row containing
                         this annotation will be returned; optional
 Returns : ($completed_count, $table)
           where:
             $completed_count - a count of the annotations that are incomplete
                because they need an evidence code or a with field, etc.
             $table - an array of hashes containing the annotation

 The returned table has this format if the annotation_type_name is an ontology
 type:
    [ { gene_identifier => 'SPCC1739.11c',
        gene_name => 'cdc11',
        annotation_type => 'molecular_function',
        annotation_id => 1234,
        term_ontid => 'GO:0055085',
        term_name => 'transmembrane transport',
        evidence_code => 'IDA',
        ... },
      { gene_identifier => '...', ... }, ]
    where annotation_id is the id of the Annotation object for this annotation

 If the annotation_type_name is an interaction type the format is:
    [ { gene_identifier => 'SPCC1739.11c',
        gene_display_name => 'cdc11',
        gene_taxonid => 4896,
        publication_uniquename => 'PMID:20870879',
        evidence_code => 'Phenotypic Enhancement',
        interacting_gene_identifier => 'SPBC12C2.02c',
        interacting_gene_display_name => 'ste20',
        interacting_gene_taxonid => 4896
        annotation_id => 1234,
        ... },
      { gene_identifier => '...', ... }, ]
    where annotation_id is the id of the Annotation object for this annotation

=cut
sub get_annotation_table
{
  my $config = shift;
  my $schema = shift;
  my $annotation_type_name = shift;
  my $constrain_annotations = shift;

  my @annotations = ();

  my %annotation_types_config = %{$config->{annotation_types}};
  my $annotation_type_config = $annotation_types_config{$annotation_type_name};
  my $annotation_type_category = $annotation_type_config->{category};

  my $ontology_lookup =
    PomCur::Track::get_adaptor($config, 'ontology');

  my $gene_rs = $schema->resultset('Gene');

  my $completed_count = 0;

  my %constraints = (
    type => $annotation_type_name,
  );

  if ($constrain_annotations) {
    if (ref $constrain_annotations eq 'ARRAY') {
      my @constrain_annotations = @$constrain_annotations;
      $constraints{annotation_id} = {
        -in => [map { $_->annotation_id() } @constrain_annotations]
      };
    } else {
      $constraints{annotation_id} = $constrain_annotations->annotation_id();
    }
  }

  my %options = ( order_by => 'annotation_id' );

  my $gene_lookup = PomCur::Track::get_adaptor($config, 'gene');

  while (defined (my $gene = $gene_rs->next())) {
    my $gene_proxy =
      PomCur::Curs::GeneProxy->new(config => $config,
                                   cursdb_gene => $gene,
                                   gene_lookup => $gene_lookup);

    my $an_rs =
      $gene_proxy->direct_annotations()->search({ %constraints }, { %options });

    my $gene_synonyms_string = join '|', $gene_proxy->synonyms();

    while (defined (my $annotation = $an_rs->next())) {
      my @entries;
      if ($annotation_type_category eq 'ontology') {
        @entries = (_make_ontology_annotation($config, $schema, $annotation,
                                              $ontology_lookup,
                                              $gene_proxy, $gene_synonyms_string));
      } else {
        if ($annotation_type_category eq 'interaction') {
          @entries = _make_interaction_annotation($config, $schema, $annotation,
                                                  $gene_proxy);
        } else {
          die "unknown annotation type category: $annotation_type_category\n";
        }
      }
      push @annotations, @entries;
      map { $completed_count++ if $_->{completed} } @entries;
    }
  }

  return ($completed_count, [@annotations]);
}

sub _process_ontology
{
  my $ontology_lookup = shift;
  my $row = shift;

  my $gene = $row->{gene};
  my $ontology_term = $row->{ontology_term};
  my $publication = $row->{publication};
  my $evidence_code = $row->{evidence_code};
  my $ontology_name = $ontology_term->{ontology_name};

  my $term_ontid = $ontology_term->{ontid};
  my $term_details =
    $ontology_lookup->lookup(ontology_name => $ontology_name,
                             search_string => $term_ontid);

  if (!@$term_details) {
    warn "failed to find term for $term_ontid\n";
    return undef;
  }

  my $term_name = $term_details->[0]->{name};

  return {
    annotation_id => $row->{annotation_id},
    gene_identifier => $gene->{identifier},
    gene_name => $gene->{name} || '',
    gene_name_or_identifier =>
      $gene->{name} || $gene->{identifier},
    gene_product => $gene->{product} || '',
    qualifier => '',
    annotation_type => $ontology_name,
    term_ontid => $term_ontid,
    term_name => $term_name,
    evidence_code => $evidence_code,
    with_or_from_identifier => $row->{with} // $row->{from},
    with_or_from_display_name => $row->{with} // $row->{from},
    taxonid => $gene->{organism_taxonid},
    status => 'existing',
    is_not => $row->{is_not} // 0,
  };
}

=head2 get_existing_ontology_annotations

 Usage   :
   my @annotations =
     PomCur::Curs::Utils::get_existing_ontology_annotations($config, $options);
 Function: Return a table of the existing ontology annotations from the database
 Args    : $config - the PomCur::Config object
 Args    : $options->{pub_uniquename} - the identifier of the publication,
               usually the PubMed ID to get annotations for
           $options->{gene_identifier} - the gene identifier to use to constrain
               the search; only annotations for the gene are returned (optional)
           $options->{ontology_name} - the ontology name to use to restrict the
               search; only annotations using terms from this ontology are
               returned (optional)
 Returns : An array of hashes containing the annotation in the same form as
           get_annotation_table() above, except that annotation_id will be a
           database identifier for the annotation.

=cut
sub get_existing_ontology_annotations
{
  my $config = shift;
  my $options = shift;

  my $pub_uniquename = $options->{pub_uniquename};
  my $gene_identifier = $options->{gene_identifier};
  my $ontology_name = $options->{annotation_type_name};

  my $args = {
    pub_uniquename => $pub_uniquename,
    gene_identifier => $gene_identifier,
    ontology_name => $ontology_name,
  };

  my $ontology_lookup =
    PomCur::Track::get_adaptor($config, 'ontology');
  my $annotation_lookup =
    PomCur::Track::get_adaptor($config, 'ontology_annotation');

  if (defined $annotation_lookup) {
    return map {
      my $res = _process_ontology($ontology_lookup, $_);
      if (defined $res) {
        ($res);
      } else {
        ();
      }
    } @{$annotation_lookup->lookup($args)};
  } else {
    return ();
  }
}

sub _process_interaction
{
  my $ontology_lookup = shift;
  my $row = shift;

  my $gene = $row->{gene};
  my $interacting_gene = $row->{interacting_gene};
  my $publication = $row->{publication};

  return {
    gene_identifier => $gene->{identifier},
    gene_display_name => $gene->{name} // $gene->{identifier},
    gene_taxonid => $gene->{taxonid},
    publication_uniquename => $publication->{uniquename},
    evidence_code => $row->{evidence_code},
    interacting_gene_identifier => $interacting_gene->{identifier},
    interacting_gene_display_name =>
      $interacting_gene->{name} // $interacting_gene->{identifier},
    interacting_gene_taxonid => $interacting_gene->{taxonid},
    status => 'existing',
  };
}

=head2 get_existing_interaction_annotations

 Usage   :
   my @annotations =
  PomCur::Curs::Utils::get_existing_interaction_annotations($config, $options);
 Function: Return a table of the existing interaction annotations from the
           database
 Args    : $config - the PomCur::Config object
           $options->{pub_uniquename} - the publication ID (eg. PubMed ID)
               to retrieve annotations from
           $options->{gene_identifier} - the gene identifier to use to constrain
               the search; only annotations for the gene are returned (optional)
 Returns : An array of hashes containing the annotation in the same form as
           get_annotation_table() above, except that annotation_id will be a
           database identifier for the annotation.

=cut
sub get_existing_interaction_annotations
{
  my $config = shift;
  my $options = shift;

  my $pub_uniquename = $options->{pub_uniquename};
  my $gene_identifier = $options->{gene_identifier};
  my $interaction_type_name = $options->{annotation_type_name};

  my $args = {
    pub_uniquename => $pub_uniquename,
    gene_identifier => $gene_identifier,
    interaction_type_name => $interaction_type_name,
  };

  my $annotation_lookup =
    PomCur::Track::get_adaptor($config, 'interaction_annotation');

  if (defined $annotation_lookup) {
    return map {
      my $res = _process_interaction($annotation_lookup, $_);
      if (defined $res) {
        ($res);
      } else {
        ();
      }
    } @{$annotation_lookup->lookup($args)};
  } else {
    return ();
  }
}

=head2 get_existing_annotations

 Usage   :
   my @annotations =
     PomCur::Curs::Utils::get_existing_annotations($config, $options);
 Function: Return a table of the existing interaction annotations from the
           database
 Args    : $config - the PomCur::Config object
           $options->{pub_uniquename} - the publication ID (eg. PubMed ID)
               to retrieve annotations from
           $options->{gene_identifier} - the gene identifier to use to constrain
               the search; only annotations for the gene are returned (optional)
           $options->{annotation_type_name} - the annotation type eg.
               'biological_process', 'physical_interaction'
           $options->{annotation_type_category} - the annotation category, eg.
               'ontology' or 'interaction'
 Returns : An array of hashes containing the annotation in the same form as
           get_annotation_table() above, except that annotation_id will be a
           database identifier for the annotation.

=cut
sub get_existing_annotations
{
  my $config = shift;
  my $options = shift;

  if ($options->{annotation_type_category} eq 'ontology') {
    return get_existing_ontology_annotations($config, $options);
  } else {
    return get_existing_interaction_annotations($config, $options);
  }
}

=head2 store_all_statuses

 Usage   : PomCur::Curs::Utils::store_all_statuses($config, $schema);
 Function: Store the current status of all Curs DBs in the Track DB
 Args    : $config - the PomCur::Config object
           $schema - a PomCur::TrackDB object
 Returns :

=cut
sub store_all_statuses
{
  my $config = shift;
  my $track_schema = shift;

  my $iter = PomCur::Track::curs_iterator($config, $track_schema);
  while (my ($curs, $cursdb) = $iter->()) {
    PomCur::Controller::Curs->store_statuses($config, $cursdb);
  }
}

1;
