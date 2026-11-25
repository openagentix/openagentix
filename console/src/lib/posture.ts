// The security posture and the usage counts of the Overview, from the policy, the catalog and the agents list only.
import type { Agent, Platform } from './types';

export interface PostureItem {
    id: 'profile' | 'egress' | 'gate' | 'memory' | 'skills' | 'max' | 'suspend';
    ok: boolean;
    /** One plain statement. */
    text: string;
}

const plural = (n: number, w: string) => `${n} ${w}${n === 1 ? '' : 's'}`;

/** The policy and the catalog said as plain statements, each with a verdict (a check or a warning). */
export function posture(p: Platform): PostureItem[] {
    const pol = p.policy;
    const out: PostureItem[] = [
        {
            id: 'profile',
            ok: pol.requireToolProfile,
            text: pol.requireToolProfile
                ? 'Every agent must use a tool profile: no tool outside a profile.'
                : 'A tool profile is optional: an agent may be defined without one.',
        },
        {
            id: 'egress',
            ok: true,
            text: `Outbound access is denied unless an origin matches the policy: ${plural(pol.egress.allowedOrigins.length, 'allowed origin')}, ${plural((pol.egress.inClusterDestinations ?? []).length, 'in-cluster exception')}.`,
        },
        {
            id: 'gate',
            ok: p.gateEnabled,
            text: p.gateEnabled
                ? 'The A2A gate is on: calls to agents go through the gate, which checks the caller.'
                : 'The A2A gate is off: calls to agents are not checked by caller rules.',
        },
    ];
    if (!pol.memory.allowed)
        out.push({ id: 'memory', ok: true, text: 'Memory is not allowed: no agent can remember.' });
    else
        out.push({
            id: 'memory',
            ok: p.memory.expiryEnabled,
            text: p.memory.expiryEnabled
                ? `Memory expires: the expiry job is on, at most ${pol.memory.maxTtlDays} days.`
                : 'Memory is allowed but the expiry job is off: memories are not removed when they expire.',
        });
    out.push(
        {
            id: 'skills',
            ok: true,
            text: `Skills are restricted: ${plural(pol.allowedSkills.length, 'approved skill')}.`,
        },
        { id: 'max', ok: true, text: `The number of agents is limited to ${pol.maxAgents} definitions.` },
    );
    if (pol.suspendAll)
        out.push({
            id: 'suspend',
            ok: false,
            text: "The operator's stop switch is on: every definition is treated as suspended.",
        });
    return out;
}

/** Tool profiles and models the agents really name, against what the catalog offers. */
export function inUse(agents: Agent[], p: Platform) {
    const profiles = new Set(agents.map((a) => a.toolProfile).filter((x) => p.profiles.some((pr) => pr.name === x)));
    const models = new Set(agents.map((a) => a.model).filter((m) => p.models.includes(m)));
    return { profiles: profiles.size, profilesOf: p.profiles.length, models: models.size, modelsOf: p.models.length };
}

/** The most recently updated agents. */
export function recent(agents: Agent[], n: number): Agent[] {
    return [...agents].sort((a, b) => (Date.parse(b.updated) || 0) - (Date.parse(a.updated) || 0)).slice(0, n);
}
