#Introduction

There are only two valid pipelines enabled:

- bouncer_gpdb5_pr.yml [branch:pgbouncer_1_8_1]

- bouncer_gpdb6_and_gpdb7_pr.yml [branch:main]

Make a pull request to **"main"** or **"pgbouncer_1_8_1"** branch will trigger the corresponding pipeline to run.

---

The pipelines are run by the following command.

`fly -t clients set-pipeline -p pgbouncer_gpdb6_and_gpdb7_pr -c bouncer_gpdb6_and_gpdb7_pr.yml -l ~/workspace/gp-continuous-integration/secrets/pgbouncer-secrets.client.yml -v git-access-token={{access-key-value}}`

`fly -t clients set-pipeline -p pgbouncer_gpdb5_pr -c ./bouncer_gpdb5_pr.yml -l ~/workspace/gp-continuous-integration/secrets/pgbouncer-secrets.client.yml -v git-access-token={{access-key-value}}`

The old pr pipeline *"bouncer_gpdb6_pr"* and *"bouncer_gpdb7_pr"* are deprecated. 
