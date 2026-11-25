// Pure helpers behind the read-only pages. Everything here is computed from the two API answers (/platform and /agents):
// nothing is added that the cluster, the catalog or the policy did not say.
import { scalar } from './yaml';
import type { Agent, Platform, PlatformPolicy, Session, State } from './types';

/** "registry/x@sha256:9c1e…b07d": the repository in full, the digest shortened. The full value is copied from the page. */
export function shortRef(ref: string): string {
    const m = /^(.*)@sha256:([0-9a-f]+)$/.exec(ref);
    const hex = m?.[2] ?? '';
    if (!m || hex.length <= 12) return ref;
    return `${m[1]}@sha256:${hex.slice(0, 4)}…${hex.slice(-4)}`;
}

/** The line under the logo: cluster context and namespace, or just the namespace when no context is named. */
export function contextLine(s: Pick<Session, 'context' | 'namespace'> | null): string {
    if (!s) return '';
    const c = (s.context ?? '').trim();
    if (!c) return s.namespace ?? '';
    if (!s.namespace || c.includes(s.namespace)) return c;
    return `${c} · ${s.namespace}`;
}

export interface StateCounts extends Record<State, number> {
    total: number;
    chart: number;
    built: number;
}

export function countStates(agents: Agent[]): StateCounts {
    const c: StateCounts = {
        ready: 0,
        pending: 0,
        refused: 0,
        error: 0,
        paused: 0,
        total: agents.length,
        chart: 0,
        built: 0,
    };
    for (const a of agents) {
        c[a.state]++;
        if (a.source === 'chart') c.chart++;
        else c.built++;
    }
    return c;
}

const RANK: Record<State, number> = { refused: 0, error: 1, pending: 2, paused: 3, ready: 4 };

export interface Attention {
    name: string;
    state: State;
    deleting: boolean;
    source: Agent['source'];
    reason: string;
    updated: string;
}

/** Definitions that are not Ready, each with the reason the API gives (for a refusal, the first violation sentence). */
export function attention(agents: Agent[]): Attention[] {
    return agents
        .filter((a) => a.state !== 'ready')
        .sort((a, b) => RANK[a.state] - RANK[b.state] || a.name.localeCompare(b.name))
        .map((a) => ({
            name: a.name,
            state: a.state,
            deleting: a.deleting,
            source: a.source,
            reason: a.stateReason,
            updated: a.updated,
        }));
}

/** Names of the agents (sorted) for which `pred` holds: "used by". */
export function usedBy(agents: Agent[], pred: (a: Agent) => boolean): string[] {
    return agents
        .filter(pred)
        .map((a) => a.name)
        .sort((a, b) => a.localeCompare(b));
}

export function ttlLine(p: Pick<Platform, 'memory' | 'policy'>): string {
    return `${p.memory.defaultTtlDays} days by default, at most ${p.policy.memory.maxTtlDays} days`;
}

export interface PlatformRow {
    label: string;
    /** The adapter name, set in mono. Empty for an optional component. */
    value: string;
    on: boolean | null;
    /** One plain sentence. */
    note: string;
}

/** The Platform panel of the Overview: active adapters and optional components, from the catalog only. */
export function platformRows(p: Platform): PlatformRow[] {
    const days = `${p.memory.defaultTtlDays} days by default`;
    return [
        { label: 'Runtime', value: p.adapters.runtime, on: null, note: 'runs the agents' },
        { label: 'Model gateway', value: p.adapters.modelGateway, on: null, note: 'every model call goes through it' },
        { label: 'Tools', value: p.adapters.tools, on: null, note: 'serves the tool profiles' },
        {
            label: 'Knowledge',
            value: '',
            on: p.knowledge.available,
            note: p.knowledge.available
                ? 'on: an agent may search the knowledge base'
                : 'off: `knowledge.enabled` is false in chart values',
        },
        {
            label: 'Memory',
            value: '',
            on: p.memory.available,
            note: p.memory.available
                ? `on, ${p.memory.expiryEnabled ? 'expiry job on' : 'expiry job off'}, ${days}`
                : 'off: the memory stack is not installed',
        },
        {
            label: 'Notify',
            value: '',
            on: p.notify.available,
            note: p.notify.available
                ? 'on: an agent may send a message to a chat'
                : 'off: no delivery tool is installed',
        },
        {
            label: 'A2A gate',
            value: '',
            on: p.gateEnabled,
            note: p.gateEnabled
                ? 'on: agents are called through the gate, which checks the caller'
                : 'off: the gate is not installed',
        },
    ];
}

// URLs, host:port and wildcard origins are plain scalars in YAML (a colon not followed by a space), so they stay unquoted.
function yScalar(s: string): string {
    const plain =
        /^[A-Za-z][A-Za-z0-9_./:@*-]*$/.test(s) &&
        !s.endsWith(':') &&
        !/^(true|false|null|yes|no|on|off|y|n)$/i.test(s);
    return plain ? s : scalar(s);
}

function yList(out: string[], indent: number, key: string, items: string[]): void {
    const pad = ' '.repeat(indent);
    if (!items.length) {
        out.push(`${pad}${key}: []`);
        return;
    }
    out.push(`${pad}${key}:`);
    for (const i of items) out.push(`${pad}  - ${yScalar(i)}`);
}

/** The platform policy as YAML, in the field order of services/control-plane/README.md ("Policy file"). */
export function policyYaml(p: PlatformPolicy): string {
    const o: string[] = [];
    o.push(`maxAgents: ${p.maxAgents}`);
    yList(o, 0, 'allowedModels', p.allowedModels);
    o.push(`requireToolProfile: ${p.requireToolProfile}`);
    yList(o, 0, 'allowedProfiles', p.allowedProfiles);
    o.push(`allowKnowledge: ${p.allowKnowledge}`);
    o.push(`allowNotify: ${p.allowNotify}`);
    yList(o, 0, 'allowedSkills', p.allowedSkills);
    o.push(
        'memory:',
        `  allowed: ${p.memory.allowed}`,
        `  maxTtlDays: ${p.memory.maxTtlDays}`,
        `  requireExpiry: ${p.memory.requireExpiry}`,
    );
    o.push('egress:');
    yList(o, 2, 'allowedOrigins', p.egress.allowedOrigins);
    yList(o, 2, 'inClusterDestinations', p.egress.inClusterDestinations ?? []);
    yList(o, 0, 'reservedNames', p.reservedNames);
    o.push(`suspendAll: ${p.suspendAll}`);
    return o.join('\n') + '\n';
}
