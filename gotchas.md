# Gotchas

Things that cost time on this project. Read before touching the stack again.

## Solr config lives in ZooKeeper, not on disk

Editing `solr-config/searchcore/conf/*.xml` and restarting Solr changes nothing. The configset is
uploaded to ZooKeeper when `start-services.sh` creates the collection with `-d`. After that, the
files on disk are just a template.

To apply a schema or solrconfig change to an existing collection:

```bash
./solr-nodes/node1/bin/solr zk upconfig -n searchcore \
    -d solr-config/searchcore/conf -z localhost:2181
curl -s "localhost:8983/solr/admin/collections?action=RELOAD&name=searchcore"
```

This is the single easiest way to conclude "my fix didn't work" when it actually did.

## The suggester needs an explicit build

`buildOnStartup` and `buildOnCommit` were both `false` in the original `solrconfig.xml`, so the
dictionary was never built and `/suggest` returned an empty list forever, with HTTP 200 and no
error. Silent failure.

`buildOnStartup=true` is now set, and `index-sample-data.sh` triggers a build after indexing.
`buildOnCommit` stays off on purpose: a build takes about 9 seconds, and indexing commits once per
500-doc chunk, so turning it on would add roughly 3 minutes to a 10k-doc load.

After any bulk index outside that script:

```bash
curl "localhost:8983/solr/searchcore/suggest?suggest.build=true"
```

## A GitHub zip download loses executable bits

`unzip` produced `setup-solr.sh` etc. without `+x`, and the failure surfaced as
`permission denied: ./setup-solr.sh`. Worse, running it through a pipe (`./setup-solr.sh | tail`)
reported exit code 0 because the pipeline's exit status came from `tail`. Check
`${PIPESTATUS[0]}`, not `$?`, when piping a script whose success matters.

## This machine cannot run the documented topology

The README's 3 ZooKeeper + 2 Solr layout needs 3 to 4 GB. With browsers open there is often under
500 MB free. Use the trimmed topology in DEMO.md (1 ZK + 1 Solr, `SOLR_HEAP=512m`).

`NUM_ZK_NODES=1` is safe because `setup-solr.sh` generates the `server.N` lines from that variable,
so a single node config forms a valid quorum of 1. Do not instead take a 3-node `zoo1.cfg` and
start one node from it; that cannot reach quorum and hangs.

## Do not regenerate the dashboard data on this hardware

`update_dashboard_from_run.py` overwrites `webapp/data/configs.json` and `cpp_data.json`, which
hold the recorded multi-node study results. A run on one memory-starved node would replace real
numbers with much worse ones and quietly destroy the project's headline finding.

## server.py is an open proxy

It forwards every `/solr/*` path, including `update`, `delete`, and `/solr/admin`. It binds
`127.0.0.1` for that reason. Do not "fix" that by binding `0.0.0.0` to demo from another device
without first restricting the proxy to `/select` and `/suggest`.

## Facet values are not display strings

The original code did `facetData[i].slice(0, 10)` and used the result both as the label and as the
checkbox value. Any file name longer than 10 characters then produced a filter query matching
nothing. Verified: `fq=file_name:("Andaman an")` returns 0, the full value returns 1. Truncate for
display only, never in state.
