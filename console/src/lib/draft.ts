// The builder's logic, with no DOM: the draft, its limits and counters, which options the policy allows and why not,
// the secret-shape scan, and the mapping of controller sentences onto fields. It is tested on its own.
import type { Platform, Prediction, Spec } from './types';

export const MAX_DESCRIPTION = 256;
export const MAX_INSTRUCTIONS_BYTES = 16384;
export const MAX_NAME = 40;
export const MAX_SKILLS = 16;
export const MAX_EGRESS = 64;
/** Names of console pages that are also paths of the app (/agents/new, /agents/playground). */
export const CONSOLE_RESERVED = ['new', 'playground'];

export interface Draft {
    name: string;
    description: string;
    instructions: string;
    model: string;
    toolProfile: string;
    tools: string[];
    knowledge: boolean;
    /** Planned kinds: kept as they are in the definition, never edited here. */
    knowledgeCollections: string[];
    notify: boolean;
    notifyDestinations: string[];
    memoryEnabled: boolean;
    /** The number field's text; empty means the catalog default. */
    memoryTtl: string;
    skills: string[];
    /** Versions of skills the definition pins; kept when the skill stays selected. */
    skillVersions: Record<string, string>;
    egress: string[];
    suspend: boolean;
}

export function emptyDraft(p: Platform | undefined): Draft {
    const model = p?.models.find((m) => p.policy.allowedModels.includes(m)) ?? '';
    const profile =
        p && p.policy.requireToolProfile
            ? (p.profiles.find((x) => p.policy.allowedProfiles.includes(x.name))?.name ?? '')
            : '';
    return {
        name: '',
        description: '',
        instructions: '',
        model,
        toolProfile: profile,
        tools: [],
        knowledge: false,
        knowledgeCollections: [],
        notify: false,
        notifyDestinations: [],
        memoryEnabled: false,
        memoryTtl: '',
        skills: [],
        skillVersions: {},
        egress: [],
        suspend: false,
    };
}

export function draftFromSpec(name: string, s: Spec): Draft {
    return {
        name,
        description: s.description ?? '',
        instructions: s.instructions ?? '',
        model: s.model,
        toolProfile: s.toolProfile ?? '',
        tools: [...(s.tools ?? [])],
        knowledge: !!s.knowledge?.enabled,
        knowledgeCollections: [...(s.knowledge?.collections ?? [])],
        notify: !!s.notify?.enabled,
        notifyDestinations: [...(s.notify?.destinations ?? [])],
        memoryEnabled: !!s.memory?.enabled,
        memoryTtl: s.memory?.ttlDays ? String(s.memory.ttlDays) : '',
        skills: (s.skills ?? []).map((x) => x.name),
        skillVersions: Object.fromEntries(
            (s.skills ?? []).filter((x) => x.version).map((x) => [x.name, x.version as string]),
        ),
        egress: [...(s.egress?.allow ?? [])],
        suspend: !!s.suspend,
    };
}

/** The spec a draft stands for: only what is set, so the YAML stays as short as what kubectl would write. */
export function specFromDraft(d: Draft): Spec {
    const s: Spec = { model: d.model, instructions: d.instructions };
    if (d.description.trim()) s.description = d.description.trim();
    if (d.toolProfile) s.toolProfile = d.toolProfile;
    if (d.tools.length) s.tools = [...d.tools];
    if (d.knowledge)
        s.knowledge = {
            enabled: true,
            ...(d.knowledgeCollections.length ? { collections: [...d.knowledgeCollections] } : {}),
        };
    if (d.notify)
        s.notify = {
            enabled: true,
            ...(d.notifyDestinations.length ? { destinations: [...d.notifyDestinations] } : {}),
        };
    if (d.memoryEnabled) {
        const n = Number.parseInt(d.memoryTtl, 10);
        s.memory = { enabled: true, ...(Number.isFinite(n) && n > 0 ? { ttlDays: n } : {}) };
    }
    if (d.skills.length)
        s.skills = d.skills.map((n) => (d.skillVersions[n] ? { name: n, version: d.skillVersions[n] } : { name: n }));
    if (d.egress.length) s.egress = { allow: [...d.egress] };
    if (d.suspend) s.suspend = true;
    return s;
}

export function sameSpec(a: Spec, b: Spec): boolean {
    return JSON.stringify(a) === JSON.stringify(b);
}

// --- counters ---

export function byteLength(s: string): number {
    return new TextEncoder().encode(s).length;
}

const fmt = new Intl.NumberFormat('en-US');
export function counterText(used: number, max: number, unit?: string): string {
    return `${fmt.format(used)} / ${fmt.format(max)}${unit ? ` ${unit}` : ''}`;
}
/** Within 10% of the limit (or over it): the counter is announced. */
export function nearLimit(used: number, max: number): boolean {
    return used >= max * 0.9;
}

// --- name ---

const NAME_RE = /^[a-z]([-a-z0-9]*[a-z0-9])?$/;

export function nameProblem(name: string, p: Platform | undefined): string {
    if (!name) return '';
    if (name.length > MAX_NAME) return `${name} is too long: at most ${MAX_NAME} characters`;
    if (!NAME_RE.test(name)) return 'A name is lower case letters, digits and dashes, starting with a letter';
    if (CONSOLE_RESERVED.includes(name)) return `${name} is used by a page of the console; pick another name`;
    if (p && (p.reservedNames.includes(name) || p.policy.reservedNames.includes(name)))
        return `${name} is reserved (chart agents and platform services own it)`;
    return '';
}

// --- options the policy forbids ---

export interface OptionState {
    value: string;
    label: string;
    disabled: boolean;
    reason?: string;
}

export function modelOptions(p: Platform): OptionState[] {
    return p.models.map((m) =>
        p.policy.allowedModels.includes(m)
            ? { value: m, label: m, disabled: false }
            : { value: m, label: m, disabled: true, reason: 'Not allowed by the platform policy' },
    );
}

export function profileOptions(p: Platform): OptionState[] {
    const none: OptionState = p.policy.requireToolProfile
        ? { value: '', label: 'None', disabled: true, reason: 'The platform policy requires a toolProfile' }
        : { value: '', label: 'None', disabled: false };
    return [
        none,
        ...p.profiles.map((x) =>
            p.policy.allowedProfiles.includes(x.name)
                ? { value: x.name, label: x.name, disabled: false }
                : { value: x.name, label: x.name, disabled: true, reason: 'Not allowed by the platform policy' },
        ),
    ];
}

export interface ToolRow {
    name: string;
    prefix: string;
    rest: string;
    code: boolean;
    /** Listed by the definition but not offered by the selected profile. */
    foreign: boolean;
}

const PREFIXES = ['knowledge_', 'delivery_', 'osv_', 'fetch_'];

export function splitTool(name: string): { prefix: string; rest: string } {
    for (const p of PREFIXES) if (name.startsWith(p)) return { prefix: p, rest: name.slice(p.length) };
    return { prefix: '', rest: name };
}

/** The checklist: what the profile offers, plus what the definition lists that the profile does not (shown as refused rows). */
export function toolRows(p: Platform, profile: string, selected: string[]): ToolRow[] {
    const offered = p.profiles.find((x) => x.name === profile)?.tools ?? [];
    const row = (name: string, foreign: boolean): ToolRow => ({
        name,
        ...splitTool(name),
        code: name === 'execute_tool_script',
        foreign,
    });
    return [
        ...offered.map((n) => row(n, false)),
        ...selected.filter((n) => !offered.includes(n)).map((n) => row(n, true)),
    ];
}

export interface FeatureState {
    disabled: boolean;
    reason?: string;
}

export function featureState(p: Platform, f: 'knowledge' | 'notify' | 'memory'): FeatureState {
    if (f === 'knowledge') {
        if (!p.policy.allowKnowledge) return { disabled: true, reason: 'Not allowed by the platform policy' };
        if (!p.knowledge.available) return { disabled: true, reason: 'Knowledge is not installed on this platform' };
    } else if (f === 'notify') {
        if (!p.policy.allowNotify) return { disabled: true, reason: 'Not allowed by the platform policy' };
        if (!p.notify.available) return { disabled: true, reason: 'Notify is not installed on this platform' };
    } else {
        if (!p.policy.memory.allowed) return { disabled: true, reason: 'Not allowed by the platform policy' };
        if (!p.memory.available) return { disabled: true, reason: 'Memory is not installed on this platform' };
        if (p.policy.memory.requireExpiry && !p.memory.expiryEnabled)
            return {
                disabled: true,
                reason: 'The memory expiry job is off, so the time limit would not be enforced; memory is refused until an operator turns it on',
            };
    }
    return { disabled: false };
}

export interface SkillState {
    name: string;
    disabled: boolean;
    reason?: string;
}
export function skillStates(p: Platform): SkillState[] {
    return p.skills.map((s) =>
        p.policy.allowedSkills.includes(s.name)
            ? { name: s.name, disabled: false }
            : { name: s.name, disabled: true, reason: 'Not allowed by the platform policy' },
    );
}

// --- egress ---

const ORIGIN_RE = /^https?:\/\/(\*\.)?[a-z0-9]([-a-z0-9]*[a-z0-9])?(\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*(:[0-9]{1,5})?$/;

export function originShapeProblem(o: string): string {
    if (!ORIGIN_RE.test(o) || o.length > 270)
        return `${o} is not an origin: use https://host[:port], a lower case DNS name, no path, no query, no address`;
    return '';
}

// --- the secret shapes of the controller (ten patterns of memory-expiry.sh, plus the platform's virtual key) ---

const SHAPES: { name: string; re: RegExp; label: string }[] = [
    { name: 'aws_access_key_id', re: /\b(AKIA|ASIA)[0-9A-Z]{16}\b/g, label: 'AWS access key id' },
    { name: 'bearer_token', re: /[Bb]earer[ ]+[A-Za-z0-9._~+/=-]{24,}/g, label: 'bearer token' },
    { name: 'github_token', re: /\b(gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{50,})/g, label: 'GitHub token' },
    { name: 'google_api_key', re: /\bAIza[0-9A-Za-z_-]{35}/g, label: 'Google API key' },
    { name: 'jwt', re: /\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/g, label: 'JWT' },
    { name: 'private_key_header', re: /-----BEGIN [A-Z ]*PRIVATE KEY-----/g, label: 'private key header' },
    { name: 'provider_secret_key', re: /\bsk-[A-Za-z0-9_-]{32,}/g, label: 'provider secret key' },
    { name: 'slack_token', re: /\bxox[abeprs]-[A-Za-z0-9-]{10,}/g, label: 'Slack token' },
    { name: 'stripe_secret_key', re: /\b(sk|rk)_(live|test)_[0-9A-Za-z]{16,}/g, label: 'Stripe key' },
    { name: 'telegram_bot_token', re: /\b[0-9]{8,10}:[A-Za-z0-9_-]{35}/g, label: 'Telegram bot token' },
    { name: 'platform_virtual_key', re: /\bvk-[0-9a-f]{32}\b/g, label: 'platform virtual key' },
];

export interface SecretMatch {
    name: string;
    label: string;
    start: number;
    end: number;
}

export function scanSecrets(text: string): SecretMatch[] {
    const out: SecretMatch[] = [];
    for (const s of SHAPES) {
        for (const m of text.matchAll(s.re))
            out.push({ name: s.name, label: s.label, start: m.index ?? 0, end: (m.index ?? 0) + m[0].length });
    }
    return out.sort((a, b) => a.start - b.start);
}

export function secretSentence(m: SecretMatch[]): string {
    const first = m[0];
    if (!first) return '';
    return `Instructions contain something shaped like a secret (${first.label}); remove it.`;
}

// --- sentences to fields ---

export type FieldKey =
    | 'name'
    | 'description'
    | 'instructions'
    | 'model'
    | 'toolProfile'
    | 'tools'
    | 'knowledge'
    | 'notify'
    | 'memory'
    | 'memory.ttlDays'
    | 'skills'
    | 'egress.allow';

/** Which field a controller sentence is about, by the words the controller uses. A sentence that maps to none stays in the notice only. */
export function fieldOfSentence(s: string): FieldKey | null {
    const t = s.trim();
    if (/^name\b/.test(t) || /^the platform policy allows at most \d+ agents/.test(t)) return 'name';
    if (/^description\b/.test(t)) return 'description';
    if (/^instructions\b/.test(t)) return 'instructions';
    if (/^model\b/.test(t)) return 'model';
    if (/^toolProfile\b/.test(t) || /^the platform policy requires a toolProfile/.test(t)) return 'toolProfile';
    if (/^the definition lists tool/.test(t) || /^tools\b/.test(t))
        return /names no toolProfile/.test(t) ? 'toolProfile' : 'tools';
    if (/^knowledge\b/.test(t)) return 'knowledge';
    if (/^notify\b/.test(t)) return 'notify';
    if (/^memory\.ttlDays\b/.test(t)) return 'memory.ttlDays';
    if (/^memory\b/.test(t) || /^the memory expiry job/.test(t)) return 'memory';
    if (/^skills?\b/.test(t)) return 'skills';
    if (/^egress\.allow\b/.test(t)) return 'egress.allow';
    return null;
}

export function bucketSentences(sentences: string[]): Map<FieldKey, string[]> {
    const m = new Map<FieldKey, string[]>();
    for (const s of sentences) {
        const f = fieldOfSentence(s);
        if (f) m.set(f, [...(m.get(f) ?? []), s]);
    }
    return m;
}

export function bucketPredictions(ps: Prediction[]): Map<FieldKey, string[]> {
    const m = new Map<FieldKey, string[]>();
    for (const p of ps) {
        const f = (p.field as FieldKey) || fieldOfSentence(p.message);
        if (f) m.set(f, [...(m.get(f) ?? []), p.message]);
    }
    return m;
}

/** An origin named in a sentence, so its tag can take the refused edge. */
export function originsInSentences(sentences: string[]): Set<string> {
    const out = new Set<string>();
    for (const s of sentences) for (const m of s.matchAll(/"((?:https?:\/\/)[^"]+)"/g)) if (m[1]) out.add(m[1]);
    return out;
}

/** The knowledge, notify and memory prompts this draft would add to the system prompt. */
export function addedPrompts(p: Platform, d: Draft): { title: string; text: string }[] {
    const out: { title: string; text: string }[] = [];
    if (d.knowledge && p.knowledge.prompt) out.push({ title: 'knowledge', text: p.knowledge.prompt });
    if (d.notify && p.notify.prompt) out.push({ title: 'notify', text: p.notify.prompt });
    if (d.memoryEnabled && p.memory.prompt) out.push({ title: 'memory', text: p.memory.prompt });
    return out;
}

export function memoryMax(p: Platform): number {
    return p.policy.memory.maxTtlDays;
}
