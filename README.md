PHI-Canto
=========

PHI-Canto is a web application used for the annotation of pathogen–host
interactions. PHI-Canto is an extension of Canto, a genome annotation tool
developed and maintained by [PomBase](https://www.pombase.org/). PHI-Canto is
currently used by [PHI-base](http://www.phi-base.org/) to assist with curation
of pathogen–host literature.

Note that PHI-Canto shares almost all of its source code with Canto.
Development on PHI-Canto is managed on the Canto repository on the PomBase
GitHub organization ([pombase/canto](https://github.com/pombase/canto)). All
issues and pull requests related to PHI-Canto should be directed to the
[Canto issue tracker](https://github.com/pombase/canto/issues). This repository
is used primarily to allow PHI-Canto's source code to be cited directly in
publications.

Installation
------------

PHI-Canto runs in a Docker container, so Docker must be installed (see
[instructions](https://docs.docker.com/engine/install/)).

The following commands will download PHI-Canto's source code and set up the
environment:

```sh
# Note that the path to the canto-space directory cannot contain spaces.
mkdir canto-space
cd canto-space
mkdir data import_export logs

git clone https://github.com/PHI-base/canto.git
```
Run the following command to create a database for PHI-Canto and generate the
main configuration file (`canto_deploy.yaml`).
```sh
./canto/script/canto_start_docker --initialise /data
```
Run the following command from the `canto-docker` folder to start PHI-Canto:
```sh
./canto/script/canto_start_docker
```

Publications
------------

Alayne Cuzick, James Seager, Valerie Wood, Martin Urban, Kim Rutherford, and Kim E. Hammond-Kosack (2023) **A framework for community curation of interspecies interaction literature.** eLife2023;12:e84658 DOI: https://doi.org/10.7554/eLife.84658
