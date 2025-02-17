package Canto::Curs::ServiceUtils;

=head1 NAME

Canto::Curs::ServiceUtils - Helper functions for returning lists of data to the
                            browser.

=head1 SYNOPSIS

=head1 AUTHOR

Kim Rutherford C<< <kmr44@cam.ac.uk> >>

=head1 BUGS

Please report any bugs or feature requests to C<kmr44@cam.ac.uk>.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Canto::Curs::ServiceUtils

=over 4

=back

=head1 COPYRIGHT & LICENSE

Copyright 2013 Kim Rutherford, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=head1 FUNCTIONS

=cut

use strict;
use warnings;
use Moose;
use Carp qw(carp croak cluck);

use JSON;

use Try::Tiny;
use Scalar::Util qw(looks_like_number);
use Clone qw(clone);

use Canto::Curs::GeneProxy;
use Canto::Curs::Utils;
use Canto::Curs::ConditionUtil;
use Canto::Curs::MetadataStorer;
use Canto::Curs::OrganismManager;
use Canto::Curs::StrainManager;
use Canto::Curs::GeneProxy;

has curs_schema => (is => 'ro', isa => 'Canto::CursDB', required => 1);

has ontology_lookup => (is => 'ro', init_arg => undef, lazy_build => 1);
has allele_lookup => (is => 'ro', init_arg => undef, lazy_build => 1);
has genotype_lookup => (is => 'ro', init_arg => undef, lazy_build => 1);
has organism_lookup => (is => 'ro', init_arg => undef, lazy_build => 1);
has strain_lookup => (is => 'ro', init_arg => undef, lazy_build => 1);
has organism_manager => (is => 'ro', init_arg => undef, lazy_build => 1);
has strain_manager => (is => 'ro', init_arg => undef, lazy_build => 1);

has state => (is => 'rw', init_arg => undef,
              isa => 'Canto::Curs::State', lazy_build => 1);
has metadata_storer => (is => 'rw', init_arg => undef, lazy_build => 1,
                        isa => 'Canto::Curs::MetadataStorer');
has curator_manager => (is => 'rw', init_arg => undef, lazy_build => 1,
                        isa => 'Canto::Track::CuratorManager');

with 'Canto::Role::Configurable';
with 'Canto::Role::MetadataAccess';
with 'Canto::Curs::Role::CuratorSet';

sub _build_state
{
  my $self = shift;

  return $self->state(Canto::Curs::State->new(config => $self->config()));
}

sub _build_metadata_storer
{
  my $self = shift;

  return Canto::Curs::MetadataStorer->new(config => $self->config());
}

sub _build_ontology_lookup
{
  my $self = shift;

  return Canto::Track::get_adaptor($self->config(), 'ontology');
}

sub _build_allele_lookup
{
  my $self = shift;

  return Canto::Track::get_adaptor($self->config(), 'allele');
}

sub _build_genotype_lookup
{
  my $self = shift;

  return Canto::Track::get_adaptor($self->config(), 'genotype');
}

sub _build_organism_lookup
{
  my $self = shift;

  return Canto::Track::get_adaptor($self->config(), 'organism');
}

sub _build_strain_lookup
{
  my $self = shift;

  return Canto::Track::get_adaptor($self->config(), 'strain');
}

sub _build_organism_manager
{
  my $self = shift;

  return Canto::Curs::OrganismManager->new(config => $self->config(),
                                           curs_schema => $self->curs_schema());
}

sub _build_strain_manager
{
  my $self = shift;

  return Canto::Curs::StrainManager->new(config => $self->config(),
                                         curs_schema => $self->curs_schema(),
                                         organism_lookup => $self->organism_lookup());
}

sub _build_curator_manager
{
  my $self = shift;

  return Canto::Track::CuratorManager->new(config => $self->config());
}

# return a list of conditions used by this session
sub _get_conditions
{
  my $self = shift;

  my $curs_schema = $self->curs_schema();
  my $lookup = $self->ontology_lookup();

  my %conds = ();

  my $rs = $curs_schema->resultset('Annotation');

  while (defined (my $annotation = $rs->next())) {
    my $data = $annotation->data();

    my @conditions_with_names =
      Canto::Curs::ConditionUtil::get_conditions_with_names($lookup, $data->{conditions});

    map {
      my $key = $_->{name} . '_' . ($_->{id} // 'NONE');
      if (!exists $conds{$key}) {
        $conds{$key} = $_;
      }
    } @conditions_with_names;
  }

  return map { $conds{$_}; } sort keys %conds;
}

sub _get_organisms
{
  my $self = shift;
  my $args = shift;

  my %options = ();
  if ($args) {
    %options = %$args;
  }

  my $include_counts = $options{include_counts};

  my $curs_schema = $self->curs_schema();
  my $organism_lookup = $self->organism_lookup();

  my %conds = ();

  my $rs = $curs_schema->resultset('Organism');

  my @return_list = ();

  while (defined (my $org = $rs->next())) {
    my $organism_details = $organism_lookup->lookup_by_taxonid($org->taxonid());

    $organism_details->{genotype_count} = $org->genotypes()->count();

    $organism_details->{genes} =
      [map {
        my $gene_proxy =
          Canto::Curs::GeneProxy->new(config => $self->config(), cursdb_gene => $_);
        my $gene_details = {
          primary_identifier => $gene_proxy->primary_identifier(),
          primary_name => $gene_proxy->primary_name(),
          display_name => $gene_proxy->display_name(),
          gene_id => $_->gene_id(),
        };

        if ($include_counts) {
          $gene_details->{genotype_count} = $gene_proxy->cursdb_gene()->genotypes()->count();
        }

        $gene_details;
      } $org->genes()->all()];

    push @return_list, $organism_details;
  }

  return @return_list;
}

sub _get_strains
{
  my $self = shift;
  my $args = shift;

  my %options = ();
  if ($args) {
    %options = %$args;
  }

  my $include_counts = $options{include_counts};

  my $curs_schema = $self->curs_schema();
  my $strain_lookup = $self->strain_lookup();

  my %conds = ();

  my $rs = $curs_schema->resultset('Strain');

  my @return_list = ();

  my %results_by_strain_id = ();

  my @track_strain_ids = ();

  while (defined (my $curs_strain = $rs->next())) {
    my $strain_res = {
      taxon_id => $curs_strain->organism()->taxonid(),
    };

    my $track_strain_id = $curs_strain->track_strain_id();

    if ($track_strain_id) {
      $strain_res->{strain_id} = $track_strain_id;
      $results_by_strain_id{$track_strain_id} = $strain_res;
    } else {
      $strain_res->{strain_name} = $curs_strain->strain_name();
      push @return_list, $strain_res;
    }
  }

  map {
    my $strain_details = $_;
    my $strain_res = $results_by_strain_id{$_->{strain_id}};
    $strain_res->{strain_name} = $strain_details->{strain_name};
    $strain_res->{synonyms} = $strain_details->{synonyms};
    push @return_list, $strain_res;
  } $strain_lookup->lookup_by_strain_ids(keys %results_by_strain_id);

  return @return_list;
}

sub _get_annotation_by_type
{
  my $self = shift;
  my $annotation_type_name = shift;
  my $pub_uniquename = shift;

  my ($completed_count, $rows) =
    Canto::Curs::Utils::get_annotation_table($self->config(),
                                             $self->curs_schema(),
                                             $annotation_type_name);
  my @new_annotations = @$rows;

  ($completed_count, $rows) =
    Canto::Curs::Utils::get_existing_annotations($self->config(),
                                                 $self->curs_schema(),
                                                 { pub_uniquename => $pub_uniquename,
                                                   annotation_type_name => $annotation_type_name });

  return (@new_annotations, @$rows);
}

sub _get_annotation
{
  my $self = shift;
  my $annotation_type_name = shift;

  my $curs_schema = $self->curs_schema();

  my $pub_rs = $curs_schema->resultset('Pub');

  my @pubs = $pub_rs->all();

  if (@pubs > 1) {
    die "internal error - more than one publication stored in session: ",
      $curs_schema->resultset('Metadata')->find({ key => 'curs_key' })->value();
  }

  if (@pubs == 0) {
    die "internal error - no publications stored in session: ",
      $curs_schema->resultset('Metadata')->find({ key => 'curs_key' })->value();
  }

  my $pub = $pubs[0];
  my $pub_uniquename = $pub->uniquename();

  if ($annotation_type_name) {
    return $self->_get_annotation_by_type($annotation_type_name, $pub_uniquename)
  } else {
    my @annotation_type_list = @{$self->config()->{annotation_type_list}};

    return
      map {
        $self->_get_annotation_by_type($_->{name}, $pub_uniquename);
      } @annotation_type_list;
  }
}

sub _filter_by_gene_identifiers
{
  my $curs_schema = shift;
  my $genotype_rs = shift;
  my $gene_identifiers = shift;

  my @sub_queries = map {
    my $gene_identifier = $_;
    my $sub_query =
      $curs_schema->resultset('Genotype')
        ->search({ 'gene.primary_identifier' => $gene_identifier },
                 {
                   join => {
                     allele_genotypes => {
                       allele => 'gene'
                     }
                   }
                 });
    {
      'genotype_id' =>
        {
          -in => $sub_query->get_column('genotype_id')->as_query()
        }
      }
  } @$gene_identifiers;

  my $search_arg = {
    -and => \@sub_queries,
  };

  return $genotype_rs->search($search_arg);
}

sub _filter_lookup_genotypes
{
  my $self = shift;
  my $max = shift;
  my $gene_identifiers = shift;

  my $genotype_lookup = $self->genotype_lookup();

  if (!$genotype_lookup) {
    return ();
  }

  my %options = ();

  if (defined $max) {
    if ($max == 0) {
      return ();
    } else {
      $options{max_results} = $max;
    }
  }

  if (defined $gene_identifiers && @$gene_identifiers > 0) {
    $options{gene_primary_identifiers} = $gene_identifiers;
  }

  return @{$genotype_lookup->lookup(%options)->{results}};
}

sub _genotype_details_hash
{
  my $self = shift;
  my $genotype = shift;
  my $include_allele = shift;

  my $config = $self->config();

  my $organism_lookup = $self->organism_lookup();
  my $organism_details = $organism_lookup->lookup_by_taxonid($genotype->organism()->taxonid());

  my $strain_name = undef;

  my $strain = $genotype->strain();

  if ($strain) {
    $strain_name = $strain->strain_name();

    if (!$strain_name && $strain->track_strain_id()) {
      my $strain_lookup = $self->strain_lookup();
      my @strain_details =
        $strain_lookup->lookup_by_strain_ids($strain->track_strain_id());
      if (@strain_details) {
        $strain_name = $strain_details[0]->{strain_name};
      }
    }
  }

  my %metagenotype_count_by_type = $genotype->metagenotype_count_by_type();

  my %ret = (
    identifier => $genotype->identifier(),
    name => $genotype->name(),
    background => $genotype->background(),
    comment => $genotype->comment(),
    allele_string => $genotype->allele_string($config),
    display_name => $genotype->display_name($config),
    genotype_id => $genotype->genotype_id(),
    annotation_count => $genotype->annotations()->count(),
    metagenotype_count_by_type => \%metagenotype_count_by_type,
    strain_name => $strain_name,
    organism => $organism_details,
  );

  if ($include_allele) {
    my %diploid_names = ();

    my $curs_schema = $self->curs_schema();
    my $allele_genotype_rs = $curs_schema->resultset('AlleleGenotype')
      ->search({ genotype => $genotype->genotype_id() },
               { prefetch => [qw[diploid allele]] });

    my @alleles = ();

    my %allele_count_per_locus = ();
    my $locus_count = 0;

    while (defined (my $row = $allele_genotype_rs->next())) {
      my $allele = $row->allele();
      push @alleles, $allele;
      my $diploid = $row->diploid();
      if ($diploid) {
        if (exists $allele_count_per_locus{$diploid->name()}) {
          $allele_count_per_locus{$diploid->name()}++;
        } else {
          $allele_count_per_locus{$diploid->name()} = 1;
          $locus_count++;
        }
        push @{$diploid_names{$allele->allele_id()}}, $diploid->name();
      } else {
        $locus_count++;
      }
    }

    my @allele_hashes = map { $self->_allele_details_hash($_); } @alleles;

    my %allele_type_order = ();

    for (my $idx = 0; $idx < @{$config->{allele_type_list}}; $idx++) {
      my $allele_config = $config->{allele_type_list}->[$idx];

      $allele_type_order{$allele_config->{name}} = $idx;
    }

    map {
      if ($diploid_names{$_->{allele_id}}) {
        my $diploid_name = pop(@{$diploid_names{$_->{allele_id}}});
        if ($diploid_name) {
          $_->{diploid_name} = $diploid_name;
        }
      }
    } @allele_hashes;

    @allele_hashes = sort {
      ($allele_type_order{$a->{type}} // 0) <=> ($allele_type_order{$b->{type}} // 0);
    } @allele_hashes;

    $ret{alleles} = [@allele_hashes];

    $ret{diploid_locus_count} = 0;

    map {
      my $diploid_name = $_;
      if ($allele_count_per_locus{$diploid_name} > 1) {
        $ret{diploid_locus_count}++;
      }
    } keys %allele_count_per_locus;

    $ret{locus_count} = $locus_count;
  }

  return \%ret;
}

sub _get_genes
{
  my $self = shift;
  my $curs_schema = $self->curs_schema();
  my $gene_rs = $curs_schema->resultset('Gene');
  my @res = sort {
    if ($a->{display_name} =~ /^[A-Z]/ &&
        $b->{display_name} !~ /^[A-Z]/) {
      1;
    } else {
      if ($a->{display_name} !~ /^[A-Z]/ &&
          $b->{display_name} =~ /^[A-Z]/) {
        -1;
      } else {
        $a->{display_name} cmp $b->{display_name};
      }
    }
  } map {
    my $proxy =
      Canto::Curs::GeneProxy->new(config => $self->config(),
                                  cursdb_gene => $_);
    my $organism_details = $proxy->organism_details();

    {
      primary_identifier => $proxy->primary_identifier(),
      primary_name => $proxy->primary_name(),
      display_name => $proxy->display_name(),
      gene_id => $proxy->gene_id(),
      feature_id => $proxy->gene_id(),
      organism => {
        full_name => $organism_details->{full_name},
        taxonid => $organism_details->{taxonid},
        pathogen_or_host => $organism_details->{pathogen_or_host},
      },
    }
  } $gene_rs->all();
}

sub _sort_genotypes_by_allele_type
{
  my $self = shift;
  my @genotype_hashes = @_;

  my $config = $self->config();

  my %allele_type_order = ();

  for (my $idx = 0; $idx < @{$config->{allele_type_list}}; $idx++) {
    my $allele_config = $config->{allele_type_list}->[$idx];

    $allele_type_order{$allele_config->{name}} = $idx;
  }

  my $sorter = sub {
    my $genotype_a = shift;
    my $genotype_b = shift;

    my $genotype_a_allele_count = 0;

    if ($genotype_a->{alleles}) {
      $genotype_a_allele_count = scalar(@{$genotype_a->{alleles}})
    }

    my $genotype_b_allele_count = 0;

    if ($genotype_b->{alleles}) {
      $genotype_b_allele_count = scalar(@{$genotype_b->{alleles}})
    }

    if ($genotype_a_allele_count == 0 && $genotype_b_allele_count == 0) {
      return 0;
    }

    if ($genotype_a_allele_count == 0) {
      return -1;
    }

    if ($genotype_b_allele_count == 0) {
      return 1;
    }

    my $allele_a = $genotype_a->{alleles}->[0];
    my $allele_b = $genotype_b->{alleles}->[0];

    if (!defined $allele_a->{type} && !defined $allele_b->{type}) {
      return 0;
    }

    if (!defined $allele_a->{type}) {
      return -1;
    }

    if (!defined $allele_b->{type}) {
      return 1;
    }

    my $res =
      ($allele_type_order{$allele_a->{type}} // 0)
        <=>
      ($allele_type_order{$allele_b->{type}} // 0);

    if ($res == 0) {
      # fail back, just try a user-friendly ordering
      my $allele_a_name = lc $allele_a->{name} // 'UNKNOWN';
      my $allele_a_description = $allele_a->{description} // 'UNKNOWN';
      my $allele_a_type = $allele_a->{type} // 'UNKNOWN';
      my $allele_a_expression = $allele_a->{expression} // 'UNKNOWN';

      my $allele_b_name = lc $allele_b->{name} // 'UNKNOWN';
      my $allele_b_description = $allele_b->{description} // 'UNKNOWN';
      my $allele_b_type = $allele_b->{type} // 'UNKNOWN';
      my $allele_b_expression = $allele_b->{expression} // 'UNKNOWN';

      "$allele_a_name-$allele_a_description-$allele_a_type-$allele_a_expression"
        cmp
      "$allele_b_name-$allele_b_description-$allele_b_type-$allele_b_expression"
    } else {
      $res;
    }
  };

  return sort { $sorter->($a, $b) } @genotype_hashes;
}

sub _get_genotypes
{
  my $self = shift;
  my $arg = shift; # "curs_only", "external_only" or "all"
  my $options = shift;
  my $curs_schema = $self->curs_schema();
  my $genotype_rs = $curs_schema->resultset('Genotype');

  my $filter = undef;
  my $max = undef;
  my $include_allele = 0;
  my $pathogen_or_host = undef;

  if (defined $options) {
    $filter = $options->{filter};
    $max = $options->{max};
    $include_allele = $options->{include_allele} // 0;
    $pathogen_or_host = $options->{pathogen_or_host};
  }

  if ($filter) {
    my $gene_identifiers = $filter->{gene_identifiers};
    $genotype_rs = _filter_by_gene_identifiers($curs_schema, $genotype_rs,
                                               $gene_identifiers);
  }

  if ($max) {
    $genotype_rs = $genotype_rs->search({}, { rows => $max });
  }

  my @res = ();

  my $organism_lookup = $self->organism_lookup();

  if ($arg eq 'curs_only' || $arg eq 'all') {
    @res =
      map {
        my $genotype = $_;
        $self->_genotype_details_hash($genotype, $include_allele);
      }
      grep {
        my $genotype = $_;

        if ($genotype->alleles()->count() == 0) {
          # wild type genotype
          0;
        } else {
          if ($pathogen_or_host) {
            my $organism_details =
              $self->organism_lookup->lookup_by_taxonid($genotype->organism()->taxonid());

            $pathogen_or_host eq $organism_details->{pathogen_or_host};
          } else {
            1;
          }
        }
      }
      $genotype_rs->all();
  }

  if ($arg eq 'external_only' || $arg eq 'all') {
    my $lookup_max = undef;

    if (defined $max) {
      $lookup_max = $max - scalar(@res);
    } else {
      $lookup_max = undef;
    }

    if (!defined $lookup_max || $lookup_max > 0) {
      if ($filter) {
        my $gene_identifiers = $filter->{gene_identifiers};
        push @res,
          $self->_filter_lookup_genotypes($lookup_max, $gene_identifiers);
      } else {
        push @res,
          $self->_filter_lookup_genotypes($lookup_max);
      }
    }
  }

  if ($self->config()->{sort_genotype_management_page_by_allele_type}) {
    @res = $self->_sort_genotypes_by_allele_type(@res);
  }

  return @res;
}

sub _get_metagenotypes
{
  my $self = shift;
  my $options = shift;

  my $curs_schema = $self->curs_schema();

  my $prefetch_options =
    [{ pathogen_genotype => 'organism'}, {host_genotype => 'organism' }];
  my $metagenotype_rs =
    $curs_schema->resultset('Metagenotype', { prefetch => $prefetch_options });

  my @res = ();

  my $include_allele = $options->{include_allele} // 0;

  while (defined (my $metagenotype = $metagenotype_rs->next())) {
    if ($options->{pathogen_taxonid} &&
        $metagenotype->pathogen_genotype()->organism()->taxonid() != $options->{pathogen_taxonid}) {
      next;
    }
    if ($options->{host_taxonid} &&
        $metagenotype->host_genotype()->organism()->taxonid() != $options->{host_taxonid}) {
      next;
    }

    my $pathogen_genotype_hash =
      $self->_genotype_details_hash($metagenotype->pathogen_genotype(), $include_allele);
    my $host_genotype_hash =
      $self->_genotype_details_hash($metagenotype->host_genotype(), $include_allele);

    my $display_name =
      $pathogen_genotype_hash->{display_name} . ' ' .
      $pathogen_genotype_hash->{organism}->{scientific_name};
    if ($pathogen_genotype_hash->{strain_name}) {
      $display_name .= ' (' . $pathogen_genotype_hash->{strain_name} . ')';
    }
    $display_name .= ' / ' .
      $host_genotype_hash->{display_name} . ' ' .
      $host_genotype_hash->{organism}->{scientific_name};
    if ($host_genotype_hash->{strain_name}) {
      $display_name .= ' (' . $host_genotype_hash->{strain_name} . ')';
    }

    push @res, {
      metagenotype_id => $metagenotype->metagenotype_id(),
      feature_id => $metagenotype->metagenotype_id(),
      pathogen_genotype => $pathogen_genotype_hash,
      host_genotype => $host_genotype_hash,
      display_name => $display_name,
      annotation_count => $metagenotype->annotations()->count(),
    };
  }

  return @res;
}

sub _make_allelesynonym_hashes
{
  my $allele = shift;

  return map {
    {
      synonym => $_->synonym(),
      edit_status => $_->edit_status(),
    }
  } $allele->allelesynonyms()->all();
}

sub _allele_details_hash
{
  my $self = shift;
  my $allele = shift;

  if (ref $allele ne 'Canto::CursDB::Allele') {
    confess();
  }

  my $display_name = $allele->display_name($self->config());
  my $long_display_name = $allele->long_identifier($self->config());

  my @synonyms_list = _make_allelesynonym_hashes($allele);

  my %notes = map {
    (
      $_->key(),
      $_->value(),
    );
  } $allele->allele_notes()->all();

  my %result = (
    uniquename => $allele->primary_identifier(),
    name => $allele->name(),
    description => $allele->description(),
    type => $allele->type(),
    expression => $allele->expression(),
    display_name => $display_name,
    long_display_name => $long_display_name,
    comment => $allele->comment(),
    allele_id => $allele->allele_id(),
    synonyms => \@synonyms_list,
    notes => \%notes,
  );

  if ($allele->type() !~ /^aberration/) {
    $result{gene_id} = $allele->gene()->gene_id();

    my $gene_proxy =
      Canto::Curs::GeneProxy->new(config => $self->config(),
                                  cursdb_gene => $allele->gene());

    $result{gene_display_name} = $gene_proxy->display_name();
    $result{gene_systematic_id} = $gene_proxy->primary_identifier();
  }

  return \%result;
}

sub _get_alleles
{
  my $self = shift;
  my $gene_primary_identifier = shift;
  my $search_string = shift;
  my $curs_schema = $self->curs_schema();
  my $query = {};

  if ($gene_primary_identifier ne ':ALL:') {
    $query = {
      'gene.primary_identifier' => $gene_primary_identifier,
    };
  }

  if ($search_string ne ':ALL:') {
    $query->{name} = { -like => $search_string . '%' };
  }

  my $allele_rs = $curs_schema->resultset('Allele')
    ->search($query,
             {
               join => 'gene',
               # only return alleles that are part of a genotype
               where => \"me.allele_id IN (SELECT allele FROM allele_genotype)",
             });
  my @res = map {
    $self->_allele_details_hash($_);
  } $allele_rs->all();

  my $allele_lookup = $self->allele_lookup();

  my $max_results = 15;

  if (@res < $max_results && $allele_lookup) {
    my $lookup_res = $allele_lookup->lookup(gene_primary_identifier =>
                                              $gene_primary_identifier,
                                            search_string => $search_string);

    while (@res < $max_results && @$lookup_res > 0) {
      my $new_res = shift @$lookup_res;
      # add if there are no alleles with that name
      if (!grep {
        ($_->{name} // 'no_name') eq ($new_res->{name} // 'no_name');
      } @res) {
        push @res, $new_res;
      }
    }
  }

  return @res;
}

my %list_for_service_subs =
  (
    gene => \&_get_genes,
    genotype => \&_get_genotypes,
    metagenotype => \&_get_metagenotypes,
    allele => \&_get_alleles,
    annotation => \&_get_annotation,
    condition => \&_get_conditions,
    organism => \&_get_organisms,
    strain => \&_get_strains,
  );

=head2 list_for_service

 Usage   : my @result = $service_utils->list_for_service('genotype');
 Function: Return a summary list of the given curs data for sending as JSON to
           the browser.
 Args    : $type - the data type: eg. "genotype"
 Return  : a list of hash refs summarising a type.  Example for genotype:
           [ { identifier => 'SPCC63.05-unk ssm4delta' }, { ... }, ... ]

=cut

sub list_for_service
{
  my $self = shift;
  my $type = shift;
  my @args = @_;

  my $proc = $list_for_service_subs{$type};

  if (defined $proc) {
    return [$proc->($self, @args)];
  } else {
    die "unknown list type: $type\n";
  }
}

sub _get_genotype
{
  my $self = shift;

  my $query_type = shift;
  my $arg = shift;

  my $curs_schema = $self->curs_schema();
  my $genotype_rs = $curs_schema->resultset('Genotype');

  my %find_arg = ();

  if ($query_type eq 'by_id') {
    $find_arg{genotype_id} = $arg;
  } else {
    $find_arg{identifier} = $arg;
  }

  my $genotype = $genotype_rs->find(\%find_arg);

  if (!$genotype) {
    return undef;
  }

  return $self->_genotype_details_hash($genotype, 1);
}

sub _get_curator_details
{
  my $self = shift;

  my $curs_key = $self->get_metadata($self->curs_schema(), 'curs_key');

  my $curator_manager = $self->curator_manager();

  my ($curator_email, $curator_name, $curator_known_as,
      $accepted_date, $community_curated, $creation_date,
      $curs_curator_id, $curator_orcid) =
        $self->state()->curator_manager()->current_curator($curs_key);

  return {
    curator_email => $curator_email,
    curator_name => $curator_name,
    curator_known_as => $curator_known_as,
    curator_orcid => $curator_orcid,
    accepted_date => $accepted_date,
    # false means that an admin user is doing the curation
    community_curated => $community_curated ? JSON::true : JSON::false,
  };
}

sub _get_session_details
{
  my $self = shift;

  my $curs_schema = $self->curs_schema();

  my $pub_id = $self->get_metadata($self->curs_schema(), 'curation_pub_id');
  my $pub = $curs_schema->find_with_type('Pub', $pub_id);
  my ($state) = $self->state()->get_state($curs_schema);

  return {
    publication_uniquename => $pub->uniquename(),
    curator => $self->_get_curator_details(),
    state => $state,
  };
}

my %details_for_service_subs =
  (
    genotype => \&_get_genotype,
    session => \&_get_session_details,
  );

=head2 details_for_service

 Usage   : my $result = $service_utils->details_for_service('genotype', $id);
 Function: Return the details of the given curs data for sending as JSON to
           the browser.
 Args    : $type - the data type: eg. "genotype"
           $id - the database ID of the feature
 Return  : hash summarising the data.  Example for genotype:
           { identifier => 'SPCC63.05-unk ssm4delta', alleles => [ {...}, ... ] }

=cut

sub details_for_service
{
  my $self = shift;
  my $type = shift;
  my @args = @_;

  my $proc = $details_for_service_subs{$type};

  if (defined $proc) {
    my $res = $proc->($self, @args);

    if ($res) {
      return $res;
    } else {
      return {};
    }
  } else {
    die "unknown list type: $type\n";
  }
}


sub _lookup_gene_id
{
  my $schema = shift;
  my $gene_id = shift;

  return $schema->resultset('Gene')->find({ gene_id => $gene_id });
}

sub _term_name_from_id
{
  my $self = shift;
  my $term_id = shift;

  my $lookup = $self->ontology_lookup();
  my $res = $lookup->lookup_by_id(id => $term_id);

  if (defined $res) {
    return $res->{name};
  } else {
    return undef;
  }
}

sub _process_interaction_genotypes
{
  my $self = shift;
  my $genotype_a_id = shift;
  my $genotype_b_id = shift;

  if (!$genotype_a_id) {
    croak "missing genotype_a_id";
  }
  if (!$genotype_b_id) {
    croak "missing genotype_b_id";
  }

  my $genotype_manager =
    Canto::Curs::GenotypeManager->new(config => $self->config(),
                                      curs_schema => $self->curs_schema());

  my $genotype_a = $self->curs_schema()->resultset('Genotype')->find($genotype_a_id);
  my $genotype_b = $self->curs_schema()->resultset('Genotype')->find($genotype_b_id);

  my $metagenotype =
    $genotype_manager->find_metagenotype(interactor_a => $genotype_a,
                                         interactor_b => $genotype_b)
      //
    $genotype_manager->make_metagenotype(interactor_a => $genotype_a,
                                         interactor_b => $genotype_b);

  return $metagenotype;
}

sub make_annotation
{
  my ($self, $pub, $data_arg) = @_;

  if (!$data_arg) {
    croak "no \$data passed to make_annotation()\n";
  }

  my $data = clone $data_arg;

  if (!$pub) {
    croak "no publication passed to make_annotation()\n";
  }

  my $annotation_type_name = delete $data->{annotation_type};

  if (!defined $annotation_type_name) {
    die "no annotation_type passed in changes hash\n";
  }

  if (!$annotation_type_name) {
    die "no annotation_type_name passed to make_annotation()\n";
  }

  my $category = $self->_category_from_type($annotation_type_name);

  my $curs_schema = $self->curs_schema();

  my $evidence_types = $self->config()->{evidence_types};

  my $annotation_config = $self->config()->{annotation_types}->{$annotation_type_name};

  my $type_has_ev_codes = $annotation_config->{evidence_codes} &&
    scalar(@{$annotation_config->{evidence_codes}}) > 0;

  my $evidence_code = $data->{evidence_code};
  if (!defined $evidence_code && $type_has_ev_codes) {
    die "Adding annotation failed - no evidence_code\n";
  }

  my %annotation_data = ();

  my $term_ontid = $data->{term_ontid};

  if (defined $term_ontid) {
    if (!defined $self->_term_name_from_id($term_ontid)) {
      die "Adding annotation failed - invalid term ID\n";
    }

    $annotation_data{term_ontid} = $term_ontid;
  } else {
    if ($category ne 'interaction') {
      die "Adding annotation failed - no term ID\n";
    }
  }

  if (defined $evidence_code) {
    my $needs_with_gene = $evidence_types->{$evidence_code}->{with_gene};
    if ($needs_with_gene) {
      if (!$data->{with_gene_id}) {
        die "no 'with_gene_id' with passed in the data object to make_annotation()\n";
      }
    } else {
      if ($data->{with_gene_id}) {
        die "annotation with evidence code '$evidence_code' shouldn't have a 'with_gene_id' passed in the data\n";
      }
    }
  }

  my $feature_type = $annotation_config->{feature_type};

  if ($category eq 'interaction') {
    if ($feature_type eq 'metagenotype') {
      my $metagenotype =
        $self->_process_interaction_genotypes($data->{genotype_a_id}, $data->{genotype_b_id});

      delete $data->{genotype_a_id};
      delete $data->{genotype_b_id};

      $data->{feature_id} = $metagenotype->metagenotype_id();
      $data->{feature_type} = 'metagenotype';
    } else {
      if ($feature_type eq 'gene') {
        # the interacting gene is in $data
      } else {
        die "unexpected feature type for interaction: $feature_type\n";
      }
    }
  }

  my $current_date = Canto::Curs::Utils::get_iso_date();
  my $new_annotation =
    $curs_schema->create_with_type('Annotation',
                                   {
                                     type => $annotation_type_name,
                                     status => 'new',
                                     pub => $pub,
                                     creation_date => $current_date,
                                     data => { },
                                   });

  $self->_store_change_hash($new_annotation, $data);

  $self->_update_annotation_interactions($new_annotation, $data, 0);

  $self->set_annotation_curator($new_annotation);
  $self->metadata_storer()->store_counts($curs_schema);

  return $new_annotation;
}

sub _check_curs_key
{
  my $self = shift;
  my $details = shift;

  my $curs_key = $self->get_metadata($self->curs_schema(), 'curs_key');

  if (!defined $details->{key} || $details->{key} ne $curs_key) {
    die "incorrect key\n";
  }

  delete $details->{key};
}

sub _store_interaction_annotation_with_phenotypes
{
  my $curs_schema = shift;
  my $interaction_type = shift;
  my $primary_genotype_annotation_id = shift;
  my $genotype_a_id = shift;
  my $genotype_a_phenotype_annotation_id = shift;
  my $genotype_b_id = shift;

  my $genotype_annotation = $curs_schema->resultset('GenotypeAnnotation')
    ->find({
      genotype => $genotype_a_id,
      annotation => $genotype_a_phenotype_annotation_id,
    });

  $curs_schema->resultset('GenotypeInteractionWithPhenotype')
    ->find_or_create({
      interaction_type => $interaction_type,
      primary_genotype_annotation_id => $primary_genotype_annotation_id,
      genotype_annotation_a_id => $genotype_annotation->genotype_annotation_id(),
      genotype_b_id => $genotype_b_id,
    });
}

sub _store_interaction_annotation
{
  my $curs_schema = shift;
  my $interaction_type = shift;
  my $primary_genotype_annotation_id = shift;
  my $genotype_a_id = shift;
  my $genotype_b_id = shift;

  $curs_schema->resultset('GenotypeInteraction')
    ->find_or_create({
      interaction_type => $interaction_type,
      primary_genotype_annotation_id => $primary_genotype_annotation_id,
      genotype_a_id => $genotype_a_id,
      genotype_b_id => $genotype_b_id,
    });
}

sub _ontology_change_keys
{
  my $self = shift;
  my $annotation = shift;
  my $changes = shift;

  my $lookup = Canto::Track::get_adaptor($self->config(), 'ontology');
  my $data = $annotation->data();

  return (
    term_ontid => sub {
      my $term_ontid = shift;

      my $category = $self->_category_from_type($annotation->type());

      if (!defined $term_ontid) {
        if ($category eq 'interaction') {
          delete $data->{term_ontid};
          return 1;
        } else {
          die "no term_ontid passed to change_annotation()\n";
        }
      }

      my $res = $lookup->lookup_by_id( id => $term_ontid );

      if ($res->{annotation_type_name}) {
        my $annotation_config = $self->config()->{annotation_types}->{$annotation->type()};

        if ($annotation_config->{name} eq 'biological_process' ||
            $annotation_config->{name} eq 'molecular_function' ||
            $annotation_config->{name} eq 'cellular_component') {
          # special handling for the case where a GO ID from the
          # wrong aspect is pasted into the annotation edit dialog
          $annotation->type($res->{annotation_type_name});
        }
      }

      if (defined $res) {
        # do the default - set Annotation->data()->{...}
        return 0;
      } else {
        die "no such term ID: $term_ontid";
      }
    },
    evidence_code => sub {
      my $evidence_code = shift;

      my @type_evidence_codes = $self->_evidence_codes_from_type($annotation->type());

      if (@type_evidence_codes && !$evidence_code) {
        die "configuration error: this annotation type requires an evidence code";
      }

      if (@type_evidence_codes) {
        my $evidence_config = $self->config()->{evidence_types}->{$evidence_code};

        if (defined $evidence_config) {
          # do the default - set Annotation->data()->{...}
          return 0
        } else {
          die "no such evidence code: $evidence_code\n";
        }
      } else {
        if ($evidence_code) {
          die "configuration error: tried to store an evidence code for an " .
            "annotation type with no evidence codes configured";
        }
      }
    },
    feature_type => sub {
      return 1;
    },
    feature_id => sub {
      my $feature_id = shift;

      if (!defined $changes->{feature_type}) {
        die "no feature_type passed to ServiceUtils\n";
      }

      if ($changes->{feature_type} eq 'gene') {
        my $gene = $self->curs_schema()->find_with_type('Gene', { gene_id => $feature_id });
        $annotation->gene_annotations()->delete();
        $annotation->set_genes($gene);
      } else {
        if ($changes->{feature_type} eq 'genotype') {
          my $genotype =
            $self->curs_schema()->find_with_type('Genotype', { genotype_id => $feature_id });
          $annotation->genotype_annotations()->delete();
          $annotation->set_genotypes($genotype);
        } else {
          if ($changes->{feature_type} eq 'metagenotype') {
            my $metagenotype =
              $self->curs_schema()->find_with_type('Metagenotype', { metagenotype_id => $feature_id });
            $annotation->metagenotype_annotations()->delete();
            $annotation->set_metagenotypes($metagenotype);
          } else {
            die "unknown feature type: ", $changes->{feature_type};
          }
        }
      }
      return 1;
    },
    submitter_comment => 1,
    figure => 1,
    extension => sub {
      my $extension = shift // [];

      for my $and_group (@$extension) {
        for my $ext_part (@$and_group) {
          if ($ext_part->{rangeType} &&
              $ext_part->{rangeType} eq 'Metagenotype') {
            # the display name will be created as needed since it can change
            # over time if the genotype details change
            delete $ext_part->{rangeDisplayName};
          }
        }
      }

      # set the extension as usual
      return 0;
    },
    organism => 1,
    with_gene_id => sub {
      my $gene_id = shift;

      if ($gene_id) {
        my $gene = _lookup_gene_id($self->curs_schema(), $gene_id);

        if (defined $gene) {
          $data->{with_gene} = $gene->primary_identifier();
          return 1;
        } else {
          die "can't find gene with id: $gene_id\n";
        }
      } else {
        # set with_gene to undef
        return undef;
      }
    },
    term_suggestion_name => sub {
      my $suggested_name = shift;
      if ($suggested_name) {
        $data->{term_suggestion}->{name} = $suggested_name;
      } else {
        delete $data->{term_suggestion}->{name};
      }
      return 1;
    },
    term_suggestion_definition => sub {
      my $suggested_definition = shift;
      if ($suggested_definition) {
        $data->{term_suggestion}->{definition} = $suggested_definition;
      } else {
        delete $data->{term_suggestion}->{definition};
      }
      return 1;
    },
    conditions => sub {
      my $condition_data = shift;
      my @condition_names =
        map { $_->{name}; } @$condition_data;
      my @conditions_with_ids =
        Canto::Curs::ConditionUtil::get_conditions_from_names($lookup,
                                                              \@condition_names);
      $data->{conditions} =
        [ map { $_->{term_id} // $_->{name} } @conditions_with_ids ];

      return 1;
    },
    qualifiers => sub {
      warn "storing of qualifiers is not implemented\n";
      return 1;
    },
    alleles => sub {
      warn "storing of alleles is not implemented\n";
      return 1;
    },
    interaction_annotations => sub {
      return 1;
    },
    interaction_annotations_with_phenotypes => sub {
      return 1;
    }
  )
}

sub _interaction_change_keys
{
  my $self = shift;
  my $annotation = shift;
  my $changes = shift;

  my $data = $annotation->data();

  return (
    evidence_code => sub {
      my $evidence_code = shift;

      my $evidence_config = $self->config()->{evidence_types}->{$evidence_code};

      if (defined $evidence_config) {
        # do the default - set Annotation->data()->{...}
        return 0
      } else {
        die "no such evidence code: $evidence_code\n";
      }
    },
    feature_id => sub {
      my $feature_id = shift;

      my $gene = $self->curs_schema()->find_with_type('Gene', { gene_id => $feature_id });
      $annotation->gene_annotations()->delete();
      $annotation->set_genes($gene);

      return 1;
    },
    feature_type => sub {
      my $feature_type = shift;

      if ($feature_type ne 'gene') {
        die qq(incorrect feature_type "$feature_type" for interaction - needed "gene"\n);
      }

      return 1;
    },
    interacting_gene_id => sub {
      my $gene_id = shift;

      if ($gene_id) {
        my $gene = _lookup_gene_id($self->curs_schema(), $gene_id);

        if (defined $gene) {
          $data->{interacting_genes} =
            [
              {
                primary_identifier => $gene->primary_identifier(),
              },
            ];
          return 1;
        } else {
          die "can't find gene with id: $gene_id\n";
        }
      } else {
        die "no interacting_gene_id passed to service\n";
      }
    },
    submitter_comment => 1,
    figure => 1,
  );
}


sub _store_change_hash
{
  my $self = shift;
  my $annotation = shift;
  my $changes = shift;

  $self->_check_curs_key($changes);

  my %valid_change_keys;

  my $annotation_config = $self->config()->{annotation_types}->{$annotation->type()};

  my $category = $self->_category_from_type($annotation->type());

  if ($category eq 'ontology' ||
      $category eq 'interaction' && $annotation_config->{feature_type} eq 'metagenotype') {
    %valid_change_keys = $self->_ontology_change_keys($annotation, $changes);
  } else {
    if ($category eq 'interaction' && $annotation_config->{feature_type} eq 'gene') {
      %valid_change_keys = $self->_interaction_change_keys($annotation, $changes);
    } else {
      die "can't find category for ", $annotation->type(), "\n";
    }
  }

  my $data = $annotation->data();

 CHANGE: for my $key (keys %$changes) {
    my $conf = $valid_change_keys{$key};

    if (!defined $conf) {
      die "No such annotation field type: $key\n";
    }

    my $value = $changes->{$key};

    my $key_to_set = $key;

    if (ref $conf eq 'CODE') {
      my $result = undef;

      my $res = $conf->($value);

      if ($res) {
        if (!ref $res && looks_like_number($res)) {
          # non-zero was returned - do nothing
          next CHANGE;
        } else {
          # it returned a different key to set
          $key_to_set = $res;
        }
      }
    }

    $data->{$key_to_set} = $changes->{$key};
  }

  my $evidence_code = $data->{evidence_code};

  if (defined $evidence_code) {
    my $evidence_config = $self->config()->{evidence_types}->{$evidence_code};

    if (!$evidence_config->{with_gene}) {
      delete $data->{with_gene};
    }
  }

  if ($data->{term_suggestion} &&
      (keys (%{$data->{term_suggestion}}) == 0 ||
         !$data->{term_suggestion}->{name} && !$data->{term_suggestion}->{definition})) {
    delete $data->{term_suggestion};
  }

  if (!$annotation->gene_annotations() &&
      !$annotation->genotype_annotations()) {
    die "annotation ", $annotation->annotation_id(),
      " has no gene or genotype\n";
  }

  $self->_update_annotation_interactions($annotation, $changes, 0);

  $annotation->data($data);
  $annotation->update();
}


sub _update_annotation_interactions
  {
    my $self = shift;
    my $annotation = shift;
    my $changes = shift;
    my $merge_with_existing = shift;

    if ($annotation->genotype_annotations()->count() > 0) {
      # only try this for phenotype annotations

      my $primary_genotype_annotation =
        $annotation->genotype_annotations()->first();
      my $primary_genotype_annotation_id =
        $primary_genotype_annotation->genotype_annotation_id();

      my @existing_interactions_without_phenotypes = ();
      my @existing_interactions_with_phenotypes = ();

      if ($merge_with_existing) {

        my $ontology_lookup =
          Canto::Track::get_adaptor($self->config(), 'ontology');
        my $organism_lookup =
          Canto::Track::get_adaptor($self->config(), 'organism');

        my @existing_interactions =
          Canto::Curs::Utils::make_interaction_annotations($self->config(),
                                                           $self->curs_schema(),
                                                           $annotation,
                                                           $ontology_lookup,
                                                           $organism_lookup);

        map {
          if (exists $_->{genotype_a_phenotype_annotations}) {
            push @existing_interactions_with_phenotypes, $_;
          } else {
            push @existing_interactions_without_phenotypes, $_;
          }
        } @existing_interactions;
      }

      my $interaction_annotations_with_phenotypes =
        $changes->{interaction_annotations_with_phenotypes};

      if (defined $interaction_annotations_with_phenotypes) {
        # remove, then re-add interactions without phenotypes
        $primary_genotype_annotation
          ->genotype_interactions_with_phenotype_primary_genotype_annotation()
          ->delete();


        map {
          my $dir_annotation = $_;

          my $interaction_type = $dir_annotation->{interaction_type};
          my $genotype_a_id = $dir_annotation->{genotype_a}->{genotype_id};
          my $genotype_b_id = $dir_annotation->{genotype_b}->{genotype_id};
          map {
            my $genotype_a_phenotype_id = $_->{annotation_id};

            _store_interaction_annotation_with_phenotypes($self->curs_schema(),
                                                          $interaction_type,
                                                          $primary_genotype_annotation_id,
                                                          $genotype_a_id,
                                                          $genotype_a_phenotype_id,
                                                          $genotype_b_id);

          } @{$dir_annotation->{genotype_a_phenotype_annotations}};
        } (@existing_interactions_with_phenotypes, @$interaction_annotations_with_phenotypes);

      }


      my $interaction_annotations =
        $changes->{interaction_annotations};

      if (defined $interaction_annotations) {
        $primary_genotype_annotation->genotype_interactions()->delete();

        map {
          my $interaction_annotation = $_;

          my $interaction_type = $interaction_annotation->{interaction_type};
          my $genotype_a_id = $interaction_annotation->{genotype_a}->{genotype_id};
          my $genotype_b_id = $interaction_annotation->{genotype_b}->{genotype_id};

          _store_interaction_annotation($self->curs_schema(),
                                        $interaction_type,
                                        $primary_genotype_annotation_id,
                                        $genotype_a_id,
                                        $genotype_b_id);

        } (@existing_interactions_without_phenotypes, @$interaction_annotations);

      }
    }
  }

sub _category_from_type
{
  my $self = shift;
  my $type_name = shift;

  my $annotation_config = $self->config()->{annotation_types}->{$type_name};

  return $annotation_config->{category};
}

sub _evidence_codes_from_type
{
  my $self = shift;
  my $type_name = shift;

  my $annotation_config = $self->config()->{annotation_types}->{$type_name};

  return @{$annotation_config->{evidence_codes} || []};
}

sub _make_error
{
  my $message = shift;

  return {
    status => 'error',
    message => $message,
  };
}

=head2

 Usage   : $service_utils->change_annotation($annotation_id, 'new'|'existing',
                                             $changes);
 Function: Change an annotation in the Curs database based on the $changes hash.
 Args    : $annotation_id
           $changes - a hash that specifies which parts of the annotation are
                      to change, with these possible keys:
                      comment - set the comment
 Return  :

=cut

sub change_annotation
{
  my $self = shift;
  my $annotation_id = shift;

  my $changes = shift;

  my $curs_schema = $self->curs_schema();

  my $pub_id = $self->get_metadata($curs_schema, 'curation_pub_id');
  my $pub = $curs_schema->resultset('Pub')->find($pub_id);

  my $annotation = $curs_schema->resultset('Annotation')->find($annotation_id);
  my $annotation_type_name = $annotation->type();
  my $category = $self->_category_from_type($annotation_type_name);

  if ($category eq 'ontology') {
    my $details =
      Canto::Curs::Utils::make_ontology_annotation($self->config(),
                                                   $curs_schema, $annotation);

    my %details_for_find = (%$details, %$changes);

    my $existing_annotation = $self->find_existing_annotation(\%details_for_find);

    if (defined $existing_annotation) {
      $self->_update_annotation_interactions($existing_annotation, $changes, 1);

      my $existing_annotation_hash =
        Canto::Curs::Utils::make_ontology_annotation($self->config(),
                                                     $curs_schema,
                                                     $existing_annotation);

      return { status => 'existing',
               annotation => $existing_annotation_hash };
    }
  }

  $curs_schema->txn_begin();

  try {
    my $orig_metagenotype = undef;

    my $annotation_config = $self->config()->{annotation_types}->{$annotation_type_name};

    if ($annotation_config->{category} eq 'interaction' &&
      $annotation_config->{feature_type} eq 'metagenotype') {
      my $genotype_a_id = delete $changes->{genotype_a_id};
      my $genotype_b_id = delete $changes->{genotype_b_id};

      if ($genotype_a_id || $genotype_b_id) {
        $orig_metagenotype = $annotation->metagenotype_annotations()
          ->search({ }, { prefetch => 'metagenotype' })->first()->metagenotype();

        $genotype_a_id //= $orig_metagenotype->first_genotype_id();
        $genotype_b_id //= $orig_metagenotype->second_genotype_id();

        my $new_metagenotype =
          $self->_process_interaction_genotypes($genotype_a_id, $genotype_b_id);

        $changes->{feature_id} = $new_metagenotype->metagenotype_id();
        $changes->{feature_type} = 'metagenotype';
      }
    }

    $self->_store_change_hash($annotation, $changes);

    if ($orig_metagenotype) {
      my $rs = $orig_metagenotype->metagenotype_annotations();
      if ($rs->count() == 0) {
        $orig_metagenotype->delete();
      }
    }

    my $annotation_hash;

    if ($self->_category_from_type($annotation->type()) eq 'ontology') {
      $annotation_hash =
        Canto::Curs::Utils::make_ontology_annotation($self->config(),
                                                     $curs_schema,
                                                     $annotation, undef, undef,
                                                     1, 1);
    } else {
      $annotation_hash =
        Canto::Curs::Utils::make_interaction_annotation($self->config(),
                                                        $curs_schema,
                                                        $annotation);
    }
    $self->metadata_storer()->store_counts($curs_schema);

    $curs_schema->txn_commit();

    return { status => 'success',
             annotation => $annotation_hash };
  } catch {
    $curs_schema->txn_rollback();

    chomp $_;

    return _make_error($_);
  };
}

sub safe_equals
{
  my $a = shift;
  my $b = shift;

  if (ref $a or ref $b) {
    die;
  } else {
    if (!defined $a and !defined $b) {
      return 1;
    } else {
      if (defined $a and defined $b) {
        return $a eq $b
      } else {
        return 0;
      }
    }
  }
}

sub conditions_equal
{
  my $self = shift;

  my $existing_conditions = shift // [];
  my $new_conditions = shift // [];

  my @existing_condition_names = sort map {
    $self->_term_name_from_id($_) // $_;
  } @$existing_conditions;

  my @new_condition_names = sort map {
    $_->{name};
  } @$new_conditions;

  return (join ":::", @existing_condition_names) eq (join ":::", @new_condition_names);
}

sub extension_equal
{
  my $existing_extension = shift // [];
  my $new_extension = shift // [];

  if (@$existing_extension > 1 || @$new_extension > 1) {
    # give up because one of the annotations has an "independent
    # extension" and was created by an admin
    return 0;
  }

  if (@$existing_extension == 0 && @$new_extension == 0) {
    return 1;
  }

  if (@$existing_extension == 0 || @$new_extension == 0) {
    return 0
  }

  my @existing_and_parts = @{$existing_extension->[0]};
  my @new_and_parts = @{$new_extension->[0]};

  if (scalar(@existing_and_parts) != scalar(@new_and_parts)) {
    return 0;
  }

  my $sorter = sub {
    my $a = shift;
    my $b = shift;

    ($a->{relation} // 'UNKNOWN') cmp ($b->{relation} // 'UNKNOWN')
      ||
    ($a->{rangeType} // 'UNKNOWN') cmp ($b->{rangeType} // 'UNKNOWN')
      ||
    ($a->{rangeValue} // 'UNKNOWN') cmp ($b->{rangeValue} // 'UNKNOWN')
  };

  my @sorted_existing_and_parts = sort {
    $sorter->($a, $b);
  } @existing_and_parts;

  my @sorted_new_and_parts = sort {
    $sorter->($a, $b);
  } @new_and_parts;

  for (my $i = 0; $i < @sorted_new_and_parts; $i++) {
    my $new_part = $sorted_new_and_parts[$i];
    my $existing_part = $sorted_existing_and_parts[$i];
    if ($new_part->{relation} ne $existing_part->{relation} ||
        $new_part->{rangeType} ne $existing_part->{rangeType} ||
        $new_part->{rangeValue} ne $existing_part->{rangeValue}) {
      return 0;
    }
  }

  return 1;
}


sub find_existing_annotation
{
  my $self = shift;

  my $details = shift;

  my $curs_schema = $self->curs_schema();

  my $annotation_type_name = $details->{annotation_type};
  my $annotation_type =
    $self->config()->get_annotation_type_by_name($annotation_type_name);

  my $feature_id = $details->{feature_id};
  my $feature_type = $details->{feature_type};
  my $term_ontid = $details->{term_ontid};

  my $base_rs;

  if ($feature_type eq 'gene') {
    $base_rs = $curs_schema->resultset('GeneAnnotation');
  } else {
    if ($feature_type eq 'genotype') {
      $base_rs = $curs_schema->resultset('GenotypeAnnotation');
    } else {
      if ($feature_type eq 'metagenotype') {
        $base_rs = $curs_schema->resultset('MetagenotypeAnnotation');
      } else {
        return undef;
      }
    }
  }

  my $rs = $base_rs->search(
    {
      $feature_type => $feature_id,
      'annotation.type' => $annotation_type_name,
    },
    {
      prefetch => 'annotation'
    });

  while (defined (my $row = $rs->next())) {
    my $existing_annotation = $row->annotation();

    if (defined $details->{annotation_id} &&
        $existing_annotation->annotation_id() == $details->{annotation_id}) {
      next;
    }

    my $existing_data = $existing_annotation->data();

    if ($existing_data->{term_ontid} ne $term_ontid) {
      next;
    }
    if ($existing_data->{evidence_code} ne $details->{evidence_code}) {
      next;
    }
    if (!safe_equals($existing_data->{with_gene_id}, $details->{with_gene_id})) {
      next;
    }
    if (!extension_equal($existing_data->{extension}, $details->{extension})) {
      next;
    }
    if (!$self->conditions_equal($existing_data->{conditions}, $details->{conditions})) {
      next;
    }

    return $existing_annotation;
  }

  return undef;
}


=head2

 Usage   : $service_utils->create_annotation($details);
 Function: Create an annotation in the Curs database based on the $details hash.
 Args    : $details - annotation details:
             - feature_id: a gene_id or a genotype_id
             - feature_type: "gene" or "genotype"
             - annotation_type: a CV name (eg. "molecular_function") - required
             - term_ontid: a term accession (eg. "GO:0000137") - required

 Return  : A hash of information about the new annotation suitable for returning
           as a JSON string

=cut

sub create_annotation
{
  my $self = shift;
  my $details = shift;

  if (!defined $details->{feature_id} && !defined $details->{genotype_a_id} &&
      !defined $details->{genotype_b_id}) {
    return _make_error('No feature(s) passed to annotation creation service');
  }

  my $annotation_type = $details->{annotation_type};

  if (!defined $annotation_type) {
    return _make_error('No annotation_type passed to annotation creation service');
  }

  my $curs_schema = $self->curs_schema();

  my $category = $self->_category_from_type($annotation_type);

  if ($category eq 'ontology') {
    my $existing_annotation = $self->find_existing_annotation($details);

    if (defined $existing_annotation) {
      $self->_update_annotation_interactions($existing_annotation, $details, 1);

      my $existing_annotation_hash =
        Canto::Curs::Utils::make_ontology_annotation($self->config(),
                                                     $curs_schema,
                                                     $existing_annotation);

      return { status => 'existing',
               annotation => $existing_annotation_hash };
    }
  }

  $curs_schema->txn_begin();

  try {
    my $curs_key = $self->get_metadata($curs_schema, 'curs_key');
    my $pub_id = $self->get_metadata($curs_schema, 'curation_pub_id');
    my $pub = $curs_schema->resultset('Pub')->find($pub_id);

    my $annotation = $self->make_annotation($pub, $details);

    my $annotation_hash = undef;

    if ($category eq 'ontology') {
      $annotation_hash =
        Canto::Curs::Utils::make_ontology_annotation($self->config(),
                                                     $curs_schema,
                                                     $annotation);
    } else {
      $annotation_hash =
        Canto::Curs::Utils::make_gene_interaction_annotation($self->config(),
                                                             $curs_schema,
                                                             $annotation);
    }

    $self->metadata_storer()->store_counts($curs_schema);

    $curs_schema->txn_commit();

    return { status => 'success',
             annotation => $annotation_hash };
  } catch {
    $curs_schema->txn_rollback();

    chomp $_;
    return _make_error($_);
  };
}

=head2

 Usage   : $service_utils->delete_annotation($details);
 Function: Delete an annotation in the Curs database
 Args    : $details - annotation details:
             - key: the curs key
             - annotation_id: ID of the annotation to delete

 Return  : { status: 'success' }
         or:
           { status: 'error', message: '...' }

=cut

sub delete_annotation
{
  my $self = shift;
  my $details = shift;

  my $curs_schema = $self->curs_schema();

  my $annotation_id = $details->{annotation_id};
  my $annotation = $curs_schema->find_with_type('Annotation', $annotation_id);

  for my $genotype_annotation ($annotation->genotype_annotations()) {
    my $interaction =
      $genotype_annotation->genotype_interactions_with_phenotype_primary_genotype_annotation()->first()
      //
      $genotype_annotation->genotype_interactions_with_phenotype_genotype_annotation_a()->first()
      //
      $genotype_annotation->genotype_interactions()->first();

    if ($interaction) {
      return {
        message => 'this annotation is used by a ' .
        $interaction->interaction_type() .
        ' interaction',
        status => 'error',
      };
    }
  }

  $curs_schema->txn_begin();

  try {
    $self->_check_curs_key($details);

    my @metagenotype_annotations = $annotation->metagenotype_annotations()
      ->search({}, { prefetch => 'metagenotype' })
      ->all();

    my @metagenotypes = map {
      $_->metagenotype();
    } @metagenotype_annotations;

    map {
      $_->delete();
    } @metagenotype_annotations;

    map {
      my $metagenotype = $_;
      if ($metagenotype->type() eq 'interaction') {
        if ($metagenotype->metagenotype_annotations()->count() == 0) {
          $metagenotype->delete();
        }
      }
    } @metagenotypes;

    $annotation->delete();

    $self->metadata_storer()->store_counts($curs_schema);

    $curs_schema->txn_commit();

    return { status => 'success' };
  } catch {
    $curs_schema->txn_rollback();

    chomp $_;
    return _make_error($_);
  }
}

=head2 delete_genotype

 Usage   : $utils->delete_genotype($genotype_id, $details);
 Function: Remove a genotype from the CursDB if it has no annotations.
           Any alleles not referenced by another Genotype will be removed too.
 Args    : $genotype_id
           $details - annotation details containing:
             - key: the curs key
 Return  : { status: 'success' }
         or:
           { status: 'error', message: '...' }

=cut

sub delete_genotype
{
  my $self = shift;
  my $genotype_id = shift;
  my $details = shift;

  my $curs_schema = $self->curs_schema();
  $curs_schema->txn_begin();

  try {
    $self->_check_curs_key($details);

    my $genotype_manager =
      Canto::Curs::GenotypeManager->new(config => $self->config(),
                                        curs_schema => $self->curs_schema());

    my $ret = $genotype_manager->delete_genotype($genotype_id);

    $self->metadata_storer()->store_counts($curs_schema);

    $curs_schema->txn_commit();

    if ($ret) {
      return {
        status => 'error',
        message => $ret,
      };
    } else {
      return {
        status => 'success',
      };
    }
  } catch {
    $curs_schema->txn_rollback();

    chomp $_;
    return _make_error($_);
  }
}

=head2 delete_metagenotype

 Usage   : $utils->delete_metagenotype($metagenotype_id, $details);
 Function: Remove a metagenotype from the CursDB if it has no annotations.
 Args    : $metagenotype_id
           $details - annotation details containing
             - key: the curs key
 Return  : { status: 'success' }
         or:
           { status: 'error', message: '...' }

=cut

sub delete_metagenotype
{
  my $self = shift;
  my $metagenotype_id = shift;
  my $details = shift;

  my $curs_schema = $self->curs_schema();
  $curs_schema->txn_begin();

  try {
    $self->_check_curs_key($details);

    my $genotype_manager =
      Canto::Curs::GenotypeManager->new(config => $self->config(),
                                        curs_schema => $self->curs_schema());

    my $ret = $genotype_manager->delete_metagenotype($metagenotype_id);

    $self->metadata_storer()->store_counts($curs_schema);

    $curs_schema->txn_commit();

    if ($ret) {
      return {
        status => 'error',
        message => $ret,
      };
    } else {
      return {
        status => 'success',
      };
    }
  } catch {
    $curs_schema->txn_rollback();

    chomp $_;
    return _make_error($_);
  }
}


=head2 add_gene_by_identifier

 Usage   : $service_utils->add_gene_by_identifier($gene_identifier);
 Function: Find a gene with a call to lookup() then store and return it
 Args    : $gene_identifier - the gene to find
 Return  : a hash, with keys:
              status - "success" or "error"
              gene_id - on success, the id of the new Gene
              message - on error, the error message

=cut

sub add_gene_by_identifier
{
  my $self = shift;
  my $gene_identifier = shift;

  my $gene_manager =
    Canto::Curs::GeneManager->new(config => $self->config(),
                                  curs_schema => $self->curs_schema());

  my @result = $gene_manager->find_and_create_genes([$gene_identifier]);

  if (@result == 1) {
    my %ret = (
      status => 'success',
    );

    my $new_gene = $result[0]->{$gene_identifier};

    if (defined $new_gene) {
      $ret{gene_id} = $new_gene->gene_id(),
    } else {
      # the gene was already in the session and wasn't added again
      $ret{gene_id} = undef;
    }

    return \%ret;
  } else {
    return _make_error(qq(couldn't find gene "$gene_identifier"));
  }
}


=head2 add_organism_by_taxonid

 Usage   : $service_utils->add_organism_by_taxonid($taxonid);
 Function: Add the given organism to the session
 Args    : $taxonid
 Return  : a hash, with keys:
              status - "success" or "error"
              message - on error, the error message

=cut

sub add_organism_by_taxonid
{
  my $self = shift;
  my $taxonid = shift;

  my $curs_schema = $self->curs_schema();

  my $organism_manager = $self->organism_manager();

  try {
    $curs_schema->txn_begin();

    my $organism = $organism_manager->add_organism_by_taxonid($taxonid);

    if ($organism) {
      $curs_schema->txn_commit();
      return {
        status => 'success',
      };
    } else {
      return {
        status => 'error',
        message => "organism with taxonid $taxonid not found",
      };
    }
  } catch {
    $curs_schema->txn_rollback();
    chomp $_;
    return _make_error($_);
  }
}

=head2 add_strain_by_id

 Usage   : $service_utils->add_strain_by_id($track_strain_id);
 Function: Add the strain with the given ID to the session
 Args    : $track_strain_id

=cut

sub add_strain_by_id
{
  my $self = shift;
  my $track_strain_id = shift;

  my $curs_schema = $self->curs_schema();

  my $strain_manager = $self->strain_manager();

  try {
    $curs_schema->txn_begin();

    my $strain = $strain_manager->add_strain_by_id($track_strain_id);

    if ($strain) {
      $curs_schema->txn_commit();
      return {
        status => 'success',
      };
    } else {
      return {
        status => 'error',
        message => "strain with ID $track_strain_id not found",
      };
    }
  } catch {
    $curs_schema->txn_rollback();
    chomp $_;
    return _make_error($_);
  }
}


=head2 add_strain_by_name

 Usage   : $service_utils->add_strain_by_name($taxon_id, $strain_name);
 Function: Add the strain with the given taxon ID and name to the session

=cut

sub add_strain_by_name
{
  my $self = shift;
  my $taxon_id = shift;
  my $strain_name = shift;

  my $curs_schema = $self->curs_schema();

  my $strain_manager = $self->strain_manager();

  try {
    $curs_schema->txn_begin();

    my $strain = $strain_manager->add_strain_by_name($taxon_id, $strain_name);

    if ($strain) {
      $curs_schema->txn_commit();
      return {
        status => 'success',
      };
    } else {
      return {
        status => 'error',
        message => "failed to create strain",
      };
    }
  } catch {
    $curs_schema->txn_rollback();
    chomp $_;
    return _make_error($_);
  }
}


=head2 delete_organism_by_taxonid

 Usage   : $service_utils->delete_organism_by_taxonid($taxonid);
 Function: Remove the given organism from the session.  Returns an error if
           there are genes or strains from that organism in the session.
 Args    : $taxonid
 Return  : a hash, with keys:
              status - "success" or "error"
              message - on error, the error message

=cut

sub delete_organism_by_taxonid
{
  my $self = shift;
  my $taxonid = shift;

  my $curs_schema = $self->curs_schema();

  my $organism_manager = $self->organism_manager();

  try {
    $curs_schema->txn_begin();

    my $organism = $organism_manager->delete_organism_by_taxonid($taxonid);

    if ($organism) {
      $curs_schema->txn_commit();
      return {
        status => 'success',
      };
    } else {
      return {
        status => 'error',
        message => "organism with taxonid $taxonid not found",
      };
    }
  } catch {
    $curs_schema->txn_rollback();
    chomp $_;
    return _make_error($_);
  }
}


=head2 delete_strain_by_id

 Usage   : $service_utils->delete_strain_by_id($track_strain_id);
 Function: Remove the given strain from the session.  Returns an error if
           there are genotypes that reference the strain
 Args    : $track_strain_id - the ID in the TrackDB
 Return  : a hash, with keys:
              status - "success" or "error"
              message - on error, the error message

=cut

sub delete_strain_by_id
{
  my $self = shift;
  my $track_strain_id = shift;

  my $curs_schema = $self->curs_schema();

  my $strain_manager = $self->strain_manager();

  try {
    $curs_schema->txn_begin();

    my $strain = $strain_manager->delete_strain_by_id($track_strain_id);

    if ($strain) {
      $curs_schema->txn_commit();
      return {
        status => 'success',
      };
    } else {
      return {
        status => 'error',
        message => "strain with ID $track_strain_id not found",
      };
    }
  } catch {
    $curs_schema->txn_rollback();
    chomp $_;
    return _make_error($_);
  }
}


=head2 delete_strain_by_name

 Usage   : $service_utils->delete_strain_by_name($taxon_id, $strain_name);
 Function: Remove the given strain from the session.  Returns an error if
           there are genotypes that reference the strain
 Args    : $taxon_id
           $strain_name
 Return  : a hash, with keys:
              status - "success" or "error"
              message - on error, the error message

=cut

sub delete_strain_by_name
{
  my $self = shift;
  my $taxon_id = shift;
  my $strain_name = shift;

  my $curs_schema = $self->curs_schema();

  my $strain_manager = $self->strain_manager();

  try {
    $curs_schema->txn_begin();

    my $strain = $strain_manager->delete_strain_by_name($taxon_id, $strain_name);

    if ($strain) {
      $curs_schema->txn_commit();
      return {
        status => 'success',
      };
    } else {
      return {
        status => 'error',
        message => "failed to delete strain",
      };
    }
  } catch {
    $curs_schema->txn_rollback();
    chomp $_;
    return _make_error($_);
  }
}

1;
