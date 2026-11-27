# Third-party components

OpenAgentix installs, references or compiles in the components below. This repository does not copy their source code (see [NOTICE](NOTICE)). Each keeps its own licence.

Read on 2026-11-25 with the GitHub API (`gh api repos/<owner>/<repo>/license?ref=<tag>` and the `LICENSE` file at the pinned tag), or the Hugging Face model API for model weights. "Verified" means I read the licence file or the licence metadata at the version in the "Pinned" column. "Unverified" means I did not, and it says why. Nothing is guessed. Re-check before each release. This is not legal advice.

Status of the licences:

- **Permissive and verified**: Apache-2.0, MIT, BSD-3-Clause, PostgreSQL licence.
- **Flagged** items are listed again in "Flags" at the end.

## Installed by `install.sh` (runtime platform)

| Component | Pinned in this repo | Licence | Source | How verified |
|---|---|---|---|---|
| kagent (controller, UI, `golang-adk` harness image) | 1.0.1 (`components/runtime/kagent-helm.sh`, `values/kagent.yaml`; harness image by digest in `values.yaml`) | Apache-2.0 | https://github.com/kagent-dev/kagent | `LICENSE` at tag `v1.0.1` |
| Agent Substrate (control plane, `kubectl-ate`, gVisor worker image `ateworker-gvisor`) | 1.0.1 (`components/runtime/up.sh`, `values/kagent.yaml`) | Apache-2.0 | https://github.com/kagent-dev/substrate | `LICENSE` at tag `v1.0.1` |
| agentgateway | v1.7.0 (`components/model-gateway/install.sh`) | Apache-2.0 | https://github.com/agentgateway/agentgateway | `LICENSE` at tag `v1.7.0` |
| Gateway API CRDs | 1.6.3 (`components/model-gateway/install.sh`) | Apache-2.0 | https://github.com/kubernetes-sigs/gateway-api | `LICENSE` at tag `v1.6.3` |
| ToolHive (operator, vMCP) | 0.67.1 (`components/tools/install.sh`) | Apache-2.0 | https://github.com/stacklok/toolhive | `LICENSE` at tag `v0.67.1` |
| ToolHive MCP server `gofetch` (image) | 2.0.1 (`values.yaml`, `mcp.servers`) | Apache-2.0 | https://github.com/StacklokLabs/gofetch | `LICENSE` at tag `v2.0.1`; the image is pinned by tag only, and I did not check that the image was built from that tag |
| ToolHive MCP server `osv-mcp` (image) | 0.2.1 (`values.yaml`, `mcp.servers`) | Apache-2.0 | https://github.com/StacklokLabs/osv-mcp | `LICENSE` at tag `v0.2.1`; same note as above |
| Agent Kourier (chart and image) | 0.6.0 (`components/channels/kourier.sh`) | Apache-2.0 | https://github.com/agentkourier/agent-kourier | `LICENSE` at tag `v0.6.0`; the installer also verifies the chart and image with `cosign` when it is installed |
| kind and the node image `kindest/node` | kind 0.33+ (README), node `v1.37.0` (`hack/kind-config.yaml`) | Apache-2.0 (kind and Kubernetes) | https://github.com/kubernetes-sigs/kind, https://github.com/kubernetes/kubernetes | `LICENSE` at kind `v0.33.0` and Kubernetes `v1.37.0`. The node image also holds an operating system and container runtime, which I did not check |

## Pulled by the chart (observability, knowledge, memory)

| Component | Pinned in this repo | Licence | Source | How verified |
|---|---|---|---|---|
| VictoriaMetrics (single-node image) | v1.156.0, by digest (`values.yaml`) | Apache-2.0 | https://github.com/VictoriaMetrics/VictoriaMetrics | `LICENSE` at tag `v1.156.0` |
| Jaeger (image) | 2.23.0, by digest (`values.yaml`) | Apache-2.0 | https://github.com/jaegertracing/jaeger | `LICENSE` at tag `v2.23.0` |
| PostgreSQL (in image `pgvector/pgvector:pg17`) | 17, by digest (`values.yaml`) | PostgreSQL licence | https://github.com/postgres/postgres | `COPYRIGHT` on branch `REL_17_STABLE`; I did not read it at the exact minor version in the digest |
| pgvector (extension, in the same image) | the version inside the pinned digest is not recorded here; I read `v0.8.0` | PostgreSQL licence | https://github.com/pgvector/pgvector | `LICENSE` at tag `v0.8.0`. **Version in the digest: unverified** |
| llama.cpp server (image) | `server-b10088`, by digest (`values.yaml`) | MIT | https://github.com/ggml-org/llama.cpp | `LICENSE` at tag `b10088`. The image also holds an operating system layer I did not check |
| Embedding model `bge-small-en-v1.5` (GGUF, Q8_0, via `CompendiumLabs/bge-small-en-v1.5-gguf`) | repo and quantisation, **no revision pinned** (`values.yaml`, `knowledge.embeddings.model.hf`) | MIT | https://huggingface.co/BAAI/bge-small-en-v1.5, https://huggingface.co/CompendiumLabs/bge-small-en-v1.5-gguf | model card metadata through the Hugging Face API (`license: mit` for both repositories). I did not read a licence file |
| Embedding model `bge-base-en-v1.5` (GGUF, Q8_0, via `CompendiumLabs/bge-base-en-v1.5-gguf`) | same, no revision pinned (`memory.embeddings.model.hf`) | MIT | https://huggingface.co/BAAI/bge-base-en-v1.5, https://huggingface.co/CompendiumLabs/bge-base-en-v1.5-gguf | model card metadata, as above |
| rustfs (object store used by Agent Substrate) | set by the Substrate chart 1.0.1, **not pinned here** | Apache-2.0 | https://github.com/rustfs/rustfs | licence metadata of the default branch only. **Version: unverified** |
| gVisor (sandbox runtime, delivered with Substrate's worker image) | SandboxConfig release `gvisor-default` v7 (`components/runtime/NOTES.md`); the gVisor version inside the image is **not recorded here** | Apache-2.0 | https://github.com/google/gvisor | licence metadata of the default branch only. **Version: unverified** |

## Container images of our own services and tools

| Component | Pinned in this repo | Licence | Source | How verified |
|---|---|---|---|---|
| distroless `static:nonroot` (final image of every Go service) | `nonroot` at `sha256:8ce6dd87e9823c5b48dcfb2c8604714ccb351ce59607327bcc4957448da279b5` in each `Dockerfile` | Apache-2.0 for the build files; the image holds Debian packages (base files, CA certificates, tzdata) with their own licences | https://github.com/GoogleContainerTools/distroless | `LICENSE` on the default branch. **Image contents: unverified** |
| Go toolchain image `golang:1.25` (build stage only, not shipped) | `1.25` at `sha256:699337d620559a59b4a2bb298ad59611e535d2ee755a34cf2d2a98f37578dc80` | BSD-3-Clause (Go); the image also holds Debian packages | https://github.com/golang/go | **Unverified** (not shipped in any final image) |
| crane (`gcr.io/go-containerregistry/crane`, used by `install.sh` to push the example skill) | `latest` (`install.sh`, `components/tools/install.sh`), **not pinned** | Apache-2.0 | https://github.com/google/go-containerregistry | `LICENSE` on the default branch. **Version: not pinned** |
| curl (`curlimages/curl:8.10.1`, README test commands only) | 8.10.1 | curl licence (MIT-style) | https://github.com/curl/curl | `COPYING` at tag `curl-8_10_1` |

## Compiled into our Go modules

`services/a2a-gate`, `services/control-plane`, `tools/a2a-call` and `bridges/telegram` use only the Go standard library. The others use the modules below (versions from each `go.mod`; run `go list -m all` for the full graph, which I did not scan).

| Module | Version | Used by | Licence | How verified |
|---|---|---|---|---|
| github.com/modelcontextprotocol/go-sdk | v1.8.0 | kb, notify | MIT for older contributions, Apache-2.0 for newer ones (the `LICENSE` file says the project is moving from MIT to Apache-2.0; both are permissive) | `LICENSE` at tag `v1.8.0` |
| github.com/jackc/pgx/v5 | v5.13.0 | kb | MIT | licence metadata at tag |
| github.com/jackc/puddle/v2 | v2.2.3 | kb | MIT | licence metadata at tag |
| gopkg.in/yaml.v3 (github.com/go-yaml/yaml) | v3.0.1 | notify | MIT and Apache-2.0 (two licences, see its `LICENSE` and `NOTICE`) | `LICENSE` and `NOTICE` at tag |
| modernc.org/sqlite (with its modernc.org dependencies, `github.com/dustin/go-humanize`, `github.com/mattn/go-isatty`, `github.com/ncruces/go-strftime`, `github.com/remyoudompheng/bigfft`) | v1.46.2 | examples/use-cases/records | BSD-3-Clause (sqlite itself; the dependencies carry their own permissive licences) | `LICENSE` of modernc.org/sqlite v1.46.2 read in the module cache. **The licences of the dependencies were not read one by one**; the SQLite code is public domain |
| github.com/google/jsonschema-go | v0.4.3 | kb, notify | MIT | licence metadata at tag |
| github.com/segmentio/encoding, github.com/segmentio/asm | v0.5.4, v1.1.3 | kb, notify | MIT | licence metadata at tag |
| github.com/yosida95/uritemplate/v3 | v3.0.2 | kb, notify | BSD-3-Clause | licence metadata at tag |
| golang.org/x/oauth2 | v0.35.0 | kb, notify | BSD-3-Clause | licence metadata at tag |
| golang.org/x/sync, sys, time, text, tools | v0.22.0, v0.41.0 and v0.47.0, v0.15.0, v0.41.0, v0.48.0 (varies by module) | kb, notify | BSD-3-Clause | read the `LICENSE` text ("Copyright The Go Authors", BSD 3-clause wording) at tag; the API reports no SPDX id for these |
| github.com/google/ax | `v0.0.0` replaced by a local path (`bridges/ax-adapter/go.mod`) | ax-adapter (benchmark bridge, not installed by default) | Apache-2.0 | licence metadata of the default branch only. **Pinned version: unverified** |
| go.ate.dev/substrate | v1.0.0 | ax-adapter | probably the same as Agent Substrate (Apache-2.0); the module path matches `kagent-dev/substrate` `go.mod` | **Unverified at v1.0.0** |
| google.golang.org/grpc | v1.83.2 | ax-adapter | Apache-2.0 | licence metadata at tag |
| google.golang.org/protobuf | v1.36.12 | ax-adapter | BSD-3-Clause | `LICENSE` at tag (text "Copyright 2018 The Go Authors", BSD wording); no SPDX id reported |
| golang.org/x/net | v0.60.0 | ax-adapter | BSD-3-Clause | `LICENSE` at tag, as above |
| google.golang.org/genproto/googleapis/rpc | v0.0.0-20260803160001-6ac0973c030d | ax-adapter | Apache-2.0 | licence metadata of the default branch only |

## Documentation site (not part of the platform)

| Component | Pinned in this repo | Licence | Source | How verified |
|---|---|---|---|---|
| Docusaurus (`@docusaurus/core`, `preset-classic`, `theme-mermaid`) | 3.10.2 (`website/package.json`) | MIT | https://github.com/facebook/docusaurus | `LICENSE` at tag `v3.10.2` |
| Other npm packages in `website/package-lock.json` | see lockfile | not scanned | | **Unverified.** Not shipped in the platform |

## Used as a service, not installed

The Anthropic API and the Telegram Bot API are used from your own accounts and are not bundled. Their terms are yours to read. OpenAgentix does not redistribute them.

## Flags

1. **Not pinned, so the licence read may not match what runs:** crane (`latest`), the embedding model weights (no revision), rustfs and the gVisor build inside Substrate's images, and the pgvector version inside its image digest.
2. **Unverified:** the licence of the rest of each container image's operating system layers (Debian or Ubuntu packages, with a mix of licences including copyleft ones, as in any such image; they are pulled at run time and not redistributed by this repository), the version-specific licence of `go.ate.dev/substrate` v1.0.0, `google/ax`, gVisor and rustfs, and the npm tree of the documentation site.
3. **Mixed licence:** `modelcontextprotocol/go-sdk` v1.8.0 is partly MIT and partly Apache-2.0 per its `LICENSE`. Both are permissive. `gopkg.in/yaml.v3` is MIT and Apache-2.0.
4. **Not clearly "permissive" by SPDX tooling:** several repositories showed `NOASSERTION` in the GitHub API even though the text is permissive (PostgreSQL licence, curl, Go modules, protobuf-go, yaml.v3, go-sdk). A scanner such as ScanCode or FOSSA would help to confirm it. I read the texts above. I found no copyleft or non-commercial licence among the components I could read.
5. **Model weights** are licensed per their model cards (MIT). A model card is not a legal licence file, and the training data is not covered by that statement.
6. **SBOM and this table.** From release 0.3 each release image has an SPDX SBOM (made by syft from the pushed image, attached as a signed cosign attestation and published with the release, see [Verify a release](docs/diary/guide/verify-release.md)). The SBOM lists the packages syft finds inside our images: the Go modules compiled in and the Debian packages of the base image. It does not cover the upstream components that `install.sh` installs (kagent, agentgateway, ToolHive and the others above), and its licence fields come from package metadata, not from reading the licence files. This table stays the licence record for those. A licence scan is still not in CI. The SBOM step has not run on a real tag yet.
