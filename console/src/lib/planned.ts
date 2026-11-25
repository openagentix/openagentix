// The honest "not available yet" pages (ADR 0007 table, UI-SPEC section 6, the read-only notices of the mockup).
// Each says what the page will show, why it is not available in this release, and where the thing is configured today.
// Text between backticks is rendered as code. There is no data here, and none is invented.

export interface PlannedContent {
    title: string;
    strip: string;
    noticeTitle: string;
    notice: string;
    willShow: string[];
    why: string;
    today: string;
}

export interface Seg {
    text: string;
    code: boolean;
}

/** Splits "Set `gateway.models` in values" into text and code segments. */
export function segments(s: string): Seg[] {
    return s
        .split('`')
        .map((text, i) => ({ text, code: i % 2 === 1 }))
        .filter((x) => x.text !== '');
}

/** The header and the read-only notice of the pages that show real data (Models, Tools, Skills, Memory, Governance). */
export interface ReadOnlyContent {
    title: string;
    strip: string;
    noticeTitle: string;
    notice: string;
}

export const READONLY: Record<string, ReadOnlyContent> = {
    skills: {
        title: 'Skills',
        strip: 'platform catalog · skills (digest-pinned OCI images) · platform policy',
        noticeTitle: 'Read-only in this release',
        notice: 'Skills are OCI images listed under `skills` in chart values with a pinned digest. Change them there and run `install.sh`. Editing skills from the console is postponed (ADR 0013).',
    },
    models: {
        title: 'Models',
        strip: 'platform catalog · platform policy · chart values gateway.models',
        noticeTitle: 'Read-only in this release',
        notice: 'Models are set in chart values under `gateway.models`, and provider keys are Secrets in `agentgateway-system`. Change them there and run `install.sh`. Editing models from the console is postponed (ADR 0013).',
    },
    tools: {
        title: 'Tools',
        strip: 'platform catalog · platform policy · chart values mcp.servers, mcp.profiles',
        noticeTitle: 'Read-only in this release',
        notice: 'Servers and profiles are set in chart values under `mcp.servers` and `mcp.profiles`. A new server image is a supply-chain decision and will need operator approval. Editing tools from the console is postponed (ADR 0013).',
    },
    memory: {
        title: 'Memory',
        strip: 'platform catalog · platform policy · AgentDefinition memory',
        noticeTitle: 'Settings are edited per agent in the builder',
        notice: "This page only reads. A person's memories are never listed in the console. A Telegram user can list and forget their own with `/memories` and `/forget`.",
    },
    governance: {
        title: 'Governance',
        strip: 'ConfigMap control-plane-policy · AgentDefinition status',
        noticeTitle: 'Owned by operators',
        notice: 'The platform policy and the gate rules are not edited in the console. Change `controlPlane.policy` and `governance.a2a.callers` in chart values or Git.',
    },
};

export const PLANNED: Record<string, PlannedContent> = {
    playground: {
        title: 'Playground',
        strip: 'A2A gate · caller console',
        noticeTitle: 'Not available yet',
        notice: 'Sending a message goes through the A2A gate as caller `console`. The console API has no route for it in this release.',
        willShow: [
            'A conversation with one Ready agent, with its tool calls as collapsed rows',
            'A footer per turn: model calls, tokens, cost, duration and a link to the trace',
            'The caller `console` and the user id the agent sees',
        ],
        why: 'The playground needs a gate caller rule for `console`, the gate switched on, and a route that sends the message. ADR 0007 puts it in a later slice than the registry and the builder.',
        today: 'Call an agent through the A2A gate with a caller rule from `governance.a2a.callers` in chart values, or ask it through a channel binding in `channels.bindings`.',
    },
    knowledge: {
        title: 'Knowledge',
        strip: 'kb service · namespace openagentix-knowledge',
        noticeTitle: 'No data source in this release',
        notice: 'Today documents are added with `hack/kb-ingest.sh <dir> <collection>` and curated facts with `hack/kb-graph-load.sh`.',
        willShow: [
            'Collections with documents, chunks and last ingest; graph statistics where the graph is on',
            'Sources and their sync schedule',
            'A graph view with the path of a question and the document each fact came from',
        ],
        why: 'The console API has no route to the knowledge service, and the `KnowledgeCollection` and `KnowledgeSource` kinds are postponed (ADR 0013).',
        today: "`hack/kb-ingest.sh` and `hack/kb-graph-load.sh`; whether a built agent may use knowledge is the policy `allowKnowledge` and the builder's Knowledge switch.",
    },
    channels: {
        title: 'Channels and triggers',
        strip: 'Agent Kourier · ChatConnection, Binding · Telegram bridge',
        noticeTitle: 'No data source in this release',
        notice: 'Today connections and bindings are set in chart values under `channels.connections` and `channels.bindings`. Credentials will be entered once and never shown again.',
        willShow: [
            'Connections: platform, verification scheme, whether the secret is set, readiness',
            'Bindings: connection, channel, agent, trigger, limits and the user id the agent sees',
            'The Telegram bridge: allowlist size and memory commands',
        ],
        why: 'The console API does not read Kourier resources, and the `Channel` and `Trigger` kinds are not in the release plan of ADR 0013.',
        today: '`channels.connections` and `channels.bindings` in chart values.',
    },
    schedules: {
        title: 'Schedules',
        strip: 'CronJob · namespace openagentix-schedules · chart values schedules[]',
        noticeTitle: 'No data source in this release',
        notice: 'Today schedules are set in chart values under `schedules`. Every firing is at least one model call.',
        willShow: [
            'Each schedule with its agent, cron expression in plain English, state and next run',
            'The last runs with outcome and duration',
            'The user id the agent sees, which is the scope of its memory',
        ],
        why: 'The console API does not read CronJobs, and the `Schedule` kind is planned for release 0.3 (ADR 0013).',
        today: '`schedules` in chart values.',
    },
    traces: {
        title: 'Traces',
        strip: 'Observability adapter · bundled Jaeger · last 2,000 traces in memory',
        noticeTitle: 'No data source in this release',
        notice: 'The console API does not read the trace store in this release. Prompts and answers are not stored (content capture is off).',
        willShow: [
            'Recent turns with time, agent, caller, duration, model calls, cost and outcome',
            'One turn as a waterfall of gate, agent, model, tool, memory and knowledge spans',
            'Attributes of the selected span, in platform names',
        ],
        why: 'It needs the observability adapter of ADR 0009. No route of the console API reads Jaeger yet, so the page would have nothing true to show.',
        today: 'The bundled Jaeger, when `observability.enabled` is true in chart values.',
    },
};
