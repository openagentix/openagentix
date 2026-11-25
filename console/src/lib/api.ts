// The one module that talks to the console API. It adds the bearer token, turns failures into the sentence pattern of
// the UI contract (what happened, why, what to do) and signs out on 401.

import { auth } from './auth.svelte';
import type { MetricsSummary } from './metrics';
import type { TraceDetail, Turn } from './traces';
import type { AgentList, Detail, Platform, Session, Spec, ValidateResult, WriteRequest } from './types';

export class ApiError extends Error {
    constructor(
        public readonly status: number,
        public readonly code: string,
        message: string,
    ) {
        super(message);
        this.name = 'ApiError';
    }
    /** 0 means the request never got an answer. */
    get network(): boolean {
        return this.status === 0;
    }
}

interface ErrorBody {
    error?: { code?: string; message?: string };
}

export interface Transport {
    (input: string, init: RequestInit): Promise<Response>;
}

let transport: Transport = (input, init) => fetch(input, init);

/** Tests replace the transport; nothing else should. */
export function setTransport(t: Transport): void {
    transport = t;
}

async function request<T>(method: string, path: string, body?: unknown, signal?: AbortSignal): Promise<T> {
    const headers: Record<string, string> = { Accept: 'application/json' };
    if (auth.token) headers['Authorization'] = `Bearer ${auth.token}`;
    let payload: string | undefined;
    if (body !== undefined) {
        headers['Content-Type'] = 'application/json';
        payload = JSON.stringify(body);
    }
    let res: Response;
    try {
        res = await transport(path, {
            method,
            headers,
            body: payload,
            signal,
            cache: 'no-store',
            credentials: 'omit',
            referrerPolicy: 'no-referrer',
        });
    } catch (e) {
        if (e instanceof DOMException && e.name === 'AbortError') throw e;
        throw new ApiError(
            0,
            'network',
            'The console API did not answer. Check that the port-forward to the console is still running.',
        );
    }
    if (res.status === 401) {
        auth.signOut();
        throw new ApiError(
            401,
            'unauthenticated',
            'The console token was not accepted. Sign in again with the token from the console Secret.',
        );
    }
    if (!res.ok) {
        let e: ErrorBody = {};
        try {
            e = (await res.json()) as ErrorBody;
        } catch {
            /* not JSON: use the status */
        }
        throw new ApiError(
            res.status,
            e.error?.code ?? 'error',
            e.error?.message ?? `The console API returned ${res.status}.`,
        );
    }
    return (await res.json()) as T;
}

export const api = {
    session: (signal?: AbortSignal) => request<Session>('GET', '/api/v1/session', undefined, signal),
    platform: (signal?: AbortSignal) => request<Platform>('GET', '/api/v1/platform', undefined, signal),
    metrics: (window: '24h' | '7d', signal?: AbortSignal) =>
        request<MetricsSummary>('GET', `/api/v1/metrics/summary?window=${window}`, undefined, signal),
    traces: (signal?: AbortSignal) => request<{ items: Turn[] }>('GET', '/api/v1/traces', undefined, signal),
    trace: (id: string, signal?: AbortSignal) =>
        request<TraceDetail>('GET', `/api/v1/traces/${encodeURIComponent(id)}`, undefined, signal),
    agents: (signal?: AbortSignal) => request<AgentList>('GET', '/api/v1/agents', undefined, signal),
    agent: (name: string, signal?: AbortSignal) =>
        request<Detail>('GET', `/api/v1/agents/${encodeURIComponent(name)}`, undefined, signal),
    create: (req: WriteRequest) => request<Detail>('POST', '/api/v1/agents', req),
    update: (name: string, req: WriteRequest) =>
        request<Detail>('PUT', `/api/v1/agents/${encodeURIComponent(name)}`, req),
    remove: (name: string) =>
        request<{ name: string; deleting: boolean }>('DELETE', `/api/v1/agents/${encodeURIComponent(name)}`),
    validate: (name: string, spec: Spec, signal?: AbortSignal) =>
        request<ValidateResult>(
            'POST',
            '/api/v1/agents/validate',
            { name, spec } satisfies Pick<WriteRequest, 'name' | 'spec'>,
            signal,
        ),
};

/**
 * The error message pattern of UI-SPEC section 7: what happened, then why, then what to do. The API already writes its
 * messages that way; this adds the "Could not <action>" head and the hint for statuses that have a known next step.
 */
export function describeError(action: string, subject: string, e: unknown): string {
    if (!(e instanceof ApiError))
        return `Could not ${action} ${subject}: something unexpected happened in the browser. Reload the page.`;
    const head = `Could not ${action} ${subject}`;
    switch (e.status) {
        case 0:
            return `${head}: ${e.message}`;
        case 401:
            return `${head}: ${e.message}`;
        case 403:
            if (e.code === 'forbidden') return `${head}: the console API returned 403. ${e.message}`;
            if (e.code === 'cross_origin')
                return `${head}: the console API returned 403. ${e.message} Open the console from its own address.`;
            return `${head}: the console API returned 403. ${e.message}`;
        case 409:
            return `${head}: the console API returned 409. ${e.message}`;
        default:
            return `${head}: the console API returned ${e.status}. ${e.message}`;
    }
}
