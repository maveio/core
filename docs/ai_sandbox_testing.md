# AI sandbox testing for pull requests

The [AI sandbox workflow](../.github/workflows/ai-sandbox.yml) lets a model test
an incoming pull request: it reads the diff, runs and writes tests in a
disposable sandbox, looks for regressions and security weaknesses, and posts its
findings as one comment for a maintainer to review. It is advisory. It never
approves, merges or blocks a pull request, and it complements the
[security checks](security_checks.md) rather than replacing them or code review.

It is off by default. Forks and self-hosted copies do not run it unless they
opt in.

## Trust boundaries

Pull-request code is untrusted, and so is everything a model writes after
reading it. The workflow runs from the base branch (`pull_request_target`), so a
pull request cannot change the workflow, the scripts or the toolchain that test
it. Three jobs keep three powers apart:

| Job | Runs pull-request code | Network for that code | Model key | Repository token |
| --- | --- | --- | --- | --- |
| `prepare` | yes, while fetching and compiling dependencies | yes | no | read |
| `explore` | yes, only inside the sandbox containers | none | yes, in the orchestrator step | read |
| `report` | no | n/a | no | may comment |

The model and the code it tests never share a side. The
[orchestrator](../.github/scripts/ai_sandbox.py) holds the key and talks to the
model API; each tool call is relayed into the sandbox with `docker exec`. The
sandbox and its throwaway PostgreSQL, ClickHouse and object storage share one
internal network ([compose file](../.github/ai-sandbox/compose.yml)) with no
route to the internet or the host, no host mounts, no published ports, no
capabilities, unprivileged users and only the public test passwords. Before the
model is called, a preflight verifies these properties from the container
configuration and from inside the sandbox, and stops the run if one is missing.

What comes back is handled as data. Command output is size-limited and never
reaches the start of a log line, where the runner would parse it. The report is
validated and rendered without mentions, links, images or HTML. The pull
request's title, description and diff are marked as untrusted in the prompt, and
the model has no tool that reaches outside the sandbox, so a prompt injection
can at worst distort the advisory report.

## Enable it

1. Create an API key for the [Claude API](https://platform.claude.com/) that is
   used for nothing else, with a spend limit.
2. Add it as the secret `ANTHROPIC_API_KEY` of a GitHub environment named
   `ai-sandbox`. Add required reviewers to that environment if a maintainer
   should approve each run, for example for pull requests from first-time
   contributors.
3. Set the repository variable `AI_SANDBOX_ENABLED` to `true`.

Non-draft pull requests are then tested when they are opened or updated. A
maintainer can also start a run for one pull request from the Actions tab.
A newer push cancels the run in progress.

Optional repository variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `AI_SANDBOX_MODEL` | `claude-opus-5-5` | Model that tests the pull request |
| `AI_SANDBOX_EFFORT` | `high` | Thinking effort: `low` to `max` |
| `AI_SANDBOX_MAX_TURNS` | `40` | Model turns per run |
| `AI_SANDBOX_MAX_MINUTES` | `30` | Time budget per run |
| `AI_SANDBOX_REFUSAL_FALLBACK` | `default` | Let the API retry a declined request on its fallback model; `off` disables it |

The turn and time budgets bound the cost of a run; the report states the tokens
used. The diff, the description and command output of the pull request are sent
to the model provider, so enable this only where that content may be shared.

## Read the report

The comment lists findings by severity with the file, the evidence and a
suggested fix, then what was checked and what was not covered. Treat it as a
colleague's notes: reproduce a finding before acting on it, and do not read a
clean report as approval. The complete session, including every command and its
output, is attached to the workflow run as the `ai-sandbox-report` artifact.

## Run it locally

With Docker, a checkout of the pull request in another directory and an API key:

```sh
.github/ai-sandbox/prepare.sh ../pull-request-checkout
.github/ai-sandbox/start.sh

export PR_NUMBER=123 PR_BASE_SHA=<base commit> PR_HEAD_SHA=<head commit>
python3 -m venv .venv && .venv/bin/pip install --require-hashes -r .github/ai-sandbox/requirements.txt
ANTHROPIC_API_KEY=... .venv/bin/python .github/scripts/ai_sandbox.py review --output report.json
python3 .github/scripts/ai_sandbox_report.py report.json

docker compose -f .github/ai-sandbox/compose.yml down --volumes
```

`review --model-script .github/ai-sandbox/selftest.json` replays fixed steps
instead of calling a model. Pull requests that change the sandbox run this
self-test in CI, together with the isolation preflight and the
[unit tests](../.github/scripts/test_ai_sandbox.py), without any secret.

## Limits

- The boundary is a hardened container on a disposable hosted runner, not a
  virtual machine. A container escape during `explore` could reach the model
  key, which is why that key must be dedicated and spend-limited. The sandbox
  runtime is configurable (`AI_SANDBOX_RUNTIME`), but a syscall-filtering
  runtime such as gVisor cannot run the media confinement tests, which need
  Landlock and seccomp.
- The toolchain comes from the base branch. A pull request that changes the
  Dockerfile toolchain is tested with the old one.
- A model can miss problems, report false ones and be misled by the code it
  reads. Findings are leads for a reviewer, not verdicts.
