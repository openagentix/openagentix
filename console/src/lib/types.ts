// The JSON of the console API (services/console/internal/model and internal/platform), by hand. Keep in step with the Go side.

export type State = 'ready' | 'pending' | 'refused' | 'error' | 'paused';
export type Source = 'built' | 'chart';
export type ConditionStatus = 'True' | 'False' | 'Unknown';

export interface Memory {
    enabled: boolean;
    ttlDays?: number;
}

export interface Egress {
    allow?: string[];
}

/** knowledge and notify (ADR 0012): the lists belong to planned kinds and are empty for now. */
export interface FeatureSpec {
    enabled: boolean;
    collections?: string[];
    destinations?: string[];
}

export interface SkillRef {
    name: string;
    version?: string;
}

export interface ContainerEnvVar {
    name: string;
    value: string;
}

/** spec.runtime.container (ADR 0015): the user's own image, pinned by digest. */
export interface ContainerRuntime {
    image: string;
    port: number;
    env?: ContainerEnvVar[];
}

export interface Runtime {
    type?: 'builtin' | 'container' | string;
    container?: ContainerRuntime;
}

export interface Spec {
    description?: string;
    model: string;
    /** Absent for a container agent, which is configured in its image. */
    instructions?: string;
    runtime?: Runtime;
    toolProfile?: string;
    tools?: string[];
    knowledge?: FeatureSpec;
    notify?: FeatureSpec;
    memory?: Memory;
    skills?: SkillRef[];
    egress?: Egress;
    suspend?: boolean;
}

export interface Condition {
    type: string;
    status: ConditionStatus;
    reason: string;
    message?: string;
    observedGeneration?: number;
    lastTransitionTime?: string;
}

export interface ObjectRef {
    apiVersion: string;
    kind: string;
    name: string;
}

export interface Endpoint {
    protocol?: string;
    url?: string;
    protocolVersion?: string;
}

/**
 * The public status contract (ADR 0012): conditions (Accepted and Ready are the contract, the rest informational),
 * observedGeneration, endpoint, revision, effectiveTools, effectiveEgress, violations, capabilities, agentRef.
 * `controller` is internal and may change without notice: shown collapsed, never relied on.
 */
export interface Status {
    observedGeneration: number;
    conditions: Condition[];
    endpoint?: Endpoint;
    revision?: string;
    effectiveTools: string[];
    effectiveEgress: string[];
    violations: string[];
    capabilities?: Record<string, unknown>;
    agentRef?: ObjectRef;
    controller?: Record<string, unknown>;
}

export interface Agent {
    name: string;
    namespace: string;
    source: Source;
    description: string;
    model: string;
    toolProfile: string;
    toolsCount: number;
    knowledge: boolean;
    notify: boolean;
    memory?: Memory;
    suspended: boolean;
    runtimeType?: 'builtin' | 'container';
    isolation?: string;
    team?: string;
    project?: string;
    skills: string[];
    egressCount: number;
    /** status.effectiveTools and status.effectiveEgress: what the controller gave the agent. Empty for a chart agent. */
    effectiveTools: string[];
    effectiveEgress: string[];
    state: State;
    stateReason: string;
    deleting: boolean;
    conditions: Condition[];
    generation: number;
    updated: string;
    resourceVersion?: string;
}

export interface AgentList {
    items: Agent[];
    used: number;
    warnings: string[];
    /** True when the cluster holds more objects than the console reads; `cap` is how many it read of each kind. */
    truncated?: boolean;
    cap?: number;
}

export interface OwnedObject {
    kind: string;
    name?: string;
    state?: string;
    note?: string;
}

export interface Detail extends Agent {
    readOnly: boolean;
    spec?: Spec;
    status?: Status;
    yaml: string;
    objects: OwnedObject[];
    /** Spec fields the stored object has and the console cannot edit (instructionsFrom, or a later release's). A save keeps them. */
    unmanaged?: string[];
}

export interface WriteRequest {
    name: string;
    resourceVersion?: string;
    spec: Spec;
}

export interface Prediction {
    field: string;
    message: string;
}

export interface ValidateResult {
    schema: { ok: boolean; skipped: boolean; errors: string[] };
    predicted: Prediction[];
    prediction: boolean;
    note: string;
}

export interface Session {
    subject: string;
    role: 'operator' | 'viewer';
    canWrite: boolean;
    /** What the Authorizer allows for a bare resource, per action: create, update, delete, validate. */
    capabilities?: Record<string, boolean>;
    demo: boolean;
    version: string;
    edition: string;
    namespace: string;
    context: string;
}

export interface Profile {
    name: string;
    toolServer: string;
    codeMode: boolean;
    tools: string[];
    /** The operator opened this profile to container agents (ADR 0019). */
    containerAccess?: boolean;
}

export interface Feature {
    available: boolean;
    tools: string[];
    prompt: string;
}

export interface PlatformPolicy {
    maxAgents: number;
    allowedModels: string[];
    requireToolProfile: boolean;
    allowedProfiles: string[];
    allowKnowledge: boolean;
    allowNotify: boolean;
    allowedSkills: string[];
    memory: { allowed: boolean; maxTtlDays: number; requireExpiry: boolean };
    egress: { allowedOrigins: string[]; inClusterDestinations?: string[] };
    reservedNames: string[];
    /** The operator's stop switch: every definition is treated as suspended. */
    suspendAll: boolean;
    /** Runtime types a definition may use; absent means builtin only. */
    allowedRuntimes?: string[];
}

/** What the builder needs for "bring your own agent" (GET /api/v1/platform, field container). */
export interface ContainerInfo {
    /** The platform has the container runtime installed. */
    available: boolean;
    /** The policy lists the container runtime in allowedRuntimes. */
    allowed: boolean;
    /** Registry prefixes an image must start with. Empty: no image is allowed. */
    images: string[];
    /** Most container agents in the namespace; 0 means no extra limit. */
    maxAgents: number;
}

/** Already formatted headline numbers of the metrics row (the metrics route is a later pull request; absent today). */
export interface MetricsHeadline {
    spendToday: string;
    spendNote: string;
    tokensToday: string;
    tokensNote: string;
    turns24h: string;
    turnsNote: string;
}

export interface Platform {
    demo: boolean;
    /** Present only when the console API can read a metrics store. */
    metrics?: { available: boolean };
    /** Present only when the console API can read a trace store. */
    traces?: { available: boolean };
    adapters: { runtime: string; modelGateway: string; tools: string };
    namespaces: { agents: string; gateway: string; tools: string };
    gatewayBaseUrl: string;
    gateEnabled: boolean;
    models: string[];
    toolServer: string;
    profiles: Profile[];
    knowledge: Feature;
    notify: Feature;
    memory: { available: boolean; expiryEnabled: boolean; defaultTtlDays: number; prompt: string };
    skills: { name: string; ref: string }[];
    reservedNames: string[];
    policy: PlatformPolicy;
    container: ContainerInfo;
}

/** GET /api/v1/schedules (services/console/internal/govern). No prompt, token or user id. */
export interface Schedule {
    name: string;
    agent: string;
    cron: string;
    timeZone: string;
    concurrencyPolicy: string;
    timeout: string;
    state: 'active' | 'suspended';
    active: number;
    lastScheduled: string;
    lastSucceeded: string;
    created: string;
}
export interface ScheduleList {
    configured: boolean;
    namespace: string;
    items: Schedule[];
}

/** GET /api/v1/access. The user id value, keys and hashes are never in it. */
export interface Caller {
    name: string;
    source: 'chart' | 'values';
    serviceAccount: string;
    key: boolean;
    agents: string[];
    userIdRule: 'exact' | 'prefix' | 'fixed' | '';
    methods: string[];
    memory: boolean;
}
export interface AccessList {
    configured: boolean;
    namespace: string;
    items: Caller[];
}

export const CONDITION_ORDER = ['Accepted', 'KeyReady', 'Applied', 'Ready'] as const;
