package PomCur::Controller::Tools;

use strict;
use warnings;
use parent 'Catalyst::Controller';
use Package::Alias PubmedUtil => 'PomCur::Track::PubmedUtil',
                   LoadUtil => 'PomCur::Track::LoadUtil';

use Clone qw(clone);


sub _get_status_cv
{
  my $schema = shift;

  my $cv_name = 'PomCur publication triage status';
  return $schema->find_with_type('Cv', { name => $cv_name });
}

sub _get_next_triage_pub
{
  my $schema = shift;
  my $new_cvterm = shift;

  my $constraint = {
    triage_status_id => $new_cvterm->cvterm_id()
  };

  my $options = {
    # nasty hack to order by pubmed ID
    order_by => {
      -asc => "cast((case me.uniquename like 'PMID:%' WHEN 1 THEN " .
        "substr(me.uniquename, 6) ELSE me.uniquename END) as integer)"
    },
    rows => 1,
  };

  return $schema->resultset('Pub')->search($constraint, $options)->single();
}

=head1 NAME

PomCur::Controller::Tools - Controller for PomCur user tools

=head1 METHODS

=cut
sub triage :Local {
  my ($self, $c) = @_;

  if (!defined $c->user() || $c->user()->role()->name() ne 'admin') {
    $c->stash()->{error} = "Log in as administrator to allow triaging";
    $c->forward('/front');
    $c->detach();
    return;
  }

  my $st = $c->stash();
  my $schema = $c->schema('track');
  my $cv = _get_status_cv($schema);

  my $pub_just_triaged = undef;

  my $return_pub_id = $c->req()->param('triage-return-pub-id');
  $st->{return_pub_id} = $return_pub_id;

  my $new_status_cvterm = $schema->find_with_type('Cvterm',
                                                  { cv_id => $cv->cv_id(),
                                                    name => 'New' });

  my $next_pub = undef;

  my $untriaged_pubs_count = $schema->resultset('Pub')->search({
    triage_status_id => $new_status_cvterm->cvterm_id(),
  })->count();

  if ($c->req()->param('submit')) {
    my $guard = $schema->txn_scope_guard;

    my $pub_id = $c->req()->param('triage-pub-id');
    my $status_name = $c->req()->param('submit');

    $pub_just_triaged = $schema->find_with_type('Pub', $pub_id);

    my $status = $schema->find_with_type('Cvterm', { name => $status_name,
                                                     cv_id => $cv->cv_id() });

    $pub_just_triaged->triage_status_id($status->cvterm_id());

    my $pubprop_types_cv_name = 'PomCur publication property types';

    my $pubprop_types_cv =
      $schema->find_with_type('Cv',
                              { name => $pubprop_types_cv_name });
    my $experiment_type =
      $schema->find_with_type('Cvterm',
                              { name => 'experiment_type',
                                cv_id => $pubprop_types_cv->cv_id() });
    $pub_just_triaged->pubprops()->search({ type_id => $experiment_type->cvterm_id() })
      ->delete();

    for my $exp_type_param ($c->req()->param('experiment-type')) {
      my $pubprop =
        $schema->create_with_type('Pubprop',
                                  { type_id => $experiment_type->cvterm_id(),
                                    value => $exp_type_param,
                                    pub_id => $pub_just_triaged->pub_id() });
    }

    my $corresponding_author_id =
      $c->req()->param('triage-corresponding-author-person-id');
    if (defined $corresponding_author_id && length $corresponding_author_id > 0) {
      if ($corresponding_author_id =~ /^\d+$/) {
        if (defined $schema->resultset('Person')->find({
          person_id => $corresponding_author_id
        })) {
          $pub_just_triaged->corresponding_author($corresponding_author_id);
        }
      }
    } else {
      # user may have used the "New ..." button
      my $new_name =
        $c->req()->param('triage-corresponding-author-add-name') // '';
      $new_name =~ s/^\s+//;
      $new_name =~ s/\s+$//;
      my $new_email =
        $c->req()->param('triage-corresponding-author-add-email') // '';
      $new_email =~ s/^\s+//;
      $new_email =~ s/\s+$//;

      if (length $new_name > 0 || length $new_email > 0) {
        my $new_params = clone $c->req()->params();
        delete $new_params->{submit};
        my $redirect_uri = $c->uri_for('/tools/triage', $new_params);
        if (length $new_email == 0) {
          $c->flash()->{error} =
            "No email address given for new user: $new_name";
          $c->res->redirect($redirect_uri);
        }
        if (length $new_name == 0) {
          $c->flash()->{error} =
            "No name given for new email: $new_email";
          $c->res->redirect($redirect_uri);
        }
        my $load_util = LoadUtil->new(schema => $schema);
        my $user_types_cv = $load_util->find_cv('PomCur user types');
        my $user_cvterm = $load_util->get_cvterm(cv => $user_types_cv,
                                                 term_name => 'user');

        my $new_person = $schema->resultset('Person')->create({
          name => $new_name,
          email_address => $new_email,
          role => $user_cvterm,
        });
        $pub_just_triaged->corresponding_author($new_person->person_id());
      } else {
        # they didn't enter a new person
      }
    }

    my $priority_cvterm_id = $c->req()->param('triage-curation-priority');
    my $priority_cvterm =
      $schema->resultset('Cvterm')->find({ cvterm_id => $priority_cvterm_id });

    $pub_just_triaged->curation_priority($priority_cvterm);

    my $community_curatable = $c->req()->param('community-curatable');
    my $community_curatable_cvterm =
      $schema->resultset('Cvterm')->find({ name => "community_curatable" });

    if (!defined $community_curatable_cvterm) {
      die "Can't find term for: community_curatable";
    }

    $pub_just_triaged->pubprops()->search({ type_id => $community_curatable_cvterm->cvterm_id() })
      ->delete();

    if (defined $community_curatable) {
      $schema->create_with_type('Pubprop',
                                { type_id => $community_curatable_cvterm->cvterm_id(),
                                  value => 'yes',
                                  pub_id => $pub_just_triaged->pub_id() });
    }

    my $triage_comment = $c->req()->param('triage-comment');
    my $triage_comment_cvterm =
      $schema->resultset('Cvterm')->find({ name => "triage_comment" });

    if (!defined $triage_comment_cvterm) {
      die "Can't find term for: triage_comment";
    }

    $pub_just_triaged->pubprops()->search({ type_id => $triage_comment_cvterm->cvterm_id() })
      ->delete();

    if (defined $triage_comment) {
      $triage_comment =~ s/^\s+//;
      $triage_comment =~ s/\s+$//;
      if (length $triage_comment > 0) {
        $schema->create_with_type('Pubprop',
                                  { type_id => $triage_comment_cvterm->cvterm_id(),
                                    value => $triage_comment,
                                    pub_id => $pub_just_triaged->pub_id() });
      }
    }

    $pub_just_triaged->update();

    $guard->commit();

    if (defined $return_pub_id && length $return_pub_id > 0) {
      # we were triaging a single publication and should now go back to the
      # publication detail page
      $next_pub = undef;
    } else {
      $next_pub = _get_next_triage_pub($schema, $new_status_cvterm);
    }

    if (defined $next_pub) {
      $c->res->redirect($c->uri_for('/tools/triage'));
      $c->detach();
    } else {
      # fall through
    }
  } else {
    my $return_pub = $schema->resultset('Pub')->find({ pub_id => $return_pub_id });
    $next_pub = $return_pub // _get_next_triage_pub($schema, $new_status_cvterm);
  }

  if (defined $next_pub) {
    $st->{title} = 'Triaging ' . $next_pub->uniquename();
    if (!defined $return_pub_id) {
      $st->{right_title} =
        "$untriaged_pubs_count remaining";
    }

    $st->{pub} = $next_pub;

    $st->{template} = 'tools/triage.mhtml';
  } else {
    if (defined $return_pub_id && length $return_pub_id > 0) {
      $c->flash()->{message} = $pub_just_triaged->uniquename . ' triaged';
      $c->res->redirect($c->uri_for("/view/object/pub/$return_pub_id", { model => 'track'} ));
    } else {
      $c->flash()->{message} =
        'Triaging finished - no more un-triaged publications';
      $c->res->redirect($c->uri_for('/'));
    }
    $c->detach();
  }
}

sub _load_one_pub
{
  my $config = shift;
  my $schema = shift;
  my $pubmedid = shift;

  my $raw_pubmedid;

  $pubmedid =~ s/[^_\d\w:]+//g;

  if ($pubmedid =~ /^\s*(?:pmid:|pubmed:)?(\d+)\s*$/i) {
    $raw_pubmedid = $1;
    $pubmedid = "PMID:$1";
  } else {
    my $message = 'You need to give the raw numeric ID, or the ID ' .
      'prefixed by "PMID:" or "PubMed:"';
    return (undef, $message);
  }

  my $pub = $schema->resultset('Pub')->find({ uniquename => $pubmedid });

  if (defined $pub) {
    return ($pub, undef);
  } else {
    my $xml = PubmedUtil::get_pubmed_xml_by_ids($config, $raw_pubmedid);

    my $count = PubmedUtil::load_pubmed_xml($schema, $xml, 'user_load');

    if ($count) {
      $pub = $schema->resultset('Pub')->find({ uniquename => $pubmedid });
      return ($pub, undef);
    } else {
      (my $numericid = $pubmedid) =~ s/.*://;
      my $message = "No publication found in PubMed with ID: $numericid";
      return (undef, $message);
    }
  }
}

sub pubmed_id_lookup : Local Form {
  my ($self, $c) = @_;

  my $st = $c->stash();

  my $pubmedid = $c->req()->param('pubmed-id-lookup-input');

  my $result;

  if (!defined $pubmedid) {
    $result = {
      message => 'No PubMed ID given'
    }
  } else {
    my ($pub, $message) =
      _load_one_pub($c->config, $c->schema('track'), $pubmedid);

    if (defined $pub) {
      $result = {
        pub => {
          uniquename => $pub->uniquename(),
          title => $pub->title(),
          authors => $pub->authors(),
          abstract => $pub->abstract(),
          pub_id => $pub->pub_id(),
        }
      };

      my $sessions_rs = $pub->curs();
      if ($sessions_rs->count() > 0) {
        my $uniquename = $pub->uniquename();
        $result->{message} = "Sorry, $uniquename is currently being curated by someone " .
            "else.  Please contact the curation team for more information.";
        $result->{curation_sessions} = [ map { $_->curs_key(); } $sessions_rs->all() ],
      }
    } else {
      $result = {
        message => $message
      }
    }
  }

  $c->stash->{json_data} = $result;
  $c->forward('View::JSON');

}

sub pubmed_id_start : Local {
  my ($self, $c) = @_;

  my $st = $c->stash();

  $st->{title} = 'Find a publication to curate using a PubMed ID';
  $st->{show_title} = 0;
  $st->{template} = 'tools/pubmed_id_start.mhtml';
}

=head2 start

 Usage   : /start/<pubmedid>
 Function: Create a new session for a publication and redirect to it
 Args    : pubmedid

=cut
sub start : Local Args(1) {
  my ($self, $c, $pub_uniquename) = @_;

  my $st = $c->stash();

  my $schema = $c->schema('track');
  my $config = $c->config();

  my $pub = $schema->find_with_type('Pub', { uniquename => $pub_uniquename });
  my $curs_key = PomCur::Curs::make_curs_key();

  my $curs = $schema->create_with_type('Curs',
                                       {
                                         pub => $pub,
                                         curs_key => $curs_key,
                                       });

  my $curs_schema = PomCur::Track::create_curs_db($config, $curs);

  $c->res->redirect($c->uri_for("/curs/$curs_key"));
}

=head2 pub_session

 Usage   : /pub_session/<pubmedid>
 Function: If a session exists for the publication, go to it.  Otherwise create
           a new session for a publication and redirect to it.
           If there is more than one session, go to the first.
 Args    : pubmedid

=cut
sub pub_session : Local Args(1) {
  my ($self, $c, $pub_id) = @_;

  my $st = $c->stash();

  my $schema = $c->schema('track');
  my $config = $c->config();

  my $pub = $schema->find_with_type('Pub', { pub_id => $pub_id });

  my $curs = $pub->curs()->first();

  if (!defined $curs) {
    my $curs_key = PomCur::Curs::make_curs_key();
    $curs = $schema->create_with_type('Curs',
                                       {
                                         pub => $pub,
                                         curs_key => $curs_key,
                                       });
    my $curs_schema = PomCur::Track::create_curs_db($config, $curs);
  }

  $c->res->redirect($c->uri_for("/curs/" . $curs->curs_key()));
}

=head2 store_all_statuses

 Function: Call PomCur::Curs::Utils::store_all_statuses()
 Args    : none

=cut
sub store_all_statuses : Local Args(0) {
  my ($self, $c) = @_;

  my $track_schema = $c->schema('track');
  my $config = $c->config();

  PomCur::Curs::Utils::store_all_statuses($config, $track_schema);

  $c->flash()->{message} =
    'Stored statuses for all sessions';
  $c->res->redirect($c->uri_for('/'));
  $c->detach();
}

sub ann_ex_locations : Local Args(0) {
  my ($self, $c) = @_;

  my $st = $c->stash();

  my $track_schema = $c->schema('track');
  my $config = $c->config();

  my %anexs = ();

  my $iter = PomCur::Track::curs_iterator($config, $track_schema);
  while (my ($curs, $cursdb) = $iter->()) {
    my $curs_key = $curs->curs_key();
    for my $gene ($cursdb->resultset('Gene')->all()) {
      for my $annotation ($gene->direct_annotations()) {
        next if $annotation->status() eq 'deleted';
        if (defined $annotation->data()->{annotation_extension}) {
          push @{$anexs{$annotation->data()->{annotation_extension}}->{$curs_key}}, {
            primary_identifier => $gene->primary_identifier(),
            gene_id => $gene->gene_id(),
          };
        }
      }
    }
  }

  $st->{extension_data} = \%anexs;

  $st->{title} = 'Locations of annotation extension strings';
  $st->{show_title} = 0;
  $st->{template} = 'tools/ann_ex_locations.mhtml';
}

sub sessions_with_type : Local Args(1) {
  my ($self, $c, $annotation_type) = @_;

  my $st = $c->stash();

  my $track_schema = $c->schema('track');
  my $config = $c->config();

  my $proc = sub {
    my $curs = shift;
    my $curs_schema = shift;

    my $rs = $curs_schema->resultset("Annotation")->search({ type => $annotation_type });
    return [$curs->curs_key(), $rs->count()];
  };

  my @res = PomCur::Track::curs_map($config, $track_schema, $proc);

  $st->{annotation_type} = $annotation_type;
  $st->{type_data} = [sort { $a->[0] cmp $b->[1] } grep { $_->[1] > 0 } @res];

  $st->{title} = "Sessions with annotations of type: $annotation_type";
  $st->{template} = 'tools/session_with_type.mhtml';
}

sub sessions_with_type_list : Local Args(0) {
  my ($self, $c) = @_;

  my $st = $c->stash();

  my $track_schema = $c->schema('track');
  my $config = $c->config();

  my $proc = sub {
    my $curs = shift;
    my $curs_schema = shift;

    my %res_map = ();

    my $rs = $curs_schema->resultset("Annotation");
    while (defined (my $an = $rs->next())) {
      $res_map{$an->type()} = 1;
    }
    return \%res_map;
  };

  my @res = PomCur::Track::curs_map($config, $track_schema, $proc);

  my %totals = ();

  map {
    while (my ($key, $count) = each %$_) {
      $totals{$key} += $count;
    }
  } @res;

  $st->{annotation_types} = [map {
    [$_->{name}, $totals{$_->{name}} // 0]
  } @{$config->{annotation_type_list}}];


  $st->{title} = "Sessions listed by type";
  $st->{template} = 'tools/sessions_with_type_list.mhtml';
}

=head1 LICENSE
This library is free software. You can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

1;
