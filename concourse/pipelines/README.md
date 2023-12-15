#Introduction

There are only three valid pipelines enabled:

- bouncer_gpdb5_pr.yml [branch: pgbouncer_1_8_1]

- bouncer_gpdb7_pr.yml [branch: main]

- bouncer_gpdb7_release.yml [branch: main]

Make a pull request to **"main"** or **"pgbouncer_1_8_1"** branch will trigger the corresponding pipeline to run.
You need to specify the tag_branch_name when fly release pipeline by "-v git-branch=${tag_branch_name}".
---

The pipelines are run by the following command.

`fly -t dev2 set-pipeline -p pgbouncer_gpdb7_pr -c bouncer_gpdb7_pr.yml`

`fly -t dev2 set-pipeline -p pgbouncer_gpdb5_pr -c ./bouncer_gpdb5_pr.yml`

`fly -t dev2 set-pipeline -p pgbouncer_gpdb7_release -v git-branch=${tag_branch_name} -c bouncer_gpdb7_release.yml`
