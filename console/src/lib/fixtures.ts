import type { Agent, Detail, Platform } from './types';

export function platform(): Platform {
    return {
        demo: true,
        adapters: { runtime: 'kagent', modelGateway: 'agentgateway', tools: 'toolhive' },
        namespaces: { agents: 'kagent', gateway: 'g', tools: 't' },
        gatewayBaseUrl: 'http://gw/v1',
        gateEnabled: true,
        models: ['claude-haiku'],
        toolServer: 'toolhive-vmcp',
        profiles: [
            {
                name: 'lookup',
                toolServer: 'toolhive-vmcp-lookup',
                codeMode: true,
                tools: [
                    'knowledge_kb_search',
                    'osv_query_vulnerability',
                    'osv_get_vulnerability',
                    'execute_tool_script',
                ],
            },
        ],
        knowledge: { available: true, tools: ['knowledge_kb_search', 'knowledge_kb_get_document'], prompt: 'K prompt' },
        notify: { available: true, tools: ['delivery_notify_send'], prompt: 'N prompt' },
        memory: { available: true, expiryEnabled: true, defaultTtlDays: 15, prompt: 'M prompt' },
        skills: [{ name: 'openagentix-canary', ref: 'r' }],
        reservedNames: ['assistant'],
        policy: {
            maxAgents: 5,
            allowedModels: ['claude-haiku'],
            requireToolProfile: true,
            allowedProfiles: ['lookup'],
            allowKnowledge: true,
            allowNotify: true,
            allowedSkills: ['openagentix-canary'],
            memory: { allowed: true, maxTtlDays: 30, requireExpiry: true },
            egress: { allowedOrigins: ['https://api.osv.dev'] },
            reservedNames: [],
            suspendAll: false,
        },
    };
}

export function agent(over: Partial<Agent> = {}): Agent {
    return {
        name: 'researcher',
        namespace: 'kagent',
        source: 'built',
        description: 'Looks things up',
        model: 'claude-haiku',
        toolProfile: 'lookup',
        toolsCount: 1,
        knowledge: false,
        suspended: false,
        notify: false,
        skills: [],
        egressCount: 0,
        effectiveTools: [],
        effectiveEgress: [],
        state: 'ready',
        stateReason: '',
        deleting: false,
        generation: 1,
        updated: '2026-11-25T10:00:00Z',
        resourceVersion: '7',
        conditions: ['Accepted', 'KeyReady', 'Applied', 'Ready'].map((type) => ({
            type,
            status: 'True' as const,
            reason: type,
        })),
        ...over,
    };
}

export function detail(over: Partial<Detail> = {}): Detail {
    return {
        ...agent(),
        readOnly: false,
        yaml: 'kind: AgentDefinition\n',
        objects: [],
        spec: {
            model: 'claude-haiku',
            instructions: 'Be brief.',
            toolProfile: 'lookup',
            tools: ['osv_query_vulnerability'],
            description: 'Looks things up',
        },
        status: {
            observedGeneration: 1,
            conditions: agent().conditions,
            effectiveTools: [],
            effectiveEgress: [],
            violations: [],
        },
        ...over,
    };
}
