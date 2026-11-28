# Market research: what organisations build with agent platforms

Status: draft. Sections 1 to 3 and 7 have first content. Sections 4 to 6 are an outline only. See "Next steps" at the end.

## 1. Method and date

- Read date for every source: 2026-11-26.
- Web search and page reads of vendor case studies, sample repositories, adopters files, the CNCF blog, KubeCon EU 2026 listings and one independent survey.
- "Opened" means the page was read. "Seen" means only a search result summary was read. Rows that rest on a summary only are marked "seen".
- Maturity: **production**, **pilot** or **demo**. "Claimed" means only the vendor, or the customer on a vendor page, says so. No row has an independent measurement.
- Risk: **read-only** (the agent reads and reports) or **mutating** (the agent changes a system), with how the change is gated when the source says it.
- Not covered yet: the KubeCon NA 2026 schedule, McKinsey and Gartner numbers (a page read timed out), CNCF, PagerDuty and Datadog surveys, the AWS AgentCore sample names, kagent and k8sgpt adopters.

## 2. Use cases found

### 2.1 SRE, platform, DevOps and security

| Use case | What it does | Trigger | Tools and systems | Who | Platform | Evidence | Maturity | Risk |
|---|---|---|---|---|---|---|---|---|
| First-pass alert investigation | Investigates an alert, narrows the search, rates its own confidence | alert | Datadog, Slack | BlaBlaCar | Cleric | [case study](https://www.casestudies.com/company/cleric/case-study/how-the-worlds-leading-community-based-travel-network-is-transforming-incident-response-with-ai) (opened) | production, claimed | read-only |
| Alert triage and latency investigation | Reads logs, traces and metrics; triages low-priority alerts; answers in chat | alert, chat | Datadog APM and logs, Slack | Nulab | Datadog Bits AI SRE | [case study](https://www.datadoghq.com/case-studies/nulab) (opened) | production, claimed | read-only |
| Triage before a human is paged | Links a spike to a recent change, suggests a fix; a responder clicks to run it | incident | Grafana, Datadog, Splunk, GitHub, Confluence, Slack, Teams | vendor | PagerDuty SRE Agent | [blog](https://www.pagerduty.com/blog/ai/new-enhancements-to-pagerdutys-sre-agent-triage-faster-without-waking-a-human/) (opened) | production, claimed | mutating, human click per action |
| Scribe and shift handover | Feeds incident notes and shift context to triage | incident, shift change | PagerDuty, Slack | vendor | PagerDuty agents | same as above | claimed | read-only |
| Staged trust for actions | Teams choose which actions run alone and which need approval | incident | PagerDuty | Royal Caribbean, LiveRamp | PagerDuty SRE Agent | [blog](https://www.pagerduty.com/blog/ai/meet-paige-sre-agent/) (seen) | unclear | approval tiers |
| Incident bridge RCA | Investigates across deploys and telemetry during an incident | incident | deploy data, telemetry | Coinbase | Resolve AI | [customer page](https://resolve.ai/customers/coinbase) (seen) | claimed | read-only |
| Backtested RCA in the customer's cloud | Read-only agent in the customer's VPC; 25 past incidents replayed | alert, incident | 7+ observability tools | unnamed crypto exchange | Traversal | [customer story](https://www.traversal.com/customer-stories/leading-global-crypto-exchange) (opened) | pilot | read-only, private network |
| Kubernetes troubleshooting and self-healing | Fixes crash loops, bad config, failed rollouts; right-sizes workloads | alert, chat | kubectl, cluster | Cisco | Komodor Klaudia | [Help Net Security](https://www.helpnetsecurity.com/2025/11/05/komodor-platform-self-healing-and-cost-optimization-capabilities/) (opened) | production, claimed | mutating, optional human in the loop, RBAC, audit |
| Cluster issue triage | Node readiness, pod scheduling, DNS, upgrades | chat, CLI | kubectl, Prometheus, events, logs | Microsoft AKS team | HolmesGPT (CNCF) | [ADOPTERS.md](https://raw.githubusercontent.com/HolmesGPT/holmesgpt/master/ADOPTERS.md) (opened) | production, self-listed | read-only |
| P0 and P1 incident RCA | RCA over APM data and logs inside an in-house tool | incident | APM, logs | Innovaccer | HolmesGPT | same as above | production, self-listed | read-only |
| Cluster analyzers | Built-in checks for pods, services, nodes; operator mode | on demand, continuous | Kubernetes API | AWS blog, no named adopter | k8sgpt (CNCF) | [AWS blog](https://aws.amazon.com/blogs/machine-learning/use-k8sgpt-and-amazon-bedrock-for-simplified-kubernetes-cluster-maintenance) (seen) | demo | read-only |
| Kubernetes tools agent | MCP tools for Kubernetes, Helm, Argo, Prometheus, Grafana, Cilium | chat | MCP servers | no adopters listed | kagent (CNCF) | [repository](https://github.com/kagent-dev/kagent) (opened) | demo | mutating tools exist, no approval gate documented |
| Pipeline failure analysis | Replaces a 45-minute manual log read and bridge set-up | pipeline failure | Azure DevOps, Slack | A+E Global Media | Kubiya | [TechTarget](https://www.techtarget.com/it-infrastructure/news/366628264/AE-Global-Media-boosts-AIOps-with-deterministic-AI) (seen) | production, claimed | not stated |
| Incident comms and runbooks | Stakeholder updates, RCA, runbook runs | incident | Slack, runbooks | Momentum | Rootly | [customer page](https://rootly.com/customers/momentum) (seen) | claimed | not stated |
| Azure live-site incidents | Finds root cause, proposes or applies mitigation | incident | logs, metrics, deploys, repos, MCP | Microsoft (internal) | Azure SRE Agent | [Tech Community](https://techcommunity.microsoft.com/blog/appsonazureblog/how-we-build-and-use-azure-sre-agent-with-agentic-workflows/4508753) (opened) | production internally, claimed | mutating, approval gates |
| AWS incident investigation | Correlates telemetry and deploys, writes a mitigation plan | alert, ticket | CloudWatch, PagerDuty, ServiceNow, GitHub, Slack | vendor | AWS DevOps Agent | [AWS blog](https://aws.amazon.com/blogs/aws/aws-devops-agent-helps-you-accelerate-incident-response-and-improve-system-reliability-preview) (seen) | preview, claimed | read-only, plan only |
| Ops automation sample | Tool search over AWS ops APIs | chat | AgentCore Gateway, SSM, CloudWatch | vendor sample | Bedrock AgentCore | [repository](https://github.com/aws-samples/sample-aws-ops-agentcore-gateway-search) (seen) | demo | mutating possible |
| Support case companion | Reads CloudWatch logs, opens AWS support cases | chat | CloudWatch, Support API | vendor sample | Bedrock AgentCore | [AWS blog](https://aws.amazon.com/blogs/machine-learning/build-an-ai-powered-aws-support-companion-with-amazon-bedrock-agentcore/) (seen) | demo | mutating (creates cases) |
| Cloud alert investigation | Root cause across logs, metrics, config | alert | Cloud Logging, Monitoring | vendor | Gemini Cloud Assist | [docs](https://docs.cloud.google.com/cloud-assist/overview) (seen) | preview | read-only |
| Cost anomaly explanation | Explains a cost change and which account caused it | event | billing, audit logs | vendor | Gemini Cloud Assist | [product page](https://cloud.google.com/products/gemini/cloud-assist) (seen) | preview, claimed | read-only |
| Engineering ticket triage | Assigns engineering tickets | event | ticketing | Gelato | Google Gemini | [Google list](https://blog.google/products/google-cloud/gen-ai-business-use-cases/) (opened) | claimed | mutating (assigns) |
| Threat hunting and detection rules | Hunts threats, drafts detection rules | alert | SIEM, SOAR | Deloitte | Gemini in Security Operations | same list | claimed | mostly read-only |
| Self-healing control plane in banking | KubeCon EU 2026 talk | alert | not read | Millennium bcp, Upbound | Crossplane-based | [sched](https://kccnceu2026.sched.com/event/2CVzm/from-alert-fatigue-to-self-healing-building-ai-enabled-control-planes-in-banking-nuno-guedes-millennium-bcp-yury-tsarev-upbound) (seen) | talk, not read | not read |

### 2.2 The non-DevOps cases organisations choose first

| Use case | What it does | Who | Platform | Evidence | Maturity | Risk |
|---|---|---|---|---|---|---|
| Customer service chat | Answers and deflects customer cases | Reddit, BCU, Wiley, reMarkable | Salesforce Agentforce | [Reddit story](https://www.salesforce.com/eu/customer-stories/reddit/) (seen) | production, claimed | read-only mostly |
| Customer service chat | 2M+ chats | Commerzbank | Google | [Google list](https://blog.google/products/google-cloud/gen-ai-business-use-cases/) (opened) | production, claimed | read-only |
| Message routing | Routes customer mail to the right department | SIGNAL IDUNA | Gemini Enterprise | [story](https://cloud.google.com/customers/signaliduna) (seen) | production, claimed | mutating (routing) |
| Internal knowledge assistant | Staff questions over Jira, ServiceNow, SharePoint | FletcherTech, B3Networks | Gemini Enterprise | [FletcherTech](https://cloud.google.com/customers/fletchertech) (seen) | production, claimed | read-only |
| HR assistant | Policy questions and HR service | Cemex, Coca-Cola Andina | Copilot Studio | [Cemex](https://www.microsoft.com/en/customers/story/26985-cemex-microsoft-copilot-studio) (seen) | production, claimed | read-only plus tickets |
| IT service desk | Employees describe issues in chat; tickets opened | mobilezone, ServiceNow (own use), Salesforce (own use) | Copilot Studio, ServiceNow, Agentforce | [ServiceNow](https://www.servicenow.com/uk/customers/now-on-now-autonomous-it-service-desk.html) (seen) | production, self-reported | mutating (tickets) |
| Service desk agent assist | Summarises tickets, drafts resolution notes | EY | ServiceNow Now Assist | [story](https://www.servicenow.com/customers/ey-ai.html) (seen) | production, claimed | read-only suggestions |
| Coding assistant | Code help in the IDE | CME Group, Infosys, Capgemini | Gemini Code Assist | [Google list](https://blog.google/products/google-cloud/gen-ai-business-use-cases/) (opened) | claimed | read-only suggestions |
| Data analyst | Researchers query data without an analyst | Ipsos, Populix | Google | same list | claimed | read-only |
| Procurement supplier search | Finds suppliers | Moglix | Vertex AI | same list | claimed | read-only |

### 2.3 Independent survey

- LangChain, State of Agent Engineering, 1,340 answers, 2025-11-18 to 2025-12-02: 57.3% have agents in production. Top primary use cases: customer service 26.5%, research and data analysis 24.4%, internal workflow automation 18%. Quality is the top barrier (32%). 89% have observability; 52.4% run offline evaluations, 29.5% run none. Source URL to be confirmed in the next round (the numbers were read, the link was not kept).

## 3. Patterns and what they need from a governed platform

- **Read-only investigation is what runs in production.** Every named SRE deployment above reads telemetry and writes a finding. Only Komodor advertises changes without a click, and names one customer. Need: tool profiles with read-only tools, private network access to telemetry, audit of every tool call.
- **Changes are gated by a human click.** PagerDuty and Azure SRE Agent show approval tiers. No customer story shows the audit trail of those approvals. Need: approval for chosen tool calls ([#12](https://github.com/openagentix/openagentix/issues/12)), an audit line per approval.
- **The trigger is an alert or an incident, then chat.** Schedules are rare in the sources. Need: triggers from outside events ([#16](https://github.com/openagentix/openagentix/issues/16)), Slack ([#40](https://github.com/openagentix/openagentix/issues/40)).
- **Agents sit on top of existing observability.** They need scoped read access to Prometheus, logs, traces, GitHub and the cluster, not a shell. Need: identity per agent ([#13](https://github.com/openagentix/openagentix/issues/13)), scoped credentials ([#14](https://github.com/openagentix/openagentix/issues/14)), CLI tools behind MCP ([#141](https://github.com/openagentix/openagentix/issues/141)).
- **Private network matters.** Traversal runs inside the customer's VPC; Foundry Agent Service advertises private networking. OpenAgentix runs in the cluster already; egress control is per agent.
- **Evaluation is mostly the vendor's own.** The closest to customer evidence is a replay of 25 past incidents. Need: replayable fixtures and evaluation cases ([#25](https://github.com/openagentix/openagentix/issues/25)).
- **Budgets are almost absent from vendor material.** Only AWS DevOps Agent shows a monthly task limit. Per-agent token budgets are something OpenAgentix already has.

## 4. Merge with the owner's catalogue

Not done. The catalogue (`docs/use-cases/catalogue.md`) was not on `main` at the time of writing. Next round: unify duplicates, add the new candidates from section 2, rank by demand evidence, fit with read-only first, demo without customer data, and the features each one forces.

## 5. Shortlist of reference agents

Not done. First candidates from the evidence, to be ranked against the catalogue: alert first-pass investigation, Kubernetes cluster triage (read-only), incident scribe and on-call handover, pipeline failure analysis, change risk review, cost anomaly explanation, internal runbook question answering with sources, IT helpdesk triage.

## 6. Agent library structure

Not done. Outline: `examples/agents/<use-case>/` with a README, an `AgentDefinition`, a tool profile, fixtures (recorded alerts, logs, a broken workload), evaluation cases, and one install command. Related: [#53](https://github.com/openagentix/openagentix/issues/53).

## 7. Honest limits

- Every number in vendor material (MTTR cuts, resolution rates, hours saved) comes from the vendor or a vendor-hosted customer story. None is quoted in the tables for that reason.
- Adopters files (HolmesGPT) are self-listed by the adopter. They show use, not results.
- Salesforce's own index showed escalations to humans rising from 22% to 32% between Q1 and Q2 2025, which weakens the resolution-rate headlines (source to be confirmed).
- A reported flaw in Azure SRE Agent exposed other tenants' conversations ([BankInfoSecurity](https://www.bankinfosecurity.com/token-flaw-turned-azures-ai-agent-into-spy-a-31462), seen). Fix status not checked.
- No named customer was found for DBA or FinOps agents, or for Foundry Agent Service as such.
- Many rows rest on search summaries ("seen"). They need a page read before they are used in public claims.

## Next steps

1. Read the "seen" pages, the KubeCon NA 2026 schedule, the AgentCore sample list, and McKinsey, CNCF, PagerDuty and Datadog surveys.
2. Rebase on the catalogue pull request and write sections 4 to 6.
3. Check open issues and open at most six new gap issues, plus the agent library design issue.
