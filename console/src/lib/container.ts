// The "Bring your own agent" path of the builder, with no DOM: the draft, the spec it stands for, and the rules the platform
// guard applies to a container agent (ADR 0015, ADR 0019) in plain English. The controller stays the authority: these checks
// only save a round trip, and the validate route repeats them on the server before anything is created.
import { nameProblem, scanSecrets, type OptionState } from './draft';
import type { Platform, Spec } from './types';

export const MIN_PORT = 1024;
export const MAX_PORT = 65535;
export const MAX_ENV_VARS = 32;
export const MAX_ENV_VALUE_BYTES = 4096;
export const MAX_ENV_TOTAL_BYTES = 16 * 1024;
export const MAX_ENV_NAME = 63;
/** Names that belong to the platform. */
export const RESERVED_ENV_PREFIXES = ['OPENAGENTIX_', 'OPENAI_', 'OTEL_', 'KUBERNETES_'];

export interface EnvRow {
    name: string;
    value: string;
}

export interface ContainerDraft {
    name: string;
    description: string;
    model: string;
    image: string;
    /** The number field's text. */
    port: string;
    env: EnvRow[];
    toolProfile: string;
}

export type ContainerField = 'name' | 'description' | 'model' | 'image' | 'port' | 'env' | 'toolProfile';

export function emptyContainerDraft(p: Platform | undefined): ContainerDraft {
    const model = p?.models.find((m) => p.policy.allowedModels.includes(m)) ?? '';
    return { name: '', description: '', model, image: '', port: '8080', env: [], toolProfile: '' };
}

/** The spec a draft stands for. A container agent has no instructions: it is configured in its image. */
export function containerSpec(d: ContainerDraft): Spec {
    const container: NonNullable<NonNullable<Spec['runtime']>['container']> = {
        image: d.image.trim(),
        port: Number.parseInt(d.port, 10),
    };
    const env = d.env
        .filter((e) => e.name.trim() !== '' || e.value !== '')
        .map((e) => ({ name: e.name.trim(), value: e.value }));
    if (env.length) container.env = env;
    const s: Spec = { model: d.model, runtime: { type: 'container', container } };
    if (d.description.trim()) s.description = d.description.trim();
    if (d.toolProfile) s.toolProfile = d.toolProfile;
    return s;
}

// --- availability ---

export function containerAvailability(p: Platform): { ok: true } | { ok: false; reason: string } {
    if (!p.container.available)
        return {
            ok: false,
            reason: 'Container agents are not installed on this platform. An operator turns them on with controlPlane.containerAgents.enabled.',
        };
    if (!p.container.allowed)
        return {
            ok: false,
            reason: 'The platform policy does not allow container agents. An operator adds container to controlPlane.policy.allowedRuntimes.',
        };
    if (p.container.images.length === 0)
        return {
            ok: false,
            reason: 'The platform policy allows no image registry yet, so no image can be used. An operator lists registries in controlPlane.policy.runtimes.container.images.',
        };
    return { ok: true };
}

// --- the image ---

const IMAGE_RE = /^[a-z0-9.-]+(:[0-9]+)?(\/[a-z0-9._-]+)+@sha256:[0-9a-f]{64}$/;
const TAG_NEXT_TO_DIGEST_RE = /:[^/@:]+@sha256:/;

/** An example image that would pass, built from the first registry the policy allows. */
export function imageExample(p: Platform): string {
    const prefix = p.container.images[0] ?? 'registry.example.com/team/';
    return `${prefix}my-agent@sha256:<64 hex digits>`;
}

function imageProblem(image: string, p: Platform): string {
    const img = image.trim();
    if (!img) return 'Enter the image reference.';
    if (TAG_NEXT_TO_DIGEST_RE.test(img))
        return 'Remove the tag. Use the registry, the path and the digest only: registry/path@sha256:<64 hex digits>.';
    if (!img.includes('@'))
        return `The image must be pinned by digest, for example ${imageExample(p)}. A digest, not a tag: :latest and :1.0 are not accepted. Find the digest with: docker buildx imagetools inspect <image>`;
    if (!/@sha256:[0-9a-f]{64}$/.test(img))
        return 'The digest must be sha256: followed by exactly 64 lower case hex digits (0 to 9 and a to f).';
    if (!IMAGE_RE.test(img))
        return 'This is not a valid image reference. Use lower case letters, digits, dots, dashes and underscores: registry/path@sha256:<64 hex digits>.';
    if (p.container.images.length === 0)
        return 'The platform policy allows no image registry yet, so no image can be used. Ask an operator to list registries in controlPlane.policy.runtimes.container.images.';
    if (!p.container.images.some((pre) => pre !== '' && img.startsWith(pre)))
        return `This image is not under a registry the platform policy allows. It must start with one of: ${p.container.images.join(', ')}`;
    return '';
}

// --- port and environment ---

function portProblem(port: string): string {
    const t = port.trim();
    const n = Number(t);
    if (!/^\d+$/.test(t) || !Number.isInteger(n) || n < MIN_PORT || n > MAX_PORT)
        return `The port must be a whole number from ${MIN_PORT} to ${MAX_PORT}. The container runs as a non-root user, so it cannot use a lower port.`;
    return '';
}

const bytes = (s: string) => new TextEncoder().encode(s).length;

function envProblems(env: EnvRow[]): string[] {
    const out: string[] = [];
    const rows = env.filter((e) => e.name.trim() !== '' || e.value !== '');
    if (rows.length > MAX_ENV_VARS)
        out.push(`At most ${MAX_ENV_VARS} environment variables are allowed; there are ${rows.length}.`);
    const seen = new Set<string>();
    let total = 0;
    for (const e of rows) {
        const name = e.name.trim();
        total += bytes(name) + bytes(e.value);
        if (!/^[A-Z_][A-Z0-9_]*$/.test(name) || name.length > MAX_ENV_NAME) {
            out.push(
                `${name || 'A variable'} is not a valid name. Use upper case letters, digits and underscores, not starting with a digit (at most ${MAX_ENV_NAME} characters).`,
            );
            continue;
        }
        if (seen.has(name)) {
            out.push(`${name} is set twice.`);
            continue;
        }
        seen.add(name);
        if (RESERVED_ENV_PREFIXES.some((x) => name.startsWith(x)))
            out.push(
                `${name} is reserved: names that start with ${RESERVED_ENV_PREFIXES.join(', ')} belong to the platform.`,
            );
        if (bytes(e.value) > MAX_ENV_VALUE_BYTES)
            out.push(`The value of ${name} is ${bytes(e.value)} bytes; at most ${MAX_ENV_VALUE_BYTES} are allowed.`);
        const sec = scanSecrets(e.value);
        // the value is never repeated in a message: only its kind
        if (sec[0])
            out.push(
                `The value of ${name} is shaped like a secret (${sec[0].label}). A plain value is not the place for one: remove it. The agent gets its model key from the platform.`,
            );
    }
    if (total > MAX_ENV_TOTAL_BYTES)
        out.push(`The environment is ${total} bytes in all; at most ${MAX_ENV_TOTAL_BYTES} are allowed.`);
    return out;
}

// --- options ---

/** The tool profiles a container agent may use: allowed by the policy and opened to container agents by the operator. */
export function containerProfileOptions(p: Platform): OptionState[] {
    return [
        { value: '', label: 'None', disabled: false },
        ...p.profiles.map((x): OptionState => {
            if (!p.policy.allowedProfiles.includes(x.name))
                return { value: x.name, label: x.name, disabled: true, reason: 'Not allowed by the platform policy' };
            if (!x.containerAccess)
                return { value: x.name, label: x.name, disabled: true, reason: 'Not open to container agents' };
            return { value: x.name, label: x.name, disabled: false };
        }),
    ];
}

// --- all rules ---

/** What is wrong with a draft, by field, in plain English. A field that is fine has no entry. */
export function containerProblems(d: ContainerDraft, p: Platform): Partial<Record<ContainerField, string>> {
    const out: Partial<Record<ContainerField, string>> = {};
    const name = nameProblem(d.name, p);
    if (name) out.name = name;
    if (!d.model) out.model = 'Choose a model.';
    else if (!p.models.includes(d.model) || !p.policy.allowedModels.includes(d.model))
        out.model = `${d.model} is not allowed by the platform policy. Choose one of the models in the list.`;
    const image = imageProblem(d.image, p);
    if (image) out.image = image;
    const port = portProblem(d.port);
    if (port) out.port = port;
    const env = envProblems(d.env);
    if (env.length) out.env = env.join(' ');
    if (d.toolProfile) {
        const prof = p.profiles.find((x) => x.name === d.toolProfile);
        if (!prof) out.toolProfile = `${d.toolProfile} is not defined on this platform.`;
        else if (!p.policy.allowedProfiles.includes(d.toolProfile))
            out.toolProfile = `${d.toolProfile} is not allowed by the platform policy.`;
        else if (!prof.containerAccess)
            out.toolProfile = `${d.toolProfile} is not open to container agents. An operator opens a profile with controlPlane.containerAgents.toolProfiles.`;
    }
    return out;
}

/** Which field a server sentence (a prediction or a refusal) is about. */
export function containerFieldOf(field: string, message = ''): ContainerField | null {
    if (field === 'name' || field === 'model' || field === 'toolProfile' || field === 'description') return field;
    if (field === 'runtime.container.image') return 'image';
    if (field === 'runtime.container.port') return 'port';
    if (field === 'runtime.container.env') return 'env';
    if (field === 'runtime' || field === 'runtime.container') return message.includes('image') ? 'image' : null;
    return null;
}
